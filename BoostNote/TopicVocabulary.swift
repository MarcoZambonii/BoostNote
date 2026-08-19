import Foundation
import NaturalLanguage

// RICONOSCERE CHE DUE ETICHETTE PARLANO DELLO STESSO ARGOMENTO.
//
// L'indice del Vault etichetta ogni chunk per conto suo, quindi lo stesso
// argomento rientra scritto in modi diversi ("Dualità in PL", "dualità in
// programmazione lineare", "problemi di trasporto" / "problema di
// trasporto"). Tutto ciò che raggruppa sulla stringa nuda — la griglia
// degli argomenti in creazione, il filtro dei chunk, le statistiche dei
// progressi — si frantuma di conseguenza.
//
// Qui si fa la parte DETERMINISTICA del lavoro, che è gratis, offline e
// ripetibile: varianti morfologiche e acronimi. La sinonimia vera
// ("dualità in PL" ≡ "problema duale") è conoscenza del dominio e NON si
// risolve manipolando stringhe: se servirà, è una singola chiamata Lite
// sulla LISTA di etichette (non sui documenti), quindi non scala col
// materiale.
enum TopicKey {

    // Parole funzionali italiane: non distinguono un argomento da un
    // altro, quindi non entrano nella chiave. "problema"/"analisi" e
    // simili NON stanno qui: quelle l'argomento lo caratterizzano.
    private static let stopwords: Set<String> = [
        "di", "del", "dello", "della", "dei", "degli", "delle",
        "da", "dal", "dallo", "dalla", "dai", "dagli", "dalle",
        "in", "nel", "nello", "nella", "nei", "negli", "nelle",
        "a", "al", "allo", "alla", "ai", "agli", "alle",
        "con", "su", "sul", "sullo", "sulla", "sui", "sugli", "sulle",
        "per", "tra", "fra", "e", "ed", "o", "od",
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una",
        "che", "come", "ovvero", "cioe"
    ]

    // Memoria dei token già calcolati: `NLTagger` costa troppo per stare
    // in un percorso chiamato a ogni ridisegno di SwiftUI, e le etichette
    // sono poche e ripetute.
    private static let cacheLock = NSLock()
    private static var cache: [String: [String]] = [:]

    // I token significativi di un'etichetta: minuscoli, lemmatizzati
    // (così "problemi" e "problema" coincidono), senza accenti né
    // punteggiatura, senza parole funzionali. L'ORDINE resta quello
    // originale: serve alle iniziali degli acronimi.
    static func tokens(_ topic: String) -> [String] {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        cacheLock.lock()
        if let cached = cache[trimmed] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        let computed = compute(trimmed)

        cacheLock.lock()
        // Tetto prudente: le etichette di un corso sono decine, ma la
        // cache è statica e vive quanto il processo.
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[trimmed] = computed
        cacheLock.unlock()
        return computed
    }

    private static func compute(_ topic: String) -> [String] {
        let lowered = topic.lowercased()
        var lemmas: [String] = []
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = lowered
        tagger.setLanguage(.italian, range: lowered.startIndex..<lowered.endIndex)
        tagger.enumerateTags(
            in: lowered.startIndex..<lowered.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitPunctuation, .omitWhitespace, .omitOther]
        ) { tag, range in
            // Senza lemma (sigle, termini tecnici che il modello
            // linguistico non conosce) si tiene la parola com'è: mai
            // inventare, al massimo non normalizzare.
            let word = tag?.rawValue ?? String(lowered[range])
            lemmas.append(word)
            return true
        }
        if lemmas.isEmpty { lemmas = lowered.components(separatedBy: .whitespaces) }

        return lemmas.compactMap { lemma in
            let folded = lemma
                .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "it_IT"))
                .unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .reduce(into: "") { $0.unicodeScalars.append($1) }
            guard !folded.isEmpty, !stopwords.contains(folded) else { return nil }
            return folded
        }
    }

    // Chiave canonica: token ordinati alfabeticamente, così "dualità in
    // PL" e "PL, dualità" cadono sulla stessa. Vuota se l'etichetta non
    // ha niente di significativo.
    static func key(_ topic: String) -> String {
        tokens(topic).sorted().joined(separator: " ")
    }

    // Le sigle scritte TUTTE MAIUSCOLE nell'etichetta originale (PL,
    // PLI, FFT): è l'unico posto dove la forma grafica porta
    // informazione, quindi si leggono PRIMA di normalizzare.
    static func acronyms(_ topic: String) -> [String] {
        topic
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                guard token.count >= 2, token.count <= 5 else { return false }
                return token.allSatisfy { $0.isUppercase && $0.isLetter }
            }
            .map { $0.lowercased() }
    }
}

// Il vocabolario di un Vault: le etichette raggruppate per argomento, con
// una forma canonica per gruppo. Si costruisce da una lista di etichette
// grezze, senza rete e senza modelli.
struct TopicVocabulary {

    private struct Cluster {
        var canonical: String
        var tokens: Set<String>
        var order: Int
    }

    private var clusters: [Cluster] = []
    // Chiave canonica → indice del gruppo, per la lookup diretta.
    private var byKey: [String: Int] = [:]

    // Le etichette canoniche, nell'ordine in cui i loro gruppi sono
    // apparsi la prima volta (che è l'ordine del corso).
    var labels: [String] { clusters.sorted { $0.order < $1.order }.map(\.canonical) }

    var isEmpty: Bool { clusters.isEmpty }

    init(_ rawLabels: [String]) {
        // 1) Mappa degli acronimi: una sigla si espande SOLO se in questo
        //    stesso Vault esiste un'etichetta le cui iniziali la
        //    compongono per intero. Nessun dizionario indovinato.
        var expansions: [String: [String]] = [:]
        let tokenized = rawLabels.map { (label: $0, tokens: TopicKey.tokens($0)) }
        for candidate in tokenized where candidate.tokens.count >= 2 {
            let initials = candidate.tokens.compactMap(\.first).map(String.init).joined()
            guard initials.count == candidate.tokens.count else { continue }
            for raw in rawLabels {
                for acronym in TopicKey.acronyms(raw) where acronym == initials {
                    // Se due etichette diverse producono la stessa sigla
                    // vince la prima incontrata: l'ordine di ingresso è
                    // stabile, quindi lo è anche l'esito.
                    if expansions[acronym] == nil { expansions[acronym] = candidate.tokens }
                }
            }
        }

        // 2) Token definitivi: le sigle diventano la loro espansione.
        let resolved: [(label: String, tokens: [String])] = tokenized.map { entry in
            var out: [String] = []
            for token in entry.tokens {
                if let expansion = expansions[token], expansion != entry.tokens {
                    out.append(contentsOf: expansion)
                } else {
                    out.append(token)
                }
            }
            return (entry.label, out)
        }

        // 3) Raggruppamento. Si parte dalle etichette PIÙ specifiche (più
        //    token): la canonica di un gruppo è quella completa, non la
        //    troncata — "dualità in programmazione lineare" dice più di
        //    "dualità".
        let ordered = resolved.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.tokens.count != rhs.element.tokens.count {
                    return lhs.element.tokens.count > rhs.element.tokens.count
                }
                return lhs.offset < rhs.offset
            }

        for (offset, entry) in ordered {
            let tokens = Set(entry.tokens)
            guard !tokens.isEmpty else { continue }
            let key = entry.tokens.sorted().joined(separator: " ")

            if let existing = byKey[key] {
                clusters[existing].order = min(clusters[existing].order, offset)
                continue
            }

            // NIENTE contenimento in costruzione, di proposito. Fondere
            // "programmazione lineare" dentro "dualità in programmazione
            // lineare" non unisce due duplicati: cancella un argomento
            // più generale, e questi sono gli argomenti che l'utente
            // vede e spunta. Le vere varianti (accenti, plurali,
            // maiuscole, sigle) cadono già sulla stessa chiave qui
            // sopra; il resto è una differenza di granularità, che il
            // deterministico non è in grado di giudicare.
            byKey[key] = clusters.count
            clusters.append(Cluster(canonical: entry.label, tokens: tokens, order: offset))
        }
    }

    // L'etichetta canonica per un argomento qualsiasi — anche scritto da
    // un modello, che è il caso di `snap`. nil se non si riconosce: mai
    // inventare un aggancio, meglio un argomento in più che uno sbagliato.
    func canonical(for topic: String) -> String? {
        let tokens = Set(TopicKey.tokens(topic))
        guard !tokens.isEmpty else { return nil }
        let key = tokens.sorted().joined(separator: " ")
        if let index = byKey[key] { return clusters[index].canonical }

        // Il modello tende ad allungare ("dualità in PL (problema
        // duale)") o ad accorciare: si accetta il gruppo con la
        // sovrapposizione maggiore, purché uno contenga l'altro.
        var best: (index: Int, overlap: Int)?
        for (index, cluster) in clusters.enumerated() {
            guard tokens.isSubset(of: cluster.tokens) || cluster.tokens.isSubset(of: tokens) else { continue }
            let overlap = tokens.intersection(cluster.tokens).count
            if overlap > (best?.overlap ?? 0) { best = (index, overlap) }
        }
        guard let best else { return nil }
        return clusters[best.index].canonical
    }

    // Riduce una lista di etichette grezze alle sole canoniche, senza
    // doppioni e nell'ordine del corso.
    static func consolidated(_ rawLabels: [String]) -> [String] {
        TopicVocabulary(rawLabels).labels
    }
}
