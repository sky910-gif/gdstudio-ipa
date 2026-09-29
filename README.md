# 把 music.gdstudio.xyz 打包成 IPA（无 Mac / 无付费开发者账号）

用一个原生 **WKWebView 外壳**把 <https://music.gdstudio.xyz> 包成 iOS App，
解决网页版在 **iPhone 锁屏 / 切到后台后无法自动播放下一首** 的问题。

## 为什么包成 App 就能锁屏连播

| 差异 | Safari 网页 | 本外壳 App |
| --- | --- | --- |
| 后台音频权限 | 没有，锁屏即挂起 JS | 工程开启 `UIBackgroundModes: audio` |
| 音频会话 | 无 | `AVAudioSession` 使用 `.playback`（静音开关不影响、锁屏不断） |
| 切歌间隙 | JS 被冻结，无法加载下一首 | 用零音量静音音频保活，JS 持续运行，自动下一首 |
| 锁屏界面 | 无控件 / 无封面 | 显示标题、歌手、封面、进度，支持线控和锁屏切歌 |

> 注意：外壳加载的是**在线网址**，使用时仍需联网；网站改版若更换了播放器结构，
> 锁屏切歌按钮的"猜 DOM"兜底可能需要微调（核心的后台连播不受影响）。

---

## 0. 限制

- Windows 无法本地构建 iOS 包（需要 Xcode/macOS），本方案用 **GitHub Actions 云端 macOS** 免费构建。
- 产出的是**未签名 IPA**，必须用 **Sideloadly / AltStore + 普通 Apple ID** 自签安装。
- 免费 Apple ID：App **7 天后失效**需重签；同时最多 3 个自签 App。
- 想要 1 年有效需 ¥688/年的 Apple Developer Program。

## 1. 新建 GitHub 仓库并上传本目录内容

1. GitHub 右上角 **New repository**，名字随意（如 `gdstudio-ipa`），建议建为 **Public**。
2. 把**本文件夹（`gdstudio-ipa`）里的所有内容**传到仓库**根目录**，最终结构：

```text
仓库根目录/
├─ .github/workflows/ios-ipa.yml
├─ project.yml
├─ App/
│  ├─ AppDelegate.swift
│  ├─ AudioSessionController.swift
│  ├─ RemoteCommandController.swift
│  ├─ WebViewController.swift
│  ├─ bridge.js
│  └─ Silence.wav
└─ README.md
```

上传方式任选：

- **网页端**：仓库页 `Add file → Upload files`，把内容拖进去（注意保持上述目录层级）；
- **命令行**（在本目录执行）：

```bash
git init
git add .
git commit -m "add gdmusic webview wrapper"
git branch -M main
git remote add origin https://github.com/你的用户名/gdstudio-ipa.git
git push -u origin main
```

## 2. 运行云端构建

1. 仓库页点 **Actions**，出现绿色提示则点 **I understand my workflows, enable them**。
2. 左侧选 **Build GDMusic IPA (unsigned)** → 右侧 **Run workflow** → 绿色 **Run workflow**。
3. 等待约 10–15 分钟，显示绿色对勾即成功。

> 若想换一个要包装的音乐站点，先改 `App/WebViewController.swift` 顶部的 `targetURL`，
> 提交后 Actions 会自动重新构建。

## 3. 下载 IPA

进入成功的运行记录，拉到最下方 **Artifacts**，下载 **`GDMusic-unsigned-ipa`**（zip，解压得到 `GDMusic-1.0.0-unsigned.ipa`）。Artifacts 保留 14 天。

## 4. 自签安装到 iPhone

### 方式 A：Sideloadly（Windows 推荐，最简单）

1. 安装**官网版 iTunes**（非 Microsoft Store 版）并登录过一次；下载 <https://sideloadly.io/>。
2. 数据线连接 iPhone 并在手机上点**信任**此电脑。
3. 打开 Sideloadly：**iDevice** 选手机，**IPA** 选下载的包，**Apple account** 输入 Apple ID（建议小号）。
4. 点 **Start** 等待完成。
5. iPhone 进入 **设置 → 通用 → VPN与设备管理**，点你的 Apple ID 描述文件 → **信任**。

### 方式 B：AltStore（支持同 Wi-Fi 后台续签）

安装 AltServer（<https://altstore.io/>），在 AltStore 的 **My Apps → ＋** 选择 IPA 安装，同样需信任描述文件。

## 5. 验证锁屏连播

1. 打开桌面的 **GD音乐**，进入网页后**手动点一首歌开始播放**（首次播放需用户手势）。
2. 直接锁屏：当前歌播完应**自动播放下一首**；锁屏界面可见封面/标题和切歌按钮。
3. 若锁屏切歌按钮个别曲目无效，属网页播放器结构差异，自动连播仍正常；可把网站播放器的
   按钮 class 补充到 `App/bridge.js` 的选择器里重新构建。

## 6. 常见问题

- **构建红色失败**：看日志末尾；`brew install xcodegen` 偶发网络问题，重新 Run workflow 即可。
- **装不上 / 签名无效**：确认已信任描述文件；免费名额满（≤3 个）就删掉旧的自签 App。
- **7 天过期**：无需重新构建，复用同一个 IPA 重新走第 4 步签名即可。
- **有声但锁屏不切歌**：后台连播靠原生音频保活，已生效；切歌按钮选择器是 best-effort，
  以网页实际 DOM 为准。
- **想离线使用**：可把网页静态文件放进 App 用 `loadFileURL` 加载（音乐源仍需联网），需要时可再扩展。
