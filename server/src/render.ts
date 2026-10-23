// Turns a page into a PNG Claude can look at: the user's ink (as uploaded by the app),
// Claude's own layer on top, and optionally a labelled coordinate grid so Claude can aim.
import fs from "node:fs";
import sharp, { type OverlayOptions } from "sharp";
import { itemToSvg } from "./items.js";
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

const svgDoc = (body: string, bg?: string) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${PAGE_W}" height="${PAGE_H}" viewBox="0 0 ${PAGE_W} ${PAGE_H}">${bg ? `<rect width="100%" height="100%" fill="${bg}"/>` : ""}${body}</svg>`;

export async function renderPage(store: Store, page: Page, opts: { grid?: boolean; claudeLayer?: boolean; scale?: number } = {}) {
  const { grid = false, claudeLayer = true, scale = 1 } = opts;
  const snap = store.snapshotPath(page.id);
  const base = fs.existsSync(snap)
    ? sharp(await sharp(snap).resize(PAGE_W, PAGE_H, { fit: "fill" }).flatten({ background: "#ffffff" }).png().toBuffer())
    : sharp(Buffer.from(svgDoc(backgroundSvg(page), "#ffffff")));

  const layers: OverlayOptions[] = [];
  if (claudeLayer && page.claudeLayer.length) layers.push({ input: Buffer.from(svgDoc(page.claudeLayer.map(itemToSvg).join(""))) });
  if (grid) layers.push({ input: Buffer.from(svgDoc(coordinateOverlaySvg())) });

  let img = sharp(await base.composite(layers).png().toBuffer());
  if (scale !== 1) img = img.resize(Math.round(PAGE_W * scale));
  return img.png().toBuffer();
}

/** Just Claude's layer as standalone SVG, for the web viewer and as a fallback for the app. */
export function claudeLayerSvg(page: Page) {
  return svgDoc(page.claudeLayer.map(itemToSvg).join(""));
}
