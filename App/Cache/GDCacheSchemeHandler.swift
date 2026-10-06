import Foundation
import UIKit
import WebKit
import UniformTypeIdentifiers

/// 接管 gdcache:// 自定义协议：
/// - gdcache://item/<key>            读取已缓存的本地文件（支持 Range）
/// - gdcache://fetch?u=<编码后的URL> 在线代理播放，并后台整曲下载缓存
@objc(GDCacheSchemeHandler)
final class GDCacheSchemeHandler: NSObject, WKURLSchemeHandler {

    private var passthroughSessions: [Int: PassthroughTask] = [:]
    private let lock = NSLock()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, -1); return
        }

        // 1) 已缓存文件
        if url.host == "item" {
            let key = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            serveCached(key: key, task: urlSchemeTask)
            return
        }

        // 2) 在线代理
        if url.host == "fetch" {
            guard
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let original = comps.queryItems?.first(where: { $0.name == "u" })?.value,
                let target = URL(string: original)
            else { fail(urlSchemeTask, -2); return }

            let key = CacheStore.key(for: original)

            // 若其实已缓存（例如 JS 信息滞后），直接读本地
            if CacheStore.shared.has(key: key) {
                serveCached(key: key, task: urlSchemeTask)
                return
            }

            startPassthrough(task: urlSchemeTask, target: target, originalURL: original, key: key)
            return
        }

        fail(urlSchemeTask, -3)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        let p = passthroughSessions.removeValue(forKey: urlSchemeTask.hash)
        lock.unlock()
        p?.cancel()
    }

    // MARK: - 读本地缓存（支持 Range）

    private func serveCached(key: String, task: WKURLSchemeTask) {
        guard let entry = CacheStore.shared.entry(for: key) else {
            fail(task, -4); return
        }
        let fileURL = CacheStore.shared.audioFile(for: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let totalLen = attrs[.size] as? Int64 else {
            fail(task, -5); return
        }

        let mime = entry.mime.isEmpty ? "audio/mpeg" : entry.mime
        let request = task.request
        var status = 200
        var start: Int64 = 0
        var end: Int64 = totalLen - 1

        if let range = request.value(forHTTPHeaderField: "Range"),
           range.lowercased().hasPrefix("bytes=") {
            let spec = String(range.dropFirst(6))
            let parts = spec.split(separator: "-", maxSplits: 1).map(String.init)
            if let s = Int64(parts.first ?? "") { start = s }
            if parts.count == 2, let e = Int64(parts[1]) { end = min(e, totalLen - 1) }
            status = 206
        }

        let length = end - start + 1

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            fail(task, -6); return
        }
        defer { try? handle.close() }

        var headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": String(length),
            "Accept-Ranges": "bytes",
        ]
        if status == 206 {
            headers["Content-Range"] = "bytes \(start)-\(end)/\(totalLen)"
        }

        guard let response = HTTPURLResponse(
            url: request.url ?? fileURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else { fail(task, -7); return }

        task.didReceive(response)

        do {
            try handle.seek(toOffset: UInt64(max(0, start)))
            var remaining = length
            let chunkSize: Int64 = 64 * 1024
            while remaining > 0 {
                let toRead = min(chunkSize, remaining)
                let data = handle.readData(ofLength: Int(toRead))
                if data.isEmpty { break }
                task.didReceive(data)
                remaining -= Int64(data.count)
            }
            task.didFinish()
        } catch {
            fail(task, -8)
        }
    }

    // MARK: - 在线代理播放

    private func startPassthrough(task: WKURLSchemeTask, target: URL,
                                  originalURL: String, key: String) {
        // 把请求头（如 Range）转发给源站
        var request = URLRequest(url: target)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let range = task.request.value(forHTTPHeaderField: "Range") {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        let pt = PassthroughTask(task: task)
        lock.lock(); passthroughSessions[task.hash] = pt; lock.unlock()
        pt.start(request: request)

        // 仅在这是首次（无 Range 或从 0 开始）请求时，后台整曲下载缓存
        let range = task.request.value(forHTTPHeaderField: "Range") ?? ""
        let fromStart = range.isEmpty || range.contains("bytes=0-")
        if fromStart {
            FullDownloader.shared.download(urlString: originalURL, key: key)
        }
    }

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        let err = NSError(domain: "GDCacheScheme", code: code)
        task.didFailWithError(err)
    }
}

// MARK: - 单次代理任务

/// 把源站响应和数据原样转回 WebView。
private final class PassthroughTask: NSObject, URLSessionDataDelegate {
    private weak var schemeTask: WKURLSchemeTask?
    private var session: URLSession?
    private var stopped = false

    init(task: WKURLSchemeTask) { self.schemeTask = task }

    func start(request: URLRequest) {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 不走系统缓存；允许蜂窝
        config.allowsCellularAccess = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session?.dataTask(with: request).resume()
    }

    func cancel() {
        stopped = true
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !stopped, let task = schemeTask else { completionHandler(.cancel); return }
        task.didReceive(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped else { return }
        schemeTask?.didReceive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped else { return }
        if let error = error {
            schemeTask?.didFailWithError(error)
        } else {
            schemeTask?.didFinish()
        }
    }
}
