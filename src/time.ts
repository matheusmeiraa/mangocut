import type { Microseconds } from "./types.ts";

/**
 * 1 second = 1,000,000 microseconds (`int64_t` across all CapCut TimeRange / Keyframe fields).
 */
export const MICROSECONDS_PER_SECOND = 1_000_000;

/**
 * Constant `1000.0` loaded from `__TEXT,__const` at `0x1178f0678` (`0x408f400000000000`).
 */
export const KEYFRAME_TOLERANCE_SCALE = 1000.0;

/**
 * Default keyframe search tolerance (`1000` us = 1 ms) when rational FPS is zero (`0x1150a3214`).
 */
export const DEFAULT_KEYFRAME_TOLERANCE_US: Microseconds = 1000;

/**
 * Wide keyframe search tolerance (`10000` us = 10 ms) when context flag `+41` is set (`0x1150a3240`).
 */
export const WIDE_KEYFRAME_TOLERANCE_US: Microseconds = 10000;

/**
 * Converts seconds to truncated integer microseconds (`int64`).
 */
export function secondsToMicroseconds(seconds: number): Microseconds {
  return Math.trunc(seconds * MICROSECONDS_PER_SECOND);
}

/**
 * Converts microseconds (`int64`) to floating-point seconds.
 */
export function microsecondsToSeconds(us: Microseconds): number {
  return us / MICROSECONDS_PER_SECOND;
}

/**
 * Converts a frame index at a given `fps` to integer microseconds.
 */
export function framesToMicroseconds(frame: number, fps: number): Microseconds {
  if (fps <= 0) {
    throw new RangeError("fps must be greater than 0");
  }
  return Math.trunc((frame * MICROSECONDS_PER_SECOND) / fps);
}

/**
 * Clean-room implementation of `keyframe_utils::get_keyframe_time_tolerance` (`0x1150a31bc`).
 *
 * Binary evidence (`0x1150a31e4`..`0x1150a3248`):
 * - If `wideToleranceMode` (`[x8, #41]`) is true, returns `10000` us (`mov w8, #10000`).
 * - If `fpsNum == 0`, returns `1000` us.
 * - Otherwise computes `trunc(0.5 * 1000.0 * fpsDen / fpsNum)`; if `0`, falls back to `1000` us.
 */
export function computeKeyframeToleranceUs(options?: {
  fpsNum?: number;
  fpsDen?: number;
  wideToleranceMode?: boolean;
}): Microseconds {
  if (options?.wideToleranceMode) {
    return WIDE_KEYFRAME_TOLERANCE_US;
  }
  const fpsNum = options?.fpsNum ?? 0;
  const fpsDen = options?.fpsDen ?? 0;
  if (fpsNum === 0) {
    return DEFAULT_KEYFRAME_TOLERANCE_US;
  }
  const raw = Math.trunc((0.5 * KEYFRAME_TOLERANCE_SCALE * fpsDen) / fpsNum);
  return raw === 0 ? DEFAULT_KEYFRAME_TOLERANCE_US : raw;
}

/**
 * Clean-room implementation of endpoint snapping and linear speed scaling in
 * `keyframe_utils.cpp` (`0x1150a2b18` and `0x1150a2f58`).
 *
 * Binary evidence:
 * - At `0x1150a2c7c`: `cmp x9, #1000; b.hs` -> if `|t| < 1000` us, snaps to `0`.
 * - At `0x1150a2cbc`: `cmp x9, #999; b.hi` -> if `|t - durationUs| <= 999` us, snaps to `durationUs`.
 */
export function snapSegmentOffsetUs(
  timeOffsetUs: Microseconds,
  segmentDurationUs: Microseconds,
): Microseconds {
  if (Math.abs(timeOffsetUs) < 1000) {
    return 0;
  }
  if (Math.abs(timeOffsetUs - segmentDurationUs) <= 999) {
    return segmentDurationUs;
  }
  return timeOffsetUs;
}

/**
 * Maps a material source time (`us`) to segment-local `time_offset` (`us`),
 * applying the endpoint snapping and linear speed division from `0x1150a2b18`..`0x1150a2da8`.
 */
export function mapMaterialToSegmentTimeUs(
  materialTimeUs: Microseconds,
  sourceStartUs: Microseconds,
  segmentDurationUs: Microseconds,
  speed = 1.0,
): Microseconds {
  const effectiveSpeed = speed > 0 ? speed : 1.0;
  const unmappedOffset = Math.trunc((materialTimeUs - sourceStartUs) / effectiveSpeed);
  return snapSegmentOffsetUs(unmappedOffset, segmentDurationUs);
}

/**
 * Maps a segment-local `time_offset` (`us`) back to material source time (`us`),
 * following `0x1150a2f58`..`0x1150a3154`.
 */
export function mapSegmentToMaterialTimeUs(
  segmentOffsetUs: Microseconds,
  sourceStartUs: Microseconds,
  segmentDurationUs: Microseconds,
  speed = 1.0,
): Microseconds {
  const snapped = snapSegmentOffsetUs(segmentOffsetUs, segmentDurationUs);
  const effectiveSpeed = speed > 0 ? speed : 1.0;
  return sourceStartUs + Math.trunc(snapped * effectiveSpeed);
}
