/**
 * Clean-room TypeScript types for CapCut iOS v19.7.0 (`com.lemon.lvoverseas`)
 * project persistence (`draft_content.json` / `draft_info.json`) and keyframe interpolation.
 */

export type Microseconds = number;

export interface Point2D {
  x: number;
  y: number;
}

export type GraphPointType = "on" | "off" | string;

export interface GraphPoint {
  id: string;
  type: GraphPointType;
  point: Point2D;
}

export interface KeyframeGraph {
  id: string;
  resource_id?: string;
  resource_name?: string;
  source_platform?: number;
  graph_points: GraphPoint[];
}

export type CurveType = "Line" | "Quad" | "Cubic" | "Bezier" | string;

export interface CommonKeyframe {
  id: string;
  curveType: CurveType;
  /** Offset in microseconds relative to the segment start. */
  time_offset: Microseconds;
  /** Incoming control vector relative to this keyframe. */
  left_control: Point2D;
  /** Outgoing control vector relative to this keyframe. */
  right_control: Point2D;
  /** Numeric property values at this keyframe (typically length 1). */
  values: number[];
  string_value: string;
  graph?: KeyframeGraph | null;
}

export type KeyframePropertyType =
  | "KFTypePositionX"
  | "KFTypePositionY"
  | "KFTypeScaleX"
  | "KFTypeScaleY"
  | "KFTypeRotation"
  | "KFTypeAlpha"
  | "KFTypeVolume"
  | "KFTypeBrightness"
  | "KFTypeContrast"
  | "KFTypeSaturation"
  | string;

export interface CommonKeyframeList {
  id: string;
  property_type: KeyframePropertyType;
  keyframe_list: CommonKeyframe[];
  material_id?: string;
}

/**
 * Represents `TimeRange` (`time_range.cpp`, `0x115fa2d70`).
 * Note: `duration` is strictly required via `json.at("duration")` (`0x115fa2e40`),
 * whereas `start` is optional with default `0` (`0x115fa2df0`).
 */
export interface TimeRange {
  id?: string;
  start?: Microseconds;
  duration: Microseconds;
}

export interface ClipTransform {
  alpha: number;
  flip: {
    horizontal: boolean;
    vertical: boolean;
  };
  rotation: number;
  scale: Point2D;
  transform: Point2D;
}

export interface UniformScale {
  on: boolean;
  value: number;
}

/**
 * Represents `Segment` (`0x115abf51c` / `0x115abe454`).
 */
export interface Segment {
  id: string;
  material_id: string;
  source_timerange?: TimeRange | null;
  target_timerange: TimeRange;
  render_timerange?: TimeRange;
  desc?: string;
  state?: number;
  speed: number;
  is_loop?: boolean;
  is_tone_modify?: boolean;
  reverse?: boolean;
  intensifies_audio?: boolean;
  cartoon?: boolean;
  volume: number;
  last_nonzero_volume?: number;
  clip?: ClipTransform | null;
  uniform_scale?: UniformScale;
  extra_material_refs: string[];
  render_index: number;
  track_render_index?: number;
  keyframe_refs?: string[];
  enable_lut?: boolean;
  enable_adjust?: boolean;
  enable_hsl?: boolean;
  visible: boolean;
  group_id?: string;
  enable_color_curves?: boolean;
  enable_hsl_curves?: boolean;
  enable_color_wheels?: boolean;
  track_attribute?: number;
  is_placeholder?: boolean;
  template_id?: string;
  template_scene?: string;
  common_keyframes: CommonKeyframeList[];
  source?: string;
  segment_color_tag?: string;
}

export type TrackType =
  | "video"
  | "audio"
  | "text"
  | "sticker"
  | "effect"
  | "filter"
  | "adjust"
  | string;

/**
 * Represents `Track` (`track.cpp`, `0x115fadf14`).
 * Note: `segments` (`0x115fae030`) and `name` (`0x115fae24c`) are strictly
 * required via `json.at()`.
 */
export interface Track {
  id: string;
  type: TrackType;
  segments: Segment[];
  flag: number;
  attribute: number;
  name: string;
  is_default_name?: boolean;
}

export interface CanvasConfig {
  id?: string;
  width: number;
  height: number;
  ratio: string;
  background?: Record<string, unknown> | null;
}

export interface DraftConfig {
  video_mute: boolean;
  maintrack_adsorb?: boolean;
  record_audio_last_index: number;
  extract_audio_last_index: number;
  original_sound_last_index: number;
   sticker_max_index?: number;
  adjust_max_index?: number;
   material_save_mode?: number;
  multi_language_mode?: string;
  subtitle_recognition_id?: string;
  subtitle_sync?: boolean;
  lyrics_recognition_id?: string;
  lyrics_sync?: boolean;
  [key: string]: unknown;
}

export interface PlatformInfo {
  os: string;
  os_version?: string;
  app_id?: number;
  app_version?: string;
  app_source?: string;
  device_id?: string;
  hard_disk_id?: string;
  mac_address?: string;
}

export interface VideoMaterial {
  id: string;
  type: "video" | "photo" | string;
  path: string;
  material_name?: string;
  duration: Microseconds;
  width: number;
  height: number;
  crop_ratio?: string;
  crop_scale?: number;
  extra_type_option?: number;
  [key: string]: unknown;
}

export interface SpeedMaterial {
  id: string;
  type: "speed";
  mode: number;
  speed: number;
  curve_speed?: unknown | null;
}

export interface DraftMaterials {
  videos: VideoMaterial[];
  audios: Record<string, unknown>[];
  texts: Record<string, unknown>[];
  stickers: Record<string, unknown>[];
  speeds: SpeedMaterial[];
  canvases: Record<string, unknown>[];
  transitions: Record<string, unknown>[];
  video_effects: Record<string, unknown>[];
  audio_effects: Record<string, unknown>[];
  flowers?: Record<string, unknown>[];
  tail_leaders?: Record<string, unknown>[];
  [key: string]: unknown;
}

export interface PersistentDraft {
  id: string;
  version: number;
  new_version: string;
  name: string;
  /** Total timeline duration in microseconds (`int64`). */
  duration: Microseconds;
  create_time: number;
  update_time: number;
  fps: number;
  is_drop_frame_timecode: boolean;
  color_space: number;
  canvas_config: CanvasConfig;
  config: DraftConfig;
  tracks: Track[];
  materials: DraftMaterials;
  keyframes: Record<string, unknown[]>;
  keyframe_graph_list?: KeyframeGraph[];
  group_container?: { groups: unknown[] } | null;
  platform: PlatformInfo;
  last_modified_platform: PlatformInfo;
  mutable_config?: unknown | null;
  extra_info?: unknown | null;
  relationships?: unknown[];
  render_index_track_mode_on?: boolean;
  free_render_index_mode_on?: boolean;
  mixed_track_mode_on?: boolean;
  static_cover_image_path?: string;
  source?: string;
  time_marks?: { id?: string; mark_items?: unknown[] } | null;
  path?: string;
  lyrics_effects?: unknown[];
  draft_type?: number;
  is_minimal_draft?: boolean;
  /** Edições exclusivas do MangoCUT (filtros, efeitos, transições e textos). */
  mangocut?: MangoCutExtension;
}

export type FilterId = "noir" | "vintage" | "warm" | "cool" | "vivid" | "contrast";
export type EffectId = "zoomIn" | "zoomOut" | "fadeIn" | "fadeOut" | "blur";
export type TextFont = "system" | "rounded" | "serif" | "mono";

export interface ClipFilter {
  id: FilterId;
  /** 0 = sem efeito, 1 = filtro completo. */
  intensity: number;
}

export interface ClipStyle {
  filter: ClipFilter | null;
  effects: EffectId[];
}

export interface Transition {
  kind: "dissolve";
  durationUs: Microseconds;
}

export interface TextOverlay {
  id: string;
  text: string;
  /** Início no tempo da timeline (o que se vê no player), em µs. */
  startUs: Microseconds;
  durationUs: Microseconds;
  font: TextFont;
  /** Altura da fonte como fração da altura do canvas. */
  size: number;
  /** `#RRGGBB` */
  color: string;
  /** Centro do texto, de 0 a 1 a partir do canto superior esquerdo. */
  x: number;
  y: number;
  background: boolean;
}

/**
 * Bloco `mangocut` do draft. As transições ficam indexadas pelo clipe que vem antes delas.
 */
export interface MangoCutExtension {
  version: 1;
  clipStyles: Record<string, ClipStyle>;
  transitions: Record<string, Transition>;
  texts: TextOverlay[];
}

/**
 * Error bitflags set by `DraftRepairEngine` tasks:
 * - `0x004` (`4`): `SegInErrorTrackRepairTask` (`0x115c90774`)
 * - `0x008` (`8`): `SegTimeConflictRepairTask` (`0x115c9095c`)
 * - `0x800` (`2048`): `DraftDurationRepairTask` (`0x114ec40c4`)
 */
export const DraftErrorFlags = {
  NONE: 0x0,
  SEG_IN_ERROR_TRACK: 0x4,
  SEG_TIME_CONFLICT: 0x8,
  DRAFT_DURATION_ERROR: 0x800,
} as const;

export interface DraftValidationIssue {
  path: string;
  code:
    | "NOT_OBJECT"
    | "MISSING_REQUIRED_KEY"
    | "TYPE_ERROR"
    | "ID_CONFLICT"
    | "DURATION_MISMATCH"
    | "TRACK_MATERIAL_MISMATCH"
    | "SEGMENT_TIME_CONFLICT";
  message: string;
  fatal: boolean;
}

export interface DraftValidationResult {
  valid: boolean;
  fatalExceptionMessage?: string;
  errorMask: number;
  issues: DraftValidationIssue[];
}

export interface DraftRepairReport {
  errorMask: number;
  errorInfo: string[];
  fixInfo: string[];
  repairedDraft: PersistentDraft;
}
