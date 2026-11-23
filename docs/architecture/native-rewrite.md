# Architecture: native Swift renderer and Mac App Store release

> Architecture plan from November 12, 2026, based on the
> [native rewrite requirements](../features/native-rewrite.md). See the
> [development guide](../DEVELOPMENT.md) for the current implementation and release workflow.
> The plan used Xcode 27 / macOS 27.0 SDK
> (`SDKSettings.json`: `"Version":"27.0"`). Supported OS range is therefore **macOS 26 and
> macOS 27**, deployment target **macOS 26.0**, **Apple silicon only** (owner decision 7).
>
> Revised the same day to follow the owner's answers in section 8 ("Owner decisions").
>
> Every claim below is either marked **confirmed** with its primary source, or labelled
> **unverified** / **estimate**. Recommendations that rest on an unverified item say so.

---

## 1. Verification of the open technical checks

Sources: "SDK" means the installed `MacOSX.sdk` (27.0) headers and `.swiftinterface` files;
"Apple docs" means developer.apple.com documentation JSON; "Assimp" means files on
`github.com/assimp/assimp` branch `master` (CMake `PROJECT(Assimp VERSION 6.0.6`); "Guidelines"
means the App Store Review Guidelines page as fetched on 2026-11-12.

### 1.1 Rendering framework

| Claim | Result | Source |
|---|---|---|
| SceneKit is current on macOS 26/27 | **Refuted.** "SceneKit is deprecated, use RealityKit instead." Deprecated at 26.0 on every platform, including macOS. The SDK headers carry no deprecation macro (soft deprecation), so the compiler will not warn. | Apple docs, SceneKit framework page and `SCNSceneSource` metadata (`deprecatedAt: 26.0`); SDK `SCNView.h` |
| Mac App Store apps may use deprecated technologies | **Refuted.** 2.4.5(viii): "Apps should run on the currently shipping OS and may not use deprecated or optionally installed technologies (such as Java)." Whether App Review applies this to a soft-deprecated framework is **unverified**, but it is a written rule. | Guidelines 2.4.5(viii) |
| RealityKit is available on macOS with custom shaders | **Confirmed.** `CustomMaterial` (Metal `SurfaceShader` + `GeometryModifier`, lit/unlit lighting models) `@available(macOS 12.0, …)`, unavailable only on visionOS. `ShaderGraphMaterial` macOS 15. | SDK `RealityFoundation.swiftinterface` |
| RealityKit has runtime skeletal animation and low-level meshes on macOS | **Confirmed (API exists).** `MeshResource.Skeleton`, `SkeletalPosesComponent`, `BlendShapeWeightsComponent`, `LowLevelMesh` (part `topology: MTLPrimitiveType`), `LowLevelTexture`, `ImageBasedLightComponent`: macOS 15. `SampledAnimation`: macOS 12. `ARView` (NSView): macOS 10.15. `RealityView` (SwiftUI): macOS 15. | SDK `RealityFoundation`, `RealityKit`, `_RealityKit_SwiftUI` swiftinterfaces |
| RealityKit renders line primitives / polygon wireframe | **Unverified.** `triangleFillMode` exists (triangle edges only, not polygons). Whether a `LowLevelMesh` part with `.line` topology is drawn is not documented. | SDK (API shape only) |
| Metal / MetalKit current and usable | **Confirmed current.** `MTKView` `API_AVAILABLE(macos(10.11))`, no deprecation; new API added in macOS 26 / 26.4 (`currentMTL4RenderPassDescriptor`, `residencySet`). | SDK `MTKView.h` |
| RealityKit / Metal / Model I/O usable in an app extension | **Confirmed not marked unavailable**: no `ApplicationExtension, unavailable` attribute in RealityKit, RealityFoundation, `_RealityKit_SwiftUI`; no `NS_EXTENSION_UNAVAILABLE` on `MTKView`. Whether they run within Quick Look's memory and launch-time budget is **unverified** (spike S1). | SDK |

### 1.2 Apple framework format coverage (spec assumption: OBJ, STL, PLY, USD/USDZ, COLLADA read by the system)

| Format | Reader | Result | Source |
|---|---|---|---|
| OBJ, PLY, STL, USD (.usd/.usda/.usdc/.usdz), Alembic | Model I/O `MDLAsset` | **Confirmed** as Model I/O's file types (`kUTType3dObject`, `kUTTypePolygon`, `kUTTypeStereolithography`, `kUTTypeUniversalSceneDescription`, `kUTTypeAlembic`). Import vs export direction per type is not stated on that page; `MDLAsset.canImportFileExtension` settles it at runtime. | Apple docs, Model I/O "Asset File Types" |
| Polygon structure through Model I/O | `MDLAsset(url:vertexDescriptor:bufferAllocator:preserveTopology:error:)` | **Confirmed**: with `preserveTopology`, uniform-face submeshes keep their geometry type (e.g. quads) and mixed ones get `MDLGeometryTypeVariableTopology` + `faceTopologyBuffer`; the default initialisers triangulate. | SDK `MDLAsset.h` |
| USD via RealityKit | `Entity(contentsOf:)` | **Confirmed**: "RealityKit supports loading entities from USD (.usd, .usda, .usdc, .usdz) and Reality (.reality) files." macOS 15. | Apple docs |
| COLLADA (.dae) | SceneKit `SCNSceneSource` only | **Partly refuted**: read only by SceneKit (".dae, macOS 10.8 and later"), which is deprecated (1.1). Model I/O does not list it. So COLLADA is **not** covered by a non-deprecated Apple framework and goes to Assimp. | Apple docs `SCNSceneSource` |
| glTF/GLB, VRM, FBX, 3MF, 3DS, Blender | — | **Confirmed not listed** by Model I/O, SceneKit or RealityKit loading docs. | Same pages |
| Model I/O fidelity: OBJ `.mtl` materials, USD skinning/animation, PLY point clouds, STL colour | — | **Unverified.** Model I/O has `MDLSkeleton`/`MDLPackedJointAnimation`/`MDLMaterial` types, but how much of a given file survives must be measured on the test corpus (spike S6). | — |

### 1.3 Assimp

Since owner decision 1, Assimp is used **only for FBX, 3MF, 3DS and COLLADA**.

| Claim | Result | Source |
|---|---|---|
| Reads FBX, 3MF, 3DS, COLLADA (also glTF 2.0, OBJ, STL, PLY, not used here) | **Confirmed** (importer list). | Assimp `doc/Fileformats.md` |
| USD | **Confirmed opt-in/experimental**: "REQUIRES OPT-IN: enable cmake option `ASSIMP_BUILD_USD_IMPORTER`"; CMake comment "Experimental USD importer: disabled". Not used. | Assimp `Fileformats.md`, `CMakeLists.txt` |
| Blender reader does not handle 2.80+ | **Confirmed in effect, more strongly than assumed**: "support for BLEND is deprecated … It is too time-consuming to maintain an undocumented format". Which versions it once read was **not checked**; irrelevant since it is deprecated. | Assimp `Fileformats.md` |
| No VRM support | **Confirmed**: VRM not mentioned. | Assimp `Fileformats.md` |
| Draco | **Confirmed build option** (`ASSIMP_BUILD_DRACO … "Primarily for glTF" OFF`). Not needed now: our own glTF reader decodes Draco through Google's Draco decoder directly, so Assimp is built with it **off**. | Assimp `CMakeLists.txt` |
| Meshopt | **Unverified / probably absent** in Assimp (not listed). Moot: our glTF reader uses the meshoptimizer decoder. | Assimp `Fileformats.md` |
| Licence | **Confirmed BSD 3-Clause**; binary redistribution "must reproduce the above copyright notice … in the documentation and/or other materials provided with the distribution" (the Acknowledgments window satisfies this). Compatible with the App Store (no copyleft). Licences of bundled `contrib/` libraries: **unverified**, audited in spike S2. | Assimp `LICENSE` |
| Can be built static, without exporters | **Confirmed options**: `BUILD_SHARED_LIBS` (default ON, set OFF), `ASSIMP_NO_EXPORT`, `ASSIMP_BUILD_ZLIB`. Per-importer switches not checked. | Assimp `CMakeLists.txt` |
| Polygon structure survives import | **Unverified.** Expected behaviour (faces keep their corner count unless `aiProcess_Triangulate` is requested) is from memory; spike S2 measures it on the quad FBX/DAE/3DS test files. | — |
| Binary size | **Unverified.** Estimate only: low single-digit MB (arm64 only) for the four importers; measured in S2. | — |

### 1.4 Sandbox, folder access, settings

| Claim | Result | Source |
|---|---|---|
| App Group container usable by app and extension from the Mac App Store | **Confirmed**: requires `com.apple.security.application-groups` and `containerURL(forSecurityApplicationGroupIdentifier:)`; works without a prompt when "distributed through the Mac App Store, or notarized"; otherwise the system asks the user. | Apple docs "Accessing files from the macOS App Sandbox" |
| Folder grant persists across relaunch | **Confirmed**: security-scoped bookmark (`withSecurityScope`, optional `securityScopeAllowOnlyReadAccess`), resolve then `startAccessingSecurityScopedResource()`. | Same page |
| A grant made in the app can be used by the Quick Look extension | **Unverified.** The documented cross-process route is a bookmark *without* security scope handed by the app to "another process, like a launch agent or an XPC service". Quick Look launches the extension, not our app; the page does not mention extensions or App Group sharing of bookmarks. Spike S3 tests the one plausible route. Owner decision 6 says what happens with either result. | Same page |
| Related files with the same base name can be opened without a grant | **Confirmed for apps**: `NSIsRelatedItemType` + `NSFilePresenter.primaryPresentedItemURL` + `NSFileCoordinator`. Covers `model.mtl`, `model.bin`; not arbitrarily named textures or `model.fbm/`. Inside a Quick Look extension: **unverified**. | Same page |
| Old settings file can be migrated without an exception | **Refuted by construction**: the old file is outside both containers. Owner decision 2: settings reset to defaults; no migration. | `Spacebar3D/Shared/ViewerSettings.swift`, entitlements |

### 1.5 App Review

| Claim | Result | Source |
|---|---|---|
| A Quick Look extension overlapping Apple's own previews draws an objection | **Unverified.** No guideline addresses it directly. 4.4 requires extensions to be disclosed in marketing text and to offer settings/help "where possible". | Guidelines 4.4, 4.2, 4.3 |
| The listing may mention `scripts/prefer-spacebar3d.sh` | **Settled by owner decision 4**: neither shipped nor mentioned in the App Store version. Risk context: 2.5.9 ("alter or disable … native user interface elements or behaviors"), 2.4.5(iv), 2.5.2. | Guidelines |
| The Apple extensions are `com.apple.HydraQLPreviewExtension` / `com.apple.RAQLPreviewExtension` | **Unverified** (repository script only); no longer relevant to the store build. | `scripts/prefer-spacebar3d.sh` |
| Other blocking rules | 2.4.5(i) sandboxed; (ii) Xcode packaging, self-contained bundle; (iv) no downloaded code; (vii) updates via the store; (viii) no deprecated technologies. All satisfied by this design if SceneKit is avoided. | Guidelines 2.4.5 |

### 1.6 Default app and Finder action (added for owner decision 4)

| Claim | Result | Source |
|---|---|---|
| An app can ask to become the default app for a type | **Confirmed API**: `NSWorkspace.setDefaultApplication(at:toOpen: UTType, completionHandler:)`, macOS 12; "Some types require user consent … the system will ask the user asynchronously before invoking the completion handler." Whether it works from a sandboxed App Store app, and whether our `LSHandlerRank: Alternate` must change, is **unverified** (spike S7). | SDK `NSWorkspace.h` |
| Being the default app changes what Space does | **No**: it changes double-click / Open. Space stays with whichever Quick Look extension macOS prefers (owner decision 4 already says no supported override is known; not re-checked). | — |
| Services (`NSServices` in Info.plist) exist on macOS | **Confirmed key exists** (macOS 10.0+; `NSMenuItem`, `NSMessage`, `NSSendTypes`, …). That a file-based service shows in Finder's right-click menu (Quick Actions / Services), the exact file-type keys, and that it works for a sandboxed App Store app are **unverified** (spike S7). | Apple docs `NSServices` |
| "Open With → 3D Preview" already exists | **Confirmed in repo**: `CFBundleDocumentTypes` with `LSHandlerRank: Alternate` for all 14 formats. | `project.yml` |

---

## 2. Recommended architecture

### 2.1 Rendering framework: Metal + MetalKit, own renderer

**Decision.** Build a purpose-made renderer on **Metal** (`MTKView` in AppKit, hosted by both
the Quick Look view controller and the app's window), shaders in Metal Shading Language,
controls in SwiftUI over the view. Built for arm64 only.

| Option | Verdict | Why |
|---|---|---|
| **SceneKit** | Rejected | Deprecated at macOS 26 (confirmed) and 2.4.5(viii) forbids deprecated technologies (confirmed text). Technically the closest fit (shader modifiers, `SCNTechnique`, skinning, DAE import), so this is a real loss, including its COLLADA reader. |
| **RealityKit** | Runner-up | Current and recommended by Apple, with PBR, IBL, skeletons, blend shapes, `CustomMaterial` (confirmed). Against it for this app: one material per mesh part, so outline and wireframe passes become duplicated entities; no custom per-vertex attributes in `CustomMaterial` as far as the API shape shows; line rendering, transparent/gradient background, screen-space effects (Hologram glow, sketch hatching, glyph rain) and start-up cost in Quick Look are unverified. Its loader covers 4 of 14 formats; every other importer produces our own scene either way. The full Hologram and full VRM requirements (MToon, outlines) make fine control more valuable, not less. |
| **Metal (own renderer)** | **Chosen** | Current and not extension-restricted (confirmed as far as the SDK marks it). Multi-pass looks, a polygon-edge pass, GPU skinning, morph targets, MToon, our own metallic-roughness PBR with overrides, alpha-cleared or gradient background, particles and bloom are all ordinary renderer work under our control. Cost: we write the renderer (section 6.2). |

Switch condition: if task T3 (renderer core) overruns badly, re-evaluate RealityKit for the
Textured view only; the looks, Hologram and VRM stay on Metal either way.

### 2.2 Readers per format

| Format | Reader | Notes |
|---|---|---|
| STL, PLY, OBJ | Model I/O, `preserveTopology: true` | Fidelity check in S6. Fallback: Assimp (also reads all three) if S6 fails. |
| USD / USDA / USDC / USDZ | Model I/O | Skinning/animation via `MDLSkeleton` / `MDLPackedJointAnimation` (exists; fidelity unverified, S6). |
| FBX, COLLADA, 3DS, 3MF | Assimp (static, arm64) | The only Assimp formats (owner decision 1). |
| glTF / GLB (incl. separate files, Draco, Meshopt), VRM, VRMA | **Own Swift glTF 2.0 reader** (owner decision 1), with Google's Draco decoder (C++, Apache-2.0, the licence of today's decoder) and the meshoptimizer decoder (C, MIT) as vendored C targets | VRM/VRMA refer to glTF node/mesh/material indices and need the raw extension JSON, which this reader keeps. |
| Blender ≥ 2.80 | **Own Swift .blend reader** | Assimp's is deprecated. Same scope as today (`renderer/src/blend.ts`): visible meshes of the first scene as saved, Principled BSDF plain values, packed base-colour images, zstd/gzip containers. Needs a zstd decoder (vendored C, BSD) and gzip (system). |

### 2.3 Module boundaries

One local Swift package, `Packages/Spacebar3DKit`, consumed by both targets. XcodeGen keeps
generating the project; the package is a local package dependency.

```
Spacebar3DKit (SwiftPM, macOS 26, arm64)
├── ModelCore        pure Swift, no GPU: ModelScene types, FormatDetector (port of format.ts),
│                    SourceTopology/statistics, LookState, ViewerSettings model + normalize
├── FileAccess       sidecar resolution policy (port of ModelPayload's folder rules and limits),
│                    ResourceProvider protocol, FolderGrantStore (bookmarks)
├── ImportModelIO    Model I/O → ModelScene (STL, PLY, OBJ, USD*)
├── CAssimpBridge    C API shim over Assimp (extern "C"), links binaryTarget assimp.xcframework
├── ImportAssimp     Swift: CAssimpBridge → ModelScene (FBX, DAE, 3DS, 3MF)
├── CDraco, CMeshopt vendored decoder targets (pinned)
├── ImportGLTF       Swift glTF 2.0 reader
├── VRM              VRM 0.x / 1.0 layer on ImportGLTF output; VRMA retargeting; spring-bone
│                    and constraint solvers (CPU, per frame)
├── CZstd            vendored zstd decoder
├── ImportBlend      Swift .blend reader
├── ImportRouter     Format → importer; the only module that knows all importers
├── RenderMetal      GPU scene, passes, looks (incl. MToon and Hologram), shaders (.metal),
│                    animation sampling, skinning, morphs
└── ViewerUI         ViewerController (NSViewController: MTKView + SwiftUI controls),
                     gizmo, looks bar, animation bar, statistics, notices
```

Dependency direction: `ModelCore` ← everything; importers depend on `ModelCore` and
`FileAccess` only; `VRM` depends on `ImportGLTF` and `ModelCore`; `RenderMetal` depends on
`ModelCore` only (never on an importer; the per-frame VRM solvers write poses through a
`ModelCore` animation-pose interface); `ViewerUI` depends on `RenderMetal`, `ImportRouter`,
`ModelCore`. Only `ViewerUI` and the targets import AppKit.

Targets:

- **Spacebar3DExtension**: thin `PreviewViewController` creating a `ViewerController` with a
  `ResourceProvider` that allows the previewed file only — or, if spike S3 succeeds, also files
  inside folders the app has granted (owner decision 6). Unread sidecars drive the
  "shown without textures" notice. Reads settings from the App Group. Never asks for access.
- **Spacebar 3D (app)**: settings window (writes App Group settings); viewer windows; the
  folder-grant flow; the **default-app offer** (2.8); the **Finder action** (2.8); an
  **Acknowledgments** item in the app menu opening a window with each bundled project's
  licence text and the credit to sawa-zen's original project (owner decision 8; wording by the
  owner).
- **Assimp** sits only behind `CAssimpBridge` (a few C functions:
  `p3d_import(bytes, length, formatHint, ioCallbacks, limits) -> p3d_scene*`, accessors,
  `p3d_free`). Swift never sees C++ types. Assimp's file access goes through a custom
  `IOSystem` in the shim that calls back into Swift's `ResourceProvider`, so Assimp cannot open
  any file our policy did not allow.

### 2.4 Scene representation (`ModelCore.ModelScene`)

Value types, `Sendable`, produced off the main thread, consumed by the renderer. Importers do
all coordinate/unit fix-ups (Z-up → Y-up, VRM 0.x facing) so the renderer has one convention.

- `nodes: [Node]` — name, parent index, local TRS, optional `mesh`, `skin`.
- `meshes: [Mesh]` → `parts: [MeshPart]` — vertex streams (position, normal, tangent, uv0,
  uv1, colour, joints4, weights4), `triangleIndices`, **`faceSizes: [UInt32]?`** (corner count
  per source polygon in triangle order; `nil` for triangle-only sources), `material`, morph
  targets, `primitive` (`.triangles` | `.points`).
- `materials: [Material]` — canonical metallic-roughness (base colour, metallic, roughness,
  normal, occlusion, emissive, alpha mode/cutoff, double-sided, `unlit`), `authoredPBR: Bool`
  (false for Phong/Lambert sources, so override sliders know they supply a stand-in), and
  `extensions` (e.g. `MToon` parameters, VRM 0.x and 1.0 normalised to one MToon model).
- `textures: [TextureRef]` — `.embedded(Data, mime)`, `.sidecar(name)`, `.missing(name)`.
- `skins`, `animations: [Clip]` (node TRS / morph-weight channels with interpolation).
- `topology: SourceTopology` — faces, vertices, triangles, quads, n-gons as authored.
- `vrm: VRMDocument?` — meta, humanoid map, expressions (incl. 0.x blend shape groups),
  look-at (bone and expression types), first-person, spring bones (joints, colliders,
  groups), node constraints (aim / roll / rotation).
- `diagnostics` — missing resources (drives the notice), skipped features.

### 2.5 Looks

`LookState` (view, style, wire, flat, pbr, metallic?, roughness?) keeps the shape of
`looks.ts`, so `defaultShading` values and `lookToState` port 1:1. A look resolves to a **pass
list** per mesh part:

| Pass | Used by |
|---|---|
| Surface (PBR, Lambert, unlit, matcap clay, normal, toon ramp, sketch, **MToon**, hologram shell) | every view/style; one fragment function per kind with function constants for flat/smooth, textured, skinned |
| Outline (back-face hull pushed along normals in clip space; MToon outline width/colour/mode from the material) | Cartoon, Sketch, VRM MToon outlines |
| Polygon wire (line list built once from `faceSizes`, depth-biased, expanded to screen-space quads for width/anti-aliasing; all triangle edges when `faceSizes` is nil) | wireframe overlay |
| Hologram effects (build front and reveal, rays from points around the model, rising scan pass, slice glitches, sparkling grains/particles, falling glyph columns from a Core Text-drawn atlas, bloom glow) | Hologram — **full effect at release** (owner decision 5) |

The polygon wire as real line geometry replaces today's barycentric trick and quad-pairing
heuristics, because importers hand over face lists directly. Materials are never mutated;
looks pick pipelines, so every look is exactly undoable.

### 2.6 What must be written in Swift / MSL, with relative size

Relative size points (estimate, not measured): S = 1, M = 2, L = 4, XL = 8.

| Component | Size | Points |
|---|---|---|
| Metal renderer core (camera/orbit, fit, grid, lights, PBR + generated environment for IBL, transparency, skinning, morphs, gizmo picking) | L | 4 |
| Looks (clay, normal, unlit, cartoon, sketch, polygon wire, outline) | M | 2 |
| **Hologram, full** (see 2.5) | **L** | 4 |
| Controls in SwiftUI (looks bar, view settings, gizmo, animation bar, stats, notices) | M | 2 |
| glTF 2.0 reader + Draco/Meshopt glue | M | 2 |
| **VRM 0.x + 1.0, full** (MToon shading + outlines, expressions, look-at, spring bones, constraints, 0.x corrections) | **XL** | 8 |
| VRMA (humanoid retargeting; stick figure without mesh) | M | 2 |
| **Blender ≥ 2.80 reader** | **L** | 4 |
| Assimp build + shim + Swift conversion | M | 2 |
| Model I/O conversion | S | 1 |
| Format detection, topology, file-access policy, settings (ports) | S | 1 |
| Folder grant + Quick Look notice (+ Quick Look textures if S3 passes) | S | 1 |
| Default-app offer, Finder action, Acknowledgments window | S | 1 |
| Containment (XPC import service in the app, fuzzing in CI) | M | 2 |
| App Store foundation; web removal and release | S + S | 2 |
| **Total** | | **38** |

### 2.7 Data flow

**Quick Look extension**

1. `preparePreviewOfFile(at:)` → `FormatDetector.detect(prefix bytes, extension)`.
2. `RendererRoute.route(format)` → native or web (section 5). Native continues:
3. `ImportRouter.load(url, provider:, limits)` on a background task; file memory-mapped;
   today's `ModelPayload` size limits kept.
4. Importer (+ `VRM` layer for VRM/VRMA) → `ModelScene` + diagnostics.
5. The completion handler is called when the first frame is ready, or with the error.
6. `RenderMetal.prepare(scene)` uploads buffers/textures; `ViewerController` applies settings
   from the App Group and the default look; draws on demand (animating, spring bones settling,
   auto-rotate, Hologram, interaction) and stops in `viewDidDisappear`.
7. Missing sidecars → visible notice.

**App**: identical from step 2, except the `ResourceProvider` reads inside granted folders and
the import runs in the XPC service (section 3). Missing sidecars outside any grant → model
untextured with a "Show textures…" button running the grant flow (4.2), then reload.

### 2.8 Default-app offer and Finder action (owner decision 4)

- **Default-app offer.** In the app (the settings window and a one-time first-launch prompt,
  decided in N1) a "Make 3D Preview the default app for OBJ, STL, PLY, USD and USDZ"
  control calls `NSWorkspace.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: UTType)`
  per type (API confirmed, 1.6) and shows the current default via
  `urlForApplication(toOpen: UTType)`. The copy must say this changes double-click, not Space.
  Sandbox behaviour and whether `LSHandlerRank` must change from `Alternate` for these five
  types: **unverified**, spike S7.
- **Finder action — proposed mechanism: a Service** declared in the app's `NSServices`
  ("Open in 3D Preview", accepting the 14 file types), handled by the app's services provider,
  which opens a viewer window. Chosen because it needs no extra target and no folder
  monitoring. **Unverified**: that it appears in Finder's right-click menu for these files,
  the exact file-type keys, and sandbox/App Store suitability (spike S7). If S7
  fails, an Action extension offered as a Finder Quick Action is tried next (decided in N2;
  unverified, and a third bundle to sign and review); the existing "Open With → 3D Preview"
  (confirmed present) is what remains if that fails too. A Finder Sync extension is rejected:
  it only acts in folders it monitors.

---

## 3. Containment for untrusted parsing

All readers (Assimp in particular, plus Draco, zstd and our own parsers) parse files chosen by
anyone who can put a file in Finder.

- **Process**: the Quick Look extension is already a separate sandboxed process; a crash only
  kills the preview. In the app, imports run in an **XPC service** embedded in the app
  (documented as a valid bookmark receiver, 1.4), so a crashing or hanging import does not take
  down the app and can be killed on timeout. Embedding an XPC service in the `.appex`:
  **unverified**, not required.
- **Surface**: only the four Assimp importers needed, `ASSIMP_NO_EXPORT=ON`, Draco off, no USD
  or Blender importers, no post-processing beyond validation and normal generation.
- **I/O**: Assimp file access only via the shim's `IOSystem` → `ResourceProvider`.
- **Limits**: existing byte limits; vertex/face/node/joint/texture-dimension caps checked
  before allocation; spring-bone joint/collider caps; a wall-clock timeout in the app.
- **Testing**: a fuzz target per reader (libFuzzer on the C shims; corpus tests for the Swift
  readers) in CI with Address Sanitizer; pinned upstream versions with an update procedure.
- No network entitlement once the web renderer is gone.

---

## 4. Sandbox, entitlements and settings

### 4.1 Entitlements at release

Both targets: `com.apple.security.app-sandbox`, `com.apple.security.application-groups =
[<group id>]`. App only: `com.apple.security.files.user-selected.read-only` (open panel, folder
grant), `com.apple.security.files.bookmarks.app-scope` (entitlement name from memory —
**verify** in Xcode's capability editor). Removed: both `temporary-exception` keys, and
`com.apple.security.network.client` when the web renderer goes. Hardened Runtime stays on.
Signing: Apple Development locally, Apple Distribution for submission, automatic provisioning
with the team ID. `ARCHS = arm64` (owner decision 7); no x86_64 build or test work.

App Group identifier: `<TEAMID>.com.vitalis.Spacebar3D` (team-prefixed form; documented as
working for App Store and notarized builds, 1.4).

### 4.2 Folder grant (app)

1. The importer's diagnostics list sidecar names the provider refused.
2. The window offers "Show textures…" → `NSOpenPanel` (directories only, starting at the
   model's folder, prompt says why).
3. Store `bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])`
   keyed by the folder's resolved path — in the app's container by default; in the App Group
   if spike S3 shows the extension can resolve it there.
4. On later loads, the provider finds a grant containing the model's folder, resolves it,
   starts access, reads within today's rules (model folder and usual texture subfolders, no
   symlink escapes, size/count limits), stops. Stale bookmarks are refreshed or dropped.
5. Declare `.mtl` and `.bin` as `NSIsRelatedItemType`, so same-named sidecars open without a
   grant (confirmed mechanism, 1.4).

### 4.3 Quick Look textures

Owner decision 6: if S3 passes, Quick Look shows textures for granted folders and the notice
elsewhere; otherwise Quick Look stays untextured with the notice. Embedded textures (GLB, VRM,
FBX with embedded media, USDZ, packed .blend images) show in Quick Look either way.

### 4.4 Settings

New location: `viewer-settings.json` in the App Group container (keeps
`ViewerSettings.normalize`, its tests and the shared vectors). Owner decision 2: **reset to
defaults on upgrade**; no migration code, no import panel. The release notes say so.

---

## 5. Migration seam and per-format plan

### 5.1 The seam

- `ModelCore.Format` enum (the cases of `format.ts`, with `vrm`/`vrma` split after glTF JSON
  inspection).
- `ViewerUI.RendererRoute.route(for:) -> .native | .web`, backed by one
  `static let nativeFormats: Set<Format>`. Moving a format is a one-line change plus its tests.
- Debug-only override `P3DForceRenderer = web|native` (launch argument / user default) for
  side-by-side comparison.
- `WebViewerController` is today's WKWebView code behind the same `Viewer` protocol as
  `ViewerController`, so the hosts do not know which one they show.
- **A format moves only when it has no regression against 1.0.0** for that format: views,
  wireframe, statistics, every style, animation where it has any. Hence Unlit/Cartoon/Sketch
  (T4) come before the first move, Hologram falls back to the web renderer on native formats
  until the full native Hologram (T8) lands, and **VRM stays on the web
  renderer until all of VRM is done** (owner decision 3) — no partial VRM ever ships, even
  locally.
- Consequence of the App Store foundation coming first: with the home-folder exception gone,
  the **web** path loses sidecar textures for formats not yet moved. Stated so it is not filed
  as a regression; it is removed format by format as FBX, DAE, 3DS and glTF move.
- **Deletion at the end**: remove `WebViewerController`, `renderer/`, the XcodeGen pre-build
  script and folder reference, `ModelPayload.base64/script/texturesJSON` (folder rules live on
  in `FileAccess`), `network.client`, Node/Vite from docs and CI, three.js-family licences;
  `RendererRoute` collapses to native. Acceptance criterion 5 is then a grep.

### 5.2 Order

| Step | Formats | Reader | Why here |
|---|---|---|---|
| 1 | STL | Model I/O | Simplest; proves the pipeline. |
| 2 | PLY (mesh + points), OBJ | Model I/O | Proves `faceSizes` and point rendering. |
| 3 | USD family | Model I/O | Embedded textures, first skinned animation → animation bar. |
| 4 | 3MF, 3DS | Assimp | First Assimp formats, small. |
| 5 | COLLADA | Assimp | Animations; sidecars → folder grant lands here. |
| 6 | FBX | Assimp | `.fbm` folder; skeleton-only display. |
| 7 | glTF / GLB | Swift glTF | Separate files, Draco, Meshopt. |
| 8 | VRM, then VRMA | Swift glTF + VRM | Moves only when complete. |
| 9 | Blender | Swift .blend | Independent; can run in parallel from step 4. |

The task list (7) puts Unlit, Cartoon and Sketch (T4) before the first format moves, and
covers Hologram on native formats by a temporary web fallback until T8, so every moved format
keeps every style.

---

## 6. Risks and size

### 6.1 Ranked risks (likelihood × impact)

| # | Risk | L | I | Mitigation / retiring spike |
|---|---|---|---|---|
| 1 | **VRM complete at release** (MToon + outlines, expressions, look-at, spring bones, constraints, 0.x and 1.0) is the largest item and sits on the critical path; spring-bone behaviour and MToon look are judged against three-vrm by eye | High | High | Spike S4 builds the riskiest parts first (spring bones with colliders, MToon with outline) on one 1.0 and one 0.x avatar; the reference corpus is compared side by side via the debug override. No deferral is possible, so the only lever is starting early and in parallel. |
| 2 | **Full Hologram at release** overruns: many coordinated effects (build, rays, scan, glitch, particles, glyph rain, glow) with timing tuned by eye | High | Med–High | Spike S8 (rays + glyph atlas + bloom in Metal, the parts with no counterpart elsewhere in the renderer); build it as an effect graph with the timings of `hologram.ts` as data. Release-blocking, so it runs in parallel with the format work. |
| 3 | **Blender ≥ 2.80 reader** breaks across Blender versions | Med (was High; see S5 result) | Med | Spike S5 matched Blender on 44 files from 18 versions, 2.80 to 5.2, including 3.6 LTS and 4.2 LTS. Remaining risk is in the data S5 did not read. |
| 4 | **App Review** objects to the Quick Look overlap, the default-app offer, or applies 2.4.5(viii) to anything we use | Med | High | No SceneKit; no script; Review Notes describe the extension, viewer, default-app offer and service (2.3.1(a)); no early submission (decided in N3): an objection is first discovered at the release submission, so this risk is accepted, not mitigated. |
| 5 | **Assimp fidelity** for FBX/DAE (materials, embedded textures, animation, units, polygon lists) below three.js | Med | High | Spike S2 with a regression corpus vs 1.0.0 screenshots and statistics. |
| 6 | Metal in Quick Look: memory/launch limits with large models, spring bones and the Hologram running | Med | Med | Spike S1. |
| 7 | Security bug in a C/C++ parser via a crafted file | Low–Med | High | Section 3. |
| 8 | Model I/O fidelity gaps | Med | Med | Spike S6; fallback Assimp for OBJ/PLY/STL. |
| 9 | Finder action or default-app offer not workable in the sandbox | Med | Low | Spike S7; fallbacks in 2.8. |
| 10 | Settings reset on upgrade | Certain | Low | Accepted (decision 2); release note. |

### 6.2 How big the two release requirements are

On the point scale of 2.6 (estimates), **VRM + VRMA (10) and the full Hologram (4) are 14 of
38 points, about 37 % of the whole project**. That is more than the renderer core, the basic
looks, the controls and all Model I/O and Assimp formats together (4 + 2 + 2 + 1 + 2 = 11).
Adding the Blender reader (4), the three items whose size the spec does not signal account for
**18 of 38, close to half**. Calendar estimates are deliberately not given.

---

## 7. Sequenced tasks

### 7.1 Spikes first (each a throwaway branch with a written result)

Ordered by how much of the plan a failure would invalidate:

1. **S1 Metal in Quick Look** — `MTKView` in `QLPreviewingController`, transparent and
   gradient clear, one skinned mesh, `.metal` shaders compiled from the package. Measure memory
   and time to first frame (20 MB and 100 MB models). *Invalidates:* the framework choice for
   the extension.
2. **S2 Assimp build and link** — script building a static arm64 `assimp.xcframework` from a
   pinned tag (FBX, DAE, 3DS, 3MF; no export; Draco off), linked via `CAssimpBridge` into the
   sandboxed, hardened extension; size; `faceSizes` on the quad FBX/3DS/DAE files; `contrib/`
   licence audit. *Invalidates:* the reader plan for four formats.
3. **S4 VRM risk core** — spring bones with colliders and MToon + outline on one 1.0 and one
   0.x avatar. *Re-sizes:* the critical path.
4. **S8 Hologram risk core** — rays, glyph columns from a Core Text atlas, bloom.
5. **S5 Blender versions**, **S6 Model I/O fidelity** — each can move one format to a
   different reader.
6. **S3 Bookmark in extension**, **S7 default app + Service in sandbox** — affect only the
   Quick Look textures and the Finder integration; can run any time before T9 / T16.

### 7.2 Tasks

**T1 App Store foundation** (precise):
- `project.yml`: `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE: Automatic`, identity "Apple
  Development"; deployment target `26.0`; `ARCHS: arm64`; remove `CODE_SIGN_IDENTITY: "-"`.
- Both `.entitlements`: remove both `temporary-exception` keys; add
  `com.apple.security.application-groups = [<TEAMID>.com.vitalis.Spacebar3D]`; keep
  `network.client` for now (web renderer).
- `ViewerSettings.fileURL` → App Group container + `viewer-settings.json`; keep
  `load(from:)`/`save(_:to:)` so existing tests pass unchanged; no migration code (decision 2).
- Update the comments in `ViewerSettings.swift` and the entitlements; update
  `docs/DEVELOPMENT.md` (signing, settings location, sidecar textures not read by the web path).
- Release scripts: App Store export path (may be its own task).
- Acceptance: both targets build signed and run; Settings round-trip app → extension;
  `codesign -d --entitlements -` shows no temporary exception; existing Swift tests pass.

**T2 Package skeleton and seam** (precise):
- `Packages/Spacebar3DKit` with `ModelCore` and `ViewerUI`; local package in `project.yml` for
  both targets and the test target.
- Port `detectFormat`/`isFBX`/`isOBJ`/`isSTL`/`isBlend` to `ModelCore.FormatDetector` with the
  renderer's format test cases ported; port `SourceTopology` and `topologyLabel`.
- Move today's WKWebView code into `WebViewerController` behind a `Viewer` protocol; add
  `RendererRoute` with an empty `nativeFormats`; both hosts go through it.
- Acceptance: behaviour identical (manual check, all 14 formats, both hosts); new tests pass.

**T3 Renderer core + STL native** (precise enough to begin): `RenderMetal` camera/orbit/fit,
grid, lights, Solid, Textured (PBR + overrides), Normal views, flat/smooth, polygon-wire pass,
statistics; `ImportModelIO` for STL; `ViewerUI` controls without styles and animation. STL is
**not** added to `nativeFormats` until T4 (no style regression). Acceptance: STL renders
natively under the debug override with all views, wireframe, counts and settings; native load
test passes.

Then:

- **T4** Styles Unlit, Cartoon, Sketch (incl. outline pass) → STL moves to native.
- **T5** PLY + OBJ native.
- **T6** USD family + animation bar (clip selection, scrubbing).
- **T7** Assimp integration (from S2) + 3MF, 3DS.
- **T8** Full Hologram (from S8), in parallel with T5–T7 if a second implementer is available.
  Until T8 lands, choosing Hologram on a native format reloads that model in the web renderer
  (one temporary seam rule, deleted with T8), so moved formats never lose the style.
- **T9** Folder grant, Quick Look notice, Quick Look textures if S3 passed; `NSIsRelatedItemType`.
  Also here (owner decision, 2026-11-12): our own `.mtl` reader for OBJ (`mtllib`, `usemtl`, `vt`,
  one part per material; colours, opacity, texture names), since this is when the file can first
  be reached. OBJ stays on our reader; Model I/O is not used for it.
- **T10** ~~COLLADA native~~ dropped with the format (owner decision, 2026-11-12). **T11** FBX native.
- **T12** glTF / GLB + Draco + Meshopt native. ← *earliest sensible stopping point (7.3)*
- **T13** VRM: 13a VRM 1.0 + MToon + outlines; 13b expressions + look-at; 13c spring bones +
  constraints; 13d VRM 0.x → only then VRM moves to native.
- **T14** VRMA native.
- **T15** Blender native (parallel track from T7 on).
- **T16** Default-app offer (Settings control and one-time first-launch prompt), Finder Service
  or, if S7 rules it out, a Quick Action extension; Acknowledgments window (after S7).
- **T17** Containment: XPC import service in the app, fuzzing in CI.
- **T18** Remove the web renderer (5.1), docs, licences.
- **T19** App Store metadata, Review Notes, submission.

Seam rule note for T3/T4: the earlier draft let formats move before styles; that is withdrawn.
The T8 Hologram fallback above is the only temporary cross-routing.

### 7.3 Stopping point and critical path

- **Earliest sensible stopping point: after T12.** Every format that keeps textures in separate
  files (FBX, DAE, 3DS, glTF) is native with the folder grant, so the local build has no
  regression against 1.0.0 even without the home-folder exception; VRM, VRMA and Blender still
  work through the web renderer with embedded data, as today. It is a sound local build — not
  an App Store build, because the web view (and `network.client`) remain and VRM/Hologram
  requirements are unmet. Stopping earlier (after T1–T11) leaves multi-file glTF without
  textures on the web path, a regression.
- **Critical path to submission:** S1 → T1 → T2 → T3 → T4 → T12 (glTF) → T13a–d (VRM) → T14
  (VRMA) → T18 → T19. VRM is the long pole. Parallel tracks that must finish before T18: the
  Hologram (S8 → T8), Blender (S5 → T15), Assimp formats (S2 → T7, T10, T11), T9, T16, T17.

Handoff owners: implementation per task; tests are part of each task's acceptance (QA reviews
the corpus comparisons of S2, S4, S6 and the per-format moves); product/design owns the look
specs for T4, T8 and MToon, the notice/grant copy (T9), the default-app copy (T16) and the
Acknowledgments wording; review checks each task against sections 2–5.

---

## 8. Questions for the owner

1. **glTF through our own Swift reader instead of Assimp.** VRM needs it anyway; one glTF path
   instead of two. Accept this deviation from "Assimp for the rest"?
2. **Settings reset** on upgrade (no exception-free silent migration). Accept, or add an
   "Import old settings…" panel?
3. **VRM scope for "no regressions"**: spring-bone physics, expressions, look-at, constraints,
   VRM 0.x — all required for release, or which can follow later?
4. **Space-bar override**: accept that App Store users get Apple's previews for OBJ, STL, PLY,
   USD, USDZ in Finder (the app still opens them), and that the script is neither shipped nor
   mentioned in the listing?
5. **Hologram redesign latitude**: is a simpler intro (no glyph columns/beams) acceptable for
   the first release?
6. **If spike S3 shows Quick Look can use the app's folder grants**: show textures in Quick Look
   for granted folders, or keep Quick Look always untextured as specified?
7. **Intel Macs**: ship universal (arm64 + x86_64) while macOS 26 is supported, or Apple silicon
   only? (Which Intel Macs run macOS 26/27 was not verified.)
8. **Licence notices UI**: an acknowledgments window in the app (BSD/Apache require notices in
   "documentation and/or other materials") — placement and wording.

### Owner decisions (2026-11-12)

Answers to the questions above. Where an earlier section of this document assumed something
different, these answers take precedence.

1. **glTF reader:** our own Swift reader for glTF, GLB, VRM and VRMA. Assimp is not used for
   glTF. Draco and Meshopt decoding still need a library or our own code.
2. **Settings:** reset to defaults on upgrade. No import panel.
3. **VRM scope:** all of it is required at release: VRM 0.x and 1.0, the toon shading and
   outlines, expressions and look-at, spring bones and constraints. Nothing is deferred.
4. **Space bar:** the App Store version neither ships nor mentions the override script (it
   stays in the public repository). Instead the app offers to be the default app for OBJ,
   STL, PLY and USD / USDZ, and adds a Finder right-click action. No supported way to take
   over Space for those types is known; this was not re-checked against macOS 27
   documentation.
5. **Hologram:** the full effect at release (build animation, rays, scan pass, glitches,
   particles, falling characters, glow), redesigned natively. No simplified first version.
6. **Quick Look textures:** if spike S3 shows the extension can use a folder grant made in
   the app, Quick Look shows textures for granted folders and the untextured notice
   elsewhere. Otherwise Quick Look stays untextured.
7. **Processors:** Apple silicon only. Intel Macs still running a supported macOS version
   are not served.
8. **Licence notices:** an "Acknowledgments" item in the app menu opens a window listing each
   bundled project with its licence text and the credit to sawa-zen's original project.
   Wording to be drafted and approved by the owner.

Consequences for the plan: decisions 3 and 5 keep the two most expensive items (VRM, the
Hologram) in the first release; decision 4 adds two small tasks (default-app offer, Finder
action); decision 7 removes the x86_64 build and test work.

### New questions raised by these decisions

- **N1 Default-app offer placement:** only a control in Settings, or also a one-time prompt at
  first launch? (Either way it changes double-click, not Space.)
- **N2 Finder action fallback:** if spike S7 shows a Service cannot appear in Finder's
  right-click menu from a sandboxed App Store app, is the existing "Open With → 3D Preview"
  acceptable as the right-click action, or should an Action extension (Quick Action) be tried
  as well?
- **N3 Early review probe:** submit the T1 foundation build (web renderer inside) to TestFlight /
  App Review early to learn about the Quick Look overlap and entitlements, accepting that it is
  not the release build?

Answers (2026-11-12):

| Question | Decision | Effect |
|---|---|---|
| N1 | Settings control and a one-time prompt at first launch | T16 gains the prompt and its copy; it must say that double-click changes and Space does not, and declining must be remembered. |
| N2 | If the Service cannot appear in Finder, try a Quick Action extension | S7 tests the Service first; a failure adds an Action extension target to T16. "Open With" stays as the last resort. |
| N3 | No early submission; only the finished native build goes to review | Risk 4 is accepted: a review objection to the Quick Look overlap or the default-app prompt is found last. S3 and S7 still need the T1 signing, tested locally. |

## 9. Spike results

### S1 Metal in Quick Look — passed (2026-11-12)

Code: branch `spike/s1-metal-quicklook` (throwaway, not for merging). An `MTKView` replaced
the web view inside the real preview extension for a spike-only file type (`.p3dspike`, a
binary STL), opened with `qlmanage -p`. The mesh was drawn unindexed, 32 bytes per corner,
skinned on the GPU with two bones, over a gradient background. Shaders were compiled from a
`.metal` file in the extension target. Machine: Apple M4 Pro, macOS 27, sandboxed ad-hoc
Release build.

| | 19 MB file, 400,000 triangles | 95 MB file, 2,000,000 triangles |
|---|---|---|
| Vertex buffer | 37 MB | 183 MB |
| Read and upload | 0.07 s | 0.04 s |
| First frame presented, from `preparePreviewOfFile` | 0.08 s | 0.06 s |
| Steady frame rate at 1600×1200 | 60 fps | 60 fps |
| Memory footprint at start / steady | 10 MB / 240 MB | 11 MB / 458 MB |

What this shows:

- Metal works inside the sandboxed Quick Look preview extension with the current
  entitlements, including GPU skinning and a custom shader library.
- The extension was not terminated at a 458 MB footprint.
- Time to first frame is far below anything a user would notice for files of this size.

#### Follow-up run (same day): the gaps of the first run

The spike was changed so the Metal path never creates a web view, a magenta view was placed
behind the Metal view, and a probe dirtied 256 MB more memory every half second up to a
4 GB cap.

- **Transparency: confirmed.** With the background fading to alpha 0, the magenta view
  behind shows through the corners in a screenshot of the real Quick Look panel.
- **Baseline: the web view was not the cause.** Without it the numbers are the same
  (8 MB at `loadView`, 238 MB and 455 MB steady). The footprint is roughly 175 MB fixed
  plus about 1.5 times the vertex buffer. What the fixed part consists of was not
  identified.
- **Memory limit: a soft limit of 1,324 MB, not fatal here.** The kernel logged
  `Spacebar3DExtension exceeded mem limit: ActiveSoft 1324 MB (non-fatal)` as the footprint
  passed it. The extension kept running to 4,337 MB (the probe's cap) at 56 fps, and
  dropped back to 239 MB when the memory was released. No crash report was written.
- **From launch to first frame:** about 0.38 s (19 MB file) and 0.46 s (95 MB file) from
  starting `qlmanage` to the first presented frame, which includes `qlmanage`'s own
  start-up. The extension's part, from `loadView` to the first frame, was 0.08 s and 0.15 s.

Still not shown:

- **What happens above the soft limit under memory pressure.** This Mac has plenty of free
  memory; on a Mac that is short of it the system may terminate an extension that is over
  its soft limit. Whether the 1,324 MB figure is the same on Macs with less memory is
  unknown.
- **Where the fixed 175 MB goes**, and so whether it can be reduced.
- **Shaders from a Swift package**, which is how the real renderer would ship them.
- **Finder's own Space-bar path** (the runs used `qlmanage -p`), macOS 26, other hardware,
  and a real skinned model with textures.

Design input: treat about 1.3 GB as the budget for the extension. Above it, the preview
should fall back (for example to a reduced model or a message) instead of relying on the
system's tolerance.

Consequence: the framework choice for the extension stands. An indexed vertex format should
roughly halve or better the per-model memory seen here.

### S2 Assimp build and link — passed (2026-11-12)

Code: branch `spike/s2-assimp` (throwaway; it links a library built under `/tmp`, so it
builds only on the machine that ran the spike).

**Build.** Assimp v6.0.6 (commit `a79ff6bb`), CMake + Ninja, static, arm64,
`MinSizeRel`, deployment target macOS 26, `ASSIMP_NO_EXPORT=ON`, `ASSIMP_BUILD_DRACO=OFF`,
`ASSIMP_BUILD_ALL_IMPORTERS_BY_DEFAULT=OFF` with only the FBX, COLLADA, 3DS and 3MF
importers on, the system zlib instead of the bundled one. It configured and built without
changes to the source.

| | |
|---|---|
| `libassimp.a` | 4.2 MB |
| Extension binary without Assimp | 0.20 MB |
| Extension binary with Assimp linked (dead code stripped) | 1.93 MB, so about 1.7 MB added |

**Link and run.** Swift calls Assimp's C API (`assimp/cimport.h`) through a bridging
header; no C++ of our own was needed. Linker flags: the static library, `-lc++`, `-lz`.
The extension stayed sandboxed and hardened (`adhoc,runtime`), and imported files from
memory (`aiImportFileFromMemory` with a format hint) inside the real Quick Look process.

**Polygon structure survives.** With no post-processing flags nothing is triangulated:

| File | Triangles | Quads | 5+ corners | Notes |
|---|---|---|---|---|
| Tripo ship (FBX, 2.5 MB) | 18 | 43,188 | 5 | 43,211 faces: the same count 1.0.0 shows; 0.015 s |
| `animation_with_skeleton.fbx` | 0 | 1,056 | 0 | 14 bones, 1 animation |
| Hand-made FBX (10 triangles + 4 quads) | 10 | 4 | 0 | as authored |
| `COLLADA.dae` | 6,718 | 2 | 0 | |
| `ConcavePolygon.dae` | 0 | 0 | 1 | one concave n-gon kept whole |
| `CameraRollAnim.3ds` | 12 | 0 | 0 | 1 animation |
| Copper tack (3MF, 2.2 MB) | 138,690 | 0 | 0 | 69,347 vertices: the same counts 1.0.0 shows; 0.047 s |

**Licences of what this configuration compiles in** (from the files in `contrib/`):
Assimp itself BSD 3-Clause; pugixml and openddlparser MIT; poly2tri BSD 3-Clause; clipper
and utf8cpp Boost 1.0; unzip (MiniZip) under the zlib licence according to its header,
whose licence text was not read in full. Nothing copyleft was found. Each needs its notice
in the Acknowledgments window.

What it does not show:

- **Fidelity against today's loaders**: materials, textures, skinning weights and
  animation curves were counted, not compared. This is still risk 5.
- **Files with separate textures**, which an import from memory cannot resolve by itself;
  the reader has to supply them.
- **Robustness on hostile files.** Nothing was fuzzed; the containment plan in section 3
  still stands.
- **Packaging.** The spike points Xcode at a build folder. Assimp's own `module.modulemap`
  expects the generated `config.h` beside the public headers, so the headers have to be
  merged into one folder (an XCFramework would do this). A reproducible build script and
  the XCFramework are still to be written.

Consequence: the reader plan for FBX, COLLADA, 3DS and 3MF stands, and the wireframe and
statistics can keep the file's own polygons.

### S4 VRM risk core — passed, with open points (2026-11-12)

Code: branch `spike/s4-vrm`, `Spikes/S4VRM` (throwaway). A standalone SwiftPM program of
about 880 lines: its own GLB reader, GPU skinning, a minimal MToon with inverted-hull
outlines, and the VRM 1.0 spring-bone algorithm with sphere and capsule colliders, plus the
VRM 0.x material and spring conversions. It swings the whole avatar for three seconds,
holds still for three, renders frames off screen and prints measurements. Shaders are
compiled from source at run time.

Avatars (downloaded to a temporary folder, not added to the repository): Seed-san and
VRM1_Constraint_Twist_Sample (VRM 1.0, from `vrm-c/vrm-specification`, VRM Public License
1.0, redistribution allowed) and Alicia Solid (VRM 0.51, from `vrm-c/UniVRM`'s tests,
under its own rules page).

| | Seed-san (1.0) | Twist sample (1.0) | Alicia (0.x) |
|---|---|---|---|
| Load, including textures | 0.11 s | 0.12 s | 0.08 s |
| MToon materials / with outline | 10 / 7 | 13 / 7 | 12 / 8 |
| Spring joints / colliders (capsules) | 17 / 8 (7) | 57 / 13 (7) | 48 / 14 (0) |
| Cost of one simulation step | 0.003 ms | 0.011 ms | 0.008 ms |
| Largest swing, violent motion | 72° | 133° | 67° |
| Back at rest three seconds after the motion stops | yes (0.1°) | yes (9.8°, its gravity droop) | yes (1.5°) |
| NaN or runaway | none | none | none |
| Deepest collider penetration left, violent / gentle motion | 1.0 / 1.3 mm | 33.8 / 17.4 mm | 73.5 / 9.9 mm |

What this shows:

- **Spring bones are cheap and stable.** Hair, skirt and accessories trail the motion and
  settle back; a step costs about a hundredth of a millisecond.
- **MToon's core and outlines are straightforward in Metal.** Lit / shade ramp, shade and
  emissive textures, cut-out and see-through materials, and outlines all render. Side by
  side with 1.0.0's renderer, the Twist sample and Alicia look the same at rest to the eye
  (colours, shading split, outline weight).
- **VRM 0.x works through the same path** with a conversion layer for materials (Unity
  properties, sRGB colours, centimetre outline widths) and springs (bone groups walked as
  trees, an imaginary tail on leaf bones).
- A first render had the Twist sample's hair orange instead of brown: the emissive factor
  was applied without its texture. A reminder that every MToon input matters to the look.

What it does not show:

- **Agreement with three-vrm in motion.** There was no reference for the moving frames, so
  the spring behaviour was judged plausible, not matched. The collider penetration left
  after a step (up to 7 cm in violent motion on Alicia) may be inherent in the algorithm or
  a mistake in the spike; that has to be compared against three-vrm before the real
  implementation.
- **Parts of the 0.x conversion written from memory**: the shade shift / toony mapping, the
  flipped z of collider offsets, and the 180° facing. They gave a correct-looking Alicia
  but were not checked against UniVRM or three-vrm sources.
- **The rest of MToon**: rim lighting, matcap, UV animation, shading-shift and outline-width
  textures, screen-space outline widths, normal maps, GI equalisation, and the ordering of
  see-through parts by render queue beyond a simple sort.
- **The rest of VRM**: expressions (morph targets), look-at, node constraints, spring
  "centre" spaces (simulated in world space here), collider scale, first-person flags.
- Performance with several avatars or inside the extension; only one avatar was run, on an
  M4 Pro.

Consequence: the two parts judged riskiest are feasible, so VRM stays on the critical
path as planned. The spike retires the question of whether it can be done, not how much
work remains: the list above is most of T13b–d and the long tail of T13a, and matching
today's look still has to be checked by eye, avatar by avatar.

### S8 Hologram risk core — passed (2026-11-12)

Code: branch `spike/s8-hologram`, `Spikes/S8Hologram` (throwaway). A standalone SwiftPM
program of about 530 lines that renders off screen at 1600×1200 and measures the GPU time
of each frame. In one frame it draws:

- the model as a see-through mint shell (edge glow from the viewing angle, scan lines),
  built from the bottom up over 8 seconds with a bright build line;
- 180 light rays, as camera-facing ribbons, from four far points to surface points just
  under the build line;
- 700 drifting grains, positioned entirely in the vertex shader;
- two blocks of falling characters (360 cells) sampled from an 8×8 atlas drawn with
  Core Text, with bright heads and fading tails;
- after the build, a 20-second scan pass with two secondary lines and six glitches that
  shift a thin slice of the model sideways;
- glow: bright parts kept at half size, blurred, blurred again at quarter size, and added
  back, with the final picture keeping its transparency.

| Mesh | GPU time per frame, median (worst) | CPU time to encode a frame |
|---|---|---|
| 400,000 triangles | 0.86 ms (3.26 ms) | 0.04 ms |
| 2,000,000 triangles | 2.13 ms (2.94 ms) | 0.06 ms |

In the see-through output half of the pixels are fully transparent and 46% partly, so the
glow carries alpha instead of forcing an opaque background.

What this shows:

- Every Hologram ingredient has a direct Metal form, and none needs anything exotic: all
  of it is additive instanced drawing plus five full-screen passes.
- It is cheap: about 2 ms of a 16.7 ms frame for a two-million-triangle model on an M4 Pro.
- A Core Text atlas is enough for the falling characters; no font file has to be bundled.

What it does not show:

- **The look.** The frames are recognisably the effect but untuned (the rays are blown out
  where they meet the build line, and the shell is flatter than today's). Reaching a look
  the owner accepts is tuning by eye, and that is where the time goes; the spike only
  removes the technical doubt.
- **Textured and skinned models**, where today's Hologram shows the model's own colours
  faintly, and animated models.
- The effect inside the Quick Look extension together with a large model's memory, older
  or integrated GPUs, and the extra render targets' memory (five more textures at up to
  full size).
- Reduced-motion and accessibility behaviour.

Consequence: T8 is feasible as planned. Its size is dominated by tuning, not by rendering
technique.

### S5 Blender files across versions — passed (2026-11-12)

Code: branch `spike/s5-s6-readers`, `Spikes/S5Blend/main.swift` (throwaway, about 260 lines
of Swift, no dependencies). It reads the file header, the block list and the file's own
structure description (the `DNA1` block), then finds every mesh and reports its vertex
count, the size of each face and the bounding box of its vertex positions. Field offsets
always come from the file's description; only field names are written in the code.

Each file was also opened in Blender 5.2.2 without a window, and mesh names, vertex counts,
face-size counts and bounding boxes were compared.

Corpus: 22 files already on this Mac plus 22 public demo files from
`download.blender.org/demo` (kept in `/tmp`, not in the repository).

| Written by | Files | Where the mesh data sits |
|---|---|---|
| 2.80, 2.82, 2.83, 2.91, 2.93 | 9 | vertex array on the mesh, face records |
| 3.1, 3.2, 3.3, 3.4, 3.5, 3.6 LTS | 8 | same |
| 4.0, 4.2 LTS, 4.3, 4.5 | 16 | named "position" layer, face offset table |
| 5.0, 5.1, 5.2 | 11 | attribute storage, face offset table; new file header and block header |

44 files, 2,752 meshes, 18 versions: all identical to Blender after one fix (below). Reading
takes 4 to 20 ms for most files and 0.11 s for an 82 MB one.

**The bug the wider corpus found.** The first version looked up a pointer's target among
all blocks of the file. Counts matched everywhere, but bounding boxes were wrong in three
files (3.5, 5.0, 5.1): Blender writes some arrays from temporary memory, so the same old
address can appear under several data-blocks. A pointer must be resolved among the blocks
that follow its own data-block first. With that rule all three files match. This is the
kind of error that counts alone do not reveal, and the reader's tests must compare values.

What this shows:

- One reader driven by the file's own description covers three mesh layouts, both header
  formats, and every LTS release from 2.80 on. The differences between versions are a
  handful of field names and three places to look for positions, not separate parsers.
- Quads and larger faces come through as stored, so the wireframe and the statistics keep
  the file's polygons.

What it does not show:

- **Versions with no file tested:** 2.81, 2.90, 2.92, 3.0, 4.1, 4.4 and 5.3. Each sits
  between tested versions that share a layout, but that is an inference.
- **Anything beyond counts and bounding boxes.** Texture coordinates, normals, materials,
  object placement and parenting, armatures, skinning weights, animation and modifiers
  (the web renderer shows meshes as stored, without modifiers) were not read at all. These
  are the bulk of T15, and the address rule above applies to every one of them.
- **Compression inside the app.** 19 of the 44 files are Zstandard-compressed (Blender 3.0
  and later; one is split into 24 frames plus a seek table) and 8 are gzip-compressed
  (before 3.0). The spike decompressed both with command-line tools first. gzip is
  available in the system (zlib); Zstandard is not in Apple's Compression framework, so
  the app needs a decoder: the reference C library (BSD licence) or a decode-only build of
  it. That is a second bundled C dependency, to be recorded with its notice like Assimp.
- 32-bit and big-endian files (the reader rejects big-endian; neither exists in practice
  for 2.80 and later), and files that link data from other .blend files.

Consequence: the reader's foundation is sound and small, so risk 3 drops from High to
Medium. T15 gains a Zstandard decoder, gzip input, and value-level comparison against
Blender in its tests.

### S5 extension: texture coordinates, materials, object placement — passed (2026-11-12)

The same prototype (now about 460 lines) was extended and run on the same 44 files. Each
value was compared with what Blender 5.2.2 reports for the opened file. Position and
texture-coordinate arrays were compared with a checksum that changes if any value or the
order changes.

| What | Compared | Result |
|---|---|---|
| Vertex positions | 2,744 meshes | all identical |
| Texture-coordinate maps (every map of every mesh, by name) | 2,674 | 2,673 identical, 1 disagreement (below) |
| Material slots of each mesh, and the material number of every face | 2,752 meshes | all identical |
| Material base colour: the first Principled node's colour, or the plain colour when the material has no nodes; and what feeds that colour (image file path, or the kind of node) | 376 materials | 370 identical, 6 not comparable (below) |
| Object placement in the scene, computed from location, rotation (all six Euler orders, quaternion, axis and angle), scale, the delta values and the parent chain | 1,951 of 3,012 objects | all identical |

Where the data sits also differs by version, as for positions: texture coordinates are a
12-byte record per corner up to 3.6, a plain pair in a named layer in 4.x, and an entry in
attribute storage in 5.x; the face's material number is in the face record up to 3.3 and a
named layer or attribute after that. Field names on disk did not change between 2.80 and
5.2 (for example the object's scale is still stored as `size`).

Not compared, and why:

- **1,061 objects** whose placement depends on something the prototype does not read:
  physics (461), animation (272), a bone as parent (260), a scene other than the open one
  (43), constraints (25). The first four of these are what an armature and animation reader
  must handle.
- **6 materials** in old files: Blender 5.2 rewrites their node graph while opening the
  file (it inserts a mix node in front of the base colour), so its answer no longer
  describes what the file holds. Blender also gives node-less materials a node tree and
  replaces the old mix node on load; the comparison allows for both.
- **1 texture-coordinate map** (`click_tools-impact_fracture.blend`, 4.2, mesh `Cube`): the
  file holds 1,845 coordinate pairs for it; Blender shows the map as empty although the
  mesh has 1,845 corners. Unexplained. It may be Blender dropping the data rather than the
  reader inventing it, but that was not established.

A second pointer rule came out of this run. The first fix kept a fallback to any block in
the file when a pointer's target was not among its own data-block's blocks. Nothing in the
44 files needs that fallback, and it is unsafe (a stale pointer would resolve to another
object's data), so it was removed: data pointers resolve only within their own data-block,
and pointers to other data-blocks (materials, images, parents) only among data-block
headers.

What this adds to the picture:

- Static, textured, multi-object .blend scenes are within reach of a small reader: mesh
  geometry, texture coordinates, material assignment, base colour or base-colour image,
  and placement all agree with Blender across 2.80 to 5.2.
- 40 of the 376 materials have nodes but no Principled node, and for 15 the base colour
  comes from an image file. Anything else feeding the colour (mix nodes, ramps, procedural
  textures) cannot be shown faithfully without evaluating the node graph; the reader has
  to fall back to a flat colour there.

Still not read at all: normals and smooth/flat marking, vertex colours, armatures, skin
weights, animation, bone parenting, shape keys,
modifiers, images packed inside the .blend, instanced collections, data linked from other
files, and objects that are not meshes (curves, text). Armatures, skin weights and
animation are covered by the next section.

### S5 extension: armatures, skin weights and animation — passed (2026-11-12)

The prototype (now about 730 lines) was extended to rigs and run on the same 44 files,
again against Blender 5.2.2.

| What | Compared | Result |
|---|---|---|
| Rest pose: every bone's parent and rest matrix | 1,037 bones | all identical |
| Skin weights: group names and every (vertex, group, weight) entry, by checksum | 244 meshes | all identical |
| Stored pose: each bone's matrix computed from its stored location, rotation and scale, the rest pose and its parent | 980 of 1,037 bones | 978 identical, 2 differ (below) |
| Animation curves: key count, key values, handles, and the value at nine times between the first and last key | 30,396 of 30,411 curves | all identical |
| Playback: the action assigned to a rig applied at frames 3, 17 and 42, giving each bone's matrix | 2,766 of 2,868 bone poses (956 bones in 14 animated rigs; 428 of them move between those frames) | all identical |

The curve evaluation covers constant, linear and Bezier keys, including Blender's rule
that shortens a handle reaching past the neighbouring key. Curves are found in the old
place (a list on the action: 1,305 curves, in every file up to 4.3) and in the new one
(layers, strips and per-slot channel groups: 29,091 curves, in the 4.5 and 5.x files). No
4.4 file was available, so the exact version of the switch was not observed. Both forms
are read.

Not compared, and why:

- **146 bone poses and 57 stored poses** in rigs that use inverse kinematics (the whole rig
  is skipped) or where the bone or an ancestor has a constraint.
- **15 curves** that use an easing preset (9) or a curve modifier (6), and the 9 bone
  poses they drive.
- **2 stored poses** (`transform_socket-pizza_delivery.blend`, one rig): the reader's
  result equals the matrix stored in the file, and Blender reports a slightly different
  rotation after opening it, so Blender recomputed the pose on load. Not a reader error as
  far as this shows.

Limits of the corpus: armatures appear only in files from 3.4, 4.2, 4.5, 5.1 and 5.2 (the
Roblox character templates supply most of them). No file older than 3.0 has an armature,
and before 3.0 the group names sit on the object rather than the mesh; that path ran on
one mesh only. Curves were compared in 2.80 to 3.6 files too, but those animate objects,
not bones.

Still not done:

- **Deforming the mesh.** Weights and bone matrices are each right, but the skinned vertex
  positions were not computed and compared. The arithmetic is standard; the open part is
  matching groups to bones and Blender's options (preserve volume, a group limiting the
  modifier, several armature modifiers).
- Inverse kinematics and constraints. A viewer cannot show such rigs correctly from the
  file alone without implementing the solvers; the poses stored in the file are usable
  for the saved frame only.
- Drivers, the non-linear animation editor's tracks, shape keys and their animation,
  object-level animation applied to placement, objects parented to a bone, easing presets,
  curve modifiers, extrapolation beyond the keys.
- Bones that do not inherit rotation or scale in the default way (none occurred here).

Consequence: the largest unknown in T15 is smaller than feared. A plain keyframed rig
(what a game or avatar export looks like) plays back identically to Blender with under 300
lines of reader and evaluation code. What cannot be had cheaply is rigs driven by
constraints or inverse kinematics; T15 should decide up front to show those in their saved
pose with a notice, not attempt the solvers. Risk 3 stays at Medium because of that class
of file and the untested pre-3.0 rigs.

### S6 What Model I/O preserves — passed, with one fallback needed (2026-11-12)

Code: branch `spike/s5-s6-readers`, `Spikes/S6ModelIO/main.swift` (throwaway). It loads a
file with `MDLAsset` and `preserveTopology: true` and prints meshes, vertex counts, face
sizes, vertex attributes, materials, textures, skeletons and animations.

| Format | Kept | Lost or failed |
|---|---|---|
| OBJ | `.mtl` materials and their textures, quads and larger faces, vertex colours | a point-cloud OBJ (vertices only) does not load |
| STL | geometry, binary and text | nothing found |
| PLY | geometry, vertex colours, point clouds | quads are split into triangles (a 6-quad cube arrives as 12 triangles); `s, t` texture coordinates are dropped |
| USD (`.usdc`, `.usda` from Blender; a textured `.usdz`) | skeleton, joint indices and weights, the joint animation and its time range, textures, quads and larger faces, the up axis | nothing found |

What this shows:

- OBJ and USD keep more than the plan assumed, including what skinned animated USD needs.
- The two PLY losses are not regressions: 1.0.0 also triangulates PLY and shows it with a
  plain material.

What it does not show:

- **Values.** Presence was checked, not correctness: material numbers, animation curves and
  skin weights were not compared with the web renderer or with the source.
- **The sandbox.** Everything ran as a command-line tool. Whether Model I/O can load an
  OBJ's `.mtl` and textures, or a USD's external textures, inside the extension is part of
  S3.
- USD features beyond one Blender-exported skinned mesh: variants, references to other
  files, instancing, blend shapes, several animations, USD files from other tools.
- Memory and load time on large files.

Consequence: Model I/O stays the reader for all four. A vertices-only OBJ needs its own
path (a few lines of parsing, or Assimp, which S2 already links). PLY polygons and texture
coordinates are a possible later improvement through Assimp, not a release requirement.

### S3 Folder grant in the Quick Look extension — works within one login session (2026-11-12)

Code: branch `spike/s3-s7-sandbox` (throwaway probes added to the real app and extension,
built on the T1 signing and sandbox). A folder was granted to the app by opening it with
the app, which gives the same kind of access as choosing it in an open panel; the open
panel itself was not exercised. The app then stored three bookmarks of the folder in the
App Group container, and the extension tried each while previewing a `.gltf` in that
folder. Folders tried: one under `/tmp`, one in the home folder, one in Documents.

| Route, tried inside the extension | Result |
|---|---|
| Read the folder beside the previewed file directly | Denied |
| Security-scoped bookmark made by the app | Cannot be resolved (it belongs to the app) |
| Plain bookmark made by the app while it had access (no security scope) | **Works**: resolves, and the extension lists the folder and reads a texture. Same result with the app running and with the app quit, in all three locations |
| Related file with the same base name (`model.bin` beside `model.gltf`, declared as a related item) | Denied without a grant. An earlier run appeared to pass only because the plain bookmark had already opened the folder |

In the app, after a relaunch, the security-scoped bookmark restores access, so the T9
premise (a grant survives relaunching the app) holds.

Two more findings:

- **The plain bookmark holds a system access token** (a read-write sandbox token is visible
  in its bytes). Such tokens are issued for the current startup of the Mac and are expected
  to stop working after a restart. This was not tested, because it needs a restart. If it
  is so, Quick Look textures work until the Mac restarts, and again once the app has been
  opened (the app can rewrite the plain bookmarks from its lasting ones at launch).
- **The extension cannot write to the App Group container.** Reading works (settings);
  writes are denied. The extension therefore cannot cache anything there or record state.

Not shown: behaviour after a restart or logout; the open-panel path; whether App Review
accepts handing a bookmark to the extension this way (it is the documented way to give a
helper process access, but an extension is not named there); folders on external or
network volumes; what happens when the folder is moved or renamed.

Consequence: owner decision 6 ("show textures in Quick Look for granted folders if the
extension can use the grant") can be met, with the limit above. T9 gains: write plain
bookmarks into the group container when a folder is granted and at every app launch; in the
extension, look for a stored bookmark that covers the previewed file's folder. A separate
`.bin` cannot be reached any other way, so a multi-file glTF in a folder that was never
granted needs its own message in Quick Look.

### S7 Default-app offer and Finder Service in the sandbox — both work; menu not seen (2026-11-12)

Code: same branch.

**Default app.** The sandboxed app called
`NSWorkspace.setDefaultApplication(at:toOpen:)` for PLY, and in a second run for STL. Both
were opened by Xcode before.

- The call is allowed from the sandbox, and `LSHandlerRank: Alternate` does not block it.
- The system then asks the user, in its own dialog: "Do you want all documents with the
  extension “.ply” to open with “Preview3D”, or to keep using “Xcode”? The application
  “Preview3D” requested this change." The completion handler runs only after the answer.
- In the PLY run the change went through 15 seconds after the call; the dialog was
  answered on screen, not by the test. In the STL run the dialog was left unanswered and
  then dismissed with "Keep". Both types were set back to Xcode afterwards, which showed
  the same dialog in the other direction.
- The dialog is per file extension. Offering all of OBJ, STL, PLY, USD, USDA, USDC and
  USDZ means up to seven system dialogs in a row.
- The dialog names the app "Preview3D" (the bundle name), not "3D Preview".

**Finder Service.** An `NSServices` entry ("Open in 3D Preview", sending five of the
file types) and a handler in the app:

- The service is registered by the system (`pbs -dump` lists it with its file types).
- Invoked through the Services interface with a file on the pasteboard, it launched the
  sandboxed app, which received the file and read all of it (10.9 MB) without any grant.
- **Not seen:** the item in Finder's right-click menu. Reading the menu by automation
  failed, so whether it shows there, and whether directly or under Services, is unconfirmed.

Consequence: T16 is feasible as planned and needs no Quick Action extension unless the
menu item turns out not to appear. Two design points for T16 and N1: the first-launch
offer leads into several system dialogs, one per extension, so it should let the user pick
which formats to hand over, or offer only the ones they open; and the bundle name shown in
the dialog should become "3D Preview".

### Where the spikes leave the plan

All eight spikes have run; none of them invalidated the architecture. Additions to the
plan from the spikes: a Zstandard decoder for compressed Blender files; a path for
vertices-only OBJ; plain bookmarks in the group container for Quick Look textures (T9);
a message for multi-file glTF in folders that were never granted; a format picker in the
default-app offer (T16). Open checks that need a person: whether Quick Look texture access
survives a restart, and whether "Open in 3D Preview" shows in Finder's right-click menu.

## 10. Task results

### T1 App Store foundation — done except the export path (2026-11-12)

Branch `feature/t1-app-store-foundation`.

- `project.yml`: team `V3AQWQ8JMY` (read from the signing certificates in the keychain),
  automatic signing with the "Apple Development" identity, minimum macOS 26.0, arm64 only.
  The build signs without a provisioning profile and without contacting Apple.
- Both entitlements files: the two temporary exceptions are gone; the App Group
  `V3AQWQ8JMY.com.vitalis.Spacebar3D` is added; `network.client` stays for the web view.
- `ViewerSettings.fileURL` is `viewer-settings.json` in the App Group container. No
  migration from the old location.
- `scripts/build.sh` uses the project's signing by default; the Developer ID path is
  unchanged.
- Tests: 156 pass. One new test reads both entitlements files and checks that the group
  equals `ViewerSettings.appGroup` and that no temporary exception is present.

Checked on the built app (Release, from the build folder):

| Acceptance point | Result |
|---|---|
| Both targets build signed | Yes: same team on the app and the extension, `codesign --verify --deep --strict` passes |
| No temporary exception in the signed entitlements | Yes, read back with `codesign -d --entitlements` |
| App writes settings into the group container | Yes: first launch created the container and the file |
| Extension reads them | Yes: with the background colour in that file set to red, the Quick Look preview is red; restored afterwards. The edit was made in the file, not through the app's controls |
| Existing Swift tests pass | Yes |

Consequences seen while testing:

- A `.gltf` whose geometry is in a separate `.bin` now shows "Failed to load" in Quick Look
  and in the app, because the file beside it cannot be read. The decision "Quick Look shows
  the model untextured" does not cover this case: without the `.bin` there is no geometry
  to show. In the app T9 restores it; in Quick Look it depends on spike S3, and otherwise
  needs a message that says why.
- Testing note: the web view does not draw while its window is covered. A Quick Look
  screenshot taken while the app's window is in front shows an empty preview. Tests of
  the extension must keep the app closed or in the background.

Not done: the App Store export path (archive, distribution certificate and profiles,
upload). `get-task-allow` is still injected in local builds, as before. The release
workflow still produces a Developer ID build.

### T2 Package skeleton and seam — done (2026-11-12)

Branch `feature/t2-package-seam`.

- `Packages/Spacebar3DKit` with `ModelCore` (`Format`, `FormatDetector`, `SourceTopology`,
  `topologyLabel`) and `ViewerUI` (`Viewer`, `Renderer`, `RendererRoute` with an empty
  `nativeFormats` and the debug-only `P3DForceRenderer` override). Both targets and the
  test target depend on it.
- `WebViewerController` (in `Spacebar3D/Shared`, not in the package, so it can be deleted
  with the web renderer) holds what used to be two copies of the WKWebView code.
  `ViewerFactory` detects the format, asks `RendererRoute`, and returns a `Viewer`; the
  app window and the Quick Look controller only hold that. A forced `native` falls back
  to the web viewer until T3 adds the first native one.
- Tests: 83 cases of `renderer/test/format.test.ts` and the `topologyLabel` cases ported to
  Swift, plus Swift-only cases (sliced and short `Data`), 97 in `ModelCoreTests`; 3 in
  `ViewerUITests`. All pass, as do the 156 existing ones; the `Spacebar3DTests` scheme
  runs the package tests too.

Checked by eye on the built app, web renderer behind the new seam:

| Host | Formats seen rendering |
|---|---|
| Quick Look | VRM, GLB, glTF (embedded), FBX with animation bar, 3MF, COLLADA, 3DS, Blender |
| App window | OBJ, STL, PLY, VRM |

Not checked: VRMA and USDZ (no sample at hand), the reset of the controls when Quick Look
shows a kept preview again, keyboard focus in the app window, and a side-by-side
comparison with the build before this change.

Found on the way, not caused by this task: the web renderer fails on a skinned `.usdc`
exported by Blender ("Failed to load", also outside both hosts), and shows nothing for
the `.usda` form of the same model.

Not done from the plan's wording: `Format` has no separate VRM and VRMA cases yet; they
are needed when glTF moves, and the split needs the glTF JSON.

### T3 Renderer core and native STL — built, partly verified (2026-11-12)

Branch `feature/t3-renderer-core`. STL is not in `nativeFormats`; the native viewer is
reached only with the debug override.

- `ModelCore.ModelScene` (nodes, meshes, parts with `faceSizes`, materials, textures,
  topology, diagnostics; skins, clips and VRM are added with the formats that have them).
- `ImportModelIO` and `ImportRouter`: STL through Model I/O, turned from Z-up to Y-up as
  the web renderer does.
- `RenderMetal`: orbit, pan, zoom and fit camera; grid; light intensity; Solid, Textured
  (with the metallic and roughness overrides) and Normal views; flat and smooth; the
  polygon wire as line geometry, each edge once.
- `ViewerUI.NativeViewer`: Metal view with the views bar, wireframe toggle, view settings,
  fit / light / grid / auto-rotate buttons, gizmo, statistics, and load errors as text.
  `NativeViewerSettings` carries the user's settings; a default look that is a style not
  built yet falls back to the Textured view. `ViewerFactory` returns it for `.native`.

Seen working: package and scheme tests pass (offscreen renders of every view included);
in the app window, two STL files draw with controls and statistics, and one of them
matches the web renderer side by side, including a file whose normals are all zero and
therefore shows as a flat silhouette in both. In Quick Look the native viewer comes up
with its controls and grid.

Measured by the test suite, offscreen, release build, 2,000,000-triangle STL: import
0.09 s, upload 0.15 s, 9.6 ms per frame (15 ms with wire), wire build 0.25 s, about
1.2 GB in the test process with the wire built. A debug build takes about 15 s to upload.

Checked afterwards, in a debug build:

- **Quick Look draws models natively.** A 400,000-triangle STL and a 2,000,000-triangle
  STL (100 MB), given another extension so that our extension receives them, both draw.
  The extension's memory footprint was 131 MB (peak 278 MB) and 258 MB (peak 571 MB),
  wireframe off, against a soft limit of about 1.3 GB.
- **Input in the app window**, driven by synthetic mouse events and compared by
  screenshot: drag orbits (the gizmo follows), scroll zooms, the Solid / Normal buttons,
  wireframe toggle, grid button, fit, a gizmo axis click and the view-settings popover
  all act; auto-rotate changes the picture between two shots and, switched off, two
  shots a second apart are identical.

Still not verified: pan, pinch and right-drag; the light slider; the metallic and
roughness overrides in a window; memory with the wireframe built in the extension; the
reset when Quick Look shows a kept preview again; anything on a trackpad by hand.

Known differences from the web viewer: the controls are standard macOS controls, not the
web bar's icons; no keyboard shortcuts; smooth and flat look the same for STL (as on the
web); pan and zoom gestures were chosen by the implementer, not copied.

Settled: Model I/O picks its reader from the file extension, while our detection goes by
content. An STL with another extension is now read through a temporary link that carries
`.stl` (tested).

### T4 Styles, and STL moved to the native renderer — built (2026-11-12)

Branch `feature/t4-styles`.

Owner decision for this step: native formats have **no Hologram** until the native effect
(T8) exists. The native bar has no Hologram button, and a Hologram default look falls
back to the Textured view (Solid for a model with no colours). This replaces the earlier
plan of handing such windows to the web renderer, and is a known regression against
1.0.0 for STL until T8.

- `RenderMetal`: `RenderLook.style` with Unlit, Cartoon (three tones, raised saturation)
  and Sketch (paper, fringe, hatching), using the constants of `looks.ts`; one shared
  outline pass (back-face hull, one extra draw per part). The hull moves all corners at
  one position together, so it stays closed on meshes that repeat their corners (STL).
- `ModelCore`: `ModelScene.hasTexturedAppearance`, the web renderer's rule: a model with
  no texture, no vertex colours and one unsaturated colour has no Textured view and its
  Unlit and Cartoon buttons are disabled.
- `ViewerUI`: the three style buttons with the web bar's interaction rules; the outline
  is prepared when a look needs it; default looks unlit, cartoon and sketch map to their
  styles.
- STL gets the web renderer's plain material, and `RendererRoute.nativeFormats = [.stl]`.

Seen working: all five test bundles pass. In a release build an STL opens in the native
viewer by default, in the Solid view, with no Textured button and Unlit and Cartoon
disabled, as the web renderer shows it; clicking Sketch gives a picture that matches the
web renderer's side by side. In Quick Look a 2,000,000-triangle STL draws natively by
default (footprint 264 MB, peak 522 MB).

Not verified: Unlit and Cartoon on a model that has colours (no native format has them
yet; only offscreen tests on a generated mesh); the outline's cost and memory on a large
model; the outline width against the web's on a high-density display; Hologram as the
default look in a real window.

Outline and wireframe cost, measured afterwards on the 2,000,000-triangle STL:

| Where | Result |
|---|---|
| Frame time, release build, offscreen 1600×1200 | Sketch 7.6 ms, Cartoon 7.5 ms, Unlit 6.2 ms (Solid 8.6 ms, Textured with wire 14.1 ms) |
| Outline build, release | 0.07 s; adds 69 MB (the outline normals) in the test process |
| Quick Look extension (debug build): Solid | 263 MB |
| … after choosing Sketch | 637 MB, peak 822 MB |
| … then Solid with wireframe | 694 MB, peak 891 MB |
| App (release build): Solid | 724 MB |
| … after Sketch, then wireframe | 1,270 MB and 1,241 MB, peak 1,352 MB |
| … the same window 20 s later, idle | 681 MB |

Speed is not a concern. The steady cost of the outline is its data, 69 MB. The rest of
the rise is working memory that the system keeps charged to the process for some seconds
after the build has freed it (it shows as owned but unmapped memory, 372 MB in the app)
and then drops. The outline and wire builds were changed to read positions in place
instead of copying them, which lowered the extension's Sketch peak from 938 MB to 822 MB.

Looked into further (this replaces the first reading above, which blamed the outline):

- **STL is now read by our own reader** (`ImportSTL`, memory-mapped, straight into the
  scene's arrays; a zero normal in the file is replaced by the face's own). Import of
  the 2,000,000-triangle file went from 0.107 s to 0.020 s, and the load peak in the
  extension from 571 MB to 483 MB. Model I/O held the whole file plus its own buffers
  while we copied out of them.
- **The rise is not the outline.** Measured step by step, the outline adds its 69 MB
  and nothing else. The same rise of about 300 MB appears whenever drawing resumes after
  the view has been idle (a small orbit is enough) and goes away after some seconds
  without drawing:

  | Quick Look extension, debug build, 2,000,000 triangles | Footprint |
  |---|---|
  | Loaded, idle | 261 MB |
  | After a small orbit | 574 MB |
  | 20 s idle | 267 MB |
  | Sketch chosen | 633 MB (peak 818 MB) |
  | 20 s idle | 336 MB |

  It shows as about 300 MB of "owned but unmapped" memory in some 2,700 regions, close to
  twice the size of the model's GPU buffers (168 MB). The reading that fits is that the
  graphics system charges the buffers a frame uses to the process while it is drawing
  and lets go when it stops. That is an inference from the numbers; it was not confirmed.
- **Freed import memory is also returned late** by the system allocator (it shows as
  "Malloc Large (empty)", 206 MB in the app after load with our reader, 412 MB with
  Model I/O) and still counts while it waits. Asking the allocator to release it at once
  had no effect.
- An autorelease pool was added around the Model I/O import (still used for nothing yet,
  kept for PLY, OBJ and USD), since imports run on threads that have none.

Where this leaves the limit: while a 2,000,000-triangle STL is being drawn the extension
sits at about 570 to 630 MB and peaked at 818 MB, against a soft limit of about 1.3 GB.
By proportion a model of about 4,000,000 triangles would reach it.

GPU-private buffers, tried and dropped: drawing from private copies of the vertex and
index buffers left the rise exactly as it was (307 MB after a small orbit) and added the
copies' 168 MB at rest, so it was reverted. The rise follows the amount of geometry
drawn, not how the buffers are stored: 92 MB for 400,000 triangles and 307 MB for
2,000,000, roughly 40 MB plus 135 bytes per triangle. That fits the GPU keeping the
frame's transformed geometry while it draws (an inference; not confirmed).

**Sharing vertices (done).** An STL arrives with three separate corners per triangle,
6,000,000 vertices for this model where 1,000,000 positions exist. A part whose triangles
each carry one normal on all three corners, and that has no texture coordinates or vertex
colours, is now merged to its distinct positions at upload and drawn indexed; its flat look
comes from the surface itself in the fragment stage, which is the path the Flat setting
already used. A test shows the merged cube renders byte for byte like the unmerged one
shaded flat. The Smooth setting has no visible effect on such a file, as before.

Measured on the same 2,000,000-triangle STL:

| | Before | After |
|---|---|---|
| Geometry on the GPU | 183 MB | 45 MB (68 MB with wireframe) |
| Extension, loaded and idle | 261 MB | 146 MB |
| Extension, while drawing | about 574 MB | about 310 MB |
| Extension, Sketch | 818 MB peak | about 313 MB |
| Extension, highest at any time | 818 MB | 498 MB, during loading |
| Solid frame, 1600 x 1200 offscreen | | 6.3 ms |

The amount that appears while drawing and goes away when drawing stops is still there,
at about 160 MB instead of about 310 MB; on the 400,000-triangle file it is about 45 MB.
Parts with texture coordinates, vertex colours or smooth normals are uploaded as before.

**Merging in the STL reader (done).** With the upload merging corners, the highest point
was the load: the reader still built all 6,000,000 corners with a normal each (about
216 MB) only for the upload to merge them. The reader now merges corners as it reads them
and marks the part `faceted`, so the unmerged mesh never exists; the scene it returns for
this file is about 40 MB. The normals written in the file are no longer kept, since the
flat look comes from the surface. Import of the file takes 0.07 s.

| Extension, 2,000,000-triangle STL | Merge at upload | Merge in the reader |
|---|---|---|
| Highest while loading and showing the first frames | 498 MB | 276 MB |
| Loaded and idle | 146 MB | 147 MB |
| While drawing | about 310 MB | about 310 MB |
| Highest at any time (orbit, then Sketch) | 498 MB | 424 MB |

The highest point is now reached while drawing, not while loading.

**The memory that comes and goes with drawing: explained, and halved.** It is the GPU's
own store of a frame's transformed triangles. Apple GPUs sort every visible triangle into
screen tiles before shading, and keep what the vertex stage produced for each of them until
the frame is done; the memory is owned by the process but not mapped into it, which is how
`footprint` reports it. Measured with the 2,000,000-triangle model in a test process,
against the same frames with no model (figures are the model's share):

| Variation | Model's share |
|---|---|
| As it was | 154 MB |
| Model outside the view | 2 MB |
| Back faces culled | 71 MB |
| 64 x 64 target instead of 1600 x 1200 | about 108 MB |
| Vertex stage hands on only a position | 75 MB |

So it follows the number of triangles on screen and the size of what each vertex hands
on, not the size of the view, and it is not ours to free. Allowing only one frame in
flight did not change the highest point and was not kept.

What changed: the vertex stage no longer hands on a world position (12 bytes); the
fragment stage works out where the surface is from the fragment's own position, which
carries the distance in front of the camera. Flat-shaded parts use a pipeline whose
vertices hand on nothing but the position, since their normal comes from the surface;
smooth parts still hand on their normal. Screenshots of Solid and Sketch in Quick Look
are unchanged. Culling back faces would halve it again but is wrong for files with
inconsistent winding, so it is not done.

| Extension, 2,000,000-triangle STL | Before | After |
|---|---|---|
| While drawing | about 310 MB | about 220 MB |
| Sketch | about 314 MB | about 226 MB |
| Highest at any time | 424 MB | 336 MB |
| Loaded and idle | 147 MB | 146 MB |

On the 400,000-triangle file the amount is about 20 MB (was 45 MB). Materials with
textures will add texture coordinates to what a vertex hands on (8 bytes) when they arrive.

**Back faces left out where that is certain to be invisible (done).** At upload a merged
part is checked (`ClosedSurface`): every edge must belong to exactly two triangles running
along it in opposite directions, and every separate piece must enclose a positive volume.
Such a part is closed with its faces turned outward, so from outside no back face can be
seen, and they are culled. They are drawn after all whenever the camera is in or within
reach of the part's box, where the near plane could cut the surface open. A mirrored
placement culls the other side. Tests compare frames with and without culling, byte for
byte, from outside, from inside, at the surface and mirrored. Anything that fails the check
(a hole, a face turned the other way, an inward-facing piece such as an inner cavity, a
seam whose two sides differ by rounding) is drawn with both sides as before. The check
takes about 0.06 s for 2,000,000 triangles and about 30 MB while it runs. Only merged,
flat-shaded parts are checked so far, which is every STL.

| Extension, while drawing | Before | After |
|---|---|---|
| 400,000-triangle STL, closed | 136 MB | 128 MB |
| 2,000,000-triangle STL, closed | about 220 MB | 189 MB (highest at any time 308 MB) |
| 2,000,000-triangle STL with a seam (the file used above) | about 220 MB | unchanged |

The file used for the earlier measurements has a seam where its two ends meet (1,002,501
positions for a torus that needs 1,000,000), so it is not closed and gains nothing; a
torus without the seam was generated for this measurement. Sketch draws the back faces of
the outline hull in any case, so its saving is the same amount, not a half.

An example of a model that rightly keeps both sides: an STL exported by an AI model
generator (53,920 triangles, 28,522 positions). Of its 82,502 edges, 3,656 belong to one
triangle only (open borders), 364 to three or more, and 155 to two triangles running the
same way (one of them is flipped); 10 triangles are stored twice. It is 166 separate
pieces, none of them closed. No two positions lie within a ten-thousandth of the model's
size of each other, so merging near-equal positions would not change this. Culling its
back faces would show holes where the flipped faces are. Checked on screen: this file in
Solid, wireframe, Sketch and Normal and with the camera inside it, and a generated closed
sphere with the camera inside, where the inner surface is drawn in full.

### T5 PLY and OBJ moved to the native renderer — built (2026-11-12)

**Readers.** Both formats are read by our own readers (`ImportPLY`, `ImportOBJ`), memory-
mapped like the STL one, not by Model I/O as section 9 planned. Reasons: Model I/O splits
PLY polygons into triangles, does not load an OBJ with positions only, picks its reader by
file extension, and held a large STL several times over. `ImportModelIO` stays for USD.

- PLY: text and binary of either byte order; positions, normals, vertex colours (bytes,
  16-bit or floats), faces kept as polygons, other properties and elements passed over. No
  faces: a point cloud. Counts in the header are checked against the size of the file
  before anything is allocated.
- OBJ: positions, colours written after a position, normals, faces as polygons, indices
  counted from the end, `s off`. Positions without faces: a point cloud. No `.mtl`, as in
  the web viewer (the file is beside the model, out of reach); texture coordinates, lines
  and curves are passed over. Polygons are split as a fan, so a concave polygon is filled
  wrongly, as in the web viewer.
- Run over Assimp's 34 PLY and OBJ test files: 31 load; two deliberately malformed PLY
  files and a UTF-16 OBJ are refused with a message, none crashes.

**Model I/O measured against our readers** on generated files of 2,000,000 triangles
(PLY: binary with colours, 41 MB; OBJ: text, 1,000,000 quads with normals, 120 MB), each
in a fresh process, reading into plain arrays:

| | Model I/O | Ours |
|---|---|---|
| PLY, time | 0.40 s | 0.08 s |
| PLY, highest footprint | 147 MB | 117 MB |
| OBJ, time | 3.26 s | 0.42 s |
| OBJ, highest footprint | 416 MB | 176 MB |
| PLY cube of 6 quads | 12 triangles | 6 quads |
| OBJ with positions only | refused ("OBJ file has no faces") | point cloud |
| OBJ quads, normals, vertex colours; PLY colours | kept | kept |
| OBJ `.mtl` materials | read (spike 6) | not read |

So the memory argument, measured before only on STL, holds for OBJ and is small for PLY;
the PLY case rests on keeping polygons, the OBJ case on speed, memory and point clouds.
Of our 117 MB for the PLY, 16 MB is the per-face corner list kept for the statistics,
which an all-triangle file does not need.

**Renderer.** Vertex colours (4 bytes per vertex, shown in Textured and its styles, through
separate pipelines so models without colours hand on nothing more per vertex). Point
clouds as dots 2 points wide in their own colour, unlit, in every view. A part without
normals and with more than 300,000 triangles keeps its shared vertices and gets one
averaged normal per vertex; smaller ones get crease-aware normals per corner as before.
Every indexed part is checked for being closed, not only flat-shaded ones.

**Checked on screen in Quick Look** (files renamed so that our extension gets them): PLY
with normals, with quads, with float colours, a 70,051-point coloured cloud; OBJ with and
without normals, with vertex colours, with quads; Unlit, Cartoon and the wireframe on
coloured models; the wireframe of a quad cube shows no diagonals. Side by side with the web
renderer for four of them: same framing, same colours, same point cloud. Differences, both
intended: a cube without normals keeps sharp edges (the web viewer rounds PLY and facets
OBJ), and PLY statistics count the file's polygons (the web viewer counts triangles).

A generated 2,000,000-triangle PLY with colours (41 MB) in the extension: 154 MB loaded,
about 219 MB while drawing, 336 MB at most.

**Not done:** an OBJ that has only lines is shown as dots, not lines. Not checked: the app
window (same viewer), files in the hundreds of megabytes, text PLY or OBJ speed at that size.

### T6, first part: USD moved to the native renderer, without animation — built (2026-11-12)

The web viewer shows USD without animation, so a static native USD is no step back; the
animation bar and skinned playback are the second part of T6 and not built.

**Reader.** Model I/O (`ImportModelIO/USDScene.swift`), as planned: the object tree with
placements, the up axis, meshes with their polygons, normals, texture coordinates and
colours, one part per sub-mesh; per material the colour or colour image, metallic and
roughness as numbers or images (packed into one image, roughness in green, metallic in
blue), and the normal map. Model I/O lists its own default for every material property
beside the file's (a "baseColor" of 0.18 next to the file's "diffuseColor"); the file's is
taken. An image the file names but Model I/O could not load is recorded as missing and the
part is drawn neutral grey. The USD form (package, binary, text) is told from the first
bytes, for files with another extension. Skeletons and animation are not read: a rigged
model shows in its rest pose. Emissive images and opacity are not read.

**Renderer.** Texture coordinates (8 bytes per vertex, own pipelines), colour images
with mipmaps (sides above 4096 scaled down), metallic-roughness and normal maps (2048 at
most). Normal maps are applied without stored tangents, from how position and texture
coordinate change across the screen. A value set in the view settings replaces the map.
Changed for every format: the surroundings are mirrored only where the view settings set
metallic or roughness, as in the web viewer; before, a file's own metal was washed out by
a bright reflection the web viewer does not have.

**Checked on screen in Quick Look against the web renderer:** a 32 MB textured `.usdz`
(160,668 triangles, 4096 and 2048 pixel images) matches closely, including highlights and
surface grain; a `.usdz` with a plain colour matches; a skinned `.usdc` from Blender that
the web renderer fails to load, and its `.usda` form that the web renderer shows empty,
both show in their rest pose.

**Memory, textured `.usdz` in the extension:** 246 MB loaded, about 290 MB while drawing,
558 MB at most, during loading (Model I/O's decoded images, our copies of them and the GPU
textures exist together for a moment).

**Texture memory reduced.** Two changes. Images are no longer loaded through Model I/O:
the importer takes each image as the compressed bytes the file holds (out of the `.usdz`
package, which is a zip of stored entries, or from a file path where it can be read) and
it is decoded once, when it goes to the GPU, at no more than the size wanted there (a
JPEG is decoded at a reduced size directly). A cap of 2048 pixels for colour images in the
Quick Look extension was tried and measured (last column) and then withdrawn by the owner:
colour images are held at 4096 at most in both the app and Quick Look; normal and
metallic-roughness maps at 2048 in both. `NativeViewer.maxTextureSide` remains as the switch. Data images are read in their own colour space so their numbers are not
converted.

| Textured `.usdz` in the extension | Before | Own decoding (kept) | With 2048 in Quick Look (withdrawn) |
|---|---|---|---|
| Loaded | 246 MB | 245 MB | 181 MB |
| Highest, during loading | 558 MB | 464 MB | 353 MB |

At the size Quick Look shows it by default the 2048 preview was pixel for pixel the same.

**Not checked:** USD files from tools other than Blender and the two downloaded ones;
references to other files, variants, instancing; images with 16 bits per channel (skipped);
the app window.

### T6, second part: skeletons, animation and the animation bar — built (2026-11-12)

**Scene.** `ModelScene` gains skeletons (joints with parent, rest placement and inverse
bind), a skin per mesh part (up to four joints and weights per vertex, and the transform
that takes the part into the skeleton's bind space), and clips: translations, rotations and
scales over time for every joint of one skeleton. `Skeleton.skinMatrices(clip:time:)` is the
one place a pose is worked out; what a clip does not animate stays at rest.

**USD.** Skeletons, each mesh's binding (joint indices and weights in whatever width the
file uses, up to four per vertex; a mesh's own joint list is mapped onto the skeleton's) and
the skeleton's joint animation are read through Model I/O. A hand-written skinned `.usda`
in the tests goes from file to posed vertices.

**Skinning is done on the CPU**, not in the vertex stage: posed positions and normals are
written into one of three vertex buffers in turn (so a frame still being drawn keeps its
own), and every pipeline, the wireframe and the outline work on them unchanged. The wire and
the outline are built from the bound shape; the outline's normals are turned with the
joints. A skinned part is placed by its skeleton's node, the box for framing is taken
around the posed parts, and skinned parts are not checked for being closed. This is enough
for previews; skinning in the vertex stage is the step to take if large rigged models turn
out slow, and it was not measured on one.

**Viewer.** The animation bar sits above the bottom bar when the model has clips: play or
pause, the clip when there are several, and a scrubber; dragging the scrubber pauses at the
chosen moment, the space bar toggles playback (in the app; Quick Look keeps the space bar
for itself). The `autoplay` and `showAnimationBar` settings are honoured. Drawing is
continuous only while something plays.

**Checked on screen in Quick Look:** the skinned Blender `.usdc` and `.usda` (which the web
renderer cannot show) play; clicking the scrubber pauses and the frame holds; Sketch with
its outline follows the pose.

**Processor use while playing** (this 3,360-vertex model, extension, share of one core):

| | While playing |
|---|---|
| Debug build, as first measured | 24 to 29% |
| Release build | 17 to 18% |
| Release build, scrubber moved 30 times a second | about 7% |

Paused: 0.3%. The first figure was taken from a Debug build: the extension registered
with the system was the Debug one, as it has been for every Quick Look measurement in
this document (the previews' titles say "[DEBUG]"). Memory figures do not depend much on
that; time and processor figures do, and from here on they are taken from a Release build
(`pluginkit -r` the Debug extension, `pluginkit -a` the Release one). In the Release
build the pose and the drawing were a few samples in thousands; what cost was SwiftUI
laying out the controls again for every frame because the scrubber's position changed
every frame. It is now updated 30 times a second. Frames are still drawn at the display's
rate, 120 a second on this Mac; drawing at 60 would roughly halve what remains and was not
done.

**Not checked:** a file with several clips (the picker), several skeletons, more than
four joints per vertex (refused, shown at rest), the space bar in the app, large rigged
models, blend shapes (not read).

### Memory re-measured with the Release extension (2026-11-12)

The same files, the same code (`edb0f0e`), one run each, Quick Look extension:

| File | | Release | Debug |
|---|---|---|---|
| STL, 2,000,000 triangles, with a seam | loaded | 145 MB | 147 MB |
| | while drawing | 220 MB | 220 MB |
| | Sketch | 226 MB | 230 MB |
| | highest | 336 MB | 337 MB |
| STL, 2,000,000 triangles, closed | loaded | 145 MB | 147 MB |
| | while drawing | 186 MB | 188 MB |
| | highest | 320 MB | 304 MB |
| PLY, 2,000,000 triangles, coloured | loaded | 149 MB | 155 MB |
| | while drawing | 218 MB | 220 MB |
| | highest | 351 MB | 321 MB |
| STL, 400,000 triangles | loaded | 109 MB | 110 MB |
| | while drawing | 120 MB | 128 MB |
| Textured `.usdz`, 32 MB | loaded | 245 MB | 245 MB |
| | highest | 502 MB | 465 MB |

The figures a model settles at agree within a few megabytes, so the ones recorded above
from Debug builds stand. The highest point is 16 to 37 MB higher in Release for three of
the files and reached earlier, already while loading: the faster build has the first
frames under way while memory freed by the import has not been returned yet. With one run
each, part of that difference may be chance.

### The loading peak of textured models, looked into (2026-11-12)

Measured step by step in a test process on the 32 MB textured `.usdz`, then in the
extension. What one 4096 pixel colour image cost on its way to the GPU:

| Step | Held |
|---|---|
| Our buffer for the decoded pixels | 64 MB |
| The decoder's own copy while it draws into ours | 64 MB more, for a moment |
| The texture with its smaller versions | 85 MB, kept |
| Asking the GPU to make the smaller versions | about 70 MB more, for a second or so |

The last line was the surprise: `generateMipmaps` left about 70 MB behind after each
image, whatever the queue, storage mode or usage, and none without it. Changes:

- The smaller versions are made on the CPU (two by two averages, colours averaged as
  light) and uploaded level by level. Textures no longer need to be render targets.
- Decoded pixels live in memory taken from the system directly and given back at once,
  not in arrays, whose freed blocks linger. On its own this changed little.
- The decoder reads the compressed bytes in place and is told not to cache what it
  decodes; uploads have an autorelease pool, which their threads lacked.

| Textured `.usdz`, extension, highest | Release | Debug |
|---|---|---|
| Before | 502 MB | 465 MB |
| With system memory for pixels and no decoder cache | 465 MB | 465 MB |
| With the smaller versions made on the CPU | 416 MB | 385 MB |

Loaded it is 245 MB as before, and the preview is pixel for pixel the same. What is left
above that while loading is mostly the two 64 MB copies during the decode of the largest
image, the compressed images (25 MB) and Model I/O's asset; not reduced further.

### T7 Assimp in the build; 3MF and 3D Studio read natively, neither routed yet (2026-11-12)

**Build.** `scripts/build-assimp.sh` builds the pinned Assimp (v6.0.6, commit `a79ff6bb`,
checked by the script) with the spike's configuration into
`Packages/Spacebar3DKit/Vendor/Assimp.xcframework`: the static library, the public headers
merged with the generated `config.h`, and a module map that exposes the C interface to
Swift and links `c++` and `z`. The framework is not kept in git (5.4 MB of binary); it is
built once after cloning, `build.sh` and the release workflow run the script (the workflow
change is untested). It was built here from the checkout the spike had fetched.

**Reader.** `ImportAssimp` calls the C interface only: the file is passed from memory,
vertices identical in every respect are merged, nothing is triangulated. It brings the
node tree with placements, polygons, normals (dropped when Assimp marks them unknown),
texture coordinates, colours, each material's colour, metallic, roughness and colour
image (embedded, or beside the file where that can be read, by file name only). All 15
sample files load (9 of 3D Studio, 6 of 3MF, among them one deliberately malformed).

**Compared on screen with the web renderer, six files:**

| | Result |
|---|---|
| 3MF, single object (two files, 53,886 and 138,690 triangles) | same |
| 3MF with several objects in separate model files (`cube_gears`) | differs: the parts lie side by side, 25,692 triangles, where the web renderer shows a stacked shape of 31,688. First recorded here as an Assimp fault; **that was mistaken**, see the 3MF entry below |
| 3D Studio, shape and placement (three files) | same, once the extra turn to Y up was removed (Assimp already turns 3D Studio scenes) |
| 3D Studio with transparent materials (`cubes_with_alpha`) | **differs**: drawn opaque; the web renderer shows them see-through |

So neither format was put in `nativeFormats` at this point. 3D Studio needed transparency
in the renderer, which every later format needs too.

### Transparency, and 3D Studio moved to the native renderer (2026-11-12)

**Renderer.** A material has an opacity. Parts whose opacity is below one are drawn after
everything opaque, farthest first (by the middle of each part), blended over what is there,
writing depth as the web renderer's do. The colour image's alpha counts as well. Seen
through, a surface's far side shows, so such parts are not culled as closed surfaces; only
a one-sided material loses its back faces. Transparency exists where the model's own
colours show (Textured, Unlit, Cartoon); Solid, Normal and Sketch stay opaque, as in the
web renderer. Every surface pipeline now exists twice, opaque and blended. Opacity is read
from 3D Studio and 3MF materials (Assimp) and from USD.

Not done: sorting within one part (a see-through part that overlaps itself can blend in
the wrong order), and cut-out alpha (drawn or not drawn by a threshold), which glTF needs.

**3D Studio is in `nativeFormats`.** Against the web renderer on `cubes_with_alpha.3DS`,
shape and placement are the same and two things differ, both checked against the file:

- The file gives its see-through material a transparency of 17 percent (read from the
  chunk directly), which is the opacity of 0.83 drawn here. The web renderer shows it far
  more see-through than that.
- The web renderer's colours are lighter. The file stores display colours as bytes; here
  they are taken as such, the web loader appears to take them as linear light.

3MF stayed on the web renderer at this point; see the next entry.

The Release extension binary is 3.2 MB with Assimp linked.

### T7 3MF: own reader, native; the earlier Assimp finding corrected (2026-11-12)

**Correction.** The entry above first said Assimp read `cube_gears_prod_req.3mf` wrongly.
Checked against the file itself, Assimp was right and the web renderer is wrong:

- The package holds 17 model files with 25,692 triangles in all. The build lists the 17
  objects with no placement, and the vertices put the parts side by side on the print
  bed (x 38 to 206 mm, all resting at z 17).
- The web renderer's 31,688 triangles are 17 times 1,864, the size of the last gear: its
  loader resolves every build item to the same object, because each model file numbers
  its object 1, and draws that one gear 17 times in one place.

The own reader was started on the mistaken finding. It was kept for what it measured:

| | Own reader | Assimp |
|---|---|---|
| Copper tack, 138,690 triangles, read time | 0.042 s | 0.146 s |
| 3MF parsing | Swift, bounds-checked | C++ |

**Reader.** `ImportThreeMF`: a zip reader (stored and deflate, zip64), a tag scanner over
the XML bytes, and the model: objects with vertices and triangles, components and build
items with their placements, objects in other model files of the package (production
extension), colours from base materials and colour groups (one colour for a whole object
becomes its material; several become vertex colours). Limits: nesting 16 deep, 100,000
placed objects, 50 million triangles, 1 GiB per unpacked file. Triangles that point
outside the vertices are dropped. Not read: texture groups, composite and multi
materials, beam lattices, slices.

Results: all six sample files load; `cube_gears` 17 parts, all closed; the 53,886-triangle
file in 0.015 s. 3MF is now in `nativeFormats`.

**Both readers compared on the 3MF Consortium's sample files (2026-11-12).** Eleven files
from `3MFConsortium/3mf-samples`, read by both and drawn by the same renderer:

| | Own reader | Assimp |
|---|---|---|
| Shape, counts (all eleven) | same | same |
| One colour per triangle (`rhombicuboctahedron_color`, `dodeca_chain_loop_color`) | each face in its own colour, as the file says | colours smeared across faces and darkened: one colour is kept per shared vertex, and some vertices get none |
| Colours per vertex (`pyramid_vertexcolor`) | as the file says | same colours, darker (multiplied by Assimp's grey default material; that part is ours to fix) |
| Images (`sphere_logo`, `multipletextures`) | **not read**, drawn white | read and drawn; one seam fault on the sphere |
| Combined properties (`multiprop-*`) | **not read**, drawn white | first layer's colour or image |
| Read time, Release, largest file (96,692 triangles) | 0.041 s | 0.047 s |

The times are level on these files; the threefold difference above was measured on one
file (the tack) and is not general.

**Images added to the own reader; 3MF taken out of Assimp (2026-11-12, owner decision).**
The reader now takes images (`texture2d`), their coordinates (`texture2dgroup`) and
properties laid over each other (`multiproperties`). Triangles with an image form a part
of their own per image. A colour with images over it, all lying the same way, is painted
into one image when the file is read (at most 2048 on a side); any other layering keeps
the first image and multiplies the colours.

Checked against the consortium's files:

| | Own reader now | Assimp |
|---|---|---|
| `sphere_logo` | logo in place, no seam fault | seam fault |
| `multipletextures` (two images) | star field on 94,042 triangles, world map on 2,650, as the file assigns them | the world map on everything |
| `multiprop-*` (colour, star, smiley) | as the thumbnail stored in each file | one colour or one image |
| Read time, `multipletextures`, Release | 0.081 s (0.041 s before images were read) | 0.047 s |

Not read: the display properties of the materials extension (metallic, translucent),
tile styles, composite materials, beam lattices, slices. An image whose corners name
different images within one triangle is drawn plain.

Assimp is now built with the 3D Studio, FBX and COLLADA importers only (library 4.24 MB,
was 4.43 MB) and `ImportAssimp` reads 3D Studio alone; its tests use a 3D Studio box
written by the test.

**Reading 3MF with images made faster (2026-11-12).** Best of seven reads, Release:

| File | Before | After |
|---|---|---|
| `multipletextures`, 96,692 triangles with image coordinates | 0.076 s | 0.034 s |
| `dodeca_chain_loop_color`, 7,680 triangles, colour per triangle | 0.0040 s | 0.0022 s |
| Tack, 138,690 triangles, no properties | 0.0375 s | 0.0364 s |
| `heartgears`, tripo, `cube_gears` (no properties) | unchanged | |

Three changes: attributes of a tag are found in one pass when asked for in the order
they are written (a triangle with properties has seven); plain decimal numbers are read
directly instead of through `strtod`; the copies of a vertex are kept in a chain per
vertex instead of a hash table, and the group a triangle names is looked up once per
run of triangles. Of the 0.034 s, unpacking is 0.008 s and reading the XML most of the
rest.

**3MF display properties (2026-11-12).** A base material's display properties are read,
whether the group names them (the specification) or the base itself (the consortium's
samples): `pbmetallic` gives metallic and roughness, `pbspecular` roughness from its
glossiness, `translucent` its roughness and a fixed opacity of 0.5 (the file's
absorption and refractive index have no use in this renderer). Triangles that look
different form parts of their own. The textured variants are not read.

Against the thumbnails stored in the files: `multiprop-translucent` now shows see-through
as its thumbnail does. `multiprop-metallic` is read correctly (metallic 1, roughness 0.2)
but **drawn almost black**: the renderer mirrors the surroundings only where the view
settings set metallic or roughness, as the web viewer does, so a file's own metal has
nothing to reflect. With the surroundings mirrored for a file's own metal as well
(tried, not kept) it shows silver like its thumbnail. That rule is the renderer's and
touches every format with metals (USD today); open for the owner.

**A file's own metal mirrors the surroundings (2026-11-12, owner decision).** The
surroundings are now mirrored wherever the metallic value is above zero, not only where
the view settings set it; this departs from the web viewer. Checked before and after on
four files: the 3MF metallic sample goes from near black to silver, as its thumbnail;
the USD tack (metallic 1 with a metallic image) goes from dark with two highlights to a
lit metal; a USD model and a 3MF model without metal are unchanged.

### T8 Hologram in the native renderer (2026-11-12)

**What is drawn.** The style of `renderer/src/hologram.ts`, with its timings and numbers
kept: the see-through mint shell (rim glow, grid where the surface turns away, scan
lines, a slow breathing), built from the bottom up over 8 seconds behind a ragged bright
front; up to 4,000 sparkling grains for the part not yet built; 180 beams from four
points around the model onto the front; two blocks of falling characters; after the
build a scan line that crosses the model every 20 seconds, with six slice glitches per
pass; a glow.

**How.** `RenderLook.Style.hologram`, drawn by `Hologram` (made when the style is first
used) with the shaders of `HologramShaders`:

1. A layer of its own, 16-bit float, four samples: the shell with no depth and normal
   blending, then grains, beams and characters added. The four-sample target is kept in
   the GPU's tile memory only.
2. Glow: what is brighter than 0.55, blurred at a half, quarter, eighth, sixteenth and
   thirty-second of the size, each wider than the last.
3. In the view's own pass: background, grid, then layer and glow laid over them. Glow
   beside the model becomes a veil of its own colour, so a see-through view stays so.

`HologramTimeline` gives every value of the course from the seconds since the style was
turned on, and is tested on its own. The characters are drawn once with Core Text
(Menlo) into a 512 x 1024 image; no font is bundled. The viewer starts the course at the
first frame after the style is turned on or a model is loaded, and redraws every frame
while the style is on. With Reduce Motion on, the settled shell is shown at rest.

Differences from the web version: a part with vertex colours and no image counts as
white for the "own colour shows through" rule; a point cloud is drawn as mint dots up to
the build front; a mesh without normals takes them from its triangles. The wireframe
overlay is not drawn over the hologram.

**Compared with the web renderer** on the same file (3MF, 53,886 triangles) in Quick
Look, mid-build and settled: shell, front, grains, beams, characters and glow agree to
the eye. The glow needed the wide, flat blur at the smallest sizes to veil the
background as the web version does.

**Cost** (Release extension, Quick Look window 810 x 622 points at 2x, same file):

| | |
|---|---|
| CPU while the hologram runs | 9 to 16 percent of one core |
| Memory the style adds | 28 MB on the GPU (layer 16 MB, blurs 12 MB), measured by the device's own count |
| Footprint, model shown and still | 99 MB |
| Footprint, hologram running | 253 MB |
| Footprint, plain look with auto-rotate running | 222 MB |

So most of the rise is not the hologram's: any view that is redrawn continuously goes
from 99 to about 220 MB, in the category the footprint tool calls graphics memory not
mapped into the process. See the next entry.

Checked off screen besides: a textured USD model, 3MF with images and with colours per
triangle, a model of 17 parts, a point cloud. Not checked: the app window, the default
look set to Hologram in the settings, animated (skinned) models, Reduce Motion on a real
system setting, other GPUs.

### Memory and CPU of a view that keeps redrawing (2026-11-12)

**Where the memory is.** Measured in a test process with Metal alone, no renderer of
ours: a render pass with nothing drawn in it, one sample, no depth, 810 x 622, takes the
process from 8 MB to about 110 MB while frames are being drawn, and the system gives it
back a few seconds after the last frame. The amount does not change with the size of the
target (405 to 1620 wide), with four samples, with a depth target, with a model or
without, or with a command queue limited to two buffers. It is what the GPU driver holds
for any process that is drawing, on this Mac (M4 Pro); nothing in the app sets it. The
web renderer has the same cost in WebKit's GPU process, where it is not counted against
the extension.

**What could be lowered, and was.** The view's own multisampled colour and depth, 64 MB
for a Quick Look window of 1620 x 1244 pixels, were held all the time. The renderer now
brings these two itself and keeps them in the GPU's tile memory (`memoryless`), where
they take none of the process's; the view holds only its drawables.

| Quick Look, Release, 3MF of 53,886 triangles | Before | After |
|---|---|---|
| Model shown, nothing moving | 99 MB | 38 MB |
| Auto-rotate running | 222 MB | 159 MB |
| Hologram running | 253 MB | 196 to 209 MB |

**CPU.** Auto-rotate took 31 to 39 percent of one core, more than the hologram: the
gizmo's camera axes were a property of the model all controls observe, so every frame
redrew every control. They are now kept apart, so only the gizmo is redrawn, and while
the view keeps turning it follows 30 times a second. Auto-rotate is at 14 to 19 percent,
the same as the hologram in the same run (the two were measured between 8 and 18 percent
across runs; the machine was not otherwise idle).

**Why a redrawn view costs CPU at all, and the frame rate (2026-11-12).** The picture is
drawn by the GPU. What is counted as CPU is the work of handing each frame over: a
six-second profile of the extension with the hologram running showed the app's own code
(camera, uniforms, encoding the draws) at about 1.3 percent of a core, Core Animation's
commit at about 1 percent, and frame pacing, Metal's queues and the window server's
replies at about 2.4 percent on other threads; the rest of what Activity Monitor counts
is time in the kernel for the same calls. None of it depends on the model.

That work is paid per frame, and the view was drawing once per refresh of the display
(this Mac's built-in display refreshes up to 120 times a second; the rate itself was not
counted). While something moves the view now draws by its own clock at 60 frames a
second, and only when asked otherwise.

| Quick Look, Release | Before | 60 frames a second |
|---|---|---|
| Auto-rotate | 14 to 19 % | 5 to 7 % (7 to 11 % in a later run) |
| Hologram | 8 to 18 % | 5 to 6 % |

### Hologram arrives like a transporter (2026-11-12, owner request)

The owner asked for the Hologram to appear the way the Star Trek transporter does, and
gave a reference: a recreation of the *Star Trek: Picard* effect (a column of thin
upright streaks of cyan-white light, brightest at the foot, flickering, with flat lens
flares; the figure fades in among them and the streaks thin out, in about three
seconds). What could be found on the recent films (2009, *Into Darkness*, *Beyond*) says
their effect is points of light whirling around the traveller and the air near them,
ending in a burst, made by ILM as a particle simulation.

The native style's intro is now built from both, in 3.2 seconds instead of 8:

- **Streaks**: 260 upright ribbons through points of the model's surface, facing the
  camera, each flickering on its own, brightest at the foot; they rise first and thin
  out last.
- **Motes**: up to 4,000 points that circle the model, wide at first, and wind down
  onto its surface, where they go out.
- **The model** appears among them in thin upright strands, each glowing as it arrives,
  instead of being built from the bottom up.
- **A flare**: everything brightens at the height of the arrival, with two flat flares
  across the view at the model's foot and middle.

Gone with the old intro: the rising build front, the beams from four points, the falling
characters (and the Core Text image they were drawn into). Unchanged: the settled shell,
its scan line (which now starts when the model stands), the glitches, the glow, and the
web renderer's own Hologram, which still shows the old intro for the formats it draws.

Checked off screen on two models (a 3MF, a textured USD) at nine moments, and in Quick
Look at four moments. In one Quick Look run the view was zoomed far into the model
during the arrival. The six runs after it, with the same steps, were right. In the code
the camera's distance changes only through a scroll or pinch on the view (`zoom(scale:)`,
called from nowhere else), and the test had just parked the pointer over the preview on
a Mac in use, so a scroll that went to the preview is the likely cause; it was not
reproduced, so this is not proven. Also checked since: the app window (arrival and
settled) and a point cloud off screen. Not checked: the arrival's own CPU cost.

### Hologram arrival redesigned as two swirls (2026-11-12, owner request)

The owner asked for swirls instead of streaks: two swirls that build the model from its
middle, one to the top and one to the bottom. The arrival is now, in 4 seconds:

- **Two fronts** start at the model's middle height and move apart at a steady pace, one
  up and one down; the model exists only between them. The fronts are ragged, in blocks,
  and glow.
- **Each front carries a swirl**: a ribbon of light winding 2.6 times around the model,
  its white head at the front, its tail trailing back over what is built, never past the
  middle. The two turn opposite ways.
- **Motes** (up to 4,000, one per sampled point of the surface): as a front comes within
  a quarter of the model's height of a point, its mote circles the model, wide at first,
  and winds down onto the point, going out as the front builds the surface there.

Gone: the column of streaks, the flat flares, the flash, and the strand-by-strand fade
in. Unchanged: the settled shell, scan line, glitches, glow.

Checked off screen on two models at seven moments, in Quick Look at two, and in the app window mid-build and settled.

### Skinning moved to the GPU (2026-11-12, owner decision)

Skinned vertices were moved to their pose on the CPU every frame, into one of three
vertex buffers used in turn. They are now moved by a compute pass (`skinVertices`) at
the start of the command buffer that draws the frame: it reads the bound vertices, the
joints and weights of each, and the joints' matrices for the pose, and writes the posed
vertices (and the outline's normals, once built) into the part's one vertex buffer.
Every look, the wireframe, the outline and the Hologram draw from that buffer as before,
so no drawing shader changed. The CPU still works out the joints' matrices (a few dozen
per frame) and does the whole job once when a scene is made, and whenever the pass
cannot be set up.

`pose(clip:time:)` now only sets the pose; the vertices move when the next frame is
encoded. `MetalRenderer.skinsOnGPU` switches back to the CPU for tests, which check that
both give the same picture.

| A tube of 1,000,000 skinned vertices, 40 joints, off screen, Release | CPU posing | GPU posing |
|---|---|---|
| Time a frame | 3.6 to 3.8 ms | 1.7 to 1.8 ms |
| CPU time a frame | 2.5 to 2.7 ms | 0.7 to 0.8 ms |

So posing a million vertices cost about 1.9 ms of CPU a frame, 11 percent of a core at
60 frames a second, and that is what moved. For a model of 50,000 vertices the same
sum is about 0.1 ms a frame, under 1 percent of a core: for ordinary animated models the
change is too small to see in the CPU figure, which stays what macOS charges for
presenting frames.

Checked in Quick Look: the animated USD sample (3,360 vertices) plays as before. Not
checked: several skeletons in one file, more than four joints per vertex (the importers
keep four), the app window.

### What only drifts is drawn at 30 frames a second (2026-11-12, owner decision)

Auto-rotate and the settled Hologram run for as long as a preview is open. They are now
drawn 30 times a second. A camera move, a playing clip and the Hologram's arrival keep 60;
the rate is chosen frame by frame from what is moving.

| Quick Look, Release | 60 frames a second | 30 |
|---|---|---|
| Auto-rotate | 5 to 7 % (7 to 11 % in a later run) | 3 to 4.5 % |
| Hologram, settled | 5 to 6 % | 2.3 to 5 % |

Auto-rotate turns one degree every 83 ms, so at 30 frames a second each frame moves the
picture 0.4 degrees instead of 0.2: the cost is smoothness, judged by eye only.


### Hologram: the remaining checks (2026-11-12)

- **Animated model in the style**: `bend.usdc` in Quick Look. The arrival runs while the
  clip plays, and the settled shell bends with the GPU-posed vertices; the scrubber moves on.
- **Arrival's CPU** (Quick Look, Release, one-second samples from the click, three runs on
  two models): 3.1 to 4.3 % of a core during the arrival, 2.1 to 3.0 % once settled.
- **Hologram as the default look**: a test opens the viewer with that setting. The style is
  on from the first frame, the arrival's clock starts at that frame and starts again for the
  next model. Not seen on screen: that needs the owner's settings file, which tests never write.
- **Reduce Motion**: the viewer asks the system through a replaceable check; with it on, the
  test gets the whole shell at rest, the same picture frame after frame. The system setting
  itself was not switched.
- Seen on the way: a flat model lying on the ground (an STL of one flat plate) is edge-on to
  the opening camera and shows nothing, in every style. Not changed.

### The swirls follow the model's width (2026-11-12, owner request)

The two ribbons were sized from the bounding box, so around a tack's pin they circled as
wide as its head. The model's width is now measured at 16 heights from the surface points
already sampled for the motes (centre and half widths in x and z; heights with no points
take theirs from the nearest that have; never thinner than 4 % of the longest side), and
each ribbon winds 1.24 times that wide at its head, opening out along its tail. Seen in
Quick Look on a tack, a wide flat model, an animal and a box: the ribbons stay close to
the pin and open around the head.

### A flat model is first seen from above (2026-11-12, owner decision)

The opening camera looks from the front, so a model with no height (an STL of one plate,
lying on the ground after the Z-up turn) was edge-on and showed nothing. A model lower than
5 % of its longest horizontal side now opens 35 degrees above the horizon; Fit and reset
return there. Everything else opens as before. Seen in Quick Look with a two-triangle
plate, plain and in the Hologram style. The web renderer is unchanged.

### T9 Folder grant and OBJ materials (2026-11-12)

**OBJ materials.** `OBJReader` splits the faces into one part for each material (`usemtl`)
and reads the libraries the model names (`mtllib`, also when named after the faces, several
on a line, names with spaces). `MTLReader` keeps `Kd`, `d` / `Tr`, `map_Kd` (options before
the name passed over) and `Pr` / `Pm`. Texture coordinates are kept only for parts whose
material has an image that could be read. An image replaces the material's own colour
(as Blender reads these files; the format's text says multiply, which dims the many files
written with `Kd 0.8`). Not read: highlights, glow, bump and normal maps, `map_d`.
A 67 MB file with 980,000 triangles loads in 0.25 s.

**Files beside a model** are opened only through `SidecarFolder` (ModelCore): the model's
folder and the usual texture folders in it, by the name as written or its last part, never
through a link that leads out, at most 64 MB a file, 256 MB and 256 files a model. OBJ and
3D Studio use it; the USD reader still follows Model I/O's own paths.

**The grant.** `FolderGrants` (ViewerUI) keeps a security-scoped bookmark for each granted
folder in the app's container and a plain bookmark in the shared container
(`folder-access.plist`), which the extension uses; the app writes the plain ones again at
every launch (they are expected to stop working when the Mac restarts, S3). A grant covers
the folders inside it; granting a folder above replaces the ones inside. Access is opened
for the import only. The native viewer shows a notice when files were not read: in the app
with a button that asks for the folder (open panel at the model's folder) and shows the
model again; in Quick Look with the way to the app; with the folder open, the names of the
files that are simply not there. The web viewer's formats also read their sidecars from
granted folders, but show no notice.

Seen with the sandboxed Debug build (Assimp's `spider.obj`, five images; a 3D Studio cube
with one image):

| | Result |
|---|---|
| App, folder not granted | untextured, notice with the button |
| App after the grant, relaunched | textured |
| Quick Look, granted folder, app quit | textured (OBJ and 3D Studio) |
| Quick Look, another folder | untextured, notice |
| App, that other folder: the button, the panel opened at the model's folder with its message, Allow | the model is shown again, textured |
| Quick Look, that folder afterwards, app quit | textured |

The first grant was made by opening the folder with the app, which Debug builds accept as
a grant (as in S3); the second through the button and the panel, driven by script.

Not done or not seen:

- **Related items** (`NSIsRelatedItemType` for `.mtl` / `.bin`) are not declared. With the
  grant in place they would only save the panel for an OBJ whose library names no images.
- No list of granted folders in Settings, and no way to take a grant back in the app
  (`FolderGrants.revoke` exists).
- Quick Look after a restart of the Mac; folders on external or network volumes; a folder
  moved or renamed after the grant.
- The notice's wording is a draft for the owner to approve.

### Tests of the controls in the test process (2026-11-12, owner decision)

The viewer's SwiftUI controls are now tested with ViewInspector (MIT, a dependency of the
`ViewerUITests` target only; nothing of it is in the app): the notice and its button, the
bottom bar (Textured offered or not, the style buttons and which are off without textures,
the wireframe rule), fit, grid and auto-rotate, the animation bar, the statistics, and
what hides in a small preview. They run with the other tests and never touch the screen.

An on-screen test target (XCUITest) was built and then removed at the owner's choice. What
it showed, for whoever tries again:

- It passed: Quick Look plain before the grant, the notice and button in the app, the
  system's panel and Allow, the model textured, still so after a relaunch, Quick Look
  textured with the app quit, plain again after the grant is taken back.
- **An app built as the target of on-screen tests is signed with read access to the whole
  disk** (`temporary-exception.files.absolute-path.read-only: /`), and so is its
  extension. The sandbox under test is then gone: Quick Look showed textures in folders
  never granted. The app must be built by its own scheme and the test must not depend on it.
- The test runner is sandboxed too: it cannot start `qlmanage`, and the system drops
  launch arguments it passes along with a file.

The sandbox, the panel and Quick Look therefore stay checked by hand-run scripts against
the normally built app. Debug builds keep two aids for that: a folder opened with the app
is granted, and `-P3DRevokeFolder <path>` takes a grant back (used to clear the grants
those checks made; the stores are empty again).

### COLLADA is dropped (2026-11-12, owner decision)

COLLADA (`.dae`) is no longer a supported format: it is a legacy interchange format that
glTF, FBX and USD have replaced (Blender removed its own support in 5.0; no usage figures
were measured). Thirteen formats remain, and task 10 is gone.

- The extension no longer claims `org.khronos.collada.digital-asset-exchange`, so Finder
  gives `.dae` files to macOS's own preview; the app no longer lists the type or offers it
  in its open panel.
- A `.dae` that still reaches the app (Open With) goes to the native viewer whatever
  renderer is forced, and is answered with "COLLADA files are not supported."
- `FormatDetector` still recognises COLLADA, so such a file is not mistaken for OBJ or glTF.
- Assimp is built without its COLLADA importer (FBX and 3D Studio remain).
- Left in place: the web renderer's COLLADA loader and its tests (`renderer/src`), which
  nothing reaches now and which go with the web renderer.

### T12 glTF / GLB, step 1: the reader's core (2026-11-12)

`ImportGLTF` reads glTF 2.0 in both forms with our own code (`GLTFReader`, a `Document`
over the JSON): the binary container, buffers and images inside the file as data or beside
it through the sidecar rules, accessors of every component type (normalised integers, byte
stride, sparse replacements), the default scene's nodes, triangle lists, strips, fans and
points, positions, normals, the texture coordinates the colour image uses, vertex colours,
metallic-roughness materials with colour, metallic-roughness and normal images,
`KHR_materials_unlit`, `KHR_materials_pbrSpecularGlossiness`, and blending. The file's
linear colours are turned into the scene's on-screen ones.

Every offset, length and index from the file is checked against the data that is there; an
accessor that points outside its buffer fails the load. A buffer that sits beside the model
and cannot be read fails with the file's name (`missingFiles`); an image out of reach is
listed and the material keeps its colour. Nothing is fetched from an address.

Ten Khronos sample assets were loaded and drawn off screen (not yet through the app, which
still routes glTF to the web renderer): Box, BoxTextured, BoxVertexColors, Duck (binary
and separate files), DamagedHelmet (0.03 s), AlphaBlendModeTest, SimpleSparseAccessor, Fox
and CesiumMan, the last two in their rest pose.

Still to do before glTF moves: skins and animation (also of plain nodes), Draco and
Meshopt, cut-out transparency (`MASK` is drawn opaque), glow, texture placement
(`KHR_texture_transform`), morph targets, the notice and grant button for a model whose
buffer is beside it, and the comparison with the web renderer in the app and Quick Look.

### T12 glTF / GLB, step 2: skins and animation (2026-11-12)

The scene model moves vertices only through a skeleton, so everything in a glTF file that
moves is brought to one skeleton: every node of the scene is a joint; every joint of a
skin is one more joint under its node, carrying that skin's inverse bind matrix; and a
mesh with no skin under an animated node is bound whole to its node's joint. The existing
GPU skinning then plays skinned and plain-node animation alike.

Each animation is a clip of that skeleton, sampled from the file's samplers (linear, step
and cubic spline, each with its own key times) 30 times a second; the rate is lowered for
clips longer than two minutes or skeletons too large to hold (4 million values a
property). Weights are brought to a sum of one. Not read: morph targets and their
animation, more than four joints a vertex (both are noted in the diagnostics).

Drawn off screen at two moments of a clip: Fox (three clips, 24 joints), CesiumMan and
BoxAnimated (plain-node animation).

### T12 glTF / GLB, step 3: no compression, cut-outs, and what is said on failure (2026-11-12)

- **Draco and Meshopt are not read** (owner decision): a file that needs either is answered
  with "Draco-compressed models are not supported" (or Meshopt). No decoder is vendored.
  This is a regression against the web renderer, which opens Draco files.
- **Cut-out transparency** (`alphaMode: MASK`): `Material.alphaCutoff`; the renderer leaves
  out what lies below the threshold in the colour image's alpha and draws the rest solid.
  The Khronos AlphaBlendModeTest shows its three thresholds cut at three heights. The
  outline, the wireframe and the Hologram still follow the whole surface.
- **A model whose buffer is beside it** and out of reach fails with the file's name, and the
  notice offers the folder ("Model not shown", "Show Model…"); once the folder is allowed
  it loads. **A model that cannot be shown gets no notice about textures or materials**
  (owner instruction): on a failure the notice appears only for the model's own missing
  data, and speaks of the model.
- First look through Quick Look with the native renderer forced: Duck, Fox (clip picker,
  statistics) and DamagedHelmet match the web renderer in shape and colour as far as two
  different opening angles allow; the blend panel is see-through.

### T12 glTF / GLB, step 4: glow and texture placement (2026-11-12)

- **Glow.** `Material.emissive` (linear, with `KHR_materials_emissive_strength` counted in)
  and `emissiveTexture`; the renderer adds it to what the lights make of the surface, in
  the Textured view and its Unlit style. DamagedHelmet's visor lights and the five cubes
  of EmissiveStrengthTest show it.
- **Texture placement** (`KHR_texture_transform`): offset, rotation and scale are laid
  into the part's texture coordinates when the file is read, so the renderer is unchanged.
  The colour image decides the coordinates and their placement; an image of the same
  material that wants another set or another placement is left out and noted. Khronos'
  TextureTransformTest shows its check marks and its arrows point at the right boxes.

### T12 glTF / GLB, step 5: moved to the native renderer (2026-11-12)

glTF and GLB are in `RendererRoute.nativeFormats`. A VRM avatar or a VRM animation is glTF
by format; `FormatDetector.isVRM` looks for the VRM extensions' names in the file's
description and such a file stays with the web renderer until task 13.

Added on the way, from a run of 30 more Khronos sample assets (all load; drawn off screen):

- the colour image's sampler: clamped, mirrored or repeated, and enlarged sharp or smooth
  (`Material.sampling`; the renderer keeps a sampler for each kind it meets);
- one-sided materials (`Material.oneSided`): glTF means a material that is not
  double-sided to show its front only, where other formats' open surfaces show both sides;
- unlit materials (`KHR_materials_unlit`) drawn in their own colour, whatever the light;
- vertex colours tinting an image (they were ignored where a part had an image);
- a glow whose image cannot be used (it wants other texture coordinates) is left out,
  instead of covering the whole surface.

The Khronos tests for texture settings, negative scale, vertex colours, texture transform,
alpha modes and emissive strength show their expected marks.

In Quick Look with the default routing: DamagedHelmet and Fox (with its clip picker) are
native, a VRM avatar is still the web renderer's, a Draco file and a `.gltf` with its
buffer in a folder not allowed are answered with their messages, the latter with the notice.

Not shown, each noted in the model's diagnostics: Draco and Meshopt (owner decision), morph
targets and their animation, instanced copies (`EXT_mesh_gpu_instancing`), a second set of
texture coordinates for another image of the same material, more than four joints a vertex,
lines. Not read at all: occlusion maps, cameras, lights, and the material extensions for
clearcoat, sheen, transmission, iridescence and the like, which draw as plain
metallic-roughness. Against the web renderer the regressions are Draco and morph targets.

### Morph targets (2026-11-12)

A mesh part can carry other shapes of itself (`MeshPart.morphTargets`: what each adds to
the positions and, when the file says, the normals), a mesh the weights it starts with
(`Mesh.morphWeights`), and a clip the weights over time for each mesh (`AnimationClip.morphs`).

They show through the skin. The renderer blends the shapes on the CPU into the skin's rest
shape whenever the weights change (only the targets that are showing are added), and the
GPU skinning carries the result as it carries any rest shape. A part with shapes and no
skeleton of its own is therefore bound whole to one joint by its importer; glTF does that
with its node's joint, and gives every node that uses such a mesh its own copy, with the
node's weights where it sets them.

glTF: targets (sparse or not), mesh and node weights, and `weights` animation in all three
interpolations, sampled with the rest of the clip. Seen: AnimatedMorphCube changing shape
as it plays in Quick Look, MorphStressTest and MorphPrimitivesTest drawn off screen.

Limits: normals are not recomputed for targets that give none; the outline keeps the
resting shape's normals; the shapes are kept whole (six floats a vertex for each target),
which for an avatar's face with fifty expressions is tens of megabytes; tangents in
targets are not read.

### T13 VRM: cartoon materials and spring bones (2026-11-12)

Scope (owner decision): what today's viewer shows of an avatar. A `.vrm` file is glTF and
is read by the glTF reader; on top of it:

- **Cartoon materials.** `VRMC_materials_mtoon` (1.0) and the Unity material properties of
  0.x (`materialProperties`, shader `VRM/MToon`) both become `Material.toon`: shade colour
  and image, shift, "toony", and the outline's width, colour and lighting mix. The 0.x
  shift and toony are converted the way three-vrm converts them; its outline widths are
  centimetres. In the Textured view such a material is its colour or its shade with a
  narrow step between them (no highlights), and its outline is a second pass of the
  shape's back faces pushed out along the normals. Solid, Normal and the styles ignore it.
- **Facing.** A 0.x avatar faces away from the viewer; its roots are turned half a turn.
- **Spring bones.** `VRMC_springBone` and 0.x `secondaryAnimation` become
  `ModelScene.SpringSystem` (joints with a tail, ball and capsule colliders).
  `SpringSimulator` is VRM 1.0's algorithm in the scene's space; `GPUScene.pose` steps it
  with the frame's time (at most 1/30 s) and replaces the spring joints' turns before the
  skin matrices are made. The viewer keeps drawing until the chains have been at rest for
  twenty frames, then stops (0% CPU measured on Alicia after it settles). With Reduce
  Motion they are shown already at rest.

VRM avatars are now routed to the native renderer; a VRM animation (`.vrma`,
`VRMC_vrm_animation`) stays with the web renderer until T14.

Seen in Quick Look and the app beside the web renderer: AliciaSolid (0.51), Seed-san and
VRM1_Constraint_Twist_Sample (1.0) match in shading, outlines, facing and pose.

Highlights (owner request, same day): the rim light along the edges that turn away from
the viewer (colour, fresnel power, lift, its multiplying image), the matcap (a painted ball
looked up by the surface's direction in the view, times its factor), the image that moves
the edge between colour and shade, and the image whose green thins the outline (sampled in
the outline's vertex stage). Rim and matcap are dimmed by the light as far as the
material's lighting mix says. 0.x: `_SphereAdd`, `_RimColor`, `_RimFresnelPower`,
`_RimLift`, `_RimTexture`, `_RimLightingMix`, `_OutlineWidthTexture`.

Moving textures (owner request, same day): a cartoon material slides its images
(`uvScroll`, in image widths a second) and turns them about their middle (`uvRotation`,
radians a second), as much as the blue of its mask image says. The renderer is given the
time (`MetalRenderer.materialSeconds`) and moves the texture coordinates in the fragment
stage, for every image of the material and for its outline. The viewer keeps drawing at
30 frames a second while such a material shows in the Textured view, and not at all with
Reduce Motion. 0.x is converted as three-vrm converts it (`_UvAnimScrollY` negated,
`_UvAnimRotation` as it is; `_RimLightingMix` is zero when missing).

Seen in Quick Look beside the web renderer, on the samples with a speed patched in (none
of them has one): 1.0 sliding in Y and 0.x sliding in X match. A 0.x file sliding in Y
moves here and is shifted but still in the web renderer; the format's meaning is motion,
so this difference is kept.

The 0.x shading-grade image has no counterpart and is not read. Expressions and look-at
have no control (the shapes are read as morph targets and stay at their weights).
Constraints (`VRMC_node_constraint`) are not read: nothing moves the avatar, so at rest
they change nothing; they are needed with T14. A spring's `center` and the extended
collider shapes are ignored. A vertex list shared by several parts is counted once.

### T14 VRMA: motion with no mesh, on its skeleton (2026-11-12)

A `.vrma` file is glTF with nodes and an animation and no mesh. Today's viewer plays the
animation as plain glTF on a line skeleton, with no avatar and no retargeting; the native
one does the same. A glTF file with animations and no mesh gets a stick figure
(`Document.stickFigure`): each node with children carries a mesh of one bone per child, a
long pyramid on a short one from the node to the child, in the node's own space. The
bones follow their nodes through the existing rule for an unskinned mesh under a moving
node. The file's face and vertex counts stay zero. Nodes with no animation and no mesh
are still "empty".

VRM animations are routed to the native renderer; no glTF-family file goes to the web
renderer any more. `VRMC_vrm_animation`'s humanoid map, expressions and look-at are not
read: they matter only when the motion is put on an avatar, which the viewer does not do.
For the same reason `VRMC_node_constraint` stays unread.

Seen in Quick Look beside the web renderer with three-vrm's `test.vrma`: the figure
stands framed with the player under it, where the web renderer draws thin lines far away.

### T11 FBX native (2026-11-12)

FBX is read through Assimp (the importer already built for 3D Studio) and routed to the
native renderer. On top of what 3D Studio uses:

- **Bones.** As for glTF, everything that moves is one skeleton: every node is a joint,
  every bone of an Assimp mesh is one more joint under the node of its name carrying that
  mesh's offset matrix, the four strongest weights of each vertex are kept, and a vertex no
  bone holds stays with its mesh's node. A mesh with no bones under an animated node is
  bound whole to the node.
- **Animations.** Each Assimp animation is a clip: its position, rotation and scaling
  keys sampled at 30 Hz from the first key to the last (linear, slerp for turns), with the
  limits the glTF clips have.
- **Motion with no mesh** is shown on the stick figure, now `ModelScene.addStickFigure`
  in ModelCore, shared with glTF.
- **Materials.** Normal map, emissive colour and image as well as the colour ones. An
  opacity of zero is taken as an exporter's slip and shown opaque. Image names written
  with Windows separators are looked up by their last part; the file's `.fbm` folder is
  one of the places looked in.
- **Statistics.** Assimp gives every corner with its own normal or texture coordinate its
  own vertex; for FBX the distinct points of each mesh are counted, which is what 1.0.0
  shows (Samba Dancing 27,850; a cube 8).

Seen in Quick Look beside the web renderer (three.js's Samba Dancing and Assimp's test
models): Samba dancing with the same face and vertex counts, `animation_with_skeleton`,
`cubes_with_names`, `spider`, `maxPbrMaterial_metalRough`, `box-embedded` and `huesitos`
alike; `box.fbx` (a text file) opens here and fails there; `transparentTest.fbx` fails in
both. Tests build a text FBX by hand (a square, its material, one bone, one animation).

Blend shapes (owner request, same day): each Assimp "anim mesh" of a mesh becomes a morph
target (what it adds to the positions and, when given, the normals), and an animation's
morph channels become the clip's weights for that mesh, sampled with the rest of the
clip. At rest no shape shows, as in the web renderer. A mesh with shapes and no bones is
bound whole to its node, as the morph targets need. Over 512 shapes, or 8 million shape
vertices, a mesh's shapes are left out and the diagnostics say so. Seen in Quick Look
beside the web renderer: a hand-made text FBX whose square moves out as its shape comes
in, and three.js's `morph_test.fbx` at rest. The view is framed on the resting shape, so
a shape that grows a lot can leave the frame.

Not done: in-between shapes of one channel, more than four bones a vertex, the
file's up axis and unit (the samples stand as they do in the web renderer without them),
cubic key interpolation beyond what Assimp resamples, lights and cameras. Images beside
the file and several animations were checked afterwards (below).

### The view is fitted to the whole motion (2026-11-12, owner request)

A model with clips was framed on its resting pose, so a pose or a shape that reached
further left the view. `GPUScene.framing` now also takes in where the skinned parts are at
thirteen moments of every clip, with the morph weights of that moment (fewer moments, then
every few vertices, when vertices times clips pass a budget of six million placements).
The grid and the opening view follow, since both come from the framing. Springs are not
part of it. A clip that carries the model far away makes it small in the view; nothing
limits that.

### The picture keeps clear of the bottom controls (2026-11-12, owner request)

A model that filled the frame was drawn under the bar of controls, and under the player
when it had clips. `MetalRenderer.bottomInset` is the share of the view's height those
cover (the viewer sets it: 56 points for the bar, 40 more for the player, at most 0.4).
The projection is scaled by what is left and moved up by the inset, so the point the
camera turns about sits in the middle of the free part; the camera itself, its limits and
the gestures are untouched. `viewPosition` in the shaders reads the move from the
projection's third column. Off-screen pictures have no inset.

Seen in Quick Look in the default look. Not looked at with the inset: the Hologram style,
whose shaders use the same projection.

### FBX: images beside the file and several animations, checked (2026-11-12)

With text FBX files made by the tests' own builder (a square with texture coordinates and
a colour image named the Windows way; a second animation stack):

- Tests: the image is found beside the model, at the relative path the file gives, in a
  usual texture folder when the file names a path that is gone, and in the model's own
  `.fbm` folder; another model's `.fbm` folder is not used; an image that is nowhere
  leaves the model loading with its name in the diagnostics. Each animation stack is a
  clip with its own name and length.
- Quick Look and the app, sandboxed: before the folder is allowed the square is plain
  with "Textures not shown"; after, the image shows from beside the file and from
  `square.fbm`; a file whose image is nowhere says "Textures not found: checker.png"; the
  file with two animations has the clip picker beside the player.

### The player: one clip's name, play once, Repeat (2026-11-12, owner requests)

- A file with one clip that it names shows the name beside the scrubber, as words
  (`NativeViewerModel.onlyClipName`); a name the viewer makes up ("Clip 1") is not shown.
  Several clips keep the picker.
- A clip plays once and stops on its last moment, the play button showing again; played
  from there it starts over. `NativeViewerModel.repeats`, a switch at the end of the
  player, makes it go round as before. The switch starts, for every file, from the setting
  "Repeat animations" (`repeatAnimations`, off unless chosen) in the app's settings,
  which Quick Look reads like the others; flipping the switch in the player lasts for
  that file only and is not written back, as with the grid and auto-rotate. The key is
  also in the web renderer's settings and the shared test vectors so the two sides
  agree on it, but the web player (Blender files) ignores it and always goes round. Seen in Quick Look: Samba Dancing stops at its end and
  the extension then uses no CPU.

### T15 Blender, step 1: the reader (2026-11-12)

`ImportBlend` reads .blend files of Blender 2.80 and later into a `ModelScene`, with the
scope of today's `renderer/src/blend.ts`. It is in `ImportRouter` but **not yet routed**:
Blender files still open in the web renderer, because files saved compressed with
Zstandard cannot be unpacked yet (below).

- **The container** (`BlendFile`): both file headers (up to 4.x, and 5.0's with its wider
  block headers), 4- and 8-byte pointers, the blocks, and the file's own description of
  its structures. Every offset comes from that description; the code names fields only.
  A pointer is resolved among the blocks of the data-block being read, as spike S5 found
  it must be. Every read is checked against the file's size and gives zero outside it;
  lists stop at a limit and at a loop.
- **What is shown**: the mesh objects of the scene the file was saved on, in its first
  view layer, that a viewport shows: in a collection that is not excluded, hidden in the
  layer or disabled for viewports (nor under one that is), not hidden by hand, not
  disabled themselves. The flag Blender last worked out for an object is not trusted
  where the collections can be read: a demo file has it stale.
- **Where objects stand**: the world matrix the file keeps (up to 4.1), else location,
  rotation in any of Blender's modes and scale, with the delta values, under the parent
  and its inverse; an object held by a bone stands at that bone's far end, as posed.
- **Meshes** in the three layouts S5 found (vertex, corner and face records; named
  layers with a face offset table; Blender 5's attribute storage): faces with their
  corners as modelled, smooth or flat face by face, the material slot of each face, and
  the texture coordinates of the map used for rendering. Each corner becomes a vertex to
  draw; smooth faces share an area-weighted direction at each vertex. One part for each
  material slot. The statistics count the mesh's own vertices and faces.
- **Materials**: the Principled BSDF the output's surface comes from (or the first):
  base colour, metallic, roughness, alpha, emission colour and strength; the viewport's
  values when there is none; the base-colour image when it is packed into the file. An
  object's own material goes over the mesh's in the slots it takes. Older files do not
  say what structure a socket's value is; it is known by the socket.
- **Compressed files**: gzip (before 3.0) is unpacked with the system's zlib. Zstandard
  (3.0 on) is refused with a message: the system cannot unpack it. 12 of the 13 Blender 5
  files on this Mac are saved that way, so the format cannot move without it.
- Files older than 2.80 and big-endian files are refused with their reason.

Checked against Blender 5.2.2 itself (each file opened without a window; object names and
visibility, world matrices, face sizes, corner counts, sums of positions and of texture
coordinates over the corners, faces per material, and each material's values compared):
56 files of 2.82 to 5.2 (40 found on this Mac, 16 public demo files; Zstandard ones
unpacked with the command-line tool first). 52 agree in everything, and all 121 materials
in use agree. The four that differ:

- two meshes (3.6, 4.2) have a texture-coordinate map in the file that Blender shows as
  absent after opening; unexplained, as in S5;
- one animated object in a 2.82 file stands where the file keeps it, and Blender moves it
  when it opens the file;
- a 4.2 file whose objects are placed by constraints and a posed rig: such files no
  longer keep the result, and constraints and animation are not worked out here.

Seen in Quick Look beside the web renderer (native forced by the debug override): six
files of 2.82, 3.0, 3.6, 4.5 and 5.2 look alike with the same face and vertex counts; two
of them show nothing in the web renderer and their shapes here.

Tests write their own small .blend files (`BlendBuilder`: header, blocks and a structure
description with only the fields the reader looks for), one scene in each of the three
mesh layouts, and check values, not counts. Damaged files (cut short, bytes turned over,
every count replaced) fail or load without reading outside themselves.

Not done, as today: modifiers, armature poses and animation, node-built materials,
images in separate files, instanced collections, curves and text. Speed: the largest file
(93 MB unpacked) took 8 s in an unoptimised test build; a release build is not measured.

### T15 Blender, step 2: Zstandard, and the format moves (2026-11-12)

Blender files are now shown by the native renderer (`RendererRoute.nativeFormats` gains
`.blend`); no format is left on the web renderer.

- **Zstandard** is unpacked by the reference library's decoder, vendored as the `CZstd`
  target (owner decision of 2026-11-12, over a decoder of our own in Swift, which was
  written and then dropped): zstd 1.5.7 from the project's release archive (its published
  SHA-256 checked), only `lib/common` and `lib/decompress` with the two public headers,
  unchanged, built with the assembly path, old-format support and error strings turned
  off. About 1 MB of source; BSD licence, in `THIRD_PARTY_LICENSES.md`.
- `Zstandard.decode` drives it as a stream: frames one after another and frames to skip
  (Blender writes a large file as many frames and a table of them), a window of at most
  128 MB, and the result held to the reader's 2 GB limit. Cut-short data is damaged.
- Checked byte for byte against the 18 Zstandard .blend files found on this Mac (unpacked
  with the command-line tool before) and 26 files packed by the tool at levels 1 to 22,
  with and without checksums, empty, random, and two frames joined. The largest (150 MB
  unpacked) takes 0.5 s.
- Tests keep two small samples packed by the tool, and write frames of stored blocks
  themselves; they cover joined and skipped frames, the limit, every cut length and every
  altered byte, and a compressed .blend through the reader.
- Seen in Quick Look without the override: four compressed files (5.x and a 733,576-face
  one of 94 MB) open natively.

### The web renderer is removed (2026-11-12)

With every format native, what served the web renderer is gone:

- `renderer/` (the three.js page, its tests and build), the copy bundled in the
  extension, the build phase and release job that made it, and Node.js as a requirement;
- `WebViewerController`, `ModelPayload` (base64 hand-over, files beside a model as JSON)
  and `ViewerSettings.json`, with their tests;
- `RendererRoute`, the `Renderer` choice and the `P3DForceRenderer` debug override.
  `ViewerFactory.makeViewer(frame:)` makes a `NativeViewer`, and throws when there is no
  Metal device (the app and Quick Look then show the error);
- the `com.apple.security.network.client` entitlement of both targets, which only the web
  view needed. A test now fails if any network entitlement comes back;
- the web renderer's entries in `THIRD_PARTY_LICENSES.md`.

`testdata/settings-vectors.json` stays as the account of what a valid setting is, run
against `ViewerSettings.normalize`. The debug app is 14 MB.

Checked: package and app tests pass; the built extension, signed without the network
entitlement, opens STL, PLY, OBJ, USD, glTF, FBX, VRM, VRMA and Blender files in Quick
Look. The app window itself was not opened in this step.

### Licences inside the app (2026-11-12)

`LICENSE` and `THIRD_PARTY_LICENSES.md` are bundled as resources of the app, and
**Acknowledgements** in the app menu (under About) opens a window with both, the project's
first. The BSD terms of Assimp, Poly2Tri and Zstandard ask for the notice with the binary;
until now it was only in the repository. `THIRD_PARTY_LICENSES.md` gained Assimp 6.0.6
and the six parts found in the built library by its symbols (Clipper, UTF8-CPP, Poly2Tri,
pugixml, Open-DDL Parser, MiniZip), texts from the pinned tag.

Tests: the text has the project's licence before the third parties' and the words each
licence asks to be kept; the vendored decoder's own `LICENSE` is in it word for word; a
missing file is said to be missing; `project.yml` bundles both files. Checked in the built
app: both files are in its resources, and the menu item opens the window with the text.

### Files beside a model: asking in Quick Look, and same-named files (2026-11-12)

The notice about unread files was long, dim, and in Quick Look offered nothing to do.

- **Notice**: one short line ("They are in other files beside it."), a yellow mark, and a
  prominent **Show Materials… / Show Textures… / Show Model…** button, in both hosts.
- **Quick Look asks for the folder itself.** The folder panel opens as a sheet of the
  preview, set on the model's folder, and the model is read again once it is allowed.
  What the extension's sandbox does and does not allow was found by trying (denials read
  from the system log):
  - it cannot open the app (`deny lsopen`) or write the shared container
    (`deny file-write-create`), so handing the request to the app is not possible;
  - it cannot make security-scoped bookmarks (`deny mach-lookup
    com.apple.scopedbookmarksagent.xpc`, with or without the app-scope entitlement);
  - it can show the open panel, and a plain bookmark of the chosen folder, kept in its
    own container, opens the folder in later previews until the Mac restarts.
  `FolderGrants` therefore keeps a store per process: lasting keys in the app, plain ones
  in the extension, and the app's copy for the extension as before.
- **Same-named files without asking (app only).** `ship.mtl` beside `ship.obj` is read
  through a file coordinator that presents the model as the main item; the app declares
  the extensions (`mtl, bin, png, jpg, jpeg, tga, bmp, webp`) as related document types.
  The extension's sandbox denies the same read, with the types declared there too, so in
  Quick Look such a file still needs the folder.

Not solved: an OBJ whose `.mtl` holds only plain colours still shows the notice in Quick
Look, because the `.mtl` cannot be read there to find that out. A folder allowed in Quick
Look is not known to the app, and the other way round only through the shared copy.

Checked in the built extension with real clicks: Show Materials…, Allow, the texture
appears; a new preview process shows it without asking. In the app, the owner's OBJ with
a same-named plain `.mtl` opens with no notice. Tests: the notice texts, a grant made and
kept by each role, the name pairing, and that `project.yml` declares the extensions the
reader uses and no entitlement beyond sandbox, user-selected files and the app group.

### Repository cleanup (2026-11-12)

`Spikes/` (the S4 and S8 throwaway programs named above, 318 files) is deleted; what they
found is in this document and their code is in the history. Comments that explained a
value by the web viewer now state the value plainly. The Japanese and Korean READMEs carry
the English one's format table, the play-once and Repeat behaviour, and the folder
permission as it now works.

### Open gaps checked (2026-11-12)

What earlier entries listed as not checked, now under test; none of it needed a fix.

- **Hologram and the bottom controls**: the Hologram's own shaders follow the same shifted
  projection; its shell is three quarters the size and centred in the area above the
  controls (`BottomInsetTests`).
- **Reduce Motion**: a swinging part (a strip on a spring bone that starts out sideways)
  is shown hanging at rest from the first frame, a sliding image stays put, and two frames
  a moment apart are one picture; without Reduce Motion the same scene moves
  (`NativeViewerLoadTests`). The Hologram's rest was already covered.
- **A style as the default look**: Unlit, Cartoon, Sketch and Hologram each open in the
  Textured view on a model with colours of its own, and come back to it when Quick Look
  shows the preview again.
- **The app's window**: seen in the demo recordings of this day (the model sits above the
  bar in every look); no test of its own.

Left as it is: auto-rotate set as a default keeps turning with Reduce Motion on, since it
is the user's own setting.

### Human Interface Guidelines: review, and what an MVP needs (2026-11-12)

The app was read against Apple's guidelines (accessibility, the menu bar, settings, Dark
Mode, launching, help tags, keyboards, pointing devices, motion) and its accessibility
tree and menus were read from the running app. Owner's frame for the fixes: an MVP, only
what is required; and Quick Look gives an extension no menu bar, so what lives in menus
would reach the app's window only.

Fixed:

- **Names for VoiceOver.** Buttons that show only a symbol were read by the symbol's name
  ("Square Grid, Three By Three" for Wireframe, "Format" for Cartoon, "Scan" for Fit view).
  Each now has its own; the sliders are named; the picture is an image called "3D model";
  the gizmo is one element whose actions are the six views.
- **One name.** The menu bar said "Preview3D" above "About 3D Preview"; `CFBundleName` is
  now the display name.
- **App menu.** About stands alone, Acknowledgements is beside Settings, and the Help item
  that would open nothing is gone. The Acknowledgements window is not reopened at launch.
- **Reduce Motion.** Auto-rotate set as a default does not start by itself; its button
  still turns it on.
- **Wording.** The settings section for the preview's controls is named for what it holds,
  the statistics are named as they are shown, tooltips are in sentence case ("Cartoon
  style", "Floor grid"), "color", "100%".

Left for after the MVP, by the owner's frame: viewer commands in the menu bar with
shortcuts, moving the camera from the keyboard, Open Recent and an Edit menu without text
commands, the settings shown both in the main window and in Settings…, letters on the
gizmo's negative axes, the rotate and smart-zoom gestures, other languages.

Checked in the built app: the accessibility tree reads the new names, the menu bar is "3D
Preview" with the items in that order, and a second launch opens the main window alone.
Not checked: VoiceOver by ear, Increase Contrast, Reduce Transparency, Full Keyboard Access.

## Neon Garden

The owner put the look of Astrina's design system ahead of the HIG. The viewer's controls,
the popovers and the app's three windows now use its palette and control styles
(`ViewerUI/NeonGarden.swift`); the design is in `docs/design/neon-garden-viewer.md`.

- Dark only: the controls set their own colour scheme, the viewer window a dark title bar.
- System segmented pickers and button toggles are replaced by the palette's own, which say
  "chosen" with a mint bar and weight as well as fill. Keyboard focus is a ring in the text
  colour.
- The default background is the palette's `#07110c`. `ViewerSettings.normalize` reads the
  earlier default `#1c1c1e` as the present one, since the app wrote it into the file on first
  launch without anyone choosing it; a user who did pick exactly that colour loses it.
- The spotlight behind the model is tinted with half the background's hue.
- Found on the way: launched with a file, the app opened Acknowledgements, as the only scene
  left to take the event. That window now refuses external events; the main window opens
  beside the viewer instead.

Checked in the built app and in Quick Look by screenshot, also with the light appearance
forced. Not checked: VoiceOver by ear, Increase Contrast, Reduce Transparency.

### Second pass: neon, grain, motion

Asked to bring it to the level of Astrina. Taken from there: the neon tube (gas, glass, ink),
grain kept to the edges, heavy type, motion with a reason. `Shape.neonTube` draws the tube;
the gizmo and the app's cube (`NeonCube`) draw it in a canvas. Grain, the floor's fade and the
axis-coloured centre lines are in the background and grid shaders (`FrameUniforms` gained
`gridAxisX` and `gridAxisZ`). Fonts are the system's: Astrina's IBM Plex is not bundled.

Found by screenshot in Quick Look: the wider statistics panel covered the end of the views
bar. Under 900 pt of width the statistics now stand above the bar's row
(`ControlsVisibility.statisticsFoot`). An animated model in a view under about 640 pt can still
have the statistics touch the animation bar.

Not measured: the cost of the blurred layers on an old machine. The cube redraws at 30 frames
a second while the app's window is on screen.

### Third pass: the hand

The owner found the second pass still far from Astrina. Looking at Astrina's own screens, the
difference was not glow but hand: cord frames that wander, tape, squared paper, a spiral
binding. `ViewerUI/Scrapbook.swift` has these. The viewer's frame is a hosting view over the
Metal view that refuses every click (`PassthroughHost`) and has no say in the view's size
(`sizingOptions = []`; without that an empty frame shrank the window to nothing). Controls
moved from 14 to 22 pt from the edge to stand inside the frame.

### Fourth pass: stickers, and no frame

The owner had the cord frame taken off the preview and asked for the controls themselves to be
scrapbook pieces. Buttons and switches are stickers (`ControlFace`), the chosen segment is a
piece of tape, panels are cut by hand (`WavyFrame` as the panel's shape) and taped down. The
passthrough layer stays for the opening light alone. Controls are back at 16 pt from the edge.

## Menus and keys

`ViewerCommand` (ViewerUI) names what the canvas controls do; `NativeViewerModel.status(of:)`
and `perform(_:)` apply the controls' own rules, and `NativeViewer` adds the camera's part
(orbit, zoom). The app's `ViewerCommands` puts them in the View menu and speaks to the viewer of
the key window (`ViewerFocus`). Keys are menu equivalents only: the viewer takes none itself,
because in Quick Look the arrows belong to Finder.

Open Recent is the app's own (`RecentModels`): `NSDocumentController`'s list stayed empty in
this SwiftUI app without documents.

Checked in the built app through the accessibility tree and key presses: ticks follow the
state, Cmd-7 and the arrows and Option-Cmd-G act, and a file opens again from Open Recent
after a relaunch.

### Fifth pass: the model first

The owner asked whether it was a wow; it was not, and the reason was the model: flat white, no
shadow, a warning as the headline, and controls in two styles. Astrina's own rules pointed the
way (the content is the design; tools carry no decoration).

- Rendering: a contact shadow and a pool of light on the floor (one quad, `shadowVertex` /
  `shadowFragment`, `FrameUniforms.shadowPlace` and `shadowSize`; `MetalRenderer.showShadow`),
  a rim light, a new clay matcap, eased highlights.
- Controls: glass throughout; stickers, tilts, hand-drawn glyphs and the scalloped gizmo are
  gone (`HandGlyphs.swift` deleted). They faded to 32% when the pointer rested; that
  was removed later: the controls are always shown in full.
- The notice is one line.

The shadow is the model's own shape: `encodeCover` draws it from straight above into an
r8 picture (max blending, fainter with height), every frame, and the floor patch samples that
with 17 taps. One more pass over the geometry a frame. Measured on a torus of a million triangles at
1280 x 720 (offscreen, 20 frames, this Mac): 6.4 ms a frame without the shadow, 6.9 to 7.0 with.

### Sixth pass: arriving

- The camera comes round to a model as it opens (`openOnTheModel`): the move starts with the
  first frame drawn, because Quick Look reads the file before the view is on screen.
- While a file is read the controls wait (alpha 0) and the app's neon cube turns in the middle
  (`LoadingView`); before, an empty room with live controls stood there for as long as a large
  FBX takes.
- The app's viewer windows remember their frame (`setFrameAutosaveName`).
- The demo is recorded from a part of the screen, with the file opened while it runs, so that
  the loading and the arrival are in it.
- The floor's sheen: the opaque parts are drawn once more through a mirror matrix about the
  floor (a hair below it), then a veil of the room's own colour is laid on the floor
  (`veilVertex` / `veilFragment`; `room()` is the background's colour at a point, shared with
  the background). `showShadow` switches the shadow, the pool and the sheen together. The
  model is drawn twice; not measured apart from the shadow.
