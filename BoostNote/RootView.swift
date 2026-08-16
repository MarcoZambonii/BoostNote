import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var selectedNote: Note?
    @State private var selectedFolder: Folder?
    @State private var environment: AppEnvironment = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingProfile = false

    // Selezione dell'ambiente Studio. Vive qui e non dentro
    // StudioEnvironmentView perché ora è la barra laterale principale a
    // pilotarla: l'albero sceglie cosa mostrare, il dettaglio la riflette.
    @State private var selectedStudy: Study?
    @State private var selectedStudyModule: StudyModule?
    @State private var showingStudioProgress = false
    @State private var showingStudioCreate = false

    var body: some View {
        // La nota aperta è un LIVELLO SOPRA la split view, non il suo
        // detail: lo swipe dal bordo che riapre la sidebar è un gesto di
        // sistema senza interruttore pubblico, e dentro una nota
        // interferiva con la scrittura (richiesta utente 2026-08-16).
        // Coprendo tutto, il gesto può pure scattare: succede sotto,
        // invisibile, e l'unica uscita resta il pulsante indietro.
        ZStack {
            splitView
            if let selectedNote {
                NoteEditorView(note: selectedNote, onBack: { self.selectedNote = nil })
                    .id(selectedNote.persistentModelID)
                    .background(DesignColor.surfacePage)
            }
        }
        .sheet(isPresented: $showingProfile) {
            NavigationStack {
                ProfileView()
            }
        }
        // Nella nota niente ora/batteria: il modificatore DEVE stare qui
        // alla radice — dentro il detail della NavigationSplitView la
        // preferenza non risale fino al view controller che comanda la
        // barra di stato e veniva ignorata in silenzio. (Serve comunque
        // UIRequiresFullScreen nell'Info.plist: le app con Split View
        // non possono nascondere la barra per regola di iPadOS.)
        .statusBarHidden(selectedNote != nil)
        .task {
            migrateSubjectsToFolders()
            retireWhiteboards()
        }
        .onChange(of: selectedNote) { _, newValue in
            // Non tocca selectedFolder: chiudendo la nota si torna alla
            // cartella da cui si era partiti, non sempre alla Home.
            if newValue != nil { environment = .home }
        }
        .onChange(of: selectedFolder) { _, newValue in
            if newValue != nil { environment = .home; selectedNote = nil }
        }
        .onChange(of: selectedStudy) { _, newValue in
            // Scegliere uno studio dall'albero esce dal flusso di creazione
            // e dai progressi senza doverli chiudere a mano.
            if newValue != nil {
                showingStudioCreate = false
                showingStudioProgress = false
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                environment: $environment,
                selectedNote: $selectedNote,
                selectedFolder: $selectedFolder,
                selectedStudy: $selectedStudy,
                selectedStudyModule: $selectedStudyModule,
                showingStudioProgress: $showingStudioProgress,
                onCreateStudy: {
                    selectedStudy = nil
                    selectedStudyModule = nil
                    showingStudioProgress = false
                    showingStudioCreate = true
                },
                onOpenProfile: { showingProfile = true }
            )
            // Nessuna schermata usa il pulsante di sistema per aprire/chiudere
            // la sidebar: la navigazione passa dai controlli propri dell'app
            // (righe della sidebar, pulsante indietro nella nota, ecc.). Il
            // modificatore va sulla colonna sidebar stessa, non sull'intera
            // NavigationSplitView: lì non sopprimeva il pulsante di sistema.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .toolbar(removing: .sidebarToggle)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch environment {
        case .home:
            if let selectedFolder {
                FolderContentsView(folder: selectedFolder, selectedNote: $selectedNote, selectedFolder: $selectedFolder)
                    .id(selectedFolder.persistentModelID)
            } else {
                HomeView(
                    selectedNote: $selectedNote,
                    // I ponti "Da ripassare" della Home portano nello
                    // Studio: la navigazione la possiede questa radice.
                    onOpenStudyModule: { study, module in
                        selectedStudy = study
                        selectedStudyModule = module
                        environment = .studio
                    },
                    onOpenProgress: {
                        selectedStudy = nil
                        selectedStudyModule = nil
                        showingStudioProgress = true
                        environment = .studio
                    }
                )
            }
        case .studio:
            StudioEnvironmentView(
                selectedStudy: $selectedStudy,
                selectedModule: $selectedStudyModule,
                showingProgress: $showingStudioProgress,
                showingCreate: $showingStudioCreate
            )
        case .ricerca:
            ResearchEnvironmentView(selectedNote: $selectedNote)
        case .webeep:
            WebeepEnvironmentView(selectedNote: $selectedNote)
        }
    }

    // Gli studi creati prima delle cartelle vere erano raggruppati per il
    // campo testuale "materia": qui quella materia diventa una cartella
    // vera, una sola volta, così l'organizzazione già fatta dall'utente
    // non si perde nel passaggio.
    // Le lavagne infinite sono state ELIMINATE dall'app (decisione
    // utente 2026-08-16): quelle esistenti diventano note normali a
    // pagine. Il disegno non si perde: alla prima apertura
    // migrateLegacyContentToPages lo porta nella prima pagina, che è
    // esattamente il percorso già collaudato per le note pre-pagine.
    private func retireWhiteboards() {
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.isWhiteboard == true })
        guard let whiteboards = try? context.fetch(descriptor), !whiteboards.isEmpty else { return }
        for note in whiteboards {
            note.isWhiteboard = false
            // Il template a crocette era il segno distintivo della
            // lavagna: sulla nota a pagine torna il default.
            if note.template == .cross { note.template = .blank }
        }
    }

    private func migrateSubjectsToFolders() {
        let descriptor = FetchDescriptor<Study>()
        guard let studies = try? context.fetch(descriptor) else { return }
        let pending = studies.filter { $0.folder == nil && !$0.subject.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !pending.isEmpty else { return }

        let folderDescriptor = FetchDescriptor<StudyFolder>()
        var folders = (try? context.fetch(folderDescriptor)) ?? []

        for study in pending {
            let name = study.subject.trimmingCharacters(in: .whitespaces)
            if let existing = folders.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                study.folder = existing
            } else {
                let folder = StudyFolder(name: name)
                context.insert(folder)
                folders.append(folder)
                study.folder = folder
            }
            // Si azzera la materia dopo averla convertita, altrimenti la
            // migrazione è eterna: cancellando la cartella lo studio
            // tornava senza cartella ma con la materia ancora scritta, e
            // al riavvio successivo la cartella RISORGEVA. Le cartelle
            // cancellate devono restare cancellate.
            study.subject = ""
        }
    }
}
