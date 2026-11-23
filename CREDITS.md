# Credits

## Spacebar 3D

Copyright © 2026 Vitaly Gorodetsky.

Spacebar 3D is developed and maintained by Vitaly Gorodetsky. The current project
is distributed under the [Apache License, Version 2.0](LICENSE). Separately
licensed material retains its applicable terms and notices.

## Project origins

Thanks to sawa-zen for [Quick Look 3D](https://github.com/sawa-zen/quick-look-3d),
the original VRM / GLB / FBX previewer from which this repository began.
Spacebar 3D now has its own native viewer, rendering pipeline, format readers,
controls and documentation.

The following notice preserves the terms and attribution of previously
MIT-licensed material retained from the repository's history. It does not replace
the current project's Apache 2.0 license.

```text
MIT License

Copyright (c) 2026 sawa-zen
Copyright (c) 2026 Vitaly Gorodetsky

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## Bundled dependencies

- **Assimp**, by the Assimp team: FBX and 3DS import. BSD 3-Clause, with additional
  notices for its included components.
- **Zstandard**, by Meta Platforms, Inc. and affiliates: the decoder used for
  compressed Blender files. BSD license.

The complete notices, including Assimp's bundled contributors and components,
are in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). These notices are also
included in the app's **Help → Acknowledgements** window.

## Development tools and references

- [XcodeGen](https://github.com/yonaskolb/XcodeGen), for generating the Xcode project.
- [CMake](https://cmake.org/) and [Ninja](https://ninja-build.org/), for building Assimp.
- [ViewInspector](https://github.com/nalexn/ViewInspector), for SwiftUI view tests.
- [VRMQuickLook](https://github.com/magicien/VRMQuickLook) and
  [GLTFQuickLook](https://github.com/magicien/GLTFQuickLook), by magicien, as references
  for VRM and Quick Look implementation.
- [three-vrm](https://github.com/pixiv/three-vrm), by pixiv, as a reference for VRM behavior.

Development tools and reference projects are not bundled runtime dependencies.
