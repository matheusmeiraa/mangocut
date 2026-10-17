import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {
  createMinimalDraft,
  addTrack,
  addVideoSegment,
  addKeyframeToSegment,
  validateDraftJson,
  repairDraft,
  secondsToMicroseconds,
  microsecondsToSeconds,
  framesToMicroseconds,
  computeKeyframeToleranceUs,
  snapSegmentOffsetUs,
  mapSegmentToMaterialTimeUs,
  mapMaterialToSegmentTimeUs,
  hornerCoefficientsF32,
  solveBezierParameterF32,
  evaluateCubicBezierF32,
  expandGraphPointsToSubKeyframes,
  interpolateKeyframesAtTime,
  evaluateSegmentKeyframes,
  DraftErrorFlags,
  type CommonKeyframe,
  type GraphPoint,
} from "../src/index.ts";

const BUNDLE_DIR = path.resolve(
  import.meta.dirname,
  "../app/Payload/CapCut.app",
);

// O bundle do app não é distribuído com o repositório; sem ele (ex.: no CI) este teste é pulado.
const BUNDLE_MISSING = !fs.existsSync(BUNDLE_DIR) && "bundle do CapCut ausente em app/ (não é distribuído)";

test("Fase 1: Carregamento de projetos reais do bundle CapCut iOS 19.7.0", { skip: BUNDLE_MISSING }, () => {
  const tpl2Path = path.join(
    BUNDLE_DIR,
    "LVEditor.bundle/CollageResource.bundle/split_screen_2/template.json",
  );
  const tpl9Path = path.join(
    BUNDLE_DIR,
    "LVEditor.bundle/CollageResource.bundle/split_screen_9/template.json",
  );

  assert.ok(fs.existsSync(tpl2Path), "split_screen_2/template.json deve existir no bundle");
  assert.ok(fs.existsSync(tpl9Path), "split_screen_9/template.json deve existir no bundle");

  const raw2 = fs.readFileSync(tpl2Path, "utf-8");
  const res2 = validateDraftJson(raw2);
  assert.equal(res2.fatalExceptionMessage, undefined);
  assert.ok(res2.valid, "split_screen_2 deve ser válido");

  const raw9 = fs.readFileSync(tpl9Path, "utf-8");
  const res9 = validateDraftJson(raw9);
  assert.equal(res9.fatalExceptionMessage, undefined);
  assert.ok(res9.valid, "split_screen_9 deve ser válido");
});

test("Fase 2: Validação de raiz e exceções do parser JSON", () => {
  // Raiz não-objeto (0x115a00a14 .. 0x115a00a50: "json::parse failed: not object issue!")
  const arrayRoot = validateDraftJson("[1, 2, 3]");
  assert.equal(arrayRoot.valid, false);
  assert.match(arrayRoot.fatalExceptionMessage ?? "", /not object issue/);

  // String inválida (exceção de parse)
  const badJson = validateDraftJson("{ broken json");
  assert.equal(badJson.valid, false);
  assert.match(badJson.fatalExceptionMessage ?? "", /json::parse failed/);
});

test("Fase 2: Unidades de tempo (microssegundos), tolerância e snapping", () => {
  // 1 segundo = 1.000.000 microssegundos
  assert.equal(secondsToMicroseconds(1.5), 1_500_000);
  assert.equal(microsecondsToSeconds(2_240_000), 2.24);
  assert.equal(framesToMicroseconds(30, 30), 1_000_000);

  // Tolerância de frame (0x1150a31bc):
  // default (fpsNum == 0) -> 1000 us (1 ms)
  assert.equal(computeKeyframeToleranceUs(), 1000);
  // wide mode -> 10000 us (10 ms)
  assert.equal(computeKeyframeToleranceUs({ wideToleranceMode: true }), 10000);
  // 30 fps fracionário (fpsNum = 30, fpsDen = 1) -> 0.5 * 1000 * 1 / 30 = 16 us
  assert.equal(computeKeyframeToleranceUs({ fpsNum: 30, fpsDen: 1 }), 16);

  // Snapping de extremidades (0x1150a2c7c e 0x1150a2cbc):
  // |t| < 1000 us -> snap para 0
  assert.equal(snapSegmentOffsetUs(450, 5_000_000), 0);
  assert.equal(snapSegmentOffsetUs(-450, 5_000_000), 0);
  assert.equal(snapSegmentOffsetUs(1200, 5_000_000), 1200);

  // |t - duration| <= 999 us -> snap para duration
  assert.equal(snapSegmentOffsetUs(4_999_500, 5_000_000), 5_000_000);
  assert.equal(snapSegmentOffsetUs(5_000_200, 5_000_000), 5_000_000);
  assert.equal(snapSegmentOffsetUs(4_998_000, 5_000_000), 4_998_000);

  // Mapeamento de velocidade com snapping
  const matTime = mapSegmentToMaterialTimeUs(200, 0, 10_000_000, 2.0); // 200 us snap para 0
  assert.equal(matTime, 0);

  const segTime = mapMaterialToSegmentTimeUs(2_000_000, 0, 5_000_000, 2.0);
  assert.equal(segTime, 1_000_000);
});

test("Fase 2: Motor de reparo automático (DraftRepairEngine e as 3 Tasks)", () => {
  const draft = createMinimalDraft();
  const track = addTrack(draft, "video");

  // Adiciona segmento que vai até 3.000.000 us (excede draft.duration de 1.000.000 us)
  addVideoSegment(draft, track, {
    path: "/tmp/test.mp4",
    startUs: 0,
    durationUs: 3_000_000,
  });
  // Força draft.duration para trás para testar DraftDurationRepairTask (0x800)
  draft.duration = 1_000_000;

  // Task 1: DraftDurationRepairTask (0x114ec4058, bitflag 0x800)
  const validation1 = validateDraftJson(draft);
  assert.ok((validation1.errorMask & DraftErrorFlags.DRAFT_DURATION_ERROR) !== 0);

  // Task 2: SegInErrorTrackRepairTask (0x115c90724, bitflag 0x4)
  const audioTrack = addTrack(draft, "audio");
  const badSeg = addVideoSegment(draft, audioTrack, {
    path: "/tmp/bad.mp4",
    startUs: 0,
    durationUs: 500_000,
  });
  // Vincula material de vídeo em trilha de áudio
  assert.equal(audioTrack.segments.length, 1);

  // Task 3: SegTimeConflictRepairTask (0x115c90870, bitflag 0x8)
  // Adiciona segmento com micro-sobreposição de 50 us (<= 99 us) na trilha de vídeo
  // Seg 1: [0, 3_000_000]
  // Seg 2: [2_999_950, 3_999_950] -> overlap delta = -50 us >= -99 us
  const microConflictSeg = addVideoSegment(draft, track, {
    path: "/tmp/test2.mp4",
    startUs: 2_999_950,
    durationUs: 1_000_000,
  });
  // Simula arquivo corrompido/desatualizado com duration menor que o fim dos clipes
  draft.duration = 1_000_000;

  const validationFull = validateDraftJson(draft);
  assert.ok((validationFull.errorMask & DraftErrorFlags.DRAFT_DURATION_ERROR) !== 0);
  assert.ok((validationFull.errorMask & DraftErrorFlags.SEG_IN_ERROR_TRACK) !== 0);
  assert.ok((validationFull.errorMask & DraftErrorFlags.SEG_TIME_CONFLICT) !== 0);

  // Executa o DraftRepairEngine
  const report = repairDraft(draft);
  assert.ok((report.errorMask & DraftErrorFlags.DRAFT_DURATION_ERROR) !== 0);
  assert.ok((report.errorMask & DraftErrorFlags.SEG_IN_ERROR_TRACK) !== 0);
  assert.ok((report.errorMask & DraftErrorFlags.SEG_TIME_CONFLICT) !== 0);

  // 1. Duração corrigida para cobrir até o fim do último segmento
  assert.ok(report.repairedDraft.duration >= 4_000_000);

  // 2. Segmento incompatível removido da trilha de áudio
  const repairedAudioTrack = report.repairedDraft.tracks.find((t) => t.type === "audio");
  assert.equal(repairedAudioTrack?.segments.length, 0);

  // 3. Micro-sobreposição corrigida deslocando start para prev_end + 100 us (0x115c90aa4)
  const repairedVideoTrack = report.repairedDraft.tracks.find((t) => t.type === "video")!;
  const seg2 = repairedVideoTrack.segments.find((s) => s.id === microConflictSeg.id)!;
  assert.equal(seg2.target_timerange.start, 3_000_000 + 100);
});

test("Fase 2: Solver de Curvas Cubic Bézier (bef_swing_interpolation_cubic_bezier_static)", () => {
  // Coeficientes de Horner (0x10e6cfb54)
  const coeffs = hornerCoefficientsF32(0.42, 0.58);
  assert.ok(Number.isFinite(coeffs.a));
  assert.ok(Number.isFinite(coeffs.b));
  assert.ok(Number.isFinite(coeffs.c));

  // Simetria no ponto médio (EaseInOut: u1=0.42, u2=0.58 em p=0.5 deve dar t=0.5 e Y=0.5)
  const evalMid = evaluateCubicBezierF32(
    0, 0,
    0.42, 0,
    0.58, 1,
    1, 1,
    0.5,
  );
  assert.equal(evalMid.path, "newton");
  assert.ok(Math.abs(evalMid.t - 0.5) < 1e-3);
  assert.ok(Math.abs(evalMid.y - 0.5) < 1e-3);

  // Clamping de fronteira (p <= 0 -> 0, p >= 1 -> 1)
  const evalZero = evaluateCubicBezierF32(0, 0, 0.25, 0.1, 0.75, 0.9, 1, 1, 0.0);
  assert.equal(evalZero.path, "clamp");
  assert.equal(evalZero.t, 0.0);
  assert.equal(evalZero.y, 0.0);

  const evalOne = evaluateCubicBezierF32(0, 0, 0.25, 0.1, 0.75, 0.9, 1, 1, 1.0);
  assert.equal(evalOne.path, "clamp");
  assert.equal(evalOne.t, 1.0);
  assert.equal(evalOne.y, 1.0);

  // Curva extrema com derivada zero que força o fallback de bisseção (0x10e6cf650)
  // u1 = 0, u2 = 0 gera derivada inicial nula em t=0
  const solveBisect = solveBezierParameterF32(0.3, hornerCoefficientsF32(0, 0));
  assert.ok(solveBisect.iterations > 0);
  assert.ok(solveBisect.t >= 0 && solveBisect.t <= 1);
});

test("Fase 2: Elevação de grau Quadrática -> Cúbica (1/3, 2/3) em graph_points", () => {
  const kf0: CommonKeyframe = {
    id: "kf0",
    curveType: "Line",
    time_offset: 0,
    left_control: { x: 0, y: 0 },
    right_control: { x: 0, y: 0 },
    values: [0.0],
    string_value: "",
    graph: null,
  };
  const kf1: CommonKeyframe = {
    id: "kf1",
    curveType: "Line",
    time_offset: 1_000_000,
    left_control: { x: 0, y: 0 },
    right_control: { x: 0, y: 0 },
    values: [100.0],
    string_value: "",
    graph: null,
  };

  // 1 ponto off-curve entre 2 on-curves: P0=(0,0), Q1=(0.5, 0.8), P2=(1.0, 1.0)
  const gps: GraphPoint[] = [
    { id: "p0", type: "on", point: { x: 0.0, y: 0.0 } },
    { id: "q1", type: "off", point: { x: 0.5, y: 0.8 } },
    { id: "p2", type: "on", point: { x: 1.0, y: 1.0 } },
  ];

  const subKfs = expandGraphPointsToSubKeyframes(kf0, kf1, gps);
  assert.equal(subKfs.length, 2);
  assert.equal(subKfs[0]!.curveType, "Cubic");

  // C1 = 1/3 * P0 + 2/3 * Q1 = 2/3 * (0.5 * 1_000_000) = 333333.33 us
  // right_control = C1 - P0 = 333333.33 us
  const expectedC1x = (2.0 / 3.0) * 500_000;
  assert.ok(Math.abs(subKfs[0]!.right_control.x - expectedC1x) < 1.0);
  const expectedC1y = (2.0 / 3.0) * 80.0;
  assert.ok(Math.abs(subKfs[0]!.right_control.y - expectedC1y) < 1e-4);
});

test("Fase 2: Interpolação de keyframes fim a fim (Linear vs Bézier)", () => {
  const kfs: CommonKeyframe[] = [
    {
      id: "k1",
      curveType: "Line",
      time_offset: 0,
      left_control: { x: 0, y: 0 },
      right_control: { x: 0, y: 0 },
      values: [0.0],
      string_value: "",
      graph: null,
    },
    {
      id: "k2",
      curveType: "Line",
      time_offset: 1_000_000,
      left_control: { x: 0, y: 0 },
      right_control: { x: 0, y: 0 },
      values: [100.0],
      string_value: "",
      graph: null,
    },
  ];

  // Acerto exato (dentro da janela de tolerância de 1000 us)
  const hitExact = interpolateKeyframesAtTime(kfs, 500); // 500 us <= 1000 us de offset 0
  assert.equal(hitExact[0], 0.0);

  // Clamping antes do primeiro e depois do último
  const clampLeft = interpolateKeyframesAtTime(kfs, -500_000);
  assert.equal(clampLeft[0], 0.0);

  const clampRight = interpolateKeyframesAtTime(kfs, 2_000_000);
  assert.equal(clampRight[0], 100.0);

  // Interpolação linear pura no meio do caminho (500.000 us)
  const midLinear = interpolateKeyframesAtTime(kfs, 500_000);
  assert.equal(midLinear[0], 50.0);

  // Avaliação de propriedade em segmento
  const propResult = evaluateSegmentKeyframes(
    [
      {
        id: "prop1",
        property_type: "KFTypeScaleX",
        keyframe_list: kfs,
      },
    ],
    250_000,
  );
  assert.equal(propResult["KFTypeScaleX"]![0], 25.0);
});
