<p align="center">
  <img src="../../Packages/Spacebar3DKit/Sources/ViewerUI/Resources/Mark.png" width="200" alt="Caméléon de Spacebar 3D, moitié fil de fer et moitié ombré">
</p>

<h1 align="center">Spacebar 3D</h1>
<p align="center"><strong>Vos modèles, à une barre d’espace près.</strong></p>
<p align="center">Un visualiseur 3D natif pour Finder Quick Look et votre Mac.</p>
<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-111e17?style=flat-square" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple_silicon-arm64-a8e6a3?style=flat-square" alt="Apple silicon / arm64">
  <img src="https://img.shields.io/badge/renderer-Metal-b5cfff?style=flat-square" alt="Metal">
  <a href="../../LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-f05b99?style=flat-square" alt="Apache License 2.0"></a>
</p>
<p align="center">
  <a href="#install">Premiers pas</a> · <a href="#formats">Formats</a> · <a href="#controls">Commandes</a> · <a href="DEVELOPMENT.md">Guide de développement</a>
</p>
<p align="center"><a href="../../README.md">English</a> · <a href="../zh-Hans/README.md">简体中文</a> · <a href="../es/README.md">Español</a> · <strong>Français</strong> · <a href="../de/README.md">Deutsch</a> · <a href="../ja/README.md">日本語</a> · <a href="../pt-BR/README.md">Português do Brasil</a> · <a href="../ko/README.md">한국어</a> · <a href="../it/README.md">Italiano</a> · <a href="../ru/README.md">Русский</a></p>

---

## Trouvez-le. Appuyez sur Espace. Faites-le tourner.

Sélectionnez un fichier 3D compatible dans Finder et appuyez sur <kbd>Espace</kbd>. Faites tourner le modèle, inspectez sa topologie, changez son apparence ou parcourez une animation. Ouvrez-le dans l’application pour disposer d’une fenêtre dédiée.

<p align="center">
  <img src="../demo.gif" width="900" alt="Modèle de char dans le visualiseur Spacebar 3D, avec les commandes visibles">
</p>

> macOS peut choisir son propre aperçu pour OBJ, STL, PLY, USD et USDZ. **Fichier → Ouvrir…** ou **Ouvrir avec → Spacebar 3D** dans Finder permet d’afficher tout fichier compatible dans ce visualiseur.

<a id="looks"></a>

## Un modèle, plusieurs regards

| Inspecter | Explorer | Animer |
| :--- | :--- | :--- |
| Vues Solide, Texturée et Normales, fil de fer superposé, nombre de faces et de sommets. | Styles sans ombrage, anime, cel-shading, rétro, art voxel et hologramme ; ombrage plat ou lissé et réglages des matériaux. | Choix des clips, déplacement dans l’animation et répétition ; aperçu du squelette pour les fichiers compatibles ne contenant qu’une animation. |

**Réglez la lumière.** Sept ambiances, de Glasshouse à Neon, avec luminosité, direction et rotation automatique de la lumière. **Gardez vos repères.** Cliquez sur un axe du gizmo, tournez, déplacez, cadrez le modèle ou affichez la grille au sol. Les petits aperçus de Finder affichent uniquement le modèle.

**Natif sur Mac.** Swift, Metal, SwiftUI et AppKit, partagés entre l’application et son extension Quick Look. Le traitement des modèles est local ; aucun des deux composants ne possède d’autorisation réseau. L’interface prend en charge les dix langues du sélecteur ci-dessus et suit les préférences de macOS. [Notes de localisation, en anglais](../LOCALIZATION.md).

<a id="install"></a>

## Premiers pas

**macOS 26 ou ultérieur · Apple silicon · compilation depuis les sources**

Installez la version complète de Xcode avec le SDK macOS 26 ou ultérieur, XcodeGen, CMake et Ninja. Le projet utilise une équipe de signature et un App Group. Pour une autre équipe, configurez votre identité de signature et les identifiants correspondants avant de compiler, selon le [guide de signature](DEVELOPMENT.md#build-local).

Depuis votre copie locale du dépôt :

```bash
brew install xcodegen cmake ninja
./scripts/build.sh
```

La première compilation télécharge et compile la version fixée d’Assimp.

1. Déplacez `build/Build/Products/Release/Spacebar 3D.app` dans **Applications**.
2. **Lancez l’application une fois** pour enregistrer l’extension.
3. Activez **Spacebar 3D** dans **Réglages Système → Général → Ouverture et extensions → Quick Look**.
4. Sélectionnez un fichier compatible dans Finder et appuyez sur <kbd>Espace</kbd>.

Pour distribuer l’application, suivez le [guide de signature Developer ID et de notarisation](DEVELOPMENT.md#distribution-signing--notarization).

<details>
<summary><strong>Utiliser Spacebar 3D par défaut</strong></summary>

Dans les réglages de l’application, cliquez sur **Définir par défaut…**. macOS peut demander confirmation ; les formats qui n’ont pas pu être modifiés sont signalés. Ce choix concerne le double-clic dans Finder, pas la sélection de l’extension Quick Look.

</details>

<a id="formats"></a>

## Formats pris en charge

Avatars, ressources de jeux, exports CAO, scans et maillages Blender.

`VRM` · `VRMA` · `glTF` · `GLB` · `FBX` · `OBJ` · `STL` · `3MF` · `PLY` · `USD` · `USDA` · `USDC` · `USDZ` · `3DS` · `BLEND`

<details>
<summary><strong>Prise en charge et limites de chaque format</strong></summary>

| Format | Prise en charge |
| :--- | :--- |
| `.vrm` | Avatars VRM 0.x / 1.0 : ombrage toon, contours et spring bones. |
| `.vrma` | Animation VRM sans maillage ; mouvement affiché sur une silhouette filaire du squelette. |
| `.glb` / `.gltf` | glTF 2.0 : matériaux, textures, skinning et animations. Les fichiers `.bin` et images externes nécessitent l’accès au dossier. Draco, Meshopt et les maillages instanciés ne sont pas pris en charge. |
| `.fbx` | Binaire ou texte ; maillages avec skinning et animations intégrées. Images incorporées, voisines du fichier ou dans son dossier `.fbm`. |
| `.obj` | Géométrie et couleurs des sommets ; matériaux et textures du `.mtl` après autorisation du dossier. Sans faces, affichage sous forme de nuage de points. |
| `.stl` | STL binaire ou texte. |
| `.3mf` | Couleurs par objet ou triangle, images, matériaux métalliques et translucides. |
| `.ply` | Maillages avec couleurs des sommets ou nuages de points en l’absence de faces. |
| `.usd` / `.usda` / `.usdc` / `.usdz` | Matériaux, textures incorporées et animation squelettique. |
| `.3ds` | Couleurs et transparence des matériaux ; textures externes après autorisation du dossier. |
| `.blend` | Blender 2.80 et ultérieur : maillages visibles et matériaux simples tels qu’enregistrés ; images empaquetées et textures du dossier autorisé. Les modificateurs, poses d’armature et animations ne sont pas appliqués ; les réseaux arbitraires de nœuds de shader ne sont pas évalués. |

Les FBX contenant uniquement une animation et les VRMA dotés d’un squelette compatible sont affichés comme des silhouettes filaires. Aucun modèle ni avatar n’est fourni avec l’application.

</details>

### Textures dans des fichiers séparés

Utilisez **Afficher les textures…**, **Afficher les matériaux…** ou **Afficher le modèle…** pour autoriser l’accès en lecture seule au dossier du modèle et à ses sous-dossiers. Les textures incorporées n’exigent pas cette autorisation, mais leurs formats d’image et de matériau doivent être compatibles. Dans l’application, un fichier de matériau portant le même nom, comme `ship.mtl` à côté de `ship.obj`, peut être lu sans demande.

Si le modèle s’ouvre mais qu’aucune des textures référencées ne peut être affichée, le visualiseur passe de la vue **Texturée** à la vue **Solide**.

<a id="controls"></a>

## Prenez les commandes

| Action | Commande |
| :--- | :--- |
| Faire tourner | Glisser, ou touches fléchées lorsque le canevas de l’application a le focus |
| Déplacer | Glisser avec le bouton droit ou en maintenant Maj, Option ou Commande |
| Déplacer au clavier | Maj + flèches dans le canevas, ou le sous-menu de déplacement du menu Présentation |
| Zoomer | Défilement ou pincement |
| Cadrer le modèle | Bouton de cadrage ou ⌘0 dans l’application |
| Regarder selon un axe | Cliquer sur un axe du gizmo |
| Lire ou mettre en pause | Bouton de lecture, ou Espace lorsque le canevas de l’application a le focus |
| Fermer Quick Look | Espace |
| Solide / Texturée / Normales | ⌘1 / ⌘2 / ⌘3 dans l’application |
| Fil de fer | ⌘4 dans l’application |

La barre inférieure regroupe vues, styles et matériaux. À droite : gizmo, lumière, cadrage, grille et rotation automatique. La barre d’animation permet de choisir les clips et de les répéter. Les réglages définissent le fond, la couleur solide, la vue, la luminosité, la grille, la rotation et la lecture par défaut. Les menus de présentation et de lecture restent disponibles lorsque les commandes du canevas sont masquées.

<a id="help"></a>

## Un coup de main

Ouvrez le menu **?** dans la barre d’outils du visualiseur pour consulter les commandes, la politique de confidentialité et les remerciements. Ce menu est disponible dans l’application et dans Quick Look.

Un problème ou une question ? Dans l’application, choisissez **Aide → Assistance Spacebar 3D**, ou [ouvrez un ticket](https://github.com/vitalis/Spacebar3D/issues).

<details>
<summary><strong>L’aperçu ne s’affiche pas</strong></summary>

Lancez l’application une fois et activez l’extension. Si nécessaire, actualisez le cache Quick Look :

```bash
qlmanage -r && qlmanage -r cache
```

Pour OBJ, STL, PLY, USD et USDZ, essayez d’ouvrir directement le fichier dans l’application.

</details>

<details>
<summary><strong>Préférer Spacebar 3D aux aperçus Apple</strong></summary>

Le remplacement facultatif est réversible :

```bash
scripts/prefer-spacebar3d.sh status
scripts/prefer-spacebar3d.sh on
scripts/prefer-spacebar3d.sh off
```

`on` privilégie Spacebar 3D ; `off` rétablit les extensions Apple. Le script désactive deux extensions Apple pour votre compte avec `pluginkit`, sans modifier les fichiers système. MaterialX et Alembic obtiennent un aperçu plus simple, USDZ perd la vue AR et `.reality` n’a plus d’aperçu. Une mise à jour de macOS peut réinitialiser ce choix. L’ouverture dans l’application ne nécessite pas ce remplacement.

</details>

<details>
<summary><strong>Des textures manquent</strong></summary>

Autorisez le dossier avec **Afficher les textures…**. Une autorisation accordée uniquement dans Quick Look doit être renouvelée après le redémarrage du Mac. L’application mémorise ses autorisations ; la lancer une fois après le redémarrage les rend à nouveau disponibles pour Quick Look. Des images absentes ou des formats d’image et de matériau non pris en charge peuvent empêcher l’affichage d’une texture.

</details>

<a id="architecture"></a>

## Sous le capot

L’application et l’extension partagent `Spacebar3DKit` : `ImportRouter` lit le fichier, produit un `ModelScene`, puis Metal l’affiche. Les lecteurs Swift traitent STL, PLY, OBJ, 3MF, glTF, VRM et Blender ; Model I/O traite USD ; Assimp traite FBX et 3DS.

[Compilation et architecture](DEVELOPMENT.md) · [Localisation](../LOCALIZATION.md) · [Historique des changements](../../CHANGELOG.md) · [Politique de confidentialité en anglais](../../PRIVACY.md)

<a id="credits"></a>

## Crédits et licence

Spacebar 3D est distribué sous la [licence Apache, version 2.0](../../LICENSE).
Copyright © 2026 Vitaly Gorodetsky.

Consultez [CREDITS.md](../../CREDITS.md) pour les origines du projet, les contributeurs et les remerciements, et les [licences tierces](../../THIRD_PARTY_LICENSES.md) pour les composants sous licences distinctes. Ces notices sont également disponibles dans les remerciements du menu Aide de l’application.
