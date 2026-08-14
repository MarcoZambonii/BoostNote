import SwiftUI
import WebKit
import PDFKit

// Rende Markdown + LaTeX come testo formattato vero: grassetti, elenchi,
// titoli, codice e formule matematiche composte (frazioni, esponenti,
// radici, integrali) invece di asterischi e backslash grezzi.
// Tutto in locale con KaTeX + marked impacchettati nell'app: nessuna
// richiesta di rete, coerente col vincolo "gratis e offline".
//
// `mathOnly` serve all'azione "Genera LaTeX", dove il testo È una formula
// e va composta direttamente senza passare dal Markdown.
struct RichTextView: UIViewRepresentable {
    var text: String
    var mathOnly: Bool = false
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, mathOnly: mathOnly) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "heightHandler")
        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // L'altezza la decide il contenuto (via heightHandler): la vista
        // non scorre per conto suo dentro il foglio dei risultati.
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.pendingText = text

        if let url = Bundle.main.url(forResource: "template", withExtension: "html", subdirectory: "KaTeX")
            ?? Bundle.main.url(forResource: "template", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.render(text)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var pendingText: String?
        private var didFinishLoad = false
        private let mathOnly: Bool
        @Binding var height: CGFloat

        init(height: Binding<CGFloat>, mathOnly: Bool) {
            self._height = height
            self.mathOnly = mathOnly
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinishLoad = true
            if let text = pendingText { render(text) }
        }

        func render(_ text: String) {
            pendingText = text
            guard didFinishLoad,
                  let data = try? JSONEncoder().encode(text),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("renderContent(\(json), \(mathOnly))")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let number = message.body as? NSNumber else { return }
            let value = max(CGFloat(number.doubleValue), 24)
            guard abs(value - height) > 0.5 else { return }
            DispatchQueue.main.async { self.height = value }
        }
    }
}

// Compone una formula LaTeX e ne restituisce l'immagine ritagliata sul
// contorno reale della formula.
//
// Serve per mettere la formula BELLA sul foglio: la nota è una tela
// PencilKit con caselle di testo semplice, quindi l'unico modo di
// portarci dentro matematica composta è come immagine. Il codice grezzo
// resta comunque a disposizione col pulsante di copia.
@MainActor
enum LaTeXImageRenderer {
    // Scatto a 3× i punti logici: sul foglio si zooma parecchio e a 1×
    // la formula sgranerebbe come una scansione.
    static func image(for latex: String, pixelScale: CGFloat = 3) async -> UIImage? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = Bundle.main.url(forResource: "template", withExtension: "html", subdirectory: "KaTeX")
            ?? Bundle.main.url(forResource: "template", withExtension: "html") else { return nil }

        // Tela larga: una formula lunga non deve andare a capo né uscire
        // dal viewport, altrimenti lo scatto la taglia.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2000, height: 600))
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Il template segue prefers-color-scheme: su iPad in modo scuro
        // avrebbe composto la formula in BIANCO, cioè invisibile una volta
        // posata sul foglio (che resta bianco in ogni caso).
        webView.overrideUserInterfaceStyle = .light
        let watcher = LoadWatcher()
        webView.navigationDelegate = watcher

        // WebKit considera "viva" una vista che sta in una finestra, non è
        // nascosta e ha alpha > 0 — la posizione non conta. Va agganciata
        // fuori dallo schermo con alpha PIENA: col trucco dell'alpha quasi
        // zero la vista risulta invisibile e il rendering non produce
        // nulla (era questo a restituire un'immagine vuota).
        let host = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        webView.frame.origin = CGPoint(x: -6000, y: -6000)
        webView.isUserInteractionEnabled = false
        host?.insertSubview(webView, at: 0)
        defer { webView.removeFromSuperview() }

        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        guard await watcher.wait() else { return nil }

        // Due trappole nella misura, entrambe verificate eseguendo il
        // template: i font di KaTeX arrivano dopo il primo layout (misurare
        // prima dà una scatola sbagliata), e in display mode l'elemento
        // .katex è display:block, quindi largo quanto TUTTA la pagina — il
        // ritaglio sarebbe stato una striscia vuota con la formula in
        // mezzo. La formula vera è l'unione dei .base dentro .katex-html.
        let measured = try? await webView.callAsyncJavaScript(
            """
            // Colori fissati a mano: qui l'esito finisce su carta bianca,
            // qualunque tema abbia l'iPad.
            document.documentElement.style.colorScheme = 'light';
            document.body.style.color = '#1c1c1e';
            renderContent(latex, true);
            if (document.fonts && document.fonts.ready) { await document.fonts.ready; }
            await new Promise(function (resolve) { setTimeout(resolve, 60); });
            var nodes = document.querySelectorAll('.katex-html > .base');
            if (!nodes.length) { nodes = document.querySelectorAll('.katex-html'); }
            if (!nodes.length) { return null; }
            var left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
            for (var i = 0; i < nodes.length; i++) {
              var box = nodes[i].getBoundingClientRect();
              if (!box.width && !box.height) { continue; }
              left = Math.min(left, box.left);
              top = Math.min(top, box.top);
              right = Math.max(right, box.right);
              bottom = Math.max(bottom, box.bottom);
            }
            if (!isFinite(left)) { return null; }
            return { x: left, y: top, w: right - left, h: bottom - top };
            """,
            arguments: ["latex": trimmed],
            contentWorld: .page
        )
        guard let box = measured as? [String: Any],
              let x = box["x"] as? Double, let y = box["y"] as? Double,
              let width = box["w"] as? Double, let height = box["h"] as? Double,
              width > 1, height > 1 else { return nil }

        // Non `takeSnapshot`: quello fotografa ciò che la vista sta
        // disegnando SULLO SCHERMO, quindi dipende da dove e come la vista
        // è agganciata e può tornare vuoto. `pdf(configuration:)` fa
        // comporre la pagina al processo web e non ha quel vincolo — in
        // più il ritaglio arriva in vettoriale, da rasterizzare alla scala
        // che serve.
        let padding: Double = 6
        let pdfConfiguration = WKPDFConfiguration()
        pdfConfiguration.rect = CGRect(
            x: x - padding,
            y: y - padding,
            width: width + padding * 2,
            height: height + padding * 2
        )
        guard let pdfData = try? await webView.pdf(configuration: pdfConfiguration),
              // Il documento va tenuto vivo: una PDFPage la cui PDFDocument
              // è già stata rilasciata non disegna ("Drawing a PDFPage when
              // its PDFDocument is nil is unsupported").
              let document = PDFDocument(data: pdfData),
              let page = document.page(at: 0) else { return nil }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let pixelWidth = Int(bounds.width * pixelScale)
        let pixelHeight = Int(bounds.height * pixelScale)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Bitmap e PDF hanno entrambi l'origine in basso a sinistra:
        // nessun ribaltamento, al contrario di UIGraphicsImageRenderer.
        context.scaleBy(x: pixelScale, y: pixelScale)
        // Niente riempimento di sfondo, e soprattutto nessuna conversione
        // luminanza→trasparenza: con `isOpaque = false` WebKit NON disegna
        // la carta bianca nel PDF, quindi arriva già com'è giusto che sia
        // — glifi #1c1c1e con l'antialiasing nel canale alfa e il resto
        // trasparente. (Trattarlo come nero-su-bianco lo ribaltava in un
        // rettangolo tutto nero.)
        page.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else { return nil }
        // Con la scala giusta `size` torna in punti: chi la inserisce nel
        // foglio ottiene la dimensione logica, non quella in pixel.
        return UIImage(cgImage: cgImage, scale: pixelScale, orientation: .up)
    }

    @MainActor
    private final class LoadWatcher: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var settled = false

        // Il timeout evita che una risorsa mancante lasci l'attesa
        // appesa per sempre senza alcun segnale.
        func wait(timeout: TimeInterval = 8) async -> Bool {
            await withCheckedContinuation { cont in
                guard !settled else { return cont.resume(returning: true) }
                continuation = cont
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.settle(false)
                }
            }
        }

        private func settle(_ loaded: Bool) {
            guard !settled else { return }
            settled = true
            continuation?.resume(returning: loaded)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { settle(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { settle(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { settle(false) }
    }
}

// Contenitore pronto all'uso: si dimensiona da solo sull'altezza del
// contenuto renderizzato.
struct RichTextBlock: View {
    var text: String
    var mathOnly: Bool = false

    @State private var height: CGFloat = 40

    var body: some View {
        RichTextView(text: text, mathOnly: mathOnly, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}
