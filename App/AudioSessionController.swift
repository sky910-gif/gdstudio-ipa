import AVFoundation
import Foundation

/// 管理“播放类”音频会话，并用一段零音量静音音频在切歌间隙保活：
/// iOS 只有在 App 正在出声时才允许网页在后台继续执行 JS。
/// 歌曲之间的几秒空隙里，让静音音频顶上去，WKWebView 就不会被挂起，
/// 从而能正常触发“播放下一首”。
final class AudioSessionController: NSObject {

    static let shared = AudioSessionController()

    private var silencePlayer: AVAudioPlayer?
    /// 保活停止的延迟任务（暂停播放后宽限一会儿，避免误停）
    private var stopWorkItem: DispatchWorkItem?
    private(set) var isKeepingAlive = false

    private override init() {
        super.init()
        setupSilencePlayer()
    }

    private func setupSilencePlayer() {
        guard let url = Bundle.main.url(forResource: "Silence", withExtension: "wav") else {
            NSLog("[GDMusic] 未找到 Silence.wav，切歌间隙保活不可用")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1   // 无限循环
            player.volume = 0          // 静音，仅用于保活音频会话
            player.prepareToPlay()
            silencePlayer = player
        } catch {
            NSLog("[GDMusic] Silence.wav 初始化失败: \(error)")
        }
    }

    /// 配置并激活 playback 会话：静音开关不影响、锁屏不中断
    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            NSLog("[GDMusic] 音频会话激活失败: \(error)")
        }

        // 电话等中断结束后，尝试恢复
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        // 拔耳机时系统会自动暂停；重新插入后不自动恢复（交给网页处理）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    /// 网页内正在播放时调用：开始静音保活
    func beginKeepAlive() {
        DispatchQueue.main.async {
            self.stopWorkItem?.cancel()
            guard !self.isKeepingAlive else { return }
            self.isKeepingAlive = true
            self.silencePlayer?.play()
        }
    }

    /// 网页内暂停/停止时调用：宽限 30 秒后停止保活，
    /// 覆盖“自动切歌”造成的短暂停顿。
    func endKeepAliveAfterGrace() {
        DispatchQueue.main.async {
            self.stopWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.silencePlayer?.pause()
                self.isKeepingAlive = false
            }
            self.stopWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        }
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .ended:
            // 中断结束，重新激活会话（网页的音频会自行恢复或继续下一首）
            try? AVAudioSession.sharedInstance().setActive(true)
        default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
            reason == .oldDeviceUnavailable
        else { return }
        // 拔掉耳机：保持会话，但让静音保活也进入宽限停止
        endKeepAliveAfterGrace()
    }
}
