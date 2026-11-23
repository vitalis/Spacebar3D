# Spacebar 3D 개발

[English](../DEVELOPMENT.md) | [简体中文](../zh-Hans/DEVELOPMENT.md) | [Español](../es/DEVELOPMENT.md) | [Français](../fr/DEVELOPMENT.md) | [Deutsch](../de/DEVELOPMENT.md) | [日本語](../ja/DEVELOPMENT.md) | [Português (Brasil)](../pt-BR/DEVELOPMENT.md) | **한국어** | [Italiano](../it/DEVELOPMENT.md) | [Русский](../ru/DEVELOPMENT.md)

네이티브 macOS 앱과 Quick Look 확장 프로그램을 빌드하고 테스트하며 디버깅하는 방법입니다. 기능과 지원 형식의 제한은 [README](README.md)를 참고하세요.

[요구 사항](#requirements) · [빌드](#build-local) · [테스트](#tests) · [구조](#how-it-works) · [문제 해결](#troubleshooting) · [배포](#distribution-signing--notarization)

별도 안내가 없으면 모든 셸 명령은 저장소 루트에서 실행합니다.

<a id="requirements"></a>

## 요구 사항

| 요구 사항 | 설명 |
| :--- | :--- |
| macOS 26 이상을 실행하는 Apple Silicon Mac | 프로젝트와 Assimp는 `arm64`를 대상으로 빌드하며 Intel용 바이너리는 생성하지 않습니다. |
| macOS 26 이상 SDK가 포함된 전체 Xcode | Command Line Tools만으로는 부족합니다. 현재 로컬 개발 환경은 Xcode 27.0을 사용합니다. |
| XcodeGen | `project.yml`에서 Xcode 프로젝트를 생성합니다. |
| CMake와 Ninja | 네이티브 의존성인 Assimp를 빌드합니다. |
| Python 3 | 현지화 일관성 검사기를 실행합니다. |
| 개발 서명 ID | 설치한 앱, 확장 프로그램, 공유 App Group에 필요합니다. 아래를 참고하세요. |

```bash
brew install xcodegen cmake ninja
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

셸이 Command Line Tools나 다른 Xcode 설치를 선택했다면 빌드 전에 전체 Xcode를 지정하세요.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`xcode-select`가 Command Line Tools를 가리킬 때 `build.sh`도 위의 기본 설치 위치를 감지합니다. `xcodebuild`를 직접 실행하거나 의존성을 빌드할 때는 올바른 개발자 디렉터리를 미리 지정해야 합니다.

<a id="build-local"></a>

## 로컬 빌드

<a id="configure-signing"></a>

### 서명 설정

저장소의 설정은 [`project.yml`](../../project.yml)에 정의된 개발 팀을 사용합니다. 자신의 팀으로 빌드하려면 다음을 설정하세요.

1. `project.yml`에서 `DEVELOPMENT_TEAM`과 적절한 번들 식별자를 설정합니다.
2. 팀의 App Group을 구성합니다. [`Spacebar3D.entitlements`](../../Spacebar3D/App/Spacebar3D.entitlements), [`Spacebar3DExtension.entitlements`](../../Spacebar3D/Extension/Spacebar3DExtension.entitlements), [`ViewerSettings.swift`](../../Spacebar3D/Shared/ViewerSettings.swift)의 `ViewerSettings.appGroup`에 같은 그룹 식별자를 사용합니다.
3. Xcode에서 팀의 Apple Development 인증서와 필요한 프로비저닝 파일을 사용할 수 있는지 확인합니다. 설정을 변경한 뒤 프로젝트를 다시 생성합니다.

현재 App Group은 `V3AQWQ8JMY.com.vitalis.Spacebar3D`입니다. 빌드 명령에서 팀만 바꿔도 이 식별자는 바뀌지 않습니다. 서명하지 않은 빌드나 ad hoc 서명 빌드는 확장 프로그램 등록 및 공유 컨테이너 접근 테스트를 대신할 수 없습니다.

<a id="build-the-app"></a>

### 앱 빌드

```bash
./scripts/build.sh
```

스크립트는 Assimp 프레임워크가 없으면 먼저 빌드하고, XcodeGen을 실행한 뒤 `Spacebar3D` 스킴을 Release 구성으로 빌드합니다. 결과 위치는 다음과 같습니다.

```text
build/Build/Products/Release/Spacebar 3D.app
```

첫 빌드에는 의존성을 가져오기 위한 네트워크 연결이 필요합니다. [`build-assimp.sh`](../../scripts/build-assimp.sh)는 Assimp를 `v6.0.6`으로 고정하고 컴파일 전에 전체 커밋 SHA `a79ff6bbce54d3e01186a918dc6374ed55317426`를 확인합니다. FBX 및 3DS 임포터를 포함한 정적 arm64 XCFramework로 빌드하며 익스포터와 Draco는 제외합니다.

고정 리비전이 바뀌면 이 스크립트를 다시 실행하세요. `build.sh`는 프레임워크가 있는지만 확인하고 현재 리비전과 일치하는지는 확인하지 않습니다. 필요한 커밋으로 체크아웃한 로컬 소스를 사용하려면:

```bash
ASSIMP_SRC=/path/to/assimp ./scripts/build-assimp.sh
```

<a id="register-and-exercise-quick-look"></a>

### Quick Look 등록 및 확인

1. 빌드한 앱을 `/Applications`로 복사하고 해당 복사본을 한 번 실행합니다.
2. **시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램 → Quick Look**에서 **Spacebar 3D**를 켭니다.
3. Finder에서 지원 파일을 선택하고 스페이스 키를 누릅니다.
4. 앱의 **파일 → 열기…**에서도 같은 파일을 열어 두 실행 환경을 확인합니다.

등록 정보가 오래되었다면 캐시를 갱신하고 GLB 파일로 확인하세요.

```bash
qlmanage -r
qlmanage -r cache
qlmanage -p /path/to/model.glb
```

macOS는 OBJ, STL, PLY, USD, USDZ에 Apple의 기본 미리보기를 선택할 수 있습니다. 이것만으로 이 확장 프로그램이 실패했다고 판단할 수 없습니다. 앱을 사용하거나 [README](README.md#help)에 안내된 선택적 변경 절차를 이용하세요.

<a id="development"></a>

## 개발

Xcode에서 편집하고 디버깅하려면:

```bash
./scripts/build-assimp.sh
xcodegen generate
open Spacebar3D.xcodeproj
```

Assimp는 의존성 리비전마다 한 번 빌드하고, `project.yml`이 바뀌면 프로젝트를 다시 생성합니다. `.xcodeproj`, 생성된 두 `Info.plist` 파일, 빌드 결과와 `Vendor/Assimp.xcframework`는 Git에서 제외됩니다. 생성된 프로젝트나 속성 목록 대신 YAML 원본을 수정하세요.

터미널에서 증분 Debug 빌드를 실행하려면:

```bash
xcodebuild -project Spacebar3D.xcodeproj -scheme Spacebar3D \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build build
```

`SKIP_XCODEGEN=1 ./scripts/build.sh`는 기존 생성 프로젝트를 재사용하며 여전히 Release로 빌드합니다. 해당 프로젝트가 YAML과 일치할 때만 사용하세요.

<a id="capture-media"></a>

### 미리보기 영상과 스크린샷 캡처

위의 빌드 요구 사항을 충족한 뒤 macOS 데스크톱에 로그인한 상태에서 스크립트를 실행하세요. 시스템 설정에서 스크립트를 실행하는 앱에 화면 기록 권한을 부여하세요.

모델이 외부 텍스처, 재질 또는 형상 파일을 참조하는 경우 먼저 일반 Spacebar 3D 앱에서 모델을 여세요. 뷰어의 폴더 버튼으로 해당 파일이 들어 있는 폴더에 접근 권한을 부여하세요. 캡처용 앱은 저장된 권한을 사용합니다. 모델 파일만 열면 관련 파일에 접근하지 못할 수 있습니다.

```bash
brew install ffmpeg
./scripts/capture-media.sh /path/to/model.glb
```

스크립트는 캡처 기능을 활성화한 Spacebar 3D 앱을 별도로 빌드하고 실행합니다. 이미 캡처용으로 빌드한 앱을 사용하려면 `SPACEBAR3D_APP`에 해당 `.app` 번들의 경로를 지정하세요. 기본적으로 `build/media-captures/` 아래에 새 폴더를 만듭니다. 출력 폴더를 지정하려면 아직 사용하지 않는 경로를 두 번째 인수로 전달하세요.

Mac App Store에 공개할 미리보기 영상 `preview.mp4`는 30초 동안 모델에 사용할 수 있는 모든 렌더링 스타일을 보여 줍니다. 영상 해상도는 1920 × 1080이며 프레임 속도는 30 fps입니다. 스크립트는 2560 × 1600 PNG 이미지 네 장과 `demo.gif`도 저장합니다. 모델이 세 가지 이상의 렌더링 스타일을 지원하면 GIF는 반복 영상과 같은 15초 편집본을 사용합니다. 스타일이 그보다 적으면 미리보기 영상을 원래 속도로 사용합니다. 첫 번째 스크린샷은 텍스처 보기를 사용할 수 있으면 `01-textured.png`, 그 외에는 솔리드 보기의 `01-solid.png`로 저장됩니다. 나머지 파일은 `02-wireframe.png`, `03-normals.png`, `04-hologram.png`입니다.

<a id="capture-feature-loop"></a>

### 렌더링 스타일 반복 영상 캡처

같은 캡처 설정에서 15초 길이의 30 fps 반복 영상을 만들 수 있습니다. 모델은 세 가지 이상의 렌더링 스타일을 지원해야 합니다. 셀 셰이딩, 복셀 아트, 홀로그램을 우선 사용합니다.

```bash
./scripts/capture-feature-loop.sh /path/to/model.glb
```

기본적으로 스크립트는 `build/media-captures/` 아래 새 폴더에 `feature-loop.mp4`를 저장합니다. 출력 폴더를 지정하려면 아직 사용하지 않는 경로를 두 번째 인수로 전달하세요.

<a id="capture-screenshots"></a>

### App Store용 스크린샷 캡처

같은 캡처 설정에서 위에 나열한 2560 × 1600 sRGB PNG 이미지 네 장을 만들 수 있습니다.

```bash
./scripts/capture-screenshots.sh /path/to/model.glb
```

기본적으로 스크립트는 `build/media-captures/` 아래 새 폴더에 파일을 저장합니다. 출력 폴더를 지정하려면 아직 사용하지 않는 경로를 두 번째 인수로 전달하세요.

<a id="capture-app-review"></a>

### App Review용 비공개 시연 영상 녹화

일반 Spacebar 3D 앱을 설치해 실행하고 Quick Look 확장 프로그램을 활성화하세요. Finder의 Quick Look에서 직접 조작할 수 있는 미리보기로 열리는 모델을 선택하세요. 녹화 전에 Finder의 Quick Look 미리보기와 독립 실행형 뷰어에서 파일 이름이 같은 창을 닫으세요. 위에서 안내한 화면 기록 권한, Swift 명령줄 도구, `drawtext`와 `subtitles` 필터를 지원하는 FFmpeg가 필요합니다. 터미널을 보이게 두고 안내를 따르세요. Finder에서 파일을 선택한 상태로 두고 필요하면 목록 보기로 전환하세요. 안내가 나오면 스페이스바를 누르고 회전 또는 확대·축소 조작을 두 번 하세요. 안내가 나오면 Spacebar 3D로 열기 버튼을 클릭하세요. macOS가 앱 메뉴를 열면 Spacebar 3D를 선택하세요. 버튼이 없으면 Quick Look을 닫고 Spacebar 3D의 **파일 → 열기…**에서 같은 파일을 여세요. 독립 실행형 뷰어에서도 회전 또는 확대·축소 조작을 두 번 하세요.

```bash
SPACEBAR3D_REVIEW_ANIMATION_MODEL=docs/app-store/Spacebar3D-Review-Model.glb \
  ./scripts/capture-app-review.sh /path/to/model.fbx build/media-captures/app-review
```

스크립트는 설명 문구를 추가하고 `build/media-captures/` 아래 새 폴더에 `app-review.mp4`를 저장합니다. 출력 폴더를 지정하려면 아직 사용하지 않는 경로를 두 번째 인수로 전달하세요. 앱을 `/Applications/Spacebar 3D.app` 이외의 위치에 설치했다면 `SPACEBAR3D_REVIEW_APP`을 설정하세요.

안내에 따른 녹화가 끝나면 스크립트는 뷰어 조작, 설정, 도움말, 개인정보 보호 장을 녹화합니다. 예제에서는 애니메이션 샘플 모델로 재생 장을 추가합니다. 이미 캡처용으로 빌드한 앱을 재사용하려면 `SPACEBAR3D_REVIEW_CAPTURE_APP`을 설정하세요. 기본적으로 위의 개발 설정으로 캡처용 앱을 별도로 빌드합니다.

Finder와 뷰어의 안내 단계만 녹화한 파일이 있다면 `capture-review-features.sh`로 장을 추가할 수 있습니다. `--help`를 참조하세요.

<a id="tests"></a>

## 테스트

패키지를 해석하거나 어느 테스트 경로든 실행하기 전에 Assimp를 빌드하세요.

<a id="full-xcode-suite"></a>

### 전체 Xcode 테스트

주요 회귀 테스트 명령입니다. 앱, 공유 코드, 확장 프로그램의 소스 테스트와 `project.yml`에 선언된 아홉 개 패키지 테스트 타깃을 모두 포함합니다.

```bash
xcodegen generate
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build
python3 scripts/check-localizations.py
```

특정 테스트만 실행하려면 `-only-testing` 선택자를 추가합니다. 예:

```bash
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build \
  -only-testing:ViewerUITests/NativeViewerInputTests
```

Xcode는 `.xcresult` 번들을 `build/Logs/Test/`에 저장합니다.

<a id="package-only-tests"></a>

### 패키지 전용 테스트

`Spacebar3DTests`의 호스트 소스 테스트는 제외됩니다.

```bash
xcrun swift test --package-path Packages/Spacebar3DKit
```

대형 모델 테스트 두 개는 `P3D_LARGE=1`로 명시적으로 활성화합니다. 그중 하나는 약 100 MB의 STL 테스트 파일을 생성합니다. 해당 벤치마크를 실행하려면:

```bash
P3D_LARGE=1 xcrun swift test --package-path Packages/Spacebar3DKit \
  --filter LargeModelTests
```

<a id="what-the-tests-establish"></a>

### 테스트로 확인하는 범위

- 설정 테스트는 명시적으로 지정한 임시 저장소를 사용합니다. 설정 규칙이 바뀌면 [`settings-vectors.json`](../../testdata/settings-vectors.json)에 정규화 사례를 추가하세요.
- 임포터 테스트는 작은 테스트 파일을 만들고 잘못되거나 잘린 입력을 확인합니다.
- 렌더러 테스트는 화면 밖에 그린 뒤 픽셀을 검사하므로 작동하는 Metal 장치가 필요합니다.
- 뷰어 테스트는 네이티브 입력, 손쉬운 사용 메타데이터, 명령, 레이아웃, SwiftUI 컨트롤을 확인하며 ViewInspector 검사도 포함합니다.
- 현지화 검사는 원본 키의 포함 여부, 카탈로그 항목과 자리표시자를 검증합니다. 패키지 테스트는 컴파일된 언어 리소스도 확인합니다.

Xcode 스킴은 호스트 소스를 테스트 번들로 컴파일합니다. 서명된 앱을 실제 배포용 샌드박스 안에서 실행하지는 않습니다. 테스트 통과만으로 Quick Look 등록, 폴더 권한, VoiceOver 음성, 공증된 다운로드의 동작이 확인되지는 않습니다. 이런 변경은 설치한 서명된 앱과 Finder 확장 프로그램에서도 테스트하세요.

<a id="how-it-works"></a>

## 동작 구조

```text
Finder → Quick Look extension ─┐
                              ├─ ViewerFactory → NativeViewer
App → model window ───────────┘                      │
                                     ImportRouter → ModelScene
                                                     │
                                           RenderMetal / MTKView
                                           + SwiftUI controls
```

두 호스트는 로컬 `Spacebar3DKit` 패키지를 공유합니다. 가져오기는 메인 스레드 밖에서 실행하고 네이티브 뷰어가 렌더링과 컨트롤을 조정합니다.

| 위치 | 역할 |
| :--- | :--- |
| `Spacebar3D/App/` | 초기 설정, 환경설정, 모델 창, 기본 앱 등록, 메뉴, 도움말, 크레딧. |
| `Spacebar3D/Extension/` | Quick Look 미리보기 수명 주기. |
| `Spacebar3D/Shared/` | 뷰어 생성과 공유 설정. |
| `Packages/Spacebar3DKit/Sources/ModelCore/` | 장면 데이터, 형식 감지, 애니메이션, 토폴로지, 현지화. |
| `…/Sources/ImportRouter/` 및 `…/Sources/Import*/` | 형식별 분기와 리더. |
| `…/Sources/RenderMetal/` | GPU 장면, 카메라, 셰이딩, 렌더링. |
| `…/Sources/ViewerUI/` | 뷰어 API, 네이티브 입력, SwiftUI 컨트롤, 폴더 접근 권한. |
| `…/Sources/CZstd/` | 압축된 Blender 파일용으로 포함한 Zstandard 디코더. |
| `Spacebar3DTests/` 및 `Packages/Spacebar3DKit/Tests/` | 호스트 소스 및 패키지 테스트. |
| `docs/<language-code>/README.md` | 영어 외 아홉 언어의 README. |
| `docs/<language-code>/DEVELOPMENT.md` | 영어 외 아홉 언어의 개발 안내. |

네이티브 Swift 리더는 STL, PLY, OBJ, 3MF, glTF/GLB, VRM/VRMA, Blender를 처리합니다. Model I/O는 USD를, Assimp는 FBX와 3DS를 처리합니다. `FormatDetector`는 파일의 앞쪽 바이트를 확인하고 모호한 텍스트 형식에서는 확장자도 사용합니다. 지원 문서 유형과 `QLSupportedContentTypes`는 `project.yml`에 선언합니다.

지원되는 스켈레톤이 있는 애니메이션 전용 파일은 선으로 표현한 스켈레톤 미리보기를 사용할 수 있습니다. 기본 아바타는 포함하지 않습니다. 형식 지원 범위는 의도적으로 완전한 DCC 앱보다 좁습니다. 리더를 변경할 때 README의 제한 사항도 정확하게 유지하세요.

<a id="implementation-notes"></a>

## 구현 참고 사항

<a id="sandbox-and-related-files"></a>

### 샌드박스와 관련 파일

두 타깃은 App Sandbox와 사용자가 선택한 파일에 대한 읽기 전용 접근을 사용합니다. 네트워크 권한이나 임시 샌드박스 예외는 없습니다.

모델을 열어도 인접 파일에 대한 무제한 접근 권한은 생기지 않습니다. 두 호스트는 **모델 표시…**, **재질 표시…**, **텍스처 표시…**로 폴더 접근을 요청할 수 있습니다. 앱은 관련 파일 처리 기능으로 `ship.obj` 옆의 `ship.mtl`처럼 이름이 같은 지정된 재질 보조 파일도 지원합니다.

[`FolderGrants.swift`](../../Packages/Spacebar3DKit/Sources/ViewerUI/FolderGrants.swift)는 앱의 권한을 보안 범위 책갈피로 저장합니다. Quick Look은 자체 일반 책갈피를 보관하고 앱이 공유 컨테이너에서 갱신한 복사본도 읽습니다. Quick Look에만 부여한 권한은 Mac을 재시동하면 다시 허용해야 합니다. 앱을 실행하면 기억해 둔 앱 권한을 확장 프로그램용으로 갱신합니다. 읽기 범위는 허용한 폴더와 그 하위 항목으로 제한됩니다.

<a id="settings"></a>

### 설정

`ViewerSettings`는 App Group 컨테이너에 `viewer-settings.json`을 저장합니다. 앱이 기록하며 새 뷰어는 정규화된 값을 읽습니다. 설정이 유효하지 않거나 너무 크거나 없으면 기본값을 사용합니다. 이전의 컨테이너 밖 위치인 `~/Library/Application Support/Spacebar3D/`에서 마이그레이션하지 않습니다.

<a id="input-and-accessibility"></a>

### 입력과 손쉬운 사용

독립 실행 앱의 모델 캔버스가 키보드 입력을 처리할 때만 화살표 키로 회전하고 Shift-화살표 키로 이동합니다. 스페이스 키는 그곳에서 재생하거나 일시 정지합니다. 전역 메뉴 단축키가 아니며 포커스된 버튼이나 슬라이더의 활성화 입력을 가로채면 안 됩니다. Quick Look은 스페이스 키로 닫는 동작을 유지합니다. 메뉴와 손쉬운 사용 동작은 포인터 제스처의 대안입니다.

컨트롤을 바꿀 때는 키보드 포커스, 좁은 창, 긴 번역, 대비 증가, 투명도 감소를 확인하세요. 손쉬운 사용 트리 검증과 별도로 실제 VoiceOver 안내를 들어 보세요.

<a id="localization-and-documentation"></a>

### 현지화와 문서

공유 문자열 카탈로그 `Packages/Spacebar3DKit/Sources/ModelCore/Resources/Localizable.xcstrings`는 앱과 확장 프로그램에 열 개 언어를 제공합니다. 완전한 문자열, 자리표시자, 컴파일된 리소스, 레이아웃 검사는 [LOCALIZATION.md](../LOCALIZATION.md)를 따르세요.

영문 README는 루트에, 번역은 `docs/<language-code>/`에 있습니다. 개발 안내도 같은 언어별 폴더에 있으며 영문 원본은 `docs/DEVELOPMENT.md`입니다. 형식 제한, 조작, 설치, 권한 동작, 개발 절차를 모든 버전에서 일치시키세요.

<a id="troubleshooting"></a>

## 문제 해결

| 증상 | 확인 사항 |
| :--- | :--- |
| 패키지 해석 시 Assimp가 없다고 나옴 | 전체 Xcode, CMake, Ninja가 준비된 상태에서 `./scripts/build-assimp.sh`를 실행합니다. |
| 서명이 실패하거나 공유 설정을 사용할 수 없음 | 인증서, 팀, 번들 ID, 일치하는 App Group ID를 확인합니다. 환경 변수만으로 entitlements가 바뀌지는 않습니다. |
| 프로젝트 생성 후 수정 내용이 사라짐 | 생성된 `.xcodeproj`나 `Info.plist` 대신 `project.yml`을 수정합니다. |
| 확장 프로그램이 없거나 이전 버전이 로드됨 | 올바른 설치 앱을 실행하고 확장 프로그램을 켠 뒤 등록을 확인하고 Quick Look을 갱신합니다. 설치된 복사본과 빌드 폴더의 복사본을 혼동하지 마세요. |
| Apple 뷰어가 열림 | 위의 기본 형식 관련 설명을 확인하고 앱의 파일 → 열기와 비교합니다. |
| 텍스처나 형상이 없음 | 안내를 읽고 모델 폴더를 허용한 뒤 형식 제한과 보조 파일을 확인합니다. |
| GPU 테스트 실패 | Metal 장치를 사용할 수 있는지 확인하고 실패를 조사합니다. GPU를 사용할 수 없다는 것은 렌더링 검증 통과가 아닙니다. |

확장 프로그램 등록을 확인하고 로그를 실시간으로 봅니다.

```bash
pluginkit -m | rg -i spacebar3d
log stream --predicate 'process == "Spacebar3DExtension"'
```

첫 명령은 ripgrep의 `rg`를 사용하며 `grep -i spacebar3d`로 대체할 수 있습니다. 다른 터미널에서 `qlmanage -p /path/to/model.glb`를 실행하세요. 거부된 모델은 미리보기에 오류를 표시해야 합니다. 서명이나 권한을 변경하기 전에 가져오기, 렌더링, 접근, 확장 프로그램 선택 중 어디에 문제가 있는지 확인하세요.

<a id="distribution-signing--notarization"></a>

## 배포, 서명 및 공증

제공된 스크립트는 **Developer ID를 통한 DMG 직접 배포**를 구현합니다. Mac App Store용 빌드를 아카이브하거나 내보내거나 업로드하지 않습니다. 스토어 배포에는 별도의 서명, 아카이브, 내보내기, App Store Connect 제출 절차가 필요합니다.

직접 배포에는 Developer ID Application ID와 공증을 사용하세요. Apple의 [공증 안내](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)에 서명과 서비스 요구 사항이 있습니다. 멤버십 가격은 여기서 반복하지 않습니다.

<a id="manual"></a>

### 수동 실행

팀과 App Group 식별자가 일치하도록 구성한 뒤 실행합니다.

```bash
SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ./scripts/build.sh
```

`SIGN_IDENTITY`를 지정하면 스크립트는 수동 서명을 선택하고 `DEVELOPMENT_TEAM`을 전달하며 보안 타임스탬프를 추가하고 기본 디버그 entitlements 삽입을 끕니다. Hardened Runtime은 `project.yml`에서 활성화되어 있습니다. `SIGN_IDENTITY`가 없으면 프로젝트의 개발 서명 설정을 사용합니다.

로컬 공증에는 키체인 프로파일을 권장합니다. `notarytool`로 자격 증명을 대화식으로 저장한 뒤 프로파일 이름으로 실행하세요.

```bash
xcrun notarytool store-credentials "spacebar3d-notary"
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" ./scripts/notarize.sh
```

스크립트는 선택적으로 앱 경로를 받습니다.

```bash
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" \
  ./scripts/notarize.sh "/path/to/Spacebar 3D.app"
```

인증 방식은 다음 우선순위로 선택합니다.

| 방식 | 변수 |
| :--- | :--- |
| 키체인 프로파일 | `NOTARY_KEYCHAIN_PROFILE` |
| App Store Connect API 키 | `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER` |
| Apple 계정 자격 증명 | `APPLE_TEAM_ID`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` |

마지막 방식은 앱 암호를 `notarytool` 인수로 전달합니다. 공유 개발 머신에서는 키체인 프로파일로 이를 피할 수 있습니다. 서명 키와 자격 증명을 저장소에 넣지 마세요.

`notarize.sh`는 앱의 Developer ID 서명을 확인하고 Applications 바로가기가 포함된 DMG를 만듭니다. 앱 서명에서 읽은 ID로 DMG에 서명합니다. `SIGN_IDENTITY`가 지정되어 있으면 그 값을 사용합니다. 인증서와 개인 키를 키체인에서 사용할 수 있어야 합니다. 스크립트는 DMG를 Apple에 제출하고, 승인되면 공증 티켓을 첨부해 검증한 뒤 `spctl`로 Gatekeeper를 확인합니다. 모든 검사를 통과하면 저장소 루트에 `Spacebar3D.dmg`를 씁니다. 공유하기 전에 다운로드한 파일을 테스트하세요.

<a id="automated-github-actions"></a>

### GitHub Actions 자동 실행

[릴리스 워크플로](../../.github/workflows/release.yml)는 Apple silicon `macos-26` 실행기에서 Xcode 26을 사용합니다. `MARKETING_VERSION`과 일치하고 `origin/main`의 커밋을 가리키는 `vMAJOR.MINOR.PATCH` 형식의 태그를 푸시하거나 수동 실행에서 선택하세요.

워크플로는 프로젝트를 생성하고 `Spacebar3DTests`와 현지화 검사를 실행한 뒤 서명 인증서를 가져옵니다. Developer ID로 빌드하고 앱과 확장의 버전을 태그와 비교한 다음 DMG에 서명하고 공증합니다. 임시 키체인을 삭제한 뒤 DMG를 GitHub Release에 첨부합니다.

다음 secrets를 **실제 대상 저장소**에 설정하세요.

| Secret | 내용 |
| :--- | :--- |
| `MACOS_CERTIFICATE` | `.p12`로 내보낸 Developer ID Application 인증서와 개인 키를 Base64로 인코딩한 값. |
| `MACOS_CERTIFICATE_PWD` | 해당 `.p12`의 암호. |
| `KEYCHAIN_PASSWORD` | 임시 빌드 키체인의 암호. |
| `APPLE_TEAM_ID` | 서명 팀 ID. |
| `NOTARY_APPLE_ID` | 공증에 사용하는 Apple 계정. |
| `NOTARY_PASSWORD` | 해당 계정의 앱 암호. |

`gh secret set APPLE_TEAM_ID --repo OWNER/REPOSITORY`처럼 저장소를 명시하세요. 명령이 값 입력을 요청합니다. 로컬 `origin`이 존재하는 저장소나 의도한 릴리스 대상을 가리킨다고 가정하지 마세요.

릴리스 태그를 만들기 전에 `project.yml`의 `MARKETING_VERSION`과 `CURRENT_PROJECT_VERSION`을 설정하고, 변경 기록을 갱신하고, 테스트를 실행하고, 서명된 빌드를 확인하세요. 해당 태그를 푸시하면 워크플로가 성공했을 때 GitHub Release가 게시될 수 있습니다.

<a id="references"></a>

## 참고 자료

- [네이티브 렌더러 구조](../architecture/native-rewrite.md)
- [뷰어 디자인](../design/neon-garden-viewer.md)
- [현지화](../LOCALIZATION.md)
- [서드 파티 라이선스](../../THIRD_PARTY_LICENSES.md)
- [Apple: 공증 워크플로 사용자화](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [magicien/VRMQuickLook](https://github.com/magicien/VRMQuickLook), SceneKit 기반 VRM 0.x 구현
- [magicien/GLTFQuickLook](https://github.com/magicien/GLTFQuickLook), Quick Look 구조 참고
- [pixiv/three-vrm](https://github.com/pixiv/three-vrm), VRM 동작 참고
