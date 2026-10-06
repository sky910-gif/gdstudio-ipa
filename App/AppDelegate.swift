import UIKit
import AVFoundation

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    private let audioSession = AudioSessionController.shared

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 尽早激活“播放类”音频会话，是后台/锁屏能持续出声的前提
        audioSession.activate()

        // 后台整理历史重复缓存（不阻塞启动）
        DispatchQueue.global(qos: .utility).async {
            CacheStore.shared.removeAllDuplicates()
        }

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = .black
        window?.rootViewController = WebViewController()
        window?.makeKeyAndVisible()
        return true
    }
}
