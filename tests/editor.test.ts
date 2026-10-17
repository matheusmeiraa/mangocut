import test from "node:test";
import assert from "node:assert/strict";
import {
  EditorError,
  buildRenderPlan,
  clipAtTime,
  createEditorProject,
  listEditorCommands,
  runEditorCommand,
  validateDraftJson,
  type PersistentDraft,
} from "../src/index.ts";

const s = (seconds: number) => Math.round(seconds * 1_000_000);

/** Projeto com dois clipes: A (4 s) e B (3 s). */
function twoClips(): { draft: PersistentDraft; a: string; b: string } {
  let draft = createEditorProject({ name: "Teste", width: 1080, height: 1920 });
  const first = runEditorCommand(draft, "clip.append", { path: "media/a.mov", name: "a.mov", durationUs: s(4), width: 1080, height: 1920 });
  draft = first.draft;
  const second = runEditorCommand(draft, "clip.append", { path: "media/b.mov", name: "b.mov", durationUs: s(3) });
  return { draft: second.draft, a: first.result.segmentId!, b: second.result.segmentId! };
}

function run(draft: PersistentDraft, id: string, params: Record<string, unknown>) {
  const out = runEditorCommand(draft, id, params);
  const validation = validateDraftJson(out.draft);
  assert.equal(validation.valid, true, `${id} deixou o draft inválido: ${JSON.stringify(validation.issues)}`);
  return out;
}

test("projeto novo e clipes encostados na trilha principal", () => {
  const { draft } = twoClips();
  const plan = buildRenderPlan(draft);
  assert.deepEqual(plan.canvas, { width: 1080, height: 1920 });
  assert.equal(plan.clips.length, 2);
  assert.equal(plan.clips[0]!.timelineStartUs, 0);
  assert.equal(plan.clips[1]!.timelineStartUs, s(4));
  assert.equal(plan.durationUs, s(7));
  assert.equal(plan.clips[0]!.name, "a.mov");
  assert.equal(plan.clips[1]!.path, "media/b.mov");
  assert.equal(draft.duration, s(7));
  assert.deepEqual(plan.warnings, []);
  assert.equal(validateDraftJson(draft).valid, true);
});

test("clip.split divide no instante e mantém a mídia contínua", () => {
  const { draft, a } = twoClips();
  const out = run(draft, "clip.split", { atUs: s(1.5) });
  const [first, second, third] = out.plan.clips;
  assert.equal(out.plan.clips.length, 3);
  assert.equal(first!.segmentId, a);
  assert.equal(first!.timelineDurationUs, s(1.5));
  assert.equal(second!.segmentId, out.result.segmentId);
  assert.equal(second!.timelineStartUs, s(1.5));
  assert.equal(second!.timelineDurationUs, s(2.5));
  assert.equal(second!.sourceStartUs, s(1.5));
  assert.equal(second!.sourceDurationUs, s(2.5));
  assert.equal(third!.timelineStartUs, s(4));
  assert.equal(out.plan.durationUs, s(7));
  // Cada pedaço tem seu próprio material de velocidade
  const segments = out.draft.tracks[0]!.segments;
  assert.notEqual(segments[0]!.extra_material_refs[0], segments[1]!.extra_material_refs[0]);
  assert.throws(() => runEditorCommand(draft, "clip.split", { atUs: s(0.05) }), EditorError);
  assert.throws(() => runEditorCommand(draft, "clip.split", { atUs: s(9) }), /não há clipe/);
});

test("clip.split com velocidade 2x corta a mídia no ponto certo", () => {
  const { draft, a } = twoClips();
  const fast = run(draft, "clip.speed", { segmentId: a, speed: 2 }).draft;
  assert.equal(buildRenderPlan(fast).clips[0]!.timelineDurationUs, s(2));
  const out = run(fast, "clip.split", { atUs: s(0.5) });
  assert.equal(out.plan.clips[0]!.sourceDurationUs, s(1));
  assert.equal(out.plan.clips[1]!.sourceStartUs, s(1));
  assert.equal(out.plan.clips[1]!.sourceDurationUs, s(3));
  assert.equal(out.plan.clips[1]!.speed, 2);
});

test("clip.trim apara o início e o fim e encosta os seguintes", () => {
  const { draft, a } = twoClips();
  const start = run(draft, "clip.trim", { segmentId: a, edge: "start", atUs: s(1) });
  assert.equal(start.plan.clips[0]!.timelineDurationUs, s(3));
  assert.equal(start.plan.clips[0]!.sourceStartUs, s(1));
  assert.equal(start.plan.clips[1]!.timelineStartUs, s(3));
  const end = run(draft, "clip.trim", { segmentId: a, edge: "end", atUs: s(2.5) });
  assert.equal(end.plan.clips[0]!.timelineDurationUs, s(2.5));
  assert.equal(end.plan.clips[0]!.sourceStartUs, 0);
  assert.equal(end.plan.durationUs, s(5.5));
});

test("clip.delete e clip.move refazem a sequência", () => {
  const { draft, a, b } = twoClips();
  const moved = run(draft, "clip.move", { segmentId: b, toIndex: 0 });
  assert.deepEqual(moved.plan.clips.map((c) => c.segmentId), [b, a]);
  assert.equal(moved.plan.clips[1]!.timelineStartUs, s(3));
  const deleted = run(draft, "clip.delete", { segmentId: a });
  assert.equal(deleted.plan.clips.length, 1);
  assert.equal(deleted.plan.clips[0]!.timelineStartUs, 0);
  assert.equal(deleted.plan.durationUs, s(3));
  assert.equal(deleted.draft.duration, s(3));
});

test("clip.speed muda a duração e o material de velocidade", () => {
  const { draft, b } = twoClips();
  const out = run(draft, "clip.speed", { segmentId: b, speed: 0.5 });
  assert.equal(out.plan.clips[1]!.timelineDurationUs, s(6));
  assert.equal(out.plan.durationUs, s(10));
  const segment = out.draft.tracks[0]!.segments[1]!;
  const material = out.draft.materials.speeds.find((m) => m.id === segment.extra_material_refs[0]);
  assert.equal(material?.speed, 0.5);
  assert.throws(() => runEditorCommand(draft, "clip.speed", { segmentId: b, speed: 9 }), /entre 0.25 e 4/);
});

test("filtro, efeitos e transição ficam no bloco mangocut e aparecem no plano", () => {
  const { draft, a, b } = twoClips();
  let out = run(draft, "clip.filter", { segmentId: a, filter: "vintage", intensity: 0.7 });
  out = run(out.draft, "clip.effects", { segmentId: a, effects: ["zoomIn", "fadeIn", "zoomOut"] });
  out = run(out.draft, "clip.transition", { segmentId: a, kind: "dissolve", durationUs: s(0.5) });
  const [clipA, clipB] = out.plan.clips;
  assert.deepEqual(clipA!.filter, { id: "vintage", intensity: 0.7 });
  assert.deepEqual(clipA!.effects, ["fadeIn", "zoomOut"]);
  assert.deepEqual(clipA!.transitionOut, { kind: "dissolve", durationUs: s(0.5) });
  assert.deepEqual(clipB!.transitionIn, { kind: "dissolve", durationUs: s(0.5) });
  // A transição sobrepõe os clipes no plano, mas o draft continua sem sobreposição
  assert.equal(clipB!.timelineStartUs, s(3.5));
  assert.equal(out.plan.durationUs, s(6.5));
  assert.equal(out.draft.tracks[0]!.segments[1]!.target_timerange.start, s(4));
  assert.equal(clipAtTime(out.plan, s(3.7))?.segmentId, b);
  assert.throws(() => runEditorCommand(out.draft, "clip.transition", { segmentId: b, kind: "dissolve" }), /último clipe/);
  assert.throws(() => runEditorCommand(out.draft, "clip.filter", { segmentId: a, filter: "sepia" }), /noir, vintage/);
  const cleared = run(out.draft, "clip.filter", { segmentId: a, filter: null });
  assert.equal(cleared.plan.clips[0]!.filter, null);
  assert.deepEqual(cleared.plan.clips[0]!.effects, ["fadeIn", "zoomOut"]);
});

test("a transição nunca passa da metade de um dos clipes", () => {
  const { draft, a } = twoClips();
  const out = run(draft, "clip.transition", { segmentId: a, kind: "dissolve", durationUs: s(2) });
  assert.equal(out.plan.clips[1]!.transitionIn?.durationUs, s(1.5));
});

test("dividir leva o filtro aos dois pedaços e a transição para o segundo", () => {
  const { draft, a } = twoClips();
  let out = run(draft, "clip.filter", { segmentId: a, filter: "noir" });
  out = run(out.draft, "clip.effects", { segmentId: a, effects: ["fadeIn", "fadeOut"] });
  out = run(out.draft, "clip.transition", { segmentId: a, kind: "dissolve" });
  out = run(out.draft, "clip.split", { atUs: s(2) });
  const [first, second, third] = out.plan.clips;
  assert.equal(first!.filter?.id, "noir");
  assert.equal(second!.filter?.id, "noir");
  assert.deepEqual(first!.effects, ["fadeIn"]);
  assert.deepEqual(second!.effects, ["fadeOut"]);
  assert.equal(first!.transitionOut, null);
  assert.equal(second!.transitionOut?.kind, "dissolve");
  assert.equal(third!.transitionIn?.kind, "dissolve");
});

test("textos: adicionar, alterar e excluir", () => {
  const { draft } = twoClips();
  const added = run(draft, "text.add", { text: "Olá", startUs: s(1), color: "#ffcc00", y: 0.2 });
  const id = added.result.textId!;
  assert.equal(added.plan.texts.length, 1);
  assert.deepEqual(
    { ...added.plan.texts[0]!, id: "" },
    { id: "", text: "Olá", startUs: s(1), durationUs: s(3), font: "system", size: 0.07, color: "#FFCC00", x: 0.5, y: 0.2, background: false },
  );
  const updated = run(added.draft, "text.update", { id, text: "Tchau", font: "serif", background: true });
  assert.equal(updated.plan.texts[0]!.text, "Tchau");
  assert.equal(updated.plan.texts[0]!.font, "serif");
  assert.equal(updated.plan.texts[0]!.background, true);
  assert.throws(() => runEditorCommand(added.draft, "text.update", { id, color: "amarelo" }), /#RRGGBB/);
  assert.throws(() => runEditorCommand(added.draft, "text.update", { id, text: "  " }), /vazio/);
  const deleted = run(updated.draft, "text.delete", { id });
  assert.equal(deleted.plan.texts.length, 0);
});

test("comando desconhecido, parâmetros inválidos e o original intacto", () => {
  const { draft, a } = twoClips();
  const before = JSON.stringify(draft);
  run(draft, "clip.delete", { segmentId: a });
  assert.equal(JSON.stringify(draft), before, "runEditorCommand não pode alterar o draft recebido");
  assert.throws(() => runEditorCommand(draft, "clip.explode", {}), /comando desconhecido/);
  assert.throws(() => runEditorCommand(draft, "clip.delete", { segmentId: "nao-existe" }), /clipe não encontrado/);
  assert.throws(() => runEditorCommand(draft, "clip.split", []), /objeto JSON/);
  assert.ok(listEditorCommands().some((c) => c.id === "clip.split"));
});

test("drafts sem bloco mangocut e com trilhas extras geram plano com aviso", () => {
  const { draft } = twoClips();
  delete draft.mangocut;
  draft.tracks.push({ id: "T2", type: "audio", segments: [draft.tracks[0]!.segments[0]!], flag: 0, attribute: 0, name: "" });
  const plan = buildRenderPlan(draft);
  assert.equal(plan.clips.length, 2);
  assert.equal(plan.clips[0]!.filter, null);
  assert.match(plan.warnings[0]!, /1 trilha\(s\) além da principal/);
});
