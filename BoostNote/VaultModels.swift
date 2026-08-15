import Foundation
import SwiftData

// Il vault di corso: il materiale di una cartella Studio, letto UNA volta
// e persistito pagina per pagina. Decisioni prese con l'utente (2026-08-15):
// - il contenitore è la cartella Studio (una cartella = un corso);
// - una nota nel vault è un RIFERIMENTO VIVO (noteID), mai una copia:
//   la risincronizzazione avviene al momento dell'uso, confrontando gli
//   hash per pagina e rileggendo solo ciò che è cambiato;
// - la coda di lettura parte subito e riprende da dove era: ogni pagina
//   letta è salvata, chiudere l'app non butta lavoro.

enum VaultDocumentKind: String, Codable {
    case note      // riferimento vivo a una nota dell'app
    case pdf       // PDF caricato: statico, l'hash è quello del file
}

enum VaultPageStatus: String, Codable {
    case pending   // da leggere (nuova o cambiata)
    case read
    case failed
}

// Con che cosa è stata letta la pagina: serve per l'onestà in UI e per
// decidere se rileggere quando arriva un lettore migliore.
enum VaultPageReader: String, Codable {
    case textLayer  // livello di testo del PDF, gratis e fedele
    case vision     // OCR Apple on-device
    case model      // modello vision (scrittura a mano)
    case none
}

@Model
final class VaultDocument {
    var id: UUID = UUID()
    var title: String = ""
    var kindRaw: String = VaultDocumentKind.pdf.rawValue
    var isExamPaper: Bool = false
    var addedAt: Date = Date.now
    var lastIngestedAt: Date?

    // Riferimento vivo per kind == .note.
    var noteID: UUID?
    // Contenuto per kind == .pdf.
    @Attribute(.externalStorage) var pdfData: Data?
    // Hash dell'intero PDF: se cambia (file ricaricato) si rileggono
    // tutte le pagine; per le note l'hash vive sulla singola pagina.
    var pdfHash: String?

    var folder: StudyFolder?

    @Relationship(deleteRule: .cascade, inverse: \VaultPage.document)
    var pages: [VaultPage] = []

    @Relationship(deleteRule: .cascade, inverse: \VaultChunk.document)
    var chunks: [VaultChunk] = []

    init(title: String, kind: VaultDocumentKind, folder: StudyFolder?, noteID: UUID? = nil, pdfData: Data? = nil) {
        self.id = UUID()
        self.title = title
        self.kindRaw = kind.rawValue
        self.addedAt = .now
        self.folder = folder
        self.noteID = noteID
        self.pdfData = pdfData
    }

    var kind: VaultDocumentKind { VaultDocumentKind(rawValue: kindRaw) ?? .pdf }

    var sortedPages: [VaultPage] { pages.sorted { $0.index < $1.index } }

    var readCount: Int { pages.filter { $0.status == .read }.count }
    var pendingCount: Int { pages.filter { $0.status == .pending }.count }
    var failedCount: Int { pages.filter { $0.status == .failed }.count }

    // Testo completo del documento nell'ordine delle pagine: è ciò che
    // consumeranno indice e generazione.
    var fullText: String {
        sortedPages
            .filter { $0.status == .read && !$0.text.isEmpty }
            .map(\.text)
            .joined(separator: "\n\n")
    }

    var sortedChunks: [VaultChunk] { chunks.sorted { $0.pageStart < $1.pageStart } }

    // Tutti gli argomenti del documento, dall'indice (vuoto se non
    // ancora indicizzato).
    var allTopics: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for chunk in sortedChunks {
            for topic in chunk.topics where seen.insert(topic.lowercased()).inserted {
                result.append(topic)
            }
        }
        return result
    }
}

// Un blocco di pagine consecutive (~25k caratteri) con la sua etichetta:
// quali argomenti copre e che natura ha. È l'unità dell'INDICE: piccola
// abbastanza da essere etichettata con una chiamata Lite, grande
// abbastanza da avere senso da sola. Il testo NON è duplicato qui — si
// ricostruisce dalle pagine, il chunk tiene solo il riferimento.
@Model
final class VaultChunk {
    var id: UUID = UUID()
    var pageStart: Int = 0
    var pageEnd: Int = 0
    // Impronta degli hash delle pagine coperte: se cambia, gli argomenti
    // vanno rietichettati. Il riuso è per CONTENUTO, come per le pagine:
    // un chunk identico ritrovato dopo un riordino conserva l'etichetta.
    var fingerprint: String = ""
    var topicsJSON: String = "[]"
    // theory / exercises / mixed — servirà agli esercizi per pescare dai
    // temi d'esame e alla teoria per il resto.
    var natureRaw: String = ""
    var indexedAt: Date?
    var characterCount: Int = 0

    var document: VaultDocument?

    init(pageStart: Int, pageEnd: Int, fingerprint: String, characterCount: Int, document: VaultDocument?) {
        self.id = UUID()
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.fingerprint = fingerprint
        self.characterCount = characterCount
        self.document = document
    }

    var topics: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(topicsJSON.utf8))) ?? [] }
        set { topicsJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }

    var isIndexed: Bool { indexedAt != nil }

    // Il testo del chunk, ricostruito dalle pagine del documento.
    var text: String {
        guard let document else { return "" }
        return document.sortedPages
            .filter { $0.index >= pageStart && $0.index <= pageEnd && $0.status == .read }
            .map(\.text)
            .joined(separator: "\n\n")
    }
}

@Model
final class VaultPage {
    var id: UUID = UUID()
    var index: Int = 0
    // Hash del contenuto sorgente (inchiostro + eventuale PDF di pagina):
    // è il rilevatore di cambiamento per le note vive.
    var contentHash: String = ""
    @Attribute(.externalStorage) var text: String = ""
    var statusRaw: String = VaultPageStatus.pending.rawValue
    var readViaRaw: String = VaultPageReader.none.rawValue
    var errorMessage: String?
    var readAt: Date?

    var document: VaultDocument?

    init(index: Int, contentHash: String, document: VaultDocument?) {
        self.id = UUID()
        self.index = index
        self.contentHash = contentHash
        self.document = document
    }

    var status: VaultPageStatus {
        get { VaultPageStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var readVia: VaultPageReader {
        get { VaultPageReader(rawValue: readViaRaw) ?? .none }
        set { readViaRaw = newValue.rawValue }
    }
}
