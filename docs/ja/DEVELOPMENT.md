# Spacebar 3D の開発

[English](../DEVELOPMENT.md) | [简体中文](../zh-Hans/DEVELOPMENT.md) | [Español](../es/DEVELOPMENT.md) | [Français](../fr/DEVELOPMENT.md) | [Deutsch](../de/DEVELOPMENT.md) | **日本語** | [Português (Brasil)](../pt-BR/DEVELOPMENT.md) | [한국어](../ko/DEVELOPMENT.md) | [Italiano](../it/DEVELOPMENT.md) | [Русский](../ru/DEVELOPMENT.md)

ネイティブ macOS アプリと Quick Look 拡張機能のビルド、テスト、デバッグについて説明します。機能と対応形式の制限は [README](README.md) を参照してください。

[要件](#requirements) · [ビルド](#build-local) · [テスト](#tests) · [構成](#how-it-works) · [問題の解決](#troubleshooting) · [配布](#distribution-signing--notarization)

特記がない限り、シェルコマンドはリポジトリのルートから実行します。

<a id="requirements"></a>

## 要件

| 要件 | 補足 |
| :--- | :--- |
| macOS 26 以降を実行する Apple シリコン搭載 Mac | プロジェクトと Assimp の対象は `arm64` です。Intel 用のバイナリは生成しません。 |
| macOS 26 以降の SDK を含むフル版 Xcode | Command Line Tools だけでは不足します。現在のローカル開発環境は Xcode 27.0 を使用しています。 |
| XcodeGen | `project.yml` から Xcode プロジェクトを生成します。 |
| CMake と Ninja | ネイティブ依存ライブラリの Assimp をビルドします。 |
| Python 3 | 翻訳の整合性チェックに使用します。 |
| 開発用の署名 ID | インストールしたアプリ、拡張機能、共有 App Group に必要です。以下を参照してください。 |

```bash
brew install xcodegen cmake ninja
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

シェルが Command Line Tools や別の Xcode を選択している場合は、ビルド前にそのシェルでフル版 Xcode を指定してください。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`xcode-select` が Command Line Tools を指している場合、`build.sh` も上記の標準インストール先を検出します。`xcodebuild` の直接実行や依存ライブラリのビルドコマンドでは、あらかじめ正しい開発用ディレクトリを指定する必要があります。

<a id="build-local"></a>

## ローカルビルド

<a id="configure-signing"></a>

### 署名の設定

リポジトリの設定では [`project.yml`](../../project.yml) の開発チームを使用します。自分のチームでビルドする場合は次の手順を実行します。

1. `project.yml` に `DEVELOPMENT_TEAM` と適切なバンドル識別子を設定します。
2. チーム用の App Group を設定します。[`Spacebar3D.entitlements`](../../Spacebar3D/App/Spacebar3D.entitlements)、[`Spacebar3DExtension.entitlements`](../../Spacebar3D/Extension/Spacebar3DExtension.entitlements)、および [`ViewerSettings.swift`](../../Spacebar3D/Shared/ViewerSettings.swift) の `ViewerSettings.appGroup` に同じグループ識別子を使用します。
3. Xcode がチームの Apple Development 証明書と必要なプロビジョニング用ファイルを使用できることを確認します。設定変更後はプロジェクトを再生成してください。

現在の App Group は `V3AQWQ8JMY.com.vitalis.Spacebar3D` です。ビルドコマンドのチームだけを変更しても、この識別子は更新されません。未署名やアドホック署名のビルドでは、拡張機能の登録や共有コンテナへのアクセスの検証を代替できません。

<a id="build-the-app"></a>

### アプリのビルド

```bash
./scripts/build.sh
```

スクリプトは Assimp の framework がなければビルドし、XcodeGen を実行してから `Spacebar3D` スキームを Release 構成でビルドします。出力先は次のとおりです。

```text
build/Build/Products/Release/Spacebar 3D.app
```

初回ビルドでは依存関係の取得にネットワーク接続が必要です。[`build-assimp.sh`](../../scripts/build-assimp.sh) は Assimp を `v6.0.6` に固定し、コンパイル前にコミットの完全な SHA `a79ff6bbce54d3e01186a918dc6374ed55317426` を確認します。FBX と 3DS のインポーターを含む静的 arm64 XCFramework としてビルドし、エクスポーターと Draco は含めません。

固定リビジョンが変わったら、このスクリプトを再実行してください。`build.sh` は framework の存在のみを確認し、リビジョンの一致は確認しません。必要なコミットにチェックアウト済みのソースを使用する場合は次のように指定します。

```bash
ASSIMP_SRC=/path/to/assimp ./scripts/build-assimp.sh
```

<a id="register-and-exercise-quick-look"></a>

### Quick Look の登録と動作確認

1. ビルドしたアプリを `/Applications` にコピーし、そのコピーを一度起動します。
2. **システム設定 → 一般 → ログイン項目と機能拡張 → Quick Look** で **Spacebar 3D** を有効にします。
3. Finder で対応ファイルを選択し、スペースキーを押します。
4. アプリの **ファイル → 開く…** からも同じファイルを開き、両方の実行環境を確認します。

登録が古い場合はキャッシュを更新して GLB ファイルで試してください。

```bash
qlmanage -r
qlmanage -r cache
qlmanage -p /path/to/model.glb
```

OBJ、STL、PLY、USD、USDZ では、macOS が Apple 標準のプレビューを選ぶことがあります。それだけで本拡張機能の不具合とは判断できません。アプリを使うか、[README](README.md#help) に記載した任意の切り替え手順を利用してください。

<a id="development"></a>

## 開発

Xcode で編集やデバッグを行う場合：

```bash
./scripts/build-assimp.sh
xcodegen generate
open Spacebar3D.xcodeproj
```

Assimp は依存リビジョンごとに一度ビルドし、`project.yml` が変わったらプロジェクトを再生成します。`.xcodeproj`、生成される二つの `Info.plist`、ビルド出力、`Vendor/Assimp.xcframework` は Git の管理対象外です。生成されたプロジェクトやプロパティリストではなく、元の YAML を編集してください。

ターミナルから Debug の差分ビルドを行う場合：

```bash
xcodebuild -project Spacebar3D.xcodeproj -scheme Spacebar3D \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build build
```

`SKIP_XCODEGEN=1 ./scripts/build.sh` は既存の生成済みプロジェクトを再利用し、Release をビルドします。プロジェクトと YAML が一致している場合にのみ使用してください。

<a id="capture-media"></a>

### プレビュー動画とスクリーンショットを撮影する

上記のビルド要件を満たしたうえで、macOS のデスクトップにログインしてスクリプトを実行します。システム設定で、スクリプトを実行するアプリに画面収録を許可してください。

モデルが外部のテクスチャ、マテリアル、ジオメトリを参照している場合は、まず通常の Spacebar 3D アプリで開いてください。ビューアーのフォルダボタンで、参照先ファイルが入っているフォルダへのアクセスを許可します。撮影用のアプリは保存された許可を使います。モデルファイルだけを開くと、関連ファイルにアクセスできないことがあります。

```bash
brew install ffmpeg
./scripts/capture-media.sh /path/to/model.glb
```

スクリプトは撮影機能を有効にした Spacebar 3D を別途ビルドして起動します。撮影用にビルド済みのアプリを使う場合は、`SPACEBAR3D_APP` にその `.app` バンドルのパスを指定してください。既定では `build/media-captures/` の下に新しいフォルダを作成します。出力先を指定するには、まだ使われていないパスを第 2 引数に渡します。

Mac App Store で公開するプレビュー動画 `preview.mp4` は 30 秒で、モデルで利用できるすべての描画スタイルを表示します。解像度は 1920 × 1080、フレームレートは 30 fps です。このほかに 2560 × 1600 の PNG 画像 4 枚と `demo.gif` を出力します。モデルで 3 種類以上の描画スタイルが利用できる場合、GIF はループ動画と同じ 15 秒の編集を使います。それより少ない場合は、プレビュー動画を元の速度で使います。最初の画像は、テクスチャ表示が利用できる場合は `01-textured.png`、それ以外はソリッド表示の `01-solid.png` です。残りの画像は `02-wireframe.png`、`03-normals.png`、`04-hologram.png` です。

<a id="capture-feature-loop"></a>

### 描画スタイルを紹介するループ動画を撮影する

同じ撮影設定で、15 秒、30 fps のループ動画を作成できます。モデルで 3 種類以上の描画スタイルが利用できる必要があります。セルシェーディング、ボクセルアート、ホログラムを優先します。

```bash
./scripts/capture-feature-loop.sh /path/to/model.glb
```

既定では、`build/media-captures/` の下に新しいフォルダを作成し、`feature-loop.mp4` を保存します。出力先を指定するには、まだ使われていないパスを第 2 引数に渡します。

<a id="capture-screenshots"></a>

### App Store 用のスクリーンショットを撮影する

同じ撮影設定で、上記の 2560 × 1600 の sRGB PNG 画像 4 枚を作成できます。

```bash
./scripts/capture-screenshots.sh /path/to/model.glb
```

既定では、`build/media-captures/` の下に新しいフォルダを作成して保存します。出力先を指定するには、まだ使われていないパスを第 2 引数に渡します。

<a id="capture-app-review"></a>

### App Review 用の非公開デモを収録する

通常の Spacebar 3D アプリをインストールして起動し、Quick Look 拡張機能を有効にします。Finder の Quick Look で操作可能なプレビューが開くモデルを選びます。収録前に、Finder の Quick Look プレビューと、単体アプリで同じファイル名のウインドウを閉じます。上記の画面収録の許可に加え、Swift のコマンドラインツールと `drawtext` と `subtitles` フィルタ付きの FFmpeg が必要です。ターミナルを表示したまま、その案内に従います。Finder でファイルを選択したままにし、必要に応じてリスト表示に切り替えます。指示が出たらスペースキーを押し、回転やズームの操作を 2 回行います。指示が出たら、Spacebar 3D で開くボタンをクリックします。macOS がアプリのメニューを表示した場合は、Spacebar 3D を選びます。ボタンが表示されない場合は、Quick Look を閉じ、Spacebar 3D の **ファイル → 開く…** から同じファイルを開きます。単体アプリのビューアーでも回転やズームの操作を 2 回行います。

```bash
SPACEBAR3D_REVIEW_ANIMATION_MODEL=docs/app-store/Spacebar3D-Review-Model.glb \
  ./scripts/capture-app-review.sh /path/to/model.fbx build/media-captures/app-review
```

スクリプトは説明文を追加し、`build/media-captures/` の下の新しいフォルダに `app-review.mp4` を保存します。出力先を指定するには、未使用のパスを第 2 引数に渡します。アプリを `/Applications/Spacebar 3D.app` 以外の場所にインストールした場合は、`SPACEBAR3D_REVIEW_APP` を設定してください。

案内に沿った収録の後、スクリプトはビューアーの操作、設定、ヘルプ、プライバシーの章を収録します。この例では、アニメーション入りのサンプルモデルを使って再生操作を追加します。既存の撮影用アプリを使う場合は、`SPACEBAR3D_REVIEW_CAPTURE_APP` を設定してください。既定では、上記の開発環境で撮影用アプリをビルドします。

Finder とビューアーでの手順だけを収録済みの場合は、`capture-review-features.sh` で章を追加できます。`--help` を参照してください。

<a id="tests"></a>

## テスト

パッケージの解決や、いずれかのテスト実行を行う前に Assimp をビルドしてください。

<a id="full-xcode-suite"></a>

### Xcode の全テスト

主な回帰テスト用コマンドです。アプリ、共有コード、拡張機能のソーステストと、`project.yml` に定義された九つすべてのパッケージテストターゲットを含みます。

```bash
xcodegen generate
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build
python3 scripts/check-localizations.py
```

対象を絞る場合は `-only-testing` セレクターを追加します。例：

```bash
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build \
  -only-testing:ViewerUITests/NativeViewerInputTests
```

Xcode は `.xcresult` バンドルを `build/Logs/Test/` に保存します。

<a id="package-only-tests"></a>

### パッケージのみのテスト

`Spacebar3DTests` のホストソーステストは含まれません。

```bash
xcrun swift test --package-path Packages/Spacebar3DKit
```

大規模モデル用の二つのテストは `P3D_LARGE=1` で明示的に有効にします。一つは約 100 MB の STL テストファイルを生成します。このベンチマークを実行するには：

```bash
P3D_LARGE=1 xcrun swift test --package-path Packages/Spacebar3DKit \
  --filter LargeModelTests
```

<a id="what-the-tests-establish"></a>

### テストで確認できること

- 設定テストでは明示的な一時ストレージを使用します。設定ルールを変えたら [`settings-vectors.json`](../../testdata/settings-vectors.json) に正規化のケースを追加してください。
- インポーターテストでは小さなテストファイルを生成し、不正な入力や途中で切れた入力を確認します。
- レンダラーテストはオフスクリーンで描画し、ピクセルを検証します。動作する Metal デバイスが必要です。
- ビューアーテストはネイティブ入力、アクセシビリティメタデータ、コマンド、レイアウト、SwiftUI コントロールを検証し、ViewInspector によるチェックも含みます。
- ローカライズのチェックはソースキーの網羅性、カタログ項目、プレースホルダーを検証します。パッケージテストではコンパイル済み言語リソースも確認します。

Xcode スキームはホストのソースをテストバンドルにコンパイルします。本番用サンドボックス内で署名済みアプリを起動するわけではありません。テスト成功だけでは、Quick Look の登録、フォルダ権限、VoiceOver の読み上げ、公証済みダウンロードの動作は確認できません。これらの変更では、インストール済みの署名済みアプリと Finder 拡張機能もテストしてください。

<a id="how-it-works"></a>

## 仕組み

```text
Finder → Quick Look extension ─┐
                              ├─ ViewerFactory → NativeViewer
App → model window ───────────┘                      │
                                     ImportRouter → ModelScene
                                                     │
                                           RenderMetal / MTKView
                                           + SwiftUI controls
```

二つのホストはローカルの `Spacebar3DKit` パッケージを共有します。インポートはメインスレッド外で実行し、ネイティブビューアーが描画とコントロールを調整します。

| 場所 | 役割 |
| :--- | :--- |
| `Spacebar3D/App/` | 初期設定、設定、モデルウインドウ、デフォルトアプリ登録、メニュー、ヘルプ、クレジット。 |
| `Spacebar3D/Extension/` | Quick Look プレビューのライフサイクル。 |
| `Spacebar3D/Shared/` | ビューアーの生成と共有設定。 |
| `Packages/Spacebar3DKit/Sources/ModelCore/` | シーンデータ、形式検出、アニメーション、トポロジー、ローカライズ。 |
| `…/Sources/ImportRouter/` と `…/Sources/Import*/` | 形式の振り分けとリーダー。 |
| `…/Sources/RenderMetal/` | GPU シーン、カメラ、シェーディング、描画。 |
| `…/Sources/ViewerUI/` | ビューアー API、ネイティブ入力、SwiftUI コントロール、フォルダアクセス許可。 |
| `…/Sources/CZstd/` | 圧縮 Blender ファイル用に同梱した Zstandard デコーダー。 |
| `Spacebar3DTests/` と `Packages/Spacebar3DKit/Tests/` | ホストソースとパッケージのテスト。 |
| `docs/<language-code>/README.md` | 英語以外の九つの README。 |
| `docs/<language-code>/DEVELOPMENT.md` | 英語以外の九つの開発ガイド。 |

ネイティブ Swift リーダーが STL、PLY、OBJ、3MF、glTF/GLB、VRM/VRMA、Blender を処理します。USD は Model I/O、FBX と 3DS は Assimp が担当します。`FormatDetector` は先頭バイトを確認し、判別が曖昧なテキスト形式では拡張子も使います。対応する書類タイプと `QLSupportedContentTypes` は `project.yml` で定義します。

対応スケルトンを持つアニメーションのみのファイルでは、棒人間によるプレビューを利用できます。デフォルトアバターは同梱しません。対応範囲は意図的に本格的な DCC アプリより限定しています。リーダー変更時には README の制限も更新してください。

<a id="implementation-notes"></a>

## 実装上の注意

<a id="sandbox-and-related-files"></a>

### サンドボックスと関連ファイル

両ターゲットは App Sandbox を使用し、ユーザーが選択したファイルへの読み取り専用アクセスを持ちます。ネットワーク entitlement や一時的なサンドボックス例外はありません。

モデルを開いても、隣接ファイルへの無制限なアクセスは許可されません。両ホストは **モデルを表示…**、**マテリアルを表示…**、**テクスチャを表示…** からフォルダへのアクセスを要求できます。アプリは関連ファイル処理により、`ship.obj` に隣接する `ship.mtl` など、指定された同名のマテリアル補助ファイルにも対応します。

[`FolderGrants.swift`](../../Packages/Spacebar3DKit/Sources/ViewerUI/FolderGrants.swift) はアプリの許可を security-scoped bookmark として保存します。Quick Look は自身の通常の bookmark を保持し、共有コンテナ内でアプリが更新したコピーも読み込みます。Quick Look だけに与えた許可は Mac 再起動後に再取得が必要です。アプリを起動すると、記憶した許可を拡張機能向けに更新します。読み取り範囲は許可したフォルダとその配下に限定されます。

<a id="settings"></a>

### 設定

`ViewerSettings` は `viewer-settings.json` を App Group コンテナに保存します。アプリが書き込み、新しいビューアーは正規化済みの値を読み込みます。設定が不正、過大、または欠落している場合はデフォルト値に戻ります。旧コンテナ外の場所 `~/Library/Application Support/Spacebar3D/` からの移行は行いません。

<a id="input-and-accessibility"></a>

### 入力とアクセシビリティ

単独アプリのモデルキャンバスがキーボード入力を処理している場合だけ、矢印キーで周回、Shift と矢印キーで平行移動します。スペースキー単独で再生・一時停止します。これはグローバルなメニューショートカットではなく、フォーカス中のボタンやスライダーの操作を奪ってはいけません。Quick Look はスペースキーで閉じる動作を維持します。メニューとアクセシビリティアクションはポインタージェスチャーの代替になります。

コントロール変更時はキーボードフォーカス、狭いウインドウ、長い翻訳、「コントラストを上げる」「透明度を下げる」を確認してください。アクセシビリティツリーのアサーションとは別に、実際の VoiceOver 読み上げも確認します。

<a id="localization-and-documentation"></a>

### ローカライズとドキュメント

共有文字列カタログ `Packages/Spacebar3DKit/Sources/ModelCore/Resources/Localizable.xcstrings` は、アプリと拡張機能に十言語を提供します。完全な文、プレースホルダー、コンパイル済みリソース、レイアウトの確認については [LOCALIZATION.md](../LOCALIZATION.md) に従ってください。

英語 README はルート、翻訳は `docs/<language-code>/` にあります。開発ガイドも同じ言語別フォルダに置き、英語の原文は `docs/DEVELOPMENT.md` です。形式の制限、操作、インストール、権限の挙動、開発手順を全言語で揃えてください。

<a id="troubleshooting"></a>

## 問題の解決

| 症状 | 確認内容 |
| :--- | :--- |
| パッケージ解決時に Assimp が見つからない | フル版 Xcode、CMake、Ninja が利用可能な状態で `./scripts/build-assimp.sh` を実行します。 |
| 署名に失敗する、共有設定を使えない | 証明書、チーム、バンドル ID、一致する App Group ID を確認します。環境変数だけでは entitlements は書き換わりません。 |
| 生成後に編集内容が消える | 生成された `.xcodeproj` や `Info.plist` ではなく `project.yml` を変更します。 |
| 拡張機能がない、古い版が読み込まれる | 正しいインストール済みアプリを起動し、拡張機能を有効にして登録を確認し、Quick Look を更新します。ビルド先のコピーと混同しないでください。 |
| Apple のビューアーが開く | 上記の形式に関する注意を確認し、アプリの「ファイル → 開く」と比較します。 |
| テクスチャや形状が欠ける | 通知を読み、モデルフォルダを許可し、形式の制限と補助ファイルを確認します。 |
| GPU テストが失敗する | Metal デバイスが利用可能か確認し、失敗を調査します。GPU が利用できない状態を描画検証の成功と見なさないでください。 |

拡張機能の登録を調べ、ログをストリーミング表示します。

```bash
pluginkit -m | rg -i spacebar3d
log stream --predicate 'process == "Spacebar3DExtension"'
```

最初のコマンドは ripgrep の `rg` を使います。`grep -i spacebar3d` でも代用できます。別のターミナルで `qlmanage -p /path/to/model.glb` を実行します。拒否されたモデルはプレビューにエラーを表示するはずです。署名や権限を変更する前に、インポート、描画、アクセス、拡張機能の選択のどこに問題があるか確認してください。

<a id="distribution-signing--notarization"></a>

## 配布、署名、公証

付属スクリプトは **Developer ID を使う DMG の直接配布** に対応します。Mac App Store 向けのアーカイブ、エクスポート、アップロードは行いません。ストア配布には別途、署名、アーカイブ、エクスポート、App Store Connect への提出手順が必要です。

直接配布では Developer ID Application の署名 ID と公証を使用します。Apple の[公証ガイド](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)に署名とサービスの要件があります。会員料金はここには転載しません。

<a id="manual"></a>

### 手動実行

チームと App Group の識別子を一致させた後に実行します。

```bash
SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ./scripts/build.sh
```

`SIGN_IDENTITY` を指定すると、ビルドスクリプトは手動署名を選択し、`DEVELOPMENT_TEAM` を渡し、安全なタイムスタンプを追加して、基本デバッグ entitlements の注入を無効にします。Hardened Runtime は `project.yml` で有効です。`SIGN_IDENTITY` がなければ、プロジェクトの開発署名設定を使用します。

ローカルでの公証にはキーチェーンプロファイルを推奨します。`notarytool` で対話的に認証情報を保存し、プロファイル名を指定して実行してください。

```bash
xcrun notarytool store-credentials "spacebar3d-notary"
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" ./scripts/notarize.sh
```

アプリのパスは省略可能な引数として指定できます。

```bash
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" \
  ./scripts/notarize.sh "/path/to/Spacebar 3D.app"
```

認証方式は次の優先順で選択されます。

| 方式 | 変数 |
| :--- | :--- |
| キーチェーンプロファイル | `NOTARY_KEYCHAIN_PROFILE` |
| App Store Connect API キー | `NOTARY_KEY_PATH`、`NOTARY_KEY_ID`、`NOTARY_KEY_ISSUER` |
| Apple Account の認証情報 | `APPLE_TEAM_ID`、`NOTARY_APPLE_ID`、`NOTARY_PASSWORD` |

最後の方式はアプリ用パスワードを `notarytool` の引数で渡します。共有開発マシンではキーチェーンプロファイルを使うことでこれを避けられます。署名キーや認証情報をリポジトリに入れないでください。

`notarize.sh` はアプリの Developer ID 署名を検証し、Applications へのショートカットを含む DMG を作成します。DMG の署名にはアプリの署名から読み取った ID を使います。`SIGN_IDENTITY` を指定した場合はその値を使います。証明書と秘密鍵はキーチェーンから利用できる状態にしてください。スクリプトは DMG を Apple に提出し、受理されたら公証チケットを添付して検証します。その後、`spctl` で Gatekeeper の判定を確認します。すべての確認が通るとリポジトリのルートに `Spacebar3D.dmg` を書き出します。共有前にダウンロードしたファイルで動作を確認してください。

<a id="automated-github-actions"></a>

### GitHub Actions による自動実行

[リリースワークフロー](../../.github/workflows/release.yml) は Apple シリコンの `macos-26` ランナーで Xcode 26 を使います。`MARKETING_VERSION` と一致し、`origin/main` 上のコミットを指す `vMAJOR.MINOR.PATCH` 形式のタグをプッシュするか、手動実行で選択します。

ワークフローはプロジェクトを生成し、`Spacebar3DTests` とローカライズのチェックを実行してから署名証明書を取り込みます。Developer ID でビルドし、アプリと拡張のバージョンをタグと照合した後、DMG に署名して公証を受けます。DMG を GitHub Release に添付する前に一時キーチェーンを削除します。

以下の secrets は **実際の公開先リポジトリ** に設定してください。

| Secret | 内容 |
| :--- | :--- |
| `MACOS_CERTIFICATE` | `.p12` として書き出し、Base64 化した Developer ID Application 証明書と秘密鍵。 |
| `MACOS_CERTIFICATE_PWD` | その `.p12` のパスワード。 |
| `KEYCHAIN_PASSWORD` | 一時ビルドキーチェーンのパスワード。 |
| `APPLE_TEAM_ID` | 署名チーム ID。 |
| `NOTARY_APPLE_ID` | 公証に使う Apple Account。 |
| `NOTARY_PASSWORD` | そのアプリ用パスワード。 |

設定時は `gh secret set APPLE_TEAM_ID --repo OWNER/REPOSITORY` のようにリポジトリを明示します。このコマンドは値の入力を求めます。ローカルの `origin` が実在する、または意図した公開先を指すと仮定しないでください。

リリースタグを作成する前に、`project.yml` の `MARKETING_VERSION` と `CURRENT_PROJECT_VERSION` を設定し、変更履歴を更新し、テストを実行して署名済みのビルドを確認してください。対応するタグをプッシュすると、ワークフローが成功した場合に GitHub Release が公開されることがあります。

<a id="references"></a>

## 参考資料

- [ネイティブレンダラーの構成](../architecture/native-rewrite.md)
- [ビューアーの設計](../design/neon-garden-viewer.md)
- [ローカライズ](../LOCALIZATION.md)
- [第三者ライセンス](../../THIRD_PARTY_LICENSES.md)
- [Apple：公証ワークフローのカスタマイズ](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [magicien/VRMQuickLook](https://github.com/magicien/VRMQuickLook)：SceneKit による VRM 0.x 実装
- [magicien/GLTFQuickLook](https://github.com/magicien/GLTFQuickLook)：Quick Look 構成の参考
- [pixiv/three-vrm](https://github.com/pixiv/three-vrm)：VRM の挙動の参考
