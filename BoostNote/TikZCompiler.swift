import Foundation
import UIKit
import WebKit

// Compila sorgenti TikZ in SVG con TikZJax: il motore TeX vero compilato
// in WebAssembly, impacchettato nell'app (BoostNote/TikZJax) — offline e
// gratis, come KaTeX. Pacchetti inclusi nel build: tikz, pgfplots,
// automata (catene di Markov), positioning, arrows, matrix, calc.
// circuitikz NON c'è: richiederebbe di ricompilare il motore coi suoi
// sorgenti (nota in backlog).
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

    private var webView: WKWebView?
    private var pageLoaded = false
    private var pendingLoad: [CheckedContinuation<Bool, Never>] = []
    private var inFlight: [String: CheckedContinuation<String?, Never>] = [:]
    // Un solo texify per volta: il worker è unico e la libreria accoda,
    // ma serializzare qui rende i timeout onesti (non contano l'attesa
    // in coda di qualcun altro).
    private var queue: [() -> Void] = []
    private var busy = false

    // SVG per sorgente già compilato in questa sessione: la persistenza
    // vera sta nel payload dell'esercizio, questa evita solo i doppioni
    // nella stessa schermata.
    private var sessionCache: [String: String] = [:]

    func compile(_ tikz: String) async -> String? {
        let source = Self.normalized(tikz)
        guard !source.isEmpty else { return nil }
        if let cached = sessionCache[source] { return cached.isEmpty ? nil : cached }

        guard await ensureReady() else { return nil }

        let result: String? = await withCheckedContinuation { continuation in
            let job = { [weak self] in
                guard let self, let webView = self.webView else {
                    continuation.resume(returning: nil)
                    return
                }
                let requestID = UUID().uuidString
                self.inFlight[requestID] = continuation
                guard let sourceJSON = try? String(data: JSONEncoder().encode(source), encoding: .utf8),
                      let idJSON = try? String(data: JSONEncoder().encode(requestID), encoding: .utf8) else {
                    self.inFlight.removeValue(forKey: requestID)
                    continuation.resume(returning: nil)
                    return
                }
                webView.evaluateJavaScript("compileTikz(\(sourceJSON), \(idJSON))") { _, error in
                    if error != nil, let waiting = self.inFlight.removeValue(forKey: requestID) {
                        waiting.resume(returning: nil)
                        self.finishJob()
                    }
                }
            }
            enqueue(job)
        }
        // Anche il fallimento si ricorda (stringa vuota): un TeX che non
        // compila non va ritentato a ogni apparizione della card.
        sessionCache[source] = result ?? ""
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
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        pendingLoad.forEach { $0.resume(returning: true) }
        pendingLoad.removeAll()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pendingLoad.forEach { $0.resume(returning: false) }
        pendingLoad.removeAll()
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
              let requestID = body["id"] as? String,
              let continuation = inFlight.removeValue(forKey: requestID) else { return }
        let ok = body["ok"] as? Bool ?? false
        let svg = body["svg"] as? String ?? ""
        if ok, !svg.isEmpty {
            continuation.resume(returning: svg)
        } else {
            continuation.resume(returning: nil)
        }
        finishJob()
    }
}
