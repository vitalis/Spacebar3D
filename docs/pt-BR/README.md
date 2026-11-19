<p align="center">
  <img src="../../Packages/Spacebar3DKit/Sources/ViewerUI/Resources/Mark.png" width="200" alt="Camaleão do Spacebar 3D, metade estrutura de arame e metade sombreado">
</p>

<h1 align="center">Spacebar 3D</h1>
<p align="center"><strong>Seus modelos. A uma barra de espaço de distância.</strong></p>
<p align="center">Um visualizador 3D nativo para o Quick Look do Finder e seu Mac.</p>
<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-111e17?style=flat-square" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple_silicon-arm64-a8e6a3?style=flat-square" alt="Apple silicon / arm64">
  <img src="https://img.shields.io/badge/renderer-Metal-b5cfff?style=flat-square" alt="Metal">
  <a href="../../LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-f05b99?style=flat-square" alt="Apache License 2.0"></a>
</p>
<p align="center">
  <a href="#install">Primeiros passos</a> · <a href="#formats">Formatos</a> · <a href="#controls">Controles</a> · <a href="DEVELOPMENT.md">Guia de desenvolvimento</a>
</p>
<p align="center"><a href="../../README.md">English</a> · <a href="../zh-Hans/README.md">简体中文</a> · <a href="../es/README.md">Español</a> · <a href="../fr/README.md">Français</a> · <a href="../de/README.md">Deutsch</a> · <a href="../ja/README.md">日本語</a> · <strong>Português do Brasil</strong> · <a href="../ko/README.md">한국어</a> · <a href="../it/README.md">Italiano</a> · <a href="../ru/README.md">Русский</a></p>

---

## Encontre. Aperte Espaço. Gire.

Selecione um arquivo 3D compatível no Finder e pressione <kbd>Espaço</kbd>. Gire o modelo, examine a topologia, mude o visual ou percorra uma animação. Abra-o no app para ter uma janela dedicada.

<p align="center">
  <img src="../demo.gif" width="900" alt="Modelo de um tanque no visualizador do Spacebar 3D, com os controles visíveis">
</p>

> O macOS pode escolher sua própria pré-visualização para OBJ, STL, PLY, USD e USDZ. **Arquivo → Abrir…** ou **Abrir com → Spacebar 3D** no Finder abre qualquer arquivo compatível neste visualizador.

<a id="looks"></a>

## Um modelo, muitos visuais

| Examine | Explore | Reproduza |
| :--- | :--- | :--- |
| Visualizações sólida, texturizada e de normais; estrutura de arame sobreposta; contagens de faces e vértices. | Estilos sem sombreamento, anime, cel shading, retrô, arte voxel e holograma; sombreamento plano ou suave e ajustes de materiais. | Seleção de clipes, navegação pela animação e repetição; esqueletos para arquivos compatíveis que contêm apenas animação. |

**Ajuste a luz.** Sete ambientes, de Glasshouse a Neon, com brilho, direção e rotação automática da luz. **Oriente-se.** Clique em um eixo do gizmo, gire, mova, enquadre o modelo ou ative a grade do chão. Pré-visualizações pequenas do Finder mostram apenas o modelo.

**Nativo para Mac.** Swift, Metal, SwiftUI e AppKit, compartilhados pelo app e pela extensão Quick Look. Os modelos são processados localmente; nenhum dos componentes tem permissão de rede. A interface aceita os dez idiomas listados acima e segue as preferências do macOS. [Notas de localização, em inglês](../LOCALIZATION.md).

<a id="install"></a>

## Primeiros passos

**macOS 26 ou posterior · Apple silicon · compilação a partir do código-fonte**

Você precisa do Xcode completo com o SDK do macOS 26 ou posterior, XcodeGen, CMake e Ninja. O projeto usa uma equipe de desenvolvimento para assinatura e um App Group. Para usar outra equipe, configure sua identidade de assinatura e os identificadores correspondentes antes de compilar, conforme o [guia de assinatura](DEVELOPMENT.md#build-local).

Na cópia local do repositório:

```bash
brew install xcodegen cmake ninja
./scripts/build.sh
```

A primeira compilação baixa e compila a versão fixada do Assimp.

1. Mova `build/Build/Products/Release/Spacebar 3D.app` para **Aplicativos**.
2. **Abra o app uma vez** para registrar a extensão.
3. Ative **Spacebar 3D** em **Ajustes do Sistema → Geral → Itens de Início e Extensões → Quick Look**.
4. Selecione um arquivo compatível no Finder e pressione <kbd>Espaço</kbd>.

Para distribuir o app, siga o [guia de assinatura Developer ID e notarização](DEVELOPMENT.md#distribution-signing--notarization).

<details>
<summary><strong>Usar Spacebar 3D como app padrão</strong></summary>

Nos ajustes do app, clique em **Definir como padrão…**. O macOS pode pedir confirmação; o app informa quais formatos não conseguiu alterar. Isso muda o comportamento do clique duplo no Finder, não a escolha da extensão Quick Look.

</details>

<a id="formats"></a>

## Formatos compatíveis

Avatares, recursos de jogos, exportações CAD, digitalizações e malhas do Blender.

`VRM` · `VRMA` · `glTF` · `GLB` · `FBX` · `OBJ` · `STL` · `3MF` · `PLY` · `USD` · `USDA` · `USDC` · `USDZ` · `3DS` · `BLEND`

<details>
<summary><strong>Suporte e limitações por formato</strong></summary>

| Formato | Suporte |
| :--- | :--- |
| `.vrm` | Avatares VRM 0.x / 1.0: toon shading, contornos e spring bones. |
| `.vrma` | Animação VRM sem malha; o movimento é exibido em um boneco de palitos do esqueleto. |
| `.glb` / `.gltf` | glTF 2.0 com materiais, texturas, skinning e animações. Arquivos `.bin` e imagens externas exigem acesso à pasta. Draco, Meshopt e malhas instanciadas não são suportados. |
| `.fbx` | Binário ou texto; malhas com skinning e animações incorporadas. Imagens dentro do arquivo, ao lado dele ou na pasta `.fbm`. |
| `.obj` | Geometria e cores de vértices; materiais e texturas do `.mtl` após autorizar a pasta. Sem faces, é exibido como nuvem de pontos. |
| `.stl` | STL binário ou em texto. |
| `.3mf` | Cores por objeto ou triângulo, imagens e materiais metálicos e translúcidos. |
| `.ply` | Malhas com cores de vértices ou nuvens de pontos quando não há faces. |
| `.usd` / `.usda` / `.usdc` / `.usdz` | Materiais, texturas incorporadas e animação esquelética. |
| `.3ds` | Cores e transparência dos materiais; texturas externas após autorizar a pasta. |
| `.blend` | Blender 2.80 ou posterior: malhas visíveis e materiais básicos como foram salvos; imagens empacotadas e texturas na pasta autorizada. Modificadores, poses da armadura e animações não são aplicados; redes arbitrárias de nós de shader não são avaliadas. |

FBX contendo apenas animação e VRMA com esqueleto compatível são mostrados como bonecos de palitos. Nenhum modelo ou avatar é incluído no app.

</details>

### Texturas em arquivos separados

Use **Mostrar texturas…**, **Mostrar materiais…** ou **Mostrar modelo…** para autorizar acesso somente de leitura à pasta do modelo e às subpastas. Texturas incorporadas não precisam dessa permissão, mas devem usar formatos de imagem e material compatíveis. No app, um arquivo de material com o mesmo nome, como `ship.mtl` ao lado de `ship.obj`, pode ser lido sem perguntar.

Se o modelo abrir, mas nenhuma das texturas referenciadas puder ser exibida, o visualizador muda da vista **Texturizada** para a vista **Sólida**.

<a id="controls"></a>

## Assuma o controle

| Ação | Controle |
| :--- | :--- |
| Girar | Arrastar ou usar as setas com o foco na área do modelo do app |
| Mover | Arrastar com o botão direito, ou segurando Shift, Option ou Command |
| Mover pelo teclado | Shift + setas na área do modelo, ou o submenu de deslocamento do menu Visualizar |
| Zoom | Rolagem ou gesto de pinça |
| Enquadrar o modelo | Botão de enquadramento ou ⌘0 no app |
| Olhar ao longo de um eixo | Clicar em um eixo do gizmo |
| Reproduzir ou pausar | Botão de reprodução ou Espaço com o foco na área do modelo do app |
| Fechar Quick Look | Espaço |
| Sólido / Texturizado / Normais | ⌘1 / ⌘2 / ⌘3 no app |
| Alternar estrutura de arame | ⌘4 no app |

A barra inferior reúne visualizações, estilos e materiais. À direita ficam gizmo, luz, enquadramento, grade e rotação automática. A barra de animação oferece seleção de clipes e repetição. Os ajustes definem fundo, cor sólida, visualização, brilho, grade, rotação e reprodução. Os menus de visualização e reprodução continuam disponíveis quando os controles da área do modelo estão ocultos.

<a id="help"></a>

## Uma ajuda

Abra o menu **?** na barra de ferramentas do visualizador para consultar os controles, a política de privacidade e os créditos. O menu está disponível no app e no Quick Look.

Encontrou um problema ou tem uma dúvida? No app, escolha **Ajuda → Suporte do Spacebar 3D** ou [abra uma issue](https://github.com/vitalis/Spacebar3D/issues).

<details>
<summary><strong>A pré-visualização não aparece</strong></summary>

Abra o app uma vez e ative a extensão. Se necessário, atualize o cache do Quick Look:

```bash
qlmanage -r && qlmanage -r cache
```

Para OBJ, STL, PLY, USD e USDZ, tente abrir o arquivo diretamente no app.

</details>

<details>
<summary><strong>Preferir Spacebar 3D às pré-visualizações da Apple</strong></summary>

A substituição opcional é reversível:

```bash
scripts/prefer-spacebar3d.sh status
scripts/prefer-spacebar3d.sh on
scripts/prefer-spacebar3d.sh off
```

`on` dá preferência ao Spacebar 3D; `off` restaura as extensões da Apple. O script desativa duas extensões da Apple para sua conta com `pluginkit`, sem alterar arquivos do sistema. MaterialX e Alembic recebem uma pré-visualização mais simples, USDZ perde a visualização AR e `.reality` fica sem pré-visualização. Uma atualização do macOS pode redefinir a escolha. Abrir arquivos no app não exige essa alteração.

</details>

<details>
<summary><strong>Faltam texturas</strong></summary>

Autorize a pasta com **Mostrar texturas…**. Uma permissão concedida apenas no Quick Look precisa ser renovada após reiniciar o Mac. O app lembra suas permissões; abri-lo uma vez após reiniciar as disponibiliza novamente ao Quick Look. Imagens ausentes ou formatos de imagem e material não suportados podem impedir a exibição de uma textura.

</details>

<a id="architecture"></a>

## Por dentro

App e extensão compartilham `Spacebar3DKit`: `ImportRouter` lê o arquivo em um `ModelScene`, e o Metal o desenha. Leitores Swift processam STL, PLY, OBJ, 3MF, glTF, VRM e Blender; Model I/O processa USD; Assimp processa FBX e 3DS.

[Compilação e arquitetura](DEVELOPMENT.md) · [Localização](../LOCALIZATION.md) · [Histórico de alterações](../../CHANGELOG.md) · [Política de privacidade em inglês](../../PRIVACY.md)

<a id="credits"></a>

## Créditos e licença

Spacebar 3D é distribuído sob a [Licença Apache, versão 2.0](../../LICENSE).
Copyright © 2026 Vitaly Gorodetsky.

Consulte [CREDITS.md](../../CREDITS.md) para conhecer as origens do projeto, os colaboradores e os agradecimentos, e as [licenças de terceiros](../../THIRD_PARTY_LICENSES.md) para os componentes com licenças próprias. Esses avisos também estão disponíveis nos agradecimentos do menu Ajuda do app.
