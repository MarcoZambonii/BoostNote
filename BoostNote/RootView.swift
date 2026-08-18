import SwiftUI
import SwiftData

// Destinazioni della navigazione su iPhone: la split view collassata non
// mostrava MAI il dettaglio (la selezione passa da binding nostri, non
// dalla List), quindi su schermo compatto l'app si fermava alla sidebar.
// Qui ogni scelta della sidebar diventa un push esplicito su uno stack.
private enum CompactDestination: Hashable {
    case environment(AppEnvironment)
    case folder(Folder)
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedNote: Note?
    @State private var selectedFolder: Folder?
    @State private var environment: AppEnvironment = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingProfile = false
    // Percorso dello stack su iPhone. Vive anche quando si è su iPad:
    // ruotando o entrando in Split View il size class cambia e lo stato
    // non deve perdersi.
    @State private var compactPath: [CompactDestination] = []
    private var archiveOpenRequest = ArchiveOpenRequest.shared

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
            if horizontalSizeClass == .compact {
                compactStack
            } else {
                splitView
            }
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
        // Pacchetto .boostnote aperto da Files: si ripristina e la nota
        // si apre subito, così il ripristino si vede invece di essere
        // solo "avvenuto".
        .onChange(of: archiveOpenRequest.url) { _, url in
            guard let url else { return }
            archiveOpenRequest.url = nil
            if let note = try? NoteArchiveService.restore(from: url, in: context) {
                environment = .home
                selectedNote = note
            }
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

    // Su iPhone la sidebar è la radice e ogni destinazione si impila
    // sopra con il back di sistema. Le viste ambiente restano le stesse
    // dell'iPad: cambiano solo i binding, che oltre a selezionare
    // spingono la destinazione sullo stack.
    private var compactStack: some View {
        NavigationStack(path: $compactPath) {
            SidebarView(
                environment: compactEnvironmentBinding,
                selectedNote: $selectedNote,
                selectedFolder: compactFolderBinding,
                selectedStudy: $selectedStudy,
                selectedStudyModule: $selectedStudyModule,
                showingStudioProgress: $showingStudioProgress,
                onCreateStudy: {
                    selectedStudy = nil
                    selectedStudyModule = nil
                    showingStudioProgress = false
                    showingStudioCreate = true
                    pushIfNeeded(.environment(.studio))
                },
                onOpenProfile: { showingProfile = true }
            )
            // La sidebar ha già la sua intestazione "BoostNote": la barra
            // di navigazione vuota sopra sarebbe solo spazio perso.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: CompactDestination.self) { destination in
                compactDetail(for: destination)
            }
        }
        // Tornati alla sidebar, la selezione evidenziata non deve
        // sopravvivere alla schermata da cui si è usciti.
        .onChange(of: compactPath) { _, newValue in
            if newValue.isEmpty {
                selectedFolder = nil
                selectedStudy = nil
                selectedStudyModule = nil
            }
        }
    }

    @ViewBuilder
    private func compactDetail(for destination: CompactDestination) -> some View {
        switch destination {
        case .environment(.home):
            HomeView(
                selectedNote: $selectedNote,
                onOpenStudyModule: { study, module in
                    selectedStudy = study
                    selectedStudyModule = module
                    environment = .studio
                    pushIfNeeded(.environment(.studio))
                },
                onOpenProgress: {
                    selectedStudy = nil
                    selectedStudyModule = nil
                    showingStudioProgress = true
                    environment = .studio
                    pushIfNeeded(.environment(.studio))
                }
            )
        case .environment(.studio):
            StudioEnvironmentView(
                selectedStudy: $selectedStudy,
                selectedModule: $selectedStudyModule,
                showingProgress: $showingStudioProgress,
                showingCreate: $showingStudioCreate
            )
        case .environment(.ricerca):
            ResearchEnvironmentView(selectedNote: $selectedNote, embedsNavigationStack: false)
        case .environment(.webeep):
            WebeepEnvironmentView(selectedNote: $selectedNote)
        case .folder(let folder):
            FolderContentsView(folder: folder, selectedNote: $selectedNote, selectedFolder: compactFolderBinding)
                .id(folder.persistentModelID)
        }
    }

    // Selezionare un ambiente dalla sidebar su iPhone = spingerlo sullo
    // stack. Il binding "vero" resta la fonte di verità condivisa con
    // l'iPad, così ruotando lo schermo lo stato non si perde.
    private var compactEnvironmentBinding: Binding<AppEnvironment> {
        Binding(
            get: { environment },
            set: { newValue in
                environment = newValue
                pushIfNeeded(.environment(newValue))
            }
        )
    }

    private var compactFolderBinding: Binding<Folder?> {
        Binding(
            get: { selectedFolder },
            set: { newValue in
                selectedFolder = newValue
                if let folder = newValue {
                    pushIfNeeded(.folder(folder))
                }
            }
        )
    }

    private func pushIfNeeded(_ destination: CompactDestination) {
        guard compactPath.last != destination else { return }
        compactPath.append(destination)
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
