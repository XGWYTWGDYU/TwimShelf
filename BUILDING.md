# 构建指南

- [最快的方式：运行脚本](#最快的方式运行脚本)
- [用 Xcode 构建和运行](#用-xcode-构建和运行)
- [其他平台](#其他平台)
- [配置：config.yaml](#配置configyaml)
- [构建目录](#构建目录)
- [开启苹果平台的分享扩展](#开启苹果平台的分享扩展)
- [测试](#测试)
- [GitHub Actions 自动构建和发布](#github-actions-自动构建和发布)
- [常见问题](#常见问题)

## 最快的方式：运行脚本

```bash
./build.sh
```

macOS 和 Linux 上用 `build.sh`，Windows 上用 `build.ps1`。脚本会构建这台电脑能构建的所有版本，安装包放在 `build/apps`。

缺少的工具会询问是否安装（Rust、Flutter、Android SDK 等），不回答「是」就不会安装。执行时加上 `--yes` 可以全部自动同意。

| 命令 | 作用 |
| --- | --- |
| `./build.sh --list` | 列出所有构建目标，以及各自能在什么系统上构建 |
| `./build.sh native-macos flutter-android` | 只构建指定的目标 |
| `./build.sh --check` | 只检查工具是否齐全，不安装也不构建 |
| `./build.sh --configure` | 只应用 `config.yaml`，不构建 |
| `./build.sh --yes` | 缺什么都自动安装 |

| 构建目标 | 产物 | 构建环境 |
| --- | --- | --- |
| `native-macos` | 原生 Mac 版 `.dmg`（临时签名） | Apple Silicon Mac + Xcode |
| `native-ios` | 原生 iOS 版未签名 `.ipa` | Mac + Xcode |
| `flutter-macos` | Flutter Mac 版 `.dmg`（临时签名） | Mac + Xcode |
| `flutter-ios` | Flutter iOS 版未签名 `.ipa` | Mac + Xcode |
| `flutter-android` | Android `.apk`，每种 CPU 架构一个 | macOS、Linux 或 Windows |
| `flutter-linux` | Linux `.AppImage` | Linux |
| `flutter-windows` | Windows `setup.exe` | Windows（`build.ps1`） |

构建脚本无法帮你安装的前提条件：

- **Apple 平台**：完整的 Xcode（从 App Store 安装并打开一次），不是只装命令行工具。`build.sh` 缺 CocoaPods、CMake 时会用 Homebrew 安装，所以最好也装好 [Homebrew](https://brew.sh)。
- **所有平台**：Python 3、Git。

如果电脑上已经有 SDK，可以用环境变量指定，避免重复下载：

| 环境变量 | 作用 |
| --- | --- |
| `FLUTTER_ROOT` | 已有的 Flutter SDK（版本见 `build.sh` 开头的 `FLUTTER_VERSION`） |
| `ANDROID_HOME` | 已有的 Android SDK |
| `TL_VERSION` | 只改变安装包文件名里的版本号 |
| `TL_UPDATE_REPO` | `owner/name`，打开「检查更新」。本地构建通常留空，这时应用不会联网检查更新 |

## 用 Xcode 构建和运行

第一次打开前，先运行一次配置。这样从第一次构建开始，所有产物就都在项目的 `build/` 目录下：

```bash
./build.sh --configure
```

如果跳过这一步也能正常构建，只是第一次的产物会放到 Xcode 默认的 DerivedData 里，关闭并重新打开工程之后才会转到 `build/`。

### 原生版

```bash
open TwimShelf.xcodeproj
```

- **Mac 版**：选择 `TwimShelf-macOS` scheme，点击运行。**不需要任何开发者账号**，默认使用临时签名，可以直接在这台 Mac 上运行。
- **iOS 版**：选择 `TwimShelf-iOS` scheme，选择模拟器或者真机。
  - 模拟器：直接运行。
  - 真机：打开 `TwimShelf-iOS` target 的 **Signing & Capabilities**，在 **Team** 里选择自己的账号，然后点击运行。免费的个人账号也可以，需要 App Group 的分享扩展默认是关闭的。
- **Mac 版要长期使用**：在 Mac target 的 **Signing & Capabilities** 里勾选 **Automatically manage signing** 并选择 Team，之后重新编译时系统钥匙串不会反复询问权限。

Rust 核心会在构建时自动编译；如果还没有安装 Rust，第一次构建时会自动装到 `~/.cargo`。第一次构建还要下载 Swift 依赖（约 500 MB），需要等一段时间。

### Flutter 版

```bash
open flutter/app/ios/Runner.xcworkspace
```

```bash
open flutter/app/macos/Runner.xcworkspace
```

选择 `Runner` scheme 点击运行即可。scheme 的预处理步骤会准备好一切：Flutter SDK、Dart 依赖、Rust 核心和 CocoaPods。这些步骤的输出在 `build/cache/logs/xcode-prepare.log` 里，需要 CMake（`brew install cmake`）。

签名方式和原生版相同：Mac 版不需要账号，iOS 真机在 `Runner` target 里选择自己的 Team。

### 不通过Xcode

把 10 位的 Team ID 写进 `config.yaml` 的 `native.development_team` 和 `flutter.development_team`。Team ID 可以在 [Apple Developer 账号页面](https://developer.apple.com/account)或 Xcode 的账号设置里查到。这是个人信息，**不要提交这个改动**。

## 其他平台

### Android

```bash
./build.sh flutter-android
```

可以在 macOS、Linux 或 Windows 上构建，脚本会询问并下载 Android SDK 和 NDK（约 3 GB）。**项目路径里不能有空格**，原因见[常见问题](#常见问题)。

默认使用调试密钥签名，适合自己使用。需要用自己的发布密钥时，新建 `flutter/app/android/key.properties`（已被 Git 忽略）：

```properties
storeFile=/绝对路径/release.jks
storePassword=...
keyAlias=...
keyPassword=...
```

### Linux

```bash
./build.sh flutter-linux
```

脚本会用系统的包管理器（apt、dnf 或 pacman）询问并安装 GTK、libmpv、libsecret、Vulkan 等开发包。为了兼容更多发行版，发布版本请在尽量旧的发行版上构建。

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1 flutter-windows
```

需要 Windows 10 1803 或更新版本。脚本通过 winget 询问并安装 Visual Studio 生成工具（含 C++）、Rust、Flutter 和 Vulkan SDK。更多说明见 [docs/windows-build.md](docs/windows-build.md)。

## 配置：config.yaml

Bundle ID 和包名、版本号、签名、分享扩展开关和构建位置都在根目录的 [`config.yaml`](config.yaml) 里，代码里用到它们的地方都引用这里。应用名称 TwimShelf 直接写在代码里，不在配置中。改完之后不需要手动做什么，`build.sh`、`build.ps1` 和 Xcode 的构建按钮都会先按它重新生成配置。

| 配置项 | 含义 |
| --- | --- |
| `version`、`build_number` | 所有平台共用的版本号和构建号 |
| `build.dir` | 构建缓存和产物的位置 |
| `native.bundle_id` | 原生版的 Bundle ID 前缀：iOS 用 `<前缀>.ios`，Mac 用 `<前缀>.mac` |
| `flutter.apple_bundle_id` | Flutter 版 iOS 和 macOS 的 Bundle ID |
| `flutter.android_package` | Android 的 applicationId |
| `flutter.desktop_id` | Linux 的应用 ID |
| `native.share_extension_ios`、`native.share_extension_mac` | 原生版的分享扩展 |
| `flutter.share_extension_ios`、`flutter.share_extension_mac` | Flutter 版苹果平台的分享扩展 |
| `flutter.share_extension` | Android「分享到」、Windows「发送到」、Linux「打开方式」 |
| `native.development_team`、`flutter.development_team` | 开发团队，默认留空 |
| `native.mac_signing_identity` | Mac 版指定签名身份，默认留空 |

**换图标**：替换 `icon.png`。要求是正方形 PNG，自带圆角和透明边，建议 1024×1024 以上。各平台的图标都会自动生成：Mac 版直接缩放，iOS 和 Android 版取图案部分并铺满。第一次生成时需要 Pillow，脚本会自动下载到构建缓存里，不会安装到系统。

**分发自己的版本**：请把 Bundle ID 和包名都改成自己的。

## 构建目录

默认的 `build.dir` 是 `build`，相对于项目根目录，已被 Git 忽略。不论用脚本、Xcode 还是 Flutter 命令构建，位置都一样：

| 位置 | 内容 |
| --- | --- |
| `build/cache` | 所有缓存：Rust、Xcode Derived Data、Flutter、Gradle、Dart 依赖、下载的 SDK、日志 |
| `build/apps` | 安装包 |

完整构建所有平台大约需要几十 GB。空间不够时可以把 `build.dir` 改成其他磁盘上的绝对路径，或者直接删除 `build` 目录来清理。CocoaPods 的 `Pods` 是个例外，它必须留在工程目录里（同样被 Git 忽略）。

## 开启苹果平台的分享扩展

iOS 和 Mac 的「分享到 TwimShelf」默认关闭。扩展通过 App Group 把文件交给主应用，而 App Group 必须有开发团队的签名才能使用：临时签名的 Mac 版连共享目录都写不进去。因此 GitHub Actions 构建的 Mac 版也不带分享扩展。

| 平台 | 需要的账号 |
| --- | --- |
| Mac | 任意 Apple 账号，免费的也可以 |
| iOS | 付费的 Apple Developer Program 账号 |

开启方法：

1. 在 `config.yaml` 里把对应的 `share_extension_ios` 或 `share_extension_mac` 改成 `true`，并填写同一节的 `development_team`（只在 Xcode 里选 Team 不够）。这是个人信息，不要提交这个改动。
2. 共享组由 Bundle ID 决定：iOS 使用 `group.<bundle_id>`，Mac 使用 `<Team ID>.<bundle_id>`，不用单独配置。
3. 运行配置。原生版开关变化时需要重新生成工程，所以要先安装 XcodeGen：

```bash
brew install xcodegen
```

```bash
./build.sh --configure
```

不开分享扩展时，主应用自己的导入功能不受影响。Android「分享到」、Windows「发送到」、Linux「打开方式」不需要 App Group，默认开启。

## 测试

Rust 核心：

```bash
cd core && cargo test --locked --features heif
```

原生版的逻辑检查：

```bash
scripts/checks/run.sh
```

Flutter 版：

```bash
cd flutter/app && flutter test
```

网格缩放回放测试在 Xcode 里运行 `GridTests` scheme。标记为 `#[ignore]` 的 Rust 测试要联网或者要真实账号，运行前先看一下源码，需要的帖子链接和 Cookie 通过环境变量传入。

调试时请使用合成资料库，不要指向真实数据：[docs/testdata.md](docs/testdata.md) 说明了如何生成，以及如何用 `TL_LIBRARY_DIR` 隔离。Mac 的 Debug 版是独立的应用，有自己的 Bundle ID 和数据目录，不会碰到已安装的正式版。

## GitHub Actions 自动构建和发布

[`.github/workflows/build.yml`](.github/workflows/build.yml) 在 GitHub 的机器上构建所有平台的所有版本，并运行 Rust 测试。

| 触发方式 | 结果 |
| --- | --- |
| Pull Request | 构建和测试，安装包保存为 workflow artifact |
| 推送到 `main` | 同上。如果 `config.yaml` 的版本号还没有对应的 `v<version>` tag，所有任务通过后自动发布 Release |
| 手动运行（Actions 页面） | 和推送相同 |

只改文档（`*.md`、`docs/`）的推送不会触发构建。

**发布新版本**：提高 `config.yaml` 里的 `version` 和 `build_number`，推送到 `main`。

Release 页面没有说明文字，只包含所有安装包、`SHA256SUMS.txt`、`BUILD-INFO.json` 和 `THIRD-PARTY-NOTICES.txt`。

**Fork 之后**：工作流可以直接运行，不需要配置任何密钥，「检查更新」会自动指向你的仓库。如果要发布，请先把 Bundle ID 和包名改成自己的。

**可选的 Android 发布密钥**：本仓库的 Release 已经配置了发布密钥，Fork 的仓库需要自己配置。不配置时，每次构建都使用当次机器的临时调试密钥，新版 APK 无法覆盖安装旧版。要让用户能够直接升级，在仓库的 Settings › Secrets and variables › Actions 里添加：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | 发布密钥库文件的 base64（`base64 -i release.jks`） |
| `ANDROID_KEYSTORE_PASSWORD` | 密钥库密码 |
| `ANDROID_KEY_ALIAS` | 密钥别名 |
| `ANDROID_KEY_PASSWORD` | 密钥密码 |

请妥善备份密钥库。丢失之后，Android 版就无法再发布可覆盖安装的更新。

## 常见问题

**Xcode 提示 Bundle ID 不可用（"cannot be registered to your development team"）**

Apple 要求 Bundle ID 全球唯一，已经被其他团队注册的不能再用。把 `config.yaml` 里的 `native.bundle_id`（原生版）或 `flutter.apple_bundle_id`（Flutter 版）改成自己的，比如 `com.yourname.twimshelf`，不要提交这个改动。注意：改 Bundle ID 后设备上会被当成另一个应用，数据不会自动带过来。

**Xcode 提示 "Signing for ... requires a development team"**

iOS 真机必须选择 Team，见[用 Xcode 构建和运行](#用-xcode-构建和运行)。

**免费账号装到真机后，几天就打不开了**

这是 Apple 的限制，免费账号的描述文件 7 天过期，重新构建安装即可。

**Android、Linux 或 Windows 构建报错：`cannot be built in a path with spaces`**

llama.cpp 的 Vulkan 后端在带空格的路径里无法构建。请把项目移到不含空格的路径，或者把 `build.dir` 改到不含空格的绝对路径。

**Flutter 的 iOS / macOS 版报错：`did not contain an Info.plist`、`Library 'tl_core' not found`**

依赖没有按顺序准备好。`build.sh` 和 Xcode 的预处理步骤都会自动按顺序执行；如果手动构建，顺序是：

```bash
scripts/flutter/build_core.sh ios
```

```bash
cd flutter/app && flutter pub get && cd ios && pod install
```

```bash
cd flutter/app && flutter build ios --no-codesign
```

**`pod install` 报编码错误**

CocoaPods 需要 UTF-8 环境，运行 `export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`。

**macOS 提示“无法打开，因为无法验证开发者”**

自己构建或下载的临时签名版本都会这样。到「系统设置 › 隐私与安全性」选择「仍要打开」。

**开关分享扩展之后提示需要 XcodeGen**

原生工程需要重新生成：`brew install xcodegen`，然后运行 `./build.sh --configure`。
