# Developing Spacebar 3D

**English** | [简体中文](zh-Hans/DEVELOPMENT.md) | [Español](es/DEVELOPMENT.md) | [Français](fr/DEVELOPMENT.md) | [Deutsch](de/DEVELOPMENT.md) | [日本語](ja/DEVELOPMENT.md) | [Português (Brasil)](pt-BR/DEVELOPMENT.md) | [한국어](ko/DEVELOPMENT.md) | [Italiano](it/DEVELOPMENT.md) | [Русский](ru/DEVELOPMENT.md)

Build, test and debug the native macOS app and its Quick Look extension.
For features and supported-format limitations, see the [README](../README.md).

[Setup](#requirements) · [Build](#build-local) · [Tests](#tests) ·
[Architecture](#how-it-works) · [Troubleshooting](#troubleshooting) ·
[Distribution](#distribution-signing--notarization)

All shell commands below run from the repository root unless stated otherwise.

<a id="requirements"></a>

## Requirements

| Requirement | Notes |
| :--- | :--- |
| Apple silicon Mac running macOS 26 or later | The project and Assimp build target `arm64`; no Intel slice is produced. |
| Full Xcode with a macOS 26 or newer SDK | Command Line Tools alone are insufficient. The current local development environment uses Xcode 27.0. |
| XcodeGen | Generates the Xcode project from `project.yml`. |
| CMake and Ninja | Build the native Assimp dependency. |
| Python 3 | Runs the localization consistency checker. |
| Development signing identity | Required for the installed app/extension and their shared App Group. See below. |

```bash
brew install xcodegen cmake ninja
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

If your shell selects Command Line Tools or a different Xcode installation, select
full Xcode for that shell before building:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`build.sh` also detects that standard installation when `xcode-select` points at
Command Line Tools. Direct `xcodebuild` and dependency-build commands need the
correct developer directory themselves.

<a id="build-local"></a>

## Build (local)

<a id="configure-signing"></a>

### Configure signing

The checked-in configuration uses the development team in
[`project.yml`](../project.yml). To build with your own team:

1. Set `DEVELOPMENT_TEAM` and suitable bundle identifiers in `project.yml`.
2. Configure an App Group for that team. Use the same group identifier in
   [`Spacebar3D.entitlements`](../Spacebar3D/App/Spacebar3D.entitlements),
   [`Spacebar3DExtension.entitlements`](../Spacebar3D/Extension/Spacebar3DExtension.entitlements)
   and `ViewerSettings.appGroup` in
   [`ViewerSettings.swift`](../Spacebar3D/Shared/ViewerSettings.swift).
3. Make sure Xcode can use the team's Apple Development certificate and any
   required provisioning assets. Regenerate the project after configuration changes.

The current App Group is `V3AQWQ8JMY.com.vitalis.Spacebar3D`. Changing only the team
on a build command does not update that identifier. Unsigned or ad-hoc builds are
not a substitute for testing extension registration and shared-container access.

<a id="build-the-app"></a>

### Build the app

```bash
./scripts/build.sh
```

The script builds Assimp if its framework is absent, runs XcodeGen, and builds the
`Spacebar3D` scheme in Release configuration. Output:

```text
build/Build/Products/Release/Spacebar 3D.app
```

The first build needs network access for dependencies. Assimp is pinned in
[`build-assimp.sh`](../scripts/build-assimp.sh) to `v6.0.6`, with the full commit SHA
`a79ff6bbce54d3e01186a918dc6374ed55317426` checked before compilation. The script
builds a static arm64 XCFramework with the FBX and 3DS importers, with exporters
and Draco disabled.

Re-run that script when the pin changes; `build.sh` checks whether the framework
exists, not whether it matches the current pin. To use an existing checkout at
the required commit:

```bash
ASSIMP_SRC=/path/to/assimp ./scripts/build-assimp.sh
```

<a id="register-and-exercise-quick-look"></a>

### Register and exercise Quick Look

1. Copy the built app to `/Applications` and launch that copy once.
2. Enable **Spacebar 3D** in **System Settings → General → Login Items & Extensions → Quick Look**.
3. Select a supported file in Finder and press Space.
4. Open the same file through the app's **File → Open…** to check both hosts.

If registration is stale, refresh the cache and try a GLB file:

```bash
qlmanage -r
qlmanage -r cache
qlmanage -p /path/to/model.glb
```

macOS may choose Apple's own preview for OBJ, STL, PLY, USD and USDZ. That is not
proof that this extension failed. Use the app or the optional override described
in the [README](../README.md#a-little-help).

<a id="development"></a>

## Development

For editing and debugging in Xcode:

```bash
./scripts/build-assimp.sh
xcodegen generate
open Spacebar3D.xcodeproj
```

Build Assimp once per dependency revision, then regenerate the project when
`project.yml` changes. The `.xcodeproj`, both generated `Info.plist` files, build
output and `Vendor/Assimp.xcframework` are ignored by Git. Edit the YAML source,
not the generated project or property lists.

For an incremental Debug build from the terminal:

```bash
xcodebuild -project Spacebar3D.xcodeproj -scheme Spacebar3D \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build build
```

`SKIP_XCODEGEN=1 ./scripts/build.sh` reuses an existing generated project while
still building Release. Use it only when that project matches the YAML.

<a id="capture-media"></a>

### Capture a preview and screenshots

Run the capture script from a logged-in macOS desktop session with the build
prerequisites above. In System Settings, grant screen recording permission to the
app you run the script from.

If the model references external textures, materials or geometry, open it in
the regular Spacebar 3D app first. Use the viewer's folder button to grant
access to the folder containing those assets. The capture build uses the saved
grant. Opening the model file alone can leave its companion files inaccessible.

```bash
brew install ffmpeg
./scripts/capture-media.sh /path/to/model.glb
```

The script builds and launches a separate copy of Spacebar 3D with capture
enabled. Set `SPACEBAR3D_APP` to the path of an existing capture-enabled
`.app` bundle to reuse it. The script creates a new folder under
`build/media-captures/` by default. Pass an unused path as the second argument
to choose the output folder.

The public Mac App Store preview, `preview.mp4`, runs for 30 seconds at
1920 × 1080 and 30 fps. It shows every rendering style available for the model.
The script also writes four 2560 × 1600 PNGs and `demo.gif`. For models with at
least three styles, the GIF uses the same 15-second edit as the feature loop.
With fewer styles, it uses the preview at its original speed. For the first
screenshot, the script uses Textured when that view is available and saves
`01-textured.png`. Otherwise, it uses Solid and saves `01-solid.png`. The other
images are `02-wireframe.png`, `03-normals.png`, and `04-hologram.png`.

<a id="capture-feature-loop"></a>

### Capture a feature loop

Use the same capture setup to make a 15-second loop at 30 fps. The loop needs
at least three available styles and favors Cel-Shaded, Voxel Art and Hologram.

```bash
./scripts/capture-feature-loop.sh /path/to/model.glb
```

The script writes `feature-loop.mp4` to a new folder under
`build/media-captures/` by default. Pass an unused path as the second argument
to choose the output folder.

<a id="capture-screenshots"></a>

### Capture App Store screenshots

Use the same capture setup to generate the four 2560 × 1600 sRGB PNGs
listed above.

```bash
./scripts/capture-screenshots.sh /path/to/model.glb
```

By default, the script writes to a new folder under `build/media-captures/`.
Pass an unused path as the second argument to choose the output folder.

<a id="capture-app-review"></a>

### Record a private App Review walkthrough

Install and launch the regular Spacebar 3D app and enable its Quick Look
extension. Choose a model that opens interactively in Finder Quick Look.
Close any Quick Look preview in Finder and any standalone viewer window
with the same filename before recording.
Grant screen recording permission as above and install the Swift command-line
tools and FFmpeg with the `drawtext` and `subtitles` filters. Keep the terminal
visible and follow its prompts. In Finder, keep the file selected and switch to
List view if needed. When prompted, press Space and orbit or zoom twice.
Click **Open with Spacebar 3D** when prompted. If macOS opens an app menu, pick
Spacebar 3D. If the button is unavailable, close Quick Look and open the same
file from **File → Open…** in Spacebar 3D. Orbit or zoom twice in the standalone
viewer.

```bash
SPACEBAR3D_REVIEW_ANIMATION_MODEL=docs/app-store/Spacebar3D-Review-Model.glb \
  ./scripts/capture-app-review.sh /path/to/model.fbx build/media-captures/app-review
```

The script adds captions and writes `app-review.mp4` to a new folder under
`build/media-captures/`. Pass an unused path as the second argument to choose
the output folder. Set `SPACEBAR3D_REVIEW_APP` if your installed copy is outside
`/Applications/Spacebar 3D.app`.

The script records the viewer controls, Settings, Help and Privacy chapters
after the guided capture. The example adds playback using the original
animated sample. Set `SPACEBAR3D_REVIEW_CAPTURE_APP` to reuse an existing
capture-enabled app. By default, the script builds one with the development
setup above.

For an existing recording of the guided Finder and viewer steps alone,
`capture-review-features.sh` can add the chapters. See its `--help`.

<a id="tests"></a>

## Tests

Build Assimp before resolving the package or running either test route.

<a id="full-xcode-suite"></a>

### Full Xcode suite

This is the main regression command. It includes the app/shared/extension source
tests and all nine package test targets declared in `project.yml`.

```bash
xcodegen generate
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build
python3 scripts/check-localizations.py
```

For a focused run, append an `-only-testing` selector, for example:

```bash
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build \
  -only-testing:ViewerUITests/NativeViewerInputTests
```

Xcode writes `.xcresult` bundles under `build/Logs/Test/`.

<a id="package-only-tests"></a>

### Package-only tests

These omit the host-source tests in `Spacebar3DTests`:

```bash
xcrun swift test --package-path Packages/Spacebar3DKit
```

Two large-model tests are opt-in through `P3D_LARGE=1`. One creates an approximately
100 MB STL fixture. To run that benchmark explicitly:

```bash
P3D_LARGE=1 xcrun swift test --package-path Packages/Spacebar3DKit \
  --filter LargeModelTests
```

<a id="what-the-tests-establish"></a>

### What the tests establish

- Settings tests use explicit temporary storage. Add normalization cases to
  [`settings-vectors.json`](../testdata/settings-vectors.json) when settings rules change.
- Importer tests build small fixtures and exercise malformed and truncated inputs.
- Renderer tests draw offscreen and inspect pixels; they need a working Metal device.
- Viewer tests exercise native input, accessibility metadata, commands, layout and
  SwiftUI controls, including ViewInspector checks.
- Localization checks validate source-key coverage, catalog entries and placeholders;
  package tests also exercise compiled language resources.

The Xcode scheme compiles host sources into a test bundle. It does not launch the
signed app inside its production sandbox. Passing it does not establish Quick Look
registration, folder permissions, VoiceOver speech or a notarized download's behavior.
For those changes, also test the installed signed app and the Finder extension.

<a id="how-it-works"></a>

## How it works

```text
Finder → Quick Look extension ─┐
                              ├─ ViewerFactory → NativeViewer
App → model window ───────────┘                      │
                                     ImportRouter → ModelScene
                                                     │
                                           RenderMetal / MTKView
                                           + SwiftUI controls
```

The two hosts share the local `Spacebar3DKit` package. Import work runs off the main
thread; the native viewer coordinates rendering and controls.

| Area | Responsibility |
| :--- | :--- |
| `Spacebar3D/App/` | Setup, settings, model windows, default-app registration, menus, Help and acknowledgements. |
| `Spacebar3D/Extension/` | Quick Look preview lifecycle. |
| `Spacebar3D/Shared/` | Viewer construction and shared settings. |
| `Packages/Spacebar3DKit/Sources/ModelCore/` | Scene data, format detection, animation, topology and localization. |
| `…/Sources/ImportRouter/` and `…/Sources/Import*/` | Format dispatch and readers. |
| `…/Sources/RenderMetal/` | GPU scene, camera, shading and rendering. |
| `…/Sources/ViewerUI/` | Viewer API, native input, SwiftUI controls and folder grants. |
| `…/Sources/CZstd/` | Vendored Zstandard decoder for compressed Blender files. |
| `Spacebar3DTests/` and `Packages/Spacebar3DKit/Tests/` | Host-source and package tests. |
| `docs/<language-code>/README.md` | The nine non-English READMEs. |
| `docs/<language-code>/DEVELOPMENT.md` | The nine translated development guides. |

Native Swift readers handle STL, PLY, OBJ, 3MF, glTF/GLB, VRM/VRMA and Blender.
Model I/O handles USD; Assimp handles FBX and 3DS. `FormatDetector` uses leading
bytes and, for ambiguous text formats, the extension. Supported document types
and `QLSupportedContentTypes` are declared in `project.yml`.

Animation-only files with a supported skeleton can use a stick-figure preview.
No default avatar is bundled. Format support is deliberately narrower than a full
DCC application; keep the README's limitations accurate when changing readers.

<a id="implementation-notes"></a>

## Implementation notes

<a id="sandbox-and-related-files"></a>

### Sandbox and related files

Both targets use App Sandbox and user-selected read-only file access. Neither
has a network entitlement or a temporary sandbox exception.

Opening a model does not grant unrestricted access to neighboring files. Both
hosts can offer **Show Model…**, **Show Materials…** or **Show Textures…** to request
its folder. The app also supports designated same-name companion material files,
such as `ship.mtl` beside `ship.obj`, through its related-file handling.

[`FolderGrants.swift`](../Packages/Spacebar3DKit/Sources/ViewerUI/FolderGrants.swift)
keeps app grants as security-scoped bookmarks. Quick Look keeps its own plain
bookmarks and reads copies refreshed by the app in the shared container. A
Quick Look-only grant must be renewed after a Mac restart; launching the app
refreshes its remembered grants for the extension. Read access is bounded to the
granted folders and their descendants.

<a id="settings"></a>

### Settings

`ViewerSettings` stores `viewer-settings.json` in the App Group container. The app
writes it; new viewers load its normalized values. Invalid, oversized or missing
settings fall back to defaults. There is no migration from the old non-container
`~/Library/Application Support/Spacebar3D/` location.

<a id="input-and-accessibility"></a>

### Input and accessibility

Plain arrows orbit and Shift-arrows pan only when the standalone model canvas
handles keyboard input. Plain Space plays or pauses there; it is not a global
menu shortcut and must not steal activation from focused buttons or sliders.
Quick Look retains its own Space-to-close behavior. Menu and accessibility actions
provide alternatives to pointer gestures.

When changing controls, check keyboard focus, narrow windows, long translations,
Increase Contrast and Reduce Transparency. Check actual VoiceOver announcements
separately from accessibility-tree assertions.

<a id="localization-and-documentation"></a>

### Localization and documentation

The shared string catalog is
`Packages/Spacebar3DKit/Sources/ModelCore/Resources/Localizable.xcstrings`. It serves
the app and extension in ten languages. Follow [LOCALIZATION.md](LOCALIZATION.md)
for complete strings, placeholders, compiled resources and layout checks.

The English README is at the root; translations are under `docs/<language-code>/`.
Translated development guides live in the same language folders; the English source
is `docs/DEVELOPMENT.md`. Keep format caveats, controls, installation, permission
behavior and development procedures aligned across all versions.

<a id="troubleshooting"></a>

## Troubleshooting

| Symptom | Check |
| :--- | :--- |
| Package resolution reports missing Assimp | Run `./scripts/build-assimp.sh` with full Xcode, CMake and Ninja available. |
| Signing fails or shared settings are unavailable | Check the certificate, team, bundle IDs and matching App Group identifiers. An environment variable alone does not rewrite entitlements. |
| Edits disappear after generation | Change `project.yml`, not generated `.xcodeproj` or `Info.plist` files. |
| Extension is absent or an old version loads | Launch the intended installed app, enable its extension, check registration and refresh Quick Look. Avoid confusing installed and build-directory copies. |
| Apple's viewer opens instead | See the built-in format caveat above; compare with File → Open in the app. |
| Textures or geometry are missing | Read the notice, authorize the model folder, and check format limits and companion files. |
| A GPU test fails | Confirm a Metal device is available and inspect the failure; do not treat an unavailable GPU as a passing rendering check. |

Inspect extension registration and stream its logs:

```bash
pluginkit -m | rg -i spacebar3d
log stream --predicate 'process == "Spacebar3DExtension"'
```

The first command uses `rg` from ripgrep; `grep -i spacebar3d` is an alternative.
In another terminal, run `qlmanage -p /path/to/model.glb`. A rejected model should
show an error in the preview; check whether the issue is import, rendering, access
or extension selection before changing signing or permissions.

<a id="distribution-signing--notarization"></a>

## Distribution (signing & notarization)

The supplied scripts implement **direct Developer ID distribution as a DMG**.
They do not archive, export or upload a Mac App Store build. Store distribution
needs a separate signing, archive/export and App Store Connect submission flow.

Direct distribution requires a Developer ID Application identity and notarization.
See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
for the signing and service requirements.

<a id="manual"></a>

### Manual

After configuring matching team and App Group identifiers:

```bash
SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ./scripts/build.sh
```

When `SIGN_IDENTITY` is supplied, the build script selects manual signing, passes
`DEVELOPMENT_TEAM`, adds a secure timestamp and disables injection of base debug
entitlements. Hardened Runtime is enabled in `project.yml`. Without `SIGN_IDENTITY`,
the script uses the project's development-signing configuration.

For local notarization, prefer a Keychain profile. Store credentials interactively
with `notarytool`, then invoke the script using the profile name:

```bash
xcrun notarytool store-credentials "spacebar3d-notary"
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" ./scripts/notarize.sh
```

The script accepts an optional app path:

```bash
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" \
  ./scripts/notarize.sh "/path/to/Spacebar 3D.app"
```

Authentication is selected in this order:

| Method | Variables |
| :--- | :--- |
| Keychain profile | `NOTARY_KEYCHAIN_PROFILE` |
| App Store Connect API key | `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER` |
| Apple Account credentials | `APPLE_TEAM_ID`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` |

The last method passes an app-specific password as a `notarytool` argument; the
Keychain profile avoids that on a shared development machine. Keep signing keys
and credentials out of the repository.

`notarize.sh` verifies the app's Developer ID signature and creates a DMG with an
Applications shortcut. It signs the DMG with the identity read from the app
signature, or with `SIGN_IDENTITY` if supplied. Keep that certificate and private
key available in your keychain. The script submits the DMG to Apple, waits for
acceptance, staples and validates the ticket on the DMG, then checks Gatekeeper
with `spctl`. After all checks pass, it writes `Spacebar3D.dmg` in the repository
root. Test the downloaded artifact before sharing it.

<a id="automated-github-actions"></a>

### Automated (GitHub Actions)

[The release workflow](../.github/workflows/release.yml) runs on the Apple silicon
`macos-26` runner with Xcode 26. Push or select a tag in the form
`vMAJOR.MINOR.PATCH` that matches `MARKETING_VERSION` and points to a commit on
`origin/main`.

The workflow generates the project and runs `Spacebar3DTests` and the localization
checker before importing the signing certificate. It builds with Developer ID,
checks the app and extension versions against the tag, then signs and notarizes
the DMG. It deletes the temporary signing keychain before attaching the DMG to
the GitHub Release.

Configure these secrets on the **actual destination repository**:

| Secret | Contents |
| :--- | :--- |
| `MACOS_CERTIFICATE` | Base64-encoded Developer ID Application certificate and private key exported as `.p12`. |
| `MACOS_CERTIFICATE_PWD` | Password for that `.p12`. |
| `KEYCHAIN_PASSWORD` | Password for the temporary build keychain. |
| `APPLE_TEAM_ID` | Signing team ID. |
| `NOTARY_APPLE_ID` | Apple Account used for notarization. |
| `NOTARY_PASSWORD` | Its app-specific password. |

Use an explicit repository when configuring secrets, for example
`gh secret set APPLE_TEAM_ID --repo OWNER/REPOSITORY`, which prompts for the value.
Do not assume the local `origin` identifies an existing or intended release repository.

Before creating a release tag, set `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in `project.yml`, update the changelog, run the tests and
verify the signed build. Pushing the matching tag can publish a GitHub Release
once the workflow succeeds.

<a id="references"></a>

## References

- [Native renderer architecture](architecture/native-rewrite.md)
- [Viewer design](design/neon-garden-viewer.md)
- [Localization](LOCALIZATION.md)
- [Third-party licenses](../THIRD_PARTY_LICENSES.md)
- [Apple: customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [magicien/VRMQuickLook](https://github.com/magicien/VRMQuickLook), a SceneKit VRM 0.x implementation
- [magicien/GLTFQuickLook](https://github.com/magicien/GLTFQuickLook), a Quick Look structure reference
- [pixiv/three-vrm](https://github.com/pixiv/three-vrm), a reference for VRM behavior
