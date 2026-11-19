# Développer Spacebar 3D

[English](../DEVELOPMENT.md) | [简体中文](../zh-Hans/DEVELOPMENT.md) | [Español](../es/DEVELOPMENT.md) | **Français** | [Deutsch](../de/DEVELOPMENT.md) | [日本語](../ja/DEVELOPMENT.md) | [Português (Brasil)](../pt-BR/DEVELOPMENT.md) | [한국어](../ko/DEVELOPMENT.md) | [Italiano](../it/DEVELOPMENT.md) | [Русский](../ru/DEVELOPMENT.md)

Compiler, tester et déboguer l'application macOS native et son extension Quick Look. Consultez le [README](README.md) pour les fonctionnalités et les limites des formats pris en charge.

[Prérequis](#requirements) · [Compilation](#build-local) · [Tests](#tests) · [Architecture](#how-it-works) · [Dépannage](#troubleshooting) · [Distribution](#distribution-signing--notarization)

Sauf indication contraire, exécutez les commandes depuis la racine du dépôt.

<a id="requirements"></a>

## Prérequis

| Prérequis | Remarques |
| :--- | :--- |
| Mac avec puce Apple sous macOS 26 ou ultérieur | Le projet et Assimp ciblent `arm64`, sans version Intel. |
| Xcode complet avec le SDK macOS 26 ou ultérieur | Les Command Line Tools seuls ne suffisent pas. L'environnement local actuel utilise Xcode 27.0. |
| XcodeGen | Génère le projet Xcode à partir de `project.yml`. |
| CMake et Ninja | Compilent la dépendance native Assimp. |
| Python 3 | Exécute le contrôle de cohérence des traductions. |
| Identité de signature de développement | Nécessaire pour l'application installée, son extension et leur App Group partagé. Voir ci-dessous. |

```bash
brew install xcodegen cmake ninja
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

Si votre shell utilise les Command Line Tools ou une autre installation de Xcode, sélectionnez Xcode complet avant de compiler :

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`build.sh` détecte aussi cette installation standard lorsque `xcode-select` pointe vers les Command Line Tools. Pour les appels directs à `xcodebuild` et la compilation des dépendances, le répertoire de développement doit déjà être correct.

<a id="build-local"></a>

## Compilation locale

<a id="configure-signing"></a>

### Configurer la signature

La configuration du dépôt utilise l'équipe définie dans [`project.yml`](../../project.yml). Pour utiliser votre propre équipe :

1. Définissez `DEVELOPMENT_TEAM` et des identifiants de bundle adaptés dans `project.yml`.
2. Configurez un App Group pour cette équipe. Utilisez son identifiant dans [`Spacebar3D.entitlements`](../../Spacebar3D/App/Spacebar3D.entitlements), [`Spacebar3DExtension.entitlements`](../../Spacebar3D/Extension/Spacebar3DExtension.entitlements) et `ViewerSettings.appGroup` dans [`ViewerSettings.swift`](../../Spacebar3D/Shared/ViewerSettings.swift).
3. Vérifiez que Xcode peut utiliser le certificat Apple Development de l'équipe et les éléments de provisionnement requis. Régénérez le projet après toute modification de configuration.

L'App Group actuel est `V3AQWQ8JMY.com.vitalis.Spacebar3D`. Modifier uniquement l'équipe dans une commande de compilation ne change pas cet identifiant. Une compilation non signée ou signée ad hoc ne remplace pas les tests d'enregistrement de l'extension et d'accès au conteneur partagé.

<a id="build-the-app"></a>

### Compiler l'application

```bash
./scripts/build.sh
```

Le script compile Assimp si son framework est absent, exécute XcodeGen, puis compile le schéma `Spacebar3D` en configuration Release. Résultat :

```text
build/Build/Products/Release/Spacebar 3D.app
```

La première compilation nécessite un accès réseau pour les dépendances. [`build-assimp.sh`](../../scripts/build-assimp.sh) fixe Assimp à `v6.0.6` et vérifie le SHA complet du commit `a79ff6bbce54d3e01186a918dc6374ed55317426` avant compilation. Il produit un XCFramework statique arm64 avec les importateurs FBX et 3DS, sans exportateurs ni Draco.

Relancez ce script lorsque la révision fixée change. `build.sh` vérifie l'existence du framework, pas sa conformité à cette révision. Pour utiliser une copie locale au commit requis :

```bash
ASSIMP_SRC=/path/to/assimp ./scripts/build-assimp.sh
```

<a id="register-and-exercise-quick-look"></a>

### Enregistrer et tester Quick Look

1. Copiez l'application compilée dans `/Applications` et lancez cette copie une fois.
2. Activez **Spacebar 3D** dans **Réglages Système → Général → Ouverture et extensions → Quick Look**.
3. Sélectionnez un fichier pris en charge dans le Finder et appuyez sur Espace.
4. Ouvrez le même fichier avec **Fichier → Ouvrir…** dans l'application pour vérifier les deux modes d'exécution.

Si l'enregistrement n'est plus à jour, actualisez le cache et essayez un fichier GLB :

```bash
qlmanage -r
qlmanage -r cache
qlmanage -p /path/to/model.glb
```

macOS peut choisir l'aperçu d'Apple pour OBJ, STL, PLY, USD et USDZ. Cela ne prouve pas un échec de l'extension. Utilisez l'application ou le remplacement facultatif décrit dans le [README](README.md#help).

<a id="development"></a>

## Développement

Pour modifier et déboguer dans Xcode :

```bash
./scripts/build-assimp.sh
xcodegen generate
open Spacebar3D.xcodeproj
```

Compilez Assimp une fois par révision de la dépendance et régénérez le projet lorsque `project.yml` change. Git ignore `.xcodeproj`, les deux fichiers `Info.plist` générés, les résultats de compilation et `Vendor/Assimp.xcframework`. Modifiez la source YAML, pas les fichiers générés.

Pour une compilation Debug incrémentale depuis le terminal :

```bash
xcodebuild -project Spacebar3D.xcodeproj -scheme Spacebar3D \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build build
```

`SKIP_XCODEGEN=1 ./scripts/build.sh` réutilise le projet généré existant et compile toujours en Release. Ne l'utilisez que si ce projet correspond au YAML.

<a id="capture-media"></a>

### Enregistrer une vidéo d'aperçu et des captures d'écran

Exécutez le script depuis une session macOS ouverte, avec les prérequis de compilation ci-dessus. Dans Réglages Système, autorisez l'enregistrement de l'écran pour l'application depuis laquelle vous lancez le script.

Si le modèle fait référence à des textures, des matériaux ou de la géométrie externes, ouvrez-le d'abord dans l'application Spacebar 3D habituelle. Utilisez le bouton de dossier du visualiseur pour autoriser l'accès au dossier qui contient ces fichiers. La version de capture réutilise l'autorisation enregistrée. Ouvrir le fichier du modèle seul peut laisser ses fichiers associés inaccessibles.

```bash
brew install ffmpeg
./scripts/capture-media.sh /path/to/model.glb
```

Le script compile et lance une copie distincte de Spacebar 3D avec la capture activée. Pour réutiliser une copie déjà compilée avec cette option, indiquez le chemin de son paquet `.app` dans `SPACEBAR3D_APP`. Par défaut, le script crée un dossier sous `build/media-captures/`. Pour choisir le dossier de sortie, passez un chemin encore inutilisé en deuxième argument.

La vidéo d'aperçu publique du Mac App Store, `preview.mp4`, dure 30 secondes et montre tous les styles de rendu disponibles pour le modèle. Elle est en 1920 × 1080 à 30 images par seconde. Le script enregistre aussi quatre PNG de 2560 × 1600 et `demo.gif`. Pour un modèle qui offre au moins trois styles, le GIF reprend le montage de 15 secondes de la boucle de styles. Avec moins de styles, il reprend l'aperçu à sa vitesse d'origine. La première capture utilise la vue Texturée si elle est disponible (`01-textured.png`) ou la vue Solide dans les autres cas (`01-solid.png`). Les autres images s'appellent `02-wireframe.png`, `03-normals.png` et `04-hologram.png`.

<a id="capture-feature-loop"></a>

### Enregistrer une boucle de styles

Utilisez la même configuration de capture pour créer une boucle de 15 secondes à 30 images par seconde. Le modèle doit prendre en charge au moins trois styles de rendu. Le script privilégie Cel-shading, Art voxel et Hologramme.

```bash
./scripts/capture-feature-loop.sh /path/to/model.glb
```

Par défaut, le script enregistre `feature-loop.mp4` dans un nouveau dossier sous `build/media-captures/`. Pour choisir le dossier de sortie, passez un chemin encore inutilisé en deuxième argument.

<a id="capture-screenshots"></a>

### Prendre des captures d'écran pour l'App Store

Utilisez la même configuration de capture pour générer les quatre PNG sRGB de 2560 × 1600 indiqués plus haut.

```bash
./scripts/capture-screenshots.sh /path/to/model.glb
```

Par défaut, le script enregistre les fichiers dans un nouveau dossier sous `build/media-captures/`. Pour choisir le dossier de sortie, passez un chemin encore inutilisé en deuxième argument.

<a id="capture-app-review"></a>

### Enregistrer une démonstration privée pour App Review

Installez et lancez l'application Spacebar 3D habituelle et activez son extension Quick Look. Choisissez un modèle qui s'ouvre de façon interactive dans Quick Look depuis le Finder. Avant l'enregistrement, fermez l'aperçu Quick Look dans le Finder et les fenêtres du visualiseur autonome qui portent le même nom de fichier. Prévoyez l'autorisation d'enregistrement de l'écran décrite plus haut, les outils Swift en ligne de commande et FFmpeg avec les filtres `drawtext` et `subtitles`. Gardez le terminal visible et suivez ses indications. Gardez le fichier sélectionné dans le Finder et passez à la présentation par liste si nécessaire. Quand le terminal le demande, appuyez sur Espace et faites pivoter le modèle ou zoomez deux fois. À l'invite, cliquez sur le bouton qui ouvre le fichier dans Spacebar 3D. Si macOS affiche un menu d'applications, choisissez Spacebar 3D. Si le bouton est absent, fermez Quick Look et ouvrez le même fichier dans Spacebar 3D avec **Fichier → Ouvrir…**. Faites pivoter le modèle ou zoomez deux fois dans le visualiseur autonome.

```bash
SPACEBAR3D_REVIEW_ANIMATION_MODEL=docs/app-store/Spacebar3D-Review-Model.glb \
  ./scripts/capture-app-review.sh /path/to/model.fbx build/media-captures/app-review
```

Le script ajoute des légendes et enregistre `app-review.mp4` dans un nouveau dossier sous `build/media-captures/`. Pour choisir le dossier de sortie, passez en deuxième argument un chemin encore inutilisé. Définissez `SPACEBAR3D_REVIEW_APP` si l'application est installée ailleurs que dans `/Applications/Spacebar 3D.app`.

Après l'enregistrement guidé, le script enregistre les chapitres sur les commandes du visualiseur, les réglages, l'aide et la confidentialité. L'exemple ajoute la lecture à l'aide du modèle animé fourni. Définissez `SPACEBAR3D_REVIEW_CAPTURE_APP` pour réutiliser une application déjà compilée pour la capture. Par défaut, le script la compile avec la configuration de développement décrite plus haut.

Si vous disposez déjà d'un enregistrement des étapes guidées dans le Finder et le visualiseur, ajoutez les chapitres avec `capture-review-features.sh`. Consultez `--help`.

<a id="tests"></a>

## Tests

Compilez Assimp avant de résoudre le package ou d'exécuter l'une des deux suites.

<a id="full-xcode-suite"></a>

### Suite Xcode complète

C'est la commande principale de régression. Elle inclut les tests des sources de l'application, du code partagé et de l'extension, ainsi que les neuf cibles de test du package déclarées dans `project.yml`.

```bash
xcodegen generate
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build
python3 scripts/check-localizations.py
```

Pour cibler certains tests, ajoutez un sélecteur `-only-testing`, par exemple :

```bash
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build \
  -only-testing:ViewerUITests/NativeViewerInputTests
```

Xcode écrit les bundles `.xcresult` dans `build/Logs/Test/`.

<a id="package-only-tests"></a>

### Tests du package uniquement

Ils excluent les tests des sources hôtes de `Spacebar3DTests` :

```bash
xcrun swift test --package-path Packages/Spacebar3DKit
```

Deux tests de modèles volumineux sont activés avec `P3D_LARGE=1`. L'un crée un fichier STL de test d'environ 100 Mo. Pour exécuter explicitement ce benchmark :

```bash
P3D_LARGE=1 xcrun swift test --package-path Packages/Spacebar3DKit \
  --filter LargeModelTests
```

<a id="what-the-tests-establish"></a>

### Ce que les tests vérifient

- Les tests des réglages utilisent un stockage temporaire explicite. Ajoutez des cas de normalisation à [`settings-vectors.json`](../../testdata/settings-vectors.json) si les règles changent.
- Les tests d'import créent de petits fichiers et vérifient les entrées mal formées ou tronquées.
- Les tests du moteur de rendu dessinent hors écran et inspectent les pixels. Ils nécessitent un périphérique Metal fonctionnel.
- Les tests du visualiseur couvrent les entrées natives, les métadonnées d'accessibilité, les commandes, la disposition et les contrôles SwiftUI, notamment avec ViewInspector.
- Les vérifications de localisation couvrent les clés source, les entrées du catalogue et les paramètres de substitution. Les tests du package vérifient aussi les ressources linguistiques compilées.

Le schéma Xcode compile les sources hôtes dans un bundle de test. Il ne lance pas l'application signée dans sa sandbox de production. Une réussite ne vérifie ni l'enregistrement Quick Look, ni les autorisations des dossiers, ni la parole VoiceOver, ni le comportement d'un téléchargement notarié. Pour ces changements, testez aussi l'application signée installée et l'extension Finder.

<a id="how-it-works"></a>

## Fonctionnement

```text
Finder → Quick Look extension ─┐
                              ├─ ViewerFactory → NativeViewer
App → model window ───────────┘                      │
                                     ImportRouter → ModelScene
                                                     │
                                           RenderMetal / MTKView
                                           + SwiftUI controls
```

Les deux hôtes partagent le package local `Spacebar3DKit`. L'import s'exécute hors du thread principal ; le visualiseur natif coordonne le rendu et les contrôles.

| Emplacement | Responsabilité |
| :--- | :--- |
| `Spacebar3D/App/` | Configuration, réglages, fenêtres de modèles, enregistrement comme application par défaut, menus, aide et crédits. |
| `Spacebar3D/Extension/` | Cycle de vie de l'aperçu Quick Look. |
| `Spacebar3D/Shared/` | Création du visualiseur et réglages partagés. |
| `Packages/Spacebar3DKit/Sources/ModelCore/` | Données de scène, détection de format, animation, topologie et localisation. |
| `…/Sources/ImportRouter/` et `…/Sources/Import*/` | Sélection du format et lecteurs. |
| `…/Sources/RenderMetal/` | Scène GPU, caméra, ombrage et rendu. |
| `…/Sources/ViewerUI/` | API du visualiseur, entrées natives, contrôles SwiftUI et autorisations des dossiers. |
| `…/Sources/CZstd/` | Décodeur Zstandard intégré pour les fichiers Blender compressés. |
| `Spacebar3DTests/` et `Packages/Spacebar3DKit/Tests/` | Tests des sources hôtes et du package. |
| `docs/<language-code>/README.md` | Les neuf README traduits. |
| `docs/<language-code>/DEVELOPMENT.md` | Les neuf traductions du guide de développement. |

Les lecteurs Swift natifs gèrent STL, PLY, OBJ, 3MF, glTF/GLB, VRM/VRMA et Blender. Model I/O gère USD ; Assimp gère FBX et 3DS. `FormatDetector` examine les premiers octets et, pour les formats texte ambigus, l'extension. Les types de document et `QLSupportedContentTypes` sont déclarés dans `project.yml`.

Les fichiers d'animation seuls dotés d'un squelette compatible peuvent afficher un aperçu filaire du squelette. Aucun avatar par défaut n'est fourni. La prise en charge reste volontairement plus limitée que celle d'un logiciel DCC complet. Mettez à jour les limites du README lorsque les lecteurs changent.

<a id="implementation-notes"></a>

## Notes d'implémentation

<a id="sandbox-and-related-files"></a>

### Sandbox et fichiers associés

Les deux cibles utilisent App Sandbox et l'accès en lecture seule aux fichiers sélectionnés par l'utilisateur. Aucune n'a d'autorisation réseau ni d'exception temporaire à la sandbox.

Ouvrir un modèle n'autorise pas librement l'accès aux fichiers voisins. Les deux hôtes peuvent proposer **Afficher le modèle…**, **Afficher les matériaux…** ou **Afficher les textures…** pour demander l'accès au dossier. L'application gère aussi certains fichiers de matériaux associés de même nom, tels que `ship.mtl` à côté de `ship.obj`.

[`FolderGrants.swift`](../../Packages/Spacebar3DKit/Sources/ViewerUI/FolderGrants.swift) conserve les autorisations de l'application sous forme de signets à portée de sécurité. Quick Look conserve ses propres signets ordinaires et lit les copies actualisées par l'application dans le conteneur partagé. Une autorisation accordée uniquement à Quick Look doit être renouvelée après un redémarrage du Mac. Lancer l'application actualise ses autorisations mémorisées pour l'extension. La lecture reste limitée aux dossiers autorisés et à leurs descendants.

<a id="settings"></a>

### Réglages

`ViewerSettings` stocke `viewer-settings.json` dans le conteneur App Group. L'application l'écrit ; les nouveaux visualiseurs chargent ses valeurs normalisées. Des réglages invalides, trop volumineux ou absents rétablissent les valeurs par défaut. Aucune migration n'est faite depuis l'ancien emplacement `~/Library/Application Support/Spacebar3D/`, hors conteneur.

<a id="input-and-accessibility"></a>

### Entrées et accessibilité

Les flèches font orbiter la caméra et Maj-flèches la déplacent uniquement lorsque le canevas du modèle de l'application traite le clavier. Espace y lance ou suspend la lecture. Ce n'est pas un raccourci de menu global et il ne doit pas intercepter l'activation des boutons ou curseurs ayant le focus. Quick Look conserve Espace pour fermer l'aperçu. Les menus et actions d'accessibilité offrent des alternatives aux gestes du pointeur.

Après modification des contrôles, vérifiez le focus, les fenêtres étroites, les traductions longues, Augmenter le contraste et Réduire la transparence. Écoutez les annonces VoiceOver séparément des assertions sur l'arbre d'accessibilité.

<a id="localization-and-documentation"></a>

### Localisation et documentation

Le catalogue partagé `Packages/Spacebar3DKit/Sources/ModelCore/Resources/Localizable.xcstrings` fournit dix langues à l'application et à l'extension. Suivez [LOCALIZATION.md](../LOCALIZATION.md) pour les chaînes complètes, les paramètres de substitution, les ressources compilées et la disposition.

Le README anglais reste à la racine ; les traductions sont dans `docs/<language-code>/`. Les guides de développement sont dans ces mêmes dossiers, avec la source anglaise dans `docs/DEVELOPMENT.md`. Gardez toutes les versions cohérentes pour les formats, les contrôles, l'installation, les autorisations et les procédures de développement.

<a id="troubleshooting"></a>

## Dépannage

| Symptôme | Vérification |
| :--- | :--- |
| Assimp manque lors de la résolution du package | Exécutez `./scripts/build-assimp.sh` avec Xcode complet, CMake et Ninja disponibles. |
| Échec de signature ou réglages partagés indisponibles | Vérifiez certificat, équipe, identifiants de bundle et App Group. Une variable d'environnement seule ne réécrit pas les entitlements. |
| Modifications perdues après génération | Modifiez `project.yml`, pas les fichiers `.xcodeproj` ou `Info.plist` générés. |
| Extension absente ou ancienne version chargée | Lancez la bonne copie installée, activez l'extension, vérifiez son enregistrement et actualisez Quick Look. Distinguez copie installée et copie du dossier de compilation. |
| Le visualiseur d'Apple s'ouvre | Consultez les limites ci-dessus et comparez avec Fichier → Ouvrir dans l'application. |
| Textures ou géométrie absentes | Lisez l'avis, autorisez le dossier et vérifiez les limites du format et les fichiers associés. |
| Échec d'un test GPU | Vérifiez la disponibilité de Metal et analysez l'échec. Un GPU indisponible ne constitue pas une vérification réussie du rendu. |

Inspectez l'enregistrement de l'extension et suivez ses journaux :

```bash
pluginkit -m | rg -i spacebar3d
log stream --predicate 'process == "Spacebar3DExtension"'
```

La première commande utilise `rg` de ripgrep ; `grep -i spacebar3d` convient aussi. Dans un autre terminal, lancez `qlmanage -p /path/to/model.glb`. Un modèle rejeté doit afficher une erreur dans l'aperçu. Identifiez un problème d'import, de rendu, d'accès ou de sélection d'extension avant de modifier la signature ou les autorisations.

<a id="distribution-signing--notarization"></a>

## Distribution, signature et notarisation

Les scripts fournis assurent la **distribution directe par Developer ID sous forme de DMG**. Ils ne créent, n'exportent ni ne téléversent d'archive pour le Mac App Store. Celui-ci nécessite une procédure distincte de signature, d'archivage, d'export et de soumission à App Store Connect.

Pour la distribution directe, utilisez une identité Developer ID Application et la notarisation. Le [guide Apple](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) décrit les exigences de signature et du service. Les tarifs d'adhésion ne sont pas reproduits ici.

<a id="manual"></a>

### Procédure manuelle

Après avoir configuré des identifiants d'équipe et d'App Group cohérents :

```bash
SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ./scripts/build.sh
```

Avec `SIGN_IDENTITY`, le script choisit la signature manuelle, transmet `DEVELOPMENT_TEAM`, ajoute un horodatage sécurisé et désactive l'injection des entitlements de débogage de base. Hardened Runtime est activé dans `project.yml`. Sans `SIGN_IDENTITY`, le script utilise la signature de développement du projet.

Pour la notarisation locale, préférez un profil du trousseau. Enregistrez les identifiants de manière interactive avec `notarytool`, puis utilisez le nom du profil :

```bash
xcrun notarytool store-credentials "spacebar3d-notary"
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" ./scripts/notarize.sh
```

Le script accepte un chemin d'application facultatif :

```bash
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" \
  ./scripts/notarize.sh "/path/to/Spacebar 3D.app"
```

L'authentification est choisie dans cet ordre :

| Méthode | Variables |
| :--- | :--- |
| Profil du trousseau | `NOTARY_KEYCHAIN_PROFILE` |
| Clé API App Store Connect | `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER` |
| Identifiants du compte Apple | `APPLE_TEAM_ID`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` |

La dernière méthode transmet un mot de passe pour application à `notarytool` en argument. Le profil du trousseau évite cela sur une machine partagée. Ne placez pas les clés de signature ni les identifiants dans le dépôt.

`notarize.sh` vérifie la signature Developer ID de l’application et crée un DMG avec un raccourci Applications. Il signe le DMG avec l’identité lue dans la signature de l’application ou avec `SIGN_IDENTITY` si cette variable est renseignée. Le certificat et la clé privée doivent être disponibles dans le trousseau. Le script soumet le DMG à Apple, attend son acceptation, attache et valide le ticket, puis vérifie Gatekeeper avec `spctl`. Une fois ces vérifications terminées, il écrit `Spacebar3D.dmg` à la racine du dépôt. Testez le fichier téléchargé avant de le partager.

<a id="automated-github-actions"></a>

### Automatisation avec GitHub Actions

[Le workflow de publication](../../.github/workflows/release.yml) utilise le runner Apple silicon `macos-26` avec Xcode 26. Poussez ou sélectionnez un tag au format `vMAJOR.MINOR.PATCH` correspondant à `MARKETING_VERSION` et pointant vers un commit de `origin/main`.

Le workflow génère le projet et lance `Spacebar3DTests` et la vérification de la localisation avant d’importer le certificat de signature. Il compile avec Developer ID, compare les versions de l’application et de l’extension au tag, puis signe et notarise le DMG. Il supprime le trousseau temporaire avant de joindre le DMG à une GitHub Release.

Configurez ces secrets dans **le dépôt de destination réel** :

| Secret | Contenu |
| :--- | :--- |
| `MACOS_CERTIFICATE` | Certificat Developer ID Application et clé privée exportés en `.p12`, encodés en Base64. |
| `MACOS_CERTIFICATE_PWD` | Mot de passe de ce `.p12`. |
| `KEYCHAIN_PASSWORD` | Mot de passe du trousseau temporaire de compilation. |
| `APPLE_TEAM_ID` | Identifiant de l'équipe de signature. |
| `NOTARY_APPLE_ID` | Compte Apple pour la notarisation. |
| `NOTARY_PASSWORD` | Son mot de passe pour application. |

Spécifiez le dépôt, par exemple avec `gh secret set APPLE_TEAM_ID --repo OWNER/REPOSITORY`, qui demande la valeur. Ne supposez pas que `origin` désigne un dépôt existant ou le dépôt de publication prévu.

Avant de créer un tag de publication, définissez `MARKETING_VERSION` et `CURRENT_PROJECT_VERSION` dans `project.yml`, mettez à jour l’historique des changements, lancez les tests et vérifiez la build signée. L’envoi du tag correspondant peut publier une GitHub Release si le workflow aboutit.

<a id="references"></a>

## Références

- [Architecture du moteur de rendu natif](../architecture/native-rewrite.md)
- [Conception du visualiseur](../design/neon-garden-viewer.md)
- [Localisation](../LOCALIZATION.md)
- [Licences tierces](../../THIRD_PARTY_LICENSES.md)
- [Apple : personnaliser la notarisation](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [magicien/VRMQuickLook](https://github.com/magicien/VRMQuickLook), implémentation VRM 0.x avec SceneKit
- [magicien/GLTFQuickLook](https://github.com/magicien/GLTFQuickLook), référence pour la structure Quick Look
- [pixiv/three-vrm](https://github.com/pixiv/three-vrm), référence pour le comportement VRM
