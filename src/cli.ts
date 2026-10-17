import { closeSync, existsSync, fstatSync, openSync, readFileSync, readSync, writeFileSync } from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import {
  addTrack,
  addVideoSegment,
  createMinimalDraft,
  getTimelineEndUs,
  repairDraft,
  validateDraftJson,
} from "./draft.ts";
import { EditorError, buildRenderPlan, listEditorCommands, runEditorCommand } from "./editor.ts";
import { Mp4ProbeError, probeMp4, type ByteSource, type Mp4VideoInfo } from "./mp4.ts";
import { summarizeDraft, type DraftSummary } from "./summary.ts";
import { microsecondsToSeconds } from "./time.ts";
import {
  DraftErrorFlags,
  type DraftValidationResult,
  type Microseconds,
  type PersistentDraft,
} from "./types.ts";

const HELP = `MangoCUT — motor de timeline para projetos draft_content.json / draft_info.json

Uso:
  mangocut info <draft.json> [--json]
      Resumo do projeto: duração real, trilhas, clipes e keyframes.
  mangocut validate <draft.json> [--json]
      Valida o projeto. Sai com 0 (válido), 2 (problemas reparáveis) ou 1 (erro fatal).
  mangocut repair <draft.json> [-o saida.json] [--pretty]
      Aplica o motor de reparo. Sem -o, grava <nome>.repaired.json ao lado do original.
  mangocut new --video <video.mp4> [-o draft.json] [--name <nome>] [--fps <n>] [--force] [--pretty]
      Cria um projeto com o vídeo na trilha principal (MP4, MOV ou M4V).
  mangocut run <draft.json> <comando> ['{"param": valor}'] (-o saida.json | --in-place) [--pretty]
      Executa um comando de edição (o mesmo que o app usa). Lista em "mangocut commands".
  mangocut plan <draft.json>
      Mostra o plano de render: clipes na ordem, transições, filtros, efeitos e textos.
  mangocut commands
      Lista os comandos de edição.

Opções:
  -h, --help       Mostra esta ajuda
  -v, --version    Mostra a versão
`;

class CliError extends Error {
  readonly exitCode: number;
  constructor(message: string, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

function readVersion(): string {
  // src/cli.ts e dist/cli.js ficam ambos um nível abaixo da raiz do pacote.
  const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf-8"));
  return String(pkg.version);
}

// ---------------------------------------------------------------------------
// Formatação

function seconds(us: Microseconds): string {
  return `${microsecondsToSeconds(us).toFixed(3)}s`;
}

/** `2.24 s (00:02.240)` */
function duration(us: Microseconds): string {
  const totalMs = Math.trunc(us / 1000);
  const min = Math.trunc(totalMs / 60_000);
  const sec = Math.trunc((totalMs % 60_000) / 1000);
  const ms = totalMs % 1000;
  const clock = `${String(min).padStart(2, "0")}:${String(sec).padStart(2, "0")}.${String(ms).padStart(3, "0")}`;
  return `${microsecondsToSeconds(us)} s (${clock})`;
}

function hex(mask: number): string {
  return `0x${mask.toString(16)}`;
}

function maskNames(mask: number): string[] {
  const names: string[] = [];
  if (mask & DraftErrorFlags.DRAFT_DURATION_ERROR) names.push("DRAFT_DURATION_ERROR");
  if (mask & DraftErrorFlags.SEG_IN_ERROR_TRACK) names.push("SEG_IN_ERROR_TRACK");
  if (mask & DraftErrorFlags.SEG_TIME_CONFLICT) names.push("SEG_TIME_CONFLICT");
  return names;
}

function plural(n: number, singular: string, pluralForm = `${singular}s`): string {
  return `${n} ${n === 1 ? singular : pluralForm}`;
}

// ---------------------------------------------------------------------------
// Leitura e escrita

function loadDraft(file: string): { draft: PersistentDraft; validation: DraftValidationResult } {
  if (!existsSync(file)) throw new CliError(`arquivo não encontrado: ${file}`);
  const text = readFileSync(file, "utf-8").replace(/^﻿/, "");
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    throw new CliError(`JSON inválido em ${file}: ${(err as Error).message}`);
  }
  const validation = validateDraftJson(parsed);
  if (validation.fatalExceptionMessage && (typeof parsed !== "object" || parsed === null || Array.isArray(parsed))) {
    throw new CliError(`${file} não é um projeto: ${validation.fatalExceptionMessage}`);
  }
  return { draft: parsed as PersistentDraft, validation };
}

function writeDraft(file: string, draft: PersistentDraft, pretty: boolean): void {
  writeFileSync(file, JSON.stringify(draft, null, pretty ? 2 : undefined) + (pretty ? "\n" : ""));
}

function fileByteSource(fd: number): ByteSource {
  return {
    size: fstatSync(fd).size,
    read(offset, length) {
      const buf = Buffer.alloc(length);
      const bytesRead = readSync(fd, buf, 0, length, offset);
      return buf.subarray(0, bytesRead);
    },
  };
}

function probeVideoFile(file: string): Mp4VideoInfo {
  const fd = openSync(file, "r");
  try {
    return probeMp4(fileByteSource(fd));
  } catch (err) {
    if (err instanceof Mp4ProbeError) {
      throw new CliError(`não foi possível ler ${file}: ${err.message} (formatos aceitos: MP4, MOV, M4V)`);
    }
    throw err;
  } finally {
    closeSync(fd);
  }
}

function printValidation(validation: DraftValidationResult): void {
  if (validation.valid) {
    console.log("Validação: OK");
    return;
  }
  const names = maskNames(validation.errorMask);
  const fatal = validation.issues.filter((i) => i.fatal).length;
  console.log(
    `Validação: ${plural(validation.issues.length, "problema")}` +
      (fatal ? ` (${fatal} fatal)` : "") +
      (validation.errorMask ? ` · máscara ${hex(validation.errorMask)} ${names.join(" | ")}` : ""),
  );
  for (const issue of validation.issues) {
    console.log(`  ${issue.fatal ? "✗" : "!"} ${issue.path}: ${issue.message}`);
  }
}

function printSummary(file: string, s: DraftSummary): void {
  console.log(`Projeto: ${s.name || "(sem nome)"}  ${path.basename(file)}`);
  console.log(`ID: ${s.id || "(sem id)"} · versão ${s.version ?? "?"} (new_version ${s.newVersion ?? "?"})`);
  if (s.canvas) {
    console.log(
      `Canvas: ${s.canvas.width ?? "?"}x${s.canvas.height ?? "?"} (${s.canvas.ratio ?? "?"}) · ${s.fps ?? "?"} fps`,
    );
  }
  console.log(`Duração real: ${duration(s.timelineEndUs)}`);
  if (s.declaredDurationUs !== s.timelineEndUs) {
    console.log(`  (o campo duration declara ${duration(s.declaredDurationUs)})`);
  }
  console.log(
    `${plural(s.totals.tracks, "trilha")} · ${plural(s.totals.segments, "clipe")} · ${plural(s.totals.keyframes, "keyframe")}`,
  );

  for (const track of s.tracks) {
    console.log("");
    console.log(`#${track.index + 1} ${track.type}${track.name ? ` "${track.name}"` : ""} — ${plural(track.segments.length, "clipe")}`);
    track.segments.forEach((seg, i) => {
      const parts = [`${seconds(seg.startUs)} → ${seconds(seg.endUs)} (${seconds(seg.durationUs)})`];
      if (seg.source) parts.push(`fonte ${seconds(seg.source.startUs)}+${seconds(seg.source.durationUs)}`);
      if (seg.speed !== 1) parts.push(`vel. ${seg.speed}x`);
      parts.push(seg.material ? seg.material.label : `material ${seg.materialId || "?"} ausente`);
      console.log(`   [${i + 1}] ${parts.join(" · ")}`);
      const kfs = seg.keyframes.filter((k) => k.count > 0).map((k) => `${k.property} ×${k.count}`);
      if (seg.keyframeRefs) kfs.push(`keyframe_refs ×${seg.keyframeRefs}`);
      if (kfs.length) console.log(`       keyframes: ${kfs.join(", ")}`);
    });
  }
  console.log("");
  printValidation(s.validation);
}

// ---------------------------------------------------------------------------
// Comandos

function cmdInfo(args: string[]): number {
  const { values, positionals } = parseArgs({
    args,
    allowPositionals: true,
    options: { json: { type: "boolean" } },
  });
  const file = positionals[0];
  if (!file) throw new CliError("uso: mangocut info <draft.json> [--json]");
  const { draft, validation } = loadDraft(file);
  const summary = summarizeDraft(draft, validation);
  if (values.json) {
    console.log(JSON.stringify({ ...summary, timelineEndSeconds: microsecondsToSeconds(summary.timelineEndUs) }, null, 2));
  } else {
    printSummary(file, summary);
  }
  return 0;
}

function cmdValidate(args: string[]): number {
  const { values, positionals } = parseArgs({
    args,
    allowPositionals: true,
    options: { json: { type: "boolean" } },
  });
  const file = positionals[0];
  if (!file) throw new CliError("uso: mangocut validate <draft.json> [--json]");
  const { validation } = loadDraft(file);
  if (values.json) console.log(JSON.stringify(validation, null, 2));
  else printValidation(validation);
  if (validation.valid) return 0;
  return validation.fatalExceptionMessage ? 1 : 2;
}

function cmdRepair(args: string[]): number {
  const { values, positionals } = parseArgs({
    args,
    allowPositionals: true,
    options: {
      output: { type: "string", short: "o" },
      pretty: { type: "boolean" },
    },
  });
  const file = positionals[0];
  if (!file) throw new CliError("uso: mangocut repair <draft.json> [-o saida.json]");
  const { draft, validation } = loadDraft(file);
  if (validation.fatalExceptionMessage) {
    printValidation(validation);
    throw new CliError("o projeto tem erro fatal de estrutura; o motor de reparo não se aplica");
  }

  const report = repairDraft(draft);
  if (report.errorMask === DraftErrorFlags.NONE && !values.output) {
    console.log("Nenhum problema encontrado; nada a reparar.");
    return 0;
  }

  console.log(
    report.errorMask === DraftErrorFlags.NONE
      ? "Nenhum problema encontrado."
      : `Problemas: máscara ${hex(report.errorMask)} ${maskNames(report.errorMask).join(" | ")}`,
  );
  for (const info of report.errorInfo) console.log(`  ! ${info.trim()}`);
  for (const fix of report.fixInfo) console.log(`  ✓ ${fix}`);

  const out =
    values.output ??
    path.join(path.dirname(file), `${path.basename(file, path.extname(file))}.repaired.json`);
  writeDraft(out, report.repairedDraft, values.pretty ?? false);

  const after = validateDraftJson(report.repairedDraft);
  console.log(`Gravado: ${out} (duração real ${duration(getTimelineEndUs(report.repairedDraft))})`);
  printValidation(after);
  return 0;
}

function cmdNew(args: string[]): number {
  const { values } = parseArgs({
    args,
    options: {
      video: { type: "string" },
      output: { type: "string", short: "o" },
      name: { type: "string" },
      fps: { type: "string" },
      force: { type: "boolean" },
      pretty: { type: "boolean" },
    },
  });
  if (!values.video) throw new CliError("uso: mangocut new --video <video.mp4> [-o draft.json]");
  const videoPath = path.resolve(values.video);
  if (!existsSync(videoPath)) throw new CliError(`vídeo não encontrado: ${values.video}`);

  const fps = values.fps === undefined ? 30 : Number(values.fps);
  if (!Number.isFinite(fps) || fps <= 0) throw new CliError(`--fps inválido: ${values.fps}`);

  const out = values.output ?? "draft_content.json";
  if (existsSync(out) && !values.force) {
    throw new CliError(`${out} já existe; use --force para sobrescrever`);
  }

  const info = probeVideoFile(videoPath);
  const fileName = path.basename(videoPath);
  const draft = createMinimalDraft({
    name: values.name ?? path.basename(videoPath, path.extname(videoPath)),
    width: info.width,
    height: info.height,
    fps,
  });
  const track = addTrack(draft, "video");
  addVideoSegment(draft, track, {
    path: videoPath,
    materialName: fileName,
    startUs: 0,
    durationUs: info.durationUs,
    width: info.width,
    height: info.height,
  });

  const validation = validateDraftJson(draft);
  if (!validation.valid) {
    printValidation(validation);
    throw new CliError("o projeto gerado não passou na validação (bug do MangoCUT)");
  }
  writeDraft(out, draft, values.pretty ?? false);

  console.log(`Projeto criado: ${out}`);
  console.log(
    `Vídeo: ${fileName} · ${info.width}x${info.height}` +
      (info.rotation ? ` (rotação ${info.rotation}°)` : "") +
      (info.codec ? ` · ${info.codec}` : "") +
      (info.hasAudio ? " · com áudio" : " · sem áudio"),
  );
  console.log(`Duração: ${duration(info.durationUs)} · ${fps} fps`);
  return 0;
}

function cmdRun(args: string[]): number {
  const { values, positionals } = parseArgs({
    args,
    allowPositionals: true,
    options: {
      output: { type: "string", short: "o" },
      "in-place": { type: "boolean" },
      pretty: { type: "boolean" },
    },
  });
  const [file, commandId, paramsText] = positionals;
  if (!file || !commandId) {
    throw new CliError("uso: mangocut run <draft.json> <comando> ['{...}'] (-o saida.json | --in-place)");
  }
  const out = values.output ?? (values["in-place"] ? file : undefined);
  if (!out) throw new CliError("indique onde gravar: -o saida.json ou --in-place");

  let params: unknown = {};
  if (paramsText !== undefined) {
    try {
      params = JSON.parse(paramsText);
    } catch (err) {
      throw new CliError(`parâmetros não são JSON válido: ${(err as Error).message}`);
    }
  }
  const { draft, validation } = loadDraft(file);
  if (validation.fatalExceptionMessage) {
    throw new CliError(`o projeto tem erro fatal de estrutura: ${validation.fatalExceptionMessage}`);
  }

  let edited: ReturnType<typeof runEditorCommand>;
  try {
    edited = runEditorCommand(draft, commandId, params);
  } catch (err) {
    if (err instanceof EditorError) throw new CliError(err.message);
    throw err;
  }
  writeDraft(out, edited.draft, values.pretty ?? false);

  console.log(`${commandId}: ok`);
  for (const [key, value] of Object.entries(edited.result)) console.log(`  ${key}: ${value}`);
  const plan = edited.plan;
  console.log(
    `Gravado: ${out} · ${duration(plan.durationUs)} · ${plural(plan.clips.length, "clipe")} · ${plural(plan.texts.length, "texto")}`,
  );
  return 0;
}

function cmdPlan(args: string[]): number {
  const { positionals } = parseArgs({ args, allowPositionals: true, options: {} });
  const file = positionals[0];
  if (!file) throw new CliError("uso: mangocut plan <draft.json>");
  const { draft } = loadDraft(file);
  console.log(JSON.stringify(buildRenderPlan(draft), null, 2));
  return 0;
}

function cmdCommands(): number {
  for (const { id, label } of listEditorCommands()) console.log(`${id.padEnd(16)} ${label}`);
  return 0;
}

const COMMANDS: Record<string, (args: string[]) => number> = {
  info: cmdInfo,
  validate: cmdValidate,
  repair: cmdRepair,
  new: cmdNew,
  run: cmdRun,
  plan: cmdPlan,
  commands: cmdCommands,
};

export function main(argv: string[]): number {
  const [command, ...rest] = argv;
  if (!command || command === "-h" || command === "--help" || command === "help") {
    process.stdout.write(HELP);
    return command ? 0 : 1;
  }
  if (command === "-v" || command === "--version") {
    console.log(readVersion());
    return 0;
  }
  const run = COMMANDS[command];
  if (!run) {
    console.error(`mangocut: comando desconhecido "${command}"\n`);
    process.stderr.write(HELP);
    return 1;
  }
  try {
    return run(rest);
  } catch (err) {
    if (err instanceof CliError) {
      console.error(`mangocut: ${err.message}`);
      return err.exitCode;
    }
    // Erros de parseArgs (opção desconhecida, valor faltando) têm `code` ERR_PARSE_ARGS_*.
    if (err instanceof Error && String((err as NodeJS.ErrnoException).code ?? "").startsWith("ERR_PARSE_ARGS")) {
      console.error(`mangocut: ${err.message}`);
      return 1;
    }
    throw err;
  }
}
