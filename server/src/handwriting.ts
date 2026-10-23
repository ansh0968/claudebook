// Text is stored as outlines so the server image and iPad render the same ink.
// Kalam supplies the handwriting; Noto subsets cover symbols Kalam cannot draw.
import fs from "node:fs";
import { createRequire } from "node:module";
import opentype from "opentype.js";

const require = createRequire(import.meta.url);
const files = [
  "@fontsource/kalam/files/kalam-latin-400-normal.woff",
  "@fontsource/noto-sans-math/files/noto-sans-math-latin-400-normal.woff",
  "@fontsource/noto-sans-symbols/files/noto-sans-symbols-symbols-400-normal.woff",
  "@fontsource/noto-sans-symbols-2/files/noto-sans-symbols-2-symbols-400-normal.woff",
  "@fontsource/noto-sans/files/noto-sans-greek-400-normal.woff",
  "@fontsource/noto-sans/files/noto-sans-latin-ext-400-normal.woff",
  "@fontsource/noto-sans/files/noto-sans-latin-400-normal.woff",
];
let fonts: opentype.Font[] | undefined;

function load() {
  if (!fonts) fonts = files.map((file) => {
    const buf = fs.readFileSync(require.resolve(file));
    return opentype.parse(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
  });
  return fonts;
}

function choose(char: string, handwriting = true): { font: opentype.Font; glyph: string } {
  const order = handwriting ? load() : [...load().slice(1), load()[0]];
  const f = order.find((candidate) => candidate.charToGlyphIndex(char) !== 0);
  if (!f) throw new Error(`No text font supports ${JSON.stringify(char)} (U+${char.codePointAt(0)!.toString(16).toUpperCase()}); use a math item for this symbol`);
  return { font: f, glyph: char };
}

interface Segment { char: string; scale: number; shift: number }

// Fontsource's web subsets omit some Unicode scripts even when Noto supports
// them. Shape these using ordinary digits/letters rather than missing glyphs.
const subscript = new Map([..."₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ"].map((char, i) => [char, [..."0123456789+-=()aehijklmnoprstuvx"][i]]));
const superscript = new Map([..."⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱ"].map((char, i) => [char, [..."0123456789+-=()ni"][i]]));

function segment(char: string, scale = 1, shift = 0): Segment {
  if (subscript.has(char)) return { char: subscript.get(char)!, scale: 0.7 * scale, shift: shift + 0.2 };
  if (superscript.has(char)) return { char: superscript.get(char)!, scale: 0.7 * scale, shift: shift - 0.35 };
  return { char, scale, shift };
}

function segments(line: string): Segment[] {
  const result: Segment[] = [];
  for (let i = 0; i < line.length;) {
    const marker = line[i];
    if ((marker === "_" || marker === "^") && i + 1 < line.length) {
      let script: string;
      if (line[i + 1] === "{") {
        const end = line.indexOf("}", i + 2);
        if (end < 0) { result.push({ char: marker, scale: 1, shift: 0 }); i++; continue; }
        script = line.slice(i + 2, end);
        i = end + 1;
      } else {
        script = [...line.slice(i + 1)][0];
        i += 1 + script.length;
      }
      for (const char of script) result.push(segment(char, 0.7, marker === "^" ? -0.35 : 0.2));
      continue;
    }
    const char = [...line.slice(i)][0];
    result.push(segment(char));
    i += char.length;
  }
  return result;
}

/** Draw a baseline-aligned label using available font outlines, as in molecule atom labels. */
export function renderFontLabel(text: string, x: number, baseline: number, fontSize: number): string {
  let pen = x;
  const parts: string[] = [];
  for (const char of text) {
    const { font, glyph } = choose(char, false);
    parts.push(font.getPath(glyph, pen, baseline, fontSize).toPathData(2));
    pen += font.getAdvanceWidth(glyph, fontSize);
  }
  return parts.join(" ");
}

/** Lay out text with its top-left at (x, y). size is the line height. */
export function renderHandwriting(text: string, x: number, y: number, size = 32) {
  const fontSize = size * 0.8;
  const lines = text.split("\n");
  const parts: string[] = [];
  let w = 0;
  lines.forEach((line, row) => {
    let pen = x;
    const baseline = y + size * 0.78 + row * size;
    for (const segment of segments(line)) {
      const { font, glyph } = choose(segment.char);
      const scale = fontSize * segment.scale;
      parts.push(font.getPath(glyph, pen, baseline + segment.shift * size, scale).toPathData(2));
      pen += font.getAdvanceWidth(glyph, scale);
    }
    w = Math.max(w, pen - x);
  });
  return { d: parts.filter(Boolean).join(" "), w: Math.ceil(w), h: Math.ceil(lines.length * size) };
}
