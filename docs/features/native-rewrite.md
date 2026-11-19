# Feature: native Swift renderer and Mac App Store release

> Requirements from the November 12, 2026 feature interview. The
> [architecture plan](../architecture/native-rewrite.md) records the results of the
> technical checks. See the [development guide](../DEVELOPMENT.md) for the
> current implementation and release workflow.

## Raw request

"Refactor the project to macOS / Swift native app"

## Classification

A rewrite of the renderer, not a new feature. The host app, the Quick Look extension, file
reading (`ModelPayload`) and settings (`ViewerSettings`) are already Swift. What is not
native is everything that draws: the format loaders, the looks, the controls and the
Hologram style run as three.js inside a `WKWebView` (`renderer/`).

## Decisions

| Question | Decision |
|---|---|
| Main goal | Ship on the Mac App Store |
| Scope | Full native rewrite now. The App Store does not require it (web views are allowed there); this was chosen anyway |
| Formats | The 13 that remain of the 14 that open today (COLLADA is dropped), with no regressions, before release |
| Readers | Apple's frameworks where they cover a format; Assimp (C++) for the rest; our own Swift code for what neither covers |
| Viewer | Every view and style stays; each may be redesigned for native rendering and need not match today's screenshots |
| Separate textures | Quick Look shows the model untextured and says so; the app asks once for folder access and shows it textured |
| macOS | The current release and the one before it. Older Macs keep the web-based 1.0.0 |
| Rollout | Format by format; the web renderer is deleted when the last format has moved; the App Store submission follows |
| Developer account | A paid Apple Developer Program membership exists |

Decided after the architecture step (see `docs/architecture/native-rewrite.md`):

| Question | Decision |
|---|---|
| Rendering | Our own Metal renderer, as the architecture recommends (SceneKit is deprecated; RealityKit loads only USD) |
| glTF / GLB / VRM / VRMA | Read by our own Swift reader, not Assimp |
| COLLADA | Dropped (owner decision, 2026-11-12): no longer a supported format |
| Old settings | Reset to defaults on upgrade; no import |
| VRM at release | VRM 0.x and 1.0, toon shading and outlines, expressions and look-at, spring bones and constraints |
| Space bar for OBJ, STL, PLY, USD | The override script is not shipped or mentioned in the App Store version; the app offers to be the default app for those formats and adds a Finder right-click action |
| Hologram at release | The full effect, redesigned natively |
| Quick Look textures | Shown for folders granted in the app if the extension turns out to be able to use the grant; otherwise untextured |
| Processors | Apple silicon only |
| Licence notices | An Acknowledgments window opened from the app menu |

## Requirements

- No web view is involved in opening any of the 13 formats: VRM, VRMA, glTF / GLB
  (including separate-file glTF and Draco compression), FBX, OBJ, STL, 3MF, PLY,
  USD / USDA / USDC / USDZ, 3D Studio, Blender 2.80 and later.
- The viewer keeps: Solid, Textured and Normal views; the wireframe overlay that follows the
  file's own polygons; View Settings (flat / smooth, PBR, metallic, roughness); the Unlit,
  Cartoon, Sketch and Hologram styles; the view gizmo, fit view, lighting, grid and
  auto-rotate; topology, face and vertex counts; animation playback with clip selection
  and scrubbing; the app's settings.
- The app and the extension run with App Store sandbox entitlements only. The read-only
  home-folder exception and the settings-folder path exception are removed; settings are
  shared through an App Group.
- Models whose textures are separate files (FBX, DAE, 3DS, multi-file glTF):
  - in Quick Look, the model is shown without those textures, with a visible notice;
  - in the app, access to the model's folder is asked for once and remembered, and the
    model is shown textured.
- While the rewrite is in progress the app stays usable: a format is handled by the native
  renderer once it has moved, and by the web renderer until then.

## Non-goals

- Matching the current looks pixel for pixel.
- Supporting macOS versions older than the previous release.
- A second, direct-download build that keeps the home-folder exception.
- Intel Macs.
- Carrying existing settings over to the App Store version.
- Shipping or mentioning the Space-bar override script in the App Store version.
- Asking App Review to approve the home-folder exception.

## Acceptance criteria

1. Each of the 13 formats opens in Quick Look and in the app with no web view involved.
2. The app and the extension are signed with App Store entitlements and contain no
   temporary sandbox exceptions.
3. Every view, style and control listed under Requirements is present and works on each
   format it applies to.
4. A model with separate textures shows the notice in Quick Look, and its textures in the
   app after the folder grant; the grant survives relaunching the app.
5. At release the repository contains no Node, Vite or three.js code.
6. The existing Swift tests pass, and each format has a native load test.

## Open technical checks

These are inputs to the architecture step. Each is stated from general knowledge and has
not been checked against current documentation.

- **Rendering framework.** Which Apple framework to build on for the two supported macOS
  versions.
- **Apple's own format coverage.** Assumed: OBJ, STL, PLY, USD / USDZ and COLLADA are read
  by system frameworks; glTF / GLB, VRM, FBX, 3MF, 3DS and Blender are not.
- **Assimp coverage.** Assumed: it reads FBX, glTF, 3MF and 3DS; its Blender reader does
  not handle 2.80+ files; it has no VRM support. These decide how much Swift is written
  for VRM, VRMA and Blender, and whether Draco needs separate handling.
- **Assimp in an App Store build.** Licence terms, binary size, build set-up, and whether
  the polygon structure the wireframe and statistics rely on survives its import.
- **Folder access.** Whether a folder grant made in the app can be used by the Quick Look
  extension. Assumed not, which is why Quick Look stays untextured.
- **Space-bar override.** `scripts/prefer-spacebar3d.sh` stays outside the app; whether an
  App Store listing may mention it is unknown.
- **App Review.** Whether a Quick Look extension that overlaps Apple's own previews
  (OBJ, STL, PLY, USD, USDZ) draws an objection.

## Task shape

1. **App Store foundation.** Team, App Group for settings, exception-free entitlements,
   App Store signing. Done first so every later build is tested in the real sandbox.
2. **Native renderer core.** Scene, camera, the three views, wireframe, grid, lighting,
   statistics; the formats Apple's frameworks read (OBJ, STL, PLY, USD / USDZ).
3. **Assimp integration.** FBX and 3DS (3MF got its own reader, COLLADA is dropped); then animation playback.
4. **Own readers.** glTF / GLB, with VRM and VRMA on top; Blender 2.80+; Draco and Meshopt decoding.
5. **Styles.** Unlit, Cartoon, Sketch and Hologram, redesigned natively.
6. **Separate textures and entry points.** The folder-access flow in the app, the untextured
   notice in Quick Look, the default-app offer and the Finder right-click action.
7. **Removal and release.** Delete the web renderer, update the docs and tests, submit.

The format-by-format switch from the web renderer happens in steps 2 to 4.
