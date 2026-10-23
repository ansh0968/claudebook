// Claude's "handwriting": text is turned into outline paths with the Kalam font (OFL), so the server's
// image and the iPad draw exactly the same shapes and Claude can judge how much room her writing takes.
import fs from "node:fs";
import { createRequire } from "node:module";
import opentype from "opentype.js";

const require = createRequire(import.meta.url);
let font: opentype.Font | undefined;

function load() {
  if (!font) {
    const file = require.resolve("@fontsource/kalam/files/kalam-latin-400-normal.woff");
    const buf = fs.readFileSync(file);
    font = opentype.parse(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
  }
  return font;
}

/** Lay out `text` with its top-left at (x, y). `size` is the line height; \n starts a new line. */
export function renderHandwriting(text: string, x: number, y: number, size = 32) {
  const f = load();
  const fontSize = size * 0.8;
  const lines = text.split("\n");
  const parts: string[] = [];
  let w = 0;
  lines.forEach((line, i) => {
    const baseline = y + size * 0.78 + i * size;
    parts.push(f.getPath(line, x, baseline, fontSize).toPathData(1));
    w = Math.max(w, f.getAdvanceWidth(line, fontSize));
  });
  return { d: parts.filter(Boolean).join(" "), w: Math.round(w), h: Math.round(lines.length * size) };
}
