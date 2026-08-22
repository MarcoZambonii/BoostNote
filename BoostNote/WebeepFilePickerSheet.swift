import SwiftUI

// Selettore di PDF direttamente dai corsi WeBeep: corso → file, scarica e
// consegna i byte al chiamante. Niente download manuale e re-import dai
// File: il percorso più comune (leggere le slide del corso mentre si
// scrive) diventa due tocchi.
//
// La selezione è MULTIPLA e vive nel foglio, non nella schermata del
// corso: si spuntano più file, si cambia corso, si spunta ancora, e si
// conferma una volta sola. Aggiungere dieci dispense al Vault non deve
// voler dire aprire e chiudere il foglio dieci volte.
//
// Sheet commit (§4): il verbo in alto a destra è l'unica conferma, anche
// in modalità singola («Scegli»), dove prima il tocco scaricava subito.
// Il drilldown corso → file è a stato interno, non NavigationStack: la
// testata resta quella di BoostSheet.
struct WebeepFilePickerSheet: View {

    // Un solo file per volta serve dove il chiamante ne mostra uno solo
    // (il pannello Documento): lì la spunta diventa una scelta radio e
    // il verbo di conferma è «Scegli».
    enum SelectionMode { case single, multiple }

    var selectionMode: SelectionMode = .multiple
    // Chiamata UNA VOLTA PER FILE, in ordine di selezione: i chiamanti
    // che ne gestivano uno solo continuano a funzionare senza modifiche.
    var onPicked: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var courses: [WebeepCourse] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var openCourse: WebeepCourse?

    // In ordine di spunta: è anche l'ordine in cui i file vengono
    // aggiunti, che su una dispensa divisa in parti conta.
    @State private var selected: [WebeepFile] = []
    @State private var downloaded: Int?
    @State private var failedNames: [String] = []

    private var token: String? { WebeepService.savedToken }
    private var isDownloading: Bool { downloaded != nil }

    private var confirmVerb: String {
        switch selectionMode {
        case .single: "Scegli"
        case .multiple: selected.isEmpty ? "Aggiungi" : "Aggiungi (\(selected.count))"
        }
    }

    var body: some View {
        BoostSheet(
            title: "PDF da WeBeep",
            mode: .commit(verb: confirmVerb, enabled: !selected.isEmpty && !isDownloading),
            onDismiss: {
                guard !isDownloading else { return }
                dismiss()
            },
            onConfirm: { Task { await addSelected() } }
        ) {
            VStack(spacing: 0) {
                Group {
                    if token == nil {
                        BoostState(
                            kind: .empty,
                            icon: "link.badge.plus",
                            title: "WeBeep non collegato",
                            message: "Collega WeBeep dal Profilo, poi torna qui."
                        )
                    } else if isLoading {
                        BoostState(kind: .loading, title: "Carico i corsi…")
                    } else if let errorMessage {
                        BoostState(
                            kind: .error,
                            icon: "exclamationmark.triangle",
                            title: "Errore",
                            message: errorMessage
                        )
                    } else if let openCourse {
                        WebeepCourseFilesView(
                            course: openCourse,
                            selectionMode: selectionMode,
                            selected: $selected,
                            onBack: { self.openCourse = nil }
                        )
                    } else {
                        coursesList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                statusBar
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isDownloading)
        .task { await loadCourses() }
    }

    private var coursesList: some View {
        List(courses) { course in
            Button {
                openCourse = course
            } label: {
                HStack(spacing: DesignSpace.s3) {
                    courseRow(course)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: DesignIcon.sm))
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DesignColor.surfacePage)
    }

    private func courseRow(_ course: WebeepCourse) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(WebeepService.stripMultilang(course.fullname))
                .font(DesignFont.body)
                .foregroundStyle(DesignColor.textPrimary)
                .lineLimit(2)
            if let short = course.shortname, !short.isEmpty {
                Text(short)
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textTertiary)
            }
        }
    }

    // Progresso del download e file falliti: sotto la lista, mentre la
    // conferma resta nella testata.
    @ViewBuilder
    private var statusBar: some View {
        if isDownloading || !failedNames.isEmpty {
            VStack(spacing: DesignSpace.s2) {
                if !failedNames.isEmpty {
                    // I falliti restano spuntati: si riprova senza
                    // ricominciare la selezione da capo.
                    Text("Non scaricati: \(failedNames.joined(separator: ", ")). Restano selezionati, puoi riprovare.")
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let downloaded {
                    HStack(spacing: DesignSpace.s2) {
                        ProgressView().controlSize(.small)
                        Text("Scarico \(min(downloaded + 1, selected.count)) di \(selected.count)…")
                            .font(DesignFont.caption)
                            .foregroundStyle(DesignColor.textSecondary)
                        Spacer()
                    }
                }
            }
            .padding(DesignSpace.s4)
            .background(.bar)
        }
    }

    private func addSelected() async {
        guard let token, !selected.isEmpty else { return }
        failedNames = []
        var failed: [WebeepFile] = []
        for (index, file) in selected.enumerated() {
            downloaded = index
            do {
                let data = try await WebeepService.downloadFile(file, token: token)
                onPicked(data, file.filename)
            } catch {
                // Un file che non scende non deve far perdere gli altri:
                // si tira avanti e si riferisce alla fine.
                failed.append(file)
            }
        }
        downloaded = nil
        guard failed.isEmpty else {
            selected = failed
            failedNames = failed.map(\.filename)
            return
        }
        dismiss()
    }

    private func loadCourses() async {
        guard let token else { isLoading = false; return }
        defer { isLoading = false }
        do {
            let info = try await WebeepService.siteInfo(token: token)
            courses = try await WebeepService.courses(token: token, userID: info.userid)
            if courses.isEmpty {
                errorMessage = "Nessun corso trovato sull'account."
            }
        } catch WebeepServiceError.invalidToken {
            errorMessage = "La sessione WeBeep è scaduta: ricollega l'account dal Profilo."
        } catch {
            errorMessage = "WeBeep non risponde: controlla la connessione e riprova."
        }
    }
}

// Secondo livello: i PDF di un corso, raggruppati per sezione. Vive
// dentro la BoostSheet del genitore; il ritorno ai corsi è il bottone
// ghost in testa alla lista.
private struct WebeepCourseFilesView: View {
    let course: WebeepCourse
    let selectionMode: WebeepFilePickerSheet.SelectionMode
    @Binding var selected: [WebeepFile]
    var onBack: () -> Void

    @State private var sections: [WebeepSection] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s3) {
                BoostButton("Corsi", icon: "chevron.left", tone: .ghost, size: .compact) {
                    onBack()
                }
                Text(WebeepService.stripMultilang(course.shortname ?? course.fullname))
                    .font(DesignFont.cardTitle)
                    .foregroundStyle(DesignColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                if selectionMode == .multiple, !visibleFiles.isEmpty {
                    BoostButton(allVisibleSelected ? "Deseleziona tutti" : "Tutti", tone: .ghost, size: .compact) {
                        toggleAllVisible()
                    }
                }
            }
            .padding(.horizontal, DesignSpace.s4)
            .padding(.vertical, DesignSpace.s2)

            Group {
                if isLoading {
                    BoostState(kind: .loading, title: "Carico i file…")
                } else if pdfSections.isEmpty {
                    BoostState(
                        kind: .empty,
                        icon: "doc.questionmark",
                        title: "Nessun PDF",
                        message: "In questo corso non ci sono PDF scaricabili."
                    )
                } else {
                    List {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(DesignFont.caption)
                                .foregroundStyle(DesignColor.danger)
                        }
                        ForEach(pdfSections) { section in
                            Section(WebeepService.stripMultilang(section.name ?? "Sezione")) {
                                ForEach(pdfFiles(in: section)) { file in
                                    fileRow(file)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(DesignColor.surfacePage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            guard let token = WebeepService.savedToken else { isLoading = false; return }
            defer { isLoading = false }
            do {
                sections = try await WebeepService.contents(token: token, courseID: course.id)
            } catch {
                errorMessage = "Non riesco a caricare i file del corso: controlla la connessione e riprova."
            }
        }
    }

    private func fileRow(_ file: WebeepFile) -> some View {
        Button {
            toggle(file)
        } label: {
            HStack(spacing: DesignSpace.s3) {
                Image(systemName: isSelected(file) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected(file) ? DesignColor.brandPrimary : DesignColor.borderDefault)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.filename)
                        .font(DesignFont.body)
                        .foregroundStyle(DesignColor.textPrimary)
                        .lineLimit(2)
                    if let sub = file.subfolderName {
                        Text(sub)
                            .font(DesignFont.caption)
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                }
                Spacer()
            }
        }
    }

    private func isSelected(_ file: WebeepFile) -> Bool {
        selected.contains { $0.id == file.id }
    }

    private func toggle(_ file: WebeepFile) {
        if let index = selected.firstIndex(where: { $0.id == file.id }) {
            selected.remove(at: index)
        } else {
            // In modalità singola la spunta è una radio: la nuova scelta
            // scalza la precedente.
            if selectionMode == .single { selected.removeAll() }
            selected.append(file)
        }
    }

    private var visibleFiles: [WebeepFile] {
        pdfSections.flatMap(pdfFiles(in:))
    }

    private var allVisibleSelected: Bool {
        !visibleFiles.isEmpty && visibleFiles.allSatisfy(isSelected)
    }

    // "Tutti" agisce sul corso aperto, non sulla selezione globale: gli
    // spuntati altrove restano dove sono.
    private func toggleAllVisible() {
        if allVisibleSelected {
            let ids = Set(visibleFiles.map(\.id))
            selected.removeAll { ids.contains($0.id) }
        } else {
            for file in visibleFiles where !isSelected(file) { selected.append(file) }
        }
    }

    private func isPDF(_ file: WebeepFile) -> Bool {
        file.mimetype == "application/pdf" || file.filename.lowercased().hasSuffix(".pdf")
    }

    private func pdfFiles(in section: WebeepSection) -> [WebeepFile] {
        section.files.filter(isPDF)
    }

    private var pdfSections: [WebeepSection] {
        sections.filter { !pdfFiles(in: $0).isEmpty }
    }
}
