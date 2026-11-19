<p align="center">
  <img src="../../Packages/Spacebar3DKit/Sources/ViewerUI/Resources/Mark.png" width="200" alt="Camaleonte di Spacebar 3D, metà wireframe e metà ombreggiato">
</p>

<h1 align="center">Spacebar 3D</h1>
<p align="center"><strong>I tuoi modelli, a una barra spaziatrice di distanza.</strong></p>
<p align="center">Un visualizzatore 3D nativo per Finder Quick Look e il tuo Mac.</p>
<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-111e17?style=flat-square" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple_silicon-arm64-a8e6a3?style=flat-square" alt="Apple silicon / arm64">
  <img src="https://img.shields.io/badge/renderer-Metal-b5cfff?style=flat-square" alt="Metal">
  <a href="../../LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-f05b99?style=flat-square" alt="Apache License 2.0"></a>
</p>
<p align="center">
  <a href="#install">Per iniziare</a> · <a href="#formats">Formati</a> · <a href="#controls">Comandi</a> · <a href="DEVELOPMENT.md">Guida per sviluppatori</a>
</p>
<p align="center"><a href="../../README.md">English</a> · <a href="../zh-Hans/README.md">简体中文</a> · <a href="../es/README.md">Español</a> · <a href="../fr/README.md">Français</a> · <a href="../de/README.md">Deutsch</a> · <a href="../ja/README.md">日本語</a> · <a href="../pt-BR/README.md">Português do Brasil</a> · <a href="../ko/README.md">한국어</a> · <strong>Italiano</strong> · <a href="../ru/README.md">Русский</a></p>

---

## Trovalo. Premi Spazio. Fallo ruotare.

Seleziona un file 3D compatibile nel Finder e premi <kbd>Spazio</kbd>. Ruota il modello, esamina la topologia, cambia stile o scorri un’animazione. Aprilo nell’app per avere una finestra dedicata.

<p align="center">
  <img src="../demo.gif" width="900" alt="Modello di un carro armato nel visualizzatore di Spacebar 3D, con i comandi visibili">
</p>

> macOS può scegliere la propria anteprima per OBJ, STL, PLY, USD e USDZ. **File → Apri…** o **Apri con → Spacebar 3D** nel Finder apre qualsiasi file compatibile in questo visualizzatore.

<a id="looks"></a>

## Un modello, tanti stili

| Esamina | Esplora | Riproduci |
| :--- | :--- | :--- |
| Viste Solida, Con texture e Normali, reticolo sovrapposto, conteggi di facce e vertici. | Stili senza ombreggiatura, anime, cel shading, retrò, arte voxel e ologramma; ombreggiatura piatta o levigata e regolazioni dei materiali. | Selezione delle clip, scorrimento e ripetizione; scheletri per file compatibili contenenti solo animazione. |

**Scegli la luce.** Sette atmosfere, da Glasshouse a Neon, con luminosità, direzione e rotazione automatica della luce. **Orientati.** Fai clic su un asse del gizmo, ruota, sposta, inquadra il modello o attiva la griglia del pavimento. Le piccole anteprime del Finder mostrano soltanto il modello.

**Nativo per Mac.** Swift, Metal, SwiftUI e AppKit, condivisi dall’app e dall’estensione Quick Look. I modelli vengono elaborati localmente; nessuno dei due componenti ha autorizzazioni di rete. L’interfaccia supporta le dieci lingue elencate in alto e segue le preferenze di macOS. [Note sulla localizzazione, in inglese](../LOCALIZATION.md).

<a id="install"></a>

## Per iniziare

**macOS 26 o successivo · Apple silicon · compilazione dai sorgenti**

Servono la versione completa di Xcode con l’SDK di macOS 26 o successivo, XcodeGen, CMake e Ninja. Il progetto usa un team di sviluppo per la firma e un App Group. Per usare un altro team, configura identità di firma e identificatori prima della compilazione seguendo la [guida alla firma](DEVELOPMENT.md#build-local).

Dalla copia locale del repository:

```bash
brew install xcodegen cmake ninja
./scripts/build.sh
```

La prima compilazione scarica e compila la versione fissata di Assimp.

1. Sposta `build/Build/Products/Release/Spacebar 3D.app` in **Applicazioni**.
2. **Avvia l’app una volta** per registrare l’estensione.
3. Attiva **Spacebar 3D** in **Impostazioni di Sistema → Generali → Elementi login ed estensioni → Quick Look**.
4. Seleziona un file compatibile nel Finder e premi <kbd>Spazio</kbd>.

Per distribuire l’app, segui la [guida alla firma Developer ID e all’autenticazione notarile](DEVELOPMENT.md#distribution-signing--notarization).

<details>
<summary><strong>Usare Spacebar 3D come app predefinita</strong></summary>

Nelle impostazioni dell’app, fai clic su **Imposta come predefinita…**. macOS può chiedere conferma; l’app segnala i formati che non è riuscita a modificare. La scelta riguarda il doppio clic nel Finder, non l’estensione usata da Quick Look.

</details>

<a id="formats"></a>

## Formati supportati

Avatar, risorse per giochi, esportazioni CAD, scansioni e mesh Blender.

`VRM` · `VRMA` · `glTF` · `GLB` · `FBX` · `OBJ` · `STL` · `3MF` · `PLY` · `USD` · `USDA` · `USDC` · `USDZ` · `3DS` · `BLEND`

<details>
<summary><strong>Supporto e limiti di ogni formato</strong></summary>

| Formato | Supporto |
| :--- | :--- |
| `.vrm` | Avatar VRM 0.x / 1.0: toon shading, contorni e spring bones. |
| `.vrma` | Animazione VRM senza mesh; movimento riprodotto su una figura stilizzata dello scheletro. |
| `.glb` / `.gltf` | glTF 2.0 con materiali, texture, skinning e animazioni. I `.bin` e le immagini esterne richiedono accesso alla cartella. Draco, Meshopt e mesh istanziate non sono supportati. |
| `.fbx` | Binario o testo; mesh con skinning e animazioni incorporate. Immagini nel file, accanto ad esso o nella cartella `.fbm`. |
| `.obj` | Geometria e colori dei vertici; materiali e texture da `.mtl` dopo l’autorizzazione della cartella. Senza facce, viene mostrata una nuvola di punti. |
| `.stl` | STL binario o testuale. |
| `.3mf` | Colori per oggetto o triangolo, immagini, materiali metallici e traslucidi. |
| `.ply` | Mesh con colori dei vertici o nuvole di punti in assenza di facce. |
| `.usd` / `.usda` / `.usdc` / `.usdz` | Materiali, texture incorporate e animazione scheletrica. |
| `.3ds` | Colori e trasparenza dei materiali; texture esterne dopo l’autorizzazione della cartella. |
| `.blend` | Blender 2.80 o successivo: mesh visibili e materiali di base come salvati; immagini impacchettate e texture nella cartella autorizzata. Modificatori, pose dell’armatura e animazioni non vengono applicati; reti arbitrarie di nodi shader non vengono valutate. |

FBX contenenti solo animazione e VRMA con uno scheletro supportato vengono mostrati come figure stilizzate. L’app non include modelli né avatar.

</details>

### Texture in file separati

Usa **Mostra texture…**, **Mostra materiali…** o **Mostra modello…** per autorizzare l’accesso in sola lettura alla cartella del modello e alle sottocartelle. Le texture incorporate non richiedono questo permesso, ma devono usare formati di immagine e materiale supportati. Nell’app, un file di materiale con lo stesso nome, come `ship.mtl` accanto a `ship.obj`, può essere letto senza richiesta.

Se il modello si apre ma nessuna delle texture a cui fa riferimento può essere mostrata, il visualizzatore passa dalla vista **Con texture** alla vista **Solida**.

<a id="controls"></a>

## I comandi

| Azione | Comando |
| :--- | :--- |
| Ruotare | Trascinare o usare le frecce con il focus sull’area del modello nell’app |
| Spostare | Trascinare con il tasto destro, oppure tenendo premuto Maiuscole, Opzione o Comando |
| Spostare da tastiera | Maiuscole + frecce nell’area del modello, o il sottomenu di spostamento del menu Vista |
| Zoom | Scorrimento o gesto con due dita |
| Inquadrare il modello | Pulsante di inquadratura o ⌘0 nell’app |
| Guardare lungo un asse | Fare clic su un asse del gizmo |
| Riprodurre o mettere in pausa | Pulsante di riproduzione o Spazio con il focus sull’area del modello nell’app |
| Chiudere Quick Look | Spazio |
| Solido / Con texture / Normali | ⌘1 / ⌘2 / ⌘3 nell’app |
| Attivare il wireframe | ⌘4 nell’app |

La barra inferiore contiene viste, stili e materiali. A destra trovi gizmo, luce, inquadratura, griglia e rotazione automatica. La barra di animazione permette di scegliere e ripetere le clip. Le impostazioni definiscono sfondo, colore solido, vista, luminosità, griglia, rotazione e riproduzione. I menu Vista e Riproduzione restano disponibili quando i controlli del modello sono nascosti.

<a id="help"></a>

## Una mano, se serve

Apri il menu **?** nella barra degli strumenti del visualizzatore per consultare i comandi, l’informativa sulla privacy e i riconoscimenti. Il menu è disponibile nell’app e in Quick Look.

Hai trovato un problema o hai una domanda? Nell’app, scegli **Aiuto → Supporto di Spacebar 3D** oppure [apri una segnalazione](https://github.com/vitalis/Spacebar3D/issues).

<details>
<summary><strong>L’anteprima non appare</strong></summary>

Avvia l’app una volta e attiva l’estensione. Se necessario, aggiorna la cache di Quick Look:

```bash
qlmanage -r && qlmanage -r cache
```

Per OBJ, STL, PLY, USD e USDZ, prova ad aprire il file direttamente nell’app.

</details>

<details>
<summary><strong>Preferire Spacebar 3D alle anteprime Apple</strong></summary>

La modifica facoltativa è reversibile:

```bash
scripts/prefer-spacebar3d.sh status
scripts/prefer-spacebar3d.sh on
scripts/prefer-spacebar3d.sh off
```

`on` preferisce Spacebar 3D; `off` ripristina le estensioni Apple. Lo script disattiva due estensioni Apple per il tuo account con `pluginkit`, senza modificare file di sistema. MaterialX e Alembic ricevono un’anteprima più semplice, USDZ perde la vista AR e `.reality` non ha più anteprima. Un aggiornamento di macOS può reimpostare la scelta. L’apertura nell’app non richiede questa modifica.

</details>

<details>
<summary><strong>Mancano le texture</strong></summary>

Autorizza la cartella con **Mostra texture…**. Un’autorizzazione concessa soltanto in Quick Look va rinnovata dopo il riavvio del Mac. L’app ricorda le proprie autorizzazioni: avviarla una volta dopo il riavvio le rende di nuovo disponibili a Quick Look. File mancanti e formati di immagine o materiale non supportati possono impedire la visualizzazione delle texture.

</details>

<a id="architecture"></a>

## Dietro le quinte

App ed estensione condividono `Spacebar3DKit`: `ImportRouter` legge il file in un `ModelScene`, poi Metal lo disegna. I lettori Swift gestiscono STL, PLY, OBJ, 3MF, glTF, VRM e Blender; Model I/O gestisce USD; Assimp gestisce FBX e 3DS.

[Compilazione e architettura](DEVELOPMENT.md) · [Localizzazione](../LOCALIZATION.md) · [Cronologia delle modifiche](../../CHANGELOG.md) · [Informativa sulla privacy in inglese](../../PRIVACY.md)

<a id="credits"></a>

## Crediti e licenza

Spacebar 3D è distribuito sotto la [licenza Apache, versione 2.0](../../LICENSE).
Copyright © 2026 Vitaly Gorodetsky.

Consulta [CREDITS.md](../../CREDITS.md) per le origini del progetto, i collaboratori e i ringraziamenti, e le [licenze di terze parti](../../THIRD_PARTY_LICENSES.md) per i componenti con licenze separate. Gli avvisi sono disponibili anche nei riconoscimenti del menu Aiuto dell’app.
