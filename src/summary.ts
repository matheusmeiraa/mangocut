import { getTimelineEndUs } from "./draft.ts";
import type { DraftValidationResult, Microseconds, PersistentDraft } from "./types.ts";

/*
 * Resumo de um projeto com tipos normalizados: campos ausentes ou com tipo errado viram
 * `null`/`0`, para que a CLI e o app iOS possam exibir até projetos malformados.
 */

export interface MaterialRef {
  /** Chave em `materials` onde o material está (`videos`, `audios`, `texts`, ...). */
  category: string;
  /** Caminho do arquivo, nome do material ou, na falta deles, a categoria. */
  label: string;
}

export interface SegmentSummary {
  id: string;
  materialId: string;
  material: MaterialRef | null;
  startUs: Microseconds;
  durationUs: Microseconds;
  endUs: Microseconds;
  source: { startUs: Microseconds; durationUs: Microseconds } | null;
  speed: number;
  keyframes: { property: string; count: number }[];
  /** Referências a keyframes no formato antigo (`draft.keyframes`). */
  keyframeRefs: number;
}

export interface TrackSummary {
  index: number;
  id: string;
  type: string;
  name: string;
  segments: SegmentSummary[];
}

export interface DraftSummary {
  name: string;
  id: string;
  version: number | null;
  newVersion: string | null;
  canvas: { width: number | null; height: number | null; ratio: string | null } | null;
  fps: number | null;
  /** Valor do campo `duration`, que pode estar desatualizado. */
  declaredDurationUs: Microseconds;
  /** Fim do último clipe da timeline (ver `getTimelineEndUs`). */
  timelineEndUs: Microseconds;
  tracks: TrackSummary[];
  totals: { tracks: number; segments: number; keyframes: number };
  validation: DraftValidationResult;
}

type Loose = Record<string, unknown>;

function isObject(v: unknown): v is Loose {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function num(v: unknown, fallback = 0): number {
  return typeof v === "number" && Number.isFinite(v) ? v : fallback;
}

function numOrNull(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

function strOrNull(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}

function list(v: unknown): unknown[] {
  return Array.isArray(v) ? v : [];
}

function indexMaterials(materials: unknown): Map<string, MaterialRef> {
  const index = new Map<string, MaterialRef>();
  if (!isObject(materials)) return index;
  for (const [category, items] of Object.entries(materials)) {
    for (const item of list(items)) {
      if (!isObject(item) || typeof item.id !== "string") continue;
      const label = [item.path, item.material_name, item.name].find(
        (v): v is string => typeof v === "string" && v.length > 0,
      );
      index.set(item.id, { category, label: label ?? category });
    }
  }
  return index;
}

function summarizeSegment(seg: Loose, materials: Map<string, MaterialRef>): SegmentSummary {
  const target = isObject(seg.target_timerange) ? seg.target_timerange : {};
  const source = isObject(seg.source_timerange) ? seg.source_timerange : null;
  const startUs = num(target.start);
  const durationUs = num(target.duration);
  const materialId = typeof seg.material_id === "string" ? seg.material_id : "";
  return {
    id: typeof seg.id === "string" ? seg.id : "",
    materialId,
    material: materials.get(materialId) ?? null,
    startUs,
    durationUs,
    endUs: startUs + durationUs,
    source: source ? { startUs: num(source.start), durationUs: num(source.duration) } : null,
    speed: num(seg.speed, 1),
    keyframes: list(seg.common_keyframes)
      .filter(isObject)
      .map((kfList) => ({
        property: String(kfList.property_type ?? ""),
        count: list(kfList.keyframe_list).length,
      })),
    keyframeRefs: list(seg.keyframe_refs).length,
  };
}

/** Resume um projeto (trilhas, clipes, keyframes e duração real) junto com o resultado da validação. */
export function summarizeDraft(draft: PersistentDraft, validation: DraftValidationResult): DraftSummary {
  const root: Loose = isObject(draft) ? (draft as unknown as Loose) : {};
  const materials = indexMaterials(root.materials);
  const tracks: TrackSummary[] = list(root.tracks)
    .filter(isObject)
    .map((track, index) => ({
      index,
      id: typeof track.id === "string" ? track.id : "",
      type: typeof track.type === "string" ? track.type : "video",
      name: typeof track.name === "string" ? track.name : "",
      segments: list(track.segments)
        .filter(isObject)
        .map((seg) => summarizeSegment(seg, materials)),
    }));
  const segments = tracks.flatMap((t) => t.segments);
  const canvas = isObject(root.canvas_config) ? root.canvas_config : null;
  return {
    name: typeof root.name === "string" ? root.name : "",
    id: typeof root.id === "string" ? root.id : "",
    version: numOrNull(root.version),
    newVersion: strOrNull(root.new_version),
    canvas: canvas
      ? { width: numOrNull(canvas.width), height: numOrNull(canvas.height), ratio: strOrNull(canvas.ratio) }
      : null,
    fps: numOrNull(root.fps),
    declaredDurationUs: num(root.duration),
    timelineEndUs: getTimelineEndUs(root as Pick<PersistentDraft, "tracks">),
    tracks,
    totals: {
      tracks: tracks.length,
      segments: segments.length,
      keyframes: segments.reduce(
        (sum, s) => sum + s.keyframeRefs + s.keyframes.reduce((n, k) => n + k.count, 0),
        0,
      ),
    },
    validation,
  };
}
