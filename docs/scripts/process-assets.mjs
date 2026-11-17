import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const docsRoot = path.resolve(__dirname, '..');
const repoRoot = path.resolve(docsRoot, '..');
const publicDir = path.join(docsRoot, 'public');

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function makeChunk(type, data) {
  const typeBuf = Buffer.from(type, 'ascii');
  const lenBuf = Buffer.allocUnsafe(4);
  lenBuf.writeUInt32BE(data.length, 0);

  const crcInput = Buffer.concat([typeBuf, data]);
  const crcBuf = Buffer.allocUnsafe(4);
  crcBuf.writeUInt32BE(crc32(crcInput), 0);

  return Buffer.concat([lenBuf, typeBuf, data, crcBuf]);
}

function paethPredictor(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

function decodePng(buffer) {
  if (buffer.length < 8 || !buffer.subarray(0, 8).equals(PNG_SIGNATURE)) {
    throw new Error('Invalid PNG signature');
  }

  let offset = 8;
  let width = 0;
  let height = 0;
  let bitDepth = 0;
  let colorType = 0;
  let interlace = 0;
  let palette = null;
  let trns = null;
  const idatChunks = [];

  while (offset + 12 <= buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString('ascii', offset + 4, offset + 8);
    const dataStart = offset + 8;
    const dataEnd = dataStart + length;
    if (dataEnd + 4 > buffer.length) break;

    const data = buffer.subarray(dataStart, dataEnd);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      interlace = data[12];
    } else if (type === 'PLTE') {
      palette = data;
    } else if (type === 'tRNS') {
      trns = data;
    } else if (type === 'IDAT') {
      idatChunks.push(data);
    } else if (type === 'IEND') {
      break;
    }
    offset = dataEnd + 4;
  }

  if (bitDepth !== 8 || interlace !== 0) {
    throw new Error(`Unsupported PNG format (bitDepth=${bitDepth}, interlace=${interlace})`);
  }

  const channelsByType = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };
  const bpp = channelsByType[colorType];
  if (!bpp) {
    throw new Error(`Unsupported PNG colorType=${colorType}`);
  }

  const inflated = zlib.inflateSync(Buffer.concat(idatChunks));
  const stride = width * bpp;
  const rgba = new Uint8Array(width * height * 4);
  let prevRow = new Uint8Array(stride);

  for (let y = 0; y < height; y++) {
    const rowStart = y * (stride + 1);
    const filter = inflated[rowStart];
    const row = new Uint8Array(stride);

    for (let i = 0; i < stride; i++) {
      const x = inflated[rowStart + 1 + i];
      const a = i >= bpp ? row[i - bpp] : 0;
      const b = prevRow[i];
      const c = i >= bpp ? prevRow[i - bpp] : 0;

      let val = x;
      if (filter === 1) val = (x + a) & 0xff;
      else if (filter === 2) val = (x + b) & 0xff;
      else if (filter === 3) val = (x + ((a + b) >> 1)) & 0xff;
      else if (filter === 4) val = (x + paethPredictor(a, b, c)) & 0xff;
      row[i] = val;
    }

    const outRow = y * width * 4;
    for (let x = 0; x < width; x++) {
      const dst = outRow + x * 4;
      if (colorType === 6) {
        const src = x * 4;
        rgba[dst] = row[src];
        rgba[dst + 1] = row[src + 1];
        rgba[dst + 2] = row[src + 2];
        rgba[dst + 3] = row[src + 3];
      } else if (colorType === 2) {
        const src = x * 3;
        rgba[dst] = row[src];
        rgba[dst + 1] = row[src + 1];
        rgba[dst + 2] = row[src + 2];
        rgba[dst + 3] = 255;
      } else if (colorType === 0) {
        const v = row[x];
        rgba[dst] = v;
        rgba[dst + 1] = v;
        rgba[dst + 2] = v;
        rgba[dst + 3] = 255;
      } else if (colorType === 4) {
        const src = x * 2;
        const v = row[src];
        rgba[dst] = v;
        rgba[dst + 1] = v;
        rgba[dst + 2] = v;
        rgba[dst + 3] = row[src + 1];
      } else if (colorType === 3 && palette) {
        const idx = row[x];
        rgba[dst] = palette[idx * 3] ?? 0;
        rgba[dst + 1] = palette[idx * 3 + 1] ?? 0;
        rgba[dst + 2] = palette[idx * 3 + 2] ?? 0;
        rgba[dst + 3] = trns && idx < trns.length ? trns[idx] : 255;
      }
    }

    prevRow = row;
  }

  return { width, height, rgba };
}

function encodePng(width, height, rgba) {
  const ihdr = Buffer.allocUnsafe(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter
  ihdr[12] = 0; // interlace

  const stride = width * 4;
  const raw = Buffer.allocUnsafe(height * (stride + 1));
  for (let y = 0; y < height; y++) {
    const dstStart = y * (stride + 1);
    raw[dstStart] = 0; // filter None
    const srcStart = y * stride;
    raw.set(rgba.subarray(srcStart, srcStart + stride), dstStart + 1);
  }

  const compressed = zlib.deflateSync(raw, { level: 6 });

  return Buffer.concat([
    PNG_SIGNATURE,
    makeChunk('IHDR', ihdr),
    makeChunk('IDAT', compressed),
    makeChunk('IEND', Buffer.alloc(0)),
  ]);
}

function sampleCornerBackground(rgba, width, height) {
  const corners = [
    [2, 2],
    [width - 3, 2],
    [2, height - 3],
    [width - 3, height - 3],
  ];
  let sumR = 0;
  let sumG = 0;
  let sumB = 0;
  let sumA = 0;
  let count = 0;

  for (const [cx, cy] of corners) {
    for (let dy = -2; dy <= 2; dy++) {
      for (let dx = -2; dx <= 2; dx++) {
        const x = Math.max(0, Math.min(width - 1, cx + dx));
        const y = Math.max(0, Math.min(height - 1, cy + dy));
        const i = (y * width + x) * 4;
        sumR += rgba[i];
        sumG += rgba[i + 1];
        sumB += rgba[i + 2];
        sumA += rgba[i + 3];
        count++;
      }
    }
  }

  return {
    r: sumR / count,
    g: sumG / count,
    b: sumB / count,
    a: sumA / count,
  };
}

function colorDistance(rgba, pixelIdx, bg) {
  const i = pixelIdx * 4;
  return Math.hypot(rgba[i] - bg.r, rgba[i + 1] - bg.g, rgba[i + 2] - bg.b);
}

function findGapSplitX(rgba, width, height, bg) {
  const startX = Math.floor(width * 0.25);
  const endX = Math.floor(width * 0.48);
  let bestX = Math.floor(width * 0.355);
  let lowestMaxDist = Infinity;

  for (let x = startX; x <= endX; x++) {
    let colMax = 0;
    for (let y = 0; y < height; y++) {
      const d = colorDistance(rgba, y * width + x, bg);
      if (d > colMax) colMax = d;
    }
    if (colMax < lowestMaxDist) {
      lowestMaxDist = colMax;
      bestX = x;
    }
  }

  return bestX;
}

function decontaminatePixel(rgba, i, alpha, bg) {
  if (alpha <= 0.02) {
    rgba[i] = 0;
    rgba[i + 1] = 0;
    rgba[i + 2] = 0;
    rgba[i + 3] = 0;
    return;
  }
  if (alpha < 0.995) {
    const inv = 1 / alpha;
    rgba[i] = Math.max(0, Math.min(255, Math.round((rgba[i] - (1 - alpha) * bg.r) * inv)));
    rgba[i + 1] = Math.max(0, Math.min(255, Math.round((rgba[i + 1] - (1 - alpha) * bg.g) * inv)));
    rgba[i + 2] = Math.max(0, Math.min(255, Math.round((rgba[i + 2] - (1 - alpha) * bg.b) * inv)));
  }
  rgba[i + 3] = Math.max(0, Math.min(255, Math.round(alpha * 255)));
}

function removeBannerBackground(width, height, sourceRgba, bg, splitX) {
  const out = new Uint8Array(sourceRgba);
  const total = width * height;
  const isBg = new Uint8Array(total);
  const queue = new Int32Array(total);
  let head = 0;
  let tail = 0;

  const bgThreshold = 40;
  const featherHigh = 72;

  function tryEnqueue(x, y) {
    if (x < 0 || x > splitX || y < 0 || y >= height) return;
    const idx = y * width + x;
    if (isBg[idx]) return;
    if (colorDistance(out, idx, bg) <= bgThreshold) {
      isBg[idx] = 1;
      queue[tail++] = idx;
    }
  }

  // Seed BFS from perimeter of the left logo region (0..splitX)
  for (let x = 0; x <= splitX; x++) {
    tryEnqueue(x, 0);
    tryEnqueue(x, height - 1);
  }
  for (let y = 0; y < height; y++) {
    tryEnqueue(0, y);
    tryEnqueue(splitX, y);
  }

  // 4-connected BFS flood fill on exterior background around the capybara
  while (head < tail) {
    const idx = queue[head++];
    const x = idx % width;
    const y = (idx - x) / width;
    tryEnqueue(x - 1, y);
    tryEnqueue(x + 1, y);
    tryEnqueue(x, y - 1);
    tryEnqueue(x, y + 1);
  }

  // Clear exterior background pixels around the capybara
  for (let y = 0; y < height; y++) {
    for (let x = 0; x <= splitX; x++) {
      const idx = y * width + x;
      if (isBg[idx]) {
        const i = idx * 4;
        out[i] = 0;
        out[i + 1] = 0;
        out[i + 2] = 0;
        out[i + 3] = 0;
      }
    }
  }

  // Smoothly feather & decontaminate 1px outer rim around the capybara
  for (let y = 1; y < height - 1; y++) {
    for (let x = 1; x < splitX; x++) {
      const idx = y * width + x;
      if (isBg[idx]) continue;

      let nearBg = false;
      for (let dy = -1; dy <= 1 && !nearBg; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx;
          const ny = y + dy;
          if (nx >= 0 && nx <= splitX && ny >= 0 && ny < height) {
            if (isBg[ny * width + nx]) {
              nearBg = true;
              break;
            }
          }
        }
      }

      if (nearBg) {
        const d = colorDistance(out, idx, bg);
        if (d < featherHigh) {
          const alpha = Math.max(0, Math.min(1, (d - 22) / (featherHigh - 22)));
          decontaminatePixel(out, idx * 4, alpha, bg);
        }
      }
    }
  }

  // Key out background on the right text region (including inside letter loops of A, P, O)
  for (let y = 0; y < height; y++) {
    for (let x = splitX + 1; x < width; x++) {
      const idx = y * width + x;
      const d = colorDistance(out, idx, bg);
      if (d <= bgThreshold) {
        const i = idx * 4;
        out[i] = 0;
        out[i + 1] = 0;
        out[i + 2] = 0;
        out[i + 3] = 0;
      } else if (d < featherHigh) {
        const alpha = Math.max(0, Math.min(1, (d - bgThreshold) / (featherHigh - bgThreshold)));
        decontaminatePixel(out, idx * 4, alpha, bg);
      }
    }
  }

  return out;
}

function extractSquareLogo(width, height, transparentRgba, splitX) {
  let minX = splitX;
  let minY = height;
  let maxX = 0;
  let maxY = 0;

  for (let y = 0; y < height; y++) {
    for (let x = 0; x <= splitX; x++) {
      const a = transparentRgba[(y * width + x) * 4 + 3];
      if (a > 12) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }

  if (maxX <= minX || maxY <= minY) {
    throw new Error('Could not locate non-transparent logo bounds');
  }

  const boxW = maxX - minX + 1;
  const boxH = maxY - minY + 1;
  const contentMax = Math.max(boxW, boxH);
  const padding = Math.max(8, Math.round(contentMax * 0.05));
  const size = contentMax + padding * 2;

  const logoRgba = new Uint8Array(size * size * 4);
  const offsetX = Math.floor((size - boxW) / 2);
  const offsetY = Math.floor((size - boxH) / 2);

  for (let y = 0; y < boxH; y++) {
    const srcY = minY + y;
    const dstY = offsetY + y;
    for (let x = 0; x < boxW; x++) {
      const srcX = minX + x;
      const dstX = offsetX + x;
      const srcIdx = (srcY * width + srcX) * 4;
      const dstIdx = (dstY * size + dstX) * 4;
      logoRgba[dstIdx] = transparentRgba[srcIdx];
      logoRgba[dstIdx + 1] = transparentRgba[srcIdx + 1];
      logoRgba[dstIdx + 2] = transparentRgba[srcIdx + 2];
      logoRgba[dstIdx + 3] = transparentRgba[srcIdx + 3];
    }
  }

  return { size, rgba: logoRgba };
}

export function ensureTransparentAssets() {
  const sourceBanner = path.join(repoRoot, 'banner.png');
  const destBanner = path.join(publicDir, 'banner.png');
  const destLogo = path.join(publicDir, 'logo.png');

  if (!fs.existsSync(sourceBanner)) {
    return;
  }

  fs.mkdirSync(publicDir, { recursive: true });

  const legacyLogo = path.join(publicDir, 'logo.webp');
  if (fs.existsSync(legacyLogo)) {
    fs.unlinkSync(legacyLogo);
  }

  const srcMtime = fs.statSync(sourceBanner).mtimeMs;
  const scriptMtime = fs.statSync(__filename).mtimeMs;
  const requiredMtime = Math.max(srcMtime, scriptMtime);

  if (fs.existsSync(destBanner) && fs.existsSync(destLogo)) {
    const bannerMtime = fs.statSync(destBanner).mtimeMs;
    const logoMtime = fs.statSync(destLogo).mtimeMs;
    if (bannerMtime >= requiredMtime && logoMtime >= requiredMtime) {
      return;
    }
  }

  const rawBuffer = fs.readFileSync(sourceBanner);
  const { width, height, rgba } = decodePng(rawBuffer);
  const bg = sampleCornerBackground(rgba, width, height);

  if (bg.a < 250) {
    fs.copyFileSync(sourceBanner, destBanner);
    const { size, rgba: logoRgba } = extractSquareLogo(width, height, rgba, Math.floor(width * 0.365));
    fs.writeFileSync(destLogo, encodePng(size, size, logoRgba));
    return;
  }

  const splitX = findGapSplitX(rgba, width, height, bg);
  const transparentBannerRgba = removeBannerBackground(width, height, rgba, bg, splitX);
  const { size, rgba: logoRgba } = extractSquareLogo(width, height, transparentBannerRgba, splitX);

  fs.writeFileSync(destBanner, encodePng(width, height, transparentBannerRgba));
  fs.writeFileSync(destLogo, encodePng(size, size, logoRgba));
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  ensureTransparentAssets();
  console.log('Generated transparent public/logo.png and public/banner.png');
}
