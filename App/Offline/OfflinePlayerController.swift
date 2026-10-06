import Foundation
import AVFoundation
import MediaPlayer

/// 播放模式
enum OfflinePlayMode: Int {
    case order       // 列表顺序播放，播完即停
    case repeatAll   // 列表循环
    case repeatOne   // 单曲循环
    case shuffle     // 随机播放
}

/// 离线曲库的原生播放控制（无界面部分）：用 AVPlayer 播放本地缓存文件，
/// 维护队列、播放模式、Now Playing 信息与锁屏/车载控制。
final class OfflinePlayerController: NSObject {

    /// 界面刷新回调（主线程）
    var onChange: (() -> Void)?

    private let player = AVPlayer()

    private var entries: [CacheEntry]
    /// 当前在“顺序列表”中的索引
    private var index: Int

    private var mode: OfflinePlayMode = .repeatAll
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?

    /// 随机模式下已经出现过的顺序索引，用于不重复地选下一首
    private var shuffleHistory: [Int] = []

    // MARK: - 生命周期

    init(entries: [CacheEntry], startIndex: Int) {
        self.entries = entries
        self.index = min(max(0, startIndex), max(0, entries.count - 1))
        super.init()
        configurePlayerObservers()
    }

    deinit {
        if let t = timeObserver { player.removeTimeObserver(t) }
        NotificationCenter.default.removeObserver(self)
    }

    private func configurePlayerObservers() {
        let interval = CMTime(value: 1, timescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] _ in
            self?.onChange?()
            self?.updateNowPlayingElapsed()
        }

        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onChange?() }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnded(_:)),
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    // MARK: - 对外属性

    var currentEntry: CacheEntry? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index]
    }
    var isPlaying: Bool { player.rate != 0 }
    var currentTime: Double { CMTimeGetSeconds(player.currentTime()) }
    var playMode: OfflinePlayMode { mode }

    // MARK: - 开始 / 停止接管

    /// 开始播放并接管锁屏/车载控制
    func start() {
        RemoteCommandController.shared.setActivePlayer(self)
        playCurrent(resetPosition: true)
    }

    /// 退出离线播放器时释放锁屏接管
    func stop() {
        player.pause()
        RemoteCommandController.shared.setActivePlayer(nil)
    }

    // MARK: - 播放当前项

    private func playCurrent(resetPosition: Bool) {
        guard let entry = currentEntry else { stop(); return }

        let fileURL = CacheStore.shared.audioFile(for: entry.key)
        let item = AVPlayerItem(url: fileURL)

        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard let self = self else { return }
            if item.status == .readyToPlay {
                self.pushNowPlaying()
            }
        }

        player.replaceCurrentItem(with: item)
        player.play()
        pushNowPlaying()
        onChange?()
    }

    // MARK: - 控制

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func next() { advance(manual: true) }
    func previous() {
        // 播放超过 3 秒，先回到本曲开头
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        moveIndex(by: -1, manual: true)
    }

    func cycleMode() {
        let all: [OfflinePlayMode] = [.order, .repeatAll, .repeatOne, .shuffle]
        let cur = mode.rawValue
        mode = OfflinePlayMode(rawValue: (cur + 1) % all.count) ?? .repeatAll
        onChange?()
    }

    // MARK: - 队列移动

    /// 播完 / 手动前进
    private func advance(manual: Bool) {
        // 单曲循环且为“自动播完”：重复本曲；手动按下一首仍正常切歌
        if mode == .repeatOne && !manual {
            seek(to: 0)
            player.play()
            return
        }

        switch mode {
        case .order:
            if index >= entries.count - 1 {
                player.pause()
                onChange?()
            } else {
                moveIndex(by: 1, manual: manual)
            }
        case .repeatOne, .repeatAll:
            moveIndex(by: 1, manual: manual)
        case .shuffle:
            moveToShuffleIndex()
        }
    }

    private func moveIndex(by delta: Int, manual: Bool) {
        guard !entries.isEmpty else { return }
        let count = entries.count
        var newIndex = (index + delta) % count
        if newIndex < 0 { newIndex += count }
        index = newIndex
        playCurrent(resetPosition: true)
    }

    private func moveToShuffleIndex() {
        guard entries.count > 1 else { seek(to: 0); player.play(); return }

        var candidate: Int
        if shuffleHistory.count >= entries.count { shuffleHistory = [index] }

        repeat {
            candidate = Int.random(in: 0..<entries.count)
        } while candidate == index || shuffleHistory.contains(candidate)

        shuffleHistory.append(candidate)
        index = candidate
        playCurrent(resetPosition: true)
    }

    // MARK: - 事件

    @objc private func handleEnded(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem,
              item === player.currentItem else { return }
        advance(manual: false)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        if type == .ended {
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                .contains(.shouldResume)
            if shouldResume { player.play() }
        }
    }

    // MARK: - Now Playing

    private func pushNowPlaying() {
        guard let entry = currentEntry else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: entry.title,
            MPMediaItemPropertyArtist: entry.artist,
            MPMediaItemPropertyPlaybackDuration: entry.duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        if let artURL = CacheStore.shared.artworkURL(for: entry.key),
           let image = UIImage(contentsOfFile: artURL.path) {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingElapsed() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - RemoteCommandPlayback（统一锁屏/车载控制协议）

protocol RemoteCommandPlayback: AnyObject {
    func remotePlay()
    func remotePause()
    func remoteNext()
    func remotePrevious()
    func remoteSeek(_ seconds: Double)
}

extension OfflinePlayerController: RemoteCommandPlayback {
    func remotePlay() { play() }
    func remotePause() { pause() }
    func remoteNext() { next() }
    func remotePrevious() { previous() }
    func remoteSeek(_ seconds: Double) { seek(to: seconds) }
}
