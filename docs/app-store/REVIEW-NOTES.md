# Spacebar 3D App Review notes

Spacebar 3D previews local 3D files in Finder Quick Look and in its standalone viewer.
The attached Spacebar3D-Review-Sample.zip contains two files. app-review-final.mp4 is a
walkthrough video that shows a tank. Spacebar3D-Review-Model.glb is a self-contained
model of six colored blocks with two animation clips, for testing the same steps.
The test runs offline and requires no account.

1. Launch Spacebar 3D once. Open System Settings → General → Login Items & Extensions → Quick Look and turn on Spacebar 3D.
2. In Finder, select the local Spacebar3D-Review-Model.glb file and press Space. Quick Look should display the stepped model and the viewer controls. If the model opens in Solid, select Textured in the bottom toolbar to see the embedded colors.
3. Drag the model to orbit and scroll to zoom. If Quick Look offers Open with Spacebar 3D, click it. Otherwise, launch Spacebar 3D, choose File → Open…, and select the same GLB file.
4. The standalone viewer should display the same model. Drag to orbit or scroll to zoom. Click Wireframe in the bottom toolbar to reveal the mesh edges.

## More controls to try in the standalone viewer

- Navigation. Drag to orbit, right-drag to pan, scroll to zoom, and use Zoom to fit to reframe the model. Click a gizmo axis to change the viewing direction. Use the floor grid and auto-rotate controls on the right.
- Views and styles. Switch between Solid, Textured, and Normal. Toggle Wireframe with ⌘4 and check the face and vertex counts. Try Unshaded, Anime, Cel-Shaded, Retro, Voxel Art, and Hologram. Open View settings to compare Smooth and Flat shading. In Textured view, enable Override beside Metallic or Roughness to adjust its slider.
- Lighting. Open Light to select a mood and change brightness and direction. Turn on Rotate the light automatically to see the highlights move around the model.
- Playback. Use the animation bar to choose Lift the gold block or Slide the gold block. Play or pause the clip and drag the scrubber halfway to see the gold block move up or sideways. Enable Repeat and press Play to loop it.
- App controls. Reopen the file from File → Open Recent. Open Settings to inspect the default view and playback options. The viewer's ? menu lists controls and opens acknowledgements and the privacy policy. Help → Spacebar 3D Support opens the project's issue tracker in the browser. It is the only web link in the app.

## Sandbox and file access

The app and its Quick Look extension are sandboxed with read-only access to files the user selects. They share an App Group container only for viewer settings and remembered folder permissions. Neither has a network entitlement.

macOS may use its own Quick Look preview for OBJ, STL, PLY, USD and USDZ files. That is the system's choice of extension. File → Open… in Spacebar 3D always opens those files in this viewer.
