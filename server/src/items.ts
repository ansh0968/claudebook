// What Claude can put on a page. Kept deliberately high level: Claude is much better at
// "circle this box" than at plotting hundreds of exact points.
import { nanoid } from "nanoid";
import { z } from "zod";
import { renderMath } from "./math.js";
import { renderHandwriting } from "./handwriting.js";
import { renderMolecule } from "./molecule.js";
import svgpath from "svgpath";
import { arrowPath, pathBounds, pointBounds, type BBox, type Point } from "./geometry.js";

// A plain length-2 array rather than z.tuple: tuples become `items: [...]` in JSON Schema,
// which ChatGPT's connector rejects (it wants `items` to be one schema).
const pt = z.array(z.number()).length(2).describe("[x, y] in page coordinates") as unknown as z.ZodType<Point>;
const color = z.string().optional().describe("CSS color, default Claude orange #D97757. Use red #E5484D for mistakes, green #30A46C for corrections");
const width = z.number().positive().optional().describe("Stroke width in page units, default 3");
const group = z.string().optional().describe("Optional name for related items, so they can be erased together");

// z.union, not discriminatedUnion: the latter becomes `oneOf`, and OpenAI's tool schemas only take `anyOf`.
export const ItemSchema = z.union([
  z.object({ type: z.literal("path"), points: z.array(pt).min(2), color, width, closed: z.boolean().optional(), smooth: z.boolean().optional(), group })
    .describe("Freehand stroke through the points; smooth defaults true, false joins points with straight segments"),
  z.object({ type: z.literal("line"), from: pt, to: pt, color, width, dashed: z.boolean().optional(), group }),
  z.object({ type: z.literal("arrow"), from: pt, to: pt, color, width, group }),
  z.object({ type: z.literal("curved_arrow"), from: pt, to: pt, bend: z.number().optional(), half_head: z.boolean().optional(), color, width, group })
    .describe("Quadratic curved arrow. Signed bend offsets its control point; half_head draws one fishhook barb"),
  z.object({ type: z.literal("ellipse"), center: pt, rx: z.number(), ry: z.number().optional(), color, width, fill: z.string().optional(), group })
    .describe("Circle or ellipse. Great for circling mistakes: wrap the text box with some padding"),
  z.object({ type: z.literal("rect"), x: z.number(), y: z.number(), w: z.number(), h: z.number(), color, width, fill: z.string().optional(), group }),
  z.object({ type: z.literal("highlight"), x: z.number(), y: z.number(), w: z.number(), h: z.number(), color: z.string().optional(), group })
    .describe("Translucent marker over a region, default yellow"),
  z.object({ type: z.literal("text"), x: z.number(), y: z.number(), text: z.string(), size: z.number().optional(), color, group })
    .describe("Handwritten-style text with Unicode symbol fallback. _2 and ^- make single-character scripts; _{...} and ^{...} make longer scripts. x,y is the top-left. size is line height, default 32. Use \\n for new lines"),
  z.object({ type: z.literal("svg"), d: z.string(), color, width, fill: z.string().optional(), group })
    .describe("Raw SVG path data in page coordinates, for figures and diagrams"),
  z.object({ type: z.literal("math"), latex: z.string(), x: z.number(), y: z.number(), size: z.number().optional(), color, group })
    .describe("Typeset math from LaTeX, e.g. x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}. Use this for every equation and corrected working step, and for any symbol, subscript or charge. Chemistry works with mhchem: \\ce{H2SO4}, \\ce{OH-}, \\ce{A + B -> C}. x,y is the top-left, size is the line height, default 36. One line per item"),
  z.object({ type: z.literal("molecule"), smiles: z.string(), x: z.number(), y: z.number(), size: z.number().positive().optional(), color, group })
    .describe("Chemical structure from SMILES. x,y is the top-left; size is the longest side, default 180"),
  z.object({ type: z.literal("hint"), x: z.number(), y: z.number(), text: z.string(), label: z.string().optional(), size: z.number().positive().optional(), revealed: z.boolean().optional(), color, group })
    .describe("Hidden hint chip. The user can tap it to reveal text; label defaults to Hint"),
]);

export type ItemInput = z.infer<typeof ItemSchema>;
/** Stored items carry generated outline d and dimensions where appropriate. */
export type Item = ItemInput & { id: string; createdAt: string; d?: string; w?: number; h?: number };

/** Stamp ids and prepare outlines atomically before anything lands on the page. */
export function prepareItems(items: ItemInput[]): Item[] {
  return items.map((i) => {
    const base = { ...i, id: nanoid(8), createdAt: new Date().toISOString() };
    if (i.type === "text") return { ...base, ...renderHandwriting(i.text, i.x, i.y, i.size ?? 32) };
    if (i.type === "molecule") return { ...base, ...renderMolecule(i.smiles, i.x, i.y, i.size ?? 180) };
    if (i.type === "hint") {
      if (i.revealed) return { ...base, ...renderHandwriting(i.text, i.x, i.y, i.size ?? 32) };
      const shape = renderHandwriting(i.label ?? "Hint", i.x + 12, i.y + 3, i.size ?? 32);
      return { ...base, d: shape.d, w: shape.w + 24, h: (i.size ?? 32) + 6 };
    }
    if (i.type !== "math") {
      if (i.type === "svg") pathBounds(i.d);
      return base;
    }
    try {
      return { ...base, ...renderMath(i.latex, i.x, i.y, i.size ?? 36) };
    } catch (e) {
      throw new Error(`LaTeX error in "${i.latex}": ${(e as Error).message}`);
    }
  });
}

const DEFAULT_COLOR = "#D97757";

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** Catmull-Rom through the points, as cubic beziers. Makes Claude's strokes look like ink, not polylines. */
function smoothPath(points: [number, number][], closed = false) {
  if (points.length < 3) return `M${points.map((p) => p.join(",")).join(" L")}${closed ? " Z" : ""}`;
  const pts = closed ? [points[points.length - 1], ...points, points[0], points[1]] : [points[0], ...points, points[points.length - 1]];
  let d = `M${pts[1][0]},${pts[1][1]}`;
  for (let i = 1; i < pts.length - 2; i++) {
    const [p0, p1, p2, p3] = [pts[i - 1], pts[i], pts[i + 1], pts[i + 2]];
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6];
    const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += ` C${c1[0].toFixed(1)},${c1[1].toFixed(1)} ${c2[0].toFixed(1)},${c2[1].toFixed(1)} ${p2[0]},${p2[1]}`;
  }
  return closed ? d + " Z" : d;
}

function pathData(item: Extract<ItemInput, { type: "path" }>) {
  return item.smooth === false ? `M${item.points.map((p) => p.join(",")).join(" L")}${item.closed ? " Z" : ""}` : smoothPath(item.points, item.closed);
}

/** Boxes include stroke thickness and curve extrema, in fixed page coordinates. */
export function itemBBox(item: Item): BBox {
  const stroked = ["path", "line", "arrow", "curved_arrow", "ellipse", "rect", "svg"].includes(item.type);
  const padding = stroked ? (("width" in item ? item.width : undefined) ?? 3) / 2 : 0;
  switch (item.type) {
    case "path": return pathBounds(pathData(item), padding);
    case "line": return pointBounds([item.from, item.to], padding);
    case "arrow": return pathBounds(arrowPath(item.from, item.to, item.width), padding);
    case "curved_arrow": return pathBounds(arrowPath(item.from, item.to, item.width, item.bend ?? 40, item.half_head), padding);
    case "ellipse": return pointBounds([[item.center[0] - item.rx, item.center[1] - (item.ry ?? item.rx)], [item.center[0] + item.rx, item.center[1] + (item.ry ?? item.rx)]], padding);
    case "rect": case "highlight": return pointBounds([[item.x, item.y], [item.x + item.w, item.y + item.h]], padding);
    case "svg": return pathBounds(item.d, padding);
    default: {
      const shape = item.d === undefined ? prepareItems([item])[0] : item;
      const box = shape.d ? pathBounds(shape.d) : { x: item.x, y: item.y, w: 0, h: 0 };
      return pointBounds([[item.x, item.y], [item.x + (shape.w ?? 0), item.y + (shape.h ?? 0)], [box.x, box.y], [box.x + box.w, box.y + box.h]], item.type === "hint" && !item.revealed ? 0.75 : 0);
    }
  }
}

/** A hidden hint's answer must never leak through the page description. */
export function itemLabel(item: Item): string {
  const value = item.type === "hint" ? (item.revealed ? item.text : item.label ?? "Hint")
    : item.type === "text" ? item.text : item.type === "math" ? item.latex
    : item.type === "molecule" ? item.smiles : item.group ?? item.type;
  return value.replace(/\s+/g, " ").slice(0, 80);
}

/** Translate the prepared outline instead of re-typesetting and changing its geometry. */
export function translateItem(item: Item, dx: number, dy: number): Item {
  if (![dx, dy].every(Number.isFinite)) throw new Error("Move offsets must be finite numbers");
  const point = ([x, y]: Point): Point => [x + dx, y + dy];
  const moved = { ...item };
  if ("x" in moved) { moved.x += dx; moved.y += dy; }
  if ("from" in moved) { moved.from = point(moved.from); moved.to = point(moved.to); }
  if (moved.type === "ellipse") moved.center = point(moved.center);
  if (moved.type === "path") moved.points = moved.points.map(point);
  if (moved.d) {
    const outline = svgpath(moved.d);
    if ("err" in outline && outline.err) throw new Error(`Invalid SVG path: ${outline.err}`);
    moved.d = outline.translate(dx, dy).round(4).toString();
  }
  // Inputs may be finite while arithmetic overflows. Validate the complete
  // result before the store replaces any items or JSON turns Infinity into null.
  itemBBox(moved);
  return moved;
}

export function itemToSvg(item: ItemInput & { d?: string }): string {
  const c = esc(item.color ?? DEFAULT_COLOR);
  const w = "width" in item && item.width ? item.width : 3;
  const stroke = `stroke="${c}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"`;
  switch (item.type) {
    case "path":
      return `<path d="${pathData(item)}" fill="none" ${stroke}/>`;
    case "line":
      return `<line x1="${item.from[0]}" y1="${item.from[1]}" x2="${item.to[0]}" y2="${item.to[1]}" ${stroke}${item.dashed ? ' stroke-dasharray="10 8"' : ""}/>`;
    case "arrow":
      return `<path d="${arrowPath(item.from, item.to, w)}" fill="none" ${stroke}/>`;
    case "curved_arrow":
      return `<path d="${arrowPath(item.from, item.to, w, item.bend ?? 40, item.half_head)}" fill="none" ${stroke}/>`;
    case "ellipse":
      return `<ellipse cx="${item.center[0]}" cy="${item.center[1]}" rx="${item.rx}" ry="${item.ry ?? item.rx}" fill="${esc(item.fill ?? "none")}" ${stroke}/>`;
    case "rect":
      return `<rect x="${item.x}" y="${item.y}" width="${item.w}" height="${item.h}" rx="4" fill="${esc(item.fill ?? "none")}" ${stroke}/>`;
    case "highlight":
      return `<rect x="${item.x}" y="${item.y}" width="${item.w}" height="${item.h}" fill="${esc(item.color ?? "#FFE066")}" fill-opacity="0.45"/>`;
    case "text": {
      const shape = "d" in item && typeof item.d === "string" ? item : renderHandwriting(item.text, item.x, item.y, item.size ?? 32);
      if (shape.d) return `<path d="${esc(shape.d)}" fill="${c}"/>`;
      const size = item.size ?? 32;
      const lines = item.text.split("\n").map((l, i) => `<tspan x="${item.x}" dy="${i === 0 ? size * 0.8 : size}">${esc(l)}</tspan>`);
      return `<text x="${item.x}" y="${item.y}" font-family="Caveat, 'Comic Neue', 'DejaVu Sans', sans-serif" font-size="${size}" fill="${c}">${lines.join("")}</text>`;
    }
    case "svg":
      return `<path d="${esc(item.d)}" fill="${esc(item.fill ?? "none")}" ${stroke}/>`;
    case "hint": {
      const shape = item.d === undefined ? prepareItems([item])[0] : item as Item;
      const label = shape.d ? `<path d="${esc(shape.d)}" fill="${c}"/>` : "";
      return item.revealed ? label : `<rect x="${item.x}" y="${item.y}" width="${shape.w}" height="${shape.h}" rx="8" fill="${c}" fill-opacity="0.1" stroke="${c}" stroke-width="1.5"/>${label}`;
    }
    case "molecule": {
      const shape = item.d === undefined ? renderMolecule(item.smiles, item.x, item.y, item.size ?? 180) : item;
      return shape.d ? `<path d="${esc(shape.d)}" fill="${c}"/>` : "";
    }
    case "math":
      return item.d ? `<path d="${esc(item.d)}" fill="${c}"/>` : "";
  }
}
