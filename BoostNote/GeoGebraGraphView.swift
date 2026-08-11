import SwiftUI
import WebKit

// Grafico interattivo vero (pan/zoom/trascina punti) tramite GeoGebra
// incorporato via WKWebView, invece del plot statico disegnato a mano.
// Richiede connessione a internet (carica deployggb.js da geogebra.org),
// come le altre funzioni "intelligenti" dell'app.
struct GeoGebraGraphView: UIViewRepresentable {
    var expression: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://www.geogebra.org/"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.setExpression(expression, on: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var lastExpression: String?

        func setExpression(_ expr: String, on webView: WKWebView) {
            guard expr != lastExpression else { return }
            lastExpression = expr
            let escaped = expr
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("setExpression('y=\(escaped)')")
        }
    }

    private static let html = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <style>
        html, body, #ggb { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
    </style>
    </head>
    <body>
    <div id="ggb"></div>
    <script src="https://www.geogebra.org/apps/deployggb.js"></script>
    <script>
        window.__pendingExpr = null;
        var params = {
            appName: "graphing",
            width: window.innerWidth,
            height: window.innerHeight,
            showToolBar: false,
            showAlgebraInput: false,
            showMenuBar: false,
            showResetIcon: true,
            enableRightClick: false,
            allowStyleBar: false,
            appletOnLoad: function(api) {
                window.ggbApplet = api;
                if (window.__pendingExpr) {
                    api.evalCommand(window.__pendingExpr);
                    window.__pendingExpr = null;
                }
            }
        };
        var applet = new GGBApplet(params, true);
        window.addEventListener("load", function () { applet.inject("ggb"); });

        function setExpression(expr) {
            if (window.ggbApplet) {
                window.ggbApplet.reset();
                window.ggbApplet.evalCommand(expr);
            } else {
                window.__pendingExpr = expr;
            }
        }
    </script>
    </body>
    </html>
    """
}
