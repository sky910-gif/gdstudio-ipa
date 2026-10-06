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

    /// URL 里“每次都会变”的临时参数（签名/时间戳/令牌等），
    /// 归一化时剔除，避免同一首歌仅因这些参数不同而被重复缓存。
    private static let transientQueryNames: Set<String> = [
        "sign", "signature", "sig", "token", "access_token", "auth", "auth_key",
        "key", "secret", "timestamp", "time", "t", "ts", "_t", "nonce", "rnd",
        "rand", "random", "expires", "expire", "expiration", "expiry", "deadline",
        "valid", "validuntil", "v", "callback", "wssecret", "ws_time", "ws_auth",
    ]

    /// 把 URL 归一化成“只与歌曲本身有关”的稳定形式：
    /// 去掉临时查询参数，其余参数排序，丢弃 fragment。
    static func stableURL(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return urlString }

        var items = comps.queryItems ?? []
        items = items.filter { item in
            let lower = item.name.lowercased()
            if transientQueryNames.contains(lower) { return false }
            // 兜底：名字里含这些字样也视为临时参数
            if lower.contains("sign") || lower.contains("token") ||
               lower.contains("timestamp") || lower.contains("expire") ||
               lower.contains("nonce") || lower.contains("auth") {
                return false
            }
            return true
        }
        items.sort { $0.name < $1.name }
        comps.queryItems = items.isEmpty ? nil : items
        comps.fragment = nil

        if let r = comps.url { return r.absoluteString }
        return urlString
    }

    /// 用【归一化后的 URL】生成稳定 key
    static func key(for urlString: String) -> String {
        let stable = stableURL(from: urlString)
        let data = Data(stable.utf8)
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
            // 若这是占位/非真实标题，先不按身份合并；真实曲目到达时再去重
            consolidateDuplicates(keepKey: key)
            persistIndex()
            ok = true
        }
        if ok { notifyChanged() }
        return ok
    }

    /// 下载完成后若拿到了元数据，补充标题/歌手/时长/封面，并合并重复项
    func updateMetadata(key: String, title: String, artist: String, duration: Double) {
        queue.sync {
            guard var entry = index[key] else { return }
            if !title.isEmpty { entry.title = title }
            if !artist.isEmpty { entry.artist = artist }
            if duration > 0 { entry.duration = duration }
            index[key] = entry
            consolidateDuplicates(keepKey: key)
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

    // MARK: - 去重（按歌曲身份）

    /// 两条目是否为“同一首歌”。
    /// 优先用 歌名+歌手+时长(±2秒)；缺标题的占位条目用归一化 URL 判定。
    private func isSameSong(_ a: CacheEntry, _ b: CacheEntry) -> Bool {
        let aHasTitle = !a.title.isEmpty && a.title != "未知曲目"
        let bHasTitle = !b.title.isEmpty && b.title != "未知曲目"

        if aHasTitle && bHasTitle {
            guard a.title == b.title else { return false }
            let artistSame = a.artist == b.artist
            let durClose = (a.duration > 0 && b.duration > 0)
                ? abs(a.duration - b.duration) <= 2.0
                : true
            return artistSame && durClose
        }

        // 占位条目：比较归一化 URL
        return Self.stableURL(from: a.url) == Self.stableURL(from: b.url)
    }

    /// 把与 keepKey 身份相同的其它条目合并掉：保留 keepKey，删除重复的音频/封面，
    /// 并把更完整的元数据与封面合并过来。必须在 queue 内调用。
    private func consolidateDuplicates(keepKey: String) {
        guard let keeper = index[keepKey] else { return }

        let dupKeys = index.keys.filter { k in
            k != keepKey && isSameSong(keeper, index[k]!)
        }
        guard !dupKeys.isEmpty else { return }

        var merged = keeper
        for dk in dupKeys {
            let dup = index[dk]!

            // 合并更完整的元数据
            if (merged.title.isEmpty || merged.title == "未知曲目"),
               !dup.title.isEmpty && dup.title != "未知曲目" {
                merged.title = dup.title
            }
            if merged.artist.isEmpty && !dup.artist.isEmpty { merged.artist = dup.artist }
            if merged.duration <= 0 && dup.duration > 0 { merged.duration = dup.duration }
            if merged.artworkFile == nil && dup.artworkFile != nil {
                // 复用重复项的封面：复制到 keepKey 名下
                let src = artworkDir.appendingPathComponent(dup.artworkFile!)
                let dst = artworkFile(for: keepKey)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.removeItem(at: dst)
                    try? FileManager.default.copyItem(at: src, to: dst)
                    merged.artworkFile = dst.lastPathComponent
                }
            }

            // 删除重复音频与封面文件
            try? FileManager.default.removeItem(at: audioFile(for: dk))
            if let art = dup.artworkFile {
                try? FileManager.default.removeItem(at: artworkDir.appendingPathComponent(art))
            }
            index.removeValue(forKey: dk)
        }

        // 更新大小
        let keepFile = audioFile(for: keepKey)
        let size = (try? keepFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        merged.size = Int64(size)
        index[keepKey] = merged
    }

    /// 立即清理全库重复（供外部调用，例如版本升级后一次性整理历史重复）。
    func removeAllDuplicates() {
        var changed = false
        queue.sync {
            let before = index.count
            // 从最新条目开始保留
            let keys = index.values.sorted { $0.cachedAt > $1.cachedAt }.map { $0.key }
            for k in keys {
                if index[k] != nil { consolidateDuplicates(keepKey: k) }
            }
            changed = index.count != before
            if changed { persistIndex() }
        }
        if changed { notifyChanged() }
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
