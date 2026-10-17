import {
  DraftErrorFlags,
  type CommonKeyframe,
  type DraftRepairReport,
  type DraftValidationIssue,
  type DraftValidationResult,
  type KeyframePropertyType,
  type Microseconds,
  type PersistentDraft,
  type Point2D,
  type Segment,
  type Track,
  type TrackType,
} from "./types.ts";

/**
 * Default schema versions recovered from `draft.cpp` (`0x114e9c8b8`) and `persistent_draft.cpp` (`0x1159feb20`).
 */
export const DEFAULT_DRAFT_VERSION = 360000;
export const DEFAULT_DRAFT_NEW_VERSION = "190.0.0";
export const DEFAULT_CANVAS_RATIO = "original";

/**
 * Uses the global Web Crypto API (Node.js >= 19, browsers) so the engine has no
 * Node-only imports and also runs inside JavaScriptCore (the iOS app injects it).
 */
function upperUUID(): string {
  return globalThis.crypto.randomUUID().toUpperCase();
}

/**
 * Creates a clean-room minimal `PersistentDraft` matching CapCut iOS v19.7.0 defaults.
 */
export function createMinimalDraft(options?: {
  id?: string;
  name?: string;
  width?: number;
  height?: number;
  fps?: number;
  ratio?: string;
}): PersistentDraft {
  const nowSec = Math.floor(Date.now() / 1000);
  return {
    id: options?.id ?? upperUUID(),
    version: DEFAULT_DRAFT_VERSION,
    new_version: DEFAULT_DRAFT_NEW_VERSION,
    name: options?.name ?? "",
    duration: 0,
    create_time: nowSec,
    update_time: nowSec,
    fps: options?.fps ?? 30.0,
    is_drop_frame_timecode: false,
    color_space: 0,
    canvas_config: {
      width: options?.width ?? 1080,
      height: options?.height ?? 1920,
      ratio: options?.ratio ?? DEFAULT_CANVAS_RATIO,
    },
    config: {
      video_mute: false,
      maintrack_adsorb: true,
      record_audio_last_index: 1,
      extract_audio_last_index: 1,
      original_sound_last_index: 1,
      sticker_max_index: 1,
      adjust_max_index: 1,
      material_save_mode: 0,
      multi_language_mode: "none",
      subtitle_recognition_id: "",
      subtitle_sync: true,
      lyrics_recognition_id: "",
      lyrics_sync: true,
    },
    tracks: [],
    materials: {
      videos: [],
      audios: [],
      texts: [],
      stickers: [],
      speeds: [],
      canvases: [],
      transitions: [],
      video_effects: [],
      audio_effects: [],
      flowers: [],
      tail_leaders: [],
    },
    keyframes: {
      videos: [],
      audios: [],
      texts: [],
      stickers: [],
      filters: [],
      adjusts: [],
      handwrites: [],
    },
    keyframe_graph_list: [],
    group_container: { groups: [] },
    platform: {
      os: "ios",
      os_version: "18.0",
      app_id: 3006,
      app_version: "19.7.0",
      app_source: "app_store",
    },
    last_modified_platform: {
      os: "ios",
      os_version: "18.0",
      app_id: 3006,
      app_version: "19.7.0",
      app_source: "app_store",
    },
    relationships: [],
    render_index_track_mode_on: true,
    free_render_index_mode_on: false,
    mixed_track_mode_on: false,
    static_cover_image_path: "",
    source: "default",
    time_marks: null,
    path: "",
    lyrics_effects: [],
    draft_type: 0,
    is_minimal_draft: false,
  };
}

/**
 * Adds a `Track` to a `PersistentDraft`, ensuring required fields (`segments`, `name`) exist.
 */
export function addTrack(
  draft: PersistentDraft,
  type: TrackType = "video",
  options?: { id?: string; name?: string; flag?: number; attribute?: number },
): Track {
  const track: Track = {
    id: options?.id ?? upperUUID(),
    type,
    segments: [],
    flag: options?.flag ?? 0,
    attribute: options?.attribute ?? 0,
    name: options?.name ?? "",
    is_default_name: (options?.name ?? "") === "",
  };
  draft.tracks.push(track);
  return track;
}

/**
 * Adds a video material and a corresponding timeline `Segment` to the given video track,
 * automatically updating `draft.duration` to cover the segment end time.
 */
export function addVideoSegment(
  draft: PersistentDraft,
  track: Track,
  params: {
    segmentId?: string;
    materialId?: string;
    path: string;
    materialName?: string;
    startUs: Microseconds;
    durationUs: Microseconds;
    sourceStartUs?: Microseconds;
    sourceDurationUs?: Microseconds;
    width?: number;
    height?: number;
    speed?: number;
    volume?: number;
  },
): Segment {
  const materialId = params.materialId ?? upperUUID();
  const speedId = upperUUID();
  const speed = params.speed ?? 1.0;
  const sourceStartUs = params.sourceStartUs ?? 0;
  const sourceDurationUs =
    params.sourceDurationUs ?? Math.trunc(params.durationUs * speed);

  draft.materials.videos.push({
    id: materialId,
    type: "video",
    path: params.path,
    material_name: params.materialName ?? "",
    duration: Math.max(sourceStartUs + sourceDurationUs, params.durationUs),
    width: params.width ?? draft.canvas_config.width,
    height: params.height ?? draft.canvas_config.height,
    crop_ratio: "free",
    crop_scale: 1.0,
    extra_type_option: 0,
  });

  draft.materials.speeds.push({
    id: speedId,
    type: "speed",
    mode: 0,
    speed,
    curve_speed: null,
  });

  const segment: Segment = {
    id: params.segmentId ?? upperUUID(),
    material_id: materialId,
    source_timerange: {
      start: sourceStartUs,
      duration: sourceDurationUs,
    },
    target_timerange: {
      start: params.startUs,
      duration: params.durationUs,
    },
    render_timerange: {
      start: 0,
      duration: 0,
    },
    desc: "",
    state: 0,
    speed,
    is_loop: false,
    is_tone_modify: false,
    reverse: false,
    intensifies_audio: false,
    cartoon: false,
    volume: params.volume ?? 1.0,
    last_nonzero_volume: params.volume ?? 1.0,
    clip: {
      alpha: 1.0,
      flip: { horizontal: false, vertical: false },
      rotation: 0.0,
      scale: { x: 1.0, y: 1.0 },
      transform: { x: 0.0, y: 0.0 },
    },
    uniform_scale: { on: true, value: 1.0 },
    extra_material_refs: [speedId],
    render_index: 0,
    track_render_index: 0,
    keyframe_refs: [],
    visible: true,
    common_keyframes: [],
    source: "segmentsourcenormal",
  };

  track.segments.push(segment);
  const segEnd = params.startUs + params.durationUs;
  if (draft.duration < segEnd) {
    draft.duration = segEnd;
  }
  return segment;
}

/**
 * Adds a `CommonKeyframe` to a segment's `common_keyframes` list for `propertyType`.
 */
export function addKeyframeToSegment(
  segment: Segment,
  propertyType: KeyframePropertyType,
  kfParams: {
    id?: string;
    timeOffsetUs: Microseconds;
    values: number[];
    curveType?: string;
    leftControl?: Point2D;
    rightControl?: Point2D;
    graph?: CommonKeyframe["graph"];
  },
): CommonKeyframe {
  let propList = segment.common_keyframes.find(
    (ck) => ck.property_type === propertyType,
  );
  if (!propList) {
    propList = {
      id: upperUUID(),
      property_type: propertyType,
      keyframe_list: [],
    };
    segment.common_keyframes.push(propList);
  }

  const kf: CommonKeyframe = {
    id: kfParams.id ?? upperUUID(),
    curveType: kfParams.curveType ?? "Line",
    time_offset: kfParams.timeOffsetUs,
    left_control: kfParams.leftControl ?? { x: 0.0, y: 0.0 },
    right_control: kfParams.rightControl ?? { x: 0.0, y: 0.0 },
    values: [...kfParams.values],
    string_value: "",
    graph: kfParams.graph ?? null,
  };

  propList.keyframe_list.push(kf);
  propList.keyframe_list.sort((a, b) => a.time_offset - b.time_offset);
  return kf;
}

function isPlainObject(val: unknown): val is Record<string, unknown> {
  return typeof val === "object" && val !== null && !Array.isArray(val);
}

/**
 * Real timeline end in microseconds: the largest `target_timerange.start + duration`
 * across every segment of every track. Unlike `draft.duration`, it cannot be stale.
 */
export function getTimelineEndUs(draft: Pick<PersistentDraft, "tracks">): Microseconds {
  let end = 0;
  for (const track of Array.isArray(draft.tracks) ? draft.tracks : []) {
    for (const seg of Array.isArray(track.segments) ? track.segments : []) {
      const range = seg.target_timerange;
      if (!range || typeof range.duration !== "number") continue;
      const start = typeof range.start === "number" ? range.start : 0;
      if (Number.isFinite(start + range.duration)) end = Math.max(end, start + range.duration);
    }
  }
  return end;
}

/**
 * Validates a `TimeRange` object according to `TimeRange::from_json` (`0x115fa2d70`).
 * - `duration` is required via `json.at("duration")` (`0x115fa2e40`) and must be a number.
 * - `start` is optional (`0x115fa2df0`), but if present must be a number.
 */
function validateTimeRange(
  tr: unknown,
  path: string,
  issues: DraftValidationIssue[],
): { start: number; duration: number } | null {
  if (!isPlainObject(tr)) {
    issues.push({
      path,
      code: "TYPE_ERROR",
      message: `TimeRange at '${path}' must be an object`,
      fatal: true,
    });
    return null;
  }

  let duration = 0;
  if ("duration" in tr && tr.duration !== undefined && tr.duration !== null) {
    if (typeof tr.duration !== "number" || !Number.isFinite(tr.duration)) {
      issues.push({
        path: `${path}.duration`,
        code: "TYPE_ERROR",
        message: `[json.exception.type_error.302] type must be number at ${path}.duration`,
        fatal: true,
      });
      return null;
    }
    duration = tr.duration;
  } else {
    // 0x115fa2e40 .. 0x115fa2e44: contains("duration") == 0 branches over (default duration = 0)
    duration = 0;
  }

  let start = 0;
  if ("start" in tr && tr.start !== undefined && tr.start !== null) {
    if (typeof tr.start !== "number" || !Number.isFinite(tr.start)) {
      issues.push({
        path: `${path}.start`,
        code: "TYPE_ERROR",
        message: `[json.exception.type_error.302] type must be number at ${path}.start`,
        fatal: true,
      });
      return null;
    }
    start = tr.start;
  }

  return { start, duration };
}

/**
 * Builds a lookup table mapping `material_id` -> expected track category (`"video"`, `"audio"`, `"text"`, `"sticker"`, `"effect"`, `"filter"`).
 */
function buildMaterialCategoryMap(
  materials: unknown,
): Map<string, TrackType> {
  const map = new Map<string, TrackType>();
  if (!isPlainObject(materials)) {
    return map;
  }
  const categoryPairs: [string, TrackType][] = [
    ["videos", "video"],
    ["audios", "audio"],
    ["texts", "text"],
    ["stickers", "sticker"],
    ["video_effects", "effect"],
    ["effects", "effect"],
  ];
  for (const [matKey, trackType] of categoryPairs) {
    const arr = materials[matKey];
    if (Array.isArray(arr)) {
      for (const item of arr) {
        if (isPlainObject(item) && typeof item.id === "string") {
          map.set(item.id, trackType);
        }
      }
    }
  }
  return map;
}

/**
 * Clean-room validator reproducing both:
 * 1. Fatal deserialization checks in `persistent_draft.cpp` (`0x115a009dc`), `time_range.cpp` (`0x115fa2d70`),
 *    `track.cpp` (`0x115fadf14`), and `segment.cpp` (`0x115c90ebc`).
 * 2. Non-fatal repairable checks in `DraftRepairEngine` (`0x114f019b0`):
 *    - `DraftDurationRepairTask` (`0x114ec4058`, flag `0x800`)
 *    - `SegInErrorTrackRepairTask` (`0x115c90724`, flag `0x4`)
 *    - `SegTimeConflictRepairTask` (`0x115c90870`, flag `0x8`)
 */
export function validateDraftJson(input: unknown): DraftValidationResult {
  const issues: DraftValidationIssue[] = [];
  let errorMask = DraftErrorFlags.NONE;

  let parsed: unknown = input;
  if (typeof input === "string") {
    try {
      parsed = JSON.parse(input);
    } catch (err) {
      const msg = `json::parse failed, exception: ${(err as Error).message}`;
      return {
        valid: false,
        fatalExceptionMessage: msg,
        errorMask,
        issues: [
          {
            path: "$",
            code: "NOT_OBJECT",
            message: msg,
            fatal: true,
          },
        ],
      };
    }
  }

  // 0x115a00a14 .. 0x115a00a50: Root must be a JSON object
  if (!isPlainObject(parsed)) {
    const msg = "json::parse failed: not object issue!";
    return {
      valid: false,
      fatalExceptionMessage: msg,
      errorMask,
      issues: [
        {
          path: "$",
          code: "NOT_OBJECT",
          message: msg,
          fatal: true,
        },
      ],
    };
  }

  const draftDuration =
    typeof parsed.duration === "number" ? parsed.duration : 0;
  const materialCategoryMap = buildMaterialCategoryMap(parsed.materials);

  if ("tracks" in parsed && parsed.tracks !== undefined && parsed.tracks !== null) {
    if (!Array.isArray(parsed.tracks)) {
      issues.push({
        path: "$.tracks",
        code: "TYPE_ERROR",
        message: "[json.exception.type_error.302] type must be array, but is not",
        fatal: true,
      });
    } else {
      const seenSegmentIds = new Set<string>();

      for (let tIdx = 0; tIdx < parsed.tracks.length; tIdx++) {
        const track = parsed.tracks[tIdx];
        const trackPath = `$.tracks[${tIdx}]`;
        if (!isPlainObject(track)) {
          issues.push({
            path: trackPath,
            code: "TYPE_ERROR",
            message: `Track at ${trackPath} must be an object`,
            fatal: true,
          });
          continue;
        }

        // 0x115fae028 .. 0x115fae034: if json.contains("segments") == 0 -> skip (default empty segments)
        if ("segments" in track && track.segments !== undefined && !Array.isArray(track.segments)) {
          issues.push({
            path: `${trackPath}.segments`,
            code: "TYPE_ERROR",
            message: `[json.exception.type_error.302] type must be array at ${trackPath}.segments`,
            fatal: true,
          });
        }

        // 0x115fae244 .. 0x115fae250: if json.contains("name") == 0 -> skip (default empty string)
        if ("name" in track && track.name !== undefined && typeof track.name !== "string") {
          issues.push({
            path: `${trackPath}.name`,
            code: "TYPE_ERROR",
            message: `[json.exception.type_error.302] type must be string at ${trackPath}.name`,
            fatal: true,
          });
        }

        if (!Array.isArray(track.segments)) {
          continue;
        }

        const trackType = typeof track.type === "string" ? track.type : "video";
        const trackId = typeof track.id === "string" ? track.id : `track_${tIdx}`;

        // Track interval hull [prevStart, prevEnd] for SegTimeConflictRepairTask (0x115c90870)
        let hasPrevInterval = false;
        let hullStart = 0;
        let hullEnd = 0;

        for (let sIdx = 0; sIdx < track.segments.length; sIdx++) {
          const seg = track.segments[sIdx];
          const segPath = `${trackPath}.segments[${sIdx}]`;
          if (!isPlainObject(seg)) {
            issues.push({
              path: segPath,
              code: "TYPE_ERROR",
              message: `Segment at ${segPath} must be an object`,
              fatal: true,
            });
            continue;
          }

          const segId = typeof seg.id === "string" ? seg.id : `seg_${sIdx}`;
          if (typeof seg.id === "string" && seg.id.length > 0) {
            if (seenSegmentIds.has(seg.id)) {
              // 0x115c90ebc: "Id conflict: {}" in segment.cpp::restore_from
              issues.push({
                path: `${segPath}.id`,
                code: "ID_CONFLICT",
                message: `Id conflict: ${seg.id}`,
                fatal: false,
              });
            }
            seenSegmentIds.add(seg.id);
          }

          if (seg.source_timerange !== undefined && seg.source_timerange !== null) {
            validateTimeRange(
              seg.source_timerange,
              `${segPath}.source_timerange`,
              issues,
            );
          }

          if (seg.target_timerange !== undefined && seg.target_timerange !== null) {
            const targetTr = validateTimeRange(
              seg.target_timerange,
              `${segPath}.target_timerange`,
              issues,
            );
            if (targetTr) {
              const segStart = targetTr.start;
              const segEnd = targetTr.start + targetTr.duration;

              // 1. DraftDurationRepairTask::visit (0x114ec4058)
              if (draftDuration < segEnd) {
                errorMask |= DraftErrorFlags.DRAFT_DURATION_ERROR;
                issues.push({
                  path: `${segPath}.target_timerange`,
                  code: "DURATION_MISMATCH",
                  message: `[DraftError]draft duration error: ${draftDuration}-${segEnd}`,
                  fatal: false,
                });
              }

              // 2. SegTimeConflictRepairTask::visit (0x115c90870)
              if (!hasPrevInterval) {
                hasPrevInterval = true;
                hullStart = segStart;
                hullEnd = segEnd;
              } else {
                const overlaps =
                  (hullStart <= segStart && segStart < hullEnd) ||
                  (segStart <= hullStart && hullStart < segEnd);
                if (overlaps) {
                  errorMask |= DraftErrorFlags.SEG_TIME_CONFLICT;
                  issues.push({
                    path: `${segPath}.target_timerange`,
                    code: "SEGMENT_TIME_CONFLICT",
                    message: `[DraftError] segment[${segStart}, ${segEnd}] cross in [${hullStart}, ${hullEnd}] (SegTimeConflict:${segId}-${trackId}[${segStart},${segEnd}],[${hullStart},${hullEnd}]; )`,
                    fatal: false,
                  });
                } else {
                  hullStart = Math.min(hullStart, segStart);
                  hullEnd = Math.max(hullEnd, segEnd);
                }
              }
            }
          }

          // 3. SegInErrorTrackRepairTask::visit (0x115c90724)
          if (typeof seg.material_id === "string") {
            const expectedTrackType = materialCategoryMap.get(seg.material_id);
            if (expectedTrackType && expectedTrackType !== trackType) {
              errorMask |= DraftErrorFlags.SEG_IN_ERROR_TRACK;
              issues.push({
                path: `${segPath}.material_id`,
                code: "TRACK_MATERIAL_MISMATCH",
                message: `SegInErrorTrack:${segId}-${trackId} (material type '${expectedTrackType}' in track type '${trackType}')`,
                fatal: false,
              });
            }
          }
        }
      }
    }
  }

  const fatalIssue = issues.find((i) => i.fatal);
  return {
    valid: !fatalIssue && errorMask === DraftErrorFlags.NONE,
    fatalExceptionMessage: fatalIssue?.message,
    errorMask,
    issues,
  };
}

/**
 * Clean-room implementation of `DraftRepairEngine::run` (`0x114f01c28`) and its 3 repair tasks:
 * 1. `DraftDurationRepairTask::visit` (`0x114ec4058`, flag `0x800`)
 * 2. `SegInErrorTrackRepairTask::visit` (`0x115c90724`, flag `0x4`)
 * 3. `SegTimeConflictRepairTask::visit` (`0x115c90870`, flag `0x8`):
 *    - If `seg_start - prev_end >= -99` us (`cmn x8, #99` at `0x115c90a84`), shifts
 *      `target_timerange.start` to `prev_end + 100` us (`add x8, x8, #100` at `0x115c90aa4`).
 *    - If `seg_start - prev_end < -99` us (overlap >= 100 us), removes the conflicting segment.
 */
export function repairDraft(draftInput: PersistentDraft): DraftRepairReport {
  const draft: PersistentDraft = structuredClone(draftInput);
  let errorMask = DraftErrorFlags.NONE;
  const errorInfo: string[] = [];
  const fixInfo: string[] = [];

  const materialCategoryMap = buildMaterialCategoryMap(draft.materials);

  // Missing keys fall back to the deserializer defaults (`tracks = []`, `segments = []`).
  const tracks: Track[] = Array.isArray(draft.tracks) ? draft.tracks : [];

  // Task 1: SegInErrorTrackRepairTask (0x115c90724)
  for (const track of tracks) {
    const keptSegments: Segment[] = [];
    for (const seg of Array.isArray(track.segments) ? track.segments : []) {
      const expectedTrackType = materialCategoryMap.get(seg.material_id);
      if (expectedTrackType && expectedTrackType !== track.type) {
        errorMask |= DraftErrorFlags.SEG_IN_ERROR_TRACK;
        errorInfo.push(`SegInErrorTrack:${seg.id}-${track.id}`);
        fixInfo.push(`Removed segment ${seg.id} from incompatible track ${track.id} (${track.type})`);
      } else {
        keptSegments.push(seg);
      }
    }
    track.segments = keptSegments;
  }

  // Task 2: SegTimeConflictRepairTask (0x115c90870)
  for (const track of tracks) {
    let hasPrev = false;
    let hullStart = 0;
    let hullEnd = 0;
    const repairedSegments: Segment[] = [];

    for (const seg of track.segments) {
      if (!seg.target_timerange) {
        repairedSegments.push(seg);
        continue;
      }
      const start = seg.target_timerange.start ?? 0;
      const duration = seg.target_timerange.duration;
      const end = start + duration;

      if (!hasPrev) {
        hasPrev = true;
        hullStart = start;
        hullEnd = end;
        repairedSegments.push(seg);
        continue;
      }

      const overlaps =
        (hullStart <= start && start < hullEnd) ||
        (start <= hullStart && hullStart < end);

      if (!overlaps) {
        hullStart = Math.min(hullStart, start);
        hullEnd = Math.max(hullEnd, end);
        repairedSegments.push(seg);
      } else {
        errorMask |= DraftErrorFlags.SEG_TIME_CONFLICT;
        errorInfo.push(
          `SegTimeConflict:${seg.id}-${track.id}[${start},${end}],[${hullStart},${hullEnd}]; `,
        );

        // 0x115c90a80 .. 0x115c90aa4: delta = seg_start - prev_end; cmn x8, #99
        const delta = start - hullEnd;
        if (delta >= -99) {
          const newStart = hullEnd + 100;
          seg.target_timerange.start = newStart;
          const newEnd = newStart + duration;
          hullEnd = Math.max(hullEnd, newEnd);
          repairedSegments.push(seg);
          fixInfo.push(
            `Shifted micro-overlapping segment ${seg.id} start from ${start} to ${newStart} (prev_end + 100 us)`,
          );
        } else {
          fixInfo.push(
            `Removed overlapping segment ${seg.id} [${start}, ${end}] crossing [${hullStart}, ${hullEnd}]`,
          );
        }
      }
    }

    track.segments = repairedSegments;
  }

  // Task 3: DraftDurationRepairTask (0x114ec4058)
  for (const track of tracks) {
    for (const seg of track.segments) {
      if (!seg.target_timerange) continue;
      const start = seg.target_timerange.start ?? 0;
      const segEnd = start + seg.target_timerange.duration;
      if (draft.duration < segEnd) {
        errorMask |= DraftErrorFlags.DRAFT_DURATION_ERROR;
        errorInfo.push(`[DraftError]draft duration error: ${draft.duration}-${segEnd}`);
        const oldDuration = draft.duration;
        draft.duration = segEnd;
        fixInfo.push(`Updated draft.duration from ${oldDuration} to ${segEnd}`);
      }
    }
  }

  return {
    errorMask,
    errorInfo,
    fixInfo,
    repairedDraft: draft,
  };
}
