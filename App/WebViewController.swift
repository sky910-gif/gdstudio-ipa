import UIKit
import WebKit

/// 仅承载目标网页的全屏 WKWebView，并在 document-start 注入桥接脚本。
final class WebViewController: UIViewController {

    /// 要包装的网址（如需改成其它音乐站点，改这里即可）
    private let targetURL = URL(string: "https://music.gdstudio.xyz/")!

    private var webView: WKWebView!
    private let remoteController = RemoteCommandController()

    /// 弱引用代理，断开 WKUserContentController 对脚本处理器的强引用环
    private let messageHandler = WeakScriptMessageHandler()

    override func loadView() {
        let config = WKWebViewConfiguration()

        // 允许网页内联播放、后台播放
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        // 不强制要求用户手势才能开始媒体播放（首次仍由网页点击触发）
        config.mediaTypesRequiringUserActionForPlayback = []

        // 注入桥接脚本（document start）
        if let jsURL = Bundle.main.url(forResource: "bridge", withExtension: "js"),
           let js = try? String(contentsOf: jsURL, encoding: .utf8) {
            let script = WKUserScript(
                source: js,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(script)
        }

        // 注册 JS -> Native 消息通道
        messageHandler.delegate = self
        config.userContentController.add(messageHandler, name: "gdBridge")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        view = webView
        remoteController.webView = webView
        remoteController.registerCommands()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalCacheData))
    }
}

// MARK: - WKScriptMessageHandler

extension WebViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "gdBridge", let dict = message.body as? [String: Any] else {
            return
        }
        remoteController.handle(message: dict)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

    /// 只在 WebView 内打开同源/http(s) 链接；其它 scheme（tel/mailto 等）交给系统
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "http" || url.scheme == "https" || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}

// MARK: - 弱引用代理

final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
