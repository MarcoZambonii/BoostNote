import SwiftUI
import SwiftData

@main
struct StudioApp: App {
    // Container con sync iCloud: i dati passano dal CloudKit PRIVATO
    // dell'utente (container "iCloud.BN.BoostNote", vedi entitlements) —
    // iPad e iPhone con lo stesso Apple ID vedono le stesse note, zero
    // backend nostro. Se il container CloudKit non si può creare (niente
    // login iCloud, firma senza entitlement) si ripiega sul database
    // locale di sempre: l'app non deve MAI rifiutarsi di aprire per un
    // problema di sync.
    private static let schema = Schema([
        Folder.self, Note.self, NoteMedia.self, NoteWidget.self,
        StudyFolder.self, Study.self, StudyMaterial.self, StudyModule.self,
        ExerciseAttempt.self,
        VaultDocument.self, VaultPage.self, VaultChunk.self
    ])

    private let container: ModelContainer = {
        do {
            let cloud = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            return try ModelContainer(for: schema, configurations: [cloud])
        } catch {
            print("CloudKit non disponibile (\(error)), si continua in locale")
            let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            // Il database locale è lo stesso store di sempre: se nemmeno
            // questo si apre, l'app non ha niente da mostrare comunque.
            return try! ModelContainer(for: schema, configurations: [local])
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                // Un .boostnote aperto da Files (o da OneDrive) apre
                // BoostNote e ripristina la nota: il pacchetto è un
                // documento NOSTRO, dichiarato in Info.plist con la sua
                // icona, quindi si comporta come tale.
                .onOpenURL { url in
                    guard url.pathExtension == "boostnote" else { return }
                    ArchiveOpenRequest.shared.url = url
                }
        }
        .modelContainer(container)
    }
}

// Il pacchetto da ripristinare arriva PRIMA che una vista con il
// ModelContext sia pronta a gestirlo: si parcheggia qui e RootView lo
// consuma quando può.
@MainActor
@Observable
final class ArchiveOpenRequest {
    static let shared = ArchiveOpenRequest()
    var url: URL?
}
