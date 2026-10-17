import type { Microseconds } from "./types.ts";

/*
 * Leitor mínimo de metadados ISO BMFF (MP4 / MOV / M4V), sem dependências.
 * Lê só as caixas necessárias para montar um material de vídeo:
 * moov/mvhd, moov/trak/tkhd, trak/mdia/{hdlr,mdhd} e o primeiro sample entry de stsd.
 * Não decodifica mídia e não lê `mdat`.
 */

/** Acesso aleatório aos bytes do arquivo (permite ler arquivos grandes sem carregá-los inteiros). */
export interface ByteSource {
  size: number;
  read(offset: number, length: number): Uint8Array;
}

export interface Mp4VideoInfo {
  durationUs: Microseconds;
  /** Largura de exibição (já considerando a rotação da matriz do `tkhd`). */
  width: number;
  /** Altura de exibição (já considerando a rotação da matriz do `tkhd`). */
  height: number;
  rotation: 0 | 90 | 180 | 270;
  /** FourCC do primeiro sample entry de vídeo (`avc1`, `hvc1`, `hev1`, ...). */
  codec?: string;
  hasAudio: boolean;
}

export class Mp4ProbeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "Mp4ProbeError";
  }
}

/** Limite para o tamanho da caixa `moov` lida na memória (256 MiB). */
const MAX_MOOV_BYTES = 256 * 1024 * 1024;

interface Box {
  type: string;
  /** Início do conteúdo (depois do cabeçalho). */
  start: number;
  /** Fim exclusivo da caixa. */
  end: number;
}

function fourcc(bytes: Uint8Array, offset: number): string {
  return String.fromCharCode(bytes[offset]!, bytes[offset + 1]!, bytes[offset + 2]!, bytes[offset + 3]!);
}

function readBoxHeader(
  header: Uint8Array,
  boxOffset: number,
  parentEnd: number,
): Box | null {
  if (header.length < 8) return null;
  const view = new DataView(header.buffer, header.byteOffset, header.byteLength);
  let size = view.getUint32(0);
  const type = fourcc(header, 4);
  let headerSize = 8;
  if (size === 1) {
    if (header.length < 16) return null;
    size = Number(view.getBigUint64(8));
    headerSize = 16;
  } else if (size === 0) {
    size = parentEnd - boxOffset;
  }
  if (size < headerSize || boxOffset + size > parentEnd) return null;
  return { type, start: boxOffset + headerSize, end: boxOffset + size };
}

/** Itera caixas filhas dentro de um buffer já carregado. */
function* childBoxes(buf: Uint8Array, start: number, end: number): Generator<Box> {
  let offset = start;
  while (offset + 8 <= end) {
    const box = readBoxHeader(buf.subarray(offset, Math.min(offset + 16, end)), offset, end);
    if (!box) return;
    yield box;
    offset = box.end;
  }
}

function findChild(buf: Uint8Array, parent: Box, type: string): Box | undefined {
  for (const box of childBoxes(buf, parent.start, parent.end)) {
    if (box.type === type) return box;
  }
  return undefined;
}

/** Lê os campos (timescale, duration) de `mvhd`/`mdhd`, que têm o mesmo layout inicial. */
function readTimescaleAndDuration(view: DataView, box: Box): { timescale: number; duration: bigint } {
  const version = view.getUint8(box.start);
  if (version === 1) {
    return {
      timescale: view.getUint32(box.start + 4 + 16),
      duration: view.getBigUint64(box.start + 4 + 20),
    };
  }
  return {
    timescale: view.getUint32(box.start + 4 + 8),
    duration: BigInt(view.getUint32(box.start + 4 + 12)),
  };
}

interface TrackHeader {
  duration: bigint;
  width: number;
  height: number;
  rotation: Mp4VideoInfo["rotation"];
}

function readTrackHeader(view: DataView, box: Box): TrackHeader {
  const version = view.getUint8(box.start);
  // v0: creation(4) modification(4) track_ID(4) reserved(4) duration(4)
  // v1: creation(8) modification(8) track_ID(4) reserved(4) duration(8)
  const durationOffset = box.start + 4 + (version === 1 ? 24 : 16);
  const duration = version === 1 ? view.getBigUint64(durationOffset) : BigInt(view.getUint32(durationOffset));
  const afterDuration = durationOffset + (version === 1 ? 8 : 4);
  // reserved(8) layer(2) alternate_group(2) volume(2) reserved(2) matrix(36) width(4) height(4)
  const matrixOffset = afterDuration + 16;
  const a = view.getInt32(matrixOffset);
  const b = view.getInt32(matrixOffset + 4);
  const c = view.getInt32(matrixOffset + 12);
  const d = view.getInt32(matrixOffset + 16);
  const width = view.getUint32(matrixOffset + 36) / 65536;
  const height = view.getUint32(matrixOffset + 40) / 65536;

  const ONE = 0x10000;
  let rotation: Mp4VideoInfo["rotation"] = 0;
  if (a === 0 && d === 0 && b === ONE && c === -ONE) rotation = 90;
  else if (a === 0 && d === 0 && b === -ONE && c === ONE) rotation = 270;
  else if (a === -ONE && d === -ONE) rotation = 180;

  return { duration, width: Math.round(width), height: Math.round(height), rotation };
}

function toMicroseconds(duration: bigint, timescale: number): Microseconds {
  if (timescale <= 0) return 0;
  return Number((duration * 1_000_000n) / BigInt(timescale));
}

/** Localiza a caixa `moov` no nível superior e devolve o conteúdo dela em memória. */
function loadMoov(source: ByteSource): { buf: Uint8Array; moov: Box } {
  let offset = 0;
  let sawFtyp = false;
  while (offset + 8 <= source.size) {
    const header = source.read(offset, Math.min(16, source.size - offset));
    const box = readBoxHeader(header, offset, source.size);
    if (!box) break;
    if (box.type === "ftyp") sawFtyp = true;
    if (box.type === "moov") {
      const length = box.end - offset;
      if (length > MAX_MOOV_BYTES) {
        throw new Mp4ProbeError(`caixa moov grande demais (${length} bytes)`);
      }
      const buf = source.read(offset, length);
      return { buf, moov: { type: "moov", start: box.start - offset, end: length } };
    }
    offset = box.end;
  }
  throw new Mp4ProbeError(
    sawFtyp
      ? "arquivo MP4/MOV sem caixa moov (gravação incompleta ou MP4 fragmentado)"
      : "não parece um arquivo MP4/MOV (ISO BMFF)",
  );
}

/**
 * Extrai duração, dimensões de exibição, rotação e codec da primeira trilha de vídeo.
 * Lança `Mp4ProbeError` se o arquivo não for ISO BMFF ou não tiver trilha de vídeo.
 */
export function probeMp4(source: ByteSource): Mp4VideoInfo {
  try {
    return probeMp4Unchecked(source);
  } catch (err) {
    // Caixas truncadas fazem o DataView ler fora do buffer.
    if (err instanceof RangeError) throw new Mp4ProbeError("arquivo MP4/MOV corrompido ou truncado");
    throw err;
  }
}

function probeMp4Unchecked(source: ByteSource): Mp4VideoInfo {
  const { buf, moov } = loadMoov(source);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);

  const mvhdBox = findChild(buf, moov, "mvhd");
  const movie = mvhdBox ? readTimescaleAndDuration(view, mvhdBox) : undefined;

  let video: { header: TrackHeader; mediaUs: Microseconds; codec?: string } | undefined;
  let hasAudio = false;

  for (const trak of childBoxes(buf, moov.start, moov.end)) {
    if (trak.type !== "trak") continue;
    const mdia = findChild(buf, trak, "mdia");
    const hdlr = mdia && findChild(buf, mdia, "hdlr");
    if (!mdia || !hdlr) continue;
    const handler = fourcc(buf, hdlr.start + 8);
    if (handler === "soun") hasAudio = true;
    if (handler !== "vide" || video) continue;

    const tkhd = findChild(buf, trak, "tkhd");
    if (!tkhd) continue;
    const mdhd = findChild(buf, mdia, "mdhd");
    const media = mdhd ? readTimescaleAndDuration(view, mdhd) : undefined;

    const stbl = (() => {
      const minf = findChild(buf, mdia, "minf");
      return minf && findChild(buf, minf, "stbl");
    })();
    const stsd = stbl && findChild(buf, stbl, "stsd");
    // stsd: version/flags(4) entry_count(4), depois o primeiro sample entry (size(4) + type(4))
    const codec = stsd && stsd.start + 16 <= stsd.end ? fourcc(buf, stsd.start + 12) : undefined;

    video = {
      header: readTrackHeader(view, tkhd),
      mediaUs: media ? toMicroseconds(media.duration, media.timescale) : 0,
      codec,
    };
  }

  if (!video) {
    throw new Mp4ProbeError("nenhuma trilha de vídeo encontrada");
  }

  // Duração de apresentação da trilha (tkhd, na escala do mvhd) > duração da mídia (mdhd) > duração do filme (mvhd).
  const trackUs = movie ? toMicroseconds(video.header.duration, movie.timescale) : 0;
  const movieUs = movie ? toMicroseconds(movie.duration, movie.timescale) : 0;
  const durationUs = trackUs || video.mediaUs || movieUs;
  if (durationUs <= 0) {
    throw new Mp4ProbeError("duração do vídeo não encontrada");
  }

  const { width, height, rotation } = video.header;
  const swap = rotation === 90 || rotation === 270;
  return {
    durationUs,
    width: swap ? height : width,
    height: swap ? width : height,
    rotation,
    codec: video.codec,
    hasAudio,
  };
}
