import UIKit

/// 离线曲库：展示已缓存歌曲，点击播放，滑动删除，可清空缓存。
final class CacheLibraryViewController: UIViewController {

    /// 点击某首歌时回调（由外部控制 WebView 播放）
    var onPick: ((CacheEntry) -> Void)?

    private var entries: [CacheEntry] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "离线曲库"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem =
            UIBarButtonItem(title: "清空", style: .plain, target: self, action: #selector(confirmClear))

        setupTable()
        setupEmptyLabel()

        NotificationCenter.default.addObserver(
            self, selector: #selector(reloadData),
            name: CacheStore.changedNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadData()
    }

    private func setupTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(CacheSongCell.self, forCellReuseIdentifier: CacheSongCell.reuseID)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupEmptyLabel() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.text = "还没有缓存歌曲\n在线播放过的歌曲会自动出现在这里"
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .systemFont(ofSize: 15)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    @objc private func reloadData() {
        entries = CacheStore.shared.allEntries()
        tableView.reloadData()
        let empty = entries.isEmpty
        emptyLabel.isHidden = !empty
        tableView.isHidden = empty

        let size = CacheStore.shared.totalSize()
        let mb = Double(size) / 1024 / 1024
        title = entries.isEmpty ? "离线曲库" : String(format: "离线曲库 · %.1f MB", mb)
    }

    @objc private func confirmClear() {
        guard !entries.isEmpty else { return }
        let alert = UIAlertController(title: "清空全部缓存？", message: "已缓存的歌曲将被删除", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { _ in
            CacheStore.shared.clearAll()
        })
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDataSource / Delegate

extension CacheLibraryViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: CacheSongCell.reuseID, for: indexPath) as! CacheSongCell
        cell.configure(with: entries[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = entries[indexPath.row]
        onPick?(entry)
        navigationController?.dismiss(animated: true)
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration? {
        let del = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            guard let self = self else { done(false); return }
            let key = self.entries[indexPath.row].key
            CacheStore.shared.delete(key: key)
            // changedNotification 会触发 reloadData，这里不手动改数组
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [del])
    }
}

// MARK: - Cell

private final class CacheSongCell: UITableViewCell {
    static let reuseID = "CacheSongCell"

    private let coverView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        coverView.translatesAutoresizingMaskIntoConstraints = false
        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.layer.cornerRadius = 6
        coverView.backgroundColor = .secondarySystemFill
        contentView.addSubview(coverView)

        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            coverView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            coverView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            coverView.widthAnchor.constraint(equalToConstant: 48),
            coverView.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with entry: CacheEntry) {
        titleLabel.text = entry.title
        let sizeText = String(format: "%.1f MB", Double(entry.size) / 1024 / 1024)
        subtitleLabel.text = entry.artist.isEmpty
            ? sizeText
            : "\(entry.artist) · \(sizeText)"

        if let url = CacheStore.shared.artworkURL(for: entry.key) {
            coverView.image = UIImage(contentsOfFile: url.path)
        } else {
            coverView.image = nil
        }
    }
}
