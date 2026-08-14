import SwiftUI
import WebKit

// Converte la notazione lineare del riconoscimento ("sqrt(x)", "sin x",
// "pi", "e^(2x)") nel LaTeX che Desmos si aspetta.
//
// Regola presa dalla documentazione Desmos (API v1.10, setExpression):
// "any multi-character symbol must be preceded by a leading backslash,
// otherwise it will be interpreted as a series of single-letter
// variables". Quindi non basta sqrt: senza backslash "sin(x)" diventa
// il prodotto s·i·n·(x), e "pi" diventa p·i. Gli esponenti di più
// caratteri vogliono le graffe ("e^{2x}", non "e^2x").
enum DesmosLatex {
    // Ordine importante solo per il match su prefisso (es. "sinx"):
    // i nomi più lunghi vanno provati per primi.
    private static let functions = [
        "arcsinh", "arccosh", "arctanh",
        "arcsin", "arccos", "arctan", "arccot", "arcsec", "arccsc",
        "sinh", "cosh", "tanh", "coth", "sech", "csch",
        "sin", "cos", "tan", "cot", "sec", "csc",
        "log", "ln", "exp", "sqrt", "cbrt", "abs",
        "floor", "ceil", "round", "sign", "mod",
        "gcd", "lcm", "mean", "median", "min", "max", "total", "stdev"
    ]

    private static let symbols: [String: String] = [
        "pi": "\\pi", "tau": "\\tau", "theta": "\\theta", "alpha": "\\alpha",
        "beta": "\\beta", "gamma": "\\gamma", "delta": "\\delta",
        "epsilon": "\\epsilon", "zeta": "\\zeta", "eta": "\\eta",
        "lambda": "\\lambda", "mu": "\\mu", "nu": "\\nu", "xi": "\\xi",
        "rho": "\\rho", "sigma": "\\sigma", "phi": "\\phi", "chi": "\\chi",
        "psi": "\\psi", "omega": "\\omega",
        "infinity": "\\infty", "infty": "\\infty", "inf": "\\infty"
    ]

    static func convert(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        // Già LaTeX (tipicamente dall'azione "Genera LaTeX" della penna
        // magica): riconvertirlo lo rovinerebbe.
        guard !trimmed.contains("\\") else { return trimmed }
        return process(Array(trimmed))
    }

    private static func process(_ chars: [Character]) -> String {
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]

            if c.isLetter {
                var end = i
                while end < chars.count, chars[end].isLetter { end += 1 }
                var run = String(chars[i..<end])
                var next = end
                // "sinx" scritto senza spazio: stacca la funzione e lascia
                // il resto al giro successivo.
                if symbols[run] == nil, !functions.contains(run),
                   let fn = functions.first(where: { run.hasPrefix($0) && run.count > $0.count }) {
                    next = i + fn.count
                    run = fn
                }
                i = next
                out += emit(run, chars, &i)
                continue
            }

            if c == "^" {
                out += "^{" + process(Array(readExponent(chars, &i))) + "}"
                continue
            }

            // Operatori che in LaTeX hanno un nome proprio.
            if c == "*" { out += "\\cdot "; i += 1; continue }
            if i + 1 < chars.count {
                let pair = String(chars[i...i + 1])
                if pair == "<=" { out += "\\le "; i += 2; continue }
                if pair == ">=" { out += "\\ge "; i += 2; continue }
                if pair == "!=" { out += "\\ne "; i += 2; continue }
            }

            out += String(c)
            i += 1
        }
        return out
    }

    // Emette un identificatore già isolato: funzione, costante greca, o
    // semplice prodotto di variabili (che è proprio ciò che Desmos
    // intende leggendo più lettere di fila, quindi si lascia com'è).
    private static func emit(_ run: String, _ chars: [Character], _ i: inout Int) -> String {
        // Un comando LaTeX attaccato a una lettera diventa un comando
        // diverso e inesistente ("\sin" + "x" = "\sinx"): serve uno spazio
        // solo quando segue davvero una lettera.
        let separator = (i < chars.count && chars[i].isLetter) ? " " : ""
        if let symbol = symbols[run] { return symbol + separator }
        guard functions.contains(run) else { return run }

        switch run {
        case "sqrt":
            return "\\sqrt{" + process(Array(readArgument(chars, &i))) + "}"
        case "cbrt":
            return "\\sqrt[3]{" + process(Array(readArgument(chars, &i))) + "}"
        case "abs":
            // Desmos non ha \abs: le barre vanno scritte esplicitamente.
            return "\\left|" + process(Array(readArgument(chars, &i))) + "\\right|"
        case "exp":
            return "e^{" + process(Array(readArgument(chars, &i))) + "}"
        default:
            // Le parentesi dell'argomento restano dove sono: \sin(x) è
            // già corretto per Desmos.
            return "\\" + run + separator
        }
    }

    // Argomento di una funzione: gruppo tra parentesi bilanciate (senza
    // le parentesi) oppure il token successivo ("sqrt 2", "sqrt x").
    private static func readArgument(_ chars: [Character], _ i: inout Int) -> String {
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count else { return "" }
        if chars[i] == "(" { return readBalancedGroup(chars, &i) }
        var end = i
        while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "." { end += 1 }
        let token = String(chars[i..<end])
        i = end
        return token
    }

    // Esponente: gruppo tra parentesi, oppure la sequenza alfanumerica
    // (con eventuale segno) che segue. Sempre racchiuso in graffe dal
    // chiamante, così "x^10" non diventa "x^1 0".
    private static func readExponent(_ chars: [Character], _ i: inout Int) -> String {
        i += 1 // consuma "^"
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count else { return "" }
        if chars[i] == "(" { return readBalancedGroup(chars, &i) }
        var end = i
        if chars[end] == "-" || chars[end] == "+" { end += 1 }
        while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "." { end += 1 }
        let token = String(chars[i..<end])
        i = end
        return token
    }

    // Contenuto di una coppia di parentesi bilanciate, parentesi escluse.
    private static func readBalancedGroup(_ chars: [Character], _ i: inout Int) -> String {
        var depth = 0
        let start = i
        while i < chars.count {
            if chars[i] == "(" { depth += 1 }
            if chars[i] == ")" {
                depth -= 1
                if depth == 0 {
                    let inner = String(chars[(start + 1)..<i])
                    i += 1
                    return inner
                }
            }
            i += 1
        }
        // Parentesi non chiusa: si prende tutto il resto.
        return String(chars[(start + 1)...].prefix(chars.count))
    }
}

// MARK: - Desmos (webview, online)
// La calcolatrice grafica di riferimento: massima potenza (disequazioni,
// funzioni implicite, slider...) al costo di richiedere la rete.

// Stato del caricamento, mostrato nel pannello: prima c'era solo una
// scritta fissa "richiede internet" che sembrava un errore anche quando
// tutto andava — e quando qualcosa andava storto davvero non diceva né
// cosa né come riprovare.
enum DesmosStatus: Equatable {
    case loading
    case ready
    case failed(String)
}

struct DesmosGraphView: UIViewRepresentable {
    var expressions: [String]
    @Binding var status: DesmosStatus
    // Incrementato dal pulsante Riprova: ricarica la pagina da zero.
    var reloadToken: Int = 0

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.navigationDelegate = context.coordinator
        context.coordinator.pendingExpressions = expressions
        context.coordinator.onStatus = { status = $0 }
        context.coordinator.load(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onStatus = { status = $0 }
        context.coordinator.pendingExpressions = expressions
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.load(into: webView)
        } else {
            context.coordinator.push(to: webView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var pendingExpressions: [String] = []
        var onStatus: ((DesmosStatus) -> Void)?
        var lastReloadToken = 0
        private var isLoaded = false

        func load(into webView: WKWebView) {
            isLoaded = false
            onStatus?(.loading)
            // Il ResizeObserver è la parte importante: il pannello laterale
            // tiene le viste vive a larghezza ZERO quando è chiuso, e un
            // Desmos inizializzato in un div 0×0 disegnava nel nulla senza
            // mai riprendersi. Così invece si ridimensiona da solo appena
            // il pannello si apre.
            let html = """
            <!DOCTYPE html><html><head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
            <style>html,body,#calc{margin:0;padding:0;width:100%;height:100%;}</style>
            <!-- ATTENZIONE PRIMA DELLA PUBBLICAZIONE: questa è la chiave
                 DEMO di Desmos (quella degli esempi della documentazione),
                 ammessa solo in sviluppo. Per l'App Store va sostituita
                 con una chiave propria, gratuita, da desmos.com/my-api —
                 la demo è condivisa da tutti e Desmos può revocarla in
                 qualunque momento, spegnendo il pannello per ogni utente. -->
            <script src="https://www.desmos.com/api/v1.10/calculator.js?apiKey=6082933e64ed490ea87245e7a3df87fb"></script>
            </head><body>
            <div id="calc"></div>
            <script>
              var calculator = null;
              if (window.Desmos) {
                calculator = Desmos.GraphingCalculator(document.getElementById('calc'), {
                  expressions: true, settingsMenu: false, zoomButtons: true, lockViewport: false
                });
                new ResizeObserver(function () {
                  if (calculator) { calculator.resize(); }
                }).observe(document.getElementById('calc'));
              }
              function setExpressions(list) {
                if (!calculator) { return false; }
                calculator.setBlank();
                list.forEach(function(latex, index) {
                  calculator.setExpression({ id: 'e' + index, latex: latex });
                });
                return true;
              }
            </script>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: URL(string: "https://www.desmos.com"))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            // La pagina è arrivata, ma Desmos c'è davvero? Se lo script
            // esterno non si è caricato (rete assente, bloccata, lenta),
            // window.Desmos non esiste: È QUELLO il "non funziona".
            webView.evaluateJavaScript("window.Desmos !== undefined") { [weak self] result, _ in
                if (result as? Bool) == true {
                    self?.onStatus?(.ready)
                    self?.push(to: webView)
                } else {
                    self?.onStatus?(.failed("Il modulo Desmos non si è scaricato: controlla la connessione e riprova."))
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onStatus?(.failed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onStatus?(.failed(error.localizedDescription))
        }

        func push(to webView: WKWebView) {
            guard isLoaded,
                  let data = try? JSONEncoder().encode(pendingExpressions),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("setExpressions(\(json))")
        }
    }
}
