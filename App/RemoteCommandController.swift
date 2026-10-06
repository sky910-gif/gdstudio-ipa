import MediaPlayer
import UIKit
import WebKit

/// 统一管理锁屏 / 控制中心 / 车载（蓝牙、CarPlay「正在播放」）的控制事件：
/// - 在线网页播放时：转发给网页 `window.__gd`；
/// - 原生离线播放器激活时：转发给该播放器（RemoteCommandPlayback）。
/// 同时仍处理网页回传的 state/meta/tick，用于网页播放时的 Now Playing 信息。
final class RemoteCommandController {

    static let shared = RemoteCommandController()

    weak var webView: WKWebView?

    /// 当前接管控制的原生播放器（离线播放）；为 nil 时走网页
    private weak var activePlayer: RemoteCommandPlayback?

    private var artworkURL: URL?
    private var artworkImage: UIImage?
    private var duration: Double = 0
    private var isPlaying = false

    private var lastElapsed: Double = 0
    private var lastElapsedDate: Date = Date()
    private var elapsedTimer: Timer?

    private var didRegister = false

    // MARK: - 注册（仅一次）

    func registerCommands() {
        guard !didRegister else { return }
        didRegister = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.dispatch(toPlayer: { $0.remotePlay() }, fallback: {
                self?.eval("window.__gd && window.__gd.cmd('play')")
            })
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.dispatch(toPlayer: { $0.remotePause() }, fallback: {
                self?.eval("window.__gd && window.__gd.cmd('pause')")
            })
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.dispatch(toPlayer: { $0.remoteNext() }, fallback: {
                self?.eval("window.__gd && window.__gd.cmd('next')")
            })
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.dispatch(toPlayer: { $0.remotePrevious() }, fallback: {
                self?.eval("window.__gd && window.__gd.cmd('prev')")
            })
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let ev = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let sec = ev.positionTime
            if let player = self?.activePlayer {
                player.remoteSeek(sec)
            } else {
                self?.eval("window.__gd && window.__gd.seek(\(sec))")
                self?.lastElapsed = sec
                self?.lastElapsedDate = Date()
            }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
    }

    // MARK: - 当前播放器

    func setActivePlayer(_ player: RemoteCommandPlayback?) {
        activePlayer = player
    }

    private func dispatch(toPlayer: (RemoteCommandPlayback) -> Void,
                          fallback: () -> Void) {
        if let player = activePlayer {
            toPlayer(player)
        } else {
            fallback()
        }
    }

    // MARK: - 网页消息（仅网页播放相关）

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

            associateWithCache(src: src, title: title, artist: artist)

            if !artwork.isEmpty {
                artworkURL = URL(string: artwork)
                artworkImage = nil
                updateNowPlaying(title: title, artist: artist)
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

    // MARK: - 网页 Now Playing

    private func updateNowPlaying(title: String, artist: String) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
        ]
        if let image = artworkImage {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
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

        if url.isFileURL {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                artworkImage = image
                updateNowPlaying(title: title, artist: artist)
            }
            return
        }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.artworkImage = image
                self?.updateNowPlaying(title: title, artist: artist)
                self?.saveArtworkToCache(data: data, src: src)
            }
        }
        task.resume()
    }

    // MARK: - 缓存关联（网页在线播放）

    private func associateWithCache(src: String, title: String, artist: String) {
        guard !src.isEmpty, src.hasPrefix("http") else { return }
        let key = CacheStore.key(for: src)
        CacheStore.shared.updateMetadata(key: key, title: title, artist: artist, duration: duration)
    }

    private func saveArtworkToCache(data: Data, src: String) {
        guard !src.isEmpty, src.hasPrefix("http") else { return }
        let key = CacheStore.key(for: src)
        CacheStore.shared.saveArtwork(key: key, data: data)
    }

    // MARK: - Helpers

    private func eval(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
