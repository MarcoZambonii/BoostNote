import Foundation
import UIKit
import WebKit

// Esito di una compilazione. La distinzione NON è cosmetica: un TeX che
// non compila è un fatto del CONTENUTO e va ricordato (non si ritenta a
// ogni apparizione della card), mentre un motore non disponibile è un
// fatto NOSTRO e non deve marcare la figura come rotta — altrimenti una
// webview che non parte una volta condanna per sempre una figura sana.
enum TikZCompileOutcome {
    case compiled(String)
    // Il sorgente non compila: esito definitivo, si può ricordare.
    case texFailed
    // Motore non disponibile (pagina non caricata, processo web morto,
    // richiesta appesa): transitorio, NON va ricordato.
    case unavailable
}

// Compila sorgenti TikZ in SVG con TikZJax: il motore TeX vero compilato
// in WebAssembly, impacchettato nell'app (BoostNote/TikZJax) — offline e
// gratis, come KaTeX. Pacchetti inclusi nel build: tikz, pgfplots,
// automata (catene di Markov), positioning, arrows, matrix, calc — e
// anche circuitikz, che nei tex_files del bundle c'è davvero.
//
// La COMPILAZIONE è il quality gate delle figure: se il TeX del modello
// non compila, la figura semplicemente non esiste — mai un disegno rotto
// sullo schermo, stesso principio del "ciò che non decodifica non si
// mostra".
//
// Una sola WKWebView riusata per tutte le compilazioni: il primo avvio
// del motore costa secondi, i successivi no. Le richieste sono
// serializzate (il worker TeX è uno).
@MainActor
final class TikZCompiler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = TikZCompiler()

    // Rete di sicurezza SOPRA il timeout di 45s che vive nel JS: copre i
    // casi in cui il JS non risponde affatto (processo web ucciso per
    // memoria, pagina mai eseguita). Senza, la continuation restava
    // sospesa, `busy` non tornava mai false e la coda si bloccava per
    // TUTTE le figure successive.
    private static let jobTimeout: TimeInterval = 75

    private var webView: WKWebView?
    private var pageLoaded = false
    private var pendingLoad: [CheckedContinuation<Bool, Never>] = []
    private var inFlight: [String: CheckedContinuation<TikZCompileOutcome, Never>] = [:]
    private var watchdogs: [String: Task<Void, Never>] = [:]
    // Un solo texify per volta: il worker è unico e la libreria accoda,
    // ma serializzare qui rende i timeout onesti (non contano l'attesa
    // in coda di qualcun altro).
    private var queue: [() -> Void] = []
    private var busy = false

    // SVG per sorgente già compilato in questa sessione: la persistenza
    // vera sta nel payload dell'esercizio, questa evita solo i doppioni
    // nella stessa schermata.
    private var sessionCache: [String: String] = [:]

    func compile(_ tikz: String) async -> TikZCompileOutcome {
        let source = Self.normalized(tikz)
        guard !source.isEmpty else { return .texFailed }
        if let cached = sessionCache[source] {
            return cached.isEmpty ? .texFailed : .compiled(cached)
        }

        guard await ensureReady() else { return .unavailable }

        let result: TikZCompileOutcome = await withCheckedContinuation { continuation in
            let job = { [weak self] in
                guard let self, let webView = self.webView else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                let requestID = UUID().uuidString
                self.inFlight[requestID] = continuation
                self.startWatchdog(for: requestID)
                guard let sourceJSON = try? String(data: JSONEncoder().encode(source), encoding: .utf8),
                      let idJSON = try? String(data: JSONEncoder().encode(requestID), encoding: .utf8) else {
                    self.settle(requestID, with: .unavailable)
                    return
                }
                webView.evaluateJavaScript("compileTikz(\(sourceJSON), \(idJSON))") { _, error in
                    if error != nil { self.settle(requestID, with: .unavailable) }
                }
            }
            enqueue(job)
        }
        // Si ricorda SOLO l'esito definitivo. Un motore non disponibile
        // non lascia traccia: alla prossima apparizione si ritenta, ed è
        // ciò che distingue una figura rotta da una webview non pronta.
        switch result {
        case .compiled(let svg): sessionCache[source] = svg
        case .texFailed: sessionCache[source] = ""
        case .unavailable: break
        }
        return result
    }

    // Il sorgente del modello arriva in forme varie: solo l'ambiente
    // tikzpicture, oppure con \begin{document}, oppure recintato in
    // markdown. Questo build di TikZJax (fork ww/Obsidian) esige il
    // corpo COMPLETO con \begin{document}: senza, TeX abortisce muto e
    // l'unico sintomo è "Could not find file input.dvi" (pagato una
    // volta, in test). Qui si garantisce la forma giusta qualunque cosa
    // arrivi.
    static func normalized(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        // Recinzioni markdown, se il modello le ha messe nonostante tutto.
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: .newlines)
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // \documentclass non serve e può solo dare fastidio.
        text = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("\\documentclass") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.contains("\\begin{document}") else { return text }

        // Preambolo (\usepackage, \usetikzlibrary, \pgfplotsset) fuori,
        // tutto il resto dentro il documento.
        var preamble: [String] = []
        var body: [String] = []
        var inBody = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inBody, trimmed.hasPrefix("\\usepackage") || trimmed.hasPrefix("\\usetikzlibrary") || trimmed.hasPrefix("\\pgfplotsset") {
                preamble.append(line)
            } else {
                if !trimmed.isEmpty { inBody = true }
                body.append(line)
            }
        }
        let head = preamble.isEmpty ? "" : preamble.joined(separator: "\n") + "\n"
        return head + "\\begin{document}\n" + body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n\\end{document}"
    }

    // MARK: - Infrastruttura webview

    private func ensureReady() async -> Bool {
        if pageLoaded { return true }
        if webView == nil { setUpWebView() }
        return await withCheckedContinuation { continuation in
            if pageLoaded { continuation.resume(returning: true); return }
            pendingLoad.append(continuation)
        }
    }

    private func setUpWebView() {
        let controller = WKUserContentController()
        controller.add(self, name: "tikzHandler")
        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.isOpaque = false
        view.navigationDelegate = self
        // Stessa regola di LaTeXImageRenderer: la vista deve stare in una
        // finestra con alpha piena perché WebKit la consideri viva.
        let host = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        view.frame.origin = CGPoint(x: -7000, y: -7000)
        view.isUserInteractionEnabled = false
        host?.insertSubview(view, at: 0)
        webView = view

        if let url = Bundle.main.url(forResource: "tikz-template", withExtension: "html", subdirectory: "TikZJax")
            ?? Bundle.main.url(forResource: "tikz-template", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // Risorse mancanti dal bundle: nessuno chiamerà mai i
            // delegate, quindi va chiuso qui o si aspetta per sempre.
            tearDownEngine()
        }
    }

    // Butta il motore e sblocca tutti gli in attesa. La webview NON viene
    // ricreata qui: la ricrea il prossimo `ensureReady()`, così un
    // fallimento non si trascina dietro un ciclo di ricostruzioni a vuoto
    // ma nemmeno condanna la sessione — era il difetto di prima: pagina
    // non caricata = attesa infinita, spinner "Preparo la figura…" per
    // sempre e coda ferma.
    private func tearDownEngine() {
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "tikzHandler")
        webView?.removeFromSuperview()
        webView = nil
        pageLoaded = false

        let waiting = pendingLoad
        pendingLoad.removeAll()
        waiting.forEach { $0.resume(returning: false) }

        let pending = inFlight
        inFlight.removeAll()
        watchdogs.values.forEach { $0.cancel() }
        watchdogs.removeAll()
        pending.values.forEach { $0.resume(returning: .unavailable) }
        // La coda riparte: senza, un motore morto fermava per sempre
        // tutte le figure successive.
        busy = false
        drainIfIdle()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        pendingLoad.forEach { $0.resume(returning: true) }
        pendingLoad.removeAll()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tearDownEngine()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tearDownEngine()
    }

    // Il processo di contenuto è morto (tipicamente memoria: qui dentro
    // girano ~7 MB di JS più il WASM di TeX). Senza questo, il messaggio
    // di ritorno non arriva MAI e la coda resta bloccata.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tearDownEngine()
    }

    private func startWatchdog(for requestID: String) {
        watchdogs[requestID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.jobTimeout))
            guard !Task.isCancelled, let self else { return }
            // Se siamo ancora qui, il motore non ha risposto nemmeno col
            // suo timeout interno: si considera morto e si riparte
            // pulito al prossimo tentativo.
            if self.inFlight[requestID] != nil { self.tearDownEngine() }
        }
    }

    // Chiude UNA richiesta, sempre una volta sola, e fa avanzare la coda.
    private func settle(_ requestID: String, with outcome: TikZCompileOutcome) {
        watchdogs.removeValue(forKey: requestID)?.cancel()
        guard let continuation = inFlight.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: outcome)
        finishJob()
    }

    private func enqueue(_ job: @escaping () -> Void) {
        queue.append(job)
        drainIfIdle()
    }

    private func drainIfIdle() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        job()
    }

    private func finishJob() {
        busy = false
        drainIfIdle()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let requestID = body["id"] as? String else { return }
        let ok = body["ok"] as? Bool ?? false
        let svg = body["svg"] as? String ?? ""
        if ok, !svg.isEmpty {
            settle(requestID, with: .compiled(svg))
            return
        }
        // Il JS dice PERCHÉ ha fallito: "compile-error"/"no-svg" sono il
        // TeX (definitivo), "timeout" è il motore appeso (transitorio).
        let reason = body["error"] as? String ?? ""
        settle(requestID, with: reason == "timeout" ? .unavailable : .texFailed)
    }
}
