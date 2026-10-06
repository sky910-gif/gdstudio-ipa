import UIKit
import WebKit
import MediaPlayer

/// 全屏 WKWebView 播放器外壳（1.2.0 稳定方案）：
/// 网页负责在线播放，原生做缓存代理；离线曲库为独立界面，
/// 点开离线歌曲会进入原生音乐播放器。
final class WebViewController: UIViewController {

    // MARK: - 可切换的站点

    struct Site: Equatable {
        let name: String
        let urlString: String
    }

    private static let sites: [Site] = [
        Site(name: "GD音乐 · xyz", urlString: "https://music.gdstudio.xyz/"),
        Site(name: "GD音乐 · org", urlString: "https://music.gdstudio.org/"),
    ]

    private static let customSiteKey = "customSite"
    private static let selectedIndexKey = "selectedSiteIndex"

    private var webView: WKWebView!
    private let remoteController = RemoteCommandController.shared
    private let messageHandler = WeakScriptMessageHandler()
    private let cacheSchemeHandler = GDCacheSchemeHandler()

    private let switchButton = UIButton(type: .system)
    private let libraryButton = UIButton(type: .system)
    private var didAutoOpenLibrary = false

    // MARK: - 生命周期

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        if let jsURL = Bundle.main.url(forResource: "bridge", withExtension: "js"),
           let js = try? String(contentsOf: jsURL, encoding: .utf8) {
            let script = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            config.userContentController.addUserScript(script)
        }

        messageHandler.delegate = self
        config.userContentController.add(messageHandler, name: "gdBridge")
        config.setURLSchemeHandler(cacheSchemeHandler, forURLScheme: "gdcache")

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
        setupTopButtons()
        loadSavedSite()
    }

    // MARK: - 站点

    private var allSites: [Site] {
        var list = Self.sites
        if let custom = UserDefaults.standard.string(forKey: Self.customSiteKey) {
            list.append(Site(name: "自定义", urlString: custom))
        }
        return list
    }

    private func loadSavedSite() {
        let list = allSites
        let idx = UserDefaults.standard.integer(forKey: Self.selectedIndexKey)
        let site = (idx >= 0 && idx < list.count) ? list[idx] : list[0]
        load(site: site)
    }

    private func load(site: Site) {
        guard let url = URL(string: site.urlString) else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        switchButton.setTitle(site.name, for: .normal)
    }

    // MARK: - 顶部按钮

    private func stylePill(_ button: UIButton) {
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 15
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    }

    private func setupTopButtons() {
        libraryButton.translatesAutoresizingMaskIntoConstraints = false
        libraryButton.setTitle("离线曲库", for: .normal)
        stylePill(libraryButton)
        libraryButton.addTarget(self, action: #selector(openLibrary), for: .touchUpInside)
        view.addSubview(libraryButton)

        switchButton.translatesAutoresizingMaskIntoConstraints = false
        stylePill(switchButton)
        switchButton.addTarget(self, action: #selector(showSiteMenu), for: .touchUpInside)
        view.addSubview(switchButton)

        NSLayoutConstraint.activate([
            libraryButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            libraryButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            switchButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            switchButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])
    }

    @objc private func openLibrary() {
        let vc = CacheLibraryViewController()
        // 点歌：先关闭曲库，完成后再全屏弹出原生播放器
        vc.onPick = { [weak self] entries, index in
            self?.dismiss(animated: true) {
                self?.presentOfflinePlayer(entries: entries, index: index)
            }
        }
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    private func presentOfflinePlayer(entries: [CacheEntry], index: Int) {
        let player = OfflinePlayerViewController(entries: entries, startIndex: index)
        player.modalPresentationStyle = .fullScreen
        present(player, animated: true)
    }

    @objc private func showSiteMenu() {
        let list = allSites
        let alert = UIAlertController(title: "切换站点", message: nil, preferredStyle: .actionSheet)
        let currentHost = webView.url?.host
        for (idx, site) in list.enumerated() {
            let active = currentHost == URL(string: site.urlString)?.host
            let mark = active ? "✓ " : ""
            alert.addAction(UIAlertAction(title: mark + site.name, style: .default) { [weak self] _ in
                UserDefaults.standard.set(idx, forKey: Self.selectedIndexKey)
                self?.load(site: site)
            })
        }
        alert.addAction(UIAlertAction(title: "自定义网址…", style: .default) { [weak self] _ in
            self?.askCustomURL()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = switchButton
            pop.sourceRect = switchButton.bounds
        }
        present(alert, animated: true)
    }

    private func askCustomURL() {
        let input = UIAlertController(title: "自定义网址", message: "输入以 http(s):// 开头的网址", preferredStyle: .alert)
        input.addTextField { tf in
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.text = UserDefaults.standard.string(forKey: Self.customSiteKey) ?? "https://"
        }
        input.addAction(UIAlertAction(title: "取消", style: .cancel))
        input.addAction(UIAlertAction(title: "打开", style: .default) { [weak self] _ in
            guard
                let self = self,
                var text = input.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                !text.isEmpty
            else { return }
            if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
                text = "https://" + text
            }
            guard URL(string: text) != nil else { return }
            UserDefaults.standard.set(text, forKey: Self.customSiteKey)
            UserDefaults.standard.set(self.allSites.count - 1, forKey: Self.selectedIndexKey)
            self.load(site: Site(name: "自定义", urlString: text))
        }
        present(input, animated: true)
    }
}

// MARK: - WKScriptMessageHandler

extension WebViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "gdBridge", let dict = message.body as? [String: Any] else { return }
        remoteController.handle(message: dict)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        if url.scheme == "http" || url.scheme == "https" || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            if UIApplication.shared.canOpenURL(url) { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard !didAutoOpenLibrary, !CacheStore.shared.allEntries().isEmpty else { return }
        didAutoOpenLibrary = true
        openLibrary()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didAutoOpenLibrary = false
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
