// Turns a page into a PNG Claude can look at: the user's ink (as uploaded by the app),
// Claude's own layer on top, and optionally a labelled coordinate grid so Claude can aim.
import { blockPath } from "./web-blocks.js";
import type { Item } from "./items.js";
import fs from "node:fs";
import sharp, { type OverlayOptions } from "sharp";
import { itemToSvg } from "./items.js";
import { rasterizePdfPage } from "./pdf.js";
import { PAGE_H, PAGE_W, type Page, type Store } from "./store.js";

function backgroundSvg(page: Page) {
  const lines: string[] = [];
  if (page.background === "lined") {
    for (let y = 120; y < PAGE_H - 40; y += 40) lines.push(`<line x1="40" y1="${y}" x2="${PAGE_W - 40}" y2="${y}" stroke="#C9D7E8" stroke-width="1.5"/>`);
  } else if (page.background === "grid") {
    for (let x = 25; x < PAGE_W; x += 25) lines.push(`<line x1="${x}" y1="0" x2="${x}" y2="${PAGE_H}" stroke="#E3EAF2" stroke-width="1"/>`);
    for (let y = 25; y < PAGE_H; y += 25) lines.push(`<line x1="0" y1="${y}" x2="${PAGE_W}" y2="${y}" stroke="#E3EAF2" stroke-width="1"/>`);
  } else if (page.background === "dotted") {
    for (let x = 25; x < PAGE_W; x += 25) for (let y = 25; y < PAGE_H; y += 25) lines.push(`<circle cx="${x}" cy="${y}" r="1.4" fill="#C9D2DC"/>`);
  }
  return lines.join("");
}

function coordinateOverlaySvg() {
  const out: string[] = [];
  for (let x = 0; x <= PAGE_W; x += 50) {
    const major = x % 100 === 0;
    out.push(`<line x1="${x}" y1="0" x2="${x}" y2="${PAGE_H}" stroke="#3B82F6" stroke-opacity="${major ? 0.35 : 0.15}" stroke-width="1"/>`);
    if (major && x > 0 && x < PAGE_W) out.push(`<text x="${x + 3}" y="14" font-size="13" font-family="DejaVu Sans, sans-serif" fill="#2563EB">${x}</text>`);
  }
  for (let y = 0; y <= PAGE_H; y += 50) {
    const major = y % 100 === 0;
    out.push(`<line x1="0" y1="${y}" x2="${PAGE_W}" y2="${y}" stroke="#3B82F6" stroke-opacity="${major ? 0.35 : 0.15}" stroke-width="1"/>`);
    if (major && y > 0) out.push(`<text x="3" y="${y - 3}" font-size="13" font-family="DejaVu Sans, sans-serif" fill="#2563EB">${y}</text>`);
  }
  return out.join("");
}

/** Labelled grid for a zoomed region: line spacing and label size adapt so they stay readable in the output. */
function regionOverlaySvg(r: Region, pxPerUnit: number) {
  const step = [5, 10, 20, 25, 50, 100].find((st) => st * pxPerUnit >= 70) ?? 100;
  const font = 14 / pxPerUnit, stroke = 1 / pxPerUnit;
  const out: string[] = [];
  for (let x = Math.ceil(r.x / step) * step; x <= r.x + r.w; x += step) {
    out.push(`<line x1="${x}" y1="${r.y}" x2="${x}" y2="${r.y + r.h}" stroke="#3B82F6" stroke-opacity="0.3" stroke-width="${stroke}"/>`);
    out.push(`<text x="${x + 3 / pxPerUnit}" y="${r.y + font * 1.1}" font-size="${font}" font-family="DejaVu Sans, sans-serif" fill="#2563EB">${x}</text>`);
  }
  for (let y = Math.ceil(r.y / step) * step; y <= r.y + r.h; y += step) {
    out.push(`<line x1="${r.x}" y1="${y}" x2="${r.x + r.w}" y2="${y}" stroke="#3B82F6" stroke-opacity="0.3" stroke-width="${stroke}"/>`);
    out.push(`<text x="${r.x + 3 / pxPerUnit}" y="${y - 3 / pxPerUnit}" font-size="${font}" font-family="DejaVu Sans, sans-serif" fill="#2563EB">${y}</text>`);
  }
  return out.join("");
}

/** Page-coordinate SVG rendered at `k` pixels per page unit. */
const svgDoc = (body: string, bg?: string, k = 1) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${PAGE_W * k}" height="${PAGE_H * k}" viewBox="0 0 ${PAGE_W} ${PAGE_H}">${bg ? `<rect width="100%" height="100%" fill="${bg}"/>` : ""}${body}</svg>`;

export interface Region {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** Clamp a requested zoom rectangle to the page, keeping it at least 50 units on each side. */
export function clampRegion(r: Region): Region {
  const w = Math.min(PAGE_W, Math.max(50, r.w)), h = Math.min(PAGE_H, Math.max(50, r.h));
  return { x: Math.min(Math.max(0, r.x), PAGE_W - w), y: Math.min(Math.max(0, r.y), PAGE_H - h), w, h };
}

export async function renderPage(store: Store, page: Page, opts: { grid?: boolean; claudeLayer?: boolean; scale?: number; region?: Region } = {}) {
  const { grid = false, claudeLayer = true, scale = 1 } = opts;
  const region = opts.region && clampRegion(opts.region);
  // Zoomed views are composed at 2x so small handwriting stays legible (the app uploads 2x snapshots).
  const k = region ? 2 : 1;
  const W = PAGE_W * k, H = PAGE_H * k;
  // Base: the app's snapshot (paper + PDF + ink) if it has sent one, else the bare PDF page, else paper.
  const snap = store.snapshotPath(page.id);
  const base = fs.existsSync(snap)
    ? sharp(await sharp(snap).resize(W, H, { fit: "fill" }).flatten({ background: "#ffffff" }).png().toBuffer())
    : page.pdf
      ? sharp(await sharp(await rasterizePdfPage(store, page.pdf.file, page.pdf.page)).resize(W, H).png().toBuffer())
      : sharp(Buffer.from(svgDoc(backgroundSvg(page), "#ffffff", k)));

  const outW = region ? Math.round(Math.min(1400, Math.max(700, region.w * 3))) : PAGE_W * scale;
  const layers: OverlayOptions[] = [];
  if (claudeLayer && page.claudeLayer.length) layers.push({ input: Buffer.from(svgDoc(page.claudeLayer.map(item => renderItem(store, item)).join(""), undefined, k)) });
  if (grid) layers.push({ input: Buffer.from(svgDoc(region ? regionOverlaySvg(region, outW / region.w) : coordinateOverlaySvg(), undefined, k)) });

  let img = sharp(await base.composite(layers).png().toBuffer());
  if (region) {
    img = sharp(await img.extract({ left: Math.round(region.x * k), top: Math.round(region.y * k), width: Math.round(region.w * k), height: Math.round(region.h * k) }).png().toBuffer());
    img = img.resize(outW);
  } else if (scale !== 1) {
    img = img.resize(Math.round(PAGE_W * scale));
  }
  return img.png().toBuffer();
}

/** Just Claude's layer as standalone SVG, for the web viewer and as a fallback for the app. */
export function claudeLayerSvg(page: Page, store?: Store) {
  return svgDoc(page.claudeLayer.map(item => store ? renderItem(store, item) : itemToSvg(item)).join(""));
}

function renderItem(store: Store, item: Item) {
  if (item.type === "web" && item.poster) {
    try {
      const bytes = fs.readFileSync(blockPath(store, item.poster));
      return `<image x="${item.x}" y="${item.y}" width="${item.w}" height="${item.h}" preserveAspectRatio="none" href="data:image/png;base64,${bytes.toString("base64")}"/>`;
    } catch { /* Missing poster is harmless: keep the placeholder visible. */ }
  }
  return itemToSvg(item);
}
