import CryptoKit
import Foundation
import SwiftData

// L'indice del Vault: spezza ogni documento in chunk (~25k caratteri su
// confini di pagina) e li etichetta con una chiamata Lite l'uno —
// argomenti coperti e natura (teoria / esercizi). È la memoria compatta
// del corso: l'indice intero sta sempre in un prompt, e sarà lui a
// decidere QUALI chunk mandare al modello quando si genera (passo 3),
// al posto del troncamento cieco ai primi 100k caratteri.
//
// Costi, per onestà: un documento da 167 pagine ≈ 16-20 chunk = 16-20
// chiamate Lite UNA VOLTA; le etichette si riusano per contenuto (stesso
// meccanismo delle pagine), quindi modificare una pagina rietichetta il
// suo chunk, non il documento.
enum VaultIndexService {

    // Budget per chunk. ~25k caratteri ≈ 6k token: abbastanza piccolo da
    // etichettare bene, abbastanza grande da non polverizzare l'indice.
    private static let chunkBudget = 25000

    // MARK: - Ricostruzione dei chunk

    // Riallinea i chunk di un documento alle pagine lette: impacchetta
    // per pagine consecutive, riusa le etichette dei chunk con la stessa
    // impronta, restituisce i chunk da etichettare.
    @MainActor
    static func rebuildChunks(for document: VaultDocument, in context: ModelContext) -> [VaultChunk] {
        let readPages = document.sortedPages.filter { $0.status == .read && !$0.text.isEmpty }
        guard !readPages.isEmpty else { return [] }

        // Impacchettamento greedy su confini di pagina.
        struct Packed {
            var pageStart: Int
            var pageEnd: Int
            var fingerprintSource: String
            var characters: Int
        }
        var packed: [Packed] = []
        var current: Packed?
        for page in readPages {
            let pageSize = page.text.count
            if var open = current, open.characters + pageSize <= chunkBudget {
                open.pageEnd = page.index
                open.fingerprintSource += page.contentHash
                open.characters += pageSize
                current = open
            } else {
                if let open = current { packed.append(open) }
                current = Packed(pageStart: page.index, pageEnd: page.index, fingerprintSource: page.contentHash, characters: pageSize)
            }
        }
        if let open = current { packed.append(open) }

        // Riuso per contenuto: un chunk esistente con la stessa impronta
        // conserva etichetta e data, ovunque si trovi ora.
        var existingByFingerprint = Dictionary(grouping: document.chunks, by: \.fingerprint)
        var toIndex: [VaultChunk] = []
        for pack in packed {
            let fingerprint = sha(pack.fingerprintSource)
            if var matches = existingByFingerprint[fingerprint], let chunk = matches.popLast() {
                existingByFingerprint[fingerprint] = matches
                chunk.pageStart = pack.pageStart
                chunk.pageEnd = pack.pageEnd
                chunk.characterCount = pack.characters
                if !chunk.isIndexed { toIndex.append(chunk) }
            } else {
                // Aggancio dal lato genitore (vedi VaultIngestionService).
                let chunk = VaultChunk(pageStart: pack.pageStart, pageEnd: pack.pageEnd, fingerprint: fingerprint, characterCount: pack.characters, document: nil)
                context.insert(chunk)
                document.chunks.append(chunk)
                toIndex.append(chunk)
            }
        }
        for stale in existingByFingerprint.values.flatMap({ $0 }) {
            context.delete(stale)
        }
        return toIndex
    }

    // MARK: - Etichettatura

    private static let indexSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "topics": ["type": "ARRAY", "items": ["type": "STRING"]],
            "nature": ["type": "STRING"]
        ],
        "required": ["topics", "nature"]
    ]

    private struct IndexDTO: Decodable {
        var topics: [String]
        var nature: String?
    }

    // Etichetta un chunk: una chiamata Lite, thinking a zero (è un
    // compito di classificazione, non di ragionamento).
    //
    // `knownTopics` sono le etichette già in uso in QUESTO Vault. Non
    // costa nessuna chiamata in più — i chunk si indicizzano già in
    // sequenza — ed è il rimedio alla radice della frammentazione: senza,
    // ogni chunk battezza lo stesso argomento con parole sue e l'elenco
    // si riempie di quasi-duplicati che poi vanno riconciliati a valle.
    @MainActor
    static func indexChunk(_ chunk: VaultChunk, knownTopics: [String] = []) async -> Bool {
        let text = chunk.text
        guard !text.isEmpty else { return false }
        // Tetto sull'elenco: il vocabolario di un corso sta in poche
        // decine di voci, e un prompt che cresce senza limite si mangia
        // il contesto che serve all'estratto.
        let known = Array(knownTopics.prefix(60))
        let reuse = known.isEmpty ? "" : """

        ETICHETTE GIÀ IN USO IN QUESTO CORSO — se un argomento dell'estratto è uno di questi, COPIA l'etichetta ALLA LETTERA, identica carattere per carattere. Creane una nuova SOLO se l'argomento non è in elenco.
        \(known.map { "- \($0)" }.joined(separator: "\n"))
        """
        let prompt = """
        Analizza questo estratto di materiale universitario e restituisci SOLO JSON.
        - "topics": gli argomenti trattati (da 1 a 6), ognuno in 2-5 parole, specifici ("dualità in programmazione lineare", non "matematica"). In italiano.
        - "nature": "theory" se l'estratto è teoria/definizioni/dimostrazioni, "exercises" se è fatto di esercizi o temi d'esame (tracce, soluzioni), "mixed" se contiene entrambi in misura simile.
        \(reuse)

        ESTRATTO:
        \(String(text.prefix(25000)))
        """
        guard case .success(let reply) = await AIService.generate(prompt: prompt, purpose: .reading, tier: .lite, schema: indexSchema),
              let json = AIService.extractJSON(from: reply.text),
              let dto = try? JSONDecoder().decode(IndexDTO.self, from: Data(json.utf8)),
              !dto.topics.isEmpty else {
            return false
        }
        // Il chunk può essere stato eliminato (documento tolto dal Vault)
        // mentre la chiamata era in volo: niente scritture su un morto.
        guard !chunk.isDeleted else { return false }
        // Il prompt è una preghiera, questa è la garanzia: ciò che il
        // modello scrive viene comunque riportato all'etichetta esistente
        // quando è una variante della stessa (accenti, plurali, sigle).
        let vocabulary = TopicVocabulary(known)
        chunk.topics = dto.topics
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { vocabulary.canonical(for: $0) ?? $0 }
        chunk.natureRaw = ["theory", "exercises", "mixed"].contains(dto.nature ?? "") ? (dto.nature ?? "") : "mixed"
        chunk.indexedAt = .now
        return true
    }

    // Indicizza tutto ciò che manca in un documento. Ritorna quanti
    // chunk sono stati etichettati (0 se era già tutto fresco).
    @MainActor
    @discardableResult
    static func indexDocument(_ document: VaultDocument, in context: ModelContext) async -> Int {
        let toIndex = rebuildChunks(for: document, in: context)
        // Vocabolario di partenza: tutto ciò che il Vault (la cartella,
        // non il singolo documento) ha già etichettato. Cresce mano a
        // mano, così i chunk successivi riusano ciò che hanno scelto i
        // precedenti.
        var known: [String] = []
        var seen: Set<String> = []
        let siblings = document.folder?.vaultDocuments ?? [document]
        for sibling in siblings {
            for chunk in sibling.sortedChunks where chunk.isIndexed {
                for topic in chunk.topics where seen.insert(TopicKey.key(topic)).inserted {
                    known.append(topic)
                }
            }
        }

        var indexed = 0
        for chunk in toIndex {
            guard !document.isDeleted else { return indexed }
            if await indexChunk(chunk, knownTopics: known) {
                indexed += 1
                for topic in chunk.topics where seen.insert(TopicKey.key(topic)).inserted {
                    known.append(topic)
                }
            }
            try? context.save()
        }
        return indexed
    }

    private static func sha(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
