import SwiftUI
import SwiftData

@main
struct StudioApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        // .modelContainer registra Folder e Note e attiva il sync
        // automatico via CloudKit (serve solo abilitare la capability
        // "iCloud > CloudKit" nelle impostazioni del target in Xcode).
        .modelContainer(for: [Folder.self, Note.self, NoteMedia.self, NoteWidget.self, StudyFolder.self, Study.self, StudyMaterial.self, StudyModule.self, ExerciseAttempt.self])
    }
}
