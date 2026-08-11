import SwiftUI
import SwiftData

struct RootView: View {
    @State private var selectedNote: Note?
    @State private var selectedFolder: Folder?
    @State private var environment: AppEnvironment = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingProfile = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                environment: $environment,
                selectedNote: $selectedNote,
                selectedFolder: $selectedFolder,
                onOpenProfile: { showingProfile = true }
            )
        } detail: {
            detail
        }
        // Nessuna schermata usa il pulsante di sistema per aprire/chiudere
        // la sidebar: la navigazione passa dai controlli propri dell'app
        // (righe della sidebar, pulsante indietro nella nota, ecc.).
        .toolbar(removing: .sidebarToggle)
        .sheet(isPresented: $showingProfile) {
            NavigationStack {
                ProfileView()
            }
        }
        .onChange(of: selectedNote) { _, newValue in
            // Non tocca selectedFolder: chiudendo la nota si torna alla
            // cartella da cui si era partiti, non sempre alla Home.
            if newValue != nil {
                environment = .home
                // La sidebar non può stare aperta insieme alla nota: si
                // nasconde del tutto (non solo "si può riaprire"), così
                // l'unico modo per uscire è il pulsante indietro della nota.
                columnVisibility = .detailOnly
            } else {
                columnVisibility = .all
            }
        }
        .onChange(of: selectedFolder) { _, newValue in
            if newValue != nil { environment = .home; selectedNote = nil }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch environment {
        case .home:
            if let selectedNote {
                NoteEditorView(note: selectedNote, onBack: { self.selectedNote = nil })
                    .id(selectedNote.persistentModelID)
            } else if let selectedFolder {
                FolderContentsView(folder: selectedFolder, selectedNote: $selectedNote, selectedFolder: $selectedFolder)
                    .id(selectedFolder.persistentModelID)
            } else {
                HomeView(selectedNote: $selectedNote)
            }
        case .studio:
            ComingSoonScreen(
                title: "Studio",
                subtitle: "Flashcard generate automaticamente dalle tue note — in arrivo.",
                systemImage: "rectangle.on.rectangle"
            )
        case .ricerca:
            ResearchEnvironmentView(selectedNote: $selectedNote)
        case .webeep:
            WebeepEnvironmentView(selectedNote: $selectedNote)
        }
    }
}
