// Text is stored as outlines so the server image and iPad render the same ink.
// Kalam supplies the handwriting, Playpen Sans (also hand-drawn) covers Greek and maths
// symbols, arrows are drawn as strokes, and Noto subsets catch whatever is left.
import fs from "node:fs";
import { createRequire } from "node:module";
import opentype from "opentype.js";
import { strokePolyline, type Point } from "./geometry.js";

const require = createRequire(import.meta.url);
const files = [
  "@fontsource/kalam/files/kalam-latin-400-normal.woff",
  "@fontsource/kalam/files/kalam-latin-ext-400-normal.woff",
  "@fontsource/playpen-sans/files/playpen-sans-greek-400-normal.woff",
  "@fontsource/playpen-sans/files/playpen-sans-math-400-normal.woff",
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

/** Fallback glyphs are scaled so their capitals stand as tall as Kalam's. */
const capScale = (font: opentype.Font) => {
  const kalam = load()[0].tables.os2?.sCapHeight, own = font.tables.os2?.sCapHeight;
  return kalam && own ? Math.min(1.25, Math.max(0.8, kalam / own)) : 1;
};

// At note sizes Playpen's capital omega reads as an underlined O and its lambda as a backwards ∂.
// Noto's versions are unmistakable.
const PLAYPEN_SKIP = new Set(["Ω", "Ω", "λ"]);

/** The first four fonts are hand-drawn (Kalam, Playpen Sans); the rest are typeset Noto. */
const HANDWRITTEN = 4;

function choose(char: string, handwriting = true): { font: opentype.Font; glyph: string; scale: number } {
  const all = load(), noto = all.slice(HANDWRITTEN);
  // Molecule labels want the typeset look first; handwriting wants Kalam, then Playpen, then Noto.
  const order = handwriting ? (PLAYPEN_SKIP.has(char) ? [all[0], all[1], ...noto] : all) : [...noto, ...all.slice(0, HANDWRITTEN)];
  const f = order.find((candidate) => candidate.charToGlyphIndex(char) !== 0);
  if (!f) throw new Error(`No text font supports ${JSON.stringify(char)} (U+${char.codePointAt(0)!.toString(16).toUpperCase()}); use a math item for this symbol`);
  return { font: f, glyph: char, scale: handwriting && f !== all[0] && f !== all[1] ? capScale(f) : 1 };
}

// No handwriting font draws arrows, and Noto's are thin and typeset. Draw them as pen strokes
// with the weight of Kalam's hyphen, on its height. Each entry: shafts and heads in em units.
type ArrowSpec = { width: number; shafts: [number, number, number, number][]; heads: [number, number, number][] };
const ARROWS: Record<string, ArrowSpec> = (() => {
  const single = (w: number, right: boolean, left: boolean): ArrowSpec =>
    ({ width: w, shafts: [[0.08, 0, w - 0.08, 0]], heads: [...(right ? [[w - 0.08, 0, 0]] : []), ...(left ? [[0.08, 0, Math.PI]] : [])] as [number, number, number][] });
  const double = (w: number, right: boolean, left: boolean): ArrowSpec =>
    ({ width: w, shafts: [[0.12, -0.09, w - 0.15, -0.09], [0.12, 0.09, w - 0.15, 0.09]], heads: [...(right ? [[w - 0.06, 0, 0]] : []), ...(left ? [[0.06, 0, Math.PI]] : [])] as [number, number, number][] });
  return {
    "→": single(1, true, false), "←": single(1, false, true), "↔": single(1.1, true, true),
    "⟶": single(1.5, true, false), "⟵": single(1.5, false, true), "⟷": single(1.6, true, true),
    "⇒": double(1.05, true, false), "⇐": double(1.05, false, true), "⇔": double(1.15, true, true), "⟹": double(1.5, true, false),
    "↑": { width: 0.6, shafts: [[0.3, 0.32, 0.3, -0.38]], heads: [[0.3, -0.38, -Math.PI / 2]] },
    "↓": { width: 0.6, shafts: [[0.3, -0.38, 0.3, 0.32]], heads: [[0.3, 0.32, Math.PI / 2]] },
    "⇌": { width: 1.1, shafts: [[0.08, -0.09, 1.02, -0.09], [0.08, 0.09, 1.02, 0.09]], heads: [] },
  };
})();

/** Outline of a drawn arrow glyph; returns its path and advance. */
function arrowGlyph(spec: ArrowSpec, char: string, pen: number, baseline: number, fontSize: number) {
  const em = fontSize, axis = baseline - 0.3 * em, stroke = 0.075 * em;
  const at = (x: number, y: number): Point => [pen + x * em, axis + y * em];
  const parts = spec.shafts.map(([x1, y1, x2, y2]) => strokePolyline([at(x1, y1), at(x2, y2)], stroke));
  for (const [x, y, angle] of spec.heads) {
    const tip = at(x, y), barb = 0.28 * em;
    for (const side of [-0.5, 0.5]) parts.push(strokePolyline([[tip[0] - barb * Math.cos(angle + side), tip[1] - barb * Math.sin(angle + side)], tip], stroke));
  }
  if (char === "⇌") {
    // Equilibrium harpoons: top barb up on the right end, bottom barb down on the left end.
    const r = at(1.02, -0.09), l = at(0.08, 0.09), barb = 0.24 * em;
    parts.push(strokePolyline([[r[0] - barb * Math.cos(0.5), r[1] - barb * Math.sin(0.5)], r], stroke));
    parts.push(strokePolyline([[l[0] + barb * Math.cos(0.5), l[1] + barb * Math.sin(0.5)], l], stroke));
  }
  return { d: parts.join(""), advance: (spec.width + 0.1) * em };
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
      const scale = fontSize * segment.scale, arrow = ARROWS[segment.char];
      if (arrow) {
        const drawn = arrowGlyph(arrow, segment.char, pen, baseline + segment.shift * size, scale);
        parts.push(drawn.d);
        pen += drawn.advance;
        continue;
      }
      const { font, glyph, scale: fit } = choose(segment.char);
      parts.push(font.getPath(glyph, pen, baseline + segment.shift * size, scale * fit).toPathData(2));
      pen += font.getAdvanceWidth(glyph, scale * fit);
    }
    w = Math.max(w, pen - x);
  });
  return { d: parts.filter(Boolean).join(" "), w: Math.ceil(w), h: Math.ceil(lines.length * size) };
}

/** Legacy notes must remain readable and must never stop the server starting.
 * The caller retains the original text; only its missing visual outline gets a label.
 */
export function renderLegacyHandwriting(text: string, x: number, y: number, size = 32) {
  try { return { ...renderHandwriting(text, x, y, size), unsupported: false }; }
  catch { return { ...renderHandwriting("[unsupported text]", x, y, size), unsupported: true }; }
}
