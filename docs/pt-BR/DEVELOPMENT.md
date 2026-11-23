# Desenvolver o Spacebar 3D

[English](../DEVELOPMENT.md) | [简体中文](../zh-Hans/DEVELOPMENT.md) | [Español](../es/DEVELOPMENT.md) | [Français](../fr/DEVELOPMENT.md) | [Deutsch](../de/DEVELOPMENT.md) | [日本語](../ja/DEVELOPMENT.md) | **Português (Brasil)** | [한국어](../ko/DEVELOPMENT.md) | [Italiano](../it/DEVELOPMENT.md) | [Русский](../ru/DEVELOPMENT.md)

Compile, teste e depure o app nativo para macOS e sua extensão Quick Look. Consulte os recursos e as limitações dos formatos no [README](README.md).

[Requisitos](#requirements) · [Compilação](#build-local) · [Testes](#tests) · [Arquitetura](#how-it-works) · [Solução de problemas](#troubleshooting) · [Distribuição](#distribution-signing--notarization)

Execute os comandos na raiz do repositório, salvo indicação em contrário.

<a id="requirements"></a>

## Requisitos

| Requisito | Observações |
| :--- | :--- |
| Mac com Apple silicon e macOS 26 ou posterior | O projeto e o Assimp compilam para `arm64`; nenhuma variante Intel é gerada. |
| Xcode completo com SDK do macOS 26 ou posterior | Apenas as Command Line Tools não bastam. O ambiente local atual usa Xcode 27.0. |
| XcodeGen | Gera o projeto Xcode a partir de `project.yml`. |
| CMake e Ninja | Compilam a dependência nativa Assimp. |
| Python 3 | Executa a verificação de consistência das traduções. |
| Identidade de assinatura de desenvolvimento | Necessária para o app instalado, a extensão e o App Group compartilhado. Veja abaixo. |

```bash
brew install xcodegen cmake ninja
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

Se o shell selecionar as Command Line Tools ou outra instalação do Xcode, selecione o Xcode completo antes de compilar:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`build.sh` também detecta essa instalação padrão quando `xcode-select` aponta para as Command Line Tools. Chamadas diretas de `xcodebuild` e comandos de compilação das dependências precisam estar com o diretório de desenvolvimento correto.

<a id="build-local"></a>

## Compilação local

<a id="configure-signing"></a>

### Configurar a assinatura

A configuração do repositório usa a equipe definida em [`project.yml`](../../project.yml). Para usar sua equipe:

1. Defina `DEVELOPMENT_TEAM` e identificadores de bundle adequados em `project.yml`.
2. Configure um App Group para a equipe. Use o mesmo identificador em [`Spacebar3D.entitlements`](../../Spacebar3D/App/Spacebar3D.entitlements), [`Spacebar3DExtension.entitlements`](../../Spacebar3D/Extension/Spacebar3DExtension.entitlements) e `ViewerSettings.appGroup` em [`ViewerSettings.swift`](../../Spacebar3D/Shared/ViewerSettings.swift).
3. Confirme que o Xcode pode usar o certificado Apple Development da equipe e os recursos de provisionamento necessários. Gere o projeto novamente após mudar a configuração.

O App Group atual é `V3AQWQ8JMY.com.vitalis.Spacebar3D`. Alterar apenas a equipe no comando de compilação não atualiza esse identificador. Builds sem assinatura ou com assinatura ad hoc não substituem os testes de registro da extensão e acesso ao contêiner compartilhado.

<a id="build-the-app"></a>

### Compilar o app

```bash
./scripts/build.sh
```

O script compila o Assimp se o framework estiver ausente, executa o XcodeGen e compila o esquema `Spacebar3D` na configuração Release. Saída:

```text
build/Build/Products/Release/Spacebar 3D.app
```

A primeira compilação precisa de rede para obter as dependências. [`build-assimp.sh`](../../scripts/build-assimp.sh) fixa o Assimp em `v6.0.6` e verifica o SHA completo do commit `a79ff6bbce54d3e01186a918dc6374ed55317426` antes de compilar. Ele gera um XCFramework estático arm64 com importadores FBX e 3DS, sem exportadores nem Draco.

Execute o script novamente quando a revisão fixada mudar. `build.sh` verifica se o framework existe, não se corresponde à revisão. Para usar um checkout local no commit exigido:

```bash
ASSIMP_SRC=/path/to/assimp ./scripts/build-assimp.sh
```

<a id="register-and-exercise-quick-look"></a>

### Registrar e testar o Quick Look

1. Copie o app compilado para `/Applications` e abra essa cópia uma vez.
2. Ative **Spacebar 3D** em **Ajustes do Sistema → Geral → Itens de Início e Extensões → Quick Look**.
3. Selecione um arquivo compatível no Finder e pressione Espaço.
4. Abra o mesmo arquivo em **Arquivo → Abrir…** no app para verificar os dois ambientes.

Se o registro estiver desatualizado, atualize o cache e teste um arquivo GLB:

```bash
qlmanage -r
qlmanage -r cache
qlmanage -p /path/to/model.glb
```

O macOS pode escolher a prévia da Apple para OBJ, STL, PLY, USD e USDZ. Isso não comprova uma falha da extensão. Use o app ou a substituição opcional descrita no [README](README.md#help).

<a id="development"></a>

## Desenvolvimento

Para editar e depurar no Xcode:

```bash
./scripts/build-assimp.sh
xcodegen generate
open Spacebar3D.xcodeproj
```

Compile o Assimp uma vez por revisão da dependência e gere o projeto novamente quando `project.yml` mudar. O Git ignora `.xcodeproj`, os dois `Info.plist` gerados, os resultados da compilação e `Vendor/Assimp.xcframework`. Edite o YAML, não o projeto ou as listas de propriedades geradas.

Para uma compilação Debug incremental no terminal:

```bash
xcodebuild -project Spacebar3D.xcodeproj -scheme Spacebar3D \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build build
```

`SKIP_XCODEGEN=1 ./scripts/build.sh` reutiliza o projeto gerado existente e continua compilando em Release. Use apenas quando o projeto corresponder ao YAML.

<a id="capture-media"></a>

### Gravar um vídeo de prévia e fazer capturas de tela

Execute o script em uma sessão gráfica do macOS e siga os requisitos de compilação acima. Nos Ajustes do Sistema, conceda permissão de gravação de tela ao app usado para executar o script.

Se o modelo fizer referência a texturas, materiais ou geometria externos, abra-o primeiro no app normal do Spacebar 3D. Use o botão de pasta no visualizador para conceder acesso à pasta que contém esses arquivos. A versão de captura usa a permissão salva. Abrir apenas o arquivo do modelo pode deixar os arquivos associados inacessíveis.

```bash
brew install ffmpeg
./scripts/capture-media.sh /path/to/model.glb
```

O script compila e abre uma cópia separada do Spacebar 3D com a captura ativada. Para reutilizar uma cópia já compilada com essa opção, defina `SPACEBAR3D_APP` com o caminho do pacote `.app`. Por padrão, o script cria uma pasta em `build/media-captures/`. Passe um caminho ainda livre como segundo argumento para escolher a pasta de saída.

O vídeo público de prévia da Mac App Store, `preview.mp4`, dura 30 segundos e mostra todos os estilos de renderização disponíveis para o modelo. O vídeo tem resolução de 1920 × 1080 a 30 fps. O script também salva quatro arquivos PNG de 2560 × 1600 e `demo.gif`. Em modelos com pelo menos três estilos, o GIF usa a mesma edição de 15 segundos do vídeo em loop dos estilos. Com menos estilos, usa a prévia na velocidade original. A primeira captura usa a visualização Texturizada quando disponível (`01-textured.png`) ou a visualização Sólida nos demais casos (`01-solid.png`). As outras imagens são `02-wireframe.png`, `03-normals.png` e `04-hologram.png`.

<a id="capture-feature-loop"></a>

### Gravar um vídeo em loop dos estilos

Use a mesma configuração de captura para criar um loop de 15 segundos a 30 fps. O modelo precisa oferecer pelo menos três estilos de renderização. O script dá preferência a Cel shading, Arte voxel e Holograma.

```bash
./scripts/capture-feature-loop.sh /path/to/model.glb
```

Por padrão, o script salva `feature-loop.mp4` em uma pasta nova dentro de `build/media-captures/`. Passe um caminho ainda livre como segundo argumento para escolher a pasta de saída.

<a id="capture-screenshots"></a>

### Fazer capturas de tela para a App Store

Use a mesma configuração de captura para gerar os quatro arquivos PNG em sRGB de 2560 × 1600 listados acima.

```bash
./scripts/capture-screenshots.sh /path/to/model.glb
```

Por padrão, o script salva os arquivos em uma pasta nova dentro de `build/media-captures/`. Passe um caminho ainda livre como segundo argumento para escolher a pasta de saída.

<a id="capture-app-review"></a>

### Gravar uma demonstração privada para o App Review

Instale e abra o app normal do Spacebar 3D e ative sua extensão do Quick Look. Escolha um modelo que abra de forma interativa no Quick Look do Finder. Antes da gravação, feche a prévia do Quick Look no Finder e as janelas do visualizador independente com o mesmo nome de arquivo. Use a permissão de gravação de tela indicada acima, as ferramentas de linha de comando do Swift e o FFmpeg com os filtros `drawtext` e `subtitles`. Mantenha o terminal visível e siga suas instruções. Mantenha o arquivo selecionado no Finder e mude para a visualização em lista se necessário. Quando solicitado, pressione a barra de espaço e gire o modelo ou ajuste o zoom duas vezes. Quando solicitado, clique no botão para abrir no Spacebar 3D. Se o macOS abrir um menu de apps, escolha o Spacebar 3D. Se o botão não estiver disponível, feche o Quick Look e abra o mesmo arquivo em **Arquivo → Abrir…** no Spacebar 3D. Gire o modelo ou ajuste o zoom duas vezes no visualizador independente.

```bash
SPACEBAR3D_REVIEW_ANIMATION_MODEL=docs/app-store/Spacebar3D-Review-Model.glb \
  ./scripts/capture-app-review.sh /path/to/model.fbx build/media-captures/app-review
```

O script adiciona legendas e salva `app-review.mp4` em uma pasta nova dentro de `build/media-captures/`. Para escolher a pasta de saída, passe um caminho ainda livre como segundo argumento. Defina `SPACEBAR3D_REVIEW_APP` se o app estiver instalado em um caminho diferente de `/Applications/Spacebar 3D.app`.

Após a gravação guiada, o script grava capítulos sobre os controles do visualizador, ajustes, ajuda e privacidade. O exemplo adiciona a reprodução com o modelo animado de amostra. Defina `SPACEBAR3D_REVIEW_CAPTURE_APP` para reutilizar um app já compilado para captura. Por padrão, o script o compila com a configuração de desenvolvimento descrita acima.

Se você já tiver uma gravação das etapas guiadas no Finder e no visualizador, `capture-review-features.sh` pode adicionar os capítulos. Consulte `--help`.

<a id="tests"></a>

## Testes

Compile o Assimp antes de resolver o pacote ou executar qualquer uma das duas opções de teste.

<a id="full-xcode-suite"></a>

### Suíte completa do Xcode

Este é o comando principal de regressão. Inclui testes dos fontes do app, do código compartilhado e da extensão, além dos nove targets de teste do pacote declarados em `project.yml`.

```bash
xcodegen generate
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build
python3 scripts/check-localizations.py
```

Para uma execução específica, acrescente um seletor `-only-testing`, por exemplo:

```bash
xcodebuild test -project Spacebar3D.xcodeproj -scheme Spacebar3DTests \
  -destination 'platform=macOS' -derivedDataPath build \
  -only-testing:ViewerUITests/NativeViewerInputTests
```

O Xcode grava os bundles `.xcresult` em `build/Logs/Test/`.

<a id="package-only-tests"></a>

### Testes apenas do pacote

Eles não incluem os testes dos fontes dos hosts em `Spacebar3DTests`:

```bash
xcrun swift test --package-path Packages/Spacebar3DKit
```

Dois testes de modelos grandes são habilitados com `P3D_LARGE=1`. Um deles cria um arquivo STL de teste de cerca de 100 MB. Para executar esse benchmark explicitamente:

```bash
P3D_LARGE=1 xcrun swift test --package-path Packages/Spacebar3DKit \
  --filter LargeModelTests
```

<a id="what-the-tests-establish"></a>

### O que os testes verificam

- Os testes de ajustes usam armazenamento temporário explícito. Adicione casos de normalização a [`settings-vectors.json`](../../testdata/settings-vectors.json) quando as regras mudarem.
- Os testes de importadores criam arquivos pequenos e verificam entradas malformadas e truncadas.
- Os testes de renderização desenham fora da tela e inspecionam pixels; precisam de um dispositivo Metal funcional.
- Os testes do visualizador cobrem entrada nativa, metadados de acessibilidade, comandos, layout e controles SwiftUI, incluindo verificações com ViewInspector.
- As verificações de localização validam cobertura das chaves, entradas do catálogo e marcadores de posição. Os testes do pacote também verificam os recursos de idioma compilados.

O esquema do Xcode compila os fontes dos hosts em um bundle de teste. Ele não abre o app assinado dentro de sua sandbox de produção. Passar nos testes não comprova registro do Quick Look, permissões de pastas, fala do VoiceOver ou comportamento de um download notarizado. Para essas mudanças, teste também o app assinado instalado e a extensão do Finder.

<a id="how-it-works"></a>

## Funcionamento

```text
Finder → Quick Look extension ─┐
                              ├─ ViewerFactory → NativeViewer
App → model window ───────────┘                      │
                                     ImportRouter → ModelScene
                                                     │
                                           RenderMetal / MTKView
                                           + SwiftUI controls
```

Os dois hosts compartilham o pacote local `Spacebar3DKit`. A importação ocorre fora da thread principal; o visualizador nativo coordena a renderização e os controles.

| Área | Responsabilidade |
| :--- | :--- |
| `Spacebar3D/App/` | Configuração, ajustes, janelas de modelos, registro como app padrão, menus, ajuda e créditos. |
| `Spacebar3D/Extension/` | Ciclo de vida da prévia do Quick Look. |
| `Spacebar3D/Shared/` | Criação do visualizador e ajustes compartilhados. |
| `Packages/Spacebar3DKit/Sources/ModelCore/` | Dados de cena, detecção de formato, animação, topologia e localização. |
| `…/Sources/ImportRouter/` e `…/Sources/Import*/` | Seleção de formatos e leitores. |
| `…/Sources/RenderMetal/` | Cena GPU, câmera, sombreamento e renderização. |
| `…/Sources/ViewerUI/` | API do visualizador, entrada nativa, controles SwiftUI e autorizações de pastas. |
| `…/Sources/CZstd/` | Decodificador Zstandard incluído para arquivos Blender compactados. |
| `Spacebar3DTests/` e `Packages/Spacebar3DKit/Tests/` | Testes dos fontes dos hosts e do pacote. |
| `docs/<language-code>/README.md` | Os nove READMEs traduzidos. |
| `docs/<language-code>/DEVELOPMENT.md` | Os nove guias de desenvolvimento traduzidos. |

Leitores nativos em Swift processam STL, PLY, OBJ, 3MF, glTF/GLB, VRM/VRMA e Blender. Model I/O processa USD; Assimp processa FBX e 3DS. `FormatDetector` examina os primeiros bytes e, em formatos de texto ambíguos, a extensão. Os tipos de documento e `QLSupportedContentTypes` são declarados em `project.yml`.

Arquivos que contêm apenas animação e têm um esqueleto compatível podem usar uma prévia esquemática do esqueleto. Nenhum avatar padrão é incluído. O suporte a formatos é intencionalmente mais restrito que o de um aplicativo DCC completo. Mantenha as limitações do README corretas ao alterar os leitores.

<a id="implementation-notes"></a>

## Notas de implementação

<a id="sandbox-and-related-files"></a>

### Sandbox e arquivos relacionados

Os dois targets usam App Sandbox e acesso somente de leitura a arquivos selecionados pelo usuário. Nenhum tem permissão de rede ou exceção temporária à sandbox.

Abrir um modelo não concede acesso irrestrito aos arquivos vizinhos. Os dois hosts podem oferecer **Mostrar modelo…**, **Mostrar materiais…** ou **Mostrar texturas…** para solicitar acesso à pasta. O app também aceita determinados arquivos de materiais associados com o mesmo nome, como `ship.mtl` ao lado de `ship.obj`, por meio do tratamento de arquivos relacionados.

[`FolderGrants.swift`](../../Packages/Spacebar3DKit/Sources/ViewerUI/FolderGrants.swift) guarda autorizações do app como bookmarks com escopo de segurança. O Quick Look mantém seus próprios bookmarks comuns e lê cópias atualizadas pelo app no contêiner compartilhado. Uma autorização exclusiva do Quick Look precisa ser renovada após reiniciar o Mac. Abrir o app atualiza as autorizações memorizadas para a extensão. A leitura fica restrita às pastas autorizadas e seus descendentes.

<a id="settings"></a>

### Ajustes

`ViewerSettings` armazena `viewer-settings.json` no contêiner App Group. O app grava o arquivo; novos visualizadores carregam os valores normalizados. Ajustes inválidos, grandes demais ou ausentes usam os padrões. Não há migração do local antigo fora do contêiner, `~/Library/Application Support/Spacebar3D/`.

<a id="input-and-accessibility"></a>

### Entrada e acessibilidade

As setas orbitam e Shift-setas deslocam a câmera somente quando a área do modelo no app independente trata o teclado. Espaço reproduz ou pausa ali; não é um atalho global de menu e não deve interceptar a ativação de botões ou controles deslizantes com foco. O Quick Look mantém Espaço para fechar. Menus e ações de acessibilidade oferecem alternativas aos gestos do ponteiro.

Ao alterar controles, verifique foco, janelas estreitas, traduções longas, Aumentar Contraste e Reduzir Transparência. Ouça os anúncios reais do VoiceOver separadamente das verificações da árvore de acessibilidade.

<a id="localization-and-documentation"></a>

### Localização e documentação

O catálogo compartilhado `Packages/Spacebar3DKit/Sources/ModelCore/Resources/Localizable.xcstrings` atende ao app e à extensão em dez idiomas. Siga [LOCALIZATION.md](../LOCALIZATION.md) para strings completas, marcadores de posição, recursos compilados e verificações de layout.

O README em inglês fica na raiz; as traduções estão em `docs/<language-code>/`. Os guias de desenvolvimento ficam nessas mesmas pastas, com a fonte em inglês em `docs/DEVELOPMENT.md`. Mantenha limites de formatos, controles, instalação, permissões e procedimentos de desenvolvimento alinhados entre as versões.

<a id="troubleshooting"></a>

## Solução de problemas

| Sintoma | Verificação |
| :--- | :--- |
| Falta Assimp na resolução do pacote | Execute `./scripts/build-assimp.sh` com Xcode completo, CMake e Ninja disponíveis. |
| A assinatura falha ou os ajustes compartilhados estão indisponíveis | Confira certificado, equipe, identificadores de bundle e App Group. Uma variável de ambiente sozinha não reescreve entitlements. |
| As edições desaparecem após a geração | Altere `project.yml`, não os arquivos `.xcodeproj` ou `Info.plist` gerados. |
| A extensão não aparece ou carrega uma versão antiga | Abra a cópia instalada correta, habilite a extensão, confira o registro e atualize o Quick Look. Não confunda cópias instaladas com as da pasta de compilação. |
| O visualizador da Apple abre | Veja os limites acima e compare com Arquivo → Abrir no app. |
| Faltam texturas ou geometria | Leia o aviso, autorize a pasta e confira os limites do formato e os arquivos associados. |
| Um teste GPU falha | Confira se Metal está disponível e investigue o erro. Uma GPU indisponível não equivale a um teste de renderização aprovado. |

Inspecione o registro da extensão e acompanhe seus logs:

```bash
pluginkit -m | rg -i spacebar3d
log stream --predicate 'process == "Spacebar3DExtension"'
```

O primeiro comando usa `rg` do ripgrep; `grep -i spacebar3d` é uma alternativa. Em outro terminal, execute `qlmanage -p /path/to/model.glb`. Um modelo rejeitado deve exibir um erro na prévia. Confira se o problema está na importação, renderização, acesso ou seleção da extensão antes de alterar assinatura ou permissões.

<a id="distribution-signing--notarization"></a>

## Distribuição, assinatura e notarização

Os scripts implementam a **distribuição direta com Developer ID por DMG**. Eles não arquivam, exportam nem enviam uma build para a Mac App Store. A loja exige um fluxo separado de assinatura, arquivamento, exportação e envio ao App Store Connect.

Para distribuição direta, use uma identidade Developer ID Application e notarização. O [guia da Apple](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) explica os requisitos de assinatura e do serviço. Os preços de associação não são reproduzidos aqui.

<a id="manual"></a>

### Processo manual

Após configurar identificadores de equipe e App Group correspondentes:

```bash
SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ./scripts/build.sh
```

Com `SIGN_IDENTITY`, o script seleciona assinatura manual, passa `DEVELOPMENT_TEAM`, adiciona um carimbo de tempo seguro e desativa a inclusão de entitlements básicos de depuração. Hardened Runtime está habilitado em `project.yml`. Sem `SIGN_IDENTITY`, usa a configuração de assinatura de desenvolvimento do projeto.

Para notarização local, prefira um perfil das Chaves. Armazene as credenciais interativamente com `notarytool` e use o nome do perfil:

```bash
xcrun notarytool store-credentials "spacebar3d-notary"
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" ./scripts/notarize.sh
```

O script aceita um caminho opcional para o app:

```bash
NOTARY_KEYCHAIN_PROFILE="spacebar3d-notary" \
  ./scripts/notarize.sh "/path/to/Spacebar 3D.app"
```

A autenticação é selecionada nesta ordem:

| Método | Variáveis |
| :--- | :--- |
| Perfil das Chaves | `NOTARY_KEYCHAIN_PROFILE` |
| Chave API do App Store Connect | `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER` |
| Credenciais da Conta Apple | `APPLE_TEAM_ID`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` |

O último método passa uma senha específica de app como argumento de `notarytool`; o perfil das Chaves evita isso em uma máquina compartilhada. Mantenha chaves de assinatura e credenciais fora do repositório.

`notarize.sh` verifica a assinatura Developer ID do app e cria um DMG com um atalho para Applications. Assina o DMG com a identidade lida na assinatura do app ou com `SIGN_IDENTITY`, quando definida. O certificado e a chave privada precisam estar disponíveis no chaveiro. O script envia o DMG à Apple, aguarda a aprovação, anexa e valida o ticket e verifica o Gatekeeper com `spctl`. Quando todas as verificações passam, grava `Spacebar3D.dmg` na raiz do repositório. Teste o arquivo baixado antes de compartilhá-lo.

<a id="automated-github-actions"></a>

### Automação com GitHub Actions

[O workflow de lançamento](../../.github/workflows/release.yml) usa o runner Apple silicon `macos-26` com Xcode 26. Envie ou selecione uma tag no formato `vMAJOR.MINOR.PATCH` que corresponda a `MARKETING_VERSION` e aponte para um commit de `origin/main`.

O workflow gera o projeto e executa `Spacebar3DTests` e a verificação de localização antes de importar o certificado de assinatura. Compila com Developer ID, compara as versões do app e da extensão com a tag e então assina e notariza o DMG. Exclui o chaveiro temporário antes de anexar o DMG a uma GitHub Release.

Configure estes secrets no **repositório de destino real**:

| Secret | Conteúdo |
| :--- | :--- |
| `MACOS_CERTIFICATE` | Certificado Developer ID Application e chave privada exportados como `.p12`, codificados em Base64. |
| `MACOS_CERTIFICATE_PWD` | Senha desse `.p12`. |
| `KEYCHAIN_PASSWORD` | Senha das chaves temporárias de compilação. |
| `APPLE_TEAM_ID` | Identificador da equipe de assinatura. |
| `NOTARY_APPLE_ID` | Conta Apple usada na notarização. |
| `NOTARY_PASSWORD` | Sua senha específica de app. |

Informe o repositório explicitamente, por exemplo com `gh secret set APPLE_TEAM_ID --repo OWNER/REPOSITORY`, que solicita o valor. Não presuma que `origin` aponta para um repositório existente ou para o destino pretendido do lançamento.

Antes de criar a tag de lançamento, defina `MARKETING_VERSION` e `CURRENT_PROJECT_VERSION` em `project.yml`, atualize o histórico de alterações, execute os testes e verifique a build assinada. Enviar a tag correspondente pode publicar uma GitHub Release se o workflow for concluído com sucesso.

<a id="references"></a>

## Referências

- [Arquitetura do renderizador nativo](../architecture/native-rewrite.md)
- [Design do visualizador](../design/neon-garden-viewer.md)
- [Localização](../LOCALIZATION.md)
- [Licenças de terceiros](../../THIRD_PARTY_LICENSES.md)
- [Apple: personalizar a notarização](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [magicien/VRMQuickLook](https://github.com/magicien/VRMQuickLook), implementação VRM 0.x com SceneKit
- [magicien/GLTFQuickLook](https://github.com/magicien/GLTFQuickLook), referência de estrutura Quick Look
- [pixiv/three-vrm](https://github.com/pixiv/three-vrm), referência de comportamento VRM
