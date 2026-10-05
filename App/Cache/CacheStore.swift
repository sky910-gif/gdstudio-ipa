import Foundation
import UIKit
import CryptoKit

/// 一条已缓存的曲目
struct CacheEntry: Codable {
    var key: String            // 由原始音频 URL 生成的唯一键
    var url: String            // 原始音频 URL
    var title: String
    var artist: String
    var duration: Double
    var size: Int64
    var mime: String
    var cachedAt: Date
    /// 封面本地文件名（如已保存）
    var artworkFile: String?
}

/// 本地缓存中心：文件落盘、元数据索引、封面存取、空间统计。
final class CacheStore {

    static let shared = CacheStore()

    private let indexKey = "cacheIndex_v1"
    private let maxCacheBytes: Int64 = 500 * 1024 * 1024   // 上限 500MB
    private let queue = DispatchQueue(label: "gd.cache.store")

    private var index: [String: CacheEntry] = [:]

    // MARK: - 目录

    private var baseDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("GDCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var audioDir: URL {
        let d = baseDir.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var artworkDir: URL {
        let d = baseDir.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private init() {
        loadIndex()
    }

    // MARK: - Key

    static func key(for urlString: String) -> String {
        let data = Data(urlString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 索引读写

    private func indexFile() -> URL { baseDir.appendingPathComponent("index.json") }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFile()),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        else { return }
        index = decoded
    }

    private func persistIndex() {
        // 调用方需保证在 queue 上，或外部仅通过 queue 方法使用
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexFile(), options: .atomic)
    }

    // MARK: - 查询

    func audioFile(for key: String) -> URL { audioDir.appendingPathComponent(key) }
    func artworkFile(for key: String) -> URL { artworkDir.appendingPathComponent(key + ".jpg") }

    func entry(for key: String) -> CacheEntry? {
        var result: CacheEntry?
        queue.sync { result = index[key] }
        return result
    }

    func allEntries() -> [CacheEntry] {
        var result: [CacheEntry] = []
        queue.sync { result = index.values.sorted { $0.cachedAt > $1.cachedAt } }
        return result
    }

    func has(key: String) -> Bool { entry(for: key) != nil }

    func cachedURL(forOriginal original: String) -> String? {
        let key = Self.key(for: original)
        guard has(key: key) else { return nil }
        return "gdcache://item/\(key)"
    }

    func totalSize() -> Int64 {
        var total: Int64 = 0
        queue.sync { total = index.values.reduce(0) { $0 + $1.size } }
        return total
    }

    // MARK: - 写入（下载完成后调用）

    /// 把下载好的临时音频移动进缓存并登记。返回是否成功。
    func commit(key: String, originalURL: String, tempFile: URL, mime: String,
                title: String, artist: String, duration: Double) -> Bool {
        var ok = false
        queue.sync {
            // 已有同名则先删旧
            let dest = audioFile(for: key)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tempFile, to: dest)
            } catch {
                // 跨卷移动失败时尝试拷贝
                do { try FileManager.default.copyItem(at: tempFile, to: dest) }
                catch { ok = false; return }
            }
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var entry = index[key] ?? CacheEntry(
                key: key, url: originalURL, title: title, artist: artist,
                duration: duration, size: Int64(size), mime: mime,
                cachedAt: Date(), artworkFile: nil)
            entry.url = originalURL
            entry.size = Int64(size)
            entry.mime = mime
            // 元数据可能晚于下载到达，保留已有信息
            if !title.isEmpty { entry.title = title }
            if !artist.isEmpty { entry.artist = artist }
            if duration > 0 { entry.duration = duration }
            index[key] = entry
            persistIndex()
            ok = true
        }
        if ok { notifyChanged() }
        return ok
    }

    /// 下载完成后若拿到了元数据，补充标题/歌手/时长/封面
    func updateMetadata(key: String, title: String, artist: String, duration: Double) {
        queue.sync {
            guard var entry = index[key] else { return }
            if !title.isEmpty { entry.title = title }
            if !artist.isEmpty { entry.artist = artist }
            if duration > 0 { entry.duration = duration }
            index[key] = entry
            persistIndex()
        }
        notifyChanged()
    }

    /// 保存封面图片数据，返回是否成功
    func saveArtwork(key: String, data: Data) -> Bool {
        var ok = false
        queue.sync {
            let dest = artworkFile(for: key)
            do {
                try data.write(to: dest, options: .atomic)
                if var entry = index[key] {
                    entry.artworkFile = dest.lastPathComponent
                    index[key] = entry
                    persistIndex()
                }
                ok = true
            } catch { ok = false }
        }
        if ok { notifyChanged() }
        return ok
    }

    func artworkURL(for key: String) -> URL? {
        guard let file = entry(for: key)?.artworkFile else { return nil }
        let url = artworkDir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 删除

    func delete(key: String) {
        queue.sync {
            let e = index.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: audioFile(for: key))
            if let art = e?.artworkFile {
                try? FileManager.default.removeItem(at: artworkDir.appendingPathComponent(art))
            }
            persistIndex()
        }
        notifyChanged()
    }

    func clearAll() {
        queue.sync {
            index.removeAll()
            let fm = FileManager.default
            try? fm.removeItem(at: audioDir)
            try? fm.removeItem(at: artworkDir)
            try? fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
            persistIndex()
        }
        notifyChanged()
    }

    /// 是否还有空间缓存新曲目（简单按总量上限）
    func canCache(size: Int64) -> Bool {
        var allow = true
        queue.sync { allow = (index.values.reduce(0) { $0 + $1.size } + size) <= maxCacheBytes }
        return allow
    }

    // MARK: - 通知

    static let changedNotification = Notification.Name("GDCacheChanged")
    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        }
    }
}
