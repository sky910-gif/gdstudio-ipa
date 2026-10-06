import UIKit
import WebKit
import MediaPlayer

/// 全屏 WKWebView 播放器外壳，支持在多个音乐站点之间切换并记住选择。
final class WebViewController: UIViewController {

    // MARK: - 可切换的站点（如需增减，改这里即可）

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
    private let remoteController = RemoteCommandController()
    private let messageHandler = WeakScriptMessageHandler()
    private let cacheSchemeHandler = GDCacheSchemeHandler()

    /// 右上角悬浮按钮
    private let switchButton = UIButton(type: .system)
    private let libraryButton = UIButton(type: .system)

    /// 标记是否已因断网自动弹过离线曲库
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

        // 注册自定义缓存协议（必须在创建 WebView 之前）
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
        wireNativePlayer()
        loadSavedSite()
    }

    /// 把原生播放内核的事件序列化后投递回注入脚本
    private func wireNativePlayer() {
        NativePlayer.shared.onEvent = { [weak self] dict in
            guard
                let data = try? JSONSerialization.data(withJSONObject: dict),
                let json = String(data: data, encoding: .utf8)
            else { return }
            let js = "window.__gdNativeEvent && window.__gdNativeEvent(\(json))"
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - 站点加载

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
        // 切站时清理锁屏信息，避免显示上一个站的曲目
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        switchButton.setTitle(site.name, for: .normal)
    }

    // MARK: - 悬浮切换按钮

    private func stylePill(_ button: UIButton) {
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 15
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    }

    private func setupTopButtons() {
        // 离线曲库按钮（左上）
        libraryButton.translatesAutoresizingMaskIntoConstraints = false
        libraryButton.setTitle("离线曲库", for: .normal)
        stylePill(libraryButton)
        libraryButton.addTarget(self, action: #selector(openLibrary), for: .touchUpInside)
        view.addSubview(libraryButton)

        // 切站按钮（右上）
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
        vc.onPick = { [weak self] entry in
            self?.playCached(entry)
        }
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    /// 让 WebView 播放一条已缓存歌曲
    private func playCached(_ entry: CacheEntry) {
        let cacheURL = "gdcache://item/\(entry.key)"
        var artwork = ""
        if let url = CacheStore.shared.artworkURL(for: entry.key) {
            artwork = url.absoluteString
        }
        let meta: [String: Any] = [
            "title": entry.title,
            "artist": entry.artist,
            "artwork": artwork,
            "duration": entry.duration,
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: meta)
        let json = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let js = "window.__gd && window.__gd.playCached('\(cacheURL)', \(json))"
        webView.evaluateJavaScript(js, completionHandler: nil)
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
            // 自定义项位于 allSites 末尾
            UserDefaults.standard.set(self.allSites.count - 1, forKey: Self.selectedIndexKey)
            self.load(site: Site(name: "自定义", urlString: text))
        })
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

        // 播放控制类消息：交给原生内核
        switch dict["kind"] as? String {
        case "play_request":
            if let src = dict["src"] as? String, let id = dict["id"] as? String {
                NativePlayer.shared.open(urlString: src, elementId: id)
            }
        case "pause_request":
            NativePlayer.shared.pause()
        case "seek_request":
            if let t = dict["time"] as? Double {
                NativePlayer.shared.seek(to: t)
            }
        default:
            break
        }

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

    /// 主页面加载失败（通常是断网）且本地有缓存时，自动进入离线曲库
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard !didAutoOpenLibrary, !CacheStore.shared.allEntries().isEmpty else { return }
        didAutoOpenLibrary = true
        openLibrary()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 页面能正常打开，重置断网标记
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
