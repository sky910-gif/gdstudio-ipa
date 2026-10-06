import Foundation
import AVFoundation
import MediaPlayer

/// 无界面的原生播放内核：对外只暴露播放控制与状态回调。
/// 成功播放后会通过回调通知，失败由调用方回退到网页自带播放。
final class NativePlayer: NSObject {

    static let shared = NativePlayer()

    /// 原生回调给网页层（字段同 bridge 约定）
    var onEvent: (([String: Any]) -> Void)?

    private let player = AVPlayer()
    private var itemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeObserver: Any?

    /// 当前播放项对应的“元素 id”和原始/缓存 URL
    private(set) var currentElementId: String?
    private(set) var currentOriginalURL: String?
    private(set) var currentKey: String?
    private var playingIntent = false
    private var didPlaySuccessfully = false

    private override init() {
        super.init()
        configureObservers()
    }

    // MARK: - 配置

    private func configureObservers() {
        // 每秒时间回调
        let interval = CMTime(value: 1, timescale: 1)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            guard let self = self else { return }
            let sec = CMTimeGetSeconds(time)
            guard sec.isFinite else { return }
            self.emit([
                "kind": "native_time",
                "id": self.currentElementId ?? "",
                "time": sec,
            ])
        }

        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let self = self, let rate = change.newValue else { return }
            let playing = rate != 0
            self.emit([
                "kind": "native_state",
                "id": self.currentElementId ?? "",
                "playing": playing,
            ])
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playToEnd(_:)),
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemFailed(_:)),
            name: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil
        )
    }

    // MARK: - 打开并播放

    /// - Parameters:
    ///   - urlString: 要播放的地址（原始 http(s) 或 gdcache://item/<key>）
    ///   - elementId: 网页里媒体元素的映射 id
    func open(urlString: String, elementId: String) {
        currentElementId = elementId
        didPlaySuccessfully = false
        playingIntent = true

        let assetURL: URL
        var key: String?
        var original: String = urlString

        if urlString.hasPrefix("gdcache://item/") {
            let k = String(urlString.dropFirst("gdcache://item/".count))
            key = k
            currentKey = k
            assetURL = CacheStore.shared.audioFile(for: k)
        } else {
            // 在线：用归一化 key，命中本地缓存则直接读本地
            let k = CacheStore.key(for: urlString)
            currentKey = k
            if CacheStore.shared.has(key: k) {
                key = k
                assetURL = CacheStore.shared.audioFile(for: k)
            } else {
                assetURL = URL(string: urlString) ?? URL(fileURLWithPath: "")
                currentOriginalURL = urlString
            }
        }

        let item = AVPlayerItem(url: assetURL)
        // 时长通常能自动拿到；保留默认缓冲策略
        replaceItem(item, key: key, original: original)

        player.play()

        // 在线（非本地缓存）时，后台整曲下载，用于离线
        if !urlString.hasPrefix("gdcache://item/"), key == nil {
            if let target = currentOriginalURL {
                let k = CacheStore.key(for: target)
                FullDownloader.shared.download(urlString: target, key: k)
            }
        }
    }

    private func replaceItem(_ item: AVPlayerItem, key: String?, original: String) {
        itemObservation?.invalidate()
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            switch item.status {
            case .readyToPlay:
                let dur = CMTimeGetSeconds(item.duration)
                var dict: [String: Any] = [
                    "kind": "native_ready",
                    "id": self.currentElementId ?? "",
                ]
                if dur.isFinite { dict["duration"] = dur }
                self.emit(dict)
            case .failed:
                self.failCurrent(reason: item.error?.localizedDescription ?? "item failed")
            default:
                break
            }
        }

        statusObservation?.invalidate()
        statusObservation = player.observe(\.status) { [weak self] player, _ in
            if player.status == .failed {
                self?.failCurrent(reason: player.error?.localizedDescription ?? "player failed")
            }
        }

        player.replaceCurrentItem(with: item)
    }

    // MARK: - 控制

    func play() {
        playingIntent = true
        player.play()
    }

    func pause() {
        playingIntent = false
        player.pause()
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 当前播放位置
    func currentTime() -> Double {
        CMTimeGetSeconds(player.currentTime())
    }

    // MARK: - 完成 / 失败

    @objc private func playToEnd(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem,
              item === player.currentItem else { return }
        emit([
            "kind": "native_ended",
            "id": currentElementId ?? "",
        ])
    }

    @objc private func itemFailed(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem,
              item === player.currentItem else { return }
        failCurrent(reason: "failed to play to end")
    }

    private func failCurrent(reason: String) {
        guard playingIntent else { return }
        emit([
            "kind": "native_error",
            "id": currentElementId ?? "",
            "message": reason,
        ])
        playingIntent = false
    }

    // MARK: - 中断恢复

    /// 由音频会话中断结束时调用
    func resumeAfterInterruption() {
        guard playingIntent else { return }
        player.play()
    }

    // MARK: - 输出

    private func emit(_ dict: [String: Any]) {
        // 成功真正出声的判定：收到 ready 且 rate>0
        if dict["kind"] as? String == "native_state",
           (dict["playing"] as? Bool) == true {
            didPlaySuccessfully = true
        }
        DispatchQueue.main.async {
            self.onEvent?(dict)
        }
    }
}
