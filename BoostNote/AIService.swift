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
    // Composizione (verificata chiamandoli davvero il 2026-08-12):
    //   gemini-flash-lite-latest  -> 3.5 Flash Lite   500/giorno
    //   gemini-3.1-flash-lite                          500/giorno
    //   gemini-flash-latest       -> 3.6 Flash          20/giorno
    //   gemini-3.5-flash                                20/giorno
    //   gemini-3-flash-preview                          20/giorno
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
    // 3.5-flash 57,9s. Quest'ultimo sta in fondo a entrambe le catene:
    // supera il timeout di rete, va toccato solo se non resta altro.
    var modelChain: [String] {
        let lite = ["gemini-flash-lite-latest", "gemini-3.1-flash-lite"]
        let capable = ["gemini-flash-latest", "gemini-3-flash-preview"]
        let slow = ["gemini-3.5-flash"]
        switch self {
        case .lite: return lite + capable + slow
        case .full: return capable + lite + slow
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

    var message: String {
        switch self {
        case .notConfigured(let what): what
        case .network(let reason): "Errore di rete: \(reason)"
        case .quotaExhausted(let reason): "Quota esaurita su tutti i modelli disponibili. \(reason)"
        case .rateLimited(_, let detail): "Troppe richieste ravvicinate: il limite è al minuto, non giornaliero. Riprova fra poco. \(detail)"
        case .modelUnavailable(let reason): "Nessun modello disponibile. \(reason)"
        case .badResponse(let detail): detail ?? "Il modello ha risposto in un formato inatteso."
        }
    }
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

    // La chiave Gemini va in Keychain (è una credenziale); quella
    // Anthropic resta dove già vive per la penna magica (AppStorage
    // "anthropicAPIKey") per non avere due fonti di verità.
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

    static var claudeKey: String? {
        let key = UserDefaults.standard.string(forKey: "anthropicAPIKey") ?? ""
        return key.isEmpty ? nil : key
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
    // che vogliono JSON lo chiedono nel prompt e validano col decoder
    // (checklist anti-allucinazione: ciò che non decodifica non si mostra).
    static func generate(prompt: String, purpose: AIPurpose = .generation, tier: GeminiModelTier? = nil) async -> Result<String, AIServiceError> {
        switch selectedProvider {
        case .appleLocal:
            return await generateWithAppleLocal(prompt: prompt)
        case .gemini:
            return await generateWithGemini(prompt: prompt, purpose: purpose, tier: tier)
        case .claude:
            return await generateWithClaude(prompt: prompt)
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
        geminiTier(for: purpose).modelChain
    }

    // Modello che ha davvero risposto per ultimo: serve alla UI per dire
    // con cosa è stato generato quando è scattato il fallback.
    private(set) static var lastUsedModelID: String?

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
        let capable = GeminiModelTier.full.modelChain.filter { !isLiteModel($0) }
        for modelID in capable where !(await DailyQuotaLedger.shared.isExhausted(modelID)) {
            return false
        }
        return true
    }

    // Modelli che hanno già risposto "quota del giorno finita". Un
    // registro condiviso serve perché i moduli di uno studio girano in
    // PARALLELO: senza, ognuno dei tre riscopre per conto suo che i primi
    // due modelli della catena sono esauriti, pagando ogni volta le
    // stesse chiamate a vuoto. È un attore e non una variabile statica
    // proprio per quel parallelismo.
    private actor DailyQuotaLedger {
        static let shared = DailyQuotaLedger()
        private var exhaustedAt: [String: Date] = [:]

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
    }

    private static func generateWithGemini(prompt: String, purpose: AIPurpose, tier: GeminiModelTier? = nil) async -> Result<String, AIServiceError> {
        guard geminiKey != nil else {
            return .failure(.notConfigured("Nessuna chiave Gemini: creane una gratuita su aistudio.google.com e salvala nel Profilo."))
        }

        let chain = tier?.modelChain ?? geminiModelChain(for: purpose)
        var lastError: AIServiceError = .badResponse(nil)
        var attemptedAny = false

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

            for modelID in chain {
                // Saltato senza nemmeno chiamare: la quota giornaliera
                // non torna aspettando qualche secondo.
                if await DailyQuotaLedger.shared.isExhausted(modelID) { continue }
                attemptedAny = true

                switch await callGemini(prompt: prompt, modelID: modelID, purpose: purpose) {
                case .success(let text):
                    lastUsedModelID = modelID
                    return .success(text)
                case .failure(let error):
                    lastError = error
                    switch error {
                    case .quotaExhausted:
                        await DailyQuotaLedger.shared.markExhausted(modelID)
                    case .rateLimited(let retryAfter, _):
                        shortestRetry = min(shortestRetry ?? retryAfter, retryAfter)
                    case .modelUnavailable:
                        break
                    // Rete o chiave sbagliata: cambiare modello non aiuta.
                    case .network, .notConfigured, .badResponse:
                        return .failure(error)
                    }
                }
            }
        }

        // Nessuna chiamata partita: erano tutti già segnati come esauriti.
        // Dirlo con la sua ragione, invece di lasciare il messaggio
        // generico dell'ultimo errore (che qui non esiste nemmeno).
        if !attemptedAny {
            return .failure(.quotaExhausted("Tutti i modelli hanno esaurito la quota di oggi. Si azzera a mezzanotte, fuso del Pacifico."))
        }
        return .failure(lastError)
    }

    // Distingue il limite al minuto dalla quota giornaliera leggendo i
    // `details` della risposta di Gemini: le violazioni portano un
    // `quotaId` che dice quale finestra è stata superata, e un `RetryInfo`
    // con l'attesa consigliata dal server.
    private struct RateLimit {
        var isPerMinute: Bool
        var retryAfter: TimeInterval?
    }

    private static func rateLimitInfo(from errorObject: [String: Any]?, message: String?) -> RateLimit {
        var isPerMinute = false
        var retryAfter: TimeInterval?

        for detail in (errorObject?["details"] as? [[String: Any]]) ?? [] {
            let type = (detail["@type"] as? String) ?? ""
            if type.contains("QuotaFailure") {
                for violation in (detail["violations"] as? [[String: Any]]) ?? [] {
                    let identifiers = [violation["quotaId"] as? String, violation["quotaMetric"] as? String]
                    if identifiers.compactMap({ $0 }).contains(where: { $0.localizedCaseInsensitiveContains("PerMinute") }) {
                        isPerMinute = true
                    }
                }
            }
            if type.contains("RetryInfo"), let delay = detail["retryDelay"] as? String {
                retryAfter = TimeInterval(delay.replacingOccurrences(of: "s", with: ""))
            }
        }
        // Alcune risposte non portano i `details`: resta il testo.
        if !isPerMinute, let message, message.localizedCaseInsensitiveContains("per minute") {
            isPerMinute = true
        }
        return RateLimit(isPerMinute: isPerMinute, retryAfter: retryAfter)
    }

    private static func callGemini(prompt: String, modelID: String, purpose: AIPurpose) async -> Result<String, AIServiceError> {
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
        // 120s e non 45: i modelli capaci — quelli che l'utente ha
        // scelto per la qualità — impiegano 10-58s misurati su prompt da
        // 21k token, e con tre richieste in parallelo il tempo cresce
        // ancora. Un timeout più corto del tempo di risposta del modello
        // non protegge da niente: fa solo fallire chiamate sane.
        request.timeoutInterval = 120

        // Temperatura bassa: compiti estrattivi/strutturati, non creativi
        // (checklist anti-allucinazione). Niente thinkingConfig: i modelli
        // flash correnti lo rifiutano con 400 "invalid argument", e il
        // parametro faceva fallire ogni generazione.
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": purpose.maxOutputTokens,
                "responseMimeType": "application/json"
            ]
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
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let errorObject = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
            let detail = errorObject?["message"] as? String
            let status = errorObject?["status"] as? String
            // 429 vuol dire DUE cose diverse, e confonderle è costato caro:
            // la quota del giorno finita (il modello va abbandonato) oppure
            // il limite al minuto (basta aspettare qualche secondo). La
            // distinzione sta nei `details` della risposta, non nel codice.
            if http.statusCode == 429 || status == "RESOURCE_EXHAUSTED" {
                let limit = rateLimitInfo(from: errorObject, message: detail)
                if limit.isPerMinute {
                    return .failure(.rateLimited(
                        retryAfter: limit.retryAfter ?? 20,
                        detail: detail ?? "Limite di richieste al minuto."
                    ))
                }
                return .failure(.quotaExhausted(detail ?? "Quota giornaliera esaurita per questo modello."))
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
        return text.isEmpty ? .failure(.badResponse(reason(for: finishReason))) : .success(text)
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

    private static func generateWithClaude(prompt: String) async -> Result<String, AIServiceError> {
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
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 3000,
            "temperature": 0.2,
            "messages": [["role": "user", "content": prompt]]
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

    // Estrae il primo blocco JSON da una risposta che potrebbe avere
    // recinzioni markdown o testo attorno: dal primo "{" all'ultimo "}".
    static func extractJSON(from text: String) -> String? {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last else { return nil }
        return String(text[first...last])
    }

    // MARK: - Multimodale (immagine + prompt)

    // Manda un'immagine (es. l'area cerchiata dalla penna magica) al
    // provider selezionato. Il modello Apple locale non accetta immagini:
    // il chiamante deve trattare il fallimento come "usa Vision OCR".
    static func generate(prompt: String, image: UIImage) async -> Result<String, AIServiceError> {
        switch selectedProvider {
        case .appleLocal:
            return .failure(.notConfigured("Il modello Apple locale non legge immagini."))
        case .gemini:
            return await generateWithGemini(prompt: prompt, image: image, purpose: .reading)
        case .claude:
            return await generateWithClaude(prompt: prompt, image: image)
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

    private static func generateWithGemini(prompt: String, image: UIImage, purpose: AIPurpose) async -> Result<String, AIServiceError> {
        guard geminiKey != nil else {
            return .failure(.notConfigured("Nessuna chiave Gemini: creane una gratuita su aistudio.google.com e salvala nel Profilo."))
        }
        var lastError: AIServiceError = .badResponse(nil)
        var attemptedAny = false
        for modelID in geminiModelChain(for: purpose) {
            // Stesso registro del percorso testuale: un modello che ha
            // finito la quota del giorno lì è finito anche qui.
            if await DailyQuotaLedger.shared.isExhausted(modelID) { continue }
            attemptedAny = true
            switch await callGemini(prompt: prompt, image: image, modelID: modelID) {
            case .success(let text):
                lastUsedModelID = modelID
                return .success(text)
            case .failure(let error):
                lastError = error
                switch error {
                case .quotaExhausted:
                    await DailyQuotaLedger.shared.markExhausted(modelID)
                // La penna magica è interattiva: meglio fallire subito e
                // far riprovare l'utente che tenerlo fermo ad aspettare
                // la finestra del minuto.
                case .rateLimited, .modelUnavailable:
                    break
                case .network, .notConfigured, .badResponse:
                    return .failure(error)
                }
            }
        }
        if !attemptedAny {
            return .failure(.quotaExhausted("Tutti i modelli hanno esaurito la quota di oggi. Si azzera a mezzanotte, fuso del Pacifico."))
        }
        return .failure(lastError)
    }

    private static func callGemini(prompt: String, image: UIImage, modelID: String) async -> Result<String, AIServiceError> {
        guard let key = geminiKey else {
            return .failure(.notConfigured("Nessuna chiave Gemini: creane una gratuita su aistudio.google.com e salvala nel Profilo."))
        }
        guard let imageData = pngData(for: image) else { return .failure(.badResponse(nil)) }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent") else {
            return .failure(.badResponse(nil))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": ["mime_type": "image/png", "data": imageData.base64EncodedString()]]
                ]
            ]],
            "generationConfig": ["temperature": 0.1]
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
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let errorObject = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
            let detail = errorObject?["message"] as? String
            let status = errorObject?["status"] as? String
            // Stessa classificazione del percorso testuale: prima OGNI
            // errore HTTP diventava .network, che il chiamante tratta
            // come definitivo — quindi un 429 fermava la penna magica al
            // primo modello invece di far scendere la catena sui Lite.
            if http.statusCode == 429 || status == "RESOURCE_EXHAUSTED" {
                let limit = rateLimitInfo(from: errorObject, message: detail)
                if limit.isPerMinute {
                    return .failure(.rateLimited(retryAfter: limit.retryAfter ?? 20, detail: detail ?? "Limite di richieste al minuto."))
                }
                return .failure(.quotaExhausted(detail ?? "Quota giornaliera esaurita per questo modello."))
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
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return .failure(.badResponse(nil))
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? .failure(.badResponse(nil)) : .success(text)
    }

    private static func generateWithClaude(prompt: String, image: UIImage) async -> Result<String, AIServiceError> {
        guard let key = claudeKey else {
            return .failure(.notConfigured("Nessuna chiave Anthropic configurata nel Profilo."))
        }
        guard let imageData = pngData(for: image) else { return .failure(.badResponse(nil)) }
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
