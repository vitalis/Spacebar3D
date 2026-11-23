# Desarrollar Spacebar 3D

[English](../DEVELOPMENT.md) | [简体中文](../zh-Hans/DEVELOPMENT.md) | **Español** | [Français](../fr/DEVELOPMENT.md) | [Deutsch](../de/DEVELOPMENT.md) | [日本語](../ja/DEVELOPMENT.md) | [Português (Brasil)](../pt-BR/DEVELOPMENT.md) | [한국어](../ko/DEVELOPMENT.md) | [Italiano](../it/DEVELOPMENT.md) | [Русский](../ru/DEVELOPMENT.md)

Compila, prueba y depura la aplicación nativa de macOS y su extensión Quick Look. Consulta las funciones y los límites de los formatos en el [README](README.md).

[Requisitos](#requirements) · [Compilación](#build-local) · [Pruebas](#tests) · [Arquitectura](#how-it-works) · [Solución de problemas](#troubleshooting) · [Distribución](#distribution-signing--notarization)

Ejecuta los comandos desde la raíz del repositorio, salvo que se indique lo contrario.

<a id="requirements"></a>

## Requisitos

| Requisito | Notas |
| :--- | :--- |
| Mac con chip de Apple y macOS 26 o posterior | El proyecto y Assimp se compilan para `arm64`; no se genera una variante Intel. |
| Xcode completo con el SDK de macOS 26 o posterior | Las Command Line Tools no bastan. El entorno de desarrollo local actual usa Xcode 27.0. |
| XcodeGen | Genera el proyecto Xcode a partir de `project.yml`. |
| CMake y Ninja | Compilan la dependencia nativa Assimp. |
| Python 3 | Ejecuta el verificador de coherencia de las traducciones. |
| Identidad de firma de desarrollo | Necesaria para la aplicación instalada, su extensión y el App Group compartido. Consulta los pasos siguientes. |

```bash
brew install xcodegen cmake ninja
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

Si el shell selecciona las Command Line Tools u otra instalación de Xcode, selecciona Xcode completo antes de compilar:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`build.sh` también detecta esa instalación estándar cuando `xcode-select` apunta a las Command Line Tools. Los comandos directos de `xcodebuild` y de compilación de dependencias necesitan que el directorio de desarrollo ya sea correcto.

<a id="build-local"></a>

## Compilación local

<a id="configure-signing"></a>

### Configurar la firma

La configuración del repositorio usa el equipo definido en [`project.yml`](../../project.yml). Para usar tu propio equipo:

1. Configura `DEVELOPMENT_TEAM` e identificadores de bundle adecuados en `project.yml`.
2. Configura un App Group para ese equipo. Usa el mismo identificador en [`Spacebar3D.entitlements`](../../Spacebar3D/App/Spacebar3D.entitlements), [`Spacebar3DExtension.entitlements`](../../Spacebar3D/Extension/Spacebar3DExtension.entitlements) y `ViewerSettings.appGroup` en [`ViewerSettings.swift`](../../Spacebar3D/Shared/ViewerSettings.swift).
3. Comprueba que Xcode pueda usar el certificado Apple Development del equipo y los recursos de aprovisionamiento necesarios. Regenera el proyecto después de cambiar la configuración.

El App Group actual es `V3AQWQ8JMY.com.vitalis.Spacebar3D`. Cambiar solo el equipo en un comando de compilación no actualiza ese identificador. Las compilaciones sin firma o con firma ad hoc no sustituyen las pruebas de registro de la extensión y acceso al contenedor compartido.

<a id="build-the-app"></a>

### Compilar la aplicación

```bash
./scripts/build.sh
```

El script compila Assimp si falta su framework, ejecuta XcodeGen y compila el esquema `Spacebar3D` en configuración Release. Resultado:

```text
build/Build/Products/Release/Spacebar 3D.app
```

La primera compilación necesita acceso a la red para obtener dependencias. [`build-assimp.sh`](../../scripts/build-assimp.sh) fija Assimp en `v6.0.6` y comprueba el SHA completo del commit `a79ff6bbce54d3e01186a918dc6374ed55317426` antes de compilar. Genera un XCFramework estático arm64 con importadores FBX y 3DS, sin exportadores ni Draco.

Vuelve a ejecutar ese script cuando cambie la revisión fijada. `build.sh` comprueba si existe el framework, no si coincide con esa revisión. Para usar una copia local en el commit requerido:

```bash
ASSIMP_SRC=/path/to/assimp ./scripts/build-assimp.sh
```

<a id="register-and-exercise-quick-look"></a>

### Registrar y probar Quick Look

1. Copia la aplicación compilada a `/Applications` y abre esa copia una vez.
2. Activa **Spacebar 3D** en **Ajustes del Sistema → General → Ítems de inicio y extensiones → Quick Look**.
3. Selecciona un archivo compatible en Finder y pulsa Espacio.
4. Abre el mismo archivo desde **Archivo → Abrir…** en la aplicación para comprobar ambos entornos.

Si el registro está desactualizado, renueva la caché y prueba un archivo GLB:

```bash
qlmanage -r
qlmanage -r cache
qlmanage -p /path/to/model.glb
```

macOS puede elegir la vista previa de Apple para OBJ, STL, PLY, USD y USDZ. Eso no demuestra un fallo de esta extensión. Usa la aplicación o la sustitución opcional descrita en el [README](README.md#help).

<a id="development"></a>

## Desarrollo

Para editar y depurar en Xcode:

```bash
./scripts/build-assimp.sh
xcodegen generate
open Spacebar3D.xcodeproj
```

Compila Assimp una vez por revisión de la dependencia y regenera el proyecto cuando cambie `project.yml`. Git ignora `.xcodeproj`, los dos archivos `Info.plist` generados, la salida de compilación y `Vendor/Assimp.xcframework`. Edita el YAML, no el proyecto ni las listas de propiedades generadas.

Para una compilación Debug incremental desde el terminal:

```bash
xcodebuild -project Spacebar3D.xcodeproj -scheme Spacebar3D \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build build
```

`SKIP_XCODEGEN=1 ./scripts/build.sh` reutiliza el proyecto generado existente y sigue compilando en Release. Úsalo solo si el proyecto coincide con el YAML.

<a id="capture-media"></a>

### Grabar un vídeo de vista previa y tomar capturas

Ejecuta el script desde una sesión de escritorio de macOS tras cumplir los requisitos de compilación anteriores. En Ajustes del Sistema, concede permiso para grabar la pantalla a la aplicación desde la que ejecutas el script.

Si el modelo hace referencia a texturas, materiales o geometría externos, ábrelo primero en la aplicación habitual de Spacebar 3D. Usa el botón de carpeta del visor para conceder acceso a la carpeta que contiene esos archivos. La versión de captura usa el permiso guardado. Al abrir solo el archivo del modelo, los archivos asociados pueden quedar inaccesibles.

```bash
brew install ffmpeg
./scripts/capture-media.sh /path/to/model.glb
```

El script compila e inicia una copia independiente de Spacebar 3D con la captura habilitada. Para reutilizar una copia ya compilada con esta opción, indica la ruta de su paquete `.app` en `SPACEBAR3D_APP`. De forma predeterminada, el script crea una carpeta nueva dentro de `build/media-captures/`. Pasa una ruta sin usar como segundo argumento para elegir la carpeta de salida.

El vídeo público de vista previa del Mac App Store, `preview.mp4`, dura 30 segundos y muestra todos los estilos de renderizado disponibles para el modelo. Tiene una resolución de 1920 × 1080 a 30 fps. El script también guarda cuatro archivos PNG de 2560 × 1600 y `demo.gif`. Si el modelo tiene al menos tres estilos, el GIF usa el mismo montaje de 15 segundos que el bucle de estilos. Con menos estilos, usa la vista previa a su velocidad original. La primera captura usa la vista Texturizada si está disponible (`01-textured.png`) y la vista Sólida en los demás casos (`01-solid.png`). Las demás imágenes son `02-wireframe.png`, `03-normals.png` y `04-hologram.png`.

<a id="capture-feature-loop"></a>

### Grabar un vídeo en bucle de estilos

Usa la misma configuración de captura para grabar un bucle de 15 segundos a 30 fps. El modelo debe admitir al menos tres estilos de renderizado. Se da prioridad a Sombreado cel, Arte vóxel y Holograma.

```bash
./scripts/capture-feature-loop.sh /path/to/model.glb
```

De forma predeterminada, el script guarda `feature-loop.mp4` en una carpeta nueva dentro de `build/media-captures/`. Pasa una ruta sin usar como segundo argumento para elegir la carpeta de salida.

<a id="capture-screenshots"></a>

### Tomar capturas para el App Store

Usa la misma configuración de captura para generar los cuatro archivos PNG en sRGB de 2560 × 1600 indicados arriba.

```bash
./scripts/capture-screenshots.sh /path/to/model.glb
```

De forma predeterminada, el script guarda los archivos en una carpeta nueva dentro de `build/media-captures/`. Pasa una ruta sin usar como segundo argumento para elegir la carpeta de salida.

<a id="capture-app-review"></a>

### Grabar una demostración privada para App Review

Instala y abre la aplicación habitual de Spacebar 3D y activa su extensión de Quick Look. Elige un modelo que se abra de forma interactiva en Quick Look de Finder. Antes de grabar, cierra la vista previa de Quick Look en Finder y las ventanas del visor independiente con el mismo nombre de archivo. Usa el permiso de grabación de pantalla indicado arriba, las herramientas de línea de comandos de Swift y FFmpeg con los filtros `drawtext` y `subtitles`. Mantén visible el terminal y sigue sus avisos. Mantén el archivo seleccionado en Finder y cambia a la vista de lista si hace falta. Cuando se indique, pulsa Espacio y gira el modelo o cambia el zoom dos veces. Cuando se indique, haz clic en el botón para abrir con Spacebar 3D. Si macOS muestra un menú de aplicaciones, elige Spacebar 3D. Si el botón no está disponible, cierra Quick Look y abre el mismo archivo desde **Archivo → Abrir…** en Spacebar 3D. Gira el modelo o cambia el zoom dos veces en el visor independiente.

```bash
SPACEBAR3D_REVIEW_ANIMATION_MODEL=docs/app-store/Spacebar3D-Review-Model.glb \
  ./scripts/capture-app-review.sh /path/to/model.fbx build/media-captures/app-review
```

El script añade rótulos y guarda `app-review.mp4` en una carpeta nueva dentro de `build/media-captures/`. Para elegir la carpeta de salida, pasa como segundo argumento una ruta sin usar. Define `SPACEBAR3D_REVIEW_APP` si la aplicación está instalada en una ruta distinta de `/Applications/Spacebar 3D.app`.

Después de la grabación guiada, el script graba capítulos sobre los controles del visor, los ajustes, la ayuda y la privacidad. El ejemplo añade la reproducción con el modelo de muestra animado. Define `SPACEBAR3D_REVIEW_CAPTURE_APP` para reutilizar una aplicación ya compilada para captura. De forma predeterminada, el script la compila con la configuración de desarrollo indicada arriba.

Si ya tienes una grabación de los pasos guiados en Finder y el visor, `capture-review-features.sh` puede añadir los capítulos. Consulta `--help`.

<a id="tests"></a>

## Pruebas

Compila Assimp antes de resolver el paquete o ejecutar cualquiera de las dos vías de prueba.

<a id="full-xcode-suite"></a>

### Suite completa de Xcode

Este es el comando principal de regresión. Incluye las pruebas de las fuentes de la aplicación, el código compartido y la extensión, además de los nueve targets de prueba del paquete declarados en `project.yml`.

```bash
xcodegen generate
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build
python3 scripts/check-localizations.py
```

Para limitar la ejecución, añade un selector `-only-testing`, por ejemplo:

```bash
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build \
  -only-testing:ViewerUITests/NativeViewerInputTests
```

Xcode guarda los bundles `.xcresult` en `build/Logs/Test/`.

<a id="package-only-tests"></a>

### Pruebas solo del paquete

No incluyen las pruebas de las fuentes anfitrionas de `Spacebar3DTests`:

```bash
xcrun swift test --package-path Packages/Spacebar3DKit
```

Dos pruebas de modelos grandes se activan con `P3D_LARGE=1`. Una crea un archivo STL de prueba de unos 100 MB. Para ejecutar explícitamente ese benchmark:

```bash
P3D_LARGE=1 xcrun swift test --package-path Packages/Spacebar3DKit \
  --filter LargeModelTests
```

<a id="what-the-tests-establish"></a>

### Qué verifican las pruebas

- Las pruebas de ajustes usan almacenamiento temporal explícito. Añade casos de normalización a [`settings-vectors.json`](../../testdata/settings-vectors.json) cuando cambien las reglas.
- Las pruebas de importación crean archivos pequeños y comprueban entradas malformadas y truncadas.
- Las pruebas de renderizado dibujan fuera de pantalla e inspeccionan píxeles; requieren un dispositivo Metal funcional.
- Las pruebas del visor cubren entrada nativa, metadatos de accesibilidad, comandos, disposición y controles SwiftUI, incluidas comprobaciones con ViewInspector.
- Las comprobaciones de localización validan la cobertura de claves, las entradas del catálogo y los marcadores de posición. Las pruebas del paquete también verifican los recursos de idioma compilados.

El esquema de Xcode compila las fuentes anfitrionas en un bundle de pruebas. No ejecuta la aplicación firmada dentro de su sandbox de producción. Que pase no demuestra que funcionen el registro de Quick Look, los permisos de carpetas, la voz de VoiceOver ni una descarga notarizada. Para esos cambios, prueba también la aplicación firmada instalada y la extensión de Finder.

<a id="how-it-works"></a>

## Funcionamiento

```text
Finder → Quick Look extension ─┐
                              ├─ ViewerFactory → NativeViewer
App → model window ───────────┘                      │
                                     ImportRouter → ModelScene
                                                     │
                                           RenderMetal / MTKView
                                           + SwiftUI controls
```

Ambos anfitriones comparten el paquete local `Spacebar3DKit`. La importación se ejecuta fuera del hilo principal; el visor nativo coordina el renderizado y los controles.

| Área | Responsabilidad |
| :--- | :--- |
| `Spacebar3D/App/` | Configuración, ajustes, ventanas de modelos, registro como aplicación predeterminada, menús, ayuda y créditos. |
| `Spacebar3D/Extension/` | Ciclo de vida de la vista previa de Quick Look. |
| `Spacebar3D/Shared/` | Creación del visor y ajustes compartidos. |
| `Packages/Spacebar3DKit/Sources/ModelCore/` | Datos de escena, detección de formato, animación, topología y localización. |
| `…/Sources/ImportRouter/` y `…/Sources/Import*/` | Selección de formato y lectores. |
| `…/Sources/RenderMetal/` | Escena GPU, cámara, sombreado y renderizado. |
| `…/Sources/ViewerUI/` | API del visor, entrada nativa, controles SwiftUI y permisos de carpetas. |
| `…/Sources/CZstd/` | Decodificador Zstandard incluido para archivos Blender comprimidos. |
| `Spacebar3DTests/` y `Packages/Spacebar3DKit/Tests/` | Pruebas de las fuentes anfitrionas y del paquete. |
| `docs/<language-code>/README.md` | Los nueve README traducidos. |
| `docs/<language-code>/DEVELOPMENT.md` | Las nueve guías de desarrollo traducidas. |

Los lectores nativos en Swift procesan STL, PLY, OBJ, 3MF, glTF/GLB, VRM/VRMA y Blender. Model I/O procesa USD; Assimp, FBX y 3DS. `FormatDetector` examina los primeros bytes y, en formatos de texto ambiguos, la extensión. Los tipos de documento y `QLSupportedContentTypes` se declaran en `project.yml`.

Los archivos que solo contienen animación y tienen un esqueleto compatible pueden mostrar una vista previa esquemática del esqueleto. No se incluye ningún avatar predeterminado. La compatibilidad es intencionalmente menor que la de una aplicación DCC completa. Mantén actualizados los límites del README al cambiar los lectores.

<a id="implementation-notes"></a>

## Notas de implementación

<a id="sandbox-and-related-files"></a>

### Sandbox y archivos relacionados

Ambos targets usan App Sandbox y acceso de solo lectura a archivos seleccionados por el usuario. Ninguno tiene permiso de red ni excepciones temporales al sandbox.

Abrir un modelo no concede acceso ilimitado a los archivos vecinos. Ambos anfitriones pueden ofrecer **Mostrar modelo…**, **Mostrar materiales…** o **Mostrar texturas…** para solicitar su carpeta. La aplicación también admite determinados archivos de materiales asociados con el mismo nombre, como `ship.mtl` junto a `ship.obj`, mediante su gestión de archivos relacionados.

[`FolderGrants.swift`](../../Packages/Spacebar3DKit/Sources/ViewerUI/FolderGrants.swift) guarda los permisos de la aplicación como marcadores con ámbito de seguridad. Quick Look guarda sus propios marcadores normales y lee las copias que la aplicación actualiza en el contenedor compartido. Un permiso exclusivo de Quick Look debe renovarse tras reiniciar el Mac. Abrir la aplicación actualiza sus permisos recordados para la extensión. El acceso de lectura se limita a las carpetas autorizadas y sus descendientes.

<a id="settings"></a>

### Ajustes

`ViewerSettings` guarda `viewer-settings.json` en el contenedor App Group. La aplicación lo escribe; los nuevos visores cargan sus valores normalizados. Si los ajustes faltan, son inválidos o demasiado grandes, se usan los valores predeterminados. No se migran desde la antigua ubicación fuera del contenedor, `~/Library/Application Support/Spacebar3D/`.

<a id="input-and-accessibility"></a>

### Entrada y accesibilidad

Las flechas orbitan y Mayús-flechas desplazan la cámara solo cuando el lienzo del modelo en la aplicación gestiona el teclado. Espacio reproduce o pausa allí; no es un atajo global de menú y no debe interceptar la activación de botones o deslizadores con el foco. Quick Look conserva Espacio para cerrar. Los menús y las acciones de accesibilidad ofrecen alternativas a los gestos del puntero.

Al cambiar controles, comprueba el foco, ventanas estrechas, traducciones largas, Aumentar contraste y Reducir transparencia. Escucha los anuncios reales de VoiceOver por separado de las comprobaciones del árbol de accesibilidad.

<a id="localization-and-documentation"></a>

### Localización y documentación

El catálogo compartido `Packages/Spacebar3DKit/Sources/ModelCore/Resources/Localizable.xcstrings` sirve a la aplicación y la extensión en diez idiomas. Sigue [LOCALIZATION.md](../LOCALIZATION.md) para las cadenas completas, los marcadores de posición, los recursos compilados y las comprobaciones de disposición.

El README inglés está en la raíz; las traducciones están en `docs/<language-code>/`. Las guías de desarrollo están en esas mismas carpetas, con la fuente inglesa en `docs/DEVELOPMENT.md`. Mantén coherentes los límites de formatos, controles, instalación, permisos y procedimientos de desarrollo entre versiones.

<a id="troubleshooting"></a>

## Solución de problemas

| Síntoma | Comprobación |
| :--- | :--- |
| Falta Assimp al resolver el paquete | Ejecuta `./scripts/build-assimp.sh` con Xcode completo, CMake y Ninja disponibles. |
| Falla la firma o no se accede a los ajustes compartidos | Comprueba certificado, equipo, identificadores de bundle y App Group. Una variable de entorno no reescribe por sí sola los entitlements. |
| Los cambios desaparecen al generar | Modifica `project.yml`, no `.xcodeproj` ni los `Info.plist` generados. |
| Falta la extensión o se carga una versión antigua | Abre la copia instalada correcta, activa la extensión, revisa el registro y actualiza Quick Look. No confundas la copia instalada con la del directorio de compilación. |
| Se abre el visor de Apple | Consulta los límites anteriores y compara con Archivo → Abrir en la aplicación. |
| Faltan texturas o geometría | Lee el aviso, autoriza la carpeta y revisa los límites del formato y los archivos asociados. |
| Falla una prueba GPU | Comprueba que Metal esté disponible e investiga el fallo. La ausencia de GPU no equivale a una prueba de renderizado superada. |

Inspecciona el registro de la extensión y sigue sus registros:

```bash
pluginkit -m | rg -i spacebar3d
log stream --predicate 'process == "Spacebar3DExtension"'
```

El primer comando usa `rg` de ripgrep; también sirve `grep -i spacebar3d`. En otro terminal, ejecuta `qlmanage -p /path/to/model.glb`. Un modelo rechazado debe mostrar un error en la vista previa. Comprueba si falla la importación, el renderizado, el acceso o la selección de extensión antes de cambiar la firma o los permisos.

<a id="distribution-signing--notarization"></a>

## Distribución, firma y notarización

Los scripts implementan la **distribución directa con Developer ID mediante un DMG**. No archivan, exportan ni suben una compilación al Mac App Store. La tienda necesita un proceso separado de firma, archivo, exportación y envío a App Store Connect.

Para distribución directa, usa una identidad Developer ID Application y notarización. La [guía de Apple](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) explica los requisitos de firma y del servicio. No se reproducen aquí los precios de membresía.

<a id="manual"></a>

### Proceso manual

Tras configurar identificadores de equipo y App Group coincidentes:

```bash
SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ./scripts/build.sh
```

Con `SIGN_IDENTITY`, el script selecciona firma manual, pasa `DEVELOPMENT_TEAM`, añade una marca de tiempo segura y desactiva la inyección de entitlements básicos de depuración. Hardened Runtime está activado en `project.yml`. Sin `SIGN_IDENTITY`, usa la configuración de firma de desarrollo del proyecto.

Para la notarización local, usa preferentemente un perfil del llavero. Guarda las credenciales de forma interactiva con `notarytool` y después usa el nombre del perfil:

```bash
xcrun notarytool store-credentials "spacebar3d-notary"
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" ./scripts/notarize.sh
```

El script acepta una ruta de aplicación opcional:

```bash
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" \
  ./scripts/notarize.sh "/path/to/Spacebar 3D.app"
```

La autenticación se elige en este orden:

| Método | Variables |
| :--- | :--- |
| Perfil del llavero | `NOTARY_KEYCHAIN_PROFILE` |
| Clave API de App Store Connect | `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER` |
| Credenciales de la cuenta de Apple | `APPLE_TEAM_ID`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` |

El último método pasa una contraseña específica de aplicación como argumento de `notarytool`; el perfil del llavero evita esto en un equipo compartido. No guardes claves de firma ni credenciales en el repositorio.

`notarize.sh` verifica la firma Developer ID de la aplicación y crea un DMG con un acceso directo a Applications. Firma el DMG con la identidad de la firma de la aplicación o con `SIGN_IDENTITY` si está definida. El certificado y la clave privada deben estar disponibles en el llavero. El script envía el DMG a Apple, espera su aceptación, adjunta y valida el ticket y comprueba Gatekeeper con `spctl`. Cuando pasan todas las comprobaciones, escribe `Spacebar3D.dmg` en la raíz del repositorio. Prueba el archivo descargado antes de compartirlo.

<a id="automated-github-actions"></a>

### Automatización con GitHub Actions

[El flujo de publicación](../../.github/workflows/release.yml) se ejecuta en el runner `macos-26` con Apple silicon y Xcode 26. Sube o selecciona una etiqueta con el formato `vMAJOR.MINOR.PATCH` que coincida con `MARKETING_VERSION` y apunte a un commit de `origin/main`.

El flujo genera el proyecto y ejecuta `Spacebar3DTests` y la comprobación de localización antes de importar el certificado de firma. Compila con Developer ID, compara las versiones de la aplicación y la extensión con la etiqueta, y firma y notariza el DMG. Elimina el llavero temporal antes de adjuntar el DMG a una GitHub Release.

Configura estos secretos en **el repositorio de destino real**:

| Secreto | Contenido |
| :--- | :--- |
| `MACOS_CERTIFICATE` | Certificado Developer ID Application y clave privada exportados como `.p12`, codificados en Base64. |
| `MACOS_CERTIFICATE_PWD` | Contraseña de ese `.p12`. |
| `KEYCHAIN_PASSWORD` | Contraseña del llavero temporal de compilación. |
| `APPLE_TEAM_ID` | Identificador del equipo de firma. |
| `NOTARY_APPLE_ID` | Cuenta de Apple para notarización. |
| `NOTARY_PASSWORD` | Su contraseña específica de aplicación. |

Especifica el repositorio al configurar secretos, por ejemplo `gh secret set APPLE_TEAM_ID --repo OWNER/REPOSITORY`, que solicita el valor. No supongas que `origin` identifica un repositorio existente o el destino de publicación previsto.

Antes de crear una etiqueta de publicación, establece `MARKETING_VERSION` y `CURRENT_PROJECT_VERSION` en `project.yml`, actualiza el registro de cambios, ejecuta las pruebas y verifica la compilación firmada. Subir la etiqueta correspondiente puede publicar una GitHub Release si el flujo finaliza correctamente.

<a id="references"></a>

## Referencias

- [Arquitectura del renderizador nativo](../architecture/native-rewrite.md)
- [Diseño del visor](../design/neon-garden-viewer.md)
- [Localización](../LOCALIZATION.md)
- [Licencias de terceros](../../THIRD_PARTY_LICENSES.md)
- [Apple: personalizar la notarización](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [magicien/VRMQuickLook](https://github.com/magicien/VRMQuickLook), implementación VRM 0.x con SceneKit
- [magicien/GLTFQuickLook](https://github.com/magicien/GLTFQuickLook), referencia de estructura Quick Look
- [pixiv/three-vrm](https://github.com/pixiv/three-vrm), referencia del comportamiento VRM
