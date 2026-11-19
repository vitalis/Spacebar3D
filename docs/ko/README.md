<p align="center">
  <img src="../../Packages/Spacebar3DKit/Sources/ViewerUI/Resources/Mark.png" width="200" alt="절반은 와이어프레임, 절반은 셰이딩으로 표현된 Spacebar 3D 카멜레온">
</p>

<h1 align="center">Spacebar 3D</h1>
<p align="center"><strong>모델까지, 스페이스 한 번.</strong></p>
<p align="center">Finder Quick Look과 Mac을 위한 네이티브 3D 뷰어.</p>
<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-111e17?style=flat-square" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple_silicon-arm64-a8e6a3?style=flat-square" alt="Apple silicon / arm64">
  <img src="https://img.shields.io/badge/renderer-Metal-b5cfff?style=flat-square" alt="Metal">
  <a href="../../LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-f05b99?style=flat-square" alt="Apache License 2.0"></a>
</p>
<p align="center">
  <a href="#install">시작하기</a> · <a href="#formats">형식</a> · <a href="#controls">조작</a> · <a href="DEVELOPMENT.md">개발 안내</a>
</p>
<p align="center"><a href="../../README.md">English</a> · <a href="../zh-Hans/README.md">简体中文</a> · <a href="../es/README.md">Español</a> · <a href="../fr/README.md">Français</a> · <a href="../de/README.md">Deutsch</a> · <a href="../ja/README.md">日本語</a> · <a href="../pt-BR/README.md">Português do Brasil</a> · <strong>한국어</strong> · <a href="../it/README.md">Italiano</a> · <a href="../ru/README.md">Русский</a></p>

---

## 찾고, 스페이스를 누르고, 돌려 보세요.

Finder에서 지원되는 3D 파일을 선택하고 <kbd>스페이스</kbd>를 누르세요. 모델을 돌리고, 토폴로지를 확인하고, 스타일을 바꾸거나 애니메이션을 살펴볼 수 있습니다. 전용 창이 필요하면 앱에서 파일을 여세요.

<p align="center">
  <img src="../demo.gif" width="900" alt="Spacebar 3D 뷰어에 표시된 탱크 모델과 조작 버튼">
</p>

> OBJ, STL, PLY, USD, USDZ에는 macOS 자체 미리보기가 선택될 수 있습니다. 앱의 **파일 → 열기…** 또는 Finder의 **다음으로 열기 → Spacebar 3D**로 지원 파일을 이 뷰어에서 열 수 있습니다.

<a id="looks"></a>

## 하나의 모델, 다양한 모습

| 살펴보기 | 바꿔 보기 | 재생하기 |
| :--- | :--- | :--- |
| 솔리드, 텍스처, 법선 보기와 와이어프레임 오버레이. 면과 꼭짓점 수 표시. | 음영 없음, 아니메, 셀 셰이딩, 레트로, 복셀 아트, 홀로그램 스타일. 평면·부드러운 셰이딩과 재질 조정. | 클립 선택, 재생 위치 이동, 반복 재생. 애니메이션만 있는 지원 파일의 골격 미리보기. |

**빛을 조절하세요.** Glasshouse부터 Neon까지 일곱 가지 분위기와 밝기, 방향, 조명 자동 회전을 제공합니다. **방향을 잡으세요.** 기즈모 축을 클릭하거나 모델을 회전·이동하고, 화면에 맞추거나 바닥 격자를 켤 수 있습니다. Finder의 작은 미리보기에는 모델만 표시합니다.

**Mac을 위한 네이티브 앱.** 앱과 Quick Look 확장은 Swift, Metal, SwiftUI, AppKit 구현을 공유합니다. 모델은 로컬에서 처리하며 두 구성 요소 모두 네트워크 권한이 없습니다. 인터페이스는 위에 나열된 열 가지 언어를 지원하고 macOS 언어 설정을 따릅니다. [현지화 안내, 영어](../LOCALIZATION.md).

<a id="install"></a>

## 시작하기

**macOS 26 이상 · Apple silicon · 소스에서 빌드**

macOS 26 이상 SDK가 포함된 정식 Xcode, XcodeGen, CMake, Ninja가 필요합니다. 프로젝트에는 개발 서명 팀과 App Group이 설정되어 있습니다. 다른 팀을 사용한다면 빌드 전에 [서명 안내](DEVELOPMENT.md#build-local)에 따라 서명 ID와 관련 식별자를 맞춰 주세요.

로컬 저장소에서 실행하세요.

```bash
brew install xcodegen cmake ninja
./scripts/build.sh
```

첫 빌드에서는 고정된 버전의 Assimp를 다운로드하고 빌드합니다.

1. `build/Build/Products/Release/Spacebar 3D.app`을 **응용 프로그램**으로 옮깁니다.
2. **앱을 한 번 실행**하여 확장을 등록합니다.
3. **시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램 → 훑어보기**에서 **Spacebar 3D**를 활성화합니다.
4. Finder에서 지원 파일을 선택하고 <kbd>스페이스</kbd>를 누릅니다.

다른 사람에게 배포하려면 [Developer ID 서명 및 공증 안내](DEVELOPMENT.md#distribution-signing--notarization)를 따르세요.

<details>
<summary><strong>Spacebar 3D를 기본 뷰어로 사용하기</strong></summary>

앱 설정에서 **기본 앱으로 설정…**을 클릭하세요. macOS에서 확인을 요청할 수 있으며, 변경하지 못한 형식은 앱이 알려 줍니다. Finder에서 이중 클릭했을 때의 동작을 바꾸며 Quick Look 확장 선택에는 영향을 주지 않습니다.

</details>

<a id="formats"></a>

## 지원 형식

아바타, 게임 에셋, CAD 내보내기 파일, 스캔, Blender 메시를 확인하세요.

`VRM` · `VRMA` · `glTF` · `GLB` · `FBX` · `OBJ` · `STL` · `3MF` · `PLY` · `USD` · `USDA` · `USDC` · `USDZ` · `3DS` · `BLEND`

<details>
<summary><strong>형식별 지원 범위와 제한</strong></summary>

| 형식 | 지원 범위 |
| :--- | :--- |
| `.vrm` | VRM 0.x / 1.0 아바타: 툰 셰이딩, 윤곽선, 스프링 본. |
| `.vrma` | 메시 없는 VRM 애니메이션. 골격을 막대 인형으로 표시하여 동작을 재생합니다. |
| `.glb` / `.gltf` | glTF 2.0 재질, 텍스처, 스키닝, 애니메이션. 외부 `.bin`과 이미지는 폴더 접근 권한이 필요합니다. Draco·Meshopt 압축과 인스턴스 메시를 지원하지 않습니다. |
| `.fbx` | 바이너리 또는 텍스트. 스키닝된 메시와 내장 애니메이션. 파일에 포함된 이미지, 옆에 있는 이미지, `.fbm` 폴더의 이미지를 사용합니다. |
| `.obj` | 지오메트리와 꼭짓점 색상. 폴더 허용 후 `.mtl`의 재질과 텍스처를 읽습니다. 면이 없으면 포인트 클라우드로 표시합니다. |
| `.stl` | 바이너리 또는 텍스트 STL. |
| `.3mf` | 객체별·삼각형별 색상, 이미지, 금속 및 반투명 재질. |
| `.ply` | 꼭짓점 색상이 있는 메시. 면이 없으면 포인트 클라우드로 표시합니다. |
| `.usd` / `.usda` / `.usdc` / `.usdz` | 재질, 내장 텍스처, 골격 애니메이션. |
| `.3ds` | 재질 색상과 투명도. 외부 텍스처는 폴더 접근 허용 후 표시합니다. |
| `.blend` | Blender 2.80 이상. 저장된 상태의 보이는 메시와 기본 재질, 패킹된 이미지와 허용된 폴더의 텍스처. 모디파이어, 아마추어 포즈, 애니메이션은 적용하지 않으며 임의의 셰이더 노드 네트워크를 평가하지 않습니다. |

지원 골격이 있는 애니메이션 전용 FBX와 VRMA는 막대 인형으로 표시합니다. 앱에 모델이나 아바타 데이터는 포함되어 있지 않습니다.

</details>

### 텍스처가 별도 파일에 있을 때

**텍스처 표시…**, **재질 표시…**, **모델 표시…**로 모델 폴더와 하위 폴더에 대한 읽기 전용 접근을 허용하세요. 내장 텍스처는 폴더 권한이 필요 없지만 지원되는 이미지·재질 형식이어야 합니다. 앱에서는 `ship.obj` 옆의 `ship.mtl`처럼 이름이 같은 재질 파일을 묻지 않고 읽을 수 있습니다.

모델은 열리지만 참조하는 텍스처를 하나도 표시할 수 없으면 뷰어가 **텍스처** 대신 **솔리드**로 표시합니다.

<a id="controls"></a>

## 조작 방법

| 동작 | 방법 |
| :--- | :--- |
| 회전 | 드래그 또는 앱의 모델 영역에 초점이 있을 때 방향키 |
| 이동 | 오른쪽 버튼으로 드래그하거나 Shift, Option, Command를 누른 채 드래그 |
| 키보드로 이동 | 앱 모델 영역에서 Shift + 방향키, 또는 보기 메뉴의 이동 하위 메뉴 |
| 확대·축소 | 스크롤 또는 핀치 제스처 |
| 모델을 화면에 맞추기 | 맞추기 버튼 또는 앱에서 ⌘0 |
| 축 방향으로 보기 | 기즈모 축 클릭 |
| 재생·일시 정지 | 재생 버튼 또는 앱 모델 영역에 초점이 있을 때 스페이스 |
| Quick Look 닫기 | 스페이스 |
| 단색 / 텍스처 / 법선 | 앱에서 ⌘1 / ⌘2 / ⌘3 |
| 와이어프레임 전환 | 앱에서 ⌘4 |

아래쪽 막대에는 보기, 스타일, 재질 설정이 있고 오른쪽에는 기즈모, 조명, 맞추기, 격자, 자동 회전이 있습니다. 애니메이션 막대에서 클립 선택과 반복 재생을 할 수 있습니다. 앱 설정에서 배경, 단색, 보기, 밝기, 격자, 회전, 재생 기본값을 지정합니다. 모델 위의 컨트롤이 숨겨져 있어도 보기 및 재생 메뉴를 사용할 수 있습니다.

<a id="help"></a>

## 도움이 필요할 때

뷰어 도구 막대의 **?** 메뉴에서 조작 방법, 개인정보 처리방침, 크레딧을 확인할 수 있습니다. 이 메뉴는 앱과 Quick Look에서 모두 사용할 수 있습니다.

문제가 있거나 궁금한 점이 있으면 앱에서 **도움말 → Spacebar 3D 지원**을 선택하거나 [이슈를 등록](https://github.com/vitalis/Spacebar3D/issues)하세요.

<details>
<summary><strong>미리보기가 나타나지 않아요</strong></summary>

앱을 한 번 실행하고 확장을 활성화하세요. 필요하면 Quick Look 캐시를 갱신합니다.

```bash
qlmanage -r && qlmanage -r cache
```

OBJ, STL, PLY, USD, USDZ는 앱에서 직접 열어 보세요.

</details>

<details>
<summary><strong>Apple 미리보기보다 Spacebar 3D를 우선 사용하기</strong></summary>

선택 사항인 전환 스크립트는 되돌릴 수 있습니다.

```bash
scripts/prefer-spacebar3d.sh status
scripts/prefer-spacebar3d.sh on
scripts/prefer-spacebar3d.sh off
```

`on`은 Spacebar 3D를 우선하며 `off`는 Apple 확장을 복원합니다. 스크립트는 `pluginkit`으로 현재 계정의 Apple 확장 두 개를 비활성화하며 시스템 파일은 변경하지 않습니다. 활성화 중에는 MaterialX와 Alembic이 더 간단한 미리보기를 사용하고, USDZ의 AR 보기와 `.reality`의 미리보기를 사용할 수 없습니다. macOS 업데이트로 선택이 초기화될 수 있습니다. 앱에서 직접 여는 데는 이 전환이 필요하지 않습니다.

</details>

<details>
<summary><strong>텍스처가 보이지 않아요</strong></summary>

**텍스처 표시…**로 폴더를 허용하세요. Quick Look에서만 허용한 폴더는 Mac 재시동 후 다시 허용해야 합니다. 앱은 권한을 기억하며, 재시동 후 한 번 실행하면 Quick Look에서도 다시 사용할 수 있습니다. 이미지가 없거나 이미지·재질 형식이 지원되지 않아 텍스처가 표시되지 않을 수도 있습니다.

</details>

<a id="architecture"></a>

## 내부 구조

앱과 확장은 `Spacebar3DKit`을 공유합니다. `ImportRouter`가 파일을 `ModelScene`으로 읽고 Metal이 그립니다. Swift 리더는 STL, PLY, OBJ, 3MF, glTF, VRM, Blender를 처리하며 Model I/O는 USD, Assimp는 FBX와 3DS를 처리합니다.

[빌드와 아키텍처](DEVELOPMENT.md) · [현지화](../LOCALIZATION.md) · [변경 기록](../../CHANGELOG.md) · [개인정보 처리방침, 영어](../../PRIVACY.md)

<a id="credits"></a>

## 크레딧과 라이선스

Spacebar 3D는 [Apache License, Version 2.0](../../LICENSE)에 따라 배포됩니다.
Copyright © 2026 Vitaly Gorodetsky.

프로젝트의 출발점, 기여자 및 감사의 글은 [CREDITS.md](../../CREDITS.md)를, 별도 라이선스 구성 요소의 조건은 [서드파티 라이선스](../../THIRD_PARTY_LICENSES.md)를 참조하세요. 이 고지 사항은 앱 도움말 메뉴의 감사의 글에서도 볼 수 있습니다.
