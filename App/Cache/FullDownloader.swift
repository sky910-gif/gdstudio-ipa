import Foundation

/// 后台把整首歌完整下载到临时文件，完成后交给 CacheStore 落盘。
/// 同一 URL 只下载一次；超大文件（>80MB）跳过。
final class FullDownloader: NSObject {

    static let shared = FullDownloader()

    private var sessions: [String: DownloadJob] = [:]
    private let lock = NSLock()
    private let maxBytes: Int64 = 80 * 1024 * 1024

    func download(urlString: String, key: String) {
        lock.lock()
        let exists = sessions[key] != nil
        lock.unlock()
        guard !exists else { return }
        guard CacheStore.shared.canCache(size: 1) else { return }
        guard let url = URL(string: urlString) else { return }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gddl-\(key)-\(Int(Date().timeIntervalSince1970)).part")

        let job = DownloadJob(key: key, originalURL: urlString, tempFile: tmp)
        lock.lock(); sessions[key] = job; lock.unlock()

        job.start(url: url) { [weak self] finishedKey in
            self?.lock.lock(); self?.sessions.removeValue(forKey: finishedKey); self?.lock.unlock()
        }
    }
}

private final class DownloadJob: NSObject, URLSessionDownloadDelegate {
    let key: String
    let originalURL: String
    let tempFile: URL
    private var session: URLSession?
    private var mime = "audio/mpeg"
    private var expectedBytes: Int64 = 0
    private var onFinish: ((String) -> Void)?

    init(key: String, originalURL: String, tempFile: URL) {
        self.key = key; self.originalURL = originalURL; self.tempFile = tempFile
    }

    func start(url: URL, onFinish: @escaping (String) -> Void) {
        self.onFinish = onFinish
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session?.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        defer { onFinish?(key) }

        if let response = downloadTask.response as? HTTPURLResponse {
            mime = response.mimeType ?? mime
            expectedBytes = response.expectedContentLength
            guard (200...299).contains(response.statusCode) else { return }
        }
        if expectedBytes > FullDownloader.shared.maxByteLimit { return }

        // 清理可能残留的旧临时文件
        try? FileManager.default.removeItem(at: tempFile)
        do {
            try FileManager.default.moveItem(at: location, to: tempFile)
        } catch {
            do { try FileManager.default.copyItem(at: location, to: tempFile) }
            catch { return }
        }

        // 元数据可能稍后由 JS/NowPlaying 补全；先用占位信息落盘
        _ = CacheStore.shared.commit(
            key: key, originalURL: originalURL, tempFile: tempFile,
            mime: mime, title: "未知曲目", artist: "", duration: 0)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if error != nil {
            try? FileManager.default.removeItem(at: tempFile)
            onFinish?(key)
        }
    }
}

extension FullDownloader {
    var maxByteLimit: Int64 { maxBytes }
}
