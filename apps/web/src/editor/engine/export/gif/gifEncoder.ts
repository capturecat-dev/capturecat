/**
 * A small, dependency-free animated-GIF (GIF89a) encoder for the web
 * exporter. Runs wherever it is constructed — the exporter uses it inside the
 * render worker, off the main thread.
 *
 * The TIMING contract is the shared one (core/export/gifPolicy.ts, the Mac's
 * GIFExportPolicy): every frame the caller adds is one GIF frame with the
 * same whole-centisecond delay, the file loops forever (NETSCAPE2.0, count 0),
 * and the logical screen is the export size. Palette quantization is this
 * encoder's own and differs from ImageIO's on the Mac:
 *
 *  • per-frame LOCAL colour tables (≤ 256 colours) from a median cut over a
 *    6-bit-per-channel histogram of the frame's changed rectangle; each
 *    histogram bin maps to its box's mean colour (no dithering — screen
 *    content stays crisp; smooth gradients band a little);
 *  • frames after the first carry only the bounding box of pixels that
 *    changed since the previous frame (disposal "do not dispose"); an
 *    unchanged frame is a 1×1 transparent pixel, so the frame COUNT and
 *    every delay still match the policy exactly;
 *  • LZW per the GIF89a spec (variable code size up to 12 bits, clear code
 *    on a full table).
 *
 * Input frames are sRGB RGBA8 (alpha ignored — export frames are opaque).
 */

const HIST_BITS = 6;
const HIST_SIZE = 1 << (HIST_BITS * 3);

class ByteSink {
  private chunks: Uint8Array[] = [];
  private buf = new Uint8Array(1 << 16);
  private pos = 0;
  length = 0;

  byte(b: number): void {
    if (this.pos === this.buf.length) this.flushChunk();
    this.buf[this.pos++] = b;
    this.length++;
  }
  u16(v: number): void {
    this.byte(v & 0xff);
    this.byte((v >> 8) & 0xff);
  }
  bytes(a: ArrayLike<number>): void {
    for (let i = 0; i < a.length; i++) this.byte(a[i]);
  }
  ascii(s: string): void {
    for (let i = 0; i < s.length; i++) this.byte(s.charCodeAt(i));
  }
  private flushChunk(): void {
    this.chunks.push(this.buf);
    this.buf = new Uint8Array(1 << 16);
    this.pos = 0;
  }
  finish(): Uint8Array {
    const out = new Uint8Array(this.length);
    let o = 0;
    for (const c of this.chunks) {
      out.set(c, o);
      o += c.length;
    }
    out.set(this.buf.subarray(0, this.pos), o);
    return out;
  }
}

export interface GifFrameStats {
  /** Rectangle written for this frame (x, y, width, height). */
  rect: [number, number, number, number];
  colors: number;
}

export class GifEncoder {
  private readonly out = new ByteSink();
  private readonly previous: Uint8Array;
  private hasPrevious = false;
  private frames = 0;
  private finished = false;
  // Per-frame scratch (reused).
  private readonly counts = new Uint32Array(HIST_SIZE);
  private readonly sumR = new Uint32Array(HIST_SIZE);
  private readonly sumG = new Uint32Array(HIST_SIZE);
  private readonly sumB = new Uint32Array(HIST_SIZE);
  private readonly binIndex = new Uint16Array(HIST_SIZE);
  private readonly used: Uint32Array;
  readonly stats: GifFrameStats[] = [];

  constructor(
    readonly width: number,
    readonly height: number,
    /** Per-frame delay in centiseconds (GIFExportPolicy.delayCentiseconds). */
    readonly delayCentiseconds: number,
  ) {
    if (!(width > 0 && height > 0 && width < 65536 && height < 65536)) throw new Error(`GIF size ${width}×${height} out of range`);
    this.previous = new Uint8Array(width * height * 4);
    this.used = new Uint32Array(Math.min(HIST_SIZE, width * height));
    const o = this.out;
    o.ascii("GIF89a");
    o.u16(width);
    o.u16(height);
    o.byte(0x00); // no global colour table; colour resolution bits unused
    o.byte(0); // background colour index
    o.byte(0); // pixel aspect ratio
    // NETSCAPE2.0 application extension: loop forever.
    o.bytes([0x21, 0xff, 0x0b]);
    o.ascii("NETSCAPE2.0");
    o.bytes([0x03, 0x01, 0x00, 0x00, 0x00]);
  }

  get frameCount(): number {
    return this.frames;
  }

  /** Adds one frame: `rgba` is width × height × 4 sRGB bytes. */
  addFrame(rgba: Uint8Array | Uint8ClampedArray): void {
    if (this.finished) throw new Error("GIF already finished");
    const { width: W, height: H } = this;
    if (rgba.length < W * H * 4) throw new Error("GIF frame buffer too small");

    // Changed rectangle vs the previous frame (first frame: everything).
    let x0 = 0;
    let y0 = 0;
    let x1 = W - 1;
    let y1 = H - 1;
    if (this.hasPrevious) {
      const prev = this.previous;
      x0 = W;
      y0 = H;
      x1 = -1;
      y1 = -1;
      for (let y = 0; y < H; y++) {
        let row = y * W * 4;
        for (let x = 0; x < W; x++, row += 4) {
          if (rgba[row] !== prev[row] || rgba[row + 1] !== prev[row + 1] || rgba[row + 2] !== prev[row + 2]) {
            if (x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y < y0) y0 = y;
            y1 = y;
          }
        }
      }
    }
    if (x1 < 0) {
      this.writeTransparentPixel();
    } else {
      this.writeRect(rgba, x0, y0, x1 - x0 + 1, y1 - y0 + 1);
      this.previous.set(rgba.subarray(0, W * H * 4));
      this.hasPrevious = true;
    }
    this.frames++;
  }

  /** Trailer + the file bytes. */
  finish(): Uint8Array {
    if (!this.finished) {
      this.out.byte(0x3b);
      this.finished = true;
    }
    return this.out.finish();
  }

  // ── Frames ──────────────────────────────────────────────────────────────

  private graphicControl(transparentIndex: number | null): void {
    const o = this.out;
    o.bytes([0x21, 0xf9, 0x04]);
    // Disposal 1 (do not dispose) | transparency flag.
    o.byte((1 << 2) | (transparentIndex === null ? 0 : 1));
    o.u16(this.delayCentiseconds);
    o.byte(transparentIndex ?? 0);
    o.byte(0);
  }

  private imageDescriptor(x: number, y: number, w: number, h: number, tableBits: number): void {
    const o = this.out;
    o.byte(0x2c);
    o.u16(x);
    o.u16(y);
    o.u16(w);
    o.u16(h);
    o.byte(0x80 | (tableBits - 1)); // local colour table, not interlaced
  }

  private writeTransparentPixel(): void {
    this.graphicControl(0);
    this.imageDescriptor(0, 0, 1, 1, 1);
    this.out.bytes([0, 0, 0, 0, 0, 0]); // 2-entry table
    this.lzw(new Uint8Array([0]), 2);
    this.stats.push({ rect: [0, 0, 1, 1], colors: 0 });
  }

  private writeRect(rgba: Uint8Array | Uint8ClampedArray, rx: number, ry: number, rw: number, rh: number): void {
    const W = this.width;
    const { counts, sumR, sumG, sumB, binIndex, used } = this;
    const shift = 8 - HIST_BITS;
    // Histogram of the rect.
    let nUsed = 0;
    for (let y = ry; y < ry + rh; y++) {
      let p = (y * W + rx) * 4;
      for (let x = 0; x < rw; x++, p += 4) {
        const r = rgba[p];
        const g = rgba[p + 1];
        const b = rgba[p + 2];
        const k = ((r >> shift) << (HIST_BITS * 2)) | ((g >> shift) << HIST_BITS) | (b >> shift);
        if (counts[k] === 0) used[nUsed++] = k;
        counts[k]++;
        sumR[k] += r;
        sumG[k] += g;
        sumB[k] += b;
      }
    }
    const palette = medianCut(used, nUsed, counts, sumR, sumG, sumB, binIndex, 256);
    const colors = palette.length / 3;
    let tableBits = 1;
    while (1 << tableBits < colors) tableBits++;

    // Index the rect.
    const indices = new Uint8Array(rw * rh);
    let i = 0;
    for (let y = ry; y < ry + rh; y++) {
      let p = (y * W + rx) * 4;
      for (let x = 0; x < rw; x++, p += 4) {
        const k = ((rgba[p] >> shift) << (HIST_BITS * 2)) | ((rgba[p + 1] >> shift) << HIST_BITS) | (rgba[p + 2] >> shift);
        indices[i++] = binIndex[k];
      }
    }
    // Reset the histogram for the next frame (only the touched bins).
    for (let u = 0; u < nUsed; u++) {
      const k = used[u];
      counts[k] = 0;
      sumR[k] = 0;
      sumG[k] = 0;
      sumB[k] = 0;
    }

    this.graphicControl(null);
    this.imageDescriptor(rx, ry, rw, rh, tableBits);
    const table = new Uint8Array(3 << tableBits);
    table.set(palette);
    this.out.bytes(table);
    this.lzw(indices, Math.max(2, tableBits));
    this.stats.push({ rect: [rx, ry, rw, rh], colors });
  }

  // ── LZW ─────────────────────────────────────────────────────────────────

  private lzw(indices: Uint8Array, minCodeSize: number): void {
    const o = this.out;
    o.byte(minCodeSize);
    const clear = 1 << minCodeSize;
    const eoi = clear + 1;
    let codeSize = minCodeSize + 1;
    let next = eoi + 1;
    // Open-addressed (prefix << 8 | suffix) → code table.
    const HASH = 5003 * 2;
    const hashKey = new Int32Array(HASH).fill(-1);
    const hashCode = new Uint16Array(HASH);

    // Sub-block packer.
    const block = new Uint8Array(255);
    let blockLen = 0;
    let bitBuf = 0;
    let bitCount = 0;
    const emit = (code: number) => {
      bitBuf |= code << bitCount;
      bitCount += codeSize;
      while (bitCount >= 8) {
        block[blockLen++] = bitBuf & 0xff;
        bitBuf >>>= 8;
        bitCount -= 8;
        if (blockLen === 255) {
          o.byte(255);
          o.bytes(block);
          blockLen = 0;
        }
      }
    };

    // A data code, then the decoder-synchronous width bump: the decoder adds
    // its (one-behind) table entry on reading this code, reaching `next`
    // entries — once that no longer fits, every later code (EOI included)
    // is one bit wider.
    const emitData = (code: number) => {
      emit(code);
      if (next > (1 << codeSize) - 1 && codeSize < 12) codeSize++;
    };

    emit(clear);
    let prefix = indices[0];
    for (let i = 1; i < indices.length; i++) {
      const c = indices[i];
      const key = (prefix << 8) | c;
      let h = ((c << 12) ^ prefix) % HASH;
      let found = -1;
      while (hashKey[h] !== -1) {
        if (hashKey[h] === key) {
          found = hashCode[h];
          break;
        }
        h = h + 1 === HASH ? 0 : h + 1;
      }
      if (found >= 0) {
        prefix = found;
        continue;
      }
      emitData(prefix);
      if (next < 4096) {
        hashKey[h] = key;
        hashCode[h] = next++;
      } else {
        // Table full: clear at the current width, then start over.
        emit(clear);
        hashKey.fill(-1);
        codeSize = minCodeSize + 1;
        next = eoi + 1;
      }
      prefix = c;
    }
    emitData(prefix);
    emit(eoi);
    if (bitCount > 0) {
      block[blockLen++] = bitBuf & 0xff;
      if (blockLen === 255) {
        o.byte(255);
        o.bytes(block);
        blockLen = 0;
      }
    }
    if (blockLen > 0) {
      o.byte(blockLen);
      o.bytes(block.subarray(0, blockLen));
    }
    o.byte(0); // block terminator
  }
}

// ── Median cut ─────────────────────────────────────────────────────────────

interface Box {
  bins: Uint32Array;
  count: number;
  rMin: number;
  rMax: number;
  gMin: number;
  gMax: number;
  bMin: number;
  bMax: number;
}

const binR = (k: number) => (k >> (HIST_BITS * 2)) & 63;
const binG = (k: number) => (k >> HIST_BITS) & 63;
const binB = (k: number) => k & 63;

function makeBox(bins: Uint32Array, counts: Uint32Array): Box {
  const box: Box = { bins, count: 0, rMin: 63, rMax: 0, gMin: 63, gMax: 0, bMin: 63, bMax: 0 };
  for (let i = 0; i < bins.length; i++) {
    const k = bins[i];
    box.count += counts[k];
    const r = binR(k);
    const g = binG(k);
    const b = binB(k);
    if (r < box.rMin) box.rMin = r;
    if (r > box.rMax) box.rMax = r;
    if (g < box.gMin) box.gMin = g;
    if (g > box.gMax) box.gMax = g;
    if (b < box.bMin) box.bMin = b;
    if (b > box.bMax) box.bMax = b;
  }
  return box;
}

/**
 * Splits the populated bins into ≤ `maxColors` boxes (first 75 % of splits by
 * pixel count, then by count × volume — MMCQ's schedule), writes each bin's
 * palette index into `binIndex`, and returns the palette as RGB triples (each
 * box's pixel-weighted mean colour).
 */
function medianCut(
  used: Uint32Array,
  nUsed: number,
  counts: Uint32Array,
  sumR: Uint32Array,
  sumG: Uint32Array,
  sumB: Uint32Array,
  binIndex: Uint16Array,
  maxColors: number,
): Uint8Array {
  const boxes: Box[] = [makeBox(used.slice(0, nUsed), counts)];
  const byCountUntil = Math.floor(maxColors * 0.75);
  const volume = (b: Box) => (b.rMax - b.rMin + 1) * (b.gMax - b.gMin + 1) * (b.bMax - b.bMin + 1);
  while (boxes.length < maxColors) {
    let best = -1;
    let bestScore = -1;
    for (let i = 0; i < boxes.length; i++) {
      const b = boxes[i];
      if (b.bins.length < 2) continue;
      const score = boxes.length < byCountUntil ? b.count : b.count * volume(b);
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    if (best < 0) break;
    const box = boxes[best];
    const rr = box.rMax - box.rMin;
    const gr = box.gMax - box.gMin;
    const br = box.bMax - box.bMin;
    const channel = rr >= gr && rr >= br ? binR : gr >= br ? binG : binB;
    const sorted = Array.from(box.bins).sort((a, b) => channel(a) - channel(b) || a - b);
    // Weighted median split point (never empty on either side).
    let acc = 0;
    let cut = 1;
    for (let i = 0; i < sorted.length - 1; i++) {
      acc += counts[sorted[i]];
      cut = i + 1;
      if (acc * 2 >= box.count) break;
    }
    boxes.splice(best, 1, makeBox(Uint32Array.from(sorted.slice(0, cut)), counts), makeBox(Uint32Array.from(sorted.slice(cut)), counts));
  }
  const palette = new Uint8Array(boxes.length * 3);
  boxes.forEach((box, index) => {
    let r = 0;
    let g = 0;
    let b = 0;
    for (let i = 0; i < box.bins.length; i++) {
      const k = box.bins[i];
      r += sumR[k];
      g += sumG[k];
      b += sumB[k];
      binIndex[k] = index;
    }
    const n = Math.max(1, box.count);
    palette[index * 3] = Math.round(r / n);
    palette[index * 3 + 1] = Math.round(g / n);
    palette[index * 3 + 2] = Math.round(b / n);
  });
  return palette;
}
