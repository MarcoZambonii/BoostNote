import CryptoKit
import Foundation
import PDFKit
import SwiftData

// Stato osservabile della coda: la UI mostra "sta leggendo" da qui,
// mentre i conteggi per documento (lette/da leggere/fallite) escono
// direttamente dai modelli via @Query.
@MainActor
@Observable
final class VaultActivity {
    static let shared = VaultActivity()
    var ingestingFolders: Set<UUID> = []
}

// La coda di lettura del vault. Tre proprietà che sono il contratto
// concordato con l'utente (2026-08-15):
// - RIPARTIBILE: ogni pagina letta viene persistita subito con il suo
//   hash; un crash o una chiusura perdono al massimo le pagine in volo.
// - INCREMENTALE: le note sono riferimenti vivi — al sync si confrontano
//   gli hash per pagina e si rileggono solo le pagine nuove o cambiate
//   (le pagine si riconoscono per CONTENUTO, non per posizione: inserire
//   una pagina in mezzo costa una lettura, non quaranta).
// - PARTE SUBITO: appena si aggiunge materiale, mentre l'app è aperta.
@MainActor
enum VaultIngestionService {

    private static var runningFolders: Set<UUID> = []

    // MARK: - Aggiunta documenti

    @discardableResult
    static func addNote(_ note: Note, to folder: StudyFolder, in context: ModelContext) -> VaultDocument {
        let document = VaultDocument(title: note.title, kind: .note, folder: folder, noteID: note.id)
        context.insert(document)
        startIngestion(for: folder, in: context)
        return document
    }

    @discardableResult
    static func addPDF(title: String, data: Data, to folder: StudyFolder, in context: ModelContext) -> VaultDocument {
        let document = VaultDocument(title: title, kind: .pdf, folder: folder, pdfData: data)
        context.insert(document)
        startIngestion(for: folder, in: context)
        return document
    }

    // MARK: - Avvio e risincronizzazione

    static func isIngesting(_ folderID: UUID) -> Bool {
        runningFolders.contains(folderID)
    }

    static func startIngestion(for folder: StudyFolder, in context: ModelContext) {
        guard !runningFolders.contains(folder.id) else { return }
        let folderID = folder.id
        runningFolders.insert(folderID)
        VaultActivity.shared.ingestingFolders.insert(folderID)
        Task { @MainActor in
            await ingest(folder: folder, in: context)
            runningFolders.remove(folderID)
            VaultActivity.shared.ingestingFolders.remove(folderID)
        }
    }

    // Risincronizzazione "al momento dell'uso": chi sta per consumare il
    // vault (generazione, indice, chat) chiama questa e aspetta. Fa il
    // diff degli hash e legge solo il necessario: su un vault già fresco
    // costa una passata di hash e nessuna chiamata.
    static func ensureFresh(for folder: StudyFolder, in context: ModelContext) async {
        while runningFolders.contains(folder.id) {
            // Un giro è già in corso: si aspetta che finisca, il
            // risultato è lo stesso.
            try? await Task.sleep(for: .milliseconds(300))
        }
        let folderID = folder.id
        runningFolders.insert(folderID)
        VaultActivity.shared.ingestingFolders.insert(folderID)
        await ingest(folder: folder, in: context)
        runningFolders.remove(folderID)
        VaultActivity.shared.ingestingFolders.remove(folderID)
    }

    // MARK: - Il giro di ingestione

    private static func ingest(folder: StudyFolder, in context: ModelContext) async {
        for document in folder.vaultDocuments {
            let work = syncPages(of: document, in: context)
            guard !work.isEmpty else {
                // Niente pagine da leggere, ma l'indice può essere
                // indietro (chunk mai etichettati, o etichettatura
                // fallita per quota): si recupera qui.
                await VaultIndexService.indexDocument(document, in: context)
                continue
            }
            let results = await processPages(work)
            // Scrittura pagina per pagina sul MainActor: è QUI che la
            // coda diventa ripartibile — ogni pagina salvata è acquisita.
            let pagesByID = Dictionary(uniqueKeysWithValues: document.pages.map { ($0.id, $0) })
            for (pageID, result) in results {
                guard let page = pagesByID[pageID] else { continue }
                switch result {
                case .success(let text, let via):
                    page.text = text
                    page.readVia = via
                    page.status = .read
                    page.errorMessage = nil
                    page.readAt = .now
                case .empty:
                    // Pagina senza testo riconoscibile: è un esito, non
                    // un errore — non va ritentata a ogni giro.
                    page.text = ""
                    page.readVia = .none
                    page.status = .read
                    page.readAt = .now
                case .failure(let message):
                    page.status = .failed
                    page.errorMessage = message
                }
            }
            document.lastIngestedAt = .now
            try? context.save()
            // Indice subito dopo le pagine: i chunk nuovi o cambiati
            // vengono etichettati, quelli intatti riusano l'etichetta.
            await VaultIndexService.indexDocument(document, in: context)
        }
    }

    // MARK: - Sync: snapshot + diff degli hash

    // Confronta lo stato attuale del documento con le pagine già in
    // archivio e restituisce il lavoro da fare. Le pagine si appaiano
    // per hash del contenuto: ciò che non è cambiato non si tocca.
    private static func syncPages(of document: VaultDocument, in context: ModelContext) -> [PageWork] {
        switch document.kind {
        case .note:
            return syncNotePages(of: document, in: context)
        case .pdf:
            return syncPDFPages(of: document, in: context)
        }
    }

    private static func syncNotePages(of document: VaultDocument, in context: ModelContext) -> [PageWork] {
        guard let noteID = document.noteID else { return [] }
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })
        guard let note = try? context.fetch(descriptor).first else {
            // La nota non esiste più: il documento resta con le pagine
            // già lette (il testo è comunque valido come archivio), ma
            // non c'è niente di nuovo da leggere.
            return []
        }
        document.title = note.title

        // Snapshot dei contenuti pagina (stesse fonti dell'estrattore).
        let snapshots: [(drawing: Data?, pdf: Data?)]
        if note.isWhiteboard || note.pages.isEmpty {
            snapshots = [(note.drawingData, nil)]
        } else {
            snapshots = note.sortedPages.map { ($0.drawingData, $0.pdfPageData) }
        }
        let contentPages = snapshots.filter { $0.drawing != nil || $0.pdf != nil }

        // Appaiamento per hash (multiset: due pagine identiche sono due
        // pagine). Le rimanenze da una parte sono pagine cambiate o
        // rimosse (si eliminano), dall'altra pagine nuove (si leggono).
        var existingByHash: [String: [VaultPage]] = Dictionary(grouping: document.pages, by: \.contentHash)
        var work: [PageWork] = []

        for (index, snapshot) in contentPages.enumerated() {
            let hash = contentHash(snapshot.drawing, snapshot.pdf)
            if var matches = existingByHash[hash], let page = matches.popLast() {
                existingByHash[hash] = matches
                page.index = index
                // Già in archivio ma mai letta (crash, quota finita):
                // il contenuto è lo stesso, il lavoro va rifatto.
                if page.status != .read {
                    work.append(PageWork(pageID: page.id, payload: .notePage(drawing: snapshot.drawing, pdf: snapshot.pdf)))
                }
            } else {
                let page = VaultPage(index: index, contentHash: hash, document: document)
                context.insert(page)
                work.append(PageWork(pageID: page.id, payload: .notePage(drawing: snapshot.drawing, pdf: snapshot.pdf)))
            }
        }
        for leftover in existingByHash.values.flatMap({ $0 }) {
            context.delete(leftover)
        }
        return work
    }

    private static func syncPDFPages(of document: VaultDocument, in context: ModelContext) -> [PageWork] {
        guard let data = document.pdfData, let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { return [] }
        let documentHash = contentHash(data)

        // PDF invariato: resta solo il lavoro non finito (ripresa).
        if document.pdfHash == documentHash && !document.pages.isEmpty {
            return document.pages
                .filter { $0.status != .read }
                .map { PageWork(pageID: $0.id, payload: .pdfPage(container: PDFContainer(document: pdf), index: $0.index)) }
        }

        // PDF nuovo o sostituito: si riparte da zero.
        for page in document.pages { context.delete(page) }
        document.pdfHash = documentHash
        var work: [PageWork] = []
        for index in 0..<pdf.pageCount {
            let page = VaultPage(index: index, contentHash: "\(documentHash)#\(index)", document: document)
            context.insert(page)
            work.append(PageWork(pageID: page.id, payload: .pdfPage(container: PDFContainer(document: pdf), index: index)))
        }
        return work
    }

    private static func contentHash(_ datas: Data?...) -> String {
        var hasher = SHA256()
        for data in datas {
            if let data {
                hasher.update(data: data)
            }
            // Separatore: distingue (A, nil) da (nil, A).
            hasher.update(data: Data([0x1F]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Lettura vera e propria (fuori dal MainActor, 4 in parallelo)

    private struct PageWork: Sendable {
        let pageID: UUID
        let payload: Payload

        enum Payload: Sendable {
            case notePage(drawing: Data?, pdf: Data?)
            case pdfPage(container: PDFContainer, index: Int)
        }
    }

    // PDFDocument non è Sendable ma la lettura concorrente delle pagine
    // è il pattern già in produzione in StudyMaterialExtractor: il
    // wrapper serve solo a farlo viaggiare nei task del gruppo.
    struct PDFContainer: @unchecked Sendable {
        let document: PDFDocument
    }

    private enum PageResult: Sendable {
        case success(String, via: VaultPageReader)
        case empty
        case failure(String)
    }

    private nonisolated static func processPages(_ work: [PageWork]) async -> [UUID: PageResult] {
        await withTaskGroup(of: (UUID, PageResult).self) { group -> [UUID: PageResult] in
            var results: [UUID: PageResult] = [:]
            var next = 0
            let maxConcurrent = 4

            func addTask(_ item: PageWork) {
                group.addTask {
                    (item.pageID, await readPage(item.payload))
                }
            }

            while next < work.count && next < maxConcurrent {
                addTask(work[next]); next += 1
            }
            while let (pageID, result) = await group.next() {
                results[pageID] = result
                if next < work.count { addTask(work[next]); next += 1 }
            }
            return results
        }
    }

    private nonisolated static func readPage(_ payload: PageWork.Payload) async -> PageResult {
        switch payload {
        case .notePage(let drawing, let pdf):
            var chunk: [String] = []
            var via: VaultPageReader = .none
            if drawing != nil {
                if let handwriting = await StudyMaterialExtractor.recognizeHandwriting(in: drawing) {
                    chunk.append(handwriting)
                    // Con provider configurato la mano passa dal modello;
                    // senza, da Vision. Lo stesso criterio dell'estrattore.
                    via = AIService.selectedProvider != .appleLocal && AIService.isConfigured ? .model : .vision
                }
            }
            if let pdf, let text = await StudyMaterialExtractor.extractText(fromPDF: pdf) {
                chunk.append(text)
                if via == .none { via = .textLayer }
            }
            let text = chunk.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .empty : .success(text, via: via)

        case .pdfPage(let container, let index):
            guard let page = container.document.page(at: index) else {
                return .failure("Pagina \(index + 1) non leggibile dal PDF.")
            }
            let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if embedded.count >= 24 {
                return .success(embedded, via: .textLayer)
            }
            guard let image = StudyMaterialExtractor.render(page: page) else {
                return .failure("Pagina \(index + 1): rendering non riuscito.")
            }
            if let text = await StudyMaterialExtractor.recognizePDFPage(in: image) {
                let via: VaultPageReader = AIService.selectedProvider != .appleLocal && AIService.isConfigured ? .model : .vision
                return .success(text, via: via)
            }
            return embedded.isEmpty ? .empty : .success(embedded, via: .textLayer)
        }
    }
}
