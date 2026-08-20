import Foundation
import FoundationModels
import UIKit

// Layer AI provider-agnostico. Vincolo architetturale dell'app: restare
// gratuita a larga scala — l'inferenza avviene SEMPRE dal dispositivo
// dell'utente con la SUA chiave (o col modello Apple locale), mai da un
// server centralizzato. Il default consigliato è Gemini free tier (chiave
// gratuita su aistudio.google.com); Claude è BYOK opzionale; il modello
// Apple locale è il fallback zero-config.
enum AIProviderKind: String, CaseIterable {
    case appleLocal, gemini, claude

    var label: String {
        switch self {
        case .appleLocal: "Apple (locale)"
        case .gemini: "Gemini"
        case .claude: "Claude"
        }
    }

    var hint: String {
        switch self {
        case .appleLocal: "Gratis e on-device, richiede Apple Intelligence. Qualità limitata sui compiti complessi."
        case .gemini: "Consigliato: chiave gratuita su aistudio.google.com (free tier, nessuna carta)."
        case .claude: "BYOK: usa la chiave Anthropic già configurata per la penna magica."
        }
    }
}

// Quale famiglia di modelli Gemini usare. La differenza che conta NON è
// la qualità ma la quota: sul piano gratuito i modelli "Flash" pieni
// hanno ~20 richieste al giorno, i "Flash Lite" ~500. Con 5 chiamate per
// studio generato, 20/giorno significa 4 studi e l'app diventa
// inutilizzabile: per questo il default è Lite.
// Si usano SEMPRE gli alias "-latest": le versioni puntuali vengono
// ritirate per i nuovi utenti (gemini-2.5-flash risponde già 404).
enum GeminiModelTier: String, CaseIterable {
    case lite, full

    // Catena completa dei modelli da provare, in ordine. Sul piano
    // gratuito la quota è PER MODELLO, quindi incatenarli somma le quote:
    // ~1.060 richieste al giorno invece delle 500 di un modello solo.
    //
    // Composizione (verificata chiamandoli davvero il 2026-08-12; alias
    // ricontrollati sulla console il 2026-08-15):
    //   gemini-flash-lite-latest  -> 3.5 Flash Lite   500/giorno
    //   gemini-3.1-flash-lite                          500/giorno
    //   gemini-flash-latest       -> 3.7 Flash          20/giorno
    //   gemini-3.5-flash                                20/giorno
    //   gemini-3-flash-preview                          20/giorno
    // Nota dalla console: i tentativi falliti (503) contano nel limite
    // al minuto ma NON nella quota giornaliera — riprovare non spreca.
    //
    // Gli alias "-latest" stanno in testa perché non vengono mai
    // ritirati; le versioni fisse aggiungono quota ma possono sparire
    // (gemini-2.5-flash e 2.5-flash-lite rispondono già 404 "no longer
    // available to new users"), perciò un 404 fa proseguire la catena
    // invece di fermarla.
    //
    // Esclusi di proposito: Gemma 4 (26B/31B), che pure avrebbe 14.400
    // richieste al giorno — provato, non rispetta l'istruzione di
    // rispondere in JSON e restituisce il prompt riformulato, quindi
    // fallirebbe comunque la validazione dello schema.
    // Ordine tarato sui tempi MISURATI sullo stesso prompt da 21k token:
    // flash-lite 1,7s - 3-flash-preview 9,8s - flash-latest 11,3s -
    // 3.5-flash 57,9s. Quest'ultimo è l'ultima cartuccia: ci sta sotto il
    // timeout di rete (120s), ma in coda a una catena che ha già speso
    // tempo in 503 rischia di sfondare il tetto per modulo — per questo
    // di norma sta in fondo, e va davanti ai Lite solo dove la qualità
    // vale l'attesa (vedi `qualityFirst`).
    // `qualityFirst` sposta il Flash lento DAVANTI ai Lite invece che in
    // fondo. Serve agli esercizi e alla loro verifica, e solo a loro
    // (scelta dell'utente, 2026-08-17): lì la differenza Flash/Lite è
    // qualitativa — il Lite produce domande di definizione, il Flash
    // problemi con dati da applicare — quindi esaurire TUTTI i Flash
    // disponibili prima di scendere vale l'attesa. Un esercizio vero
    // dopo un minuto batte una domanda di definizione dopo due secondi.
    //
    // Sugli altri moduli resta l'ordine di prima: riassunti, flashcard e
    // ripasso sono compiti estrattivi dove il Lite non si distingue, e
    // far aspettare un minuto per un pareggio è solo attesa sprecata.
    //
    // Su `.lite` non cambia niente: chi sceglie quel tier ha scelto la
    // quota, e comunque gli esercizi passano da `.full` esplicito.
    func modelChain(qualityFirst: Bool = false) -> [String] {
        let lite = ["gemini-flash-lite-latest", "gemini-3.1-flash-lite"]
        let capable = ["gemini-flash-latest", "gemini-3-flash-preview"]
        let slow = ["gemini-3.5-flash"]
        switch self {
        case .lite: return lite + capable + slow
        case .full: return qualityFirst ? capable + slow + lite : capable + lite + slow
        }
    }

    var label: String {
        switch self {
        case .lite: "Quota alta (Lite)"
        case .full: "Qualità (Flash)"
        }
    }

    var hint: String {
        switch self {
        case .lite: "Consigliato: parte dai modelli Lite (circa 1.000 chiamate al giorno in tutto). Perfetto per riassunti, flashcard e trascrizioni."
        case .full: "Parte dai modelli più capaci (~20 chiamate al giorno, circa 10 secondi ciascuna): esercizi con dati concreti invece di domande di definizione. Esaurita la quota si scende sui Lite."
        }
    }
}

// A cosa serve la chiamata. I due usi hanno profili opposti e vanno
// configurati separatamente:
//
// - `reading` (trascrivere una pagina scritta a mano o scansionata) è ad
//   ALTO VOLUME — una chiamata per pagina, una dispensa ne vale decine —
//   ma è un compito semplice: "scrivi cosa vedi". Vuole quota, non
//   intelligenza.
// - `generation` (esercizi, riassunti, verifica) è a BASSO VOLUME —
//   cinque chiamate per studio — ma richiede ragionamento: è lì che un
//   modello migliore evita una soluzione guidata sbagliata.
//
// Con un'impostazione unica si finirebbe per bruciare il modello buono
// (~20 richieste/giorno) in trascrizioni, oppure per generare esercizi
// col modello meno capace. Da qui la separazione.
enum AIPurpose: String, CaseIterable {
    case reading, generation

    var label: String {
        switch self {
        case .reading: "Lettura dei materiali"
        case .generation: "Generazione dei contenuti"
        }
    }

    var explanation: String {
        switch self {
        case .reading: "Trascrizione di pagine scritte a mano e PDF scansionati. Tante chiamate, compito semplice."
        case .generation: "Riassunti, esercizi e verifica. Poche chiamate, ma è qui che serve un modello capace."
        }
    }

    var defaultsKey: String { "geminiModelTier_\(rawValue)" }

    // Quanto si aspetta una risposta, PRIMA di dichiarare morto il
    // modello e passare al successivo. Non è un numero uguale per tutti
    // perché le due chiamate non hanno la stessa taglia: la lettura
    // trascrive una pagina, la generazione scrive quindici esercizi con
    // traccia, passaggi, citazione e figura — 8-12k token, che a
    // scriverli ci vuole tempo. Il tetto di 120s tagliava a metà
    // scrittura risposte sane, e quello che si perdeva era il modello
    // MIGLIORE della catena: i capaci sono anche i lenti.
    //
    // Il prezzo è dichiarato: quando un modello è davvero appeso lo
    // aspettiamo il doppio prima di scendere. Lo si paga volentieri
    // perché quota esaurita e rate limit tornano comunque in pochi
    // secondi, e chi va in timeout resta poi in quarantena (vedi
    // GeminiModelLedger).
    //
    // Il rimedio giusto sarebbe un tetto di INATTIVITÀ su risposta in
    // streaming — finché arrivano token si aspetta, 45 secondi di
    // silenzio vogliono dire morto — ma richiede `streamGenerateContent`
    // e il parsing SSE: lavoro a sé.
    var networkTimeout: TimeInterval {
        switch self {
        case .reading: 120
        case .generation: 240
        }
    }

    // Tetto sui token in USCITA. Era 8192 per tutti, ed è stata la causa
    // del "modello ha restituito JSON non conforme" sugli esercizi: un
    // set da otto esercizi con traccia, passaggi guidati, risposta e
    // citazione supera abbondantemente quel tetto, la risposta veniva
    // troncata a metà oggetto e il JSON risultante non decodificava. I
    // riassunti, molto più corti, ci stavano dentro — per questo
    // fallivano solo gli esercizi.
    //
    // I flash correnti accettano 64k token in uscita. Non è un costo:
    // sul free tier si paga per richiesta, non per token generati, e il
    // modello produce comunque solo quello che serve.
    var maxOutputTokens: Int {
        switch self {
        case .reading: 8192
        case .generation: 65536
        }
    }

    var defaultTier: GeminiModelTier {
        switch self {
        // La lettura parte dai Lite e NON tocca i Flash per prima cosa,
        // per due motivi: trascrivere è un compito semplice dove il
        // modello migliore aggiunge poco, e soprattutto lettura e
        // generazione pescano dalla STESSA quota — una dispensa di 30
        // pagine si mangerebbe metà del budget "buono" della giornata,
        // lasciando gli esercizi senza. In più i Lite hanno 15
        // richieste/minuto contro 5, quindi sul volume sono anche più
        // veloci.
        case .reading: .lite
        // La generazione parte dai modelli capaci: scelta dell'utente,
        // qualità prima della velocità. Misurato sullo stesso prompt: il
        // Lite produce domande di definizione ("scrivi il duale di
        // min c'x"), il Flash esercizi con dati da applicare ("ottimo
        // finito 15, quanto vale il duale?"). Il costo in tempo è ~10s
        // contro ~2s per chiamata, reso accettabile dalla generazione dei
        // moduli in parallelo; esaurita la quota la catena scende sui
        // Lite da sola e l'utente viene avvisato.
        case .generation: .full
        }
    }
}

enum AIServiceError: Error {
    case notConfigured(String)
    case network(String)
    case quotaExhausted(String)
    // Limite AL MINUTO, non giornaliero: sul free tier i modelli capaci
    // accettano 5 richieste al minuto, e Gemini risponde 429 anche per
    // questo. È transitorio — basta aspettare — ma trattandolo come quota
    // finita si bruciava l'intera catena in pochi secondi e il modulo
    // falliva dicendo che la giornata era finita quando non lo era.
    case rateLimited(retryAfter: TimeInterval, detail: String)
    case modelUnavailable(String)
    // Il dettaglio c'è quando il modello ha detto PERCHÉ si è fermato
    // (tetto di token, filtri di sicurezza): senza, resta il messaggio
    // generico di prima.
    case badResponse(String?)
    // L'utente ha annullato, o il tetto di tempo del modulo è scaduto:
    // non è un guasto, e la catena si ferma subito invece di provare
    // altri modelli per una risposta che nessuno aspetta più.
    case cancelled

    var message: String {
        switch self {
        case .notConfigured(let what): what
        case .network(let reason): "Errore di rete: \(reason)"
        case .quotaExhausted(let reason): "Quota esaurita su tutti i modelli disponibili. \(reason)"
        case .rateLimited(_, let detail): "Troppe richieste ravvicinate: il limite è al minuto, non giornaliero. Riprova fra poco. \(detail)"
        case .modelUnavailable(let reason): "Nessun modello disponibile. \(reason)"
        case .badResponse(let detail): detail ?? "Il modello ha risposto in un formato inatteso."
        case .cancelled: "Generazione annullata."
        }
    }
}

// Risposta di una generazione testuale: il testo e il modello che l'ha
// davvero prodotta. Il modello viaggia DENTRO il risultato — la vecchia
// `static var lastUsedModelID` era condivisa tra i moduli generati in
// parallelo, e l'avviso "esercizi dal modello veloce" leggeva il modello
// dell'ultimo modulo finito, non il proprio (in Swift 6 quella corsa non
// compila nemmeno).
struct AIReply {
    let text: String
    // nil per il modello Apple locale, che non ha un ID di catena.
    let modelID: String?
    // La risposta è arrivata MOZZATA e ne è stata recuperata la parte
    // completa: chi la usa ha in mano meno roba di quanta ne ha chiesta,
    // e deve dirlo invece di far sembrare quel numero una scelta.
    var wasTruncated = false
}

enum AIService {
    private static let providerKey = "aiProviderKind"
    private static let geminiKeychainKey = "geminiAPIKey"
    static func geminiTier(for purpose: AIPurpose) -> GeminiModelTier {
        UserDefaults.standard.string(forKey: purpose.defaultsKey)
            .flatMap(GeminiModelTier.init(rawValue:)) ?? purpose.defaultTier
    }

    static func setGeminiTier(_ tier: GeminiModelTier, for purpose: AIPurpose) {
        UserDefaults.standard.set(tier.rawValue, forKey: purpose.defaultsKey)
    }

    static var selectedProvider: AIProviderKind {
        get {
            UserDefaults.standard.string(forKey: providerKey).flatMap(AIProviderKind.init(rawValue:)) ?? .appleLocal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: providerKey)
        }
    }

    // Le chiavi API vanno in Keychain: sono credenziali, non preferenze.
    // UserDefaults è un plist in chiaro che finisce nei backup — la
    // chiave Anthropic ci è rimasta a lungo per errore.
    static var geminiKey: String? {
        KeychainStore.get(geminiKeychainKey)
    }

    static func saveGeminiKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.remove(geminiKeychainKey)
        } else {
            KeychainStore.set(trimmed, forKey: geminiKeychainKey)
        }
    }

    private static let claudeKeychainKey = "anthropicAPIKey.keychain"
    private static let claudeLegacyDefaultsKey = "anthropicAPIKey"

    static var claudeKey: String? {
        if let key = KeychainStore.get(claudeKeychainKey), !key.isEmpty {
            return key
        }
        // Migrazione una tantum: chi aveva già salvato la chiave in
        // UserDefaults se la ritrova in Keychain al primo accesso, e la
        // copia in chiaro viene rimossa.
        let legacy = UserDefaults.standard.string(forKey: claudeLegacyDefaultsKey) ?? ""
        guard !legacy.isEmpty else { return nil }
        KeychainStore.set(legacy, forKey: claudeKeychainKey)
        UserDefaults.standard.removeObject(forKey: claudeLegacyDefaultsKey)
        return legacy
    }

    static func saveClaudeKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // La copia legacy in chiaro va rimossa in ogni caso: altrimenti
        // dopo un "Rimuovi" la migrazione la resusciterebbe.
        UserDefaults.standard.removeObject(forKey: claudeLegacyDefaultsKey)
        if trimmed.isEmpty {
            KeychainStore.remove(claudeKeychainKey)
        } else {
            KeychainStore.set(trimmed, forKey: claudeKeychainKey)
        }
    }

    // Il provider selezionato è utilizzabile adesso? (chiave presente /
    // modello locale disponibile). Usato per decidere se tentare la
    // generazione reale o restare sul mock.
    static var isConfigured: Bool {
        switch selectedProvider {
        case .appleLocal:
            if case .available = SystemLanguageModel.default.availability { return true }
            return false
        case .gemini:
            return geminiKey != nil
        case .claude:
            return claudeKey != nil
        }
    }

    // Unica porta d'ingresso per tutta l'app: prompt → testo. I chiamanti
    // che vogliono JSON passano `schema` (su Gemini diventa
    // responseSchema: sintassi garantita dall'API, escape LaTeX compresi)
    // e comunque validano col decoder (checklist anti-allucinazione: ciò
    // che non decodifica non si mostra).
    //
    // `thinkingBudget` è 0 di default, ed è una scelta misurata (sonda
    // del 2026-08-15, 4 varianti × 5 modelli): i Flash col thinking
    // libero spendono 1.400-5.300 token a ragionare su compiti
    // estrattivi — 21,4s invece di 4,9s su gemini-3.5-flash — e con lo
    // schema attivo gemini-3-flash-preview è andato in spirale (7.865
    // token di thinking, MAX_TOKENS, JSON rotto). Il ragionamento paga
    // solo dove si INVENTA (esercizi, verifica): lì il chiamante passa
    // un budget esplicito.
    //
    // `onAttempt` avvisa a ogni modello provato (ID, posizione, totale,
    // e PERCHÉ il precedente ha ceduto — senza quel motivo, davanti a
    // "Provo X (3/5)" non si distingue Google che arranca da un tetto di
    // tempo nostro troppo stretto):
    // serve alla UI per rendere leggibile l'attesa.
    static func generate(
        prompt: String,
        purpose: AIPurpose = .generation,
        tier: GeminiModelTier? = nil,
        schema: [String: Any]? = nil,
        thinkingBudget: Int = 0,
        qualityFirst: Bool = false,
        onAttempt: (@Sendable (_ modelID: String, _ position: Int, _ total: Int, _ previousFailure: String?) -> Void)? = nil
    ) async -> Result<AIReply, AIServiceError> {
        switch selectedProvider {
        case .appleLocal:
            return await generateWithAppleLocal(prompt: prompt).map { AIReply(text: $0, modelID: nil) }
        case .gemini:
            return await generateWithGemini(prompt: prompt, purpose: purpose, tier: tier, schema: schema, thinkingBudget: thinkingBudget, qualityFirst: qualityFirst, onAttempt: onAttempt)
        case .claude:
            return await generateWithClaude(prompt: prompt, purpose: purpose, schema: schema).map { AIReply(text: $0, modelID: "claude-haiku") }
        }
    }

    // MARK: - Apple locale (FoundationModels)

    private static func generateWithAppleLocal(prompt: String) async -> Result<String, AIServiceError> {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return .failure(.notConfigured("Il modello Apple locale non è disponibile su questo iPad (serve Apple Intelligence attiva)."))
        }
        let session = LanguageModelSession(model: model)
        guard let response = try? await session.respond(to: prompt) else {
            return .failure(.badResponse(nil))
        }
        return .success(response.content)
    }

    // MARK: - Gemini (free tier, chiave dell'utente)

    // Catena di modelli da provare: il preferito, poi l'altro. Sul piano
    // gratuito le quote sono PER MODELLO (il Flash pieno si esaurisce in
    // ~20 richieste al giorno, il Lite ne ha ~500), quindi quando uno è
    // pieno l'altro è quasi sempre ancora disponibile: senza questo
    // fallback la generazione ripiegherebbe sul mock pur avendo quota
    // altrove.
    private static func geminiModelChain(for purpose: AIPurpose) -> [String] {
        geminiTier(for: purpose).modelChain()
    }

    // True quando l'ultima generazione è finita sui modelli Lite pur
    // avendo chiesto i capaci: serve ad avvisare che la quota buona è
    // esaurita, invece di far notare all'utente un calo di qualità senza
    // spiegazione.
    static func isLiteModel(_ modelID: String?) -> Bool {
        guard let modelID else { return false }
        return modelID.contains("lite")
    }

    // True se OGGI tutti i modelli capaci risultano già senza quota:
    // permette di avvisare PRIMA di generare ("gli esercizi usciranno
    // dal modello veloce") invece di far scoprire il declassamento a
    // generazione finita. Si basa sul registro di sessione, quindi sa
    // solo dei modelli già provati: meglio un avviso mancato che uno
    // sbagliato.
    static func capableQuotaLooksExhausted() async -> Bool {
        let capable = GeminiModelTier.full.modelChain().filter { !isLiteModel($0) }
        for modelID in capable where !(await GeminiModelLedger.shared.isExhausted(modelID)) {
            return false
        }
        return true
    }

    // Cosa la sessione ha imparato su ogni modello: quota del giorno
    // finita, sovraccarico momentaneo, rifiuto di thinkingConfig. Un
    // registro condiviso serve perché i moduli di uno studio girano in
    // PARALLELO: senza, ognuno dei tre riscopre per conto suo le stesse
    // cose, pagando ogni volta le stesse chiamate a vuoto. È un attore e
    // non una variabile statica proprio per quel parallelismo.
    private actor GeminiModelLedger {
        static let shared = GeminiModelLedger()
        private var exhaustedAt: [String: Date] = [:]
        // 503/500/timeout: guasto transitorio DI QUEL modello. Misurato
        // (2026-08-15): il 503 di gemini-flash-latest arrivava dopo
        // 22-26 secondi — senza memoria, tre moduli in parallelo lo
        // pagavano tutti e tre, e poi di nuovo al retry.
        private var overloadedUntil: [String: Date] = [:]
        // Il sovraccarico passa da solo: qualche minuto di quarantena,
        // poi il modello si riprova. Vale anche per i 404 (modello
        // ritirato): riprovarlo ogni tanto costa una chiamata veloce.
        private let overloadQuarantine: TimeInterval = 180
        // Modelli che hanno risposto 400 a thinkingConfig (il solo
        // gemini-flash-lite-latest, a oggi: non ragiona affatto e
        // rifiuta il parametro). Ricordarlo evita di ripagare il 400 a
        // ogni chiamata — trenta pagine di lettura sono trenta 400.
        private var rejectsThinking: Set<String> = []

        // La quota giornaliera di Gemini si azzera a mezzanotte del fuso
        // del Pacifico: finché lì è ancora lo stesso giorno, il modello
        // resta da parte. Non è una scadenza a tempo — segnarlo alle 23:50
        // e riprovare alle 00:10 deve funzionare.
        private static let resetCalendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            if let pacific = TimeZone(identifier: "America/Los_Angeles") {
                calendar.timeZone = pacific
            }
            return calendar
        }()

        func markExhausted(_ modelID: String) {
            exhaustedAt[modelID] = .now
        }

        func isExhausted(_ modelID: String) -> Bool {
            guard let markedAt = exhaustedAt[modelID] else { return false }
            guard Self.resetCalendar.isDate(markedAt, inSameDayAs: .now) else {
                exhaustedAt.removeValue(forKey: modelID)
                return false
            }
            return true
        }

        func markOverloaded(_ modelID: String) {
            overloadedUntil[modelID] = Date.now.addingTimeInterval(overloadQuarantine)
        }

        func isOverloaded(_ modelID: String) -> Bool {
            guard let until = overloadedUntil[modelID] else { return false }
            guard until > .now else {
                overloadedUntil.removeValue(forKey: modelID)
                return false
            }
            return true
        }

        func markRejectsThinking(_ modelID: String) {
            rejectsThinking.insert(modelID)
        }

        func acceptsThinking(_ modelID: String) -> Bool {
            !rejectsThinking.contains(modelID)
        }
    }

    private static func generateWithGemini(prompt: String, purpose: AIPurpose, tier: GeminiModelTier? = nil, schema: [String: Any]? = nil, thinkingBudget: Int = 0, qualityFirst: Bool = false, onAttempt: (@Sendable (String, Int, Int, String?) -> Void)? = nil) async -> Result<AIReply, AIServiceError> {
        guard geminiKey != nil else {
            return .failure(.notConfigured("Nessuna chiave Gemini: creane una gratuita su aistudio.google.com e salvala nel Profilo."))
        }

        let chain = tier?.modelChain(qualityFirst: qualityFirst) ?? geminiModelChain(for: purpose)
        var lastError: AIServiceError = .badResponse(nil)
        var attemptedAny = false
        var skippedBusy = false
        // Motivo per cui il modello PRECEDENTE ha ceduto, in una forma
        // leggibile: viaggia con l'avviso del tentativo successivo.
        var previousFailure: String?

        // DUE passate sulla catena, e la prima non dorme mai.
        //
        // Prima si dormiva fino a 30 secondi sul modello che aveva dato
        // il limite al minuto, RIPROVANDO LO STESSO, e solo dopo si
        // passava al successivo. Ma il limite al minuto è per modello: i
        // Lite stanno due posizioni più giù con 15 richieste al minuto
        // quasi intatte, e provarli costa un secondo invece di trenta.
        // Aspettare aveva senso solo se non restava nient'altro — ed è
        // esattamente quello che fa ora la seconda passata.
        var shortestRetry: TimeInterval?

        for pass in 0...1 {
            if pass == 1 {
                // Si arriva qui solo se TUTTA la catena era al limite del
                // minuto: allora sì, l'attesa è l'unica strada.
                guard let wait = shortestRetry else { break }
                try? await Task.sleep(for: .seconds(min(wait, 30)))
            }

            for (position, modelID) in chain.enumerated() {
                // La generazione è stata annullata (dall'utente o dal
                // tetto di tempo): provare altri modelli è lavoro per
                // una risposta che nessuno aspetta più.
                if Task.isCancelled { return .failure(.cancelled) }
                // Saltato senza nemmeno chiamare: la quota giornaliera
                // non torna aspettando qualche secondo.
                if await GeminiModelLedger.shared.isExhausted(modelID) { continue }
                // Sovraccarico segnato pochi minuti fa: il suo 503 costa
                // 20+ secondi ad arrivare, il modello dopo risponde in 3.
                if await GeminiModelLedger.shared.isOverloaded(modelID) {
                    skippedBusy = true
                    continue
                }
                attemptedAny = true
                onAttempt?(modelID, position + 1, chain.count, previousFailure)

                switch await callGemini(prompt: prompt, modelID: modelID, purpose: purpose, schema: schema, thinkingBudget: thinkingBudget) {
                case .success(let reply):
                    return .success(AIReply(text: reply.text, modelID: modelID, wasTruncated: reply.truncated))
                case .failure(let error):
                    lastError = error
                    switch error {
                    case .quotaExhausted:
                        previousFailure = "aveva finito la quota di oggi"
                        await GeminiModelLedger.shared.markExhausted(modelID)
                    case .rateLimited(let retryAfter, _):
                        previousFailure = "era al limite di richieste al minuto"
                        shortestRetry = min(shortestRetry ?? retryAfter, retryAfter)
                    case .modelUnavailable(let detail):
                        // Timeout e sovraccarico finiscono nello stesso
                        // caso ma vanno distinti proprio qui: il primo
                        // accusa il NOSTRO tetto di tempo, il secondo
                        // accusa Google. I due messaggi li scriviamo noi
                        // in `callGemini`, quindi il confronto regge.
                        previousFailure = detail.localizedCaseInsensitiveContains("in tempo")
                            ? "non ha risposto in tempo"
                            : "era sovraccarico"
                        // In quarantena per qualche minuto: gli altri
                        // moduli in parallelo non devono ripagare la
                        // stessa attesa sullo stesso modello intasato.
                        await GeminiModelLedger.shared.markOverloaded(modelID)
                    case .badResponse:
                        previousFailure = "ha dato una risposta non valida"
                        // MAX_TOKENS, SAFETY, risposta vuota: è un guasto
                        // di QUEL modello su QUESTO prompt, non della
                        // richiesta — il successivo risponde quasi sempre.
                        // Prima interrompeva la catena come un errore di
                        // rete, uccidendo il modulo con quattro modelli
                        // liberi mai provati.
                        break
                    // Rete giù, chiave sbagliata, annullamento: cambiare
                    // modello non aiuta.
                    case .network, .notConfigured, .cancelled:
                        return .failure(error)
                    }
                }
            }
        }

        // Nessuna chiamata partita: dirlo con la sua ragione, invece di
        // lasciare il messaggio generico dell'ultimo errore (che qui non
        // esiste nemmeno).
        if !attemptedAny {
            if skippedBusy {
                return .failure(.modelUnavailable("I modelli con quota residua risultano sovraccarichi in questo momento. Riprova tra qualche minuto."))
            }
            return .failure(.quotaExhausted("Tutti i modelli hanno esaurito la quota di oggi. Si azzera a mezzanotte, fuso del Pacifico."))
        }
        return .failure(lastError)
    }

    // Distingue il limite al minuto dalla quota giornaliera leggendo i
    // `details` della risposta di Gemini: le violazioni portano un
    // `quotaId` che dice quale finestra è stata superata, e un `RetryInfo`
    // con l'attesa consigliata dal server.
    //
    // Il verdetto "giornaliera" richiede PROVA POSITIVA (PerDay/Daily nei
    // details o "per day" nel testo). Prima valeva il contrario — "se non
    // leggo PerMinute è giornaliera" — e un 429 coi details assenti o in
    // una forma nuova segnava il modello come morto fino a mezzanotte:
    // successo davvero, con la console che mostrava 3/20 richieste usate
    // e l'app che diceva "quota esaurita". I costi sono asimmetrici:
    // classificare male un 429 transitorio costa una giornata di messaggi
    // falsi, classificare male una quota vera costa un retry che fallisce
    // in un secondo.
    private struct RateLimit {
        var isPerDay: Bool
        var retryAfter: TimeInterval?
    }

    private static func rateLimitInfo(from errorObject: [String: Any]?, message: String?) -> RateLimit {
        var isPerDay = false
        var retryAfter: TimeInterval?

        for detail in (errorObject?["details"] as? [[String: Any]]) ?? [] {
            let type = (detail["@type"] as? String) ?? ""
            if type.contains("QuotaFailure") {
                for violation in (detail["violations"] as? [[String: Any]]) ?? [] {
                    let identifiers = [violation["quotaId"] as? String, violation["quotaMetric"] as? String].compactMap { $0 }
                    if identifiers.contains(where: { $0.localizedCaseInsensitiveContains("PerDay") || $0.localizedCaseInsensitiveContains("Daily") }) {
                        isPerDay = true
                    }
                }
            }
            if type.contains("RetryInfo"), let delay = detail["retryDelay"] as? String {
                retryAfter = TimeInterval(delay.replacingOccurrences(of: "s", with: ""))
            }
        }
        // Alcune risposte non portano i `details`: resta il testo.
        if !isPerDay, let message, message.localizedCaseInsensitiveContains("per day") {
            isPerDay = true
        }
        return RateLimit(isPerDay: isPerDay, retryAfter: retryAfter)
    }

    // Testo + "era mozzato": la bandierina nasce dentro il parsing e deve
    // arrivare fino al chiamante, altrimenti un set dimezzato si presenta
    // come un set completo.
    struct GeminiText {
        let text: String
        var truncated = false
    }

    private static func callGemini(prompt: String, modelID: String, purpose: AIPurpose, schema: [String: Any]? = nil, thinkingBudget: Int = 0) async -> Result<GeminiText, AIServiceError> {
        guard let key = geminiKey else {
            return .failure(.notConfigured("Nessuna chiave Gemini: creane una gratuita su aistudio.google.com e salvala nel Profilo."))
        }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent") else {
            return .failure(.badResponse(nil))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // La chiave viaggia in header, non in query string (finirebbe nei log).
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        // Non 45 e nemmeno un numero unico: i modelli capaci — quelli
        // che l'utente ha scelto per la qualità — impiegano 10-58s
        // misurati su prompt da 21k token, e con tre richieste in
        // parallelo il tempo cresce ancora. Un timeout più corto del
        // tempo di risposta del modello non protegge da niente: fa solo
        // fallire chiamate sane. Il tetto per scopo sta in AIPurpose.
        request.timeoutInterval = purpose.networkTimeout

        // Temperatura bassa: compiti estrattivi/strutturati, non creativi
        // (checklist anti-allucinazione).
        var generationConfig: [String: Any] = [
            "temperature": 0.2,
            "maxOutputTokens": purpose.maxOutputTokens
        ]
        // Il MIME JSON si imposta SOLO insieme allo schema. Prima era
        // fisso su application/json per ogni chiamata testuale, anche
        // quelle che chiedono prosa: il modello, costretto al JSON,
        // inventava un involucro con chiavi sue ("Spiega" mostrava
        // {"titolo": ...} crudo) e il doppio strato di escape maciullava
        // i backslash del LaTeX (\in → in). Chi vuole JSON passa uno
        // schema, e allora la sintassi la garantisce l'API (decoding
        // vincolato, verificato 2026-08-15); chi vuole testo, riceve testo.
        if let schema {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = schema
        }
        // thinkingConfig va DENTRO generationConfig. Il vecchio commento
        // "i flash lo rifiutano con 400" era una generalizzazione da un
        // solo modello: lo rifiuta gemini-flash-lite-latest (che non
        // ragiona affatto), gli altri quattro lo accettano — misurato.
        // Sul 400 si ritenta senza, e il registro lo ricorda.
        let includeThinking = await GeminiModelLedger.shared.acceptsThinking(modelID)
        if includeThinking {
            generationConfig["thinkingConfig"] = ["thinkingBudget": thinkingBudget]
        }
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": generationConfig
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.badResponse(nil))
        }
        request.httpBody = bodyData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            // Trattato come "modello non disponibile" così la catena
            // prosegue: prima un timeout faceva fallire l'intero modulo
            // anche quando il modello dopo avrebbe risposto subito.
            return .failure(.modelUnavailable("Il modello \(modelID) non ha risposto in tempo."))
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // 400 con thinkingConfig nel corpo: quasi certamente è il
            // modello che non lo supporta. Si segna e si rifà la stessa
            // chiamata senza — se il 400 aveva un'altra causa, tornerà
            // identico e seguirà la strada normale.
            if http.statusCode == 400, includeThinking {
                await GeminiModelLedger.shared.markRejectsThinking(modelID)
                return await callGemini(prompt: prompt, modelID: modelID, purpose: purpose, schema: schema, thinkingBudget: thinkingBudget)
            }
            let errorObject = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
            let detail = errorObject?["message"] as? String
            let status = errorObject?["status"] as? String
            // 429 vuol dire DUE cose diverse, e confonderle è costato caro:
            // la quota del giorno finita (il modello va abbandonato) oppure
            // il limite al minuto (basta aspettare qualche secondo). La
            // distinzione sta nei `details` della risposta — e in dubbio
            // si presume transitorio, mai giornaliero.
            if http.statusCode == 429 || status == "RESOURCE_EXHAUSTED" {
                let limit = rateLimitInfo(from: errorObject, message: detail)
                if limit.isPerDay {
                    return .failure(.quotaExhausted(detail ?? "Quota giornaliera esaurita per questo modello."))
                }
                return .failure(.rateLimited(
                    retryAfter: limit.retryAfter ?? 20,
                    detail: detail ?? "Limite di richieste raggiunto, riprova tra poco."
                ))
            }
            // 404 = modello ritirato per i nuovi utenti (succede alle
            // versioni fisse): si tratta come "prova il prossimo".
            if http.statusCode == 404 {
                return .failure(.modelUnavailable(detail ?? "Modello non disponibile."))
            }
            // 503 "experiencing high demand" = QUEL modello è
            // sovraccarico in questo momento, non la rete: il successivo
            // della catena è quasi sempre libero. Classificato come
            // errore di rete fermava l'intera generazione al primo
            // modello intasato — visto succedere davvero, con la card
            // che mostrava "Errore di rete: high demand". Il 500 idem:
            // guasto del servizio su quel modello, si prova oltre.
            if http.statusCode == 503 || http.statusCode == 500 || status == "UNAVAILABLE" || status == "INTERNAL" {
                return .failure(.modelUnavailable(detail ?? "Modello momentaneamente sovraccarico."))
            }
            return .failure(.network(detail ?? "HTTP \(http.statusCode)"))
        }
        // Chiamata riuscita: si conta per il pannello quota (i 2xx sono
        // gli unici che consumano RPD).
        Task { @MainActor in GeminiQuotaMeter.shared.record(modelID) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            return .failure(.badResponse(nil))
        }
        // Quando il modello si ferma senza produrre testo il motivo sta
        // qui, e prima finiva tutto in un ".badResponse(nil)" muto: SAFETY o
        // RECITATION vogliono un prompt diverso, MAX_TOKENS un tetto più
        // alto. Dirlo cambia cosa può fare l'utente.
        let finishReason = candidate["finishReason"] as? String
        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return .failure(.badResponse(reason(for: finishReason)))
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { return .failure(.badResponse(reason(for: finishReason))) }
        // TESTO C'È, MA È MOZZATO. Con MAX_TOKENS il modello ha smesso a
        // metà frase: il JSON che ne esce non chiude, il decoder muore con
        // "dataCorrupted" e all'utente arrivava "la risposta si è
        // interrotta prima della fine" — vero, ma detto DOPO essersi
        // giocati il modello, perché una risposta troncata risultava un
        // SUCCESSO e la catena si fermava lì con altri quattro modelli mai
        // provati. Trattarla come guasto di quel modello la rimette in
        // moto: il successivo quasi sempre ci sta dentro. Se nemmeno lui
        // ce la fa, l'ultimo errore porta comunque il consiglio giusto
        // ("chiedi meno contenuti per volta").
        guard finishReason != "MAX_TOKENS" else {
            // Prima di rinunciare: quella risposta è una chiamata GIÀ
            // PAGATA della quota del giorno, e dentro ci sono quasi
            // sempre parecchi elementi completi — si perde tutto solo
            // perché l'ultimo è a metà e l'array non chiude. Se si
            // riesce a chiuderlo sull'ultimo elemento intero, quelli si
            // tengono; altrimenti si passa al modello dopo come prima.
            if let salvaged = salvageTruncatedJSON(text) {
                return .success(GeminiText(text: salvaged, truncated: true))
            }
            return .failure(.badResponse(reason(for: finishReason)))
        }
        return .success(GeminiText(text: text))
    }

    // Chiude un JSON interrotto a metà sull'ULTIMO ELEMENTO COMPLETO di
    // un array, e butta il troncone finale.
    //
    // Non è un parser tollerante e non "aggiusta" niente: scorre il testo
    // una volta sola tenendo conto di stringhe ed escape (una parentesi
    // dentro una stringa non è una parentesi), segna l'ultimo punto in cui
    // un elemento si è chiuso restando dentro un array, taglia lì e mette
    // le chiusure che mancano. Quello che ne esce o è JSON valido con
    // MENO elementi, o è nil: mai un elemento monco spacciato per intero,
    // che sarebbe peggio di perdere la risposta.
    static func salvageTruncatedJSON(_ raw: String) -> String? {
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var safeEnd: String.Index?
        var safeStack: [Character] = []

        for index in raw.indices {
            let character = raw[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{", "[": stack.append(character)
            case "}", "]":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
                // Elemento chiuso e siamo tornati dentro un array: da qui
                // il taglio è sicuro.
                if stack.last == "[" {
                    safeEnd = raw.index(after: index)
                    safeStack = stack
                }
            default: break
            }
        }

        guard let safeEnd, !safeStack.isEmpty else { return nil }
        var repaired = String(raw[raw.startIndex..<safeEnd])
        for open in safeStack.reversed() {
            repaired.append(open == "[" ? "]" : "}")
        }
        return repaired
    }

    private static func reason(for finishReason: String?) -> String? {
        switch finishReason {
        case "MAX_TOKENS": "La risposta ha superato la lunghezza massima. Prova a generare meno contenuti per volta."
        case "SAFETY": "Il modello ha bloccato la risposta per i filtri di sicurezza."
        case "RECITATION": "Il modello ha interrotto la risposta perché stava riproducendo testo protetto da copyright."
        case .some(let other) where other != "STOP": "Il modello ha interrotto la generazione (\(other))."
        default: nil
        }
    }

    // MARK: - Escape LaTeX dentro il JSON
    //
    // Il problema più insidioso della generazione, e vale SOLO per noi
    // che chiediamo formule: in JSON il backslash è un carattere di
    // escape, e "\implies" non è una sequenza valida. Il modello quasi
    // sempre raddoppia correttamente ("\\le", "\\max"), ma basta che
    // dimentichi UN comando su cinquanta perché l'intera risposta
    // diventi indecodificabile e si perdano otto esercizi buoni.
    //
    // Misurato su una generazione vera: 47 comandi LaTeX corretti, uno
    // solo ("\implies") sbagliato, decodifica fallita. È il motivo per
    // cui fallivano gli esercizi e non i riassunti — sono gli esercizi a
    // essere pieni di formule.
    //
    // Qui i backslash non validi vengono raddoppiati, ottenendo il JSON
    // che il modello intendeva scrivere. Si lavora solo dentro le
    // stringhe: fuori, un backslash non ha motivo di esistere.
    // Il guasto GEMELLO, e più insidioso perché non fa fallire niente.
    //
    // `sanitizeJSONEscapes` raddoppia i backslash che JSON considera non
    // validi — ma \b \f \n \r \t \u SONO validi, e sono anche l'inizio dei
    // comandi LaTeX più frequenti. Così "\frac{1}{2}" scritto senza
    // raddoppio decodifica benissimo... in un formfeed seguito da
    // "rac{1}{2}". Nessun errore, solo formule rotte nelle risposte.
    // (Misurato: \frac, \begin, \theta, \neq, \rho tutti corrotti in
    // silenzio; \underline fa proprio fallire la decodifica, perché \u
    // vuole quattro cifre esadecimali.)
    //
    // Qui quelle sei sequenze vengono riportate a comandi LaTeX quando è
    // ciò che sono davvero. Il criterio cambia per lettera, perché cambia
    // quanto è plausibile l'escape vero:
    //   b, f, r  un backspace/formfeed/ritorno-carrello seguito da una
    //            lettera non ha senso in un testo di studio: è LaTeX.
    //   n, t     l'a-capo e la tabulazione servono davvero, quindi si
    //            interviene solo sui comandi noti che iniziano così.
    //   u        \u è valido solo con quattro cifre esadecimali dietro;
    //            altrimenti è \underline, \uparrow e simili.
    private static let latexCommandsAfterEscape: [Character: [String]] = [
        "n": ["neq", "nabla", "nu", "ne", "not", "notin", "nonumber",
              "nleq", "ngeq", "nmid", "nsubseteq", "nparallel", "nrightarrow"],
        "t": ["theta", "times", "tan", "tanh", "text", "textbf", "textit",
              "tau", "tfrac", "to", "top", "tilde", "triangle", "tbinom", "therefore"]
    ]

    static func protectLaTeXEscapes(in text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var inString = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            guard character == "\\", inString else {
                if character == "\"" { inString.toggle() }
                output.append(character)
                index = text.index(after: index)
                continue
            }
            let next = text.index(after: index)
            guard next < text.endIndex else {
                output.append(character)
                index = next
                continue
            }
            let escape = text[next]
            // Un backslash già raddoppiato si copia intatto: rivalutare il
            // secondo lo trasformerebbe in un comando inesistente.
            if escape == "\\" {
                output.append(character)
                output.append(escape)
                index = text.index(after: next)
                continue
            }

            let rest = text[text.index(after: next)...]
            if isLaTeXCommand(escape: escape, followedBy: rest) {
                output.append("\\")
                output.append("\\")
                output.append(escape)
            } else {
                output.append(character)
                output.append(escape)
            }
            index = text.index(after: next)
        }
        return output
    }

    private static func isLaTeXCommand(escape: Character, followedBy rest: Substring) -> Bool {
        let letters = String(rest.prefix(while: { $0.isLetter }))
        switch escape {
        case "b", "f", "r":
            return !letters.isEmpty
        case "n", "t":
            let word = String(escape) + letters
            return latexCommandsAfterEscape[escape]?.contains { word.hasPrefix($0) } ?? false
        case "u":
            let candidate = rest.prefix(4)
            return candidate.count < 4 || !candidate.allSatisfy(\.isHexDigit)
        default:
            return false
        }
    }

    static func sanitizeJSONEscapes(in text: String) -> String {
        // Le uniche sequenze che JSON considera valide dopo un backslash.
        let validEscapes: Set<Character> = ["\"", "\\", "/", "b", "f", "n", "r", "t", "u"]
        var output = ""
        output.reserveCapacity(text.count)

        var inString = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "\\" else {
                if character == "\"" { inString.toggle() }
                output.append(character)
                index = text.index(after: index)
                continue
            }
            let next = text.index(after: index)
            guard inString, next < text.endIndex else {
                output.append(character)
                index = next
                continue
            }
            let following = text[next]
            if validEscapes.contains(following) {
                // Sequenza valida: si copia intatta. Copiare ANCHE il
                // carattere seguente è essenziale — se dopo "\\" si
                // rivalutasse il secondo backslash da solo, una stringa
                // già corretta verrebbe raddoppiata di nuovo.
                output.append(character)
                output.append(following)
                index = text.index(after: next)
            } else {
                output.append("\\")
                output.append("\\")
                output.append(following)
                index = text.index(after: next)
            }
        }
        return output
    }

    // MARK: - Riparazione di un JSON troncato
    //
    // Se la risposta si interrompe a metà (tetto di token raggiunto,
    // connessione caduta), il testo contiene comunque N elementi
    // completi seguiti da uno a metà. Buttare via tutto significa
    // perdere sei esercizi buoni per colpa del settimo: qui si taglia
    // all'ultimo elemento chiuso e si richiudono i contenitori aperti,
    // ottenendo un JSON valido con quello che si è salvato.
    //
    // Restituisce nil se non c'è nemmeno un elemento completo, o se il
    // testo era già bilanciato (in quel caso non c'era niente da
    // riparare e il problema è un altro).
    static func repairTruncatedJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var stack: [Character] = []
        var lastSafeCut: String.Index?
        var lastSafeStack: [Character] = []
        var inString = false
        var escaped = false

        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if inString && character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                switch character {
                case "{", "[":
                    stack.append(character)
                case "}", "]":
                    guard !stack.isEmpty else { return nil }
                    stack.removeLast()
                    // Chiuso un oggetto che stava dentro un array: fin
                    // qui il JSON è tagliabile senza perdere un elemento
                    // a metà.
                    if stack.last == "[" {
                        lastSafeCut = text.index(after: index)
                        lastSafeStack = stack
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }

        // Bilanciato: non era troncato, riparare non ha senso.
        guard !stack.isEmpty, let cut = lastSafeCut else { return nil }

        var repaired = String(text[start..<cut])
        for open in lastSafeStack.reversed() {
            repaired.append(open == "[" ? "]" : "}")
        }
        return repaired
    }

    // MARK: - Claude (BYOK)

    // Tetto in uscita per Claude, DIVERSO da quello di Gemini: Haiku 4.5
    // arriva a 64k token, ma questa è una richiesta non-streaming su
    // URLSession e sopra i ~16k si rischia il timeout HTTP prima che il
    // modello abbia finito. Restare sotto quella soglia è la scelta
    // conservativa: chi vuole i 64k pieni deve prima passare allo
    // streaming SSE. Comunque molto più dei 3000 di prima, che erano la
    // stessa trappola già pagata su Gemini (vedi maxOutputTokens): un set
    // di esercizi con traccia, passaggi e citazione non ci sta, la
    // risposta veniva troncata e il JSON non decodificava.
    private static func claudeMaxOutputTokens(for purpose: AIPurpose) -> Int {
        switch purpose {
        case .reading: 8192
        case .generation: 16000
        }
    }

    // Traduce lo schema in dialetto Gemini (tipi in MAIUSCOLO) in JSON
    // Schema, che è quello che vuole `output_config.format` di Anthropic.
    // Oltre al case dei tipi c'è un requisito non negoziabile: ogni
    // oggetto deve portare "additionalProperties": false, altrimenti la
    // compilazione dello schema viene rifiutata con un 400.
    //
    // `required` viene lasciato COM'È, cioè minimo (vedi il commento su
    // responseSchema in StudioGenerationService): "quote" e "source" sono
    // opzionali per scelta, meglio un esercizio senza citazione che un
    // modulo fallito. Se la compilazione dovesse pretendere tutti i campi
    // in required, il 400 lo dice esplicitamente.
    private static func claudeJSONSchema(from node: Any) -> Any {
        guard var dict = node as? [String: Any] else { return node }
        // "propertyOrdering" è un'estensione di Gemini (decide l'ordine in
        // cui i campi vengono GENERATI, non solo scritti). In JSON Schema
        // non esiste, e la compilazione stretta di Anthropic rifiuta con
        // un 400 quello che non conosce: qui si toglie.
        dict.removeValue(forKey: "propertyOrdering")
        var lowercased: String?
        if let type = dict["type"] as? String {
            lowercased = type.lowercased()
            dict["type"] = lowercased
        }
        if let properties = dict["properties"] as? [String: Any] {
            dict["properties"] = properties.mapValues { claudeJSONSchema(from: $0) }
        }
        if lowercased == "object" {
            dict["additionalProperties"] = false
        }
        if let items = dict["items"] {
            dict["items"] = claudeJSONSchema(from: items)
        }
        return dict
    }

    private static func generateWithClaude(
        prompt: String,
        purpose: AIPurpose = .generation,
        schema: [String: Any]? = nil
    ) async -> Result<String, AIServiceError> {
        guard let key = claudeKey else {
            return .failure(.notConfigured("Nessuna chiave Anthropic configurata nel Profilo."))
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return .failure(.badResponse(nil))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": claudeMaxOutputTokens(for: purpose),
            "temperature": 0.2,
            "messages": [["role": "user", "content": prompt]]
        ]
        // Output strutturato garantito lato server, l'equivalente del
        // responseSchema di Gemini: il JSON esce valido per costruzione
        // invece che sperato. Prima lo schema arrivava fin qui e veniva
        // ignorato in silenzio, quindi su questo provider la torre di
        // riparazioni a valle era l'UNICA difesa.
        if let schema {
            body["output_config"] = [
                "format": ["type": "json_schema", "schema": claudeJSONSchema(from: schema)]
            ]
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.badResponse(nil))
        }
        request.httpBody = bodyData

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.badResponse(nil))
        }
        // Formato errore Anthropic: {"type":"error","error":{"message":...}} —
        // rate limit, credito esaurito, chiave non valida: il motivo reale
        // va mostrato, non un generico "formato inatteso".
        if let apiError = json["error"] as? [String: Any],
           let message = apiError["message"] as? String {
            return .failure(.network(message))
        }
        // Il perché si è fermato va guardato PRIMA di leggere il contenuto:
        // con l'output strutturato un troncamento produce JSON incompleto
        // che a valle diventerebbe un generico "formato inatteso", e su un
        // rifiuto il contenuto non rispetta lo schema per definizione.
        switch json["stop_reason"] as? String {
        case "refusal":
            return .failure(.badResponse("Il modello ha rifiutato di rispondere a questo contenuto."))
        case "max_tokens":
            return .failure(.badResponse("Risposta troncata: ha superato il tetto di token in uscita. Riprova con meno materiale o meno elementi."))
        default:
            break
        }
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            return .failure(.badResponse(nil))
        }
        return .success(text)
    }

    // Estrae il primo blocco JSON da una risposta che potrebbe avere
    // recinzioni markdown o testo attorno: dal primo "{" all'ultimo "}".
    static func extractJSON(from text: String) -> String? {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last else { return nil }
        return String(text[first...last])
    }

    // MARK: - Multimodale (immagine + prompt)

    // Manda un'immagine al provider selezionato. Il modello Apple locale
    // non accetta immagini: il chiamante deve trattare il fallimento come
    // "usa Vision OCR".
    //
    // `waitsForRateLimit` separa i due usi che hanno pazienza opposta:
    // la penna magica è interattiva (meglio fallire subito e far
    // riprovare l'utente), la lettura di una nota da trenta pagine è un
    // batch (una pagina che aspetta la finestra del minuto è meglio di
    // una pagina degradata a Vision).
    // `imageMaxDimension`: 1280 basta per un ritaglio della penna magica,
    // una pagina intera di appunti fitti vuole più pixel (la risoluzione
    // sulla scrittura a mano conta: misurato con Vision, 2x→4x cambiava
    // la lettura). Chi trascrive pagine passa 2048.
    static func generate(prompt: String, image: UIImage, waitsForRateLimit: Bool = false, imageMaxDimension: CGFloat = 1280) async -> Result<String, AIServiceError> {
        switch selectedProvider {
        case .appleLocal:
            return .failure(.notConfigured("Il modello Apple locale non legge immagini."))
        case .gemini:
            return await generateWithGemini(prompt: prompt, image: image, purpose: .reading, waitsForRateLimit: waitsForRateLimit, imageMaxDimension: imageMaxDimension)
        case .claude:
            return await generateWithClaude(prompt: prompt, image: image, maxDimension: imageMaxDimension)
        }
    }

    // L'area cerchiata può essere grande (scala 2x/3x): ridimensionata a
    // un massimo ragionevole prima dell'upload — meno byte, stessa
    // leggibilità per il modello.
    private static func pngData(for image: UIImage, maxDimension: CGFloat = 1280) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height) * image.scale
        guard longest > maxDimension else { return image.pngData() }
        let ratio = maxDimension / longest
        let target = CGSize(width: size.width * image.scale * ratio, height: size.height * image.scale * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.pngData()
    }

    private static func generateWithGemini(prompt: String, image: UIImage, purpose: AIPurpose, waitsForRateLimit: Bool = false, imageMaxDimension: CGFloat = 1280) async -> Result<String, AIServiceError> {
        guard geminiKey != nil else {
            return .failure(.notConfigured("Nessuna chiave Gemini: creane una gratuita su aistudio.google.com e salvala nel Profilo."))
        }
        var lastError: AIServiceError = .badResponse(nil)
        var attemptedAny = false
        var shortestRetry: TimeInterval?

        // Come il percorso testuale: seconda passata con attesa solo se
        // il chiamante è un batch (waitsForRateLimit) e tutta la catena
        // era al limite del minuto.
        for pass in 0...1 {
            if pass == 1 {
                guard waitsForRateLimit, let wait = shortestRetry else { break }
                try? await Task.sleep(for: .seconds(min(wait, 30)))
            }
            for modelID in geminiModelChain(for: purpose) {
                if Task.isCancelled { return .failure(.cancelled) }
                // Stesso registro del percorso testuale: un modello che ha
                // finito la quota del giorno lì è finito anche qui, e uno
                // segnato sovraccarico si salta senza pagare il suo 503.
                if await GeminiModelLedger.shared.isExhausted(modelID) { continue }
                if await GeminiModelLedger.shared.isOverloaded(modelID) { continue }
                attemptedAny = true
                switch await callGemini(prompt: prompt, image: image, modelID: modelID, maxDimension: imageMaxDimension) {
                case .success(let text):
                    return .success(text)
                case .failure(let error):
                    lastError = error
                    switch error {
                    case .quotaExhausted:
                        await GeminiModelLedger.shared.markExhausted(modelID)
                    // Interattivo: si prova il prossimo modello e basta.
                    // Batch: si annota l'attesa per la seconda passata.
                    case .rateLimited(let retryAfter, _):
                        shortestRetry = min(shortestRetry ?? retryAfter, retryAfter)
                    case .modelUnavailable:
                        await GeminiModelLedger.shared.markOverloaded(modelID)
                    case .network, .notConfigured, .badResponse, .cancelled:
                        return .failure(error)
                    }
                }
            }
        }
        if !attemptedAny {
            return .failure(.quotaExhausted("Tutti i modelli hanno esaurito la quota di oggi. Si azzera a mezzanotte, fuso del Pacifico."))
        }
        return .failure(lastError)
    }

    private static func callGemini(prompt: String, image: UIImage, modelID: String, maxDimension: CGFloat = 1280) async -> Result<String, AIServiceError> {
        guard let key = geminiKey else {
            return .failure(.notConfigured("Nessuna chiave Gemini: creane una gratuita su aistudio.google.com e salvala nel Profilo."))
        }
        guard let imageData = pngData(for: image, maxDimension: maxDimension) else { return .failure(.badResponse(nil)) }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent") else {
            return .failure(.badResponse(nil))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        // Trascrivere un'immagine è "scrivi cosa vedi": il thinking non
        // aggiunge nulla e sui Flash costa 15-20s a pagina. Zero, con lo
        // stesso ritenta-senza sul 400 del percorso testuale.
        var generationConfig: [String: Any] = ["temperature": 0.1]
        let includeThinking = await GeminiModelLedger.shared.acceptsThinking(modelID)
        if includeThinking {
            generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
        }
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": ["mime_type": "image/png", "data": imageData.base64EncodedString()]]
                ]
            ]],
            "generationConfig": generationConfig
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.badResponse(nil))
        }
        request.httpBody = bodyData

        // Un'immagine pesa più del testo: stesso timeout generoso e
        // stesso passaggio al modello successivo in caso di attesa.
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.modelUnavailable("Il modello \(modelID) non ha risposto in tempo."))
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let errorObject = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
            let detail = errorObject?["message"] as? String
            let status = errorObject?["status"] as? String
            // 400 con thinkingConfig: come nel percorso testuale, si
            // segna il modello e si ritenta la stessa chiamata senza.
            if http.statusCode == 400, includeThinking {
                await GeminiModelLedger.shared.markRejectsThinking(modelID)
                return await callGemini(prompt: prompt, image: image, modelID: modelID, maxDimension: maxDimension)
            }
            // Stessa classificazione del percorso testuale: prima OGNI
            // errore HTTP diventava .network, che il chiamante tratta
            // come definitivo — quindi un 429 fermava la penna magica al
            // primo modello invece di far scendere la catena sui Lite.
            if http.statusCode == 429 || status == "RESOURCE_EXHAUSTED" {
                let limit = rateLimitInfo(from: errorObject, message: detail)
                if limit.isPerDay {
                    return .failure(.quotaExhausted(detail ?? "Quota giornaliera esaurita per questo modello."))
                }
                return .failure(.rateLimited(retryAfter: limit.retryAfter ?? 20, detail: detail ?? "Limite di richieste raggiunto, riprova tra poco."))
            }
            if http.statusCode == 404 {
                return .failure(.modelUnavailable(detail ?? "Modello non disponibile."))
            }
            // 503/500 = quel modello è sovraccarico o guasto, non la
            // rete: si prosegue sul prossimo della catena.
            if http.statusCode == 503 || http.statusCode == 500 || status == "UNAVAILABLE" || status == "INTERNAL" {
                return .failure(.modelUnavailable(detail ?? "Modello momentaneamente sovraccarico."))
            }
            return .failure(.network(detail ?? "HTTP \(http.statusCode)"))
        }
        Task { @MainActor in GeminiQuotaMeter.shared.record(modelID) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return .failure(.badResponse(nil))
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? .failure(.badResponse(nil)) : .success(text)
    }

    private static func generateWithClaude(prompt: String, image: UIImage, maxDimension: CGFloat = 1280) async -> Result<String, AIServiceError> {
        guard let key = claudeKey else {
            return .failure(.notConfigured("Nessuna chiave Anthropic configurata nel Profilo."))
        }
        guard let imageData = pngData(for: image, maxDimension: maxDimension) else { return .failure(.badResponse(nil)) }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return .failure(.badResponse(nil))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1000,
            "temperature": 0.1,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": imageData.base64EncodedString()]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.badResponse(nil))
        }
        request.httpBody = bodyData

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.badResponse(nil))
        }
        // Formato errore Anthropic: {"type":"error","error":{"message":...}} —
        // rate limit, credito esaurito, chiave non valida: il motivo reale
        // va mostrato, non un generico "formato inatteso".
        if let apiError = json["error"] as? [String: Any],
           let message = apiError["message"] as? String {
            return .failure(.network(message))
        }
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            return .failure(.badResponse(nil))
        }
        return .success(text)
    }
}
