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
            if let container = try? ModelContainer(for: schema, configurations: [local]) {
                return container
            }
            // Nemmeno lo store locale si apre (migrazione fallita, store
            // corrotto): l'ultima spiaggia è un container in memoria.
            // I dati su disco restano INTATTI per un aggiornamento che
            // sappia leggerli; il try! che stava qui crashava al lancio
            // in loop proprio nello scenario in cui serviva il fallback.
            print("Store locale non apribile: sessione in memoria, i dati su disco non vengono toccati")
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: [memory])
            } catch {
                // Un container in-memory che non si crea non dipende dai
                // dati: qui non c'è più niente di sensato da tentare.
                fatalError("Impossibile creare anche il container in memoria: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                // ACCENTO UNICO PER TUTTI I CONTROLLI DI SISTEMA.
                // Interruttori, cursori, indicatori di caricamento, spunte
                // dei menu e campi di testo prendono il colore dell'app
                // invece del verde e del blu di iOS: sono l'unica parte
                // dell'interfaccia che non passa dai nostri componenti, e
                // senza questo restavano di un'altra tinta.
                .tint(DesignColor.brandPrimary)
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
