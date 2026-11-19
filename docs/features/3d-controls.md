# Feature: basic 3D controls

> This document describes the web renderer of 1.0.0, which has since been replaced by the
> native one (`docs/architecture/native-rewrite.md`). It is kept as the record of what the
> controls were specified to do; the paths under `renderer/` it names no longer exist.

> Design notes and decision log for the viewer controls, looks and formats, in the order
> things were decided. For what the app does today, see the [README](../../README.md) and
> the [changelog](../../CHANGELOG.md).

Status: implemented on local branch `feature/3d-controls` (no fork push, not part of PR #4).
Verified offscreen in a WKWebView with the production build.

**Keyboard shortcuts are not supported in Finder's Quick Look.** Tested by hand: Finder
keeps the keyboard while the preview is open (pressing Z jumps to a file starting with
"z"), so key presses never reach the preview. The toolbar is the only supported way to
use the controls. The key handler remains in the code for contexts where the page has
focus (the dev server in a browser), but no shortcut is shown in the UI.

## Raw request

> add basic 3D controls to the project

Follow-up from the interview: "Can we add all of these? but copy the Blender's design",
with a screenshot of a top toolbar of sphere icons and a shading dropdown
(wireframe, flat, smooth, textured).

## Current state

- All work lands in the TypeScript renderer (`renderer/src/main.ts`, `renderer/index.html`).
  The Swift extension only hands the file bytes to the page and needs no change.
- Already present: mouse orbit / zoom / pan (OrbitControls with damping), auto-framing
  on load, a floor grid, automatic playback of the first animation clip, and a skeleton
  view for mesh-less files (VRMA, skin-less FBX).
- Missing: any on-screen control, keyboard shortcut, or way to get back to the initial view.

## Decisions

| Topic | Decision |
|---|---|
| Scope | Reset / fit view, view presets, display toggles, animation playback, shading modes |
| Shading modes | Wireframe, flat shaded, smooth shaded, textured (default) |
| Layout | Icon toolbar along the top, auto-hiding when the pointer is idle; animation bar at the bottom, shown only for animated models |
| Look | Blender-style: dark translucent bar, sphere icons for shading, dropdown under the active shading icon |
| Keyboard | Requested Blender-style keys; not deliverable in Finder's Quick Look (see Status) |
| Animation | Play/pause, clip picker when more than one clip, scrubber |
| Persistence | None. Every preview opens textured, grid on, auto-rotate off |
| Rollout | Local feature branch; install on this Mac; publish nothing yet |

## Requirements

### Toolbar (top, auto-hiding)

1. Shading button showing the current mode's sphere icon; clicking opens a vertical
   dropdown with the four modes. Selecting one applies it immediately and closes the dropdown.
2. Fit view button: returns the camera to the framed view computed at load.
3. View presets: Front, Back, Left, Right, Top. The camera moves to that side of the
   model's bounding box, keeps the model framed, and animates briefly (about 250 ms).
4. Grid toggle (on by default).
5. Auto-rotate toggle (off by default). Any manual orbit keeps working while it is on.
6. (Superseded: the controls no longer fade.) The bar fades out after about 2.5 s without pointer movement and returns on pointer
   movement or a key press. It stays visible while the pointer is over it or a dropdown is open.
7. In narrow windows (under roughly 360 px) the five presets collapse into one dropdown.

### Animation bar (bottom, only when the model has clips)

8. Play/pause button; playback starts playing, as today.
9. Clip dropdown, shown only when there is more than one clip.
10. Scrubber showing the position in the current clip; dragging it seeks and pauses.
11. Hidden entirely for models without clips. Follows the same auto-hide rule as the toolbar.

### Keyboard (browser/dev only; not available in Finder's Quick Look)

| Key | Action |
|---|---|
| `1` / `Ctrl+1` (number row and numpad) | Front / Back |
| `3` / `Ctrl+3` | Right / Left |
| `7` | Top |
| `Home` or `.` | Fit view |
| `Z` | Cycle shading mode |
| `G` | Toggle grid |
| `R` | Toggle auto-rotate |
| `P` | Play / pause |

Space, Escape and the arrow keys are not used: Quick Look owns them (close, close,
next/previous file).

### Shading mode behaviour

- Textured: the model's own materials, exactly as today.
- Smooth: a neutral grey lit material on every mesh, no textures.
- Flat: the same with faceted (per-face) shading.
- Wireframe: the neutral material drawn as wireframe.
- Switching back to Textured restores the original materials exactly.
- Skinned and morph-target meshes keep deforming in every mode.
- VRM outline passes are hidden in the three non-textured modes.
- For mesh-less files (skeleton view) the shading button is disabled.

## Acceptance criteria

- [ ] A textured GLB, a VRM 1.0, a VRM 0.x and an FBX each switch through all four
      shading modes and return to an image identical to the initial textured render.
- [ ] After orbiting, zooming and panning, Fit view restores the initial framing.
- [ ] Each preset shows the expected side: Front shows the face of both VRM 0.x and
      VRM 1.0 sample models.
- [ ] Grid and auto-rotate toggles reflect their state visually (pressed/unpressed).
- [ ] An animated GLB shows the animation bar; play/pause, scrubbing and (with two or
      more clips) clip switching work. A static model shows no animation bar.
- [ ] The toolbar fades when idle and returns on pointer movement; it never hides
      while a dropdown is open.
- [x] Not met in Finder: keyboard shortcuts do not reach the preview (platform behaviour).
      Space still closes Quick Look.
- [ ] Opening a second file starts from defaults (textured, grid on, auto-rotate off).
- [ ] The production build still carries the Content-Security-Policy and makes no
      network request; all icons are inline.
- [ ] Every control has an accessible name and a tooltip; focus order follows the bar.
- [ ] `tsc --noEmit` and `npm run build` pass; `./scripts/build.sh` succeeds.

## Technical direction

- Split `main.ts`: keep scene/loader code there, add `controls/` modules for the
  toolbar, shading, view presets, animation bar and keyboard map. No new dependencies;
  plain DOM and CSS, inlined by the existing single-file build.
- Icons as inline SVG in the bundle. The CSP (`default-src 'none'`, inline script and
  style only, `blob:`/`data:` images) forbids icon fonts or remote assets.
- Shading: keep a map from mesh to its original material(s); swap in one shared
  override material per mode and restore from the map. Dispose override materials
  when a model is replaced.
- Presets and fit view reuse the bounding-box maths in `frameModel`; store the framed
  camera state at load for Fit view.
- Animation: extend the existing `AnimationMixer` handling to keep all clips, the
  current action and its time; the scrubber sets the action time while paused.
- Auto-hide and the preset animation respect `prefers-reduced-motion`.

## Risks and open points

- **Keyboard focus in Quick Look.** Key events may not reach the web view until the
  user clicks inside the preview, and Quick Look may intercept some keys first. To be
  verified early in the real extension; if keys cannot be delivered reliably, the
  shortcuts ship as "after clicking the preview" and the toolbar remains the primary path.
- **MToon in non-textured modes.** VRM toon materials and outlines need the override
  path checked on both sample models.
- **No automated tests exist** in the renderer. Verification is by the offscreen
  WKWebView snapshot approach used for the security work plus manual checks in Quick
  Look; adding a test runner is out of scope unless requested.

## Settings (added after first hands-on test)

Request: "all of them should be configurable via the installed application".

The host app window (and its Settings… menu item) now has a settings form:

| Group | Settings |
|---|---|
| When a preview opens | Default shading mode, floor grid, auto-rotate, autoplay animations |
| Appearance | Background colour, solid shading colour, lighting strength (20% to 200%) |
| Toolbar buttons | Show or hide Shading, Fit view, View presets, Grid, Auto-rotate, Animation bar |

- Stored as `~/Library/Application Support/Spacebar3D/viewer-settings.json`, which both
  sandboxed targets reach through a sandbox path exception entitlement (read-write for the
  app, read-only for the extension); see `Spacebar3D/Shared/ViewerSettings.swift`.
  An app group was tried first and does not work in local ad-hoc signed builds (no team
  identifier). Path exceptions are fine for Developer ID distribution but would not be
  accepted on the Mac App Store.
- The extension posts them to the renderer as a `settings` message before the model;
  `renderer/src/settings.ts` validates every value and falls back to defaults.
- Changes apply the next time a file is previewed. "Restore Defaults" clears them.
- This supersedes the earlier "Persistence: none" decision for defaults; in-preview
  changes (clicking a toolbar button) are still not remembered.
- Not configurable (not requested): auto-hide delay, toolbar size and position.

Also fixed: the toolbar never faded in the real Quick Look panel because WebKit
re-dispatches mouse-move events for a stationary pointer; identical positions are now ignored,
and the bar hides at once when the pointer leaves the preview.

**To confirm by hand:** that a colour chosen in the app reaches the preview.

## Layout revision: right-hand sidebar

Request (with a reference screenshot): add the controls shown there and merge the
existing ones into a vertical sidebar on the right.

- The top toolbar is gone. Top right now holds, from left to right: model statistics
  (triangles, vertices) and an axis gizmo. Clicking an axis handle looks at the model
  from that side; this replaces the F/B/L/R/T buttons and adds a bottom view.
- Beneath the gizmo, a vertical pill: shading (menu opens to the left), fit view,
  lighting (slider, 20% to 200%), perspective / orthographic, grid, auto-rotate.
- The animation bar stays along the bottom.
- Everything fades together when idle. In small previews the statistics, then the gizmo,
  are dropped so the pill always fits.
- Settings gained toggles for the gizmo, statistics, lighting and projection buttons;
  "View presets" became "View gizmo".

Differences from the reference screenshot, on purpose:

- Topology was first left out because the loaders triangulate on import; it was added
  later by reading the polygons from the file itself (see the statistics revision).
- Orthographic view is a very long lens (2 degree field of view) on the same camera
  rather than a true orthographic projection. Perspective distortion is negligible and
  framing, orbit and zoom behave the same in both modes.

## Gizmo and statistics revision

- The gizmo and the statistics text scale with the preview (larger in big windows and
  full screen), and are larger than before at every size.
- Dragging on the gizmo orbits the camera freely, with the same directions as dragging
  the model; clicking an axis handle still snaps to that view.
- Statistics (final form, after feedback): three rows in the bottom-right corner:
  Topology, Faces, Vertices. Hidden in previews narrower than 560 px.
- Topology is read from the file, not the scene, because the loaders triangulate on
  import (`renderer/src/topology.ts`): OBJ `f` lines, and FBX `PolygonVertexIndex`
  arrays (binary, including compressed arrays, and ASCII). It reports Triangle, Quad,
  N-gon or Mixed; Faces and Vertices are then the authored polygon and position counts.
  glTF, GLB and VRM store triangles only, so they always read Triangle with counts from
  the scene. If an FBX cannot be parsed the stats fall back to triangle counts.

## Perspective / orthographic switch removed

Removed on request after trying it: the button, its setting and its shortcut are gone.
The camera is always perspective. Mentions of it earlier in this document are historical.

## Controls always visible

Final decision after hands-on use: the controls no longer fade when the pointer is idle.
They stay visible for as long as the preview is open; the auto-hide described earlier in
this document was removed. Small previews (below) still show the model only.

## Small previews

Requested: no controls in Finder's preview column. An extension is not told which host
it is in, so this is decided by size: below 480 px wide or 340 px tall, the sidebar,
gizmo, stats and animation bar are all hidden and only the model shows. Mouse orbit,
zoom and pan still work there. (The stats alone also hide below 560 px wide.)

## OBJ files

Reported: "OBJ doesn't show the controls at all".

- Cause: the extension did not handle OBJ, so macOS showed its own preview.
- Added: an OBJ loader in the renderer and `public.geometry-definition-format` in the
  extension's supported types. A companion `.mtl` and its textures never reach the
  preview, so OBJ models use a neutral grey material.
- **Still not working in Finder.** macOS keeps using its built-in OBJ preview even though
  the extension is registered for the exact OBJ type (confirmed in the LaunchServices
  database); when an OBJ is previewed, the extension process is never started. Quick Look
  appears to give its built-in handler priority for this type, which an extension cannot
  override. The loader works in the renderer itself (verified offscreen).

### Workaround: open in the app

Because Finder will not hand OBJ to the extension, the host app can now open model files
in its own viewer window, using the same renderer page, sidebar and saved settings:

- File > Open… (Cmd-O), the "Open a Model…" button in the main window, dropping files on
  the Dock icon, or "Open With > Spacebar 3D" in Finder.
- Supports .obj, .glb, .fbx, .vrm and .vrma. The app registers as an alternate viewer
  only, so it never becomes the default app for these types.
- The window has keyboard focus, so the viewer's shortcuts work there.
- Reading the file and building the hand-off script moved to
  `Spacebar3D/Shared/ModelPayload.swift`, shared with the extension (same 128 MB cap).
- The app gained the `network.client` entitlement: WKWebView needs it even for a local
  page. The page's CSP still blocks all network requests.

Verified by launching the built app with an OBJ and a GLB and capturing its windows.

## Non-goals

- Remembering in-preview toolbar changes between previews.
- Lighting or background controls, measurement tools, exploded views, screenshots.
- Editing or exporting models.
- Changes to the Swift extension or the release pipeline.
- Publishing: no fork push, no upstream PR, PR #4 untouched.

## Task breakdown

1. Branch `feature/3d-controls` from local `main`; restructure `main.ts` so scene,
   loaders and model state are importable (no behaviour change).
2. Toolbar shell: markup, styles, auto-hide, tooltips, accessible names, narrow layout.
3. Fit view and view presets, with the animated camera move.
4. Grid and auto-rotate toggles.
5. Shading modes with material swap/restore, including VRM outlines and skinned meshes.
6. Animation bar: play/pause, clip picker, scrubber.
7. Keyboard map; verify focus behaviour inside the real Quick Look extension.
8. Verification pass against the acceptance criteria (GLB, VRM 1.0, VRM 0.x, FBX,
   animated GLB), CSP check, full build, local install.

## Revision: Tripo-style looks bar

The shading menu in the sidebar is replaced by a bar along the bottom centre that works
like the one in Tripo Studio's viewer.

| Part | Behaviour |
| --- | --- |
| Wireframe | A toggle of its own: dark wire lines drawn over whichever of the three views is showing, as in Tripo. It is not combined with styles: choosing a style turns it off, and pressing it while a style is on switches to Textured View with the wireframe on. For OBJ and FBX files that contain quads, the edges added when the loader splits each polygon into triangles are left out, so the lines follow the file's polygons (the polygon sizes are read from the file and matched to the triangles in order); GLB / VRM files store only triangles, so every triangle is outlined. |
| Views | Solid View, Textured View, Normal. Exactly one is on; Textured is the default. |
| View Settings | Panel with Shading (Flat / Smooth) and, in Textured View, PBR on / off (a pill switch) with Metallic and Roughness, which are dimmed while PBR is off. Stays open until closed. |
| Styles | Unlit, Cartoon Style, Sketch Style, Hologram Style. Optional, layered on the view; pressing the active one turns it off. |

- Cartoon and sketch draw an ink outline (the mesh drawn again, back faces pushed out
  by a fixed width on screen). Sketch is smooth paper-white in the light, with a thin yellow fringe where light turns to shadow and fine ink hatching (rising to the right) in the shadow. Cartoon keeps the textures with gentle tone steps and a thin outline.
- Hologram (`hologram.ts`) follows how Tripo's behaves. Turning it on plays an 8 s intro,
  starting just after the model's first frame: the model is built from the bottom up at a
  steady pace behind a bright ragged front, the part not yet built shows as sparkling grains,
  thin beams (up to 44 at once) fire onto the front from four points around the model, and
  columns of characters fall to its left. It then settles into a translucent shell that is
  dark teal where the surface faces the eye (with a little of the model's own colour
  showing through) and bright where it turns away: a glowing rim and a fine bright grid (about
  44 cells across) on those turned-away surfaces. Front surfaces hide what is behind them.
  - Scan lines: one thin main line rises bottom to top at the pace of the build (it is the
    build front during the intro) and then keeps repeating that trip more slowly, once every 20 s. Much thinner secondary
    lines are spaced evenly over the model and move with it; there is one line per eighth
    of the model's longest side (2 to 10), so the count follows the model's height.
  - Glitches: six 0.3 s bursts per pass of the main line, in which the model is cut into about 90
    thin slices that shift sideways in alternating directions (fine zigzag outlines), leaving
    one calm band at a random height;, one
    in the middle half of each sixth of the pass, so they are never close together.
  - With reduced motion the intro and glitches are skipped.
  - A bloom pass (`bloom.ts`, strength 0.1 / radius 0.3 / threshold 0.55: a tight halo
    around the brightest parts only) adds the glow; it runs only while this style is on and keeps the canvas
    see-through so the chosen background still shows.
  - Behaviour and timings were first taken from a published study of Tripo's effect
    (github.com/morganID/tripo-hologram-effect) and then tuned by eye; the shaders are our own.
- Unlit and cartoon keep the model's textures in Textured View and use the solid colour
  in Solid View. PBR off shows base colour with plain diffuse lighting.
- Metallic / Roughness start from the model's own values and override every material once
  moved; each new preview starts from the authored values again. Models whose materials
  have no such values (most FBX and OBJ files) get a PBR stand-in while a slider is in use,
  and overridden materials reflect a neutral studio environment so metal has something to
  show. PBR, Metallic and Roughness are shown only in Textured View with no style on,
  since they do nothing elsewhere.
- Controls are worked by pointer without taking keyboard focus (sliders are dragged by our
  own handler): a focused control makes the web view take the keyboard in Quick Look, and
  Space then stops closing the preview.
- Settings: "Look" picks what a preview opens with (a view, or Textured plus a style);
  "Looks bar" shows or hides the bar. Old values (`textured`, `smooth`, `flat`, `chrome`,
  `custom`) migrate to `original` / `clay`.
- The animation bar sits above the looks bar; small previews hide both.

## Revision: controls reset when the preview closes

Quick Look can keep the preview's page alive after Space closes it and show it again for
the same file. When the preview goes away (the page becomes hidden, and the extension also
sends a `ql-reset` event from `viewDidDisappear`), the look, View Settings, grid,
auto-rotate, lighting and camera go back to the defaults from Settings, so the next showing
starts fresh.

## Revision: tooltips, background gradient, typed values

- Tooltips: every button shows its name at once in a dark bubble (above buttons in the
  bottom bars, to the left of the ones in the right-hand pill) instead of the system's
  delayed tooltip.
- Background: the colour from Settings is drawn as a soft spotlight, a little lighter
  behind the model and darker towards the corners.
- Metallic and Roughness can be typed into their boxes (0 to 1). Typing takes the
  keyboard, so Space does not close the preview while a box is being edited; Return
  applies the value and Escape cancels, and both leave the box.

## Revision: FBX textures stored beside the file

FBX files often keep their textures in a folder beside them with the same name and the
extension `.fbm` (Tripo's FBX export does). The preview is handed only the `.fbx`, and the
sandbox hides everything else, so such models used to load without colour.

- The app and the extension now carry a read-only sandbox exception for the home folder
  (`temporary-exception.files.home-relative-path.read-only` = `/`). This is a broader read
  permission than before, chosen deliberately; nothing is written and nothing is sent
  anywhere (the page's CSP still blocks all network requests).
- `ModelPayload.texturesJSON(beside:)` reads only plain image files (jpg, png, webp, gif,
  bmp) directly inside that one `.fbm` folder, at most 32 files, 32 MB each, 96 MB in all.
- The page receives them with the model and matches the file names the FBX refers to by
  their last path component. Textures that are still missing are dropped as before.
- Files outside the home folder (external drives) are not covered and load without textures.
- When that folder has exactly one image named like a metallic map and/or one named like a
  roughness map (Tripo's `Metallic.jpg` and `Roughness.jpg`), the FBX's textured materials
  are rebuilt as PBR materials that use them, with faint reflections of a neutral studio
  and the strongly coloured parts of the colour image glowing, so painted lights stay vivid
  while grey and black paint stays dark.
  Roughness is kept at satin or rougher (0.62) so the surface does not look wet; the
  Roughness slider lifts that limit.
  FBX itself has no standard slot for these, which is why they are found by name.

## Revision: matched against Tripo screenshots of an untextured model

- Unlit and Cartoon Style need textures: on a model with none they are dimmed, do nothing,
  and their tooltip reads "Supported for textured models", as in Tripo.
- Hologram: the shell is bright mint whatever the model's colour (a dark textured model is
  only a little deeper, with its strongly coloured parts faintly showing) and is see-through
  again, so inner parts and the far side show as in an X-ray.
- Hologram build: the beams come from four points far outside the model and cross the whole
  view as thin lines; characters fall on both sides of the model.
- Textured View is hidden on a model with no textures, which opens in Solid View instead
  (also as in Tripo). Such a model's plain material colours are therefore not shown.

## Revision: sketch and cartoon matched on the textured ship

- Sketch: shading comes from a fixed light at the upper left of the view, so about half the
  model is hatched (bold strokes rising to the right); yellow marks lit silhouette edges
  and the line where light turns to shadow.
- Cartoon: the model's colours also glow a little so dark paint reads as flat colour, and
  the outline is thicker.
- Hologram build, after a frame-by-frame look at Tripo's: a dense bundle of about 180 thin
  beams from four points far out to the sides at the height of the model's top; they slant
  down onto the build front, run on a little past it, and flatten as the front reaches the top.

## Revision: side-by-side pass against Tripo on the textured ship

- Wireframe: thinner black lines, so a dense mesh is no longer darkened as a whole.
- Sketch: grey paper, a wider hatched area with thin grey strokes in half-shadow and heavy
  ink in full shadow.
- Cartoon: brighter flat colour (lighter tone steps, stronger own-colour glow).
- Unlit: the colour image is shown at 1.5x exposure.
- Cartoon also pushes colour saturation up (1.6x), which turns the ship's hull navy as in Tripo.
- Textured View of such FBX models gets a cool, slightly deeper cast on lit surfaces (blue-black hulls, as in Tripo). Sketch strokes rise to the right, as Tripo's do.

## Revision: STL

- STL files (binary and text) open: bare triangles with a neutral material (vertex colours
  when the file has them), turned from STL's Z-up to the viewer's Y-up. With no textures,
  they open in Solid View and Textured View, Unlit and Cartoon are unavailable.
- Like OBJ, macOS has its own STL preview and may keep using it for the Space bar; the
  in-app viewer (File > Open…, Open With) always works.

## Revision: USDZ, and three.js 0.171 to 0.187

- three.js was upgraded to 0.187 because its `USDLoader` reads the binary `.usdc` inside
  real USDZ files (Tripo's, Apple's); the loader in 0.171 read text USD only.
- USDZ files open with their materials and textures. Detected by the zip signature.
- macOS previews USDZ itself (AR Quick Look) and will most likely keep doing so for the
  Space bar; the in-app viewer (File > Open…, Open With) is where this is expected to work.
- After the upgrade GLB, FBX, VRM 0.x and 1.0, OBJ, STL and every look were re-run with
  no errors. three.js now logs a deprecation warning for `THREE.Clock` on start; harmless.

## Revision: OBJ, STL and USDZ in Finder's Space-bar preview

macOS ships preview extensions that claim the same types as ours and prefers them:
`com.apple.HydraQLPreviewExtension` (OBJ, STL, PLY, USD, MaterialX, Alembic) and
`com.apple.RAQLPreviewExtension` (USDZ, `.reality`). An extension cannot outrank them.

`scripts/prefer-spacebar3d.sh on` switches those two off for the current user with
`pluginkit -e ignore`, after which Finder uses Spacebar 3D for OBJ, STL and USDZ
(confirmed on macOS 27 with the ad-hoc signed build). `off` restores the default, `status`
shows the current state. It is all-or-nothing per extension: while on, PLY, USD, MaterialX
and Alembic get macOS's plain SceneKit preview, USDZ has no AR view, and `.reality` files
have no preview. The setting may be reset by a macOS update.

## Revision: 3MF, PLY, USD, DAE, 3DS and glTF with separate files

- New formats: 3MF, PLY (meshes, and point clouds when the file has no faces), USD / USDA /
  USDC, DAE (Collada, with its animations), 3DS, and `.gltf` whose buffers and images are
  separate files. 3MF, STL and 3DS are turned from Z-up to Y-up.
- The page now gets the file's extension along with its bytes. The bytes still decide
  wherever a format has a clear signature; the extension settles look-alikes (3MF and USDZ
  are both zip archives).
- Files beside the model (`ModelPayload.texturesJSON`): for FBX, DAE, 3DS and glTF the
  model file is searched for names ending in an image extension (and `.bin` for glTF), and
  those files are read from the model's folder, the path as written when it is relative,
  the `.fbm` folder, and the usual texture folders (`textures`, `images`, `maps`, …). At
  most 64 files, 64 MB each, 128 MB in all, and never from outside the model's folder.
  Targa images are decoded by the page.
- One loading manager serves every loader, so all of them find those files the same way.
- macOS has no file type for 3MF, so nothing competes for the Space bar there. PLY and USD
  belong to Apple's Hydra extension (see the Finder section); DAE and glTF are also covered
  by Apple's generic SceneKit preview, and whether ours wins there is untested.

## Revision: compressed glTF (Draco, Meshopt)

- Draco-compressed `.glb` / `.gltf` load. The decoder is three.js's plain-JavaScript build,
  bundled into the page as text and run in a worker started from a `blob:` URL; nothing is
  fetched. This grows the page from about 1.1 MB to 3.4 MB (the WebAssembly build would be
  smaller but cannot be inlined by the single-file build).
- Meshopt decoding is wired into the glTF loader; its decoder is WebAssembly. It has not
  been tried on a real Meshopt-compressed file (none was at hand).
- The page's Content-Security-Policy was loosened for this: `script-src` gains
  `'wasm-unsafe-eval'` (WebAssembly compilation only, not `eval`) and `worker-src blob:` is
  added. Network access is still blocked entirely.
- Not covered: KTX2 / Basis textures, which need a further WebAssembly transcoder.

## Revision: Blender files (.blend)

- `.blend` files open through the `blendfile` npm package (MIT, pinned to 0.1.1, with
  `fzstd` and `fflate`), a parser for the file container; Blender itself is not involved.
  The package source was read before it was added: it only parses bytes (no network,
  `eval`, DOM or process access, no install scripts), and the installed copy has the same
  checksum as the one reviewed.
- Shown: the visible mesh objects of the first scene at their saved transforms, faces as
  modelled (so statistics and the wireframe show real quads and n-gons), smooth / flat
  shading per face, and per material the Principled BSDF's colour, metallic, roughness and
  emission, plus the base-colour image when it is packed into the file.
- Not shown: modifiers (Subdivision, Mirror, …), curves, text, armature poses and
  animation, node-built materials, and images kept in separate files. Objects positioned
  by bones or constraints can appear in the wrong place.
- Works for files saved by Blender 2.80 and later, compressed or not. Older files fail
  with the "Failed to load" message.
- Blender ships no Quick Look preview of its own, so nothing competes for the Space bar.

## Revision: fixes from the branch review

- Files beside the model are compared by their real location: a symbolic link (a linked
  image, or a linked `textures` / `.fbm` folder) that leads outside the model's folder is
  not read. Links that stay inside the folder still work.
- File names with non-ASCII characters (for example `テクスチャ.png`) are found in FBX, DAE,
  3DS and glTF references.
- Looks, lighting and the camera reset only when the preview is closed (the host's
  `ql-reset`), not when the window is merely hidden or minimised.
- Textured View is offered when the model has an image, vertex colours, or material
  colours that are not a single neutral grey. Only plain grey models open in Solid View
  with Textured View hidden; View cycling skips hidden views.
- The app's settings are held in one shared model, so the main window and the Settings
  window no longer overwrite each other's edits.
- The "Solid view colour" setting tints Solid View (the default grey leaves it as it was);
  the unused wireframe-only view code is gone.
- FBX Metallic / Roughness images load through the shared asset manager, so the
  missing-texture clean-up waits for them.
- The polygon wireframe picks the source face list that fits a mesh most closely, instead
  of the first one within tolerance.
- The Hologram glow is sized from the canvas size and pixel ratio when it is first built.

## Revision: fixes from the second review

- Escape in a Metallic / Roughness value box discards what was typed (Return applies it).
- Normal View has no Unlit or Cartoon version. Choosing Unlit or Cartoon from Normal View
  switches to Textured View with that style; choosing Normal View (button or `Z`) from
  Unlit or Cartoon leaves the style. The pressed buttons always match what is drawn.
- The animation scrubber goes back to following playback when a drag ends without a
  pointer release (cancelled by the system, or the window losing focus mid-drag).
