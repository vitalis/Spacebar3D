# Spacebar 3D: the Neon Garden interface

Status: implemented. Code: `Packages/Spacebar3DKit/Sources/ViewerUI/NeonGarden.swift` (palette,
control styles), `NativeViewerControls.swift` (the controls), `Scrapbook.swift` (the hand-made
pieces), `RenderMetal` (the room and the light), `Spacebar3D/App/` (the app's windows).
Tests: `NeonGardenTests`, `ControlsViewTests`, `ViewerCommandTests`, `StyleRenderTests`.

The look is Neon Garden, the design system of Astrina. Two of its rules decide everything here:

- **The content is the design.** In Astrina the number is the design, not a gauge round it. Here
  the model is. The work goes into how the model is lit and where it stands.
- **Tools are Bulletin, the hero is Postcard.** Astrina caps decoration per surface: a utility
  card gets grain and nothing else (no tape, no stamps, no warm marks); only the hero gets the
  hand-made pieces. So the viewer's controls are plain glass, like Astrina's own tab bar, and
  the cord frame and tape appear once, round the app's mark.

## 1. Principles

1. **Dark only**, whatever the system's appearance.
2. **The model owns the picture.** Controls stay at the edges, in full: they never fade.
3. **Everything on the canvas.** Quick Look has no menu bar; the app adds menus and keys.
4. **One Signal**: at most one chartreuse button on a screen, for the act it waits for.
5. **Mint means on. Blue means a fact.** Never colour alone: a state also differs by shape.
6. **Motion has a reason**, and all of it stands still with Reduce Motion.
7. **The settings form follows the HIG** (the owner's decision). English only.

## 2. Colours

| Token | Value | Use |
|---|---|---|
| background | `#07110C` | The room; window background; the well of a chosen control |
| surface | `#0E1C14` | Panels (72% over a blur), popovers |
| surface-2, surface-3 | `#13251B`, `#1A3024` | Hover and pressed |
| text, text-2, text-3 | `#F1F4F0`, `#AEB9B0`, `#8A978D` | Text; secondary; unavailable |
| border | text 34% to 10%, top to bottom | The lit edge of a panel |
| signal | `#CFFF2E` (pressed `#A6E800`) | The one primary action |
| mint | `#A6E3A7` | On, chosen |
| info | `#B8D3FF` | Figures; the Z axis; the cord frame in the app |
| warm, success | `#FF6A3D`, `#2DE08F` | The X and Y axes |
| warm-2, mint-2 | `#FF3D89`, `#84BD6B` | Tape, in the app's window only |
| warm-ink | `#F7EFE8` | The line of ink inside a neon tube |
| danger | `#FF3D3D` | A failed save |

No caution colour: a warning is a triangle and its words. Text, mint and info reach 4.5:1 on
every surface; `NeonGardenTests` checks it.

## 3. The room and the light (`RenderMetal`)

- **Background.** A soft spotlight that takes half the background's hue, film grain towards
  the edges only, fixed to the picture.
- **Pool of light.** On the floor under the model, four times its half width, 60% of the
  spotlight's colour at the middle. It is what lets a shadow show in a dark room. None in a
  light room.
- **Shadow.** The model's own shape, as lit from straight above: it is drawn from above into a
  256-point picture (darkest where a part stands on the floor, down to 18% for parts three
  quarters of its height up), which a patch of floor takes, softened, as its darkness (72% at
  most). It moves with an animated model. Not drawn from below the floor or in the Hologram
  style.
- **Sheen.** The floor is a little glossy: the model shows in it upside down, at most 24%
  by its foot and gone by three half-widths away. Not in a see-through preview, the Hologram
  style or from below.
- **Rim light.** A cool light from behind on the edges that turn away, in the Textured view
  and in the Solid view's clay.
- **Clay (Solid).** A studio matcap: a key from the upper left that stops short of white, a
  cool edge on the far side, a little of the room's colour thrown up from below.
- **Highlights are eased** towards white above three quarters instead of clipping.
- **Floor grid** (when on) fades out at its edge; its centre lines are X (warm) and Z (info).

## 4. Layout of the viewer

```
┌──────────────────────────────────────────────────────────────┐
│ (△ Textures not shown  [Show Textures…])            ( gizmo )│
│                                                       ( fit )│
│                                                       ( sun )│
│                          model                        (  #  )│
│                                                       ( rot )│
│                                                  (statistics)│
│        ( Solid  Textured  Normal  ▢ | ◐ 🖌 ✎ ✦ | ≡ )          │
└──────────────────────────────────────────────────────────────┘
```

Controls stand 16 pt from the edge. The statistics stand in the bottom right corner on the
views bar's own line. Where the bar, in the middle, leaves them too little room, the bar (and
the animation bar over it) moves left by what is missing; only where the two cannot stand side
by side do the statistics go above the bar's row. A preview too small for controls shows none.

**Glass.** Panels are the system's Liquid Glass (`glassEffect`, regular, tinted with the
surface colour at 40%), in the panel's own shape; popovers take the same tint. With Reduce
Transparency on they are the solid surface with its thin edge and shadow.

**Always there.** Controls are shown in full with the model and stay so: nothing fades when
the pointer rests or leaves. They are hidden only while a file is being read.

**Loading.** While a file is read there are no controls: the app's mark (`NeonMark`: the
icon's own picture, its dark made clear by `scripts/make-mark.swift`) comes forward in the
middle of the room, its light breathing, a bead of light running round the rails
(VoiceOver: "Loading").

**Opening.** The camera arrives: from 22% farther off and 24° to one side it comes round to
the front in 1.1 s, easing to rest. A breath of mint light opens behind the model and fades in
0.9 s; panels rise in. With Reduce Motion the camera is simply there, and a change of view
jumps instead of gliding.

## 5. Components

All controls are glass, as Astrina's tab bar is.

**Panel.** Surface at 72% over a thin blur, radius 24 (a single row is a capsule), an edge lit
from above, a soft shadow.

**Control.** A 32 pt disc round a picture (a pill round a word).

| State | Looks |
|---|---|
| Rest | Only its picture, in text 86% |
| Hover | A surface-3 disc under it |
| Pressed | Shrunk to 90% |
| On | A dark well with a thin mint edge; the picture mint, semibold, glowing |
| Cannot be used | A dashed edge, the picture dim |
| Keyboard focus | A 2 px ring in text colour, 4 pt clear |

**Segments** (Solid / Textured / Normal; Smooth / Flat). Words in a row. The chosen one sits in
the same dark well with a mint edge and is written in mint; the well slides to the next choice.

**Signal button.** Chartreuse, heavy dark label, a warm-ink line inside its edge, a neon tube
round it whose light breathes. Only in the notice.

**Notice.** One line: a triangle, "Textures not shown", and the Signal. Why is in the tooltip.

**Light panel** (the sun button). A strip of panorama showing the mood and its two lights,
turned as the light is; a Mood pop-up; Brightness (20 to 200%) and Direction (0 to 360°)
sliders with their figures in info; a "Turn the light" switch (once round in 20 s).

| Mood | Light |
|---|---|
| Glasshouse | Neutral white from two sides: what a model opens in |
| Dawn | A low pink sun, cool blue from the sky |
| Noon | A hard white sun overhead, blue sky |
| Golden Hour | Amber from the side, violet in the shade |
| Overcast | Soft grey light from the whole sky, almost no sun |
| Moonlit | A blue moon, a little warm light from one side |
| Neon | The garden's own: chartreuse from one side, magenta from the other |

A mood is a main light, a fill light and the colours of sky, ground and reflections, worked
out in code (`RenderMetal/Surrounding.swift`), not a photograph. Moods act on the Textured
view and the Cartoon style; the Solid view follows Brightness only. They last for the preview
and are not saved.

**Gizmo.** A 100 pt glass disc. Each axis is a neon tube from a pale pin to a lit bead with
its letter (X warm, Y success, Z info); the back half is a faint dashed line ending in a hollow
dashed ring. Nearer ends are larger and lie over farther ones; the end under the pointer grows
and gets a ring. Click an end for that view, drag to orbit.

**Statistics.** Labels in 10 pt heavy tracked capitals in text 90%, values in 13 pt bold
monospaced info. They are read, not used, so they keep their full strength.

**Icons** include Wireframe `cube.transparent`, Unshaded `circle.lefthalf.filled`,
Anime `anime-eye`, Cel-Shaded `hexagon.lefthalf.filled`, Retro `gamecontroller`, Voxel Art `square.3.layers.3d`, Hologram `sparkles`, view settings
`slider.horizontal.3`, fit `viewfinder`, light `sun.max`, grid `grid`, auto-rotate `rotate.3d`.
Each has a tooltip and a VoiceOver name.

## 6. Behaviour

- Choosing any style on a model with textures also chooses the Textured view.
- Styles that need textures cannot be chosen on a model without them.
- The default background is `#07110C`; a settings file still holding the earlier default
  `#1c1c1e` follows it; any other stored colour is kept.

## 7. The app's windows

- **Main window.** A page of squared paper (faint mint lines, each only partly there). The
  app's mark is a postcard: the icon's chameleon stepping out of its file of two
  neon rails (`NeonMark`, the icon's picture with live light on it), in a frame of two wandering rails of info-blue neon cord
  (`NeonCordFrame`), held by a strip of magenta tape, the whole 1.5° askew. Then the title in
  40 pt black weight, one line ("Select a 3D model in Finder and press Space."), and the
  settings. No Signal: the window waits for nothing.
- **Settings.** The HIG rules here: system controls in the user's accent colour, a standard
  form, introductory labels ending in a colon, a Look pop-up of one-word names in three
  groups, explanations on a second line under their checkbox, a slider with end marks, a
  standard Restore Defaults button. The headings are written on tape (14 pt heavy capitals on
  mint-2, info and warm-2 strips); that and the dark page are the theme's.
- **Acknowledgements.** Monospaced text in text-2 on background.
- **Viewer window.** Dark title bar.

## 8. Menus and keys (the app)

Everything the canvas controls do is in the menu bar with the same rules (`ViewerCommand`).

| View menu | Key |
|---|---|
| Solid, Textured, Normal (ticked) | Cmd-1, 2, 3 |
| Wireframe (ticked) | Cmd-4 |
| Unshaded, Anime, Cel-Shaded, Retro, Voxel Art, Hologram (ticked) | — |
| Floor Grid, Auto-Rotate (ticked) | Option-Cmd-G, Option-Cmd-R |
| Zoom to Fit, Zoom In, Zoom Out | Cmd-0, Cmd-+, Cmd-- |
| Look From > Front, Back, Left, Right, Top, Bottom | Option-Cmd-1 to 6 |
| Orbit > Left, Right, Up, Down | the arrow keys, while the model has the keyboard (taken by the viewer, not the menu, so a slider keeps its arrows) |
| Play or Pause Animation | Space, in the viewer |

File > Open Recent lists the last ten models.

## 9. Tried and taken out

A neon cord frame round the model, tape on the panels, sticker buttons with a pale rim and a
tilt, hand-drawn icons, a scalloped gizmo, a spiral binding in the app's window. They made the
tools louder than the model, against the two rules at the top.

## 10. Not done

- Accessibility actions on the 3D view itself; an Edit menu without text commands.
- Shadows of the model on itself (only the floor is shaded).
- Astrina's typeface (IBM Plex) is not bundled; the system's is used.
