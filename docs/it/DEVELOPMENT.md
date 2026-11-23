# Sviluppare Spacebar 3D

[English](../DEVELOPMENT.md) | [简体中文](../zh-Hans/DEVELOPMENT.md) | [Español](../es/DEVELOPMENT.md) | [Français](../fr/DEVELOPMENT.md) | [Deutsch](../de/DEVELOPMENT.md) | [日本語](../ja/DEVELOPMENT.md) | [Português (Brasil)](../pt-BR/DEVELOPMENT.md) | [한국어](../ko/DEVELOPMENT.md) | **Italiano** | [Русский](../ru/DEVELOPMENT.md)

Compila, testa ed esegui il debug dell'app nativa macOS e della sua estensione Quick Look. Per funzionalità e limiti dei formati supportati, consulta il [README](README.md).

[Requisiti](#requirements) · [Compilazione](#build-local) · [Test](#tests) · [Architettura](#how-it-works) · [Risoluzione dei problemi](#troubleshooting) · [Distribuzione](#distribution-signing--notarization)

Salvo indicazione diversa, esegui i comandi dalla radice del repository.

<a id="requirements"></a>

## Requisiti

| Requisito | Note |
| :--- | :--- |
| Mac con chip Apple e macOS 26 o successivo | Il progetto e Assimp compilano per `arm64`; non viene prodotta una variante Intel. |
| Xcode completo con SDK macOS 26 o successivo | Le sole Command Line Tools non bastano. L'ambiente di sviluppo locale attuale usa Xcode 27.0. |
| XcodeGen | Genera il progetto Xcode da `project.yml`. |
| CMake e Ninja | Compilano la dipendenza nativa Assimp. |
| Python 3 | Esegue il controllo di coerenza delle traduzioni. |
| Identità di firma per lo sviluppo | Necessaria per l'app installata, l'estensione e il loro App Group condiviso. Vedi sotto. |

```bash
brew install xcodegen cmake ninja
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

Se la shell seleziona le Command Line Tools o un'altra installazione di Xcode, seleziona Xcode completo prima di compilare:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`build.sh` rileva anche questa installazione standard quando `xcode-select` punta alle Command Line Tools. I comandi diretti di `xcodebuild` e di compilazione delle dipendenze richiedono già la directory di sviluppo corretta.

<a id="build-local"></a>

## Compilazione locale

<a id="configure-signing"></a>

### Configurare la firma

La configurazione nel repository usa il team definito in [`project.yml`](../../project.yml). Per usare il tuo team:

1. Imposta `DEVELOPMENT_TEAM` e identificatori bundle appropriati in `project.yml`.
2. Configura un App Group per il team. Usa lo stesso identificatore in [`Spacebar3D.entitlements`](../../Spacebar3D/App/Spacebar3D.entitlements), [`Spacebar3DExtension.entitlements`](../../Spacebar3D/Extension/Spacebar3DExtension.entitlements) e `ViewerSettings.appGroup` in [`ViewerSettings.swift`](../../Spacebar3D/Shared/ViewerSettings.swift).
3. Verifica che Xcode possa usare il certificato Apple Development del team e i file di provisioning richiesti. Rigenera il progetto dopo le modifiche alla configurazione.

L'App Group attuale è `V3AQWQ8JMY.com.vitalis.Spacebar3D`. Cambiare solo il team nel comando di compilazione non aggiorna questo identificatore. Le build senza firma o con firma ad hoc non sostituiscono le prove di registrazione dell'estensione e di accesso al contenitore condiviso.

<a id="build-the-app"></a>

### Compilare l'app

```bash
./scripts/build.sh
```

Lo script compila Assimp se manca il framework, esegue XcodeGen e compila lo schema `Spacebar3D` in configurazione Release. Risultato:

```text
build/Build/Products/Release/Spacebar 3D.app
```

La prima compilazione richiede la rete per le dipendenze. [`build-assimp.sh`](../../scripts/build-assimp.sh) fissa Assimp a `v6.0.6` e verifica lo SHA completo del commit `a79ff6bbce54d3e01186a918dc6374ed55317426` prima della compilazione. Produce un XCFramework statico arm64 con importatori FBX e 3DS, senza esportatori né Draco.

Esegui di nuovo lo script quando cambia la revisione fissata. `build.sh` controlla solo l'esistenza del framework, non la sua corrispondenza alla revisione. Per usare un checkout locale al commit richiesto:

```bash
ASSIMP_SRC=/path/to/assimp ./scripts/build-assimp.sh
```

<a id="register-and-exercise-quick-look"></a>

### Registrare e provare Quick Look

1. Copia l'app compilata in `/Applications` e avvia quella copia una volta.
2. Attiva **Spacebar 3D** in **Impostazioni di Sistema → Generali → Elementi login ed estensioni → Quick Look**.
3. Seleziona un file supportato nel Finder e premi Spazio.
4. Apri lo stesso file con **File → Apri…** nell'app per verificare entrambi gli ambienti.

Se la registrazione non è aggiornata, aggiorna la cache e prova un file GLB:

```bash
qlmanage -r
qlmanage -r cache
qlmanage -p /path/to/model.glb
```

macOS può scegliere l'anteprima di Apple per OBJ, STL, PLY, USD e USDZ. Questo non dimostra un guasto dell'estensione. Usa l'app o la sostituzione facoltativa descritta nel [README](README.md#help).

<a id="development"></a>

## Sviluppo

Per modificare ed eseguire il debug in Xcode:

```bash
./scripts/build-assimp.sh
xcodegen generate
open Spacebar3D.xcodeproj
```

Compila Assimp una volta per revisione della dipendenza, poi rigenera il progetto quando cambia `project.yml`. Git ignora `.xcodeproj`, entrambi gli `Info.plist` generati, i risultati della compilazione e `Vendor/Assimp.xcframework`. Modifica il sorgente YAML, non il progetto o le property list generate.

Per una compilazione Debug incrementale dal terminale:

```bash
xcodebuild -project Spacebar3D.xcodeproj -scheme Spacebar3D \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build build
```

`SKIP_XCODEGEN=1 ./scripts/build.sh` riutilizza il progetto generato esistente e compila comunque in Release. Usalo solo se il progetto corrisponde al YAML.

<a id="capture-media"></a>

### Registrare un video di anteprima e acquisire schermate

Esegui lo script da una sessione desktop di macOS con i requisiti di compilazione indicati sopra. In Impostazioni di Sistema, consenti la registrazione dello schermo all'app da cui avvii lo script.

Se il modello fa riferimento a texture, materiali o geometria esterni, aprilo prima nell'app Spacebar 3D standard. Usa il pulsante della cartella nel visualizzatore per autorizzare l'accesso alla cartella che contiene quei file. La versione per l'acquisizione usa l'autorizzazione salvata. Aprire solo il file del modello può lasciare inaccessibili i file associati.

```bash
brew install ffmpeg
./scripts/capture-media.sh /path/to/model.glb
```

Lo script compila e avvia una copia separata di Spacebar 3D con la funzione di acquisizione abilitata. Per riutilizzare una copia compilata con questa opzione, imposta `SPACEBAR3D_APP` sul percorso del suo pacchetto `.app`. Per impostazione predefinita, lo script crea una cartella in `build/media-captures/`. Passa un percorso ancora libero come secondo argomento per scegliere la cartella di destinazione.

Il video di anteprima pubblico del Mac App Store, `preview.mp4`, dura 30 secondi e mostra tutti gli stili di rendering disponibili per il modello. Ha una risoluzione di 1920 × 1080 a 30 fps. Lo script salva anche quattro PNG da 2560 × 1600 e `demo.gif`. Per i modelli con almeno tre stili, la GIF usa lo stesso montaggio di 15 secondi del video in loop degli stili. Con meno stili, usa l'anteprima alla velocità originale. La prima schermata usa la vista Con texture, quando disponibile (`01-textured.png`), o la vista Solida negli altri casi (`01-solid.png`). Le altre immagini sono `02-wireframe.png`, `03-normals.png` e `04-hologram.png`.

<a id="capture-feature-loop"></a>

### Registrare un video in loop degli stili

Usa la stessa configurazione di acquisizione per creare un video in loop di 15 secondi a 30 fps. Il modello deve supportare almeno tre stili di rendering. Lo script dà la precedenza a Cel shading, Arte voxel e Ologramma.

```bash
./scripts/capture-feature-loop.sh /path/to/model.glb
```

Per impostazione predefinita, lo script salva `feature-loop.mp4` in una nuova cartella in `build/media-captures/`. Passa un percorso ancora libero come secondo argomento per scegliere la cartella di destinazione.

<a id="capture-screenshots"></a>

### Acquisire schermate per l'App Store

Usa la stessa configurazione di acquisizione per generare i quattro PNG sRGB da 2560 × 1600 indicati sopra.

```bash
./scripts/capture-screenshots.sh /path/to/model.glb
```

Per impostazione predefinita, lo script salva i file in una nuova cartella in `build/media-captures/`. Passa un percorso ancora libero come secondo argomento per scegliere la cartella di destinazione.

<a id="capture-app-review"></a>

### Registrare una dimostrazione privata per App Review

Installa e avvia l'app Spacebar 3D standard e abilita la sua estensione Quick Look. Scegli un modello che si apra in modo interattivo in Quick Look nel Finder. Prima di registrare, chiudi l'anteprima Quick Look nel Finder e le finestre del visualizzatore autonomo con lo stesso nome file. Servono l'autorizzazione alla registrazione dello schermo indicata sopra, gli strumenti Swift da riga di comando e FFmpeg con i filtri `drawtext` e `subtitles`. Tieni visibile il terminale e segui le sue indicazioni. Lascia il file selezionato nel Finder e passa alla vista elenco se necessario. Quando richiesto, premi la barra spaziatrice e ruota il modello o modifica lo zoom due volte. Quando richiesto, fai clic sul pulsante per aprire il file con Spacebar 3D. Se macOS apre un menu di app, scegli Spacebar 3D. Se il pulsante non è disponibile, chiudi Quick Look e apri lo stesso file da **File → Apri…** in Spacebar 3D. Ruota il modello o modifica lo zoom due volte nel visualizzatore autonomo.

```bash
SPACEBAR3D_REVIEW_ANIMATION_MODEL=docs/app-store/Spacebar3D-Review-Model.glb \
  ./scripts/capture-app-review.sh /path/to/model.fbx build/media-captures/app-review
```

Lo script aggiunge didascalie e salva `app-review.mp4` in una nuova cartella in `build/media-captures/`. Per scegliere la cartella di destinazione, passa come secondo argomento un percorso ancora libero. Imposta `SPACEBAR3D_REVIEW_APP` se l'app è installata in un percorso diverso da `/Applications/Spacebar 3D.app`.

Dopo la registrazione guidata, lo script registra i capitoli sui controlli del visualizzatore, sulle impostazioni, sull'aiuto e sulla privacy. L'esempio aggiunge la riproduzione con il modello animato fornito. Imposta `SPACEBAR3D_REVIEW_CAPTURE_APP` per riutilizzare un'app già compilata per l'acquisizione. Per impostazione predefinita, lo script la compila con la configurazione di sviluppo indicata sopra.

Se hai già una registrazione dei passaggi guidati nel Finder e nel visualizzatore, puoi aggiungere i capitoli con `capture-review-features.sh`. Consulta `--help`.

<a id="tests"></a>

## Test

Compila Assimp prima di risolvere il package o eseguire uno dei due percorsi di test.

<a id="full-xcode-suite"></a>

### Suite Xcode completa

Questo è il comando principale per i test di regressione. Include i test dei sorgenti dell'app, del codice condiviso e dell'estensione, oltre ai nove target di test del package dichiarati in `project.yml`.

```bash
xcodegen generate
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build
python3 scripts/check-localizations.py
```

Per un'esecuzione mirata, aggiungi un selettore `-only-testing`, per esempio:

```bash
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build \
  -only-testing:ViewerUITests/NativeViewerInputTests
```

Xcode salva i bundle `.xcresult` in `build/Logs/Test/`.

<a id="package-only-tests"></a>

### Test del solo package

Escludono i test dei sorgenti host in `Spacebar3DTests`:

```bash
xcrun swift test --package-path Packages/Spacebar3DKit
```

Due test per modelli grandi si attivano con `P3D_LARGE=1`. Uno crea un file STL di prova di circa 100 MB. Per eseguire esplicitamente questo benchmark:

```bash
P3D_LARGE=1 xcrun swift test --package-path Packages/Spacebar3DKit \
  --filter LargeModelTests
```

<a id="what-the-tests-establish"></a>

### Cosa verificano i test

- I test delle impostazioni usano memoria temporanea esplicita. Aggiungi casi di normalizzazione a [`settings-vectors.json`](../../testdata/settings-vectors.json) quando cambiano le regole.
- I test degli importatori creano piccoli file di prova e verificano input malformati e troncati.
- I test del renderer disegnano fuori schermo e controllano i pixel; richiedono un dispositivo Metal funzionante.
- I test del visualizzatore coprono input nativo, metadati di accessibilità, comandi, layout e controlli SwiftUI, incluse verifiche con ViewInspector.
- I controlli di localizzazione verificano copertura delle chiavi, voci del catalogo e segnaposto. I test del package verificano anche le risorse linguistiche compilate.

Lo schema Xcode compila i sorgenti host in un bundle di test. Non avvia l'app firmata nella sua sandbox di produzione. Un esito positivo non verifica la registrazione Quick Look, i permessi delle cartelle, la voce di VoiceOver o il comportamento di un download autenticato da Apple. Per queste modifiche, testa anche l'app firmata installata e l'estensione Finder.

<a id="how-it-works"></a>

## Funzionamento

```text
Finder → Quick Look extension ─┐
                              ├─ ViewerFactory → NativeViewer
App → model window ───────────┘                      │
                                     ImportRouter → ModelScene
                                                     │
                                           RenderMetal / MTKView
                                           + SwiftUI controls
```

I due host condividono il package locale `Spacebar3DKit`. L'importazione avviene fuori dal thread principale; il visualizzatore nativo coordina rendering e controlli.

| Area | Responsabilità |
| :--- | :--- |
| `Spacebar3D/App/` | Configurazione, impostazioni, finestre dei modelli, registrazione come app predefinita, menu, aiuto e crediti. |
| `Spacebar3D/Extension/` | Ciclo di vita dell'anteprima Quick Look. |
| `Spacebar3D/Shared/` | Creazione del visualizzatore e impostazioni condivise. |
| `Packages/Spacebar3DKit/Sources/ModelCore/` | Dati della scena, rilevamento dei formati, animazione, topologia e localizzazione. |
| `…/Sources/ImportRouter/` e `…/Sources/Import*/` | Selezione dei formati e lettori. |
| `…/Sources/RenderMetal/` | Scena GPU, camera, shading e rendering. |
| `…/Sources/ViewerUI/` | API del visualizzatore, input nativo, controlli SwiftUI e autorizzazioni delle cartelle. |
| `…/Sources/CZstd/` | Decoder Zstandard incluso per i file Blender compressi. |
| `Spacebar3DTests/` e `Packages/Spacebar3DKit/Tests/` | Test dei sorgenti host e del package. |
| `docs/<language-code>/README.md` | I nove README tradotti. |
| `docs/<language-code>/DEVELOPMENT.md` | Le nove guide di sviluppo tradotte. |

I lettori Swift nativi gestiscono STL, PLY, OBJ, 3MF, glTF/GLB, VRM/VRMA e Blender. Model I/O gestisce USD; Assimp gestisce FBX e 3DS. `FormatDetector` esamina i byte iniziali e, per formati testuali ambigui, l'estensione. Tipi di documento e `QLSupportedContentTypes` sono dichiarati in `project.yml`.

I file di sola animazione con uno scheletro compatibile possono mostrare un'anteprima stilizzata dello scheletro. Non è incluso un avatar predefinito. Il supporto ai formati è volutamente più limitato rispetto a un'applicazione DCC completa. Aggiorna i limiti nel README quando modifichi i lettori.

<a id="implementation-notes"></a>

## Note di implementazione

<a id="sandbox-and-related-files"></a>

### Sandbox e file associati

Entrambi i target usano App Sandbox e accesso in sola lettura ai file selezionati dall'utente. Nessuno ha autorizzazioni di rete o eccezioni temporanee alla sandbox.

Aprire un modello non concede accesso illimitato ai file vicini. Entrambi gli host possono proporre **Mostra modello…**, **Mostra materiali…** o **Mostra texture…** per richiedere l'accesso alla cartella. L'app supporta inoltre determinati file di materiali associati con lo stesso nome, come `ship.mtl` accanto a `ship.obj`, tramite la gestione dei file correlati.

[`FolderGrants.swift`](../../Packages/Spacebar3DKit/Sources/ViewerUI/FolderGrants.swift) salva le autorizzazioni dell'app come bookmark con ambito di sicurezza. Quick Look conserva i propri bookmark normali e legge le copie aggiornate dall'app nel contenitore condiviso. Un'autorizzazione concessa solo a Quick Look va rinnovata dopo un riavvio del Mac. Avviare l'app aggiorna per l'estensione le autorizzazioni memorizzate. La lettura resta limitata alle cartelle autorizzate e alle loro sottocartelle.

<a id="settings"></a>

### Impostazioni

`ViewerSettings` salva `viewer-settings.json` nel contenitore App Group. L'app lo scrive; i nuovi visualizzatori caricano i valori normalizzati. Impostazioni invalide, troppo grandi o mancanti ripristinano i valori predefiniti. Non esiste migrazione dal vecchio percorso esterno al contenitore, `~/Library/Application Support/Spacebar3D/`.

<a id="input-and-accessibility"></a>

### Input e accessibilità

Le frecce orbitano e Maiusc-frecce spostano la camera solo quando l'area del modello nell'app autonoma gestisce la tastiera. Spazio avvia o sospende la riproduzione in quell'area; non è una scorciatoia globale di menu e non deve sottrarre l'attivazione a pulsanti o cursori con il focus. Quick Look conserva Spazio per chiudere. Menu e azioni di accessibilità offrono alternative ai gesti del puntatore.

Quando modifichi i controlli, verifica focus, finestre strette, traduzioni lunghe, Aumenta contrasto e Riduci trasparenza. Ascolta gli annunci reali di VoiceOver separatamente dalle verifiche dell'albero di accessibilità.

<a id="localization-and-documentation"></a>

### Localizzazione e documentazione

Il catalogo condiviso `Packages/Spacebar3DKit/Sources/ModelCore/Resources/Localizable.xcstrings` serve app ed estensione in dieci lingue. Segui [LOCALIZATION.md](../LOCALIZATION.md) per stringhe complete, segnaposto, risorse compilate e controlli del layout.

Il README inglese è alla radice; le traduzioni sono in `docs/<language-code>/`. Le guide di sviluppo sono nelle stesse cartelle, con il sorgente inglese in `docs/DEVELOPMENT.md`. Mantieni coerenti limiti dei formati, controlli, installazione, permessi e procedure di sviluppo in tutte le versioni.

<a id="troubleshooting"></a>

## Risoluzione dei problemi

| Sintomo | Controllo |
| :--- | :--- |
| Assimp manca durante la risoluzione del package | Esegui `./scripts/build-assimp.sh` con Xcode completo, CMake e Ninja disponibili. |
| Firma fallita o impostazioni condivise indisponibili | Controlla certificato, team, identificatori bundle e App Group. Una variabile d'ambiente da sola non riscrive gli entitlement. |
| Le modifiche scompaiono dopo la generazione | Modifica `project.yml`, non `.xcodeproj` o `Info.plist` generati. |
| Estensione assente o versione vecchia caricata | Avvia la copia installata corretta, attiva l'estensione, verifica la registrazione e aggiorna Quick Look. Distingui le copie installate da quelle nella cartella di compilazione. |
| Si apre il visualizzatore Apple | Leggi i limiti sopra e confronta con File → Apri nell'app. |
| Texture o geometria mancanti | Leggi l'avviso, autorizza la cartella e controlla i limiti del formato e i file associati. |
| Un test GPU fallisce | Verifica che Metal sia disponibile e analizza l'errore. Una GPU non disponibile non equivale a un test di rendering superato. |

Controlla la registrazione dell'estensione e segui i log:

```bash
pluginkit -m | rg -i spacebar3d
log stream --predicate 'process == "Spacebar3DExtension"'
```

Il primo comando usa `rg` di ripgrep; in alternativa usa `grep -i spacebar3d`. In un altro terminale esegui `qlmanage -p /path/to/model.glb`. Un modello rifiutato dovrebbe mostrare un errore nell'anteprima. Verifica se il problema riguarda importazione, rendering, accesso o selezione dell'estensione prima di cambiare firma o permessi.

<a id="distribution-signing--notarization"></a>

## Distribuzione, firma e autenticazione notarile

Gli script implementano la **distribuzione diretta con Developer ID tramite DMG**. Non archiviano, esportano o caricano build per il Mac App Store. La distribuzione sullo store richiede un flusso separato di firma, archiviazione, esportazione e invio ad App Store Connect.

Per la distribuzione diretta, usa un'identità Developer ID Application e l'autenticazione notarile. La [guida Apple](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) spiega i requisiti di firma e del servizio. I prezzi di adesione non sono riprodotti qui.

<a id="manual"></a>

### Procedura manuale

Dopo aver configurato identificatori di team e App Group corrispondenti:

```bash
SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ./scripts/build.sh
```

Con `SIGN_IDENTITY`, lo script sceglie la firma manuale, passa `DEVELOPMENT_TEAM`, aggiunge un timestamp sicuro e disabilita l'inserimento degli entitlement di debug di base. Hardened Runtime è attivo in `project.yml`. Senza `SIGN_IDENTITY`, usa la firma di sviluppo del progetto.

Per l'autenticazione notarile locale, preferisci un profilo del Portachiavi. Memorizza le credenziali interattivamente con `notarytool`, quindi usa il nome del profilo:

```bash
xcrun notarytool store-credentials "spacebar3d-notary"
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" ./scripts/notarize.sh
```

Lo script accetta un percorso facoltativo dell'app:

```bash
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" \
  ./scripts/notarize.sh "/path/to/Spacebar 3D.app"
```

L'autenticazione viene scelta in quest'ordine:

| Metodo | Variabili |
| :--- | :--- |
| Profilo del Portachiavi | `NOTARY_KEYCHAIN_PROFILE` |
| Chiave API App Store Connect | `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER` |
| Credenziali Apple Account | `APPLE_TEAM_ID`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` |

L'ultimo metodo passa una password specifica per app come argomento di `notarytool`; il profilo del Portachiavi evita questo su una macchina condivisa. Non salvare chiavi di firma o credenziali nel repository.

`notarize.sh` verifica la firma Developer ID dell’app e crea un DMG con un collegamento ad Applications. Firma il DMG con l’identità letta dalla firma dell’app o con `SIGN_IDENTITY` se specificata. Il certificato e la chiave privata devono essere disponibili nel portachiavi. Lo script invia il DMG ad Apple, attende l’approvazione, allega e convalida il ticket, quindi esegue il controllo di Gatekeeper con `spctl`. Dopo aver superato i controlli, scrive `Spacebar3D.dmg` nella directory radice del repository. Prova il file scaricato prima di condividerlo.

<a id="automated-github-actions"></a>

### Automazione con GitHub Actions

[Il workflow di rilascio](../../.github/workflows/release.yml) usa il runner Apple silicon `macos-26` con Xcode 26. Invia o seleziona un tag nel formato `vMAJOR.MINOR.PATCH` che corrisponda a `MARKETING_VERSION` e punti a un commit di `origin/main`.

Il workflow genera il progetto ed esegue `Spacebar3DTests` e il controllo della localizzazione prima di importare il certificato di firma. Compila con Developer ID, confronta le versioni dell’app e dell’estensione con il tag, quindi firma e invia il DMG ad Apple per la notarizzazione. Elimina il portachiavi temporaneo prima di allegare il DMG a una GitHub Release.

Configura questi secret nel **repository di destinazione effettivo**:

| Secret | Contenuto |
| :--- | :--- |
| `MACOS_CERTIFICATE` | Certificato Developer ID Application e chiave privata esportati in `.p12`, codificati in Base64. |
| `MACOS_CERTIFICATE_PWD` | Password di quel `.p12`. |
| `KEYCHAIN_PASSWORD` | Password del portachiavi temporaneo di compilazione. |
| `APPLE_TEAM_ID` | Identificatore del team di firma. |
| `NOTARY_APPLE_ID` | Apple Account per l'autenticazione notarile. |
| `NOTARY_PASSWORD` | La relativa password specifica per app. |

Specifica il repository, ad esempio con `gh secret set APPLE_TEAM_ID --repo OWNER/REPOSITORY`, che richiede il valore. Non presumere che `origin` indichi un repository esistente o la destinazione del rilascio.

Prima di creare un tag di rilascio, imposta `MARKETING_VERSION` e `CURRENT_PROJECT_VERSION` in `project.yml`, aggiorna la cronologia delle modifiche, esegui i test e verifica la build firmata. L’invio del tag corrispondente può pubblicare una GitHub Release se il workflow termina correttamente.

<a id="references"></a>

## Riferimenti

- [Architettura del renderer nativo](../architecture/native-rewrite.md)
- [Design del visualizzatore](../design/neon-garden-viewer.md)
- [Localizzazione](../LOCALIZATION.md)
- [Licenze di terze parti](../../THIRD_PARTY_LICENSES.md)
- [Apple: personalizzare l'autenticazione notarile](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [magicien/VRMQuickLook](https://github.com/magicien/VRMQuickLook), implementazione VRM 0.x con SceneKit
- [magicien/GLTFQuickLook](https://github.com/magicien/GLTFQuickLook), riferimento per la struttura Quick Look
- [pixiv/three-vrm](https://github.com/pixiv/three-vrm), riferimento per il comportamento VRM
