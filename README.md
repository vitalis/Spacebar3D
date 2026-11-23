<p align="center">
  <img src="Packages/Spacebar3DKit/Sources/ViewerUI/Resources/Mark.png" width="200" alt="Spacebar 3D's chameleon, half wireframe and half shaded, stepping out of a neon file icon">
</p>

<h1 align="center">Spacebar 3D</h1>
<p align="center"><strong>Your models. One spacebar away.</strong></p>
<p align="center">A native 3D viewer for Finder Quick Look and your Mac.<br>Inspect the mesh. Change the mood. Play the motion.</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-111e17?style=flat-square" alt="Requires macOS 26 or later">
  <img src="https://img.shields.io/badge/Apple_silicon-arm64-a8e6a3?style=flat-square" alt="Apple silicon only">
  <img src="https://img.shields.io/badge/renderer-Metal-b5cfff?style=flat-square" alt="Native Metal renderer">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-f05b99?style=flat-square" alt="Apache License 2.0"></a>
</p>

<p align="center">
  <a href="#get-started">Get started</a> ·
  <a href="#supported-formats">Formats</a> ·
  <a href="#take-control">Controls</a> ·
  <a href="docs/DEVELOPMENT.md">Developer guide</a>
</p>
<p align="center"><strong>English</strong> · <a href="docs/zh-Hans/README.md">简体中文</a> · <a href="docs/es/README.md">Español</a> · <a href="docs/fr/README.md">Français</a> · <a href="docs/de/README.md">Deutsch</a> · <a href="docs/ja/README.md">日本語</a> · <a href="docs/pt-BR/README.md">Português do Brasil</a> · <a href="docs/ko/README.md">한국어</a> · <a href="docs/it/README.md">Italiano</a> · <a href="docs/ru/README.md">Русский</a></p>

---

## Find it. Space it. Spin it.

Select a supported 3D file in Finder and press <kbd>Space</kbd>. Orbit around it,
inspect its topology, try another look, or scrub through an animation.
Open it in the standalone app when you want a dedicated viewer window.

<p align="center">
  <img src="docs/demo.gif" width="900" alt="A tank model in Spacebar 3D's viewer, with the viewing controls visible">
</p>

> **Quick Look has company.** macOS may choose its own preview for OBJ, STL, PLY,
> USD and USDZ. **File → Open…** or Finder's **Open With → Spacebar 3D** always
> opens a supported file in this viewer.

## One model, plenty of looks

| Inspect | Explore | Play |
| :--- | :--- | :--- |
| Solid, Textured and Normal views. Wireframe overlay. Face and vertex counts. | Unshaded, Anime, Cel-Shaded, Retro, Voxel Art and Hologram styles. Flat or smooth shading and material overrides. | Clip selection, scrubbing and repeat. Skeleton previews for supported animation-only files. |

**Set the light.** Choose Glasshouse, Dawn, Noon, Golden Hour, Overcast, Moonlit or
Neon. Adjust brightness and direction, or let the light rotate around the model.

**Keep your bearings.** Click a gizmo axis, orbit, pan, zoom to fit, or turn on the
floor grid. Small Finder previews keep the controls out of the way and show the model only.

**Built for the Mac.** Swift, Metal, SwiftUI and AppKit, shared by the app and its
Quick Look extension. Model processing happens locally; neither target has a network entitlement.

**Ten UI languages.** English, 简体中文, Español, Français, Deutsch, 日本語,
Português do Brasil, 한국어, Italiano and Русский. The interface follows your macOS
language preference. [Localization notes →](docs/LOCALIZATION.md)

<a id="install"></a>

## Get started

**macOS 26 or later · Apple silicon · build from source**

To install from source, you need full Xcode with the macOS 26 SDK or newer,
XcodeGen, CMake and Ninja. The project uses a development signing team and an App
Group, so configure your own signing identity before building if you aren't using
that team. The [signing setup](docs/DEVELOPMENT.md#build-local) explains which
identifiers must agree.

From your local checkout:

```bash
brew install xcodegen cmake ninja
./scripts/build.sh
```

The first build fetches and builds the pinned Assimp dependency. Then:

1. Move `build/Build/Products/Release/Spacebar 3D.app` to **Applications**.
2. **Launch it once** to register the Quick Look extension.
3. Open **System Settings → General → Login Items & Extensions → Quick Look**
   and enable **Spacebar 3D**.
4. Select a supported file in Finder. Press <kbd>Space</kbd>.

To share a build with other people, follow the
[Developer ID signing and notarization guide](docs/DEVELOPMENT.md#distribution-signing--notarization).

<details>
<summary><strong>Make Spacebar 3D your default model viewer</strong></summary>

Open the app's **Settings** and click **Make Default…** to register it for
supported files. macOS may ask for confirmation, and the app reports formats it
couldn't change. This controls Finder double-click behavior; it does not choose
which Quick Look extension macOS uses.

</details>

## Supported formats

**Avatars, game assets, CAD exports, scans and Blender meshes.**

`VRM` · `VRMA` · `glTF` · `GLB` · `FBX` · `OBJ` · `STL` · `3MF` · `PLY` · `USD` · `USDA` · `USDC` · `USDZ` · `3DS` · `BLEND`

<details>
<summary><strong>See exactly what each format supports, including limitations</strong></summary>

| Format | Notes |
|---|---|
| `.vrm` | VRM avatar (0.x / 1.0): toon shading, outlines, spring bones |
| `.vrma` | VRM animation. No mesh, so the motion plays on a stick figure of its skeleton |
| `.glb` / `.gltf` | glTF 2.0, with its materials, textures, skins and animations. A `.gltf` with a separate `.bin` or images is shown once the model's folder is allowed (see below). Draco- and Meshopt-compressed files and instanced meshes are not supported |
| `.fbx` | FBX model, binary or text. Skinned meshes and embedded animation play; images inside the file, beside it or in its `.fbm` folder are used |
| `.obj` | Wavefront OBJ, geometry and vertex colours; materials and textures from its `.mtl` file once the model's folder is allowed (see below); a file with no faces is shown as a point cloud |
| `.stl` | STL, binary or text |
| `.3mf` | 3MF, with its colours per object or per triangle, its images, and metallic and translucent materials |
| `.ply` | PLY mesh with its vertex colours, or point cloud when the file has no faces |
| `.usdz` / `.usd` / `.usda` / `.usdc` | Universal Scene Description, with its materials and embedded textures. Plays skeletal animation |
| `.3ds` | 3D Studio, with its material colours and transparency. Textures stored beside the file are shown once the model's folder is allowed (see below) |
| `.blend` | Blender 2.80 and later: visible meshes and basic materials as saved. Packed images and external textures in the model's allowed folder are read. Modifiers, armature poses and animation are not applied; arbitrary shader node networks are not evaluated |


Animation-only FBX and VRMA files with a supported skeleton play on a stick figure.
No avatar or model data is bundled with the app. Spacebar 3D is a viewer; Blender
modifiers and arbitrary shader node networks are not evaluated.

</details>

### When textures live next door

Some models refer to separate images, materials or geometry files. Use **Show
Textures…**, **Show Materials…** or **Show Model…** when prompted to allow read-only
access to the model's folder. This covers models in that folder and its subfolders.
Embedded textures don't need a folder grant, but must use supported image and material formats.

In the app, a matching material file such as `ship.mtl` beside `ship.obj` can be read
without asking. See [folder access troubleshooting](#textures-are-missing) for grants
across restarts.

If a model opens but none of its referenced textures can be drawn, the viewer
disables **Textured** and uses **Solid** in its place.

<a id="controls"></a>

## Take control

| Do this | Use this |
| :--- | :--- |
| Orbit | Drag, or use arrow keys with the app's model canvas focused |
| Pan | Right-drag, or drag with Shift, Option or Command held |
| Pan with the keyboard | <kbd>Shift</kbd> + arrow keys on the app's canvas, or **View → Pan** |
| Zoom | Scroll or pinch |
| Fit the model | Fit button, or <kbd>⌘</kbd> + <kbd>0</kbd> in the app |
| Look along an axis | Click an axis on the view gizmo |
| Play or pause | Playback button, or <kbd>Space</kbd> with the app's canvas focused |
| Close Quick Look | <kbd>Space</kbd> |
| Choose Solid / Textured / Normal | <kbd>⌘</kbd> + <kbd>1</kbd> / <kbd>2</kbd> / <kbd>3</kbd> in the app |
| Toggle wireframe | <kbd>⌘</kbd> + <kbd>4</kbd> in the app |

The bottom bar holds views, styles and material settings. The right-hand controls
hold the gizmo, lighting, fit, grid and auto-rotate. Animated models get a playback
bar; multiple clips get a chooser. **Repeat** loops the selected animation.

Set your preferred background, solid color, view, brightness, grid, auto-rotation
and animation behavior in the app's **Settings**. The **View** and **Playback** menus
also provide commands when canvas controls are hidden.

<a id="troubleshooting"></a>

## A little help

Open the **?** menu on the viewer toolbar for controls, the privacy policy and
acknowledgements. The menu is available in both the app and Quick Look.

Found a problem or have a question? Choose **Help → Spacebar 3D Support** in the
app, or [open an issue](https://github.com/vitalis/Spacebar3D/issues).

<details>
<summary><strong>The preview doesn't appear</strong></summary>

Launch the app once and enable its Quick Look extension in System Settings.
If it still doesn't appear, refresh Quick Look's cache:

```bash
qlmanage -r && qlmanage -r cache
```

For OBJ, STL, PLY, USD and USDZ, macOS may be using its own preview. Open the model
in Spacebar 3D directly, or see the optional override below.

</details>

<details>
<summary><strong>Prefer Spacebar 3D over Apple's built-in previews</strong></summary>

The repository includes an optional, reversible override:

```bash
scripts/prefer-spacebar3d.sh status
scripts/prefer-spacebar3d.sh on     # prefer Spacebar 3D
scripts/prefer-spacebar3d.sh off    # restore Apple's previews
```

It disables two Apple preview extensions for your user account with `pluginkit`;
no system files are changed. While enabled, MaterialX and Alembic receive a plainer
macOS preview, USDZ loses its AR view, and `.reality` files have no preview. A macOS
update may reset the choice. Opening supported files in the app needs no override.

</details>

<a id="textures-are-missing"></a>
<details>
<summary><strong>Textures are missing</strong></summary>

Use **Show Textures…** to allow the model's folder. A folder allowed only in Quick
Look needs permission again after restarting the Mac. The app remembers its grants;
launching it once after a restart makes them available to Quick Look again.

Missing images, unsupported materials and unsupported image formats can still
prevent a texture from appearing. Check the format notes above.

</details>

## Under the hood

```text
Finder → Space → Quick Look ─┐
                            ├─ ImportRouter → ModelScene → Metal → your model
App → Open a Model… ────────┘
```

The app and extension share `Spacebar3DKit`. Native Swift readers handle STL, PLY,
OBJ, 3MF, glTF, VRM and Blender; Model I/O handles USD; Assimp handles FBX and 3DS.

[Build and architecture](docs/DEVELOPMENT.md) ·
[Localization](docs/LOCALIZATION.md) ·
[Changelog](CHANGELOG.md) ·
[Privacy policy](PRIVACY.md)

## Credits & license

Spacebar 3D is licensed under the [Apache License, Version 2.0](LICENSE).
Copyright © 2026 Vitaly Gorodetsky.

See [CREDITS.md](CREDITS.md) for project origins, contributors and acknowledgements,
and [third-party licenses](THIRD_PARTY_LICENSES.md) for separately licensed components.
These notices are also available in the app under **Help → Acknowledgements**.

<p align="center"><strong>Less opening apps. More looking at models.</strong></p>
