import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  Mp4ProbeError,
  getTimelineEndUs,
  probeMp4,
  repairDraft,
  type ByteSource,
  type PersistentDraft,
} from "../src/index.ts";

const CLI = path.resolve(import.meta.dirname, "../bin/mangocut.js");

// ---------------------------------------------------------------------------
// Gerador de MP4 sintético (só as caixas de metadados que o leitor usa)

function u32(n: number): Uint8Array {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, n >>> 0);
  return b;
}
function i32(n: number): Uint8Array {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setInt32(0, n);
  return b;
}
function zeros(n: number): Uint8Array {
  return new Uint8Array(n);
}
function ascii(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}
function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}
function box(type: string, ...payload: Uint8Array[]): Uint8Array {
  const body = concat(...payload);
  return concat(u32(8 + body.length), ascii(type), body);
}

const ONE = 0x10000;
const MATRIX_0 = [ONE, 0, 0, 0, ONE, 0, 0, 0, 0x40000000];
const MATRIX_90 = [0, ONE, 0, -ONE, 0, 0, 0, 0, 0x40000000];

function trak(opts: {
  handler: "vide" | "soun";
  durationMovie: number;
  mediaTimescale: number;
  mediaDuration: number;
  width?: number;
  height?: number;
  matrix?: number[];
  codec?: string;
}): Uint8Array {
  const tkhd = box(
    "tkhd",
    zeros(4), // version 0 + flags
    zeros(8), // creation, modification
    u32(1), // track_ID
    zeros(4), // reserved
    u32(opts.durationMovie),
    zeros(16), // reserved, layer, alternate_group, volume, reserved
    ...(opts.matrix ?? MATRIX_0).map(i32),
    u32((opts.width ?? 0) * 65536),
    u32((opts.height ?? 0) * 65536),
  );
  const mdhd = box("mdhd", zeros(4), zeros(8), u32(opts.mediaTimescale), u32(opts.mediaDuration), zeros(4));
  const hdlr = box("hdlr", zeros(4), zeros(4), ascii(opts.handler), zeros(12), zeros(1));
  const stsd = box("stsd", zeros(4), u32(1), box(opts.codec ?? (opts.handler === "vide" ? "avc1" : "mp4a"), zeros(16)));
  const minf = box("minf", box("stbl", stsd));
  return box("trak", tkhd, box("mdia", mdhd, hdlr, minf));
}

function makeMp4(opts?: { rotate90?: boolean; withAudio?: boolean; moovLast?: boolean }): Uint8Array {
  // 1080x1920 em retrato, gravado como 1920x1080 + matriz de 90° (como no iPhone); 5 s.
  const mvhd = box("mvhd", zeros(4), zeros(8), u32(1000), u32(5200), zeros(80));
  const video = trak({
    handler: "vide",
    durationMovie: 5000,
    mediaTimescale: 30000,
    mediaDuration: 150000,
    width: opts?.rotate90 ? 1920 : 1080,
    height: opts?.rotate90 ? 1080 : 1920,
    matrix: opts?.rotate90 ? MATRIX_90 : MATRIX_0,
    codec: "hvc1",
  });
  const audio = trak({ handler: "soun", durationMovie: 5200, mediaTimescale: 44100, mediaDuration: 229320 });
  const moov = box("moov", mvhd, video, ...(opts?.withAudio ? [audio] : []));
  const ftyp = box("ftyp", ascii("isom"), zeros(4), ascii("isomiso2"));
  const mdat = box("mdat", zeros(4096));
  return opts?.moovLast ? concat(ftyp, mdat, moov) : concat(ftyp, moov, mdat);
}

function bytesSource(bytes: Uint8Array): ByteSource {
  return { size: bytes.length, read: (offset, length) => bytes.subarray(offset, offset + length) };
}

function tmpDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "mangocut-test-"));
}

function cli(...args: string[]): { status: number | null; stdout: string; stderr: string } {
  const r = spawnSync(process.execPath, [CLI, ...args], { encoding: "utf-8" });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr };
}

// ---------------------------------------------------------------------------

test("MP4: duração da trilha de vídeo, rotação 90° troca largura/altura, codec e áudio", () => {
  const info = probeMp4(bytesSource(makeMp4({ rotate90: true, withAudio: true })));
  assert.equal(info.durationUs, 5_000_000); // tkhd (5000 na escala 1000 do mvhd), não o mvhd (5200)
  assert.equal(info.rotation, 90);
  assert.equal(info.width, 1080);
  assert.equal(info.height, 1920);
  assert.equal(info.codec, "hvc1");
  assert.equal(info.hasAudio, true);
});

test("MP4: moov depois do mdat (arquivo sem faststart)", () => {
  const info = probeMp4(bytesSource(makeMp4({ moovLast: true })));
  assert.equal(info.durationUs, 5_000_000);
  assert.equal(info.rotation, 0);
  assert.equal(info.width, 1080);
  assert.equal(info.hasAudio, false);
});

test("MP4: arquivo que não é ISO BMFF ou está truncado gera Mp4ProbeError", () => {
  assert.throws(() => probeMp4(bytesSource(ascii('{"not":"a video"}'))), Mp4ProbeError);
  const full = makeMp4();
  const moovEnd = 8 + 16 + 8; // dentro do moov
  const truncated = full.slice(0, moovEnd + 40);
  assert.throws(() => probeMp4(bytesSource(truncated)), Mp4ProbeError);
});

test("getTimelineEndUs e repairDraft toleram trilhas/segmentos incompletos", () => {
  const partial = {
    duration: 0,
    materials: { videos: [] },
    tracks: [
      { id: "t1", type: "video", segments: [{ id: "a", material_id: "m", target_timerange: { start: 1_000_000, duration: 500_000 } }] },
      { id: "t2", type: "video" },
      { id: "t3", type: "video", segments: [{ id: "b", material_id: "m" }] },
    ],
  } as unknown as PersistentDraft;
  assert.equal(getTimelineEndUs(partial), 1_500_000);
  const report = repairDraft(partial);
  assert.equal(report.repairedDraft.duration, 1_500_000);
  assert.deepEqual(report.repairedDraft.tracks[1]!.segments, []);
  assert.equal(report.repairedDraft.tracks[2]!.segments.length, 1);
  assert.equal(repairDraft({} as PersistentDraft).errorMask, 0);
});

test("CLI: new → info → validate → corrompe → repair", () => {
  const dir = tmpDir();
  const video = path.join(dir, "retrato.mp4");
  const draftFile = path.join(dir, "draft_content.json");
  fs.writeFileSync(video, makeMp4({ rotate90: true, withAudio: true }));

  const created = cli("new", "--video", video, "-o", draftFile, "--fps", "60");
  assert.equal(created.status, 0, created.stderr);
  assert.match(created.stdout, /1080x1920 \(rotação 90°\)/);

  const again = cli("new", "--video", video, "-o", draftFile);
  assert.equal(again.status, 1, "não sobrescreve sem --force");
  assert.match(again.stderr, /--force/);

  const info = cli("info", draftFile, "--json");
  assert.equal(info.status, 0, info.stderr);
  const summary = JSON.parse(info.stdout);
  assert.equal(summary.timelineEndUs, 5_000_000);
  assert.equal(summary.timelineEndSeconds, 5);
  assert.equal(summary.fps, 60);
  assert.deepEqual(summary.canvas, { width: 1080, height: 1920, ratio: "original" });
  assert.equal(summary.tracks.length, 1);
  assert.equal(summary.tracks[0].segments[0].material.label, video);
  assert.equal(summary.validation.valid, true);

  assert.equal(cli("validate", draftFile).status, 0);

  const draft = JSON.parse(fs.readFileSync(draftFile, "utf-8"));
  const seg = draft.tracks[0].segments[0];
  draft.tracks[0].segments.push({ ...structuredClone(seg), id: "MICRO", target_timerange: { start: 4_999_950, duration: 1_000_000 } });
  draft.duration = 1_000_000;
  const broken = path.join(dir, "broken.json");
  fs.writeFileSync(broken, JSON.stringify(draft));

  const invalid = cli("validate", broken);
  assert.equal(invalid.status, 2, "problemas reparáveis saem com código 2");
  assert.match(invalid.stdout, /0x808/);

  const repaired = cli("repair", broken);
  assert.equal(repaired.status, 0, repaired.stderr);
  const out = path.join(dir, "broken.repaired.json");
  assert.ok(fs.existsSync(out));
  const fixed = JSON.parse(fs.readFileSync(out, "utf-8"));
  assert.equal(fixed.tracks[0].segments[1].target_timerange.start, 5_000_100);
  assert.equal(fixed.duration, 6_000_100);
  assert.equal(cli("validate", out).status, 0);
});

test("CLI: erros de uso e arquivos inválidos", () => {
  const dir = tmpDir();
  const notJson = path.join(dir, "x.json");
  fs.writeFileSync(notJson, "{ quebrado");
  assert.equal(cli("info", notJson).status, 1);
  assert.equal(cli("info", path.join(dir, "nao-existe.json")).status, 1);
  assert.equal(cli("new", "--video", notJson, "-o", path.join(dir, "d.json")).status, 1);
  assert.equal(cli("comando-que-nao-existe").status, 1);
  assert.equal(cli("info", "--opcao-errada").status, 1);
  assert.equal(cli("--help").status, 0);
});

test("CLI: run aplica comandos de edição e plan mostra o resultado", () => {
  const dir = tmpDir();
  const video = path.join(dir, "clipe.mp4");
  const draftFile = path.join(dir, "draft_content.json");
  fs.writeFileSync(video, makeMp4());
  assert.equal(cli("new", "--video", video, "-o", draftFile).status, 0);

  assert.equal(cli("run", draftFile, "clip.split", '{"atUs":2000000}').status, 1, "sem -o nem --in-place");
  const split = cli("run", draftFile, "clip.split", '{"atUs":2000000}', "--in-place");
  assert.equal(split.status, 0, split.stderr);
  assert.match(split.stdout, /segmentId: [0-9A-F-]{36}/);

  const added = cli("run", draftFile, "text.add", '{"text":"Oi","startUs":500000}', "-o", draftFile);
  assert.equal(added.status, 0, added.stderr);

  const plan = JSON.parse(cli("plan", draftFile).stdout);
  assert.equal(plan.clips.length, 2);
  assert.equal(plan.clips[1].timelineStartUs, 2_000_000);
  assert.equal(plan.durationUs, 5_000_000);
  assert.equal(plan.texts[0].text, "Oi");
  assert.equal(cli("validate", draftFile).status, 0);

  const bad = cli("run", draftFile, "clip.speed", '{"segmentId":"x","speed":2}', "--in-place");
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /clipe não encontrado/);
  assert.equal(cli("run", draftFile, "clip.split", "{quebrado", "--in-place").status, 1);
  assert.match(cli("commands").stdout, /clip\.transition/);
});
