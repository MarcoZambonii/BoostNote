import UIKit
import Vision

// Riconoscimento del testo scritto a mano nell'area cerchiata (Vision,
// on-device), la query a Wolfram Alpha e i prompt delle azioni della
// penna magica. Le chiamate ai modelli passano tutte da AIService, che
// conosce il provider scelto dall'utente e i suoi errori reali.

// Errore con messaggio leggibile (quota, chiave, rete...): Result vuole
// un tipo Error, una String nuda non basta.
struct ServiceFailure: Error {
    let message: String
}

// Continuation che si riprende UNA volta sola, qualunque cosa succeda.
//
// Serve ai wrapper di Vision: `handler.perform` è sincrono e può LANCIARE
// senza aver mai chiamato il completion della richiesta — con il vecchio
// `try?` la continuation restava sospesa per sempre e chi aspettava
// (estrazione materiali, penna magica) si appendeva senza uscita. Ma può
// anche succedere il contrario: completion chiamato CON errore e perform
// che rilancia lo stesso errore — riprendere due volte è un crash. Le due
// chiamate avvengono in sequenza sullo stesso thread, quindi basta il
// flag, senza lock.
final class OneShotContinuation<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

enum MagicPenService {
    static func recognizeText(in image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            let resume = OneShotContinuation(continuation)
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    resume.resume(nil)
                    return
                }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                resume.resume(text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            // Senza recognitionLanguages, Vision usa di default il solo
            // inglese: scrittura in italiano (per "Spiega"/"Cerca") veniva
            // riconosciuta peggio.
            request.recognitionLanguages = ["it-IT", "en-US"]
            request.automaticallyDetectsLanguage = true

            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    resume.resume(nil)
                }
            }
        }
    }

    // In caso di fallimento restituisce il MOTIVO reale (quota esaurita,
    // chiave non valida, errore di rete...) invece di un nil muto: il
    // generico "non ha risposto" non permetteva di capire cosa sistemare.
    static func queryWolfram(text: String, appID: String) async -> Result<WolframResult, ServiceFailure> {
        // .urlQueryAllowed non esclude "+", "&", "=" — validi in un URL ma
        // con significato speciale come delimitatori di query string: un
        // "+" in un'espressione (comunissimo in matematica, es. "2+2")
        // veniva interpretato come uno spazio, rompendo la query. Con
        // URLComponents/URLQueryItem la codifica per-parametro è corretta.
        //
        // format=plaintext da solo escludeva del tutto i pod puramente
        // visivi (diagramma di Bode, grafici, circuiti...): per quei pod
        // Wolfram non ha un plaintext significativo, quindi sparivano
        // senza errore. "image" li fa arrivare come URL di immagine.
        var components = URLComponents(string: "https://api.wolframalpha.com/v2/query")
        components?.queryItems = [
            URLQueryItem(name: "input", value: text),
            URLQueryItem(name: "appid", value: appID),
            URLQueryItem(name: "format", value: "plaintext,image"),
            URLQueryItem(name: "output", value: "XML")
        ]
        // URLComponents NON codifica il "+" (per RFC è lecito in query),
        // ma il server lo decodifica come SPAZIO: "1/(s^2 + 1)" arrivava
        // come "1/(s^2 1)" e Wolfram leggeva la giustapposizione come
        // moltiplicazione (s^2 × 1). Gli spazi veri sono già %20, quindi
        // ogni "+" rimasto è un più matematico: va forzato a %2B.
        let encodedQuery = components?.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        guard let url = components?.url else { return .failure(ServiceFailure(message: "Indirizzo non valido.")) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            return .failure(ServiceFailure(message: "Errore di rete: \(error.localizedDescription)"))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Gli errori di quota/abuso arrivano spesso come corpo di
            // testo semplice (es. "Error 10: Exceeded maximum ...").
            let bodyText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let bodyText, !bodyText.isEmpty, bodyText.count < 300, !bodyText.hasPrefix("<") {
                return .failure(ServiceFailure(message: bodyText))
            }
            return .failure(ServiceFailure(message: "Il server ha risposto HTTP \(http.statusCode)."))
        }
        return WolframPodParser.parse(data)
    }

    // Il pannello dei risultati compone Markdown + LaTeX (KaTeX): senza
    // dirlo al modello, la risposta arriva in testo piatto e il
    // renderizzatore non ha niente da comporre.
    static func explainPrompt(for text: String) -> String {
        """
        Spiega in modo semplice, breve e passo passo questo appunto scritto a mano \
        (il testo arriva da riconoscimento ottico e può contenere errori).
        Formatta la risposta in Markdown: grassetti per i termini chiave, elenchi \
        puntati o numerati per i passaggi. Scrivi OGNI formula o simbolo matematico \
        in LaTeX tra $ … $ se in linea e tra $$ … $$ se su riga a sé. \
        Non usare mai blocchi di codice per la matematica.

        Appunto: \(text)
        """
    }

    static func searchURL(for text: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        // Stesso problema del "+" di queryWolfram: senza questo, un "+"
        // nell'espressione cercata diventa uno spazio.
        let encodedQuery = components?.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url
    }

    // Il risultato finisce in KaTeX in modalità "solo formula": i
    // delimitatori $ arriverebbero fino al compositore come simboli.
    static func latexPrompt(for text: String) -> String {
        "Converti questa espressione matematica scritta a mano (arriva da riconoscimento ottico e può contenere errori) in codice LaTeX valido. Rispondi SOLO con il codice LaTeX, niente delimitatori $ o $$, niente spiegazioni, niente blocchi di codice: \(text)"
    }

    // I modelli incartano volentieri la formula in ```latex … ``` o tra $
    // nonostante il prompt: KaTeX li mostrerebbe come caratteri veri.
    static func cleanLaTeX(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: .newlines)
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for fence in ["$$", "$"] where text.hasPrefix(fence) && text.hasSuffix(fence) && text.count > fence.count * 2 {
            text = String(text.dropFirst(fence.count).dropLast(fence.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return text
    }
}

// Risultato di una query Wolfram: testo (pod con plaintext) e immagini
// (pod puramente visivi — diagrammi di Bode, grafici, plot, circuiti —
// che non hanno un equivalente testuale sensato).
struct WolframResult {
    var text: String?
    var imageURLs: [URL] = []
    // I pod separati, oltre al riassunto concatenato: chi mostra tutto
    // (penna magica, pannello Wolfram) usa `text`, chi deve mostrare UN
    // risultato solo — la verifica di un esercizio — sceglie il pod giusto
    // invece di appiccicare insieme cose che sembrano contraddirsi.
    var pods: [WolframPod] = []

    // Il pod che risponde davvero alla domanda. Wolfram ne restituisce
    // molti e non in ordine di utilità: per "integrate ... from 0 to y"
    // arrivano sia l'integrale definito (quello che serve) sia quello
    // indefinito, che a colpo d'occhio sembra un risultato diverso.
    var primaryPod: WolframPod? {
        let preferred = ["definite integral", "result", "exact result", "decimal approximation",
                         "value", "solution", "derivative", "limit", "sum"]
        for key in preferred {
            if let match = pods.first(where: { $0.title.lowercased().contains(key) }) { return match }
        }
        // Mai il pod di input: ripete la domanda, non la risponde.
        return pods.first { !$0.title.lowercased().contains("input") } ?? pods.first
    }
}

struct WolframPod: Identifiable {
    var id: String { title }
    var title: String
    var text: String
}

// Estrae i pod testuali E le immagini dalla risposta XML di Wolfram Alpha
// (Full Results API), oppure il messaggio d'errore dell'API (chiave non
// valida, quota mensile esaurita...) che arriva come <error><msg>.
private enum WolframPodParser {
    static func parse(_ data: Data) -> Result<WolframResult, ServiceFailure> {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        if delegate.summary.isEmpty && delegate.imageURLs.isEmpty {
            if let apiError = delegate.errorMessage, !apiError.isEmpty {
                return .failure(ServiceFailure(message: apiError))
            }
            if !delegate.success {
                return .failure(ServiceFailure(message: "Wolfram Alpha non ha capito l'espressione. Prova a correggerla o a scrivere più chiaro."))
            }
            return .failure(ServiceFailure(message: "Wolfram Alpha ha risposto senza contenuti."))
        }
        return .success(WolframResult(
            text: delegate.summary.isEmpty ? nil : delegate.summary,
            imageURLs: delegate.imageURLs,
            pods: delegate.pods
        ))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var summary = ""
        var pods: [WolframPod] = []
        var imageURLs: [URL] = []
        var errorMessage: String?
        var success = true
        private var currentElement = ""
        private var currentPodTitle = ""
        private var currentPlaintext = ""
        private var currentErrorMsg = ""
        private var insideError = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            currentElement = elementName
            if elementName == "queryresult", attributeDict["success"] == "false" {
                success = false
            }
            if elementName == "error" { insideError = true }
            if elementName == "pod" {
                currentPodTitle = attributeDict["title"] ?? ""
            }
            // Un pod con solo immagine ha plaintext vuoto o assente: senza
            // questo, un diagramma di Bode o un plot sparivano del tutto.
            if elementName == "img", let src = attributeDict["src"], let url = URL(string: src) {
                imageURLs.append(url)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if currentElement == "plaintext" {
                currentPlaintext += string
            }
            if insideError, currentElement == "msg" {
                currentErrorMsg += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "plaintext" {
                let trimmed = currentPlaintext.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pods.append(WolframPod(title: currentPodTitle, text: trimmed))
                    if !summary.isEmpty { summary += "\n\n" }
                    summary += currentPodTitle.isEmpty ? trimmed : "\(currentPodTitle): \(trimmed)"
                }
                currentPlaintext = ""
            }
            if elementName == "error" {
                insideError = false
                let trimmed = currentErrorMsg.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { errorMessage = trimmed }
                currentErrorMsg = ""
            }
        }
    }
}
