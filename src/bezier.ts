import { computeKeyframeToleranceUs } from "./time.ts";
import type {
  CommonKeyframe,
  CommonKeyframeList,
  GraphPoint,
  Microseconds,
} from "./types.ts";

/*
 * Reimplementação própria (clean-room) das regras recuperadas do binário
 * CapCut iOS 19.7.0. Nenhum trecho decompilado foi copiado; os comentários
 * citam apenas endereços/constantes usados como evidência (ver achados.md).
 */

const f32 = Math.fround;

/**
 * Multiplicação-soma fundida em float32 (equivalente a FMADD Sd).
 * O produto de dois float32 é exato em float64; ocorre um arredondamento
 * em float64 na soma e outro para float32. Pode divergir só em empates
 * patológicos (duplo arredondamento) — ver RELATORIO.md.
 */
function fma32(a: number, b: number, c: number): number {
  return f32(a * b + c);
}

/** `0x117bd3418` = 0x358637bd ≈ 1e-6f */
export const BEZIER_EPSILON_BOUND_F32 = f32(1e-6);
/** `0x117bebae0` = 0x3a83126f ≈ 1e-3f */
export const BEZIER_EPSILON_RESIDUAL_F32 = f32(1e-3);
/** `mov w8, #8` em `0x10e6cf5d4` */
export const BEZIER_MAX_NEWTON_ITERATIONS = 8;
/** `0x117920da0` = 0x3fd5555555555555 */
export const DEGREE_ELEVATION_ONE_THIRD = 1.0 / 3.0;
/** `0x117986658` = 0x3fe5555555555555 */
export const DEGREE_ELEVATION_TWO_THIRDS = 2.0 / 3.0;

export interface HornerCoefficientsF32 {
  a: number;
  b: number;
  c: number;
}

/**
 * Coeficientes de X(t) = t·((a·t + b)·t + c) para controles horizontais
 * normalizados 0, u1, u2, 1 (mesma ordem de operações do helper `0x10e6cfb54`):
 * a = (1 − 3·u2) + 3·u1 ; b = 3·u2 + (−6·u1) ; c = 3·u1
 */
export function hornerCoefficientsF32(u1In: number, u2In: number): HornerCoefficientsF32 {
  const u1 = f32(u1In);
  const u2 = f32(u2In);
  const three = f32(3);
  const a = f32(f32(f32(1) - f32(u2 * three)) + f32(u1 * three));
  const b = f32(f32(u2 * three) + f32(u1 * f32(-6)));
  const c = f32(u1 * three);
  return { a, b, c };
}

function evalX(k: HornerCoefficientsF32, t: number): number {
  return f32(t * fma32(fma32(k.a, t, k.b), t, k.c));
}

export interface SolveResult {
  t: number;
  path: "clamp" | "newton" | "bisection" | "bisection-exhausted";
  iterations: number;
}

/**
 * Resolve X(t) = p em [0,1] (comportamento observado em `0x10e6cf594`):
 * 1. p<0 ou |p|<1e-6 → 0; p>1 ou |p−1|<1e-6 → 1.
 * 2. Newton a partir de t=p, até 8 passos; aceita se |X−p|<1e-3; se
 *    |X'|<1e-6 desiste e vai para bisseção; t limitado a [0,1] a cada passo.
 * 3. Bisseção em [0,1], ponto médio lo + 0.5·(hi−lo); retorna o ponto médio
 *    quando |X(mid)−p|<1e-3. Se o intervalo cair abaixo de 1e-6 sem
 *    convergir, retorna o último t do Newton (limitado a ≤ 1).
 */
export function solveBezierParameterF32(pIn: number, k: HornerCoefficientsF32): SolveResult {
  const p = f32(pIn);
  const one = f32(1);
  if (p < 0 || f32(Math.abs(p)) < BEZIER_EPSILON_BOUND_F32) {
    return { t: 0, path: "clamp", iterations: 0 };
  }
  if (p > one || f32(Math.abs(f32(p - one))) < BEZIER_EPSILON_BOUND_F32) {
    return { t: one, path: "clamp", iterations: 0 };
  }

  const threeA = f32(k.a * f32(3));
  const twoB = f32(k.b + k.b);
  let t = p;
  let iterations = 0;
  let goBisect = false;
  for (let i = 0; i < BEZIER_MAX_NEWTON_ITERATIONS; i++) {
    iterations++;
    const x = evalX(k, t);
    if (f32(Math.abs(f32(x - p))) < BEZIER_EPSILON_RESIDUAL_F32) {
      return { t, path: "newton", iterations };
    }
    const d = fma32(fma32(threeA, t, twoB), t, k.c);
    if (f32(Math.abs(d)) < BEZIER_EPSILON_BOUND_F32) {
      goBisect = true;
      break;
    }
    t = f32(t - f32(f32(x - p) / d));
    t = Math.min(t, one); // fminnm
    t = Math.max(t, 0); // fmaxnm
  }
  void goBisect;

  let lo = f32(0);
  let hi = one;
  const half = f32(0.5);
  while (lo < hi && f32(Math.abs(f32(hi - lo))) > BEZIER_EPSILON_BOUND_F32) {
    const mid = fma32(f32(hi - lo), half, lo);
    const x = evalX(k, mid);
    if (x < p) lo = mid;
    else hi = mid;
    if (f32(Math.abs(f32(x - p))) < BEZIER_EPSILON_RESIDUAL_F32) {
      return { t: mid, path: "bisection", iterations };
    }
  }
  return { t: t > one ? one : t, path: "bisection-exhausted", iterations };
}

export interface CubicBezierEval {
  y: number;
  t: number;
  path: SolveResult["path"];
}

/**
 * Avalia a curva de easing como em `bef_swing_interpolation_cubic_bezier_static`
 * (`0x10e6cf4b4`): recebe 4 pontos (x,y) e o progresso **já normalizado** p ∈ [0,1]
 * (a função não normaliza p; quem normaliza é o chamador).
 * Y(t) = ((u²·y0)·u + u·u·3·y1·t) ... na ordem exata de fmul/fmadd observada.
 */
export function evaluateCubicBezierF32(
  x0In: number, y0In: number,
  x1In: number, y1In: number,
  x2In: number, y2In: number,
  x3In: number, y3In: number,
  pIn: number,
): CubicBezierEval {
  const [x0, y0, x1, y1, x2, y2, x3, y3] = [x0In, y0In, x1In, y1In, x2In, y2In, x3In, y3In].map(f32) as [
    number, number, number, number, number, number, number, number,
  ];
  const dx = f32(x3 - x0);
  const u1 = f32(f32(x1 - x0) / dx);
  const u2 = f32(f32(x2 - x0) / dx);
  const solved = solveBezierParameterF32(pIn, hornerCoefficientsF32(u1, u2));
  const t = f32(solved.t);
  const u = f32(f32(1) - t);
  const three = f32(3);

  const s2a = f32(u * f32(u * y0)); // u²·y0
  const s4 = f32(u * f32(u * f32(f32(y1 * three) * t))); // 3·y1·t·u²
  const acc1 = fma32(s2a, u, s4); // u³·y0 + 3·y1·t·u²
  const s3 = f32(t * f32(f32(y2 * three) * t)); // 3·y2·t²
  const acc2 = fma32(s3, u, acc1);
  const s2b = f32(t * f32(t * y3)); // t²·y3
  const y = fma32(s2b, t, acc2);
  return { y, t, path: solved.path };
}

/**
 * Expansão de `graph_points` (normalizados em [0,1]²) entre dois keyframes em
 * sub-keyframes (regra observada em `0x116012e68`). Com exatamente 1 ponto de
 * controle Q entre âncoras P0 e P2, eleva Bézier quadrática a cúbica:
 * C1 = ⅓P0 + ⅔Q ; C2 = ⅔Q + ⅓P2. Com ≥2 controles usa os dois primeiros.
 */
export function expandGraphPointsToSubKeyframes(
  leftKf: CommonKeyframe,
  rightKf: CommonKeyframe,
  graphPoints: GraphPoint[],
): CommonKeyframe[] {
  if (!graphPoints || graphPoints.length === 0) return [leftKf, rightKf];

  const tL = leftKf.time_offset;
  const dt = rightKf.time_offset - tL;
  const dim = Math.min(leftKf.values.length, rightKf.values.length);

  interface Anchor { t: number; v: number[]; ctrls: { t: number; v: number[] }[] }
  const anchors: Anchor[] = [];
  for (const gp of graphPoints) {
    const t = Math.trunc(tL + gp.point.x * dt);
    const v: number[] = [];
    for (let i = 0; i < dim; i++) {
      const a = leftKf.values[i]!;
      const b = rightKf.values[i]!;
      v.push(a + gp.point.y * (b - a));
    }
    if (gp.type === "on" || anchors.length === 0) anchors.push({ t, v, ctrls: [] });
    else anchors[anchors.length - 1]!.ctrls.push({ t, v });
  }
  if (anchors.length < 2) return [leftKf, rightKf];

  const out: CommonKeyframe[] = anchors.map((a, i) => ({
    id: `${leftKf.id}_sub_${i}`,
    curveType: "Line",
    time_offset: a.t,
    left_control: { x: 0, y: 0 },
    right_control: { x: 0, y: 0 },
    values: [...a.v],
    string_value: "",
    graph: null,
  }));

  for (let i = 0; i < anchors.length - 1; i++) {
    const p0 = anchors[i]!;
    const p2 = anchors[i + 1]!;
    const o = out[i]!;
    const n = out[i + 1]!;
    if (p0.ctrls.length === 0) continue;
    let c1: { t: number; v: number }, c2: { t: number; v: number };
    if (p0.ctrls.length === 1) {
      const q = p0.ctrls[0]!;
      c1 = {
        t: DEGREE_ELEVATION_ONE_THIRD * p0.t + DEGREE_ELEVATION_TWO_THIRDS * q.t,
        v: DEGREE_ELEVATION_ONE_THIRD * (p0.v[0] ?? 0) + DEGREE_ELEVATION_TWO_THIRDS * (q.v[0] ?? 0),
      };
      c2 = {
        t: DEGREE_ELEVATION_TWO_THIRDS * q.t + DEGREE_ELEVATION_ONE_THIRD * p2.t,
        v: DEGREE_ELEVATION_TWO_THIRDS * (q.v[0] ?? 0) + DEGREE_ELEVATION_ONE_THIRD * (p2.v[0] ?? 0),
      };
    } else {
      c1 = { t: p0.ctrls[0]!.t, v: p0.ctrls[0]!.v[0] ?? 0 };
      c2 = { t: p0.ctrls[1]!.t, v: p0.ctrls[1]!.v[0] ?? 0 };
    }
    o.curveType = "Cubic";
    o.right_control = { x: c1.t - p0.t, y: c1.v - (p0.v[0] ?? 0) };
    n.left_control = { x: c2.t - p2.t, y: c2.v - (p2.v[0] ?? 0) };
  }
  return out;
}

export interface InterpolationOptions {
  fpsNum?: number;
  fpsDen?: number;
  wideToleranceMode?: boolean;
}

/**
 * Avalia uma lista de keyframes em `queryTimeUs` (µs relativos ao segmento):
 * - ordena por `time_offset`; acerto dentro da tolerância → valores exatos;
 * - antes do primeiro / depois do último → valor constante (clamp);
 * - ambos "Line" e sem graph_points → lerp em float64 (`0x11509391c`);
 * - caso contrário → Bézier cúbica: p = double(t−tL)/double(tR−tL) convertido
 *   para float (`fdiv d0; fcvt s8` antes de `0x115093b18`), controles
 *   absolutos x1 = tL + right_control.x, x2 = tR + left_control.x (idem y).
 */
export function interpolateKeyframesAtTime(
  keyframes: CommonKeyframe[],
  queryTimeUs: Microseconds,
  options?: InterpolationOptions,
): number[] {
  if (!keyframes || keyframes.length === 0) return [];
  const sorted = [...keyframes].sort((a, b) => a.time_offset - b.time_offset);
  const tol = computeKeyframeToleranceUs(options);

  for (const kf of sorted) {
    if (kf.time_offset >= queryTimeUs - tol && kf.time_offset <= queryTimeUs + tol) {
      return [...kf.values];
    }
  }
  const first = sorted[0]!;
  const last = sorted[sorted.length - 1]!;
  if (queryTimeUs < first.time_offset) return [...first.values];
  if (queryTimeUs > last.time_offset) return [...last.values];

  let L = first;
  let R = last;
  for (let i = 0; i < sorted.length - 1; i++) {
    if (queryTimeUs >= sorted[i]!.time_offset && queryTimeUs <= sorted[i + 1]!.time_offset) {
      L = sorted[i]!;
      R = sorted[i + 1]!;
      break;
    }
  }

  const gps = R.graph?.graph_points;
  if (gps && gps.length >= 2) {
    const sub = expandGraphPointsToSubKeyframes(L, R, gps);
    return interpolateKeyframesAtTime(sub, queryTimeUs, { fpsNum: 0 });
  }

  const dim = Math.min(L.values.length, R.values.length);
  const isLine = (k: CommonKeyframe) => !k.curveType || k.curveType === "Line";
  const span = R.time_offset - L.time_offset;
  const alpha = (queryTimeUs - L.time_offset) / span;

  if (isLine(L) && isLine(R)) {
    const out: number[] = [];
    for (let i = 0; i < dim; i++) out.push(L.values[i]! + alpha * (R.values[i]! - L.values[i]!));
    return out;
  }

  const p = f32(alpha);
  const out: number[] = [];
  for (let i = 0; i < dim; i++) {
    const y0 = L.values[i]!;
    const y3 = R.values[i]!;
    const r = evaluateCubicBezierF32(
      L.time_offset, y0,
      L.time_offset + (L.right_control?.x ?? 0), y0 + (L.right_control?.y ?? 0),
      R.time_offset + (R.left_control?.x ?? 0), y3 + (R.left_control?.y ?? 0),
      R.time_offset, y3,
      p,
    );
    out.push(r.y);
  }
  return out;
}

/** Avalia todas as propriedades `common_keyframes` de um segmento. */
export function evaluateSegmentKeyframes(
  commonKeyframes: CommonKeyframeList[],
  timeOffsetUs: Microseconds,
  options?: InterpolationOptions,
): Record<string, number[]> {
  const result: Record<string, number[]> = {};
  for (const prop of commonKeyframes) {
    result[prop.property_type] = interpolateKeyframesAtTime(prop.keyframe_list, timeOffsetUs, options);
  }
  return result;
}
