import SwiftUI
import WebKit

// Mostra la vera pagina di login Polimi dentro un browser incorporato
// (l'app non vede mai la password) e intercetta il redirect finale di
// Moodle per estrarre il token di accesso.
struct WebeepAuthView: UIViewControllerRepresentable {
    var onToken: (String) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> WebeepAuthViewController {
        WebeepAuthViewController(onToken: onToken, onCancel: onCancel)
    }

    func updateUIViewController(_ uiViewController: WebeepAuthViewController, context: Context) {}
}

final class WebeepAuthViewController: UIViewController, WKNavigationDelegate {
    private let webView = WKWebView()
    private var onToken: (String) -> Void
    private var onCancel: () -> Void

    init(onToken: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onToken = onToken
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.navigationDelegate = self
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        closeButton.frame = CGRect(x: 16, y: 50, width: 32, height: 32)
        closeButton.autoresizingMask = [.flexibleBottomMargin]
        view.addSubview(closeButton)

        let passport = UUID().uuidString
        if let url = WebeepService.loginLaunchURL(passport: passport) {
            webView.load(URLRequest(url: url))
        }
    }

    @objc private func cancelTapped() {
        onCancel()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "moodlemobile" || url.scheme == "boostnote" {
            decisionHandler(.cancel)
            if let token = WebeepService.extractToken(fromRedirect: url) {
                onToken(token)
            } else {
                onCancel()
            }
            return
        }
        decisionHandler(.allow)
    }
}
