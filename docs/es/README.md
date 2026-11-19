<p align="center">
  <img src="../../Packages/Spacebar3DKit/Sources/ViewerUI/Resources/Mark.png" width="200" alt="Camaleón de Spacebar 3D, mitad malla de alambre y mitad sombreado">
</p>

<h1 align="center">Spacebar 3D</h1>
<p align="center"><strong>Tus modelos, a una tecla de distancia.</strong></p>
<p align="center">Un visor 3D nativo para Finder Quick Look y tu Mac.</p>
<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-111e17?style=flat-square" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple_silicon-arm64-a8e6a3?style=flat-square" alt="Apple silicon / arm64">
  <img src="https://img.shields.io/badge/renderer-Metal-b5cfff?style=flat-square" alt="Metal">
  <a href="../../LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-f05b99?style=flat-square" alt="Apache License 2.0"></a>
</p>
<p align="center">
  <a href="#install">Primeros pasos</a> · <a href="#formats">Formatos</a> · <a href="#controls">Controles</a> · <a href="DEVELOPMENT.md">Guía de desarrollo</a>
</p>
<p align="center"><a href="../../README.md">English</a> · <a href="../zh-Hans/README.md">简体中文</a> · <strong>Español</strong> · <a href="../fr/README.md">Français</a> · <a href="../de/README.md">Deutsch</a> · <a href="../ja/README.md">日本語</a> · <a href="../pt-BR/README.md">Português do Brasil</a> · <a href="../ko/README.md">한국어</a> · <a href="../it/README.md">Italiano</a> · <a href="../ru/README.md">Русский</a></p>

---

## Encuéntralo. Pulsa Espacio. Gíralo.

Selecciona un archivo 3D compatible en Finder y pulsa <kbd>Espacio</kbd>. Gira el modelo, inspecciona su topología, cambia su aspecto o recorre una animación. Ábrelo en la aplicación para tener una ventana de visualización propia.

<p align="center">
  <img src="../demo.gif" width="900" alt="Modelo de un tanque en el visor de Spacebar 3D con los controles visibles">
</p>

> macOS puede elegir su propia vista previa para OBJ, STL, PLY, USD y USDZ. **Archivo → Abrir…** o **Abrir con → Spacebar 3D** en Finder abre cualquier archivo compatible en este visor.

<a id="looks"></a>

## Un modelo, muchos aspectos

| Inspecciona | Explora | Reproduce |
| :--- | :--- | :--- |
| Vistas Sólida, Texturizada y Normales; malla de alambre superpuesta; recuentos de caras y vértices. | Estilos sin sombreado, de anime, de sombreado cel, retro, de arte vóxel y de holograma; sombreado plano o suave y ajustes de materiales. | Selección de clips, desplazamiento por la animación y repetición; esqueletos para archivos compatibles que solo contienen animación. |

**Elige la luz.** Siete ambientes, desde Glasshouse hasta Neon, con brillo, dirección y rotación automática de la luz. **Oriéntate.** Pulsa un eje del gizmo, gira, desplaza, encuadra el modelo o activa la cuadrícula del suelo. Las vistas previas pequeñas de Finder muestran solo el modelo.

**Nativo de Mac.** Swift, Metal, SwiftUI y AppKit, compartidos por la aplicación y la extensión Quick Look. Los modelos se procesan localmente; ninguno de los dos componentes tiene permisos de red. La interfaz admite los diez idiomas del selector superior y sigue las preferencias de macOS. [Notas de localización, en inglés](../LOCALIZATION.md).

<a id="install"></a>

## Primeros pasos

**macOS 26 o posterior · Apple silicon · compilación desde el código fuente**

Necesitas Xcode completo con el SDK de macOS 26 o posterior, XcodeGen, CMake y Ninja. Antes de compilar con otro equipo de desarrollo, configura tu identidad de firma y los identificadores del App Group según la [guía de firma](DEVELOPMENT.md#build-local).

Desde tu copia local del repositorio:

```bash
brew install xcodegen cmake ninja
./scripts/build.sh
```

La primera compilación descarga y compila la versión fijada de Assimp.

1. Mueve `build/Build/Products/Release/Spacebar 3D.app` a **Aplicaciones**.
2. **Abre la aplicación una vez** para registrar la extensión.
3. En **Ajustes del Sistema → General → Ítems de inicio y extensiones → Quick Look**, activa **Spacebar 3D**.
4. Selecciona un archivo compatible en Finder y pulsa <kbd>Espacio</kbd>.

Para distribuir la aplicación, consulta la [guía de firma Developer ID y notarización](DEVELOPMENT.md#distribution-signing--notarization).

<details>
<summary><strong>Usar Spacebar 3D como visor predeterminado</strong></summary>

En los ajustes de la aplicación, pulsa **Usar por omisión…**. macOS puede pedir confirmación; la aplicación indica los formatos que no pudo cambiar. Esto afecta al doble clic en Finder, no a la elección de la extensión Quick Look.

</details>

<a id="formats"></a>

## Formatos compatibles

Avatares, recursos de juegos, exportaciones CAD, escaneos y mallas de Blender.

`VRM` · `VRMA` · `glTF` · `GLB` · `FBX` · `OBJ` · `STL` · `3MF` · `PLY` · `USD` · `USDA` · `USDC` · `USDZ` · `3DS` · `BLEND`

<details>
<summary><strong>Compatibilidad y limitaciones por formato</strong></summary>

| Formato | Compatibilidad |
| :--- | :--- |
| `.vrm` | Avatares VRM 0.x / 1.0: sombreado toon, contornos y spring bones. |
| `.vrma` | Animación VRM sin malla; se reproduce sobre una figura de palitos del esqueleto. |
| `.glb` / `.gltf` | glTF 2.0 con materiales, texturas, skins y animaciones. Los archivos `.bin` e imágenes externos requieren acceso a la carpeta. No se admiten Draco, Meshopt ni mallas instanciadas. |
| `.fbx` | Binario o texto; mallas con skinning y animación integrada. Imágenes incrustadas, junto al archivo o en su carpeta `.fbm`. |
| `.obj` | Geometría y colores de vértices; materiales y texturas de `.mtl` al autorizar la carpeta. Sin caras, se muestra una nube de puntos. |
| `.stl` | STL binario o de texto. |
| `.3mf` | Colores por objeto o triángulo, imágenes y materiales metálicos y translúcidos. |
| `.ply` | Mallas con colores de vértices o nubes de puntos si no hay caras. |
| `.usd` / `.usda` / `.usdc` / `.usdz` | Materiales, texturas incrustadas y animación esquelética. |
| `.3ds` | Colores y transparencia de materiales; texturas externas al autorizar la carpeta. |
| `.blend` | Blender 2.80 o posterior: mallas visibles y materiales básicos tal como se guardaron; imágenes empaquetadas y texturas de la carpeta autorizada. No se aplican modificadores, poses de armadura ni animaciones; no se evalúan redes arbitrarias de nodos de sombreado. |

Los FBX que solo contienen animación y los VRMA con esqueletos compatibles se muestran como figuras de palitos. No se incluyen datos de modelos ni avatares.

</details>

### Texturas en archivos separados

Usa **Mostrar texturas…**, **Mostrar materiales…** o **Mostrar modelo…** para autorizar acceso de solo lectura a la carpeta del modelo y sus subcarpetas. Las texturas incrustadas no necesitan ese permiso, pero deben tener formatos de imagen y material compatibles. En la aplicación, un archivo de material con el mismo nombre, como `ship.mtl` junto a `ship.obj`, puede leerse sin preguntar.

Si el modelo se abre pero no se puede mostrar ninguna de las texturas referenciadas, el visor cambia de **Texturizada** a **Sólida**.

<a id="controls"></a>

## Toma el control

| Acción | Control |
| :--- | :--- |
| Girar | Arrastrar; flechas con el lienzo de la aplicación enfocado |
| Desplazar | Arrastrar con el botón derecho o manteniendo Mayús, Opción o Comando |
| Desplazar con teclado | Mayús + flechas en el lienzo de la aplicación, o el submenú de desplazamiento de Vista |
| Acercar o alejar | Desplazamiento de rueda/trackpad o gesto de pellizco |
| Encuadrar el modelo | Botón de encuadre o ⌘0 en la aplicación |
| Mirar a lo largo de un eje | Pulsar un eje del gizmo |
| Reproducir o pausar | Botón de reproducción o Espacio con el lienzo de la aplicación enfocado |
| Cerrar Quick Look | Espacio |
| Sólido / Texturizado / Normal | ⌘1 / ⌘2 / ⌘3 en la aplicación |
| Malla de alambre | ⌘4 en la aplicación |

La barra inferior contiene vistas, estilos y materiales. A la derecha están el gizmo, la luz, el encuadre, la cuadrícula y la rotación automática. La barra de animación permite elegir clips y repetirlos. Los ajustes guardan tus preferencias de fondo, color sólido, vista, brillo, cuadrícula, rotación y animación. Los menús Vista y Reproducción también ofrecen comandos cuando los controles del lienzo están ocultos.

<a id="help"></a>

## Si necesitas ayuda

Abre el menú **?** de la barra de herramientas del visor para consultar los controles, la política de privacidad y los agradecimientos. Está disponible en la aplicación y en Quick Look.

¿Has encontrado un problema o tienes una pregunta? En la aplicación, elige **Ayuda → Soporte de Spacebar 3D** o [abre una incidencia](https://github.com/vitalis/Spacebar3D/issues).

<details>
<summary><strong>No aparece la vista previa</strong></summary>

Abre la aplicación una vez y activa la extensión. Si sigue sin aparecer, actualiza la caché:

```bash
qlmanage -r && qlmanage -r cache
```

Para OBJ, STL, PLY, USD y USDZ, prueba a abrir el archivo directamente en la aplicación.

</details>

<details>
<summary><strong>Preferir Spacebar 3D a las vistas previas de Apple</strong></summary>

La anulación opcional es reversible:

```bash
scripts/prefer-spacebar3d.sh status
scripts/prefer-spacebar3d.sh on
scripts/prefer-spacebar3d.sh off
```

`on` prefiere Spacebar 3D; `off` restaura las extensiones de Apple. El script desactiva dos extensiones de Apple para tu cuenta mediante `pluginkit`, sin cambiar archivos del sistema. MaterialX y Alembic reciben una vista previa más sencilla, USDZ pierde la vista AR y `.reality` queda sin vista previa. Una actualización de macOS puede restablecer la selección. Abrir archivos en la aplicación no requiere este cambio.

</details>

<details>
<summary><strong>Faltan texturas</strong></summary>

Autoriza la carpeta con **Mostrar texturas…**. Un permiso concedido solo en Quick Look debe renovarse después de reiniciar el Mac. La aplicación recuerda sus permisos; abrirla una vez tras reiniciar los vuelve a poner a disposición de Quick Look. Los archivos ausentes y los materiales o formatos de imagen no compatibles pueden impedir que aparezca una textura.

</details>

<a id="architecture"></a>

## Por dentro

La aplicación y la extensión comparten `Spacebar3DKit`: `ImportRouter` lee el archivo, crea un `ModelScene` y Metal lo dibuja. Los lectores Swift procesan STL, PLY, OBJ, 3MF, glTF, VRM y Blender; Model I/O procesa USD; Assimp procesa FBX y 3DS.

[Compilación y arquitectura](DEVELOPMENT.md) · [Localización](../LOCALIZATION.md) · [Historial de cambios](../../CHANGELOG.md) · [Política de privacidad en inglés](../../PRIVACY.md)

<a id="credits"></a>

## Créditos y licencia

Spacebar 3D se distribuye bajo la [Licencia Apache, versión 2.0](../../LICENSE).
Copyright © 2026 Vitaly Gorodetsky.

Consulta [CREDITS.md](../../CREDITS.md) para conocer los orígenes, colaboradores y agradecimientos del proyecto, y las [licencias de terceros](../../THIRD_PARTY_LICENSES.md) para los componentes con licencias propias. Estos avisos también están disponibles en los agradecimientos del menú Ayuda de la aplicación.
