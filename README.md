# MangoCUT

Motor de timeline open source, escrito em TypeScript, que lê, valida, repara e gera projetos no formato
`draft_content.json` / `draft_info.json` usado pelos editores da família CapCut, e reproduz a interpolação
de keyframes (linear e Bézier cúbica em `float32`) desses projetos.

Vem como **biblioteca** (`import ... from "mangocut"`), como **CLI** (`npx mangocut`) e como **app iOS**
distribuído por AltStore/SideStore. O motor não tem dependências em tempo de execução nem imports exclusivos do
Node: o mesmo código roda no Node.js, no navegador e no JavaScriptCore do iOS.

> O MangoCUT é um projeto independente, sem relação com a ByteDance. Veja o [aviso legal](#aviso-legal).

## O que já funciona

- **Modelo de projeto completo em tipos TypeScript**: `PersistentDraft`, `Track`, `Segment`, `TimeRange`,
  `CommonKeyframe`, materiais e flags de erro.
- **Validação** com as mesmas regras do carregador nativo: raiz precisa ser objeto JSON, `TimeRange.duration`
  numérico, `segments` como array, IDs de segmento duplicados.
- **Reparo automático** em três etapas, com máscara de erro compatível:

  | Flag | Etapa | O que corrige |
  | :-- | :-- | :-- |
  | `0x004` | `SegInErrorTrackRepairTask` | Remove clipes cujo material não combina com o tipo da trilha |
  | `0x008` | `SegTimeConflictRepairTask` | Sobreposição de até 99 µs: desloca o clipe para `fim_anterior + 100 µs`. Sobreposição maior: remove o clipe |
  | `0x800` | `DraftDurationRepairTask` | Corrige `duration` do projeto quando um clipe termina depois dela |

- **Tempo em microssegundos** (`int64`), tolerância de busca de keyframe por meio quadro e *snapping* das
  extremidades do segmento (< 1000 µs vai para 0, ≤ 999 µs do fim vai para `duration`).
- **Interpolação de keyframes**: linear em `float64`; Bézier cúbica com coeficientes de Horner em `float32`,
  até 8 iterações de Newton-Raphson e bisseção como fallback; elevação de grau quadrática → cúbica para
  `graph_points`.
- **Leitura de MP4/MOV/M4V sem dependências** (duração, dimensões, rotação, codec), usada para criar projetos
  a partir de um vídeo.
- **Comandos de edição** (`src/editor.ts`): dividir, aparar, mover, excluir, velocidade, filtros, efeitos,
  transições, legendas por IA, templates e textos. A CLI e o app usam os mesmos comandos.
- **Estúdio de Inteligência Artificial no iPhone**:
  - **Legendas Automáticas (IA Speech)**: transcreve a fala do vídeo localmente (offline no dispositivo via Apple Neural Engine) e insere legendas sincronizadas na timeline.
  - **Recorte Automático de Pessoa (IA Vision)**: isola o corpo humano em tempo real sem precisar de tela verde.
  - **Desfoque de Retrato Cinemático (IA Vision)**: mantém a pessoa nítida e desfoca o cenário de fundo com profundidade de campo óptica.
  - **Chroma Key (Tela Verde / Azul)**: remoção de fundo acelerada por GPU (`CIColorCube`) com supressão de bordas.
- **Engine de Shaders e Efeitos Visuais**:
  - **Filtros e LUTs Cinematográficos**: Teal & Orange Hollywoodiano, Cyberpunk / Neon, VHS Anos 90, Noir Drama, P&B, Vintage, Quente, Frio, Vívido e Contraste.
  - **Efeitos de Shaders**: Glitch RGB (aberração cromática), Granulação de película analógica 35mm, Glow / Bloom suave, Vinheta, Desfoque Gaussiano, Estilo Quadrinhos, Zooms e Fades.
  - **Transições Cinematográficas**: Dissolver, Deslizar para Esquerda/Direita, Zoom In e Flash Branco.
- **Templates Criativos de 1 Toque**: TikTok & Reels Dinâmico (9:16), Cinema Blockbuster (16:9), Retrô VHS 90s, Cyberpunk Futurista e Estético & Retrato.
- **Exportação Pro em 4K, 1080p e 720p**:
  - Seleção de Codec por hardware: **HEVC (H.265)** (50% menor tamanho de arquivo com máxima fidelidade) ou **H.264 (AVC)**.
  - Exportação direta para a Fototeca do iOS e compartilhamento rápido.
- **0% Bloatware & Privacidade Total**:
  - Enquanto editores comerciais chegam a 500+ MB com rastreadores, SDKs de anúncios e modelos pesados, o MangoCUT pesa ~1.5 MB porque reaproveita com inteligência os frameworks nativos do iOS (Vision, Speech, AVFoundation, Core Image, Metal). Zero telemetria, zero anúncios.

### Comparativo de Arquitetura: CapCut vs MangoCUT

| Componente | CapCut Comercial (~537 MB) | MangoCUT Open Source (~1.5 MB) |
| :-- | :-- | :-- |
| **Modelos de Redes Neurais** | ByteNN (~180 MB de modelos ONNX/TFLite pesados) | Apple `Vision` + `Speech` nativos (Apple Neural Engine, offline, 0 MB adicionados) |
| **Engine de Shaders** | EffectSDK (~120 MB de shaders e texturas pré-compiladas) | Shaders Metal/Core Image (Teal & Orange, Cyberpunk, Glitch RGB, Bloom, Grain 35mm) |
| **Codecs de Vídeo** | ByteVC1 + FFmpeg estático (~60 MB) | Apple VideoToolbox / AVFoundation (Hardware HEVC H.265 e H.264 até 4K) |
| **Rastreamento e Anúncios** | ~50 MB (AppLovin, Moloco, Google, TikTok, OMSDK) | **0 MB (Zero telemetria, zero anúncios, 100% privado)** |
| **Camada de Scripts** | 210 Lua + 43 JS (~30 MB) | Motor TypeScript/JavaScriptCore ultra-leve (66 KB) |
| **Tamanho do IPA** | **~537 MB** | **~1.5 MB (download instantâneo)** |

### Ainda não faz

- Exportar vídeo pela CLI: o render existe só no app.
- Trilhas extras (sobreposição, música e áudio separado) e animações por keyframe no editor.
- Mostrar no CapCut os filtros, efeitos, transições e textos feitos no MangoCUT. Eles ficam no bloco `mangocut` do
  draft, que só o MangoCUT renderiza. Cortes, ordem e velocidade são compatíveis.
- Curvas de velocidade variável (`curve_speed`) e keyframes discretos de texto (`string_value`).
- Migração de projetos de versões antigas do formato.

## Instalação

Requer Node.js 22.19 ou mais recente.

```bash
npm install mangocut
```

Para usar direto do repositório:

```bash
git clone https://github.com/matheusmeiraa/mangocut.git && cd mangocut
npm install
npm test
```

## CLI

```text
mangocut info <draft.json> [--json]
mangocut validate <draft.json> [--json]
mangocut repair <draft.json> [-o saida.json] [--pretty]
mangocut new --video <video.mp4> [-o draft.json] [--name <nome>] [--fps <n>] [--force] [--pretty]
mangocut run <draft.json> <comando> ['{"param": valor}'] (-o saida.json | --in-place) [--pretty]
mangocut plan <draft.json>
mangocut commands
```

### `new`: criar um projeto a partir de um vídeo

```console
$ npx mangocut new --video praia.mp4 -o draft_content.json
Projeto criado: draft_content.json
Vídeo: praia.mp4 · 720x1280 · avc1 · sem áudio
Duração: 6.033333 s (00:06.033) · 30 fps
```

O canvas recebe as dimensões de exibição do vídeo (vídeos de iPhone gravados em retrato, com matriz de
rotação, saem como retrato). O caminho do vídeo é gravado como absoluto. Sem `--force`, um arquivo existente
não é sobrescrito.

### `info`: duração real, trilhas, clipes e keyframes

```console
$ npx mangocut info projeto.json
Projeto: praia  projeto.json
ID: 757ED2B8-4FB8-49D1-BBC3-A717B97459E2 · versão 360000 (new_version 190.0.0)
Canvas: 720x1280 (original) · 30 fps
Duração real: 9.033283 s (00:09.033)
  (o campo duration declara 6.033333 s (00:06.033))
1 trilha · 2 clipes · 2 keyframes

#1 video — 2 clipes
   [1] 0.000s → 6.033s (6.033s) · fonte 0.000s+6.033s · /Users/voce/Videos/praia.mp4
       keyframes: KFTypeScaleX ×2
   [2] 6.033s → 9.033s (3.000s) · fonte 0.000s+3.000s · /Users/voce/Videos/praia.mp4

Validação: 2 problemas · máscara 0x808 DRAFT_DURATION_ERROR | SEG_TIME_CONFLICT
  ! $.tracks[0].segments[1].target_timerange: [DraftError]draft duration error: 6033333-9033283
  ! $.tracks[0].segments[1].target_timerange: [DraftError] segment[6033283, 9033283] cross in [0, 6033333] (...)
```

A **duração real** é o fim do último clipe da timeline, calculado a partir dos `target_timerange`. Ela é
mostrada junto com o campo `duration` quando os dois não batem. Com `--json`, a saída inclui o resumo completo
(`timelineEndUs`, `timelineEndSeconds`, trilhas, clipes, keyframes e validação).

### `repair`: aplicar o motor de reparo

```console
$ npx mangocut repair projeto.json -o projeto.ok.json
Problemas: máscara 0x808 DRAFT_DURATION_ERROR | SEG_TIME_CONFLICT
  ! SegTimeConflict:C2-5EFC195A-...[6033283,9033283],[0,6033333];
  ! [DraftError]draft duration error: 6033333-9033433
  ✓ Shifted micro-overlapping segment C2 start from 6033283 to 6033433 (prev_end + 100 us)
  ✓ Updated draft.duration from 6033333 to 9033433
Gravado: projeto.ok.json (duração real 9.033433 s (00:09.033))
Validação: OK
```

Sem `-o`, o resultado vai para `<nome>.repaired.json` ao lado do original, que nunca é alterado. Se não houver
nada a reparar, nenhum arquivo é gravado.

### `validate`: para scripts e CI

Sai com `0` (válido), `2` (problemas reparáveis) ou `1` (erro fatal: JSON inválido, raiz que não é objeto,
tipos errados).

### `run` e `plan`: editar pela linha de comando

Os comandos de edição são os mesmos que o app usa. `mangocut commands` lista todos. Tempos em microssegundos:

```bash
npx mangocut run draft_content.json clip.split '{"atUs": 2000000}' --in-place
npx mangocut run draft_content.json clip.filter '{"segmentId": "<id>", "filter": "vintage", "intensity": 0.8}' --in-place
npx mangocut run draft_content.json text.add '{"text": "Olá", "startUs": 500000, "y": 0.2}' --in-place
npx mangocut plan draft_content.json   # clipes na ordem, transições, filtros, efeitos e textos
```

Filtros: `noir`, `vintage`, `warm`, `cool`, `vivid` e `contrast`. Efeitos: `zoomIn`, `zoomOut`, `fadeIn`, `fadeOut` e
`blur`. Transição: `dissolve`.

## Biblioteca

Todos os tempos são **microssegundos inteiros** (1 s = 1.000.000 µs). Use `secondsToMicroseconds` e
`microsecondsToSeconds` para converter.

### Gerar um projeto

```ts
import { writeFileSync } from "node:fs";
import {
  createMinimalDraft,
  addTrack,
  addVideoSegment,
  addKeyframeToSegment,
  secondsToMicroseconds,
} from "mangocut";

const draft = createMinimalDraft({ name: "Meu projeto", width: 1080, height: 1920, fps: 30 });
const track = addTrack(draft, "video");

const clip = addVideoSegment(draft, track, {
  path: "/Users/voce/Videos/praia.mp4",
  startUs: 0,
  durationUs: secondsToMicroseconds(4),
});

// Zoom de 1x para 1.5x ao longo do clipe (time_offset é relativo ao início do clipe)
addKeyframeToSegment(clip, "KFTypeScaleX", { timeOffsetUs: 0, values: [1.0] });
addKeyframeToSegment(clip, "KFTypeScaleX", { timeOffsetUs: secondsToMicroseconds(4), values: [1.5] });

writeFileSync("draft_content.json", JSON.stringify(draft));
```

`addVideoSegment` cria o material de vídeo e o material de velocidade, liga os dois ao clipe e estende
`draft.duration` quando preciso. Projetos novos saem com `version` 360000 / `new_version` "190.0.0" e com os
campos `platform` do app iOS 19.7.0, para que os editores compatíveis os aceitem sem migração.

### Validar

```ts
import { readFileSync } from "node:fs";
import { validateDraftJson, DraftErrorFlags } from "mangocut";

// Aceita a string JSON ou o objeto já parseado
const result = validateDraftJson(readFileSync("draft_content.json", "utf-8"));

result.valid;                  // true
result.fatalExceptionMessage;  // ex.: "json::parse failed: not object issue!"
result.issues;                 // [{ path, code, message, fatal }]

if (result.errorMask & DraftErrorFlags.SEG_TIME_CONFLICT) {
  // há clipes sobrepostos na mesma trilha
}
```

### Reparar

```ts
import { readFileSync, writeFileSync } from "node:fs";
import { repairDraft, getTimelineEndUs, microsecondsToSeconds } from "mangocut";

const draft = JSON.parse(readFileSync("draft_content.json", "utf-8"));
draft.duration = 1_000_000; // simulando um projeto com duração desatualizada

const report = repairDraft(draft); // não altera o objeto original

report.errorMask;   // 0x800
report.fixInfo;     // ["Updated draft.duration from 1000000 to 4000000"]
microsecondsToSeconds(getTimelineEndUs(report.repairedDraft)); // 4

writeFileSync("draft_content.json", JSON.stringify(report.repairedDraft));
```

## Interpolação de keyframes e curvas Bézier

### Avaliar as propriedades de um clipe num instante

```ts
import { evaluateSegmentKeyframes, secondsToMicroseconds } from "mangocut";

// Com o clipe do exemplo de geração acima:
evaluateSegmentKeyframes(clip.common_keyframes, secondsToMicroseconds(2));
// { KFTypeScaleX: [1.25] }
```

### Keyframes com curva

Em `CommonKeyframe`, `right_control` (saída) e `left_control` (entrada) são vetores **relativos** ao keyframe,
com `x` em microssegundos e `y` na unidade da propriedade. Se os dois keyframes são `"Line"` e não há
`graph_points`, a interpolação é linear. Nos outros casos é Bézier cúbica.

```ts
import { interpolateKeyframesAtTime, type CommonKeyframe } from "mangocut";

const kfs: CommonKeyframe[] = [
  {
    id: "a", curveType: "Cubic", time_offset: 0, values: [0],
    left_control: { x: 0, y: 0 }, right_control: { x: 400_000, y: 0 },
    string_value: "", graph: null,
  },
  {
    id: "b", curveType: "Cubic", time_offset: 1_000_000, values: [100],
    left_control: { x: -400_000, y: 0 }, right_control: { x: 0, y: 0 },
    string_value: "", graph: null,
  },
];

interpolateKeyframesAtTime(kfs, 250_000);   // [13.518433570861816]  (ease-in-out)
interpolateKeyframesAtTime(kfs, 500_000);   // [50]
interpolateKeyframesAtTime(kfs, 2_000_000); // [100]  (depois do último keyframe: mantém o valor)
```

Quando a consulta cai dentro da tolerância de um keyframe, o valor dele volta exatamente. A tolerância padrão
é 1000 µs. Com `{ fpsNum, fpsDen }` ela vira meio quadro, e com `{ wideToleranceMode: true }` vira 10 ms.

### Usar o solver Bézier diretamente

`evaluateCubicBezierF32` recebe os quatro pontos da curva e o progresso **já normalizado** `p ∈ [0, 1]`. Toda
a aritmética é feita em `float32` (`Math.fround`), na mesma ordem de operações do motor nativo.

```ts
import { evaluateCubicBezierF32, hornerCoefficientsF32, solveBezierParameterF32 } from "mangocut";

// Curva ease-in-out (0.42, 0, 0.58, 1), como em CSS, a 25% do tempo
evaluateCubicBezierF32(0, 0, 0.42, 0, 0.58, 1, 1, 1, 0.25);
// { y: 0.12889105081558228, t: 0.22480620443820953, path: "newton" }

// Só achar o parâmetro t tal que X(t) = p
solveBezierParameterF32(0.25, hornerCoefficientsF32(0.42, 0.58));
// { t: 0.22480620443820953, path: "newton", iterations: 2 }
```

`path` informa como o resultado foi obtido: `"clamp"` (p fora de (0, 1)), `"newton"`, `"bisection"` ou
`"bisection-exhausted"`.

## App iOS

O app em `ios/` (SwiftUI, iOS 16+) é um editor de vídeo:

- **Projetos:** cria um projeto escolhendo vídeos na Fototeca. Cada projeto fica em
  Arquivos > No meu iPhone > MangoCUT > Projetos, com o `draft_content.json` e a pasta `media/`.
- **Editor:** preview e play/pausa, timeline com régua (arraste para navegar), zoom e desfazer.
- **Clipe selecionado:** dividir, aparar início e fim no ponto da agulha, velocidade de 0,25x a 4x, filtros com
  prévia do próprio clipe, efeitos (zoom de aproximação ou afastamento, surgir e sumir no preto, desfoque),
  transição de dissolver para o próximo clipe, mover e excluir.
- **Textos:** fonte, tamanho, cor, posição, fundo e duração.
- **Exportação:** MP4 em 720p ou 1080p, para salvar na Fototeca ou compartilhar.
- **Inspetor:** abre drafts de outros editores para ver a timeline, validar e reparar.

**Como funciona.** Toda edição é um comando do motor TypeScript. `npm run build:ios-engine` empacota `src/` em
`ios/Generated/mangocut-engine.js`, que o app executa no JavaScriptCore (`MangoEngine.swift`). O motor devolve
um plano de render. A partir dele, `CompositionBuilder` monta a composição do AVFoundation, e o `MangoCompositor`
desenha cada quadro com Core Image: encaixe, zoom, filtro, desfoque, fade, dissolver e textos (CoreText com as
fontes do sistema). O mesmo compositor serve ao player e à exportação, então o que se vê no preview é o que sai
no MP4.

**Screenshots.** Em todo push para `main`, o CI abre o app no simulador do iPhone em modo de demonstração
(`--demo-screen editor`, `filters`, `text`…) e publica as imagens na branch
[`ci-screenshots`](https://github.com/matheusmeiraa/mangocut/tree/ci-screenshots).

Para compilar localmente (precisa de Xcode e [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```bash
npm run build:ios-engine
xcodegen generate --spec ios/project.yml
open ios/MangoCUT.xcodeproj
```

### Distribuição por AltStore / SideStore

O workflow [`.github/workflows/build-ipa.yml`](.github/workflows/build-ipa.yml) roda em todo push e pull request.
Ele faz o typecheck e os testes do motor, compila o `.ipa` sem assinatura num runner macOS e deixa o arquivo
como artefato da execução. O AltStore e o SideStore assinam o app no aparelho com a conta Apple do usuário.

Numa tag `v*`, o workflow também:

1. cria o release da tag com o `MangoCUT.ipa` anexado;
2. gera a fonte a partir de [`community-source/apps.json`](community-source/apps.json) com
   [`scripts/update-source.mjs`](scripts/update-source.mjs), apontando as URLs para o repositório que rodou o workflow,
   colocando o tamanho real do `.ipa` e mantendo as versões já publicadas;
3. publica `apps.json` e `icon.png` no GitHub Pages.

Configuração única no repositório do GitHub:

1. **Settings → Pages → Source**: escolha "GitHub Actions".
2. **Settings → Environments → github-pages → Deployment branches and tags**: adicione a regra de tag `v*`.
   Sem ela, o GitHub bloqueia o deploy feito a partir de uma tag.
3. Publique uma versão:

   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

Depois disso a fonte fica em `https://<seu-usuario>.github.io/<repositorio>/apps.json`. A fonte oficial deste
repositório é `https://matheusmeiraa.github.io/mangocut/apps.json`.

Para usar, adicione essa URL em **Sources** no [SideStore](https://sidestore.io) ou no AltStore Classic
(instalado pelo AltServer). Esses dois assinam o app com o seu Apple ID.

A versão marketplace do AltStore (AltStore PAL, instalada pelo navegador) **não funciona**: ela só aceita apps
notarizados pela Apple e recusa a fonte com o aviso *"missing a marketplaceID"*. Notarizar exige uma conta paga
de desenvolvedor e o cadastro na distribuição alternativa da Apple.

## Desenvolvimento

```bash
npm install               # instala as ferramentas e gera dist/
npm test                  # roda os testes direto dos .ts (type stripping do Node)
npm run typecheck         # tsc em src/ e tests/
npm run build             # gera dist/ (JavaScript + .d.ts), que é o que vai para o npm
npm run build:ios-engine  # empacota o motor para o app iOS
```

Dentro do repositório, `bin/mangocut.js` roda direto de `src/`. Instalado pelo npm, usa `dist/`.

O teste "Fase 1" valida templates reais de projeto e só roda se houver uma cópia local do bundle do app em
`app/`. Essa pasta nunca é versionada (`.gitignore`), e sem ela o teste é pulado.

Antes de contribuir, leia o [`AGENTS.md`](AGENTS.md). Ele traz as regras clean-room deste projeto: o CapCut e
outros editores só são estudados pelo comportamento e pela aparência, e nenhum código ou asset de outro produto
entra no repositório.

## Aviso legal

MangoCUT não é afiliado, patrocinado nem endossado pela ByteDance Ltd. "CapCut" é marca de seu respectivo
titular e aparece aqui apenas para indicar compatibilidade com o formato de arquivo de projeto.

Este repositório não contém código, binários nem assets do CapCut. O MangoCUT é uma implementação
independente, feita para interoperar com arquivos de projeto que pertencem aos próprios usuários.

## Licença

[MIT](LICENSE)
