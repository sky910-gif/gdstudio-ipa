import MediaPlayer
import UIKit
import WebKit

/// 从注入网页的 JS 读取标题/歌手/封面/进度，同步到 iOS 锁屏和控制中心，
/// 并把锁屏上的 播放/暂停、上一首/下一首 转回网页操作。
final class RemoteCommandController {

    weak var webView: WKWebView?

    private var artworkURL: URL?
    private var artworkImage: UIImage?
    private var duration: Double = 0
    private var isPlaying = false

    // 最近一次网页回传的播放位置与时间，用于锁屏进度估算
    private var lastElapsed: Double = 0
    private var lastElapsedDate: Date = Date()
    private var elapsedTimer: Timer?

    // MARK: - 锁屏控制按钮

    func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.eval("window.__gd && window.__gd.cmd('play')")
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.eval("window.__gd && window.__gd.cmd('pause')")
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.eval("window.__gd && window.__gd.cmd('next')")
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.eval("window.__gd && window.__gd.cmd('prev')")
            return .success
        }

        // 拖动锁屏进度条
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let ev = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let sec = ev.positionTime
            self?.eval("window.__gd && window.__gd.seek(\(sec))")
            self?.lastElapsed = sec
            self?.lastElapsedDate = Date()
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
    }

    // MARK: - 接收 JS 同步过来的状态

    func handle(message dict: [String: Any]) {
        guard let kind = dict["kind"] as? String else { return }

        switch kind {
        case "state":
            let playing = (dict["playing"] as? Bool) ?? false
            isPlaying = playing
            if playing {
                AudioSessionController.shared.beginKeepAlive()
            } else {
                AudioSessionController.shared.endKeepAliveAfterGrace()
            }
            scheduleElapsedTimer(playing: playing)
            updatePlaybackState(playing: playing)

        case "meta":
            duration = (dict["duration"] as? Double) ?? 0
            let title = (dict["title"] as? String) ?? ""
            let artist = (dict["artist"] as? String) ?? ""
            let artwork = (dict["artwork"] as? String) ?? ""
            let src = (dict["src"] as? String) ?? ""

            // 把元数据补进缓存索引（下载可能先于元数据完成）
            associateWithCache(src: src, title: title, artist: artist)

            // 封面为空时保留上一张（离线缓存/切歌瞬间常见）
            if !artwork.isEmpty {
                artworkURL = URL(string: artwork)
                artworkImage = nil
                loadArtworkThenRefresh(title: title, artist: artist, src: src)
            } else {
                updateNowPlaying(title: title, artist: artist)
            }

        case "tick":
            if let t = dict["time"] as? Double {
                lastElapsed = t
                lastElapsedDate = Date()
            }

        default:
            break
        }
    }

    // MARK: - Now Playing 信息

    private func updateNowPlaying(title: String, artist: String) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration
        ]
        if let image = artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = estimatedElapsed()
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updatePlaybackState(playing: Bool) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = estimatedElapsed()
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func estimatedElapsed() -> Double {
        guard isPlaying else { return lastElapsed }
        return lastElapsed + Date().timeIntervalSince(lastElapsedDate)
    }

    /// 每秒同步一次进度，让锁屏进度条走动（不依赖网页在后台计时）
    private func scheduleElapsedTimer(playing: Bool) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard playing else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.estimatedElapsed()
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func loadArtworkThenRefresh(title: String, artist: String, src: String) {
        guard let url = artworkURL else { return }

        // 本地 file:// 封面（离线曲库）：直接读取
        if url.isFileURL {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                artworkImage = image
                updateNowPlaying(title: title, artist: artist)
            }
            return
        }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard
                let data = data,
                let image = UIImage(data: data)
            else { return }
            DispatchQueue.main.async {
                self?.artworkImage = image
                self?.updateNowPlaying(title: title, artist: artist)
                // 顺手把封面存进对应缓存
                self?.saveArtworkToCache(data: data, src: src)
            }
        }
        task.resume()
    }

    /// 根据当前音频地址定位缓存 key，补充元数据
    private func associateWithCache(src: String, title: String, artist: String) {
        guard !src.isEmpty else { return }

        // 离线播放：gdcache://item/<key>
        if src.hasPrefix("gdcache://item/") {
            let key = String(src.dropFirst("gdcache://item/".count))
            CacheStore.shared.updateMetadata(key: key, title: title, artist: artist, duration: duration)
            return
        }
        // 在线播放：原始 http(s) URL
        if src.hasPrefix("http") {
            let key = CacheStore.key(for: src)
            CacheStore.shared.updateMetadata(key: key, title: title, artist: artist, duration: duration)
        }
    }

    private func saveArtworkToCache(data: Data, src: String) {
        guard !src.isEmpty else { return }
        if src.hasPrefix("gdcache://item/") {
            let key = String(src.dropFirst("gdcache://item/".count))
            CacheStore.shared.saveArtwork(key: key, data: data)
        } else if src.hasPrefix("http") {
            let key = CacheStore.key(for: src)
            CacheStore.shared.saveArtwork(key: key, data: data)
        }
    }

    // MARK: - Helpers

    private func eval(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
