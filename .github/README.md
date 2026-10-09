# Kazumi（非官方修改版）

这是 [Predidit/Kazumi](https://github.com/Predidit/Kazumi) 的一个非官方修改版，**与官方 Kazumi 无关**。
应用本身、规则体系和绝大部分代码都来自上游项目，功劳属于 Kazumi 的作者和贡献者。
本仓库只在上游基础上修了一些上游 issue 里提到、但暂未合入的问题，并持续合并上游的新版本。

请不要把这个版本的问题反馈到上游仓库。遇到问题请在 [本仓库的 Issues](https://github.com/KaiC5504/Kazumi/issues) 里提。

## 和官方版的区别

| 改动 | 平台 | 相关上游 issue |
|---|---|---|
| SyncPlay 一起看：缓和同步漂移，不再频繁跳跃式追帧；可搭配任意 SyncPlay 服务器 | 全部 | [#1588](https://github.com/Predidit/Kazumi/issues/1588)、[#2441](https://github.com/Predidit/Kazumi/issues/2441)、[#1646](https://github.com/Predidit/Kazumi/issues/1646) |
| 每部番剧单独记住播放倍速（一起看时固定 1.0×） | 全部 | [#2572](https://github.com/Predidit/Kazumi/issues/2572)、[#1599](https://github.com/Predidit/Kazumi/issues/1599) |
| WebDAV 自动同步：除启动时外，切到后台、回到前台、退出播放器时也会同步历史记录；追番列表改动后立即上传 | 全部 | [#1952](https://github.com/Predidit/Kazumi/issues/1952)、[#2613](https://github.com/Predidit/Kazumi/issues/2613) |
| Bangumi 同步：一集看到 90% 时自动标记为看过（需在设置中配置 Bangumi 令牌） | 全部 | [#2185](https://github.com/Predidit/Kazumi/issues/2185) |
| 新集提醒：在看的番剧在日本首播次日 10:00 发送本地通知（界面设置 → 提醒） | Android、iOS | [#2370](https://github.com/Predidit/Kazumi/issues/2370)、[#1644](https://github.com/Predidit/Kazumi/issues/1644) |
| 在线播放时从 [AniSkip](https://aniskip.com) 查询片头片尾时间并提示跳过（播放设置中可关闭） | 全部 | [#2420](https://github.com/Predidit/Kazumi/issues/2420)、[#218](https://github.com/Predidit/Kazumi/issues/218) |
| 首次启动自动安装官方规则，之后官方新增的规则也会自动安装（删除过的不会再装回来） | 全部 | — |
| 片源旁显示实测画质标记（分辨率、编码、码率） | 全部 | — |
| 应用更新后已下载的剧集不再丢失（iOS 更新会改变应用目录，下载记录会自动指向新位置） | iOS | [#2243](https://github.com/Predidit/Kazumi/issues/2243) |
| 本地超分预处理（实验性，需要带 libplacebo 的 ffmpeg，例如 gyan.dev 的 full 版本） | Windows | — |

没有包含的功能：作者自用的「一起看」共享片库和云端超分，它们依赖作者自己的服务器，公开版中已隐藏。

## 下载与安装

在 [Releases](https://github.com/KaiC5504/Kazumi/releases) 下载：

- **Android**（arm64）：`Kazumi_android_X.Y.Z.apk`
- **Windows**（x64，免安装）：`Kazumi_windows_X.Y.Z.zip`，解压后运行 `kazumi.exe`
- **iOS**（未签名）：`Kazumi_ios_X.Y.Z_no_sign.ipa`，需用 AltStore、SideStore 或 TrollStore 等工具自签安装

说明：

- 可以和官方 Kazumi 同时安装：Android 包名和 iOS Bundle ID 不同，Windows 使用单独的数据目录（`%APPDATA%\KazumiFork\kazumi`），两边的数据互不影响。
- 应用名和图标与官方版相同。区分方法：本版本的「我的 → 关于」里有一段标明来源的说明和本仓库的链接。
- Windows 首次运行若提示「Windows 已保护你的电脑」，点「更多信息 → 仍要运行」（安装包没有代码签名）。
- 如果电脑上也装了官方版，首次启动时建议在「创建桌面快捷方式」提示中选择不创建，否则会覆盖官方版的同名快捷方式。
- 应用内检查更新只查询本仓库的 Releases。Android 可在应用内下载并安装；Windows 和 iOS 会打开下载页面。国内网络下载失败时，请用浏览器打开 Releases 页面下载。

## 从官方版迁移

在官方版和本版本中配置同一个 WebDAV，同步后可以迁移：**历史记录、追番列表、弹幕屏蔽词**。
其他设置（播放器、规则等）不会迁移，需要重新设置；规则会在首次启动时自动安装。

## 隐私

本版本不连接作者自己的任何服务器。它会访问的地址：

- 你安装的规则对应的视频站点；
- Bangumi（`api.bgm.tv`、`next.bgm.tv`，以及官方版同样使用的镜像 `api.kazumi.fyi`、`api.bgmapi.com`）；
- 弹弹play（`api.dandanplay.net`，弹幕）；
- AniSkip（`api.aniskip.com`）和 `rhilip.github.io`（番剧 ID 对照表），用于查询片头片尾；
- `cdn.gh-proxy.org`（第三方 GitHub 加速，用于下载规则）、`raw.githubusercontent.com`；
- `api.github.com` / `github.com`（检查更新、下载更新）；
- 你自己填写的 SyncPlay 服务器和 WebDAV 服务器；
- 使用以图搜番时的 trace.moe（与官方版相同）。

## 从源码构建

```bash
fvm flutter pub get
fvm flutter build apk --release --split-per-abi --target-platform android-arm64 \
  --dart-define=KAZUMI_PUBLIC=true --dart-define=KAZUMI_LIBRARY_SERVER=
fvm flutter build windows --release \
  --dart-define=KAZUMI_PUBLIC=true --dart-define=KAZUMI_LIBRARY_SERVER=
```

不加 `KAZUMI_PUBLIC=true` 构建出来的是作者自用版本，会连接作者的服务器，请不要这样分发。
Flutter 版本见 `pubspec.yaml`；Windows 需要 Visual Studio 2026 生成工具。

## 许可与致谢

- 本项目沿用上游的 [GPL-3.0](https://github.com/KaiC5504/Kazumi/blob/main/LICENSE) 许可证。每个 Release 的标签即对应的完整源代码。
- 上游项目：[Predidit/Kazumi](https://github.com/Predidit/Kazumi) 及其所有贡献者；规则来自 [KazumiRules](https://github.com/Predidit/KazumiRules)。
- 应用图标是上游 Kazumi 的图标，作者为 [Yuquanaaa](https://www.pixiv.net/users/66219277)（[Pixiv 原作](https://www.pixiv.net/artworks/116666979)），版权归原作者所有，详见[上游 README 中的说明](https://github.com/Predidit/Kazumi#readme)。
