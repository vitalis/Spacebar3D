<p align="center">
  <img src="../../Packages/Spacebar3DKit/Sources/ViewerUI/Resources/Mark.png" width="200" alt="半分がワイヤーフレーム、半分がシェーディングされた Spacebar 3D のカメレオン">
</p>

<h1 align="center">Spacebar 3D</h1>
<p align="center"><strong>モデルまで、スペースキーひとつ。</strong></p>
<p align="center">Finder の Quick Look と Mac のためのネイティブ 3D ビューア。</p>
<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-111e17?style=flat-square" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple_silicon-arm64-a8e6a3?style=flat-square" alt="Apple silicon / arm64">
  <img src="https://img.shields.io/badge/renderer-Metal-b5cfff?style=flat-square" alt="Metal">
  <a href="../../LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-f05b99?style=flat-square" alt="Apache License 2.0"></a>
</p>
<p align="center">
  <a href="#install">はじめに</a> · <a href="#formats">対応形式</a> · <a href="#controls">操作</a> · <a href="DEVELOPMENT.md">開発ガイド</a>
</p>
<p align="center"><a href="../../README.md">English</a> · <a href="../zh-Hans/README.md">简体中文</a> · <a href="../es/README.md">Español</a> · <a href="../fr/README.md">Français</a> · <a href="../de/README.md">Deutsch</a> · <strong>日本語</strong> · <a href="../pt-BR/README.md">Português do Brasil</a> · <a href="../ko/README.md">한국어</a> · <a href="../it/README.md">Italiano</a> · <a href="../ru/README.md">Русский</a></p>

---

## 見つけて、スペース、くるっと確認。

Finder で対応する 3D ファイルを選び、<kbd>スペース</kbd>キーを押すだけ。モデルを回し、トポロジーを確認し、見た目を変えたりアニメーションをスクラブしたりできます。専用のウインドウで見たいときは、アプリで開いてください。

<p align="center">
  <img src="../demo.gif" width="900" alt="Spacebar 3D のビューアに表示された戦車モデルと操作ボタン">
</p>

> OBJ、STL、PLY、USD、USDZ では、macOS 標準のプレビューが選ばれる場合があります。アプリの**ファイル → 開く…**、または Finder の**このアプリケーションで開く → Spacebar 3D**で、対応ファイルをこのビューアに表示できます。

<a id="looks"></a>

## ひとつのモデルを、いろいろな表情で

| 確認する | 試す | 再生する |
| :--- | :--- | :--- |
| ソリッド・テクスチャ・法線表示、ワイヤーフレームの重ね表示、面数と頂点数。 | シェーディングなし、アニメ、セルシェーディング、レトロ、ボクセルアート、ホログラム。フラット／スムーズシェーディングやマテリアルの調整。 | クリップ選択、スクラブ、リピート。対応するアニメーションのみのファイルは骨格で表示。 |

**光を選ぶ。** Glasshouse から Neon まで 7 種類の雰囲気。明るさと方向を調整したり、光を自動回転させたりできます。**向きをつかむ。** ギズモの軸をクリックし、回転、平行移動、全体表示、床グリッドを使い分けられます。Finder の小さなプレビューにはモデルだけを表示します。

**Mac のためのネイティブ実装。** Swift、Metal、SwiftUI、AppKit をアプリと Quick Look 拡張で共有。モデルはローカルで処理し、どちらにもネットワークのエンタイトルメントはありません。UI は上部に並ぶ 10 言語に対応し、macOS の言語設定に従います。[ローカライズの説明（英語）](../LOCALIZATION.md)。

<a id="install"></a>

## はじめに

**macOS 26 以降 · Apple シリコン · ソースからビルド**

macOS 26 以降の SDK を備えたフル版の Xcode、XcodeGen、CMake、Ninja が必要です。プロジェクトには開発用の署名チームと App Group が設定されています。別のチームを使う場合は、ビルド前に[署名の手順](DEVELOPMENT.md#build-local)に従って署名 ID と関連する識別子を設定してください。

ローカルのリポジトリで実行します。

```bash
brew install xcodegen cmake ninja
./scripts/build.sh
```

初回ビルドでは、バージョンを固定した Assimp をダウンロードしてビルドします。

1. `build/Build/Products/Release/Spacebar 3D.app` を**アプリケーション**フォルダへ移動します。
2. **一度アプリを起動**して、拡張を macOS に登録します。
3. **システム設定 → 一般 → ログイン項目と機能拡張 → クイックルック**で **Spacebar 3D** を有効にします。
4. Finder で対応ファイルを選び、<kbd>スペース</kbd>キーを押します。

他の人に配布する場合は、[Developer ID 署名と公証の手順](DEVELOPMENT.md#distribution-signing--notarization)を参照してください。

<details>
<summary><strong>Spacebar 3D をデフォルトのビューアにする</strong></summary>

アプリの設定で **デフォルトに設定…** をクリックします。macOS が確認を求める場合があります。変更できなかった形式はアプリが報告します。Finder でのダブルクリック時の動作を変更するもので、Quick Look 拡張の選択は変わりません。

</details>

<a id="formats"></a>

## 対応形式

アバター、ゲーム素材、CAD 書き出し、スキャンデータ、Blender のメッシュに。

`VRM` · `VRMA` · `glTF` · `GLB` · `FBX` · `OBJ` · `STL` · `3MF` · `PLY` · `USD` · `USDA` · `USDC` · `USDZ` · `3DS` · `BLEND`

<details>
<summary><strong>形式ごとの対応範囲と制限</strong></summary>

| 形式 | 対応範囲 |
| :--- | :--- |
| `.vrm` | VRM 0.x / 1.0 アバター。トゥーンシェーディング、アウトライン、スプリングボーン。 |
| `.vrma` | メッシュを含まない VRM アニメーション。骨格を棒人間として表示して動きを再生。 |
| `.glb` / `.gltf` | glTF 2.0 のマテリアル、テクスチャ、スキニング、アニメーション。外部 `.bin` や画像にはフォルダへのアクセス許可が必要。Draco・Meshopt 圧縮、インスタンス化されたメッシュには非対応。 |
| `.fbx` | バイナリ／テキスト。スキニングされたメッシュと内蔵アニメーション。埋め込み画像、同じフォルダの画像、`.fbm` 内の画像。 |
| `.obj` | ジオメトリと頂点カラー。許可したフォルダの `.mtl` からマテリアルとテクスチャを読み込み。面がない場合は点群表示。 |
| `.stl` | バイナリ／テキストの STL。 |
| `.3mf` | オブジェクト／三角形単位の色、画像、金属・半透明マテリアル。 |
| `.ply` | 頂点カラー付きメッシュ。面がない場合は点群表示。 |
| `.usd` / `.usda` / `.usdc` / `.usdz` | マテリアル、埋め込みテクスチャ、スケルタルアニメーション。 |
| `.3ds` | マテリアルの色と透明度。外部テクスチャにはフォルダへの許可が必要。 |
| `.blend` | Blender 2.80 以降。保存時の可視メッシュと基本マテリアル、パック済み画像、許可したフォルダのテクスチャ。モディファイア、アーマチュアのポーズ、アニメーションは適用せず、任意のシェーダーノード構成も評価しません。 |

対応する骨格を持つアニメーションのみの FBX と VRMA は棒人間で表示します。モデルやアバターのデータは同梱していません。

</details>

### テクスチャが別ファイルにあるとき

**テクスチャを表示…**、**マテリアルを表示…**、**モデルを表示…**から、モデルのフォルダとそのサブフォルダへの読み取り専用アクセスを許可します。埋め込みテクスチャにフォルダ許可は不要ですが、対応する画像・マテリアル形式である必要があります。アプリでは、`ship.obj` の隣の `ship.mtl` のような同名のマテリアルファイルを確認なしで読み込めます。

モデルを開けても参照先のテクスチャを一つも描画できない場合は、**テクスチャ**の代わりに**ソリッド**で表示します。

<a id="controls"></a>

## 操作早見表

| 操作 | 方法 |
| :--- | :--- |
| 回転 | ドラッグ。アプリのモデル領域にフォーカスがあるときは矢印キーも使用可能 |
| 平行移動 | 右ドラッグ、または Shift・Option・Command を押しながらドラッグ |
| キーボードで平行移動 | アプリのモデル領域で Shift + 矢印キー、または表示メニューの平行移動サブメニュー |
| 拡大・縮小 | スクロールまたはピンチ |
| モデル全体を表示 | 全体表示ボタン、またはアプリで ⌘0 |
| 軸に沿って見る | ギズモの軸をクリック |
| 再生・一時停止 | 再生ボタン、またはアプリのモデル領域にフォーカスがある状態でスペース |
| Quick Look を閉じる | スペース |
| ソリッド／テクスチャ／法線 | アプリで ⌘1／⌘2／⌘3 |
| ワイヤーフレームの切り替え | アプリで ⌘4 |

下部には表示・スタイル・マテリアル設定、右側にはギズモ・照明・全体表示・グリッド・自動回転があります。アニメーションバーでクリップ選択とリピートができます。アプリの設定で背景、ソリッドの色、表示、明るさ、グリッド、回転、再生の初期状態を指定します。モデル上の操作部が隠れていても、表示・再生メニューから操作できます。

<a id="help"></a>

## 困ったときは

ビューアのツールバーにある **?** メニューから、操作方法、プライバシーポリシー、謝辞を確認できます。このメニューはアプリと Quick Look の両方で使えます。

問題が見つかった場合や質問がある場合は、アプリで **ヘルプ → Spacebar 3D サポート** を選ぶか、[Issue を作成](https://github.com/vitalis/Spacebar3D/issues)してください。

<details>
<summary><strong>プレビューが出ない</strong></summary>

アプリを一度起動し、拡張を有効にしてください。必要に応じて Quick Look のキャッシュを更新します。

```bash
qlmanage -r && qlmanage -r cache
```

OBJ、STL、PLY、USD、USDZ はアプリで直接開いてみてください。

</details>

<details>
<summary><strong>Apple 標準のプレビューより優先する</strong></summary>

任意の切り替えスクリプトを用意しています。元に戻すこともできます。

```bash
scripts/prefer-spacebar3d.sh status
scripts/prefer-spacebar3d.sh on
scripts/prefer-spacebar3d.sh off
```

`on` で Spacebar 3D を優先し、`off` で Apple の拡張を復元します。`pluginkit` でユーザー単位に Apple の拡張を 2 つ無効にするもので、システムファイルは変更しません。有効な間、MaterialX と Alembic は簡易プレビューになり、USDZ の AR 表示と `.reality` のプレビューが使えなくなります。macOS の更新で設定が戻る場合があります。アプリでの直接表示には不要です。

</details>

<details>
<summary><strong>テクスチャが表示されない</strong></summary>

**テクスチャを表示…**でフォルダを許可します。Quick Look だけで許可したフォルダは、Mac の再起動後に再度許可が必要です。アプリは許可を記憶し、再起動後に一度起動すると Quick Look でも再び使えるようになります。画像の欠落や、非対応の画像・マテリアル形式が原因の場合もあります。

</details>

<a id="architecture"></a>

## 内部のしくみ

アプリと拡張は `Spacebar3DKit` を共有します。`ImportRouter` がファイルを `ModelScene` に読み込み、Metal が描画します。Swift 製リーダーは STL、PLY、OBJ、3MF、glTF、VRM、Blender を担当し、USD は Model I/O、FBX と 3DS は Assimp が担当します。

[ビルドとアーキテクチャ](DEVELOPMENT.md) · [ローカライズ](../LOCALIZATION.md) · [変更履歴](../../CHANGELOG.md) · [プライバシーポリシー（英語）](../../PRIVACY.md)

<a id="credits"></a>

## クレジットとライセンス

Spacebar 3D は [Apache License, Version 2.0](../../LICENSE) で配布されています。
Copyright © 2026 Vitaly Gorodetsky。

プロジェクトの来歴、貢献者、謝辞は [CREDITS.md](../../CREDITS.md)、個別のライセンスを持つコンポーネントの条件は[第三者ライセンス](../../THIRD_PARTY_LICENSES.md)を参照してください。これらの通知はアプリのヘルプメニュー内の謝辞でも確認できます。
