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
struct WebeepFilePickerSheet: View {

    // Un solo file per volta serve dove il chiamante ne mostra uno solo
    // (il pannello Documento): lì la spunta non avrebbe senso e il tocco
    // scarica subito, come prima.
    enum SelectionMode { case single, multiple }

    var selectionMode: SelectionMode = .multiple
    // Chiamata UNA VOLTA PER FILE, in ordine di selezione: i chiamanti
    // che ne gestivano uno solo continuano a funzionare senza modifiche.
    var onPicked: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var courses: [WebeepCourse] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    // In ordine di spunta: è anche l'ordine in cui i file vengono
    // aggiunti, che su una dispensa divisa in parti conta.
    @State private var selected: [WebeepFile] = []
    @State private var downloaded: Int?
    @State private var failedNames: [String] = []

    private var token: String? { WebeepService.savedToken }
    private var isDownloading: Bool { downloaded != nil }

    var body: some View {
        NavigationStack {
            Group {
                if token == nil {
                    ContentUnavailableView(
                        "WeBeep non collegato",
                        systemImage: "link.badge.plus",
                        description: Text("Collega WeBeep dal Profilo, poi torna qui.")
                    )
                } else if isLoading {
                    ProgressView("Carico i corsi…")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Errore",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    List(courses) { course in
                        NavigationLink {
                            WebeepCourseFilesView(
                                course: course,
                                selectionMode: selectionMode,
                                selected: $selected,
                                onPickedSingle: pickSingle
                            )
                        } label: {
                            courseRow(course)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(DesignColor.surfacePage)
                }
            }
            .navigationTitle("PDF da WeBeep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                        .disabled(isDownloading)
                }
            }
        }
        // Fuori dallo NavigationStack: così la barra di conferma resta
        // visibile anche dentro un corso, e si può spuntare in giro
        // senza tornare indietro per confermare.
        .safeAreaInset(edge: .bottom) { confirmBar }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isDownloading)
        .task { await loadCourses() }
    }

    private func courseRow(_ course: WebeepCourse) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(WebeepService.stripMultilang(course.fullname))
                .font(.system(size: 15, weight: .medium))
                .lineLimit(2)
            if let short = course.shortname, !short.isEmpty {
                Text(short)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var confirmBar: some View {
        if selectionMode == .multiple, !selected.isEmpty || isDownloading {
            VStack(spacing: DesignSpace.s2) {
                if !failedNames.isEmpty {
                    // I falliti restano spuntati: si riprova senza
                    // ricominciare la selezione da capo.
                    Text("Non scaricati: \(failedNames.joined(separator: ", ")). Restano selezionati, puoi riprovare.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await addSelected() }
                } label: {
                    HStack(spacing: DesignSpace.s2) {
                        if let downloaded {
                            ProgressView().controlSize(.small).tint(DesignColor.textOnBrand)
                            Text("Scarico \(min(downloaded + 1, selected.count)) di \(selected.count)…")
                        } else {
                            Image(systemName: "plus.circle.fill")
                            Text(selected.count == 1 ? "Aggiungi 1 file" : "Aggiungi \(selected.count) file")
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignColor.textOnBrand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSpace.s3)
                    .background(DesignColor.brandPrimary, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isDownloading)
            }
            .padding(DesignSpace.s4)
            .background(.bar)
        }
    }

    // Modalità a file singolo: invariata, il tocco scarica e chiude.
    private func pickSingle(_ data: Data, _ name: String) {
        onPicked(data, name)
        dismiss()
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

// Secondo livello: i PDF di un corso, raggruppati per sezione.
private struct WebeepCourseFilesView: View {
    let course: WebeepCourse
    let selectionMode: WebeepFilePickerSheet.SelectionMode
    @Binding var selected: [WebeepFile]
    var onPickedSingle: (Data, String) -> Void

    @State private var sections: [WebeepSection] = []
    @State private var isLoading = true
    @State private var downloadingFileID: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Carico i file…")
            } else if pdfSections.isEmpty {
                ContentUnavailableView(
                    "Nessun PDF",
                    systemImage: "doc.questionmark",
                    description: Text("In questo corso non ci sono PDF scaricabili.")
                )
            } else {
                List {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
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
        .navigationTitle(WebeepService.stripMultilang(course.shortname ?? course.fullname))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selectionMode == .multiple, !visibleFiles.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(allVisibleSelected ? "Deseleziona tutti" : "Tutti") {
                        toggleAllVisible()
                    }
                    .font(.system(size: 14, weight: .medium))
                }
            }
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
            if selectionMode == .multiple {
                toggle(file)
            } else {
                Task { await download(file) }
            }
        } label: {
            HStack(spacing: DesignSpace.s3) {
                Image(systemName: icon(for: file))
                    .foregroundStyle(isSelected(file) ? DesignColor.brandPrimary : DesignColor.brandPrimary.opacity(0.7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.filename)
                        .font(.system(size: 14))
                        .foregroundStyle(DesignColor.textPrimary)
                        .lineLimit(2)
                    if let sub = file.subfolderName {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                }
                Spacer()
                if downloadingFileID == file.id {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(selectionMode == .single && downloadingFileID != nil)
    }

    private func icon(for file: WebeepFile) -> String {
        guard selectionMode == .multiple else { return "doc.richtext" }
        return isSelected(file) ? "checkmark.circle.fill" : "circle"
    }

    private func isSelected(_ file: WebeepFile) -> Bool {
        selected.contains { $0.id == file.id }
    }

    private func toggle(_ file: WebeepFile) {
        if let index = selected.firstIndex(where: { $0.id == file.id }) {
            selected.remove(at: index)
        } else {
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

    private func download(_ file: WebeepFile) async {
        guard let token = WebeepService.savedToken else { return }
        downloadingFileID = file.id
        errorMessage = nil
        defer { downloadingFileID = nil }
        do {
            let data = try await WebeepService.downloadFile(file, token: token)
            onPickedSingle(data, file.filename)
        } catch {
            errorMessage = "Download non riuscito: \(error.localizedDescription)"
        }
    }
}
