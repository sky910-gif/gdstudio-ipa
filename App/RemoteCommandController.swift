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
            artworkURL = URL(string: artwork)
            artworkImage = nil
            updateNowPlaying(title: title, artist: artist)
            loadArtworkThenRefresh(title: title, artist: artist)

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

    private func loadArtworkThenRefresh(title: String, artist: String) {
        guard let url = artworkURL else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard
                let data = data,
                let image = UIImage(data: data)
            else { return }
            DispatchQueue.main.async {
                self?.artworkImage = image
                self?.updateNowPlaying(title: title, artist: artist)
            }
        }
        task.resume()
    }

    // MARK: - Helpers

    private func eval(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
