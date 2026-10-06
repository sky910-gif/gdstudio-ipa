import UIKit
import AVKit
import MediaPlayer

/// 离线曲库的全屏原生音乐播放器界面：
/// 大封面、歌名/歌手、可拖动进度条、播放模式、上一首/播放暂停/下一首、AirPlay、关闭。
final class OfflinePlayerViewController: UIViewController {

    private let controller: OfflinePlayerController

    // MARK: - 界面元素

    private let gradientLayer = CAGradientLayer()
    private let coverImageView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()

    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let progressSlider = UISlider()

    private let modeButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let airplayView = AVRoutePickerView()

    private let closeButton = UIButton(type: .system)

    private var isScrubbing = false

    // MARK: - 初始化

    init(entries: [CacheEntry], startIndex: Int) {
        self.controller = OfflinePlayerController(entries: entries, startIndex: startIndex)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupBackground()
        setupLayout()
        setupActions()

        controller.onChange = { [weak self] in
            self?.refresh()
        }
        controller.onError = { [weak self] message in
            let alert = UIAlertController(title: "无法播放", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            self?.present(alert, animated: true)
        }
        controller.start()
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 仅当真正被关闭（dismiss）时停止接管
        if isBeingDismissed {
            controller.stop()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradientLayer.frame = view.bounds
    }

    // MARK: - 背景

    private func setupBackground() {
        view.backgroundColor = UIColor(red: 0.06, green: 0.05, blue: 0.08, alpha: 1)
        gradientLayer.colors = [
            UIColor(red: 0.18, green: 0.12, blue: 0.24, alpha: 1).cgColor,
            UIColor(red: 0.04, green: 0.03, blue: 0.06, alpha: 1).cgColor,
        ]
        gradientLayer.locations = [0, 1]
        view.layer.addSublayer(gradientLayer)
    }

    // MARK: - 布局

    private func setupLayout() {
        closeButton.tintColor = .white
        let closeConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: closeConfig), for: .normal)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.layer.cornerRadius = 14
        coverImageView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coverImageView)

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        artistLabel.font = .systemFont(ofSize: 17)
        artistLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        artistLabel.textAlignment = .center
        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(artistLabel)

        // 进度条
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        let thumb = UIImage()
        progressSlider.setThumbImage(thumbImage(), for: .normal)
        progressSlider.minimumTrackTintColor = UIColor.white
        progressSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        view.addSubview(progressSlider)

        currentTimeLabel.font = .systemFont(ofSize: 12)
        currentTimeLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(currentTimeLabel)

        durationLabel.font = .systemFont(ofSize: 12)
        durationLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        durationLabel.textAlignment = .right
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(durationLabel)

        // 控制按钮
        setupControlImages()
        for b in [modeButton, previousButton, playPauseButton, nextButton] {
            b.tintColor = .white
            b.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(b)
        }

        airplayView.tintColor = .white
        airplayView.activeTintColor = UIColor.white.withAlphaComponent(0.6)
        airplayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(airplayView)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),

            coverImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            coverImageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 54),
            coverImageView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.72),
            coverImageView.heightAnchor.constraint(equalTo: coverImageView.widthAnchor),

            titleLabel.topAnchor.constraint(equalTo: coverImageView.bottomAnchor, constant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            currentTimeLabel.topAnchor.constraint(equalTo: artistLabel.bottomAnchor, constant: 28),
            currentTimeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            currentTimeLabel.widthAnchor.constraint(equalToConstant: 46),

            durationLabel.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),
            durationLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            durationLabel.widthAnchor.constraint(equalToConstant: 46),

            progressSlider.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),
            progressSlider.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 10),
            progressSlider.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -10),

            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -46),

            previousButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            previousButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -34),

            nextButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 34),

            modeButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            modeButton.trailingAnchor.constraint(equalTo: previousButton.leadingAnchor, constant: -30),

            airplayView.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            airplayView.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 30),
            airplayView.widthAnchor.constraint(equalToConstant: 30),
            airplayView.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func setupControlImages() {
        let large = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        let medium = UIImage.SymbolConfiguration(pointSize: 25, weight: .medium)
        let play = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)

        previousButton.setImage(UIImage(systemName: "backward.fill", withConfiguration: large), for: .normal)
        nextButton.setImage(UIImage(systemName: "forward.fill", withConfiguration: large), for: .normal)
        playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: play), for: .normal)
        modeButton.setImage(UIImage(systemName: "repeat", withConfiguration: medium), for: .normal)
        // AirPlay：系统 AVRoutePickerView 自带标准图标，无需替换
    }

    private func thumbImage() -> UIImage {
        let size = CGSize(width: 12, height: 12)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - 事件

    private func setupActions() {
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        modeButton.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        previousButton.addTarget(self, action: #selector(previousTapped), for: .touchUpInside)
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        progressSlider.addTarget(self, action: #selector(scrubStart), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside])
    }

    @objc private func close() { dismiss(animated: true) }
    @objc private func modeTapped() { controller.cycleMode() }
    @objc private func previousTapped() { controller.previous() }
    @objc private func nextTapped() { controller.next() }
    @objc private func playPauseTapped() {
        if controller.isPlaying { controller.pause() } else { controller.play() }
    }

    // MARK: - 拖动进度

    @objc private func scrubStart() { isScrubbing = true }
    @objc private func scrubChanged() {
        let dur = controller.currentEntry?.duration ?? 0
        currentTimeLabel.text = formatTime(dur * Double(progressSlider.value))
    }
    @objc private func scrubEnd() {
        let dur = controller.currentEntry?.duration ?? 0
        controller.seek(to: dur * Double(progressSlider.value))
        isScrubbing = false
    }

    // MARK: - 刷新

    private func refresh() {
        let entry = controller.currentEntry
        titleLabel.text = entry?.title
        artistLabel.text = entry?.artist

        let duration = entry?.duration ?? 0
        durationLabel.text = formatTime(duration)

        if let key = entry?.key,
           let url = CacheStore.shared.artworkURL(for: key) {
            coverImageView.image = UIImage(contentsOfFile: url.path)
        } else {
            coverImageView.image = nil
        }

        let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        let icon = controller.isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: icon, withConfiguration: config), for: .normal)

        updateModeIcon()

        if !isScrubbing {
            progressSlider.value = duration > 0 ? Float(controller.currentTime / duration) : 0
            currentTimeLabel.text = formatTime(controller.currentTime)
        }
    }

    private func updateModeIcon() {
        let medium = UIImage.SymbolConfiguration(pointSize: 25, weight: .medium)
        let icon: String
        switch controller.playMode {
        case .order: icon = "list.bullet"
        case .repeatAll: icon = "repeat"
        case .repeatOne: icon = "repeat.1"
        case .shuffle: icon = "shuffle"
        }
        modeButton.setImage(UIImage(systemName: icon, withConfiguration: medium), for: .normal)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
