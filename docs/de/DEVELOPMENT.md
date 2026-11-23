# Spacebar 3D entwickeln

[English](../DEVELOPMENT.md) | [简体中文](../zh-Hans/DEVELOPMENT.md) | [Español](../es/DEVELOPMENT.md) | [Français](../fr/DEVELOPMENT.md) | **Deutsch** | [日本語](../ja/DEVELOPMENT.md) | [Português (Brasil)](../pt-BR/DEVELOPMENT.md) | [한국어](../ko/DEVELOPMENT.md) | [Italiano](../it/DEVELOPMENT.md) | [Русский](../ru/DEVELOPMENT.md)

Die native macOS-App und ihre Quick-Look-Erweiterung bauen, testen und debuggen. Funktionen und Einschränkungen der unterstützten Formate stehen in der [README](README.md).

[Voraussetzungen](#requirements) · [Build](#build-local) · [Tests](#tests) · [Architektur](#how-it-works) · [Fehlerbehebung](#troubleshooting) · [Verteilung](#distribution-signing--notarization)

Alle Shell-Befehle werden im Stammverzeichnis des Repositorys ausgeführt, sofern nicht anders angegeben.

<a id="requirements"></a>

## Voraussetzungen

| Voraussetzung | Hinweise |
| :--- | :--- |
| Mac mit Apple Chip und macOS 26 oder neuer | Projekt und Assimp bauen für `arm64`; es wird keine Intel-Variante erzeugt. |
| Vollständiges Xcode mit macOS-26-SDK oder neuer | Command Line Tools allein reichen nicht. Die aktuelle lokale Entwicklungsumgebung nutzt Xcode 27.0. |
| XcodeGen | Erzeugt das Xcode-Projekt aus `project.yml`. |
| CMake und Ninja | Bauen die native Abhängigkeit Assimp. |
| Python 3 | Führt die Konsistenzprüfung der Übersetzungen aus. |
| Entwicklungssignatur | Für installierte App, Erweiterung und gemeinsame App Group erforderlich. Siehe unten. |

```bash
brew install xcodegen cmake ninja
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

Wenn deine Shell Command Line Tools oder eine andere Xcode-Installation auswählt, wähle vor dem Build das vollständige Xcode für diese Shell:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`build.sh` erkennt diese Standardinstallation auch dann, wenn `xcode-select` auf Command Line Tools zeigt. Direkte Aufrufe von `xcodebuild` und Befehle zum Bauen der Abhängigkeiten benötigen bereits das richtige Entwicklerverzeichnis.

<a id="build-local"></a>

## Lokal bauen

<a id="configure-signing"></a>

### Signierung einrichten

Die eingecheckte Konfiguration nutzt das Team aus [`project.yml`](../../project.yml). Für dein eigenes Team:

1. Setze `DEVELOPMENT_TEAM` und passende Bundle-Kennungen in `project.yml`.
2. Richte eine App Group für das Team ein. Verwende dieselbe Gruppenkennung in [`Spacebar3D.entitlements`](../../Spacebar3D/App/Spacebar3D.entitlements), [`Spacebar3DExtension.entitlements`](../../Spacebar3D/Extension/Spacebar3DExtension.entitlements) und `ViewerSettings.appGroup` in [`ViewerSettings.swift`](../../Spacebar3D/Shared/ViewerSettings.swift).
3. Stelle sicher, dass Xcode das Apple-Development-Zertifikat des Teams und erforderliche Provisioning-Dateien verwenden kann. Erzeuge das Projekt nach Konfigurationsänderungen neu.

Die aktuelle App Group lautet `V3AQWQ8JMY.com.vitalis.Spacebar3D`. Nur das Team im Build-Befehl zu ändern, aktualisiert diese Kennung nicht. Unsignierte oder ad hoc signierte Builds ersetzen keine Prüfung der Erweiterungsregistrierung und des Zugriffs auf den gemeinsamen Container.

<a id="build-the-app"></a>

### App bauen

```bash
./scripts/build.sh
```

Das Skript baut Assimp, falls dessen Framework fehlt, führt XcodeGen aus und baut das Schema `Spacebar3D` in der Konfiguration Release. Ausgabe:

```text
build/Build/Products/Release/Spacebar 3D.app
```

Der erste Build benötigt Netzwerkzugriff für Abhängigkeiten. [`build-assimp.sh`](../../scripts/build-assimp.sh) legt Assimp auf `v6.0.6` fest und prüft vor dem Kompilieren die vollständige Commit-SHA `a79ff6bbce54d3e01186a918dc6374ed55317426`. Es entsteht ein statisches arm64-XCFramework mit FBX- und 3DS-Importern, ohne Exporter oder Draco.

Führe das Skript erneut aus, wenn sich die festgelegte Revision ändert. `build.sh` prüft nur, ob das Framework existiert, nicht dessen Revision. Für einen vorhandenen Checkout am benötigten Commit:

```bash
ASSIMP_SRC=/path/to/assimp ./scripts/build-assimp.sh
```

<a id="register-and-exercise-quick-look"></a>

### Quick Look registrieren und prüfen

1. Kopiere die gebaute App nach `/Applications` und starte diese Kopie einmal.
2. Aktiviere **Spacebar 3D** unter **Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen → Quick Look**.
3. Wähle im Finder eine unterstützte Datei und drücke die Leertaste.
4. Öffne dieselbe Datei über **Ablage → Öffnen…** in der App, um beide Umgebungen zu prüfen.

Bei veralteter Registrierung aktualisiere den Cache und teste eine GLB-Datei:

```bash
qlmanage -r
qlmanage -r cache
qlmanage -p /path/to/model.glb
```

macOS kann für OBJ, STL, PLY, USD und USDZ Apples eigene Vorschau wählen. Das belegt keinen Fehler dieser Erweiterung. Nutze die App oder die optionale Umstellung aus der [README](README.md#help).

<a id="development"></a>

## Entwicklung

Zum Bearbeiten und Debuggen in Xcode:

```bash
./scripts/build-assimp.sh
xcodegen generate
open Spacebar3D.xcodeproj
```

Baue Assimp einmal pro Abhängigkeitsrevision und erzeuge das Projekt bei Änderungen an `project.yml` neu. Git ignoriert `.xcodeproj`, beide erzeugten `Info.plist`-Dateien, Build-Ausgaben und `Vendor/Assimp.xcframework`. Bearbeite die YAML-Quelle statt der erzeugten Projekt- und Property-List-Dateien.

Für einen inkrementellen Debug-Build im Terminal:

```bash
xcodebuild -project Spacebar3D.xcodeproj -scheme Spacebar3D \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build build
```

`SKIP_XCODEGEN=1 ./scripts/build.sh` verwendet das vorhandene erzeugte Projekt erneut und baut weiterhin Release. Nutze dies nur, wenn das Projekt zur YAML-Datei passt.

<a id="capture-media"></a>

### Vorschauvideo und Screenshots aufnehmen

Führe das Skript in einer angemeldeten macOS-Desktopsitzung aus. Es gelten die oben beschriebenen Build-Voraussetzungen. Erlaube der App, aus der du das Skript startest, in den Systemeinstellungen die Bildschirmaufnahme.

Wenn das Modell externe Texturen, Materialien oder Geometrie referenziert, öffne es zuerst in der regulären Spacebar 3D-App. Erteile über die Ordnerschaltfläche im Viewer Zugriff auf den Ordner mit diesen Dateien. Der Aufnahme-Build übernimmt die gespeicherte Freigabe. Beim Öffnen der einzelnen Modelldatei können Begleitdateien unzugänglich bleiben.

```bash
brew install ffmpeg
./scripts/capture-media.sh /path/to/model.glb
```

Das Skript baut und startet eine separate Kopie von Spacebar 3D mit aktivierter Aufnahmefunktion. Um eine bereits dafür gebaute App zu verwenden, setze `SPACEBAR3D_APP` auf den Pfad ihres `.app`-Pakets. Standardmäßig legt das Skript einen neuen Ordner unter `build/media-captures/` an. Mit einem noch freien Pfad als zweitem Argument wählst du den Ausgabeordner.

Die öffentliche Mac App Store-Vorschau `preview.mp4` dauert 30 Sekunden und zeigt alle für das Modell verfügbaren Darstellungsstile. Das Video hat 1920 × 1080 Pixel und 30 Bilder pro Sekunde. Das Skript speichert außerdem vier PNG-Dateien mit 2560 × 1600 Pixeln und `demo.gif`. Bei Modellen mit mindestens drei Darstellungsstilen verwendet das GIF denselben 15-Sekunden-Schnitt wie die Stilschleife. Bei weniger Stilen zeigt es die Vorschau in Originalgeschwindigkeit. Der erste Screenshot zeigt die Ansicht „Texturiert“, wenn sie verfügbar ist (`01-textured.png`), sonst die Vollansicht (`01-solid.png`). Die übrigen Bilder heißen `02-wireframe.png`, `03-normals.png` und `04-hologram.png`.

<a id="capture-feature-loop"></a>

### Eine Stilschleife aufnehmen

Erstelle mit denselben Aufnahmevoraussetzungen eine 15 Sekunden lange Schleife mit 30 Bildern pro Sekunde. Das Modell muss mindestens drei Darstellungsstile unterstützen. Bevorzugt werden Cel-Shading, Voxelkunst und Hologramm.

```bash
./scripts/capture-feature-loop.sh /path/to/model.glb
```

Das Skript speichert `feature-loop.mp4` standardmäßig in einem neuen Ordner unter `build/media-captures/`. Mit einem noch freien Pfad als zweitem Argument wählst du den Ausgabeordner.

<a id="capture-screenshots"></a>

### App Store-Screenshots aufnehmen

Erstelle mit denselben Aufnahmevoraussetzungen die vier oben genannten sRGB-PNGs mit 2560 × 1600 Pixeln.

```bash
./scripts/capture-screenshots.sh /path/to/model.glb
```

Das Skript speichert die Dateien standardmäßig in einem neuen Ordner unter `build/media-captures/`. Mit einem noch freien Pfad als zweitem Argument wählst du den Ausgabeordner.

<a id="capture-app-review"></a>

### Ein privates Video für App Review aufnehmen

Installiere und starte die reguläre Spacebar 3D-App und aktiviere ihre Quick Look-Erweiterung. Wähle ein Modell, das sich in Quick Look im Finder interaktiv öffnen lässt. Schließe vor der Aufnahme die Quick Look-Vorschau im Finder und alle Fenster des eigenständigen Viewers mit demselben Dateinamen. Du brauchst die oben beschriebene Berechtigung zur Bildschirmaufnahme, die Swift-Befehlszeilentools und FFmpeg mit den Filtern `drawtext` und `subtitles`. Lass das Terminal sichtbar und folge seinen Hinweisen. Lass die Datei im Finder ausgewählt und wechsle bei Bedarf in die Listenansicht. Drücke nach Aufforderung die Leertaste und drehe oder zoome zweimal. Klicke nach Aufforderung auf die Schaltfläche zum Öffnen mit Spacebar 3D. Wenn macOS ein Menü mit Apps öffnet, wähle Spacebar 3D. Wenn die Schaltfläche fehlt, schließe Quick Look und öffne dieselbe Datei in Spacebar 3D über **Ablage → Öffnen…**. Drehe oder zoome im eigenständigen Viewer zweimal.

```bash
SPACEBAR3D_REVIEW_ANIMATION_MODEL=docs/app-store/Spacebar3D-Review-Model.glb \
  ./scripts/capture-app-review.sh /path/to/model.fbx build/media-captures/app-review
```

Das Skript fügt Beschriftungen hinzu und speichert `app-review.mp4` in einem neuen Ordner unter `build/media-captures/`. Mit einem noch freien Pfad als zweitem Argument wählst du den Ausgabeordner. Setze `SPACEBAR3D_REVIEW_APP`, wenn die App an einem anderen Ort als `/Applications/Spacebar 3D.app` installiert ist.

Nach der geführten Aufnahme zeichnet das Skript Kapitel zur Viewer-Bedienung, zu Einstellungen, Hilfe und Datenschutz auf. Das Beispiel ergänzt die Wiedergabe mit dem animierten Beispielmodell. Setze `SPACEBAR3D_REVIEW_CAPTURE_APP`, um eine vorhandene Aufnahmeversion zu verwenden. Standardmäßig baut das Skript sie mit der oben beschriebenen Entwicklungsumgebung.

Eine vorhandene Aufnahme allein der geführten Finder- und Viewer-Schritte lässt sich mit `capture-review-features.sh` ergänzen. Siehe `--help`.

<a id="tests"></a>

## Tests

Baue Assimp, bevor du das Paket auflöst oder einen der beiden Testwege ausführst.

<a id="full-xcode-suite"></a>

### Vollständige Xcode-Testsuite

Dies ist der Hauptbefehl für Regressionstests. Er umfasst die Quelltests für App, gemeinsamen Code und Erweiterung sowie alle neun Paket-Testtargets aus `project.yml`.

```bash
xcodegen generate
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build
python3 scripts/check-localizations.py
```

Für einen gezielten Lauf ergänze einen `-only-testing`-Selektor, zum Beispiel:

```bash
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build \
  -only-testing:ViewerUITests/NativeViewerInputTests
```

Xcode schreibt `.xcresult`-Bundles nach `build/Logs/Test/`.

<a id="package-only-tests"></a>

### Nur Pakettests

Dabei entfallen die Host-Quelltests in `Spacebar3DTests`:

```bash
xcrun swift test --package-path Packages/Spacebar3DKit
```

Zwei Tests für große Modelle werden mit `P3D_LARGE=1` eingeschaltet. Einer erzeugt eine STL-Testdatei von etwa 100 MB. Diesen Benchmark startest du ausdrücklich so:

```bash
P3D_LARGE=1 xcrun swift test --package-path Packages/Spacebar3DKit \
  --filter LargeModelTests
```

<a id="what-the-tests-establish"></a>

### Was die Tests nachweisen

- Einstellungstests verwenden expliziten temporären Speicher. Ergänze Normalisierungsfälle in [`settings-vectors.json`](../../testdata/settings-vectors.json), wenn sich Regeln ändern.
- Importtests erzeugen kleine Testdateien und prüfen fehlerhafte sowie abgeschnittene Eingaben.
- Rendertests zeichnen außerhalb des Bildschirms und prüfen Pixel. Sie benötigen ein funktionsfähiges Metal-Gerät.
- Viewertests prüfen native Eingaben, Metadaten zur Bedienungshilfe, Befehle, Layout und SwiftUI-Steuerelemente, auch mit ViewInspector.
- Lokalisierungsprüfungen prüfen Quellschlüssel, Katalogeinträge und Platzhalter. Pakettests prüfen zusätzlich die kompilierten Sprachressourcen.

Das Xcode-Schema kompiliert Host-Quellen in ein Testbundle. Es startet die signierte App nicht in ihrer Produktions-Sandbox. Ein erfolgreicher Lauf belegt weder Quick-Look-Registrierung noch Ordnerrechte, gesprochene VoiceOver-Ausgaben oder das Verhalten eines notarisierten Downloads. Prüfe solche Änderungen zusätzlich mit der installierten signierten App und der Finder-Erweiterung.

<a id="how-it-works"></a>

## Funktionsweise

```text
Finder → Quick Look extension ─┐
                              ├─ ViewerFactory → NativeViewer
App → model window ───────────┘                      │
                                     ImportRouter → ModelScene
                                                     │
                                           RenderMetal / MTKView
                                           + SwiftUI controls
```

Beide Hosts verwenden das lokale Paket `Spacebar3DKit`. Der Import läuft außerhalb des Hauptthreads; der native Viewer koordiniert Rendering und Steuerelemente.

| Bereich | Aufgabe |
| :--- | :--- |
| `Spacebar3D/App/` | Einrichtung, Einstellungen, Modellfenster, Registrierung als Standard-App, Menüs, Hilfe und Danksagungen. |
| `Spacebar3D/Extension/` | Lebenszyklus der Quick-Look-Vorschau. |
| `Spacebar3D/Shared/` | Viewer-Erzeugung und gemeinsame Einstellungen. |
| `Packages/Spacebar3DKit/Sources/ModelCore/` | Szenendaten, Formaterkennung, Animation, Topologie und Lokalisierung. |
| `…/Sources/ImportRouter/` und `…/Sources/Import*/` | Formatauswahl und Reader. |
| `…/Sources/RenderMetal/` | GPU-Szene, Kamera, Shading und Rendering. |
| `…/Sources/ViewerUI/` | Viewer-API, native Eingaben, SwiftUI-Steuerelemente und Ordnerfreigaben. |
| `…/Sources/CZstd/` | Mitgelieferter Zstandard-Decoder für komprimierte Blender-Dateien. |
| `Spacebar3DTests/` und `Packages/Spacebar3DKit/Tests/` | Host-Quelltests und Pakettests. |
| `docs/<language-code>/README.md` | Die neun nicht englischen READMEs. |
| `docs/<language-code>/DEVELOPMENT.md` | Die neun übersetzten Entwicklerhandbücher. |

Native Swift-Reader verarbeiten STL, PLY, OBJ, 3MF, glTF/GLB, VRM/VRMA und Blender. Model I/O verarbeitet USD, Assimp FBX und 3DS. `FormatDetector` prüft die ersten Bytes und bei mehrdeutigen Textformaten die Dateiendung. Unterstützte Dokumenttypen und `QLSupportedContentTypes` stehen in `project.yml`.

Reine Animationsdateien mit unterstütztem Skelett können eine Strichfiguren-Vorschau nutzen. Ein Standardavatar wird nicht mitgeliefert. Die Formatunterstützung ist bewusst begrenzter als die einer vollständigen DCC-Anwendung. Halte die Einschränkungen in der README bei Reader-Änderungen aktuell.

<a id="implementation-notes"></a>

## Hinweise zur Implementierung

<a id="sandbox-and-related-files"></a>

### Sandbox und zugehörige Dateien

Beide Targets verwenden App Sandbox und schreibgeschützten Zugriff auf vom Benutzer ausgewählte Dateien. Keines besitzt eine Netzwerkberechtigung oder temporäre Sandbox-Ausnahme.

Das Öffnen eines Modells erlaubt keinen unbegrenzten Zugriff auf benachbarte Dateien. Beide Hosts können **Modell anzeigen…**, **Materialien anzeigen…** oder **Texturen anzeigen…** anbieten, um Zugriff auf den Ordner anzufordern. Die App unterstützt außerdem bestimmte gleichnamige Material-Begleitdateien, etwa `ship.mtl` neben `ship.obj`, über ihre Verarbeitung zugehöriger Dateien.

[`FolderGrants.swift`](../../Packages/Spacebar3DKit/Sources/ViewerUI/FolderGrants.swift) speichert App-Freigaben als Security-Scoped Bookmarks. Quick Look speichert eigene normale Bookmarks und liest die von der App im gemeinsamen Container aktualisierten Kopien. Eine nur in Quick Look erteilte Freigabe muss nach einem Mac-Neustart erneuert werden. Ein App-Start aktualisiert gespeicherte App-Freigaben für die Erweiterung. Lesezugriff bleibt auf freigegebene Ordner und deren Unterordner beschränkt.

<a id="settings"></a>

### Einstellungen

`ViewerSettings` speichert `viewer-settings.json` im App-Group-Container. Die App schreibt die Datei; neue Viewer laden die normalisierten Werte. Ungültige, zu große oder fehlende Einstellungen führen zu Standardwerten. Vom alten Speicherort außerhalb des Containers, `~/Library/Application Support/Spacebar3D/`, gibt es keine Migration.

<a id="input-and-accessibility"></a>

### Eingaben und Bedienungshilfen

Pfeiltasten drehen die Kamera um das Modell, Umschalt-Pfeiltasten verschieben sie, sofern die Modellfläche der eigenständigen App die Tastatureingaben verarbeitet. Die Leertaste startet oder pausiert dort die Wiedergabe. Sie ist kein globales Menükürzel und darf fokussierten Tasten oder Reglern nicht die Aktivierung nehmen. Quick Look behält seine Schließen-Funktion über die Leertaste. Menü- und Bedienungshilfeaktionen bieten Alternativen zu Zeigergesten.

Prüfe bei geänderten Steuerelementen Tastaturfokus, schmale Fenster, lange Übersetzungen, Kontrast erhöhen und Transparenz reduzieren. Höre echte VoiceOver-Ausgaben zusätzlich zu Prüfungen des Bedienungshilfebaums ab.

<a id="localization-and-documentation"></a>

### Lokalisierung und Dokumentation

Der gemeinsame String-Katalog `Packages/Spacebar3DKit/Sources/ModelCore/Resources/Localizable.xcstrings` versorgt App und Erweiterung in zehn Sprachen. Hinweise zu vollständigen Strings, Platzhaltern, kompilierten Ressourcen und Layoutprüfungen stehen in [LOCALIZATION.md](../LOCALIZATION.md).

Die englische README liegt im Stammverzeichnis, Übersetzungen unter `docs/<language-code>/`. Die Entwicklerhandbücher liegen in denselben Ordnern; die englische Quelle ist `docs/DEVELOPMENT.md`. Halte Formatgrenzen, Steuerung, Installation, Berechtigungsverhalten und Entwicklungsabläufe in allen Versionen konsistent.

<a id="troubleshooting"></a>

## Fehlerbehebung

| Symptom | Prüfung |
| :--- | :--- |
| Paketauflösung meldet fehlendes Assimp | Führe `./scripts/build-assimp.sh` mit vollständigem Xcode, CMake und Ninja aus. |
| Signierung scheitert oder gemeinsame Einstellungen fehlen | Prüfe Zertifikat, Team, Bundle-Kennungen und identische App-Group-Kennungen. Eine Umgebungsvariable allein schreibt keine Entitlements um. |
| Änderungen verschwinden nach der Generierung | Ändere `project.yml`, nicht erzeugte `.xcodeproj`- oder `Info.plist`-Dateien. |
| Erweiterung fehlt oder alte Version wird geladen | Starte die richtige installierte App, aktiviere ihre Erweiterung, prüfe die Registrierung und aktualisiere Quick Look. Verwechsle installierte und Build-Kopien nicht. |
| Apples Viewer öffnet sich | Beachte die Formatgrenzen oben und vergleiche mit Ablage → Öffnen in der App. |
| Texturen oder Geometrie fehlen | Lies den Hinweis, erlaube den Modellordner und prüfe Formatgrenzen sowie Begleitdateien. |
| GPU-Test scheitert | Prüfe, ob Metal verfügbar ist, und untersuche den Fehler. Eine fehlende GPU ist kein bestandener Rendertest. |

Erweiterungsregistrierung prüfen und Logs verfolgen:

```bash
pluginkit -m | rg -i spacebar3d
log stream --predicate 'process == "Spacebar3DExtension"'
```

Der erste Befehl verwendet `rg` aus ripgrep; alternativ geht `grep -i spacebar3d`. Führe in einem zweiten Terminal `qlmanage -p /path/to/model.glb` aus. Ein abgewiesenes Modell sollte in der Vorschau einen Fehler anzeigen. Kläre, ob Import, Rendering, Zugriff oder Erweiterungsauswahl betroffen sind, bevor du Signierung oder Berechtigungen änderst.

<a id="distribution-signing--notarization"></a>

## Verteilung, Signierung und Notarisierung

Die Skripte implementieren die **direkte Developer-ID-Verteilung als DMG**. Sie archivieren, exportieren oder laden keinen Mac-App-Store-Build hoch. Für den Store ist ein separater Ablauf für Signierung, Archivierung, Export und App-Store-Connect-Einreichung nötig.

Für direkte Verteilung nutze eine Developer-ID-Application-Identität und Notarisierung. Apples [Notarisierungsanleitung](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) erklärt die Signierungs- und Dienstanforderungen. Mitgliedschaftspreise werden hier bewusst nicht wiederholt.

<a id="manual"></a>

### Manuell

Nach dem Einrichten passender Team- und App-Group-Kennungen:

```bash
SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ./scripts/build.sh
```

Mit `SIGN_IDENTITY` wählt das Build-Skript manuelle Signierung, übergibt `DEVELOPMENT_TEAM`, ergänzt einen sicheren Zeitstempel und deaktiviert die automatische Ergänzung grundlegender Debug-Entitlements. Hardened Runtime ist in `project.yml` aktiviert. Ohne `SIGN_IDENTITY` nutzt das Skript die Entwicklungssignierung des Projekts.

Nutze für lokale Notarisierung möglichst ein Schlüsselbundprofil. Speichere die Zugangsdaten interaktiv mit `notarytool` und verwende dann den Profilnamen:

```bash
xcrun notarytool store-credentials "spacebar3d-notary"
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" ./scripts/notarize.sh
```

Das Skript akzeptiert einen optionalen App-Pfad:

```bash
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" \
  ./scripts/notarize.sh "/path/to/Spacebar 3D.app"
```

Die Authentifizierung wird in dieser Reihenfolge gewählt:

| Methode | Variablen |
| :--- | :--- |
| Schlüsselbundprofil | `NOTARY_KEYCHAIN_PROFILE` |
| App-Store-Connect-API-Schlüssel | `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER` |
| Apple-Account-Zugangsdaten | `APPLE_TEAM_ID`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` |

Die letzte Methode übergibt ein app-spezifisches Passwort als `notarytool`-Argument. Ein Schlüsselbundprofil vermeidet dies auf gemeinsam genutzten Rechnern. Speichere Signaturschlüssel und Zugangsdaten nicht im Repository.

`notarize.sh` prüft die Developer-ID-Signatur der App und erstellt ein DMG mit einer Applications-Verknüpfung. Es signiert das DMG mit der Identität aus der App-Signatur oder mit `SIGN_IDENTITY`, falls gesetzt. Das Zertifikat und der private Schlüssel müssen im Schlüsselbund verfügbar sein. Das Skript reicht das DMG bei Apple ein, wartet auf die Annahme, heftet das Ticket an und validiert es. Danach prüft es Gatekeeper mit `spctl`. Nach bestandenen Prüfungen schreibt es `Spacebar3D.dmg` ins Stammverzeichnis des Repositorys. Teste die heruntergeladene Datei vor der Weitergabe.

<a id="automated-github-actions"></a>

### Automatisch mit GitHub Actions

[Der Release-Workflow](../../.github/workflows/release.yml) läuft auf dem Apple-Silicon-Runner `macos-26` mit Xcode 26. Übertrage oder wähle einen Tag im Format `vMAJOR.MINOR.PATCH`, der zu `MARKETING_VERSION` passt und auf einen Commit in `origin/main` zeigt.

Der Workflow erzeugt das Projekt und führt `Spacebar3DTests` sowie die Lokalisierungsprüfung aus, bevor er das Signaturzertifikat importiert. Er baut mit Developer ID, vergleicht die Versionen von App und Erweiterung mit dem Tag und signiert und notarisiert das DMG. Vor dem Anhängen des DMG an ein GitHub Release löscht er den temporären Schlüsselbund.

Konfiguriere diese Secrets im **tatsächlichen Ziel-Repository**:

| Secret | Inhalt |
| :--- | :--- |
| `MACOS_CERTIFICATE` | Developer-ID-Application-Zertifikat und privater Schlüssel als `.p12`, Base64-kodiert. |
| `MACOS_CERTIFICATE_PWD` | Passwort dieser `.p12`-Datei. |
| `KEYCHAIN_PASSWORD` | Passwort des temporären Build-Schlüsselbunds. |
| `APPLE_TEAM_ID` | Kennung des Signierungsteams. |
| `NOTARY_APPLE_ID` | Apple Account für die Notarisierung. |
| `NOTARY_PASSWORD` | Dessen app-spezifisches Passwort. |

Gib das Repository ausdrücklich an, etwa mit `gh secret set APPLE_TEAM_ID --repo OWNER/REPOSITORY`. Der Befehl fragt den Wert ab. Verlasse dich nicht darauf, dass `origin` ein existierendes oder vorgesehenes Release-Repository bezeichnet.

Setze vor dem Erstellen eines Release-Tags `MARKETING_VERSION` und `CURRENT_PROJECT_VERSION` in `project.yml`, aktualisiere das Änderungsprotokoll, führe die Tests aus und prüfe den signierten Build. Wenn du den passenden Tag überträgst und der Workflow erfolgreich läuft, kann er ein GitHub Release veröffentlichen.

<a id="references"></a>

## Referenzen

- [Architektur des nativen Renderers](../architecture/native-rewrite.md)
- [Viewer-Design](../design/neon-garden-viewer.md)
- [Lokalisierung](../LOCALIZATION.md)
- [Drittanbieterlizenzen](../../THIRD_PARTY_LICENSES.md)
- [Apple: Notarisierung anpassen](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [magicien/VRMQuickLook](https://github.com/magicien/VRMQuickLook), VRM-0.x-Implementierung mit SceneKit
- [magicien/GLTFQuickLook](https://github.com/magicien/GLTFQuickLook), Referenz für die Quick-Look-Struktur
- [pixiv/three-vrm](https://github.com/pixiv/three-vrm), Referenz für das VRM-Verhalten
