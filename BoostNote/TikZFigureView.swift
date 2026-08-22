import SwiftUI
import WebKit

// La figura TikZ di un esercizio: compila alla prima visualizzazione
// (TikZJax, offline) e riferisce l'SVG al chiamante perché lo persista
// nel payload — dalla volta dopo si mostra e basta, zero ricompilazioni.
//
// Contratto onesto: se il TeX non compila, la figura non si mostra —
// mai un disegno rotto accanto a una traccia giusta — ma la mancanza si
// DICE (onFailed permette al chiamante di segnarla e non ritentare):
// una traccia che parla di un disegno assente, senza spiegazioni, è
// peggio di una figura mancante e basta.
struct TikZFigureView: View {
    let tikz: String
    // SVG già compilato in passato, se c'è nel payload.
    let cachedSVG: String?
    var onCompiled: (String) -> Void = { _ in }
    var onFailed: () -> Void = {}

    @State private var svg: String?
    @State private var failed = false
    // Il TeX non compila: fallimento DEFINITIVO e del contenuto, quindi
    // si dice. Diverso da `failed` da solo, che copre anche il motore
    // non pronto (transitorio, si ritenta e non si annuncia).
    @State private var sourceIsBroken = false
    @State private var height: CGFloat = 120

    var body: some View {
        Group {
            if let svg, !svg.isEmpty {
                SVGWebView(svg: svg, height: $height)
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
            } else if sourceIsBroken {
                // Il fallimento silenzioso era indistinguibile da "qui
                // una figura non serviva": la traccia parlava di un
                // disegno che non arrivava mai, senza dire perché.
                Label("La figura di questa traccia non è compilabile: disegnala tu prima di risolvere.", systemImage: "scribble.variable")
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !failed {
                HStack(spacing: DesignSpace.s2) {
                    ProgressView().controlSize(.small)
                    Text("Preparo la figura…")
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignSpace.s4)
            }
        }
        .task(id: tikz) {
            // AZZERAMENTO OBBLIGATORIO. SwiftUI può riusare questa vista
            // per un ALTRO esercizio (stessa posizione nella gerarchia):
            // senza questa riga il vecchio `svg` resta, e siccome il
            // corpo lo mostra per primo, l'esercizio nuovo si vede
            // addosso la figura del precedente finché la sua non è
            // pronta — o per sempre, se la sua non compila.
            svg = nil
            failed = false
            sourceIsBroken = false
            if let cachedSVG {
                // Vuoto = fallita in passato: niente spinner, niente retry.
                if cachedSVG.isEmpty {
                    failed = true
                    sourceIsBroken = true
                } else {
                    svg = cachedSVG
                }
                return
            }
            switch await TikZCompiler.shared.compile(tikz) {
            case .compiled(let compiled):
                svg = compiled
                onCompiled(compiled)
            case .texFailed:
                // Il TeX non compila: esito del CONTENUTO, si ricorda nel
                // payload e non si ritenta più.
                failed = true
                sourceIsBroken = true
                onFailed()
            case .unavailable:
                // Motore non pronto (webview caduta, processo web morto,
                // richiesta appesa): la figura non si mostra adesso, ma
                // NON viene marcata come rotta — alla prossima apertura
                // della card si ritenta.
                failed = true
            }
        }
    }
}

// Mostra un SVG e riporta l'altezza giusta per la larghezza disponibile.
// WebView e non Image: l'SVG di dvi2html usa font web (via CSS del
// bundle TikZJax) e da vettoriale resta nitido a ogni zoom del foglio.
private struct SVGWebView: UIViewRepresentable {
    let svg: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "sizeHandler")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        context.coordinator.load(svg: svg, into: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(svg: svg, into: view)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        @Binding var height: CGFloat
        private var lastSVG: String?

        init(height: Binding<CGFloat>) { self._height = height }

        func load(svg: String, into view: WKWebView) {
            guard svg != lastSVG else { return }
            lastSVG = svg
            let fontsURL = Bundle.main.url(forResource: "tikz-fonts", withExtension: "css", subdirectory: "TikZJax")
                ?? Bundle.main.url(forResource: "tikz-fonts", withExtension: "css")
            let cssTag = fontsURL.map { "<link rel=\"stylesheet\" href=\"\($0.lastPathComponent)\">" } ?? ""
            let html = """
            <!DOCTYPE html><html><head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
            \(cssTag)
            <style>html,body{margin:0;padding:0;background:transparent}svg{max-width:100%;height:auto;display:block;margin:0 auto}</style>
            </head><body>\(svg)
            <script>
            function report(){window.webkit.messageHandlers.sizeHandler.postMessage(document.body.scrollHeight)}
            window.addEventListener('load',report);setTimeout(report,80);setTimeout(report,300);
            </script></body></html>
            """
            // baseURL sulla cartella del bundle: così il CSS dei font si
            // carica come risorsa locale.
            let base = fontsURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL
            view.loadHTMLString(html, baseURL: base)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let number = message.body as? NSNumber else { return }
            let value = max(CGFloat(number.doubleValue), 40)
            if abs(value - height) > 0.5 {
                DispatchQueue.main.async { self.height = value }
            }
        }
    }
}
