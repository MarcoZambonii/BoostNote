import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// L'assicurazione sulla vita delle note: uno specchio automatico su una
// cartella scelta dall'utente (pensata per OneDrive — ogni studente
// Polimi ha 1TB gratuito — ma funziona con qualunque provider dell'app
// File). Decisioni prese con l'utente (2026-08-16):
// - il DATABASE resta locale e resta la verità: SQLite dentro una
//   cartella sincronizzata si corrompe, quindi lì vanno solo COPIE;
// - un file .boostnote per nota (binary plist Codable con l'inchiostro
//   VERO dentro): reimportandolo la nota torna modificabile identica;
// - si scrive SOLO alla chiusura della nota, in background, su dati già
//   salvati: la scrittura a penna non viene mai toccata;
// - archivio NON distruttivo: eliminare una nota nell'app non tocca il
//   file su OneDrive. È un archivio, non uno specchio con la gomma.
enum NoteArchiveService {

    private static let bookmarkKey = "archive.folderBookmark"

    // Il tipo dichiarato in Info.plist: dà ai pacchetti l'icona
    // BoostNote in Files/Finder e permette di aprirli con un tocco.
    static let packageType = UTType(exportedAs: "BN.BoostNote.package")

    // Dentro la cartella scelta si lavora SEMPRE in una sottocartella
    // "BoostNote": l'utente può puntare alla radice di OneDrive senza
    // ritrovarsela piena di file sparsi, e il gruppo si riconosce a
    // colpo d'occhio anche se la cartella non può avere un'icona sua
    // (su iPadOS non esistono icone di cartella personalizzate).
    private static let archiveFolderName = "BoostNote"

    // MARK: - Configurazione cartella

    static var isConfigured: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    static var folderDisplayName: String? {
        guard let url = resolveFolder() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return "\(url.lastPathComponent)/\(archiveFolderName)"
    }

    static func setFolder(_ url: URL) -> Bool {
        // Il bookmark security-scoped è ciò che permette di riaprire la
        // cartella nelle sessioni future senza richiedere il picker.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        return true
    }

    static func removeFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    // Restituisce l'URL con l'accesso GIÀ APERTO: il chiamante deve
    // chiamare stopAccessingSecurityScopedResource quando ha finito.
    private static func resolveFolder() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if stale, let refreshed = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
        }
        return url
    }

    // La sottocartella dove finiscono i pacchetti, creata se manca.
    // L'accesso security-scoped resta quello della cartella scelta: la
    // sottocartella ne eredita i permessi.
    private static func archiveDirectory(in root: URL) -> URL {
        let directory = root.appendingPathComponent(archiveFolderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    // MARK: - Formato del pacchetto

    // Tutto ciò che serve a far RINASCERE la nota, identica e
    // modificabile. Binary plist e non JSON: l'inchiostro è Data binaria
    // e in JSON pagherebbe +33% di base64.
    //
    // formatVersion 2 (2026-08-22): aggiunti pageSizeRaw, sidePanelTools
    // e lastViewedPage — la v1 li perdeva e una nota A3 ripristinata
    // tornava A4 in silenzio, con media e caselle fuori posto. I campi
    // nuovi sono OPZIONALI così i pacchetti v1 continuano a decodificarsi
    // (stessa trappola Codable documentata su StudyExercise).
    struct NotePackage: Codable {
        var formatVersion = 2
        var id: UUID
        var title: String
        var content: String
        var createdAt: Date
        var updatedAt: Date
        var templateRaw: String
        var patternScale: Double
        var folderName: String?
        var textBoxesData: Data?
        var todoItemsData: Data?
        var pages: [Page]
        var media: [Media]
        var pageSizeRaw: String?
        var sidePanelToolsRaw: String?
        var lastViewedPage: Int?

        struct Page: Codable {
            var order: Int
            var drawingData: Data?
            var pdfPageData: Data?
        }

        struct Media: Codable {
            var x: Double
            var y: Double
            var width: Double
            var height: Double
            var kindRaw: String
            var data: Data
            var sourceText: String?
        }
    }

    @MainActor
    static func package(for note: Note) -> NotePackage {
        NotePackage(
            id: note.id,
            title: note.title,
            content: note.content,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            templateRaw: note.templateRaw,
            patternScale: note.patternScale,
            folderName: note.folder?.name,
            textBoxesData: note.textBoxesData,
            todoItemsData: note.todoItemsData,
            pages: note.sortedPages.map { NotePackage.Page(order: $0.order, drawingData: $0.drawingData, pdfPageData: $0.pdfPageData) },
            media: note.media.map { NotePackage.Media(x: $0.x, y: $0.y, width: $0.width, height: $0.height, kindRaw: $0.kindRaw, data: $0.data, sourceText: $0.sourceText) },
            pageSizeRaw: note.pageSizeRaw,
            sidePanelToolsRaw: note.sidePanelToolsRaw,
            lastViewedPage: note.lastViewedPage
        )
    }

    // MARK: - Scrittura (alla chiusura della nota, mai durante)

    // Lo snapshot si fa sul MainActor (i @Model non escono dal main), la
    // scrittura su disco no: la chiusura della nota non aspetta nessuno.
    @MainActor
    static func archive(_ note: Note) {
        guard isConfigured else { return }
        let snapshot = package(for: note)
        Task.detached(priority: .utility) {
            write(snapshot)
        }
    }

    // Il nome del file porta il titolo (per ritrovarlo a occhio su
    // OneDrive) e l'UUID (per l'identità: rinominare la nota non crea un
    // duplicato — il vecchio file con lo stesso UUID viene sostituito).
    private static func write(_ package: NotePackage) {
        guard let root = resolveFolder() else { return }
        defer { root.stopAccessingSecurityScopedResource() }
        let folder = archiveDirectory(in: root)

        let safeTitle = package.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortID = package.id.uuidString.prefix(8)
        let fileName = "\(safeTitle.isEmpty ? "Nota" : safeTitle) [\(shortID)].boostnote"

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(package) else { return }

        do {
            // Se il titolo è cambiato, il file col vecchio nome ma lo
            // stesso UUID va sostituito, non affiancato.
            let existing = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for old in existing where old.lastPathComponent.contains("[\(shortID)].boostnote") && old.lastPathComponent != fileName {
                try? FileManager.default.removeItem(at: old)
            }
            try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        } catch {
            // L'archivio è un di più: un errore qui non deve mai
            // disturbare l'uso dell'app. Riproverà alla prossima chiusura.
        }
    }

    // Archivia TUTTE le note: per il primo giro dopo la configurazione.
    // Ritorna quante ne ha messe in coda.
    @MainActor
    @discardableResult
    static func archiveAll(in context: ModelContext) -> Int {
        guard isConfigured else { return 0 }
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let snapshots = notes.map { package(for: $0) }
        Task.detached(priority: .utility) {
            for snapshot in snapshots {
                write(snapshot)
            }
        }
        return snapshots.count
    }

    // MARK: - Ripristino

    enum RestoreError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Il file non è un pacchetto BoostNote valido." }
    }

    // Ricrea la nota dal pacchetto. Se una nota con lo stesso id esiste
    // già, il ripristino ne crea una COPIA separata (titolo "… —
    // ripristinata"): mai sovrascrivere silenziosamente il presente con
    // il passato.
    @MainActor
    @discardableResult
    static func restore(from url: URL, in context: ModelContext) throws -> Note {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let package = try? PropertyListDecoder().decode(NotePackage.self, from: data) else {
            throw RestoreError.unreadable
        }

        let existingIDs = Set(((try? context.fetch(FetchDescriptor<Note>())) ?? []).map(\.id))
        let isDuplicate = existingIDs.contains(package.id)

        let note = Note(
            title: isDuplicate ? "\(package.title) — ripristinata" : package.title,
            folder: matchFolder(named: package.folderName, in: context)
        )
        if !isDuplicate { note.id = package.id }
        note.content = package.content
        note.createdAt = package.createdAt
        note.updatedAt = package.updatedAt
        note.templateRaw = package.templateRaw
        note.patternScale = package.patternScale
        note.textBoxesData = package.textBoxesData
        note.todoItemsData = package.todoItemsData
        // Campi arrivati con la v2: sui pacchetti v1 mancano e restano i
        // default della nota (A4, pannello vuoto, prima pagina).
        if let pageSizeRaw = package.pageSizeRaw { note.pageSizeRaw = pageSizeRaw }
        if let sidePanelToolsRaw = package.sidePanelToolsRaw { note.sidePanelToolsRaw = sidePanelToolsRaw }
        if let lastViewedPage = package.lastViewedPage { note.lastViewedPage = lastViewedPage }
        context.insert(note)

        // Aggancio dal lato GENITORE (pages.append / media.append), mai
        // solo impostando il lato figlio: vedi la nota su Note.attach —
        // la mutazione fatta solo sul figlio può non notificare
        // l'osservazione del genitore e la nota ripristinata appariva
        // senza contenuti finché qualcosa non forzava un refresh.
        for page in package.pages {
            let restored = NotePage(order: page.order, drawingData: page.drawingData, pdfPageData: page.pdfPageData)
            context.insert(restored)
            note.pages.append(restored)
        }
        for media in package.media {
            let restored = NoteMedia(x: media.x, y: media.y, width: media.width, height: media.height, kind: NoteMediaKind(rawValue: media.kindRaw) ?? .image, data: media.data, sourceText: media.sourceText)
            context.insert(restored)
            note.media.append(restored)
        }
        return note
    }

    @MainActor
    private static func matchFolder(named name: String?, in context: ModelContext) -> Folder? {
        guard let name, !name.isEmpty else { return nil }
        let folders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        return folders.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
}
