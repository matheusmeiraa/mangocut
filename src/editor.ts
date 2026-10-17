import { addTrack, addVideoSegment, createMinimalDraft, getTimelineEndUs } from "./draft.ts";
import type {
  ClipFilter,
  ClipStyle,
  CommonKeyframeList,
  EffectId,
  FilterId,
  MangoCutExtension,
  Microseconds,
  PersistentDraft,
  Segment,
  TextFont,
  TextOverlay,
  Track,
  Transition,
} from "./types.ts";

/*
 * Comandos de edição do MangoCUT e o plano de render que o app usa para tocar e exportar.
 *
 * Cortes, ordem e velocidade ficam nas trilhas e segmentos padrão do draft. Filtros, efeitos,
 * transições e textos ficam no bloco `mangocut`. Toda edição passa por `runEditorCommand`, que
 * a CLI (`mangocut run`) e o app iOS chamam do mesmo jeito.
 */

export const FILTER_IDS: readonly FilterId[] = ["noir", "vintage", "warm", "cool", "vivid", "contrast"];
export const EFFECT_IDS: readonly EffectId[] = ["zoomIn", "zoomOut", "fadeIn", "fadeOut", "blur"];
export const TEXT_FONTS: readonly TextFont[] = ["system", "rounded", "serif", "mono"];

/** Menor duração de clipe que um corte pode deixar (0,1 s). */
export const MIN_CLIP_US: Microseconds = 100_000;
export const DEFAULT_TRANSITION_US: Microseconds = 500_000;
export const DEFAULT_TEXT_US: Microseconds = 3_000_000;
const MIN_TRANSITION_US: Microseconds = 33_000;
const MIN_SPEED = 0.25;
const MAX_SPEED = 4;

export interface RenderClip {
  segmentId: string;
  materialId: string;
  /** Caminho do arquivo como está no draft (absoluto ou relativo à pasta do projeto). */
  path: string;
  name: string;
  sourceStartUs: Microseconds;
  sourceDurationUs: Microseconds;
  speed: number;
  volume: number;
  /** Início no tempo da timeline. Transições fazem o clipe começar antes do fim do anterior. */
  timelineStartUs: Microseconds;
  timelineDurationUs: Microseconds;
  filter: ClipFilter | null;
  effects: EffectId[];
  transitionIn: Transition | null;
  transitionOut: Transition | null;
}

export interface RenderPlan {
  canvas: { width: number; height: number };
  fps: number;
  durationUs: Microseconds;
  clips: RenderClip[];
  texts: TextOverlay[];
  warnings: string[];
}

export class EditorError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EditorError";
  }
}

type Params = Record<string, unknown>;

function newId(): string {
  return globalThis.crypto.randomUUID().toUpperCase();
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function basename(path: string): string {
  return path.split(/[\\/]/).pop() ?? path;
}

// ---------------------------------------------------------------------------
// Bloco `mangocut` e trilha principal

function readExtension(draft: PersistentDraft): MangoCutExtension {
  const raw: unknown = draft.mangocut;
  const ext: MangoCutExtension = { version: 1, clipStyles: {}, transitions: {}, texts: [] };
  if (!isObject(raw)) return ext;
  if (isObject(raw.clipStyles)) ext.clipStyles = raw.clipStyles as Record<string, ClipStyle>;
  if (isObject(raw.transitions)) ext.transitions = raw.transitions as Record<string, Transition>;
  if (Array.isArray(raw.texts)) ext.texts = raw.texts as TextOverlay[];
  return ext;
}

/** Igual a `readExtension`, mas grava o bloco no draft para ser alterado. */
function extensionOf(draft: PersistentDraft): MangoCutExtension {
  const ext = readExtension(draft);
  draft.mangocut = ext;
  return ext;
}

function styleOf(ext: MangoCutExtension, segmentId: string): ClipStyle {
  const style = ext.clipStyles[segmentId];
  return {
    filter: style?.filter ?? null,
    effects: Array.isArray(style?.effects) ? [...style.effects] : [],
  };
}

/** A trilha principal é a primeira trilha de vídeo. */
function findMainTrack(draft: PersistentDraft): Track | undefined {
  return (Array.isArray(draft.tracks) ? draft.tracks : []).find(
    (t) => t.type === "video" && Array.isArray(t.segments),
  );
}

function requireMainTrack(draft: PersistentDraft): Track {
  const existing = findMainTrack(draft);
  if (existing) return existing;
  if (!Array.isArray(draft.tracks)) draft.tracks = [];
  return addTrack(draft, "video");
}

function orderedSegments(track: Track): Segment[] {
  return track.segments
    .filter((s) => s.target_timerange && typeof s.target_timerange.duration === "number")
    .sort((a, b) => (a.target_timerange.start ?? 0) - (b.target_timerange.start ?? 0));
}

function trackEnd(track: Track): Microseconds {
  return orderedSegments(track).reduce(
    (end, s) => Math.max(end, (s.target_timerange.start ?? 0) + s.target_timerange.duration),
    0,
  );
}

/** Encosta os clipes da trilha principal um no outro a partir de 0, na ordem atual. */
function packTrack(draft: PersistentDraft, track: Track, order = orderedSegments(track)): void {
  let start = 0;
  for (const segment of order) {
    segment.target_timerange.start = start;
    start += segment.target_timerange.duration;
  }
  const untimed = track.segments.filter((s) => !order.includes(s));
  track.segments = [...order, ...untimed];
  draft.duration = getTimelineEndUs(draft);
}

function speedOf(segment: Segment): number {
  return typeof segment.speed === "number" && segment.speed > 0 ? segment.speed : 1;
}

function sourceRangeOf(segment: Segment): { start: Microseconds; duration: Microseconds } {
  return {
    start: segment.source_timerange?.start ?? 0,
    duration:
      segment.source_timerange?.duration ?? Math.trunc(segment.target_timerange.duration * speedOf(segment)),
  };
}

function mapKeyframes(
  segment: Segment,
  map: (offset: Microseconds) => Microseconds | null,
  freshIds = false,
): CommonKeyframeList[] {
  if (!Array.isArray(segment.common_keyframes)) return [];
  return segment.common_keyframes
    .map((list) => ({
      ...list,
      id: freshIds ? newId() : list.id,
      keyframe_list: (Array.isArray(list.keyframe_list) ? list.keyframe_list : []).flatMap((kf) => {
        const offset = map(kf.time_offset);
        return offset === null ? [] : [{ ...kf, id: freshIds ? newId() : kf.id, time_offset: offset }];
      }),
    }))
    .filter((list) => list.keyframe_list.length > 0);
}

/** Dá ao segmento cópias próprias dos materiais de velocidade, para não compartilhar com outro clipe. */
function cloneSpeedMaterials(draft: PersistentDraft, segment: Segment): void {
  const speeds = draft.materials?.speeds;
  if (!Array.isArray(speeds) || !Array.isArray(segment.extra_material_refs)) return;
  segment.extra_material_refs = segment.extra_material_refs.map((ref) => {
    const material = speeds.find((m) => m.id === ref);
    if (!material) return ref;
    const copy = { ...structuredClone(material), id: newId() };
    speeds.push(copy);
    return copy.id;
  });
}

function setSpeedMaterials(draft: PersistentDraft, segment: Segment, speed: number): void {
  const speeds = draft.materials?.speeds;
  if (!Array.isArray(speeds) || !Array.isArray(segment.extra_material_refs)) return;
  for (const material of speeds) {
    if (segment.extra_material_refs.includes(material.id)) material.speed = speed;
  }
}

// ---------------------------------------------------------------------------
// Plano de render

export function buildRenderPlan(draft: PersistentDraft): RenderPlan {
  const ext = readExtension(draft);
  const main = findMainTrack(draft);
  const videos = new Map<string, Record<string, unknown>>();
  for (const material of Array.isArray(draft.materials?.videos) ? draft.materials.videos : []) {
    if (isObject(material) && typeof material.id === "string") videos.set(material.id, material);
  }

  const clips: RenderClip[] = [];
  const warnings: string[] = [];
  let overlap = 0;

  for (const segment of main ? orderedSegments(main) : []) {
    const start = segment.target_timerange.start ?? 0;
    const duration = segment.target_timerange.duration;
    const previous = clips[clips.length - 1];
    let transitionIn: Transition | null = null;
    const wanted = previous ? ext.transitions[previous.segmentId] : undefined;
    if (previous && wanted) {
      const length = Math.trunc(
        Math.min(wanted.durationUs, previous.timelineDurationUs / 2, duration / 2),
      );
      if (length >= MIN_TRANSITION_US) {
        transitionIn = { kind: wanted.kind, durationUs: length };
        previous.transitionOut = transitionIn;
        overlap += length;
      }
    }

    const material = videos.get(segment.material_id);
    const path = typeof material?.path === "string" ? material.path : "";
    const materialName = typeof material?.material_name === "string" ? material.material_name : "";
    if (!path) warnings.push(`O clipe ${clips.length + 1} não tem arquivo de mídia.`);
    const style = styleOf(ext, segment.id);
    const source = sourceRangeOf(segment);

    clips.push({
      segmentId: segment.id,
      materialId: segment.material_id,
      path,
      name: materialName || basename(path) || `Clipe ${clips.length + 1}`,
      sourceStartUs: source.start,
      sourceDurationUs: source.duration,
      speed: speedOf(segment),
      volume: typeof segment.volume === "number" ? segment.volume : 1,
      timelineStartUs: start - overlap,
      timelineDurationUs: duration,
      filter: style.filter,
      effects: style.effects,
      transitionIn,
      transitionOut: null,
    });
  }

  const others = (Array.isArray(draft.tracks) ? draft.tracks : []).filter(
    (t) => t !== main && Array.isArray(t.segments) && t.segments.length > 0,
  );
  if (others.length > 0) {
    const types = [...new Set(others.map((t) => t.type))].join(", ");
    warnings.push(`${others.length} trilha(s) além da principal ainda não são reproduzidas (${types}).`);
  }

  const width = draft.canvas_config?.width;
  const height = draft.canvas_config?.height;
  return {
    canvas: {
      width: typeof width === "number" && width > 0 ? width : 1080,
      height: typeof height === "number" && height > 0 ? height : 1920,
    },
    fps: typeof draft.fps === "number" && draft.fps > 0 ? draft.fps : 30,
    durationUs: clips.reduce((end, c) => Math.max(end, c.timelineStartUs + c.timelineDurationUs), 0),
    clips,
    texts: [...ext.texts].sort((a, b) => a.startUs - b.startUs),
    warnings,
  };
}

/** Clipe que aparece no instante `atUs`. Numa transição, vale o clipe que está entrando. */
export function clipAtTime(plan: RenderPlan, atUs: Microseconds): RenderClip | undefined {
  let hit: RenderClip | undefined;
  for (const clip of plan.clips) {
    if (atUs >= clip.timelineStartUs && atUs < clip.timelineStartUs + clip.timelineDurationUs) hit = clip;
  }
  return hit;
}

// ---------------------------------------------------------------------------
// Leitura de parâmetros

function numberParam(
  params: Params,
  key: string,
  options: { min?: number; max?: number; fallback?: number } = {},
): number {
  const value = params[key] ?? options.fallback;
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new EditorError(`o parâmetro "${key}" precisa ser um número`);
  }
  if ((options.min !== undefined && value < options.min) || (options.max !== undefined && value > options.max)) {
    throw new EditorError(`o parâmetro "${key}" precisa ficar entre ${options.min ?? "-∞"} e ${options.max ?? "∞"}`);
  }
  return value;
}

function stringParam(params: Params, key: string, fallback?: string): string {
  const value = params[key] ?? fallback;
  if (typeof value !== "string") throw new EditorError(`o parâmetro "${key}" precisa ser um texto`);
  return value;
}

function oneOf<T extends string>(value: unknown, allowed: readonly T[], key: string): T {
  if (typeof value === "string" && (allowed as readonly string[]).includes(value)) return value as T;
  throw new EditorError(`o parâmetro "${key}" precisa ser um destes: ${allowed.join(", ")}`);
}

function findSegment(draft: PersistentDraft, segmentId: string): { track: Track; segment: Segment } {
  const track = findMainTrack(draft);
  const segment = track?.segments.find((s) => s.id === segmentId);
  if (!track || !segment || !segment.target_timerange) {
    throw new EditorError(`clipe não encontrado: ${segmentId}`);
  }
  return { track, segment };
}

function planClip(draft: PersistentDraft, segmentId: string): RenderClip {
  const clip = buildRenderPlan(draft).clips.find((c) => c.segmentId === segmentId);
  if (!clip) throw new EditorError(`clipe não encontrado: ${segmentId}`);
  return clip;
}

/** Converte um instante da timeline em deslocamento dentro do clipe, longe das bordas. */
function offsetInside(clip: RenderClip, atUs: Microseconds): Microseconds {
  const offset = Math.trunc(atUs - clip.timelineStartUs);
  if (offset < MIN_CLIP_US || clip.timelineDurationUs - offset < MIN_CLIP_US) {
    throw new EditorError("o ponto precisa ficar dentro do clipe, a pelo menos 0,1 s das bordas");
  }
  return offset;
}

const HEX_COLOR = /^#[0-9a-fA-F]{6}$/;

function applyTextFields(overlay: TextOverlay, params: Params): void {
  if ("text" in params) {
    const text = stringParam(params, "text");
    if (!text.trim()) throw new EditorError("o texto não pode ficar vazio");
    overlay.text = text;
  }
  if ("startUs" in params) overlay.startUs = Math.trunc(numberParam(params, "startUs", { min: 0 }));
  if ("durationUs" in params) overlay.durationUs = Math.trunc(numberParam(params, "durationUs", { min: MIN_CLIP_US }));
  if ("font" in params) overlay.font = oneOf(params.font, TEXT_FONTS, "font");
  if ("size" in params) overlay.size = numberParam(params, "size", { min: 0.02, max: 0.2 });
  if ("color" in params) {
    const color = stringParam(params, "color");
    if (!HEX_COLOR.test(color)) throw new EditorError('a cor precisa estar no formato "#RRGGBB"');
    overlay.color = color.toUpperCase();
  }
  if ("x" in params) overlay.x = numberParam(params, "x", { min: 0, max: 1 });
  if ("y" in params) overlay.y = numberParam(params, "y", { min: 0, max: 1 });
  if ("background" in params) {
    if (typeof params.background !== "boolean") throw new EditorError('o parâmetro "background" precisa ser true ou false');
    overlay.background = params.background;
  }
}

function findText(ext: MangoCutExtension, id: string): TextOverlay {
  const overlay = ext.texts.find((t) => t.id === id);
  if (!overlay) throw new EditorError(`texto não encontrado: ${id}`);
  return overlay;
}

// ---------------------------------------------------------------------------
// Comandos

interface EditorCommand {
  id: string;
  label: string;
  run(draft: PersistentDraft, params: Params): Record<string, string> | void;
}

const COMMANDS: EditorCommand[] = [
  {
    id: "project.rename",
    label: "Renomear o projeto",
    run(draft, params) {
      const name = stringParam(params, "name").trim();
      if (!name) throw new EditorError("o nome não pode ficar vazio");
      draft.name = name;
    },
  },
  {
    id: "clip.append",
    label: "Adicionar um vídeo ao fim da trilha principal",
    run(draft, params) {
      const path = stringParam(params, "path");
      if (!path) throw new EditorError('o parâmetro "path" não pode ficar vazio');
      const durationUs = Math.trunc(numberParam(params, "durationUs", { min: MIN_CLIP_US }));
      const track = requireMainTrack(draft);
      const segment = addVideoSegment(draft, track, {
        path,
        materialName: "name" in params ? stringParam(params, "name") : basename(path),
        startUs: trackEnd(track),
        durationUs,
        width: "width" in params ? numberParam(params, "width", { min: 1 }) : undefined,
        height: "height" in params ? numberParam(params, "height", { min: 1 }) : undefined,
      });
      packTrack(draft, track);
      return { segmentId: segment.id };
    },
  },
  {
    id: "clip.split",
    label: "Dividir o clipe no instante indicado",
    run(draft, params) {
      const atUs = numberParam(params, "atUs", { min: 0 });
      const clip = clipAtTime(buildRenderPlan(draft), atUs);
      if (!clip) throw new EditorError("não há clipe nesse ponto da timeline");
      const offset = offsetInside(clip, atUs);
      const { track, segment } = findSegment(draft, clip.segmentId);
      const speed = speedOf(segment);
      const source = sourceRangeOf(segment);
      const sourceOffset = Math.min(source.duration, Math.trunc(offset * speed));
      const duration = segment.target_timerange.duration;

      const second = structuredClone(segment);
      second.id = newId();
      second.target_timerange = {
        ...second.target_timerange,
        start: (segment.target_timerange.start ?? 0) + offset,
        duration: duration - offset,
      };
      second.source_timerange = {
        ...(second.source_timerange ?? {}),
        start: source.start + sourceOffset,
        duration: source.duration - sourceOffset,
      };
      second.common_keyframes = mapKeyframes(segment, (t) => (t >= offset ? t - offset : null), true);
      cloneSpeedMaterials(draft, second);

      segment.target_timerange = { ...segment.target_timerange, duration: offset };
      segment.source_timerange = { ...(segment.source_timerange ?? {}), start: source.start, duration: sourceOffset };
      segment.common_keyframes = mapKeyframes(segment, (t) => (t < offset ? t : null));

      track.segments.splice(track.segments.indexOf(segment) + 1, 0, second);

      const ext = extensionOf(draft);
      if (ext.clipStyles[segment.id]) {
        const style = styleOf(ext, segment.id);
        // O fade de entrada fica no começo do primeiro pedaço e o de saída no fim do segundo.
        ext.clipStyles[second.id] = {
          filter: style.filter ? { ...style.filter } : null,
          effects: style.effects.filter((e) => e !== "fadeIn"),
        };
        ext.clipStyles[segment.id] = { ...style, effects: style.effects.filter((e) => e !== "fadeOut") };
      }
      if (ext.transitions[segment.id]) {
        ext.transitions[second.id] = ext.transitions[segment.id]!;
        delete ext.transitions[segment.id];
      }
      packTrack(draft, track);
      return { segmentId: second.id };
    },
  },
  {
    id: "clip.trim",
    label: "Aparar o início ou o fim do clipe até o instante indicado",
    run(draft, params) {
      const { track, segment } = findSegment(draft, stringParam(params, "segmentId"));
      const edge = oneOf(params.edge, ["start", "end"] as const, "edge");
      const offset = offsetInside(planClip(draft, segment.id), numberParam(params, "atUs", { min: 0 }));
      const speed = speedOf(segment);
      const source = sourceRangeOf(segment);
      const sourceOffset = Math.min(source.duration, Math.trunc(offset * speed));
      const duration = segment.target_timerange.duration;

      if (edge === "start") {
        segment.target_timerange = { ...segment.target_timerange, duration: duration - offset };
        segment.source_timerange = {
          ...(segment.source_timerange ?? {}),
          start: source.start + sourceOffset,
          duration: source.duration - sourceOffset,
        };
        segment.common_keyframes = mapKeyframes(segment, (t) => (t >= offset ? t - offset : null));
      } else {
        segment.target_timerange = { ...segment.target_timerange, duration: offset };
        segment.source_timerange = { ...(segment.source_timerange ?? {}), start: source.start, duration: sourceOffset };
        segment.common_keyframes = mapKeyframes(segment, (t) => (t <= offset ? t : null));
      }
      packTrack(draft, track);
    },
  },
  {
    id: "clip.delete",
    label: "Excluir o clipe e encostar os seguintes",
    run(draft, params) {
      const { track, segment } = findSegment(draft, stringParam(params, "segmentId"));
      track.segments = track.segments.filter((s) => s !== segment);
      const ext = extensionOf(draft);
      delete ext.clipStyles[segment.id];
      delete ext.transitions[segment.id];
      packTrack(draft, track);
    },
  },
  {
    id: "clip.move",
    label: "Mover o clipe para outra posição da trilha principal",
    run(draft, params) {
      const { track, segment } = findSegment(draft, stringParam(params, "segmentId"));
      const order = orderedSegments(track).filter((s) => s !== segment);
      const index = Math.round(numberParam(params, "toIndex", { min: 0 }));
      order.splice(Math.min(index, order.length), 0, segment);
      packTrack(draft, track, order);
    },
  },
  {
    id: "clip.speed",
    label: "Mudar a velocidade do clipe",
    run(draft, params) {
      const { track, segment } = findSegment(draft, stringParam(params, "segmentId"));
      const speed = numberParam(params, "speed", { min: MIN_SPEED, max: MAX_SPEED });
      const previous = speedOf(segment);
      const source = sourceRangeOf(segment);
      segment.speed = speed;
      segment.source_timerange = { ...(segment.source_timerange ?? {}), start: source.start, duration: source.duration };
      segment.target_timerange = {
        ...segment.target_timerange,
        duration: Math.max(MIN_CLIP_US, Math.trunc(source.duration / speed)),
      };
      segment.common_keyframes = mapKeyframes(segment, (t) => Math.trunc((t * previous) / speed));
      setSpeedMaterials(draft, segment, speed);
      packTrack(draft, track);
    },
  },
  {
    id: "clip.filter",
    label: "Aplicar ou remover o filtro do clipe",
    run(draft, params) {
      const { segment } = findSegment(draft, stringParam(params, "segmentId"));
      const ext = extensionOf(draft);
      const style = styleOf(ext, segment.id);
      style.filter =
        params.filter === null || params.filter === undefined
          ? null
          : {
              id: oneOf(params.filter, FILTER_IDS, "filter"),
              intensity: numberParam(params, "intensity", { min: 0, max: 1, fallback: 1 }),
            };
      ext.clipStyles[segment.id] = style;
    },
  },
  {
    id: "clip.effects",
    label: "Definir os efeitos do clipe",
    run(draft, params) {
      const { segment } = findSegment(draft, stringParam(params, "segmentId"));
      if (!Array.isArray(params.effects)) throw new EditorError('o parâmetro "effects" precisa ser uma lista');
      const effects: EffectId[] = [];
      for (const value of params.effects) {
        const effect = oneOf(value, EFFECT_IDS, "effects");
        // Os dois zooms se anulam: vale o último da lista.
        if (effect === "zoomIn" || effect === "zoomOut") {
          const other = effect === "zoomIn" ? "zoomOut" : "zoomIn";
          if (effects.includes(other)) effects.splice(effects.indexOf(other), 1);
        }
        if (!effects.includes(effect)) effects.push(effect);
      }
      const ext = extensionOf(draft);
      ext.clipStyles[segment.id] = { ...styleOf(ext, segment.id), effects };
    },
  },
  {
    id: "clip.transition",
    label: "Definir a transição entre o clipe e o seguinte",
    run(draft, params) {
      const { track, segment } = findSegment(draft, stringParam(params, "segmentId"));
      const ext = extensionOf(draft);
      if (params.kind === null || params.kind === undefined) {
        delete ext.transitions[segment.id];
        return;
      }
      const order = orderedSegments(track);
      if (order.indexOf(segment) === order.length - 1) {
        throw new EditorError("o último clipe não tem um clipe seguinte para a transição");
      }
      ext.transitions[segment.id] = {
        kind: oneOf(params.kind, ["dissolve"] as const, "kind"),
        durationUs: Math.trunc(
          numberParam(params, "durationUs", { min: MIN_CLIP_US, max: 2_000_000, fallback: DEFAULT_TRANSITION_US }),
        ),
      };
    },
  },
  {
    id: "text.add",
    label: "Adicionar um texto sobre o vídeo",
    run(draft, params) {
      const overlay: TextOverlay = {
        id: newId(),
        text: "Texto",
        startUs: 0,
        durationUs: DEFAULT_TEXT_US,
        font: "system",
        size: 0.07,
        color: "#FFFFFF",
        x: 0.5,
        y: 0.8,
        background: false,
      };
      applyTextFields(overlay, params);
      extensionOf(draft).texts.push(overlay);
      return { textId: overlay.id };
    },
  },
  {
    id: "text.update",
    label: "Alterar um texto",
    run(draft, params) {
      const ext = extensionOf(draft);
      applyTextFields(findText(ext, stringParam(params, "id")), params);
    },
  },
  {
    id: "text.delete",
    label: "Excluir um texto",
    run(draft, params) {
      const ext = extensionOf(draft);
      const overlay = findText(ext, stringParam(params, "id"));
      ext.texts = ext.texts.filter((t) => t !== overlay);
    },
  },
];

export function listEditorCommands(): { id: string; label: string }[] {
  return COMMANDS.map(({ id, label }) => ({ id, label }));
}

/**
 * Executa um comando sobre uma cópia do draft. O original não é alterado.
 * Lança `EditorError` com uma mensagem para o usuário quando o comando ou os parâmetros são inválidos.
 */
export function runEditorCommand(
  draftInput: PersistentDraft,
  commandId: string,
  params: unknown = {},
): { draft: PersistentDraft; plan: RenderPlan; result: Record<string, string> } {
  const command = COMMANDS.find((c) => c.id === commandId);
  if (!command) throw new EditorError(`comando desconhecido: ${commandId}`);
  if (!isObject(params)) throw new EditorError("os parâmetros precisam ser um objeto JSON");
  const draft = structuredClone(draftInput);
  const result = command.run(draft, params) ?? {};
  return { draft, plan: buildRenderPlan(draft), result };
}

/** Projeto novo do editor: draft mínimo com a trilha principal e o bloco `mangocut`. */
export function createEditorProject(options?: {
  name?: string;
  width?: number;
  height?: number;
  fps?: number;
}): PersistentDraft {
  const width = options?.width ?? 1080;
  const height = options?.height ?? 1920;
  const ratio = width === height ? "1:1" : width > height ? "16:9" : "9:16";
  const draft = createMinimalDraft({ name: options?.name, width, height, fps: options?.fps, ratio });
  addTrack(draft, "video");
  extensionOf(draft);
  return draft;
}
