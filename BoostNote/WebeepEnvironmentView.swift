import SwiftUI
import SwiftData

// Ambiente "WeBeep" a tutta pagina nella sidebar (non più un popup): sfoglia
// corsi e file veri di WeBeep, raggruppati per sezione come sulla vera
// piattaforma, e li importa in una nota nuova o esistente.
struct WebeepEnvironmentView: View {
    @Environment(\.modelContext) private var context
    @Binding var selectedNote: Note?

    @State private var token: String? = WebeepService.savedToken
    @State private var siteInfo: WebeepSiteInfo?
    @State private var courses: [WebeepCourse] = []
    @State private var selectedCourse: WebeepCourse?
    @State private var sections: [WebeepSection] = []
    @State private var isLoading = false
    @State private var showingAuth = false
    // WeBeep irraggiungibile (rete, servizio giù): il token resta valido
    // e si mostra un errore con Riprova, non la schermata di login.
    @State private var loadError: String?

    @State private var pendingFile: WebeepFile?
    // Presentazione separata dai dati: il Binding calcolato che azzerava
    // pendingFile alla chiusura faceva una corsa col Task del bottone,
    // che spesso leggeva già nil — l'import non partiva mai.
    @State private var showingImportChoice = false
    @State private var showingNotePicker = false
    @State private var isImporting = false

    @State private var quickLookURL: URL?
    @State private var isLoadingPreview = false
    @State private var previewingFileID: String?

    @State private var downloadURL: URL?
    @State private var isDownloading = false
    @State private var downloadingFileID: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Group {
                if token == nil {
                    connectPrompt
                } else if isLoading && courses.isEmpty && selectedCourse == nil {
                    BoostState(kind: .loading, title: "Carico i corsi…")
                } else if let loadError {
                    VStack(spacing: DesignSpace.s3) {
                        BoostState(
                            kind: .error,
                            icon: "wifi.exclamationmark",
                            title: "WeBeep non risponde",
                            message: loadError
                        )
                        BoostButton("Riprova", icon: "arrow.clockwise", tone: .primary) {
                            Task {
                                if let course = selectedCourse {
                                    await loadSections(course)
                                } else {
                                    await refresh()
                                }
                            }
                        }
                        .padding(.bottom, DesignSpace.s6)
                    }
                } else if let selectedCourse {
                    fileList(for: selectedCourse)
                } else {
                    courseList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignColor.surfaceSunken)
        .task { await refresh() }
        .fullScreenCover(isPresented: $showingAuth) {
            WebeepAuthView(
                onToken: { newToken in
                    WebeepService.save(token: newToken)
                    token = newToken
                    showingAuth = false
                    Task { await refresh() }
                },
                onCancel: { showingAuth = false }
            )
            .ignoresSafeArea()
        }
        .confirmationDialog(
            "Come vuoi importare questo file?",
            isPresented: $showingImportChoice,
            titleVisibility: .visible
        ) {
            // Il file viene catturato SUBITO nell'azione del bottone: il
            // Task parte dopo la chiusura del dialogo, quando pendingFile
            // potrebbe già essere stato azzerato.
            Button("In una nuova nota") {
                if let file = pendingFile { Task { await importFile(file, target: .newNote) } }
            }
            Button("In una nota esistente") { showingNotePicker = true }
            Button("Annulla", role: .cancel) { pendingFile = nil }
        }
        .sheet(isPresented: $showingNotePicker) {
            WebeepNotePickerSheet { note in
                showingNotePicker = false
                if let file = pendingFile { Task { await importFile(file, target: .existingNote(note)) } }
            }
        }
        .sheet(isPresented: Binding(get: { downloadURL != nil }, set: { if !$0 { downloadURL = nil } })) {
            if let downloadURL {
                ActivityView(items: [downloadURL])
            }
        }
        .fullScreenCover(isPresented: Binding(get: { quickLookURL != nil }, set: { if !$0 { quickLookURL = nil } })) {
            if let quickLookURL {
                ZStack(alignment: .topLeading) {
                    QuickLookPreview(url: quickLookURL)
                        .ignoresSafeArea()

                    Button {
                        self.quickLookURL = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: DesignIcon.md))
                            Text("File")
                                .font(DesignFont.cardTitle)
                        }
                        .foregroundStyle(DesignColor.textPrimary)
                        .padding(.horizontal, DesignSpace.s4)
                        .frame(height: 36)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous).stroke(DesignColor.borderDefault, lineWidth: 1))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    }
                    .padding(.top, DesignSpace.s4)
                    .padding(.leading, DesignSpace.s4)
                }
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSpace.s3) {
            // Stessa testata di Home e Studio: titolone col suo emoji e
            // una riga di contesto sotto. Prima questa schermata aveva
            // una barra tutta sua, alta 56 e col titolo da card: era
            // l'unico posto dell'app che si presentava così.
            if let selectedCourse {
                BoostButton("Corsi", icon: "chevron.left", tone: .ghost, size: .compact) {
                    self.selectedCourse = nil
                    sections = []
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(WebeepService.stripMultilang(selectedCourse.fullname))
                        .font(DesignFont.sectionTitle)
                        .foregroundStyle(DesignColor.textPrimary)
                        .lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WeBeep 🏛️")
                        .font(DesignFont.screenTitle)
                        .foregroundStyle(DesignColor.textPrimary)
                    if let siteInfo {
                        Text(siteInfo.fullname)
                            .font(DesignFont.label)
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                }
            }
            Spacer()
            if isImporting {
                // L'import scarica il file: senza questo, dopo il tocco
                // su "In una nuova nota" non si vedeva succedere niente
                // (anteprima e download avevano già il loro spinner).
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Importo…")
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Aggiorno…")
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
        }
        .padding(.horizontal, DesignSpace.s6)
        .padding(.top, DesignSpace.s6)
        .padding(.bottom, DesignSpace.s4)
        .background(DesignColor.surfacePage)
    }

    private var connectPrompt: some View {
        VStack(spacing: DesignSpace.s4) {
            Image(systemName: "building.columns")
                .font(.system(size: DesignIcon.xl))
                .foregroundStyle(DesignColor.textTertiary)
            Text("Collega WeBeep")
                .font(DesignFont.sectionTitle)
                .foregroundStyle(DesignColor.textPrimary)
            Text("Il login avviene sulla vera pagina Polimi in un browser incorporato: l'app non vede mai la password.")
                .font(DesignFont.label)
                .foregroundStyle(DesignColor.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            BoostButton("Accedi con WeBeep", tone: .primary) { showingAuth = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var courseList: some View {
        Group {
            if courses.isEmpty && !isLoading {
                BoostState(kind: .empty, icon: "building.columns", title: "Nessun corso trovato")
            } else {
                ScrollView {
                    LazyVStack(spacing: DesignSpace.s2) {
                        ForEach(courses) { course in
                            Button {
                                selectedCourse = course
                                Task { await loadSections(course) }
                            } label: {
                                HStack(spacing: DesignSpace.s3) {
                                    Image(systemName: "graduationcap.fill")
                                        .foregroundStyle(DesignColor.brandPrimary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(WebeepService.stripMultilang(course.fullname))
                                            .font(DesignFont.body)
                                            .foregroundStyle(DesignColor.textPrimary)
                                            .multilineTextAlignment(.leading)
                                        if let shortname = course.shortname {
                                            Text(shortname)
                                                .font(DesignFont.caption)
                                                .foregroundStyle(DesignColor.textTertiary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: DesignIcon.sm))
                                        .foregroundStyle(DesignColor.textTertiary)
                                }
                                .padding(DesignSpace.s4)
                                .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                                        .stroke(DesignColor.borderSubtle, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(DesignSpace.s5)
                }
            }
        }
    }

    private func fileList(for course: WebeepCourse) -> some View {
        Group {
            if sections.allSatisfy({ $0.files.isEmpty }) && !isLoading {
                BoostState(kind: .empty, icon: "doc", title: "Nessun file trovato")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignSpace.s5) {
                        ForEach(sections) { section in
                            if !section.files.isEmpty {
                                VStack(alignment: .leading, spacing: DesignSpace.s3) {
                                    Text(WebeepService.stripMultilang(section.name?.isEmpty == false ? section.name! : "Materiali"))
                                        .font(DesignFont.caption)
                                        .tracking(0.4)
                                        .foregroundStyle(DesignColor.textTertiary)
                                        .padding(.horizontal, DesignSpace.s2)

                                    // Ogni modulo Moodle con più file (o di tipo "folder") è
                                    // una vera cartella su WeBeep — spesso quella del
                                    // professore o dell'argomento — quindi resta un gruppo
                                    // a sé invece di finire appiattita nella sezione.
                                    ForEach(section.modulesWithFiles) { module in
                                        moduleGroup(module)
                                    }
                                }
                            }
                        }
                    }
                    .padding(DesignSpace.s5)
                }
            }
        }
    }

    @ViewBuilder
    private func moduleGroup(_ module: WebeepModule) -> some View {
        let files = module.contents ?? []
        let isFolder = files.count > 1 || module.modname == "folder"
        // Dentro un modulo "folder" i file possono stare in sottocartelle
        // reali (filepath) — è la suddivisione che il professore ha
        // davvero impostato, non solo un livello piatto di file.
        let rootFiles = files.filter { $0.subfolderName == nil }
        let subfolders = Dictionary(grouping: files.filter { $0.subfolderName != nil }) { $0.subfolderName! }
        let subfolderNames = subfolders.keys.sorted()

        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            if isFolder {
                Label(WebeepService.stripMultilang(module.name?.isEmpty == false ? module.name! : "Cartella"), systemImage: "folder.fill")
                    .font(DesignFont.cardTitle)
                    .foregroundStyle(DesignColor.textSecondary)
                    .padding(.horizontal, DesignSpace.s2)
            }

            if !rootFiles.isEmpty {
                fileGroupCard(rootFiles)
            }

            ForEach(subfolderNames, id: \.self) { name in
                VStack(alignment: .leading, spacing: DesignSpace.s2) {
                    Label(WebeepService.stripMultilang(name), systemImage: "folder")
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                        .padding(.horizontal, DesignSpace.s4)
                    fileGroupCard(subfolders[name] ?? [])
                        .padding(.leading, DesignSpace.s4)
                }
            }
        }
    }

    private func fileGroupCard(_ files: [WebeepFile]) -> some View {
        VStack(spacing: 1) {
            ForEach(files) { file in
                fileRow(file)
            }
        }
        .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                .stroke(DesignColor.borderSubtle, lineWidth: 1)
        )
    }

    private func fileRow(_ file: WebeepFile) -> some View {
        HStack(spacing: DesignSpace.s3) {
            Image(systemName: isPDF(file) ? "doc.richtext" : (isImage(file) ? "photo" : "doc"))
                .foregroundStyle(DesignColor.brandPrimary)
                .frame(width: 22)
            Text(WebeepService.stripMultilang(file.filename))
                .font(DesignFont.body)
                .foregroundStyle(DesignColor.textPrimary)
                .multilineTextAlignment(.leading)
            Spacer()

            if isLoadingPreview && previewingFileID == file.id {
                ProgressView().frame(width: 20, height: 20)
            } else {
                Button {
                    Task { await quickLook(file) }
                } label: {
                    Image(systemName: "eye")
                        .foregroundStyle(DesignColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Vista rapida")
            }

            if isDownloading && downloadingFileID == file.id {
                ProgressView().frame(width: 20, height: 20)
            } else {
                Button {
                    Task { await download(file) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(DesignColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scarica")
            }

            Button {
                pendingFile = file
                showingImportChoice = true
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(isPDF(file) || isImage(file) ? DesignColor.textTertiary : DesignColor.textTertiary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
            .accessibilityLabel("Aggiungi a una nota")
        }
        .padding(.horizontal, DesignSpace.s4)
        .padding(.vertical, DesignSpace.s3)
    }

    private func refresh() async {
        guard let token else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let info = try await WebeepService.siteInfo(token: token)
            siteInfo = info
            courses = try await WebeepService.courses(token: token, userID: info.userid)
        } catch WebeepServiceError.invalidToken {
            // SOLO quando Moodle dichiara il token morto si torna al
            // login: prima anche un errore di rete disconnetteva WeBeep
            // buttando un token valido dal Keychain.
            WebeepService.signOut()
            self.token = nil
        } catch {
            loadError = "Controlla la connessione e riprova: il collegamento a WeBeep resta attivo."
        }
    }

    private func loadSections(_ course: WebeepCourse) async {
        guard let token else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            sections = try await WebeepService.contents(token: token, courseID: course.id)
        } catch WebeepServiceError.invalidToken {
            WebeepService.signOut()
            self.token = nil
        } catch {
            loadError = "Controlla la connessione e riprova: il collegamento a WeBeep resta attivo."
        }
    }

    private func isPDF(_ file: WebeepFile) -> Bool {
        file.mimetype == "application/pdf" || file.filename.lowercased().hasSuffix(".pdf")
    }

    private func isImage(_ file: WebeepFile) -> Bool {
        if let mime = file.mimetype, mime.hasPrefix("image/") { return true }
        let ext = (file.filename as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp"].contains(ext)
    }

    private func download(_ file: WebeepFile) async {
        guard let token else {
            BoostToastCenter.shared.show("Non sei collegato a WeBeep: riaccedi e riprova.", role: .danger)
            return
        }
        isDownloading = true
        downloadingFileID = file.id
        defer { isDownloading = false; downloadingFileID = nil }

        let data: Data
        do {
            data = try await WebeepService.downloadFile(file, token: token)
        } catch {
            BoostToastCenter.shared.show("\"\(file.filename)\": \((error as? WebeepDownloadError)?.message ?? error.localizedDescription)", role: .danger)
            return
        }
        let safeName = WebeepService.stripMultilang(file.filename).replacingOccurrences(of: "/", with: "-")
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
            try data.write(to: tmpURL, options: .atomic)
            downloadURL = tmpURL
        } catch {
            BoostToastCenter.shared.show("Non sono riuscito a salvare \"\(file.filename)\".", role: .danger)
        }
    }

    private func quickLook(_ file: WebeepFile) async {
        guard let token else {
            BoostToastCenter.shared.show("Non sei collegato a WeBeep: riaccedi e riprova.", role: .danger)
            return
        }
        isLoadingPreview = true
        previewingFileID = file.id
        defer { isLoadingPreview = false; previewingFileID = nil }

        let data: Data
        do {
            data = try await WebeepService.downloadFile(file, token: token)
        } catch {
            BoostToastCenter.shared.show("\"\(file.filename)\": \((error as? WebeepDownloadError)?.message ?? error.localizedDescription)", role: .danger)
            return
        }
        let safeName = WebeepService.stripMultilang(file.filename).replacingOccurrences(of: "/", with: "-")
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
            try data.write(to: tmpURL, options: .atomic)
            quickLookURL = tmpURL
        } catch {
            BoostToastCenter.shared.show("Non sono riuscito ad aprire l'anteprima di \"\(file.filename)\".", role: .danger)
        }
    }

    private enum ImportTarget {
        case newNote
        case existingNote(Note)
    }

    private func importFile(_ file: WebeepFile, target: ImportTarget) async {
        guard !isImporting else { return }
        guard let token else {
            BoostToastCenter.shared.show("Non sei collegato a WeBeep: riaccedi e riprova.", role: .danger)
            return
        }
        isImporting = true
        defer { isImporting = false; pendingFile = nil }

        let data: Data
        do {
            data = try await WebeepService.downloadFile(file, token: token)
        } catch {
            BoostToastCenter.shared.show("\"\(WebeepService.stripMultilang(file.filename))\": \((error as? WebeepDownloadError)?.message ?? error.localizedDescription)", role: .danger)
            return
        }

        let note: Note
        switch target {
        case .newNote:
            note = Note(title: WebeepService.stripMultilang(file.filename), folder: nil)
            context.insert(note)
        case .existingNote(let existing):
            note = existing
        }

        // Prima il bug era che QUALSIASI file non-PDF veniva comunque
        // inserito come NoteMedia(kind: .pdf): PDFDocument(data:) su un
        // file che non è un vero PDF (slide, doc, immagine) restituisce
        // nil e il widget appariva vuoto/rotto, senza nessun errore.
        if isPDF(file) {
            guard note.appendPages(fromPDF: data, in: context) else {
                if case .newNote = target { context.delete(note) }
                BoostToastCenter.shared.show("\"\(WebeepService.stripMultilang(file.filename))\" non è un PDF leggibile — probabilmente WeBeep ha restituito una pagina di errore invece del file (token scaduto?). Prova a scaricarlo con la freccia per controllare, o a riaccedere a WeBeep.", role: .danger)
                return
            }
        } else if isImage(file) {
            // Aggancio dal lato genitore (media.append): vedi Note.attach.
            let media = NoteMedia(x: 60, y: 60, kind: .image, data: data)
            context.insert(media)
            note.media.append(media)
        } else {
            if case .newNote = target { context.delete(note) }
            BoostToastCenter.shared.show("\"\(WebeepService.stripMultilang(file.filename))\" non è un PDF né un'immagine: per ora puoi solo scaricarlo o vederne l'anteprima, non aggiungerlo direttamente alla nota.", role: .danger)
            return
        }
        note.updatedAt = .now
        selectedNote = note
    }
}

// Elenco di tutte le note per scegliere dove importare un file WeBeep.
private struct WebeepNotePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Note.updatedAt, order: .reverse) private var allNotes: [Note]
    var onSelect: (Note) -> Void

    // Il tocco seleziona, «Aggiungi» conferma: stessa meccanica di ogni
    // sheet commit (§4), invece dell'esecuzione al tocco.
    @State private var selectedNoteID: UUID?

    var body: some View {
        BoostSheet(
            title: "Scegli una nota",
            mode: .commit(verb: "Aggiungi", enabled: selectedNoteID != nil),
            onDismiss: { dismiss() },
            onConfirm: {
                if let note = allNotes.first(where: { $0.id == selectedNoteID }) {
                    onSelect(note)
                }
            }
        ) {
            List(allNotes) { note in
                let isSelected = selectedNoteID == note.id
                Button {
                    selectedNoteID = isSelected ? nil : note.id
                } label: {
                    HStack(spacing: DesignSpace.s3) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? DesignColor.brandPrimary : DesignColor.borderDefault)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title.isEmpty ? "Senza titolo" : note.title)
                                .foregroundStyle(.primary)
                            if let folder = note.folder {
                                Text(folder.name)
                                    .font(DesignFont.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
