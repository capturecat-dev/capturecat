/**
 * Texture → CPU readback for snapshots and export parity captures.
 * `encodeCopy` records the copy into the frame's command encoder (so it reads
 * exactly the pixels that frame produced); `read` maps it AFTER the submit.
 */

export interface Pixels {
  width: number;
  height: number;
  /** RGBA8 rows, tightly packed. */
  rgba: Uint8Array;
}

export interface PendingReadback {
  read(): Promise<Pixels>;
}

export function encodeCopy(device: GPUDevice, enc: GPUCommandEncoder, texture: GPUTexture): PendingReadback {
  const width = texture.width;
  const height = texture.height;
  const bpr = Math.ceil((width * 4) / 256) * 256;
  const buffer = device.createBuffer({ size: bpr * height, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
  enc.copyTextureToBuffer({ texture }, { buffer, bytesPerRow: bpr, rowsPerImage: height }, { width, height });
  const bgra = texture.format === "bgra8unorm" || texture.format === "bgra8unorm-srgb";
  return {
    async read(): Promise<Pixels> {
      await buffer.mapAsync(GPUMapMode.READ);
      const src = new Uint8Array(buffer.getMappedRange());
      const rgba = new Uint8Array(width * height * 4);
      for (let y = 0; y < height; y++) {
        const row = src.subarray(y * bpr, y * bpr + width * 4);
        const out = rgba.subarray(y * width * 4, (y + 1) * width * 4);
        if (bgra) {
          for (let i = 0; i < row.length; i += 4) {
            out[i] = row[i + 2];
            out[i + 1] = row[i + 1];
            out[i + 2] = row[i];
            out[i + 3] = row[i + 3];
          }
        } else {
          out.set(row);
        }
      }
      buffer.unmap();
      buffer.destroy();
      return { width, height, rgba };
    },
  };
}
