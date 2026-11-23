# 开发 Spacebar 3D

[English](../DEVELOPMENT.md) | **简体中文** | [Español](../es/DEVELOPMENT.md) | [Français](../fr/DEVELOPMENT.md) | [Deutsch](../de/DEVELOPMENT.md) | [日本語](../ja/DEVELOPMENT.md) | [Português (Brasil)](../pt-BR/DEVELOPMENT.md) | [한국어](../ko/DEVELOPMENT.md) | [Italiano](../it/DEVELOPMENT.md) | [Русский](../ru/DEVELOPMENT.md)

构建、测试和调试原生 macOS 应用及其 Quick Look 扩展。功能和格式支持限制请参阅 [README](README.md)。

[环境要求](#requirements) · [构建](#build-local) · [测试](#tests) · [架构](#how-it-works) · [故障排查](#troubleshooting) · [分发](#distribution-signing--notarization)

除非另有说明，以下 shell 命令均在仓库根目录运行。

<a id="requirements"></a>

## 环境要求

| 要求 | 说明 |
| :--- | :--- |
| 运行 macOS 26 或更高版本的 Apple 芯片 Mac | 项目和 Assimp 的构建目标均为 `arm64`，不生成 Intel 架构版本。 |
| 完整版 Xcode，包含 macOS 26 或更新的 SDK | 仅安装 Command Line Tools 不够。当前本地开发环境使用 Xcode 27.0。 |
| XcodeGen | 从 `project.yml` 生成 Xcode 项目。 |
| CMake 和 Ninja | 构建原生依赖 Assimp。 |
| Python 3 | 运行本地化一致性检查。 |
| 开发签名身份 | 安装后的应用、扩展及共享 App Group 需要使用，详见下文。 |

```bash
brew install xcodegen cmake ninja
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

如果 shell 当前选择了 Command Line Tools 或其他 Xcode 安装，请在构建前为该 shell 指定完整版 Xcode：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

当 `xcode-select` 指向 Command Line Tools 时，`build.sh` 也会检测上述标准安装位置。直接运行 `xcodebuild` 或依赖构建命令时，需要自行确保开发目录正确。

<a id="build-local"></a>

## 本地构建

<a id="configure-signing"></a>

### 配置签名

仓库中的配置使用 [`project.yml`](../../project.yml) 指定的开发团队。使用自己的团队时：

1. 在 `project.yml` 中设置 `DEVELOPMENT_TEAM` 和合适的 bundle 标识符。
2. 为该团队配置 App Group。在 [`Spacebar3D.entitlements`](../../Spacebar3D/App/Spacebar3D.entitlements)、[`Spacebar3DExtension.entitlements`](../../Spacebar3D/Extension/Spacebar3DExtension.entitlements) 以及 [`ViewerSettings.swift`](../../Spacebar3D/Shared/ViewerSettings.swift) 的 `ViewerSettings.appGroup` 中使用相同的组标识符。
3. 确保 Xcode 能使用团队的 Apple Development 证书及所需的预置资源。修改配置后重新生成项目。

当前 App Group 为 `V3AQWQ8JMY.com.vitalis.Spacebar3D`。仅在构建命令中更换团队不会更新此标识符。未签名或临时签名的构建不能替代对扩展注册和共享容器访问的验证。

<a id="build-the-app"></a>

### 构建应用

```bash
./scripts/build.sh
```

如果 Assimp framework 不存在，脚本会先构建它，然后运行 XcodeGen，并以 Release 配置构建 `Spacebar3D` scheme。输出位置：

```text
build/Build/Products/Release/Spacebar 3D.app
```

首次构建需要联网获取依赖。[`build-assimp.sh`](../../scripts/build-assimp.sh) 将 Assimp 固定为 `v6.0.6`，并在编译前验证完整的提交 SHA `a79ff6bbce54d3e01186a918dc6374ed55317426`。生成的是静态 arm64 XCFramework，包含 FBX 和 3DS 导入器，不包含导出器或 Draco。

固定版本变化后需重新运行此脚本。`build.sh` 仅检查 framework 是否存在，不检查它是否匹配当前固定版本。使用已检出到所需提交的本地源码时：

```bash
ASSIMP_SRC=/path/to/assimp ./scripts/build-assimp.sh
```

<a id="register-and-exercise-quick-look"></a>

### 注册并验证 Quick Look

1. 将构建好的应用复制到 `/Applications`，并启动该副本一次。
2. 在 **系统设置 → 通用 → 登录项与扩展 → Quick Look** 中启用 **Spacebar 3D**。
3. 在 Finder 中选中支持的文件并按空格键。
4. 再通过应用的 **文件 → 打开…** 打开同一文件，检查两种运行环境。

如果注册信息过期，请刷新缓存并尝试 GLB 文件：

```bash
qlmanage -r
qlmanage -r cache
qlmanage -p /path/to/model.glb
```

macOS 可能会为 OBJ、STL、PLY、USD 和 USDZ 选择 Apple 自带的预览。这不能证明本扩展失效。请使用应用，或按 [README](README.md#help) 中的可选步骤更改预览处理方式。

<a id="development"></a>

## 开发

在 Xcode 中编辑和调试：

```bash
./scripts/build-assimp.sh
xcodegen generate
open Spacebar3D.xcodeproj
```

每次依赖版本变化时构建一次 Assimp；`project.yml` 变化后重新生成项目。Git 忽略 `.xcodeproj`、两个生成的 `Info.plist`、构建输出和 `Vendor/Assimp.xcframework`。应修改 YAML 源文件，而不是生成的项目或属性列表。

在终端中进行增量 Debug 构建：

```bash
xcodebuild -project Spacebar3D.xcodeproj -scheme Spacebar3D \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build build
```

`SKIP_XCODEGEN=1 ./scripts/build.sh` 会复用现有的生成项目，仍然构建 Release。仅在该项目与 YAML 一致时使用。

<a id="capture-media"></a>

### 录制预览视频并截屏

满足上述构建要求后，登录 macOS 桌面并运行脚本。在「系统设置」中，为运行脚本的应用授予屏幕录制权限。

如果模型引用外部纹理、材质或几何体，请先在常规版 Spacebar 3D 中打开模型。使用查看器中的文件夹按钮，授权访问包含这些资源的文件夹。录制版会沿用已保存的权限。仅打开模型文件可能无法访问配套文件。

```bash
brew install ffmpeg
./scripts/capture-media.sh /path/to/model.glb
```

脚本会单独构建并启动启用了录制功能的 Spacebar 3D。要使用已为录制构建的应用，请将 `SPACEBAR3D_APP` 设为其 `.app` 应用包的路径。脚本默认在 `build/media-captures/` 下创建新文件夹。要选择输出文件夹，请将尚未使用的路径作为第二个参数传入。

用于 Mac App Store 公开展示的预览视频 `preview.mp4` 时长为 30 秒，展示该模型可用的所有渲染样式。视频分辨率为 1920 × 1080，帧率为 30 fps。脚本还会保存四张 2560 × 1600 的 PNG 图片和 `demo.gif`。如果模型至少有三种样式，GIF 会使用与样式循环视频相同的 15 秒剪辑。样式不足三种时，GIF 会按原速使用预览视频。第一张截图会在纹理视图可用时使用该视图（`01-textured.png`），否则使用实体视图（`01-solid.png`）。其余图片为 `02-wireframe.png`、`03-normals.png` 和 `04-hologram.png`。

<a id="capture-feature-loop"></a>

### 录制样式循环视频

使用相同的录制设置，可以生成 15 秒、30 fps 的循环视频。模型需要支持至少三种渲染样式，脚本会优先选择赛璐璐着色、体素艺术和全息。

```bash
./scripts/capture-feature-loop.sh /path/to/model.glb
```

脚本默认在 `build/media-captures/` 下创建新文件夹，并保存 `feature-loop.mp4`。要选择输出文件夹，请将尚未使用的路径作为第二个参数传入。

<a id="capture-screenshots"></a>

### 截取 App Store 用图

使用相同的录制设置，可以生成上文列出的四张 2560 × 1600 sRGB PNG 图片。

```bash
./scripts/capture-screenshots.sh /path/to/model.glb
```

脚本默认在 `build/media-captures/` 下创建新文件夹并保存图片。要选择输出文件夹，请将尚未使用的路径作为第二个参数传入。

<a id="capture-app-review"></a>

### 录制供 App Review 私下查看的演示

安装并启动常规版 Spacebar 3D，再启用其 Quick Look 扩展。请选择能在 Finder 的 Quick Look 中以可交互方式打开的模型。录制前，请关闭 Finder 的 Quick Look 预览，以及独立查看器中显示同名文件的窗口。需要上述屏幕录制权限、Swift 命令行工具，以及带 `drawtext` 和 `subtitles` 滤镜的 FFmpeg。保持终端可见，并按终端提示，在 Finder 中保持文件选中，必要时切换到列表视图。收到提示后按空格键，再执行两次旋转或缩放操作。收到提示后，点击使用 Spacebar 3D 打开的按钮。如果 macOS 弹出应用菜单，请选择 Spacebar 3D。如果没有该按钮，请关闭 Quick Look，然后在 Spacebar 3D 中通过 **文件 → 打开…** 打开同一文件。在独立查看器中也执行两次旋转或缩放操作。

```bash
SPACEBAR3D_REVIEW_ANIMATION_MODEL=docs/app-store/Spacebar3D-Review-Model.glb \
  ./scripts/capture-app-review.sh /path/to/model.fbx build/media-captures/app-review
```

脚本会添加说明文字，并将 `app-review.mp4` 保存到 `build/media-captures/` 下的新文件夹。要选择输出文件夹，请将尚未使用的路径作为第二个参数传入。如果应用安装在 `/Applications/Spacebar 3D.app` 以外的位置，请设置 `SPACEBAR3D_REVIEW_APP`。

按提示录制完成后，脚本会录制查看器操作、设置、帮助和隐私章节。示例使用带动画的样例模型添加播放章节。要复用已为录制构建的应用，请设置 `SPACEBAR3D_REVIEW_CAPTURE_APP`。脚本默认使用上述开发环境单独构建录制版应用。

如果已有仅包含 Finder 和查看器引导步骤的录制文件，可用 `capture-review-features.sh` 添加章节。请参阅 `--help`。

<a id="tests"></a>

## 测试

解析包或运行任一测试方式前，先构建 Assimp。

<a id="full-xcode-suite"></a>

### 完整 Xcode 测试套件

这是主要的回归测试命令，涵盖应用、共享代码和扩展的源码测试，以及 `project.yml` 中声明的全部九个包测试 target。

```bash
xcodegen generate
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build
python3 scripts/check-localizations.py
```

要只运行指定测试，可添加 `-only-testing` 选择器，例如：

```bash
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build \
  -only-testing:ViewerUITests/NativeViewerInputTests
```

Xcode 将 `.xcresult` 结果包写入 `build/Logs/Test/`。

<a id="package-only-tests"></a>

### 仅运行包测试

此方式不包含 `Spacebar3DTests` 中的宿主源码测试：

```bash
xcrun swift test --package-path Packages/Spacebar3DKit
```

两个大模型测试需通过 `P3D_LARGE=1` 显式启用。其中一个会创建约 100 MB 的 STL 测试文件。运行该基准测试：

```bash
P3D_LARGE=1 xcrun swift test --package-path Packages/Spacebar3DKit \
  --filter LargeModelTests
```

<a id="what-the-tests-establish"></a>

### 测试能验证什么

- 设置测试使用显式指定的临时存储。设置规则变化时，在 [`settings-vectors.json`](../../testdata/settings-vectors.json) 中添加规范化用例。
- 导入器测试生成小型测试文件，检查格式错误及被截断的输入。
- 渲染器测试进行离屏绘制并检查像素，需要可用的 Metal 设备。
- 查看器测试覆盖原生输入、辅助功能元数据、命令、布局和 SwiftUI 控件，包括 ViewInspector 检查。
- 本地化检查验证源键覆盖率、目录条目和占位符；包测试还会验证编译后的语言资源。

Xcode scheme 将宿主源码编译到测试 bundle 中，不会在生产沙盒内启动已签名应用。测试通过不能验证 Quick Look 注册、文件夹权限、VoiceOver 语音或经过公证的下载文件的行为。涉及这些改动时，还需测试已安装的签名应用和 Finder 扩展。

<a id="how-it-works"></a>

## 工作原理

```text
Finder → Quick Look extension ─┐
                              ├─ ViewerFactory → NativeViewer
App → model window ───────────┘                      │
                                     ImportRouter → ModelScene
                                                     │
                                           RenderMetal / MTKView
                                           + SwiftUI controls
```

两个宿主共享本地 `Spacebar3DKit` 包。导入工作在主线程之外执行，原生查看器协调渲染和控件。

| 位置 | 职责 |
| :--- | :--- |
| `Spacebar3D/App/` | 初始配置、设置、模型窗口、默认应用注册、菜单、帮助和致谢。 |
| `Spacebar3D/Extension/` | Quick Look 预览生命周期。 |
| `Spacebar3D/Shared/` | 查看器创建和共享设置。 |
| `Packages/Spacebar3DKit/Sources/ModelCore/` | 场景数据、格式检测、动画、拓扑和本地化。 |
| `…/Sources/ImportRouter/` 和 `…/Sources/Import*/` | 格式分派与读取器。 |
| `…/Sources/RenderMetal/` | GPU 场景、相机、着色与渲染。 |
| `…/Sources/ViewerUI/` | 查看器 API、原生输入、SwiftUI 控件和文件夹授权。 |
| `…/Sources/CZstd/` | 随项目提供的 Zstandard 解码器，用于压缩的 Blender 文件。 |
| `Spacebar3DTests/` 和 `Packages/Spacebar3DKit/Tests/` | 宿主源码与包测试。 |
| `docs/<language-code>/README.md` | 九种非英语 README。 |
| `docs/<language-code>/DEVELOPMENT.md` | 九种非英语开发指南。 |

原生 Swift 读取器处理 STL、PLY、OBJ、3MF、glTF/GLB、VRM/VRMA 和 Blender。Model I/O 处理 USD，Assimp 处理 FBX 和 3DS。`FormatDetector` 检查文件开头的字节，对于含义不明确的文本格式还会参考扩展名。支持的文档类型及 `QLSupportedContentTypes` 在 `project.yml` 中声明。

仅包含动画、且骨架受支持的文件可以显示简笔骨架预览。项目不附带默认角色。格式支持范围有意小于完整的 DCC 应用；修改读取器时需同步维护 README 中的限制说明。

<a id="implementation-notes"></a>

## 实现说明

<a id="sandbox-and-related-files"></a>

### 沙盒与关联文件

两个 target 均使用 App Sandbox，并只读访问用户选择的文件。两者都没有网络权限或临时沙盒例外。

打开模型不会授予对相邻文件的无限访问权。两个宿主都可通过 **显示模型…**、**显示材质…** 或 **显示纹理…** 请求访问相应文件夹。应用还通过关联文件机制支持特定的同名材质配套文件，例如 `ship.obj` 旁的 `ship.mtl`。

[`FolderGrants.swift`](../../Packages/Spacebar3DKit/Sources/ViewerUI/FolderGrants.swift) 将应用的授权保存为带安全作用域的书签。Quick Look 保存自己的普通书签，并读取应用在共享容器中刷新的副本。仅向 Quick Look 授予的权限需在 Mac 重启后重新授权；启动应用会为扩展刷新应用已记住的授权。读取权限仅限于获准的文件夹及其子目录。

<a id="settings"></a>

### 设置

`ViewerSettings` 将 `viewer-settings.json` 存储在 App Group 容器内，由应用写入，新建查看器读取其中规范化后的值。设置无效、过大或缺失时使用默认值。不会从旧的容器外位置 `~/Library/Application Support/Spacebar3D/` 迁移设置。

<a id="input-and-accessibility"></a>

### 输入与辅助功能

只有独立应用的模型画布处理键盘输入时，方向键才用于环绕，Shift 加方向键才用于平移。单按空格键在画布中播放或暂停；它不是全局菜单快捷键，不得抢占已聚焦按钮或滑块的激活操作。Quick Look 保留按空格键关闭的行为。菜单和辅助功能操作提供指针手势之外的操作方式。

修改控件后，检查键盘焦点、窄窗口、较长的翻译、“增强对比度”和“降低透明度”。除辅助功能树断言外，还应单独听取 VoiceOver 的实际播报。

<a id="localization-and-documentation"></a>

### 本地化与文档

共享字符串目录为 `Packages/Spacebar3DKit/Sources/ModelCore/Resources/Localizable.xcstrings`，为应用和扩展提供十种语言。完整字符串、占位符、编译资源和布局检查的要求见 [LOCALIZATION.md](../LOCALIZATION.md)。

英文 README 位于根目录，翻译位于 `docs/<language-code>/`。开发指南也在这些语言目录中，英文源文档为 `docs/DEVELOPMENT.md`。各版本的格式限制、控件、安装、权限行为和开发流程应保持一致。

<a id="troubleshooting"></a>

## 故障排查

| 现象 | 检查方法 |
| :--- | :--- |
| 包解析提示缺少 Assimp | 确保完整版 Xcode、CMake 和 Ninja 可用，再运行 `./scripts/build-assimp.sh`。 |
| 签名失败或共享设置不可用 | 检查证书、团队、bundle 标识符及相互匹配的 App Group 标识符。仅设置环境变量不会改写 entitlements。 |
| 生成后修改消失 | 修改 `project.yml`，不要修改生成的 `.xcodeproj` 或 `Info.plist`。 |
| 扩展缺失或加载旧版本 | 启动正确的已安装副本，启用扩展，检查注册并刷新 Quick Look。不要混淆安装副本与构建目录中的副本。 |
| 打开了 Apple 查看器 | 参阅上述内置格式说明，并与应用中的“文件 → 打开”比较。 |
| 缺少纹理或几何体 | 阅读提示，授权模型文件夹，检查格式限制和配套文件。 |
| GPU 测试失败 | 确认可用的 Metal 设备并分析失败原因。GPU 不可用不等于渲染验证通过。 |

检查扩展注册并实时查看日志：

```bash
pluginkit -m | rg -i spacebar3d
log stream --predicate 'process == "Spacebar3DExtension"'
```

第一条命令使用 ripgrep 的 `rg`，也可改用 `grep -i spacebar3d`。在另一个终端运行 `qlmanage -p /path/to/model.glb`。被拒绝的模型应在预览中显示错误。修改签名或权限前，先确定问题属于导入、渲染、访问还是扩展选择。

<a id="distribution-signing--notarization"></a>

## 分发、签名与公证

项目脚本实现的是 **通过 Developer ID 直接分发 DMG**，不会为 Mac App Store 执行归档、导出或上传。商店分发需要独立的签名、归档、导出及 App Store Connect 提交流程。

直接分发需使用 Developer ID Application 身份并进行公证。Apple 的[公证指南](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)说明了签名和服务要求；此处不重复会员价格信息。

<a id="manual"></a>

### 手动流程

配置好相互匹配的团队和 App Group 标识符后：

```bash
SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ./scripts/build.sh
```

提供 `SIGN_IDENTITY` 时，构建脚本选择手动签名、传递 `DEVELOPMENT_TEAM`、添加安全时间戳，并禁用基础调试 entitlements 的注入。`project.yml` 已启用 Hardened Runtime。未提供 `SIGN_IDENTITY` 时，脚本使用项目的开发签名配置。

本地公证优先使用钥匙串配置。通过 `notarytool` 交互式保存凭据，然后按配置名称运行脚本：

```bash
xcrun notarytool store-credentials "spacebar3d-notary"
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" ./scripts/notarize.sh
```

脚本接受可选的应用路径：

```bash
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" \
  ./scripts/notarize.sh "/path/to/Spacebar 3D.app"
```

认证方式按以下顺序选择：

| 方式 | 变量 |
| :--- | :--- |
| 钥匙串配置 | `NOTARY_KEYCHAIN_PROFILE` |
| App Store Connect API 密钥 | `NOTARY_KEY_PATH`、`NOTARY_KEY_ID`、`NOTARY_KEY_ISSUER` |
| Apple 账户凭据 | `APPLE_TEAM_ID`、`NOTARY_APPLE_ID`、`NOTARY_PASSWORD` |

最后一种方式将 App 专用密码作为 `notarytool` 参数传递；在共享开发机器上，钥匙串配置可避免这种做法。不要将签名密钥或凭据放入仓库。

`notarize.sh` 验证应用的 Developer ID 签名，并创建带有 Applications 快捷方式的 DMG。脚本使用从应用签名读取的身份来签名 DMG，也可以用 `SIGN_IDENTITY` 指定身份。证书和私钥必须在钥匙串中可用。脚本将 DMG 提交给 Apple，获批后附加并验证公证票据，再通过 `spctl` 检查 Gatekeeper 是否接受。所有检查通过后，脚本会在仓库根目录写入 `Spacebar3D.dmg`。共享前请测试下载后的文件。

<a id="automated-github-actions"></a>

### GitHub Actions 自动流程

[发布工作流](../../.github/workflows/release.yml)在 Apple 芯片的 `macos-26` runner 上使用 Xcode 26。推送或选择格式为 `vMAJOR.MINOR.PATCH` 的标签。标签须与 `MARKETING_VERSION` 一致，并指向 `origin/main` 上的提交。

工作流在导入签名证书前生成项目，并运行 `Spacebar3DTests` 和本地化检查。它使用 Developer ID 构建，核对应用和扩展的版本是否与标签一致，然后签名并公证 DMG。临时钥匙串会在 DMG 附加到 GitHub Release 之前删除。

在 **实际的目标仓库** 中配置以下 secrets：

| Secret | 内容 |
| :--- | :--- |
| `MACOS_CERTIFICATE` | 导出为 `.p12` 后进行 Base64 编码的 Developer ID Application 证书及私钥。 |
| `MACOS_CERTIFICATE_PWD` | 该 `.p12` 的密码。 |
| `KEYCHAIN_PASSWORD` | 临时构建钥匙串的密码。 |
| `APPLE_TEAM_ID` | 签名团队 ID。 |
| `NOTARY_APPLE_ID` | 用于公证的 Apple 账户。 |
| `NOTARY_PASSWORD` | 该账户的 App 专用密码。 |

配置 secrets 时显式指定仓库，例如 `gh secret set APPLE_TEAM_ID --repo OWNER/REPOSITORY`，该命令会提示输入值。不要假设本地 `origin` 指向的仓库存在，或就是预期的发布仓库。

创建发布标签之前，请在 `project.yml` 中设置 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，更新变更记录、运行测试并验证签名构建。推送匹配的标签后，工作流成功时可能会发布 GitHub Release。

<a id="references"></a>

## 参考资料

- [原生渲染器架构](../architecture/native-rewrite.md)
- [查看器设计](../design/neon-garden-viewer.md)
- [本地化](../LOCALIZATION.md)
- [第三方许可证](../../THIRD_PARTY_LICENSES.md)
- [Apple：自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [magicien/VRMQuickLook](https://github.com/magicien/VRMQuickLook)，基于 SceneKit 的 VRM 0.x 实现
- [magicien/GLTFQuickLook](https://github.com/magicien/GLTFQuickLook)，Quick Look 结构参考
- [pixiv/three-vrm](https://github.com/pixiv/three-vrm)，VRM 行为参考
