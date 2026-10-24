// Poppler text coordinates are top-left PDF points, before the page's aspect fit.
// Keep this separate from rasterization: annotations rely on that unchanged path.
import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { nanoid } from "nanoid";
import { PDF_ID, pdfPath } from "./pdf.js";
import { PAGE_H, PAGE_W, type Store, type TextBox } from "./store.js";

const run = promisify(execFile);
export interface PdfTextLine extends TextBox { words: TextBox[] }
export interface PdfTextPage { version: 1; width: number; height: number; lines: PdfTextLine[] }
function validCache(value: PdfTextPage): boolean {
  const box = (b: TextBox) => b && typeof b.text === "string" && [b.x, b.y, b.w, b.h].every(Number.isFinite) && b.w >= 0 && b.h >= 0;
  return value?.version === 1 && value.width > 0 && value.height > 0 && Number.isFinite(value.width + value.height)
    && Array.isArray(value.lines) && value.lines.every(l => box(l) && Array.isArray(l.words) && l.words.every(box));
}
const unescapeXml = (text: string) => text.replace(/&(?:#x([\da-f]+)|#(\d+)|(amp|lt|gt|quot|apos));/gi, (_, hex, decimal, name) => {
  if (hex || decimal) return String.fromCodePoint(parseInt(hex ?? decimal, hex ? 16 : 10));
  return ({ amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" } as Record<string, string>)[name.toLowerCase()];
});
function attrs(source: string) {
  return Object.fromEntries([...source.matchAll(/([\w]+)="([^"]*)"/g)].map(m => [m[1], Number(m[2])]));
}

/** Map with the same aspect-fit-and-centre geometry as the rasterizer and iPad. */
export function parsePdfText(xml: string, rotation = 0): PdfTextPage {
  const page = xml.match(/<page\b([^>]*)>([\s\S]*?)<\/page>/);
  if (!page) throw new Error("pdftotext returned no page");
  const dimensions = attrs(page[1]), quarter = (rotation % 360 + 360) % 360;
  // Poppler reports unrotated page dimensions but already rotates word boxes.
  const [width, height] = quarter === 90 || quarter === 270 ? [dimensions.height, dimensions.width] : [dimensions.width, dimensions.height];
  if (!(width > 0) || !(height > 0) || !Number.isFinite(width + height)) throw new Error("pdftotext returned invalid page dimensions");
  const scale = Math.min(PAGE_W / width, PAGE_H / height);
  const left = (PAGE_W - width * scale) / 2, top = (PAGE_H - height * scale) / 2;
  const box = (raw: string, text: string): TextBox => {
    const { xMin, yMin, xMax, yMax } = attrs(raw);
    if (![xMin, yMin, xMax, yMax].every(Number.isFinite) || xMax < xMin || yMax < yMin) throw new Error("pdftotext returned invalid text bounds");
    // Text in PDF margins may be partially outside the media box; clip it to
    // page coordinates so returned regions remain usable with view_page zoom.
    const x = Math.max(0, Math.min(PAGE_W, left + xMin * scale)), y = Math.max(0, Math.min(PAGE_H, top + yMin * scale));
    const right = Math.max(x, Math.min(PAGE_W, left + xMax * scale)), bottom = Math.max(y, Math.min(PAGE_H, top + yMax * scale));
    return { text, x, y, w: right - x, h: bottom - y };
  };
  const lines: PdfTextLine[] = [];
  for (const match of page[2].matchAll(/<line\b([^>]*)>([\s\S]*?)<\/line>/g)) {
    const words = [...match[2].matchAll(/<word\b([^>]*)>([\s\S]*?)<\/word>/g)].map(w => box(w[1], unescapeXml(w[2])));
    const text = words.map(w => w.text).join(" ").trim();
    if (text) lines.push({ ...box(match[1], text), words });
  }
  return { version: 1, width, height, lines };
}

export async function pdfTextPage(store: Store, file: string, page: number): Promise<PdfTextPage> {
  if (!PDF_ID.test(file) || !Number.isInteger(page) || page < 1) throw new Error("Invalid PDF page reference");
  const cacheDir = path.join(store.dataDir, "pdf-text"), cached = path.join(cacheDir, `${file}-${page}.json`);
  if (fs.existsSync(cached)) {
    try {
      const value = JSON.parse(fs.readFileSync(cached, "utf8")) as PdfTextPage;
      if (validCache(value)) return value;
    } catch { /* An interrupted/old cache is safe to rebuild from the immutable PDF. */ }
  }
  const [text, info] = await Promise.all([
    run("pdftotext", ["-bbox-layout", "-f", String(page), "-l", String(page), pdfPath(store, file), "-"], { timeout: 30_000, maxBuffer: 20 * 1024 * 1024, encoding: "utf8" }),
    run("pdfinfo", ["-f", String(page), "-l", String(page), pdfPath(store, file)], { timeout: 20_000, encoding: "utf8" }),
  ]);
  const rotation = Number(info.stdout.match(/^Page\s+(?:\d+\s+)?rot:\s+(-?\d+)/m)?.[1] ?? 0);
  const value = parsePdfText(text.stdout, rotation);
  fs.mkdirSync(cacheDir, { recursive: true });
  const temporary = `${cached}.${nanoid(6)}.tmp`;
  try {
    fs.writeFileSync(temporary, JSON.stringify(value));
    fs.renameSync(temporary, cached);
  } finally { fs.rmSync(temporary, { force: true }); }
  return value;
}

export function describePdfText(page: PdfTextPage, region?: { x: number; y: number; w: number; h: number }): string[] {
  if (!page.lines.length) return ["PDF text: this page has no text layer (it may be scanned)."];
  const lines = region ? page.lines.filter(b => b.x < region.x + region.w && b.x + b.w > region.x && b.y < region.y + region.h && b.y + b.h > region.y) : page.lines;
  const output = ["PDF text (x, y, w, h):"];
  for (const b of lines.slice(0, 150)) output.push(`- [${[b.x, b.y, b.w, b.h].map(n => Math.round(n * 10) / 10).join(", ")}] ${b.text}`);
  if (!lines.length) output.push("No PDF text overlaps this zoom region.");
  if (lines.length > 150) output.push(`(${lines.length - 150} more lines, zoom in to see them)`);
  return output;
}
