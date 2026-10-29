// What Claude can put on a page. Kept deliberately high level: Claude is much better at
// "circle this box" than at plotting hundreds of exact points.
import { nanoid } from "nanoid";
import { z } from "zod";
import { renderMath } from "./math.js";
import { renderHandwriting } from "./handwriting.js";
import { renderMolecule } from "./molecule.js";
import svgpath from "svgpath";
import { arrowHead, arrowPath, curvedArrowPaths, headsFor, pathBounds, pointBounds, type BBox, type HeadMode, type Point } from "./geometry.js";
import { PhysicsSchemas, rotation, patternFields, preparePhysics, patternParts, ellipseOutline, rectOutline, rotatedBBox } from "./physics.js";
import { GraphSchemas, prepareGraph, type GraphTransform } from "./graphs.js";
import { partsBBox, partsToSvg, translateParts, type Part } from "./parts.js";
import { PAGE_H, PAGE_W } from "./store.js";

// A plain length-2 array rather than z.tuple: tuples become `items: [...]` in JSON Schema,
// which ChatGPT's connector rejects (it wants `items` to be one schema).
const pt = z.array(z.number()).length(2).describe("[x, y] in page coordinates") as unknown as z.ZodType<Point>;
const color = z.string().optional().describe("CSS color, default Claude orange #D97757. Use red #E5484D for mistakes, green #30A46C for corrections");
const width = z.number().positive().optional().describe("Stroke width in page units, default 3");
const group = z.string().optional().describe("Optional name for related items, so they can be erased together");
const dashed = z.boolean().optional().describe("Dashed stroke");
const head = (fallback: string) => z.enum(["none", "end", "start", "both"]).optional().describe(`Arrowheads, aligned to the path's direction at each end. Default ${fallback}`);
const headFilled = z.boolean().optional().describe("Solid triangle arrowheads instead of open ones");
const fill = z.string().optional().describe("Fill color. Without a color, a filled shape gets no outline");
const anchor = z.enum(["top-left", "top-center", "top-right", "left-center", "center", "right-center", "bottom-left", "bottom-center", "bottom-right"]).optional()
  .describe("Which point of the item x,y names, default top-left. The stored x,y and bbox are always the top-left");

const chemistryArrow = { from: pt, to: pt, bend: z.number().optional().describe("Signed curve bend, default 40"), head: z.enum(["full", "half"]).optional().describe('Filled electron-pair or fishhook head, default full. Example: head:"half"'), half_head: z.boolean().optional().describe('Legacy alias for head:"half"'), color, width, group };

// z.union, not discriminatedUnion: the latter becomes `oneOf`, and OpenAI's tool schemas only take `anyOf`.
export const ItemSchema = z.union([
  z.object({ type: z.literal("web"), x: z.number(), y: z.number(), w: z.number().positive(), h: z.number().positive(), title: z.string(), file: z.string(), rev: z.number().int().positive(), autoplay: z.boolean().optional(), group }).describe("Interactive HTML block. Use add_web_block, never draw_on_page"),
  ...GraphSchemas,
  ...PhysicsSchemas,
  z.object({ type: z.literal("path"), points: z.array(pt).min(2), color, width, closed: z.boolean().optional(), smooth: z.boolean().optional(), dashed, head: head("none"), head_filled: headFilled, group })
    .describe("Freehand stroke through the points; smooth defaults true, false joins points with straight segments"),
  z.object({ type: z.literal("line"), from: pt, to: pt, color, width, dashed: z.boolean().optional(), group }),
  z.object({ type: z.literal("arrow"), from: pt, to: pt, color, width, dashed, head: head("end"), head_filled: headFilled, group })
    .describe("Straight arrow. head: \"both\" for dimension lines (λ, R, lengths)"),
  z.object({ type: z.literal("curved_arrow"), ...chemistryArrow })
    .describe('Chemistry arrow with a filled head aligned to the curve tangent. Example: {type:"curved_arrow",from:[100,200],to:[250,200],bend:-60,head:"full"}'),
  z.object({ type: z.literal("curly"), ...chemistryArrow })
    .describe('Alias stored as curved_arrow. Example: {type:"curly",from:[100,200],to:[250,200],head:"half"}'),
  z.object({ type: z.literal("ellipse"), center: pt, rx: z.number(), ry: z.number().optional(), color, width, fill, rotation, ...patternFields, group })
    .describe("Circle or ellipse. Great for circling mistakes: wrap the text box with some padding"),
  z.object({ type: z.literal("rect"), x: z.number(), y: z.number(), w: z.number(), h: z.number(), color, width, fill, rotation, ...patternFields, group }),
  z.object({ type: z.literal("highlight"), x: z.number(), y: z.number(), w: z.number(), h: z.number(), color: z.string().optional(), group })
    .describe("Translucent marker over a region, default yellow"),
  z.object({ type: z.literal("text"), x: z.number(), y: z.number(), text: z.string(), size: z.number().optional(), color, anchor, rotation, group })
    .describe("Handwritten-style text with Unicode symbol fallback. _2 and ^- make single-character scripts; _{...} and ^{...} make longer scripts. x,y is the top-left. size is line height, default 32. Use \\n for new lines"),
  z.object({ type: z.literal("svg"), d: z.string(), color, width, fill, dashed, head: head("none"), head_filled: headFilled, rotation, ...patternFields, group })
    .describe("Raw SVG path data in page coordinates, for figures and diagrams"),
  z.object({ type: z.literal("math"), latex: z.string(), x: z.number(), y: z.number(), size: z.number().optional(), color, anchor, rotation, group })
    .describe("Typeset math from LaTeX, e.g. x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}. Use this for every equation and corrected working step, and for any symbol, subscript or charge. Chemistry works with mhchem: \\ce{H2SO4}, \\ce{OH-}, \\ce{A + B -> C}. x,y is the true ink top-left unless anchor is set; bbox excludes invisible layout padding. size is the line height, default 36; one line is about 0.55 x size tall, fractions and matrices more. Arrow labels: \\xrightarrow[below]{above} or \\ce{A ->[above][below] B}. One line per item"),
  z.object({ type: z.literal("molecule"), smiles: z.string(), x: z.number(), y: z.number(), size: z.number().positive().optional(), show_carbons: z.boolean().optional().describe('Label every carbon. Example: show_carbons:true'), explicit_h: z.boolean().optional().describe('Draw every hydrogen atom and bond. Example: explicit_h:true'), color, rotation, group })
    .describe('Chemical structure from SMILES. Returns atoms (index to [x,y]) and elements maps in page units. x,y is top-left; size is longest side, default 180. Example: {type:"molecule",smiles:"CC(=O)O",x:100,y:200,show_carbons:true}'),
  z.object({ type: z.literal("hint"), x: z.number(), y: z.number(), text: z.string(), label: z.string().optional(), size: z.number().positive().optional(), revealed: z.boolean().optional(), color, group })
    .describe("Hidden hint chip. The user can tap it to reveal text; label defaults to Hint"),
]);

export type ItemInput = z.infer<typeof ItemSchema>;
/** Stored items carry generated outline d, arrowhead outline head_d and dimensions where appropriate. */
export type Item = ItemInput & { id: string; createdAt: string; d?: string; w?: number; h?: number; head_d?: string; parts?: Part[]; graph?: GraphTransform; rotation_center?: Point; head_filled?: boolean; atoms?: Record<string, Point>; elements?: Record<string, string>; poster?: string; posterAt?: string; logs?: string[] };
/** Expose atom targets where the rendered molecule is, while keeping stored coordinates unrotated.
 * Rotation metadata is optional so this composes with the separate physics drawing feature.
 */
export function moleculeAtomsForDisplay(item: Item & { rotation?: number; rotation_center?: Point }): Record<string, Point> | undefined {
  if (!item.atoms || !item.rotation || !item.rotation_center) return item.atoms;
  const angle = (item.rotation % 360) * Math.PI / 180, cos = Math.cos(angle), sin = Math.sin(angle);
  const [cx, cy] = item.rotation_center;
  return Object.fromEntries(Object.entries(item.atoms).map(([id, [x, y]]) => [id,
    [cx + (x - cx) * cos - (y - cy) * sin, cy + (x - cx) * sin + (y - cy) * cos] as Point,
  ]));
}

/** Fractions of the item's width and height that each anchor sits at. */
const ANCHORS: Record<NonNullable<z.infer<typeof anchor>>, [number, number]> = {
  "top-left": [0, 0], "top-center": [0.5, 0], "top-right": [1, 0], "left-center": [0, 0.5], center: [0.5, 0.5],
  "right-center": [1, 0.5], "bottom-left": [0, 1], "bottom-center": [0.5, 1], "bottom-right": [1, 1],
};

/** Shift a rendered outline so the anchor lands on x,y; the stored x,y become the true top-left. */
function anchored<T extends { x: number; y: number; anchor?: keyof typeof ANCHORS }>(item: T, shape: { d: string; w: number; h: number }) {
  const { anchor: a, ...rest } = item;
  const [fx, fy] = ANCHORS[a ?? "top-left"];
  if (!fx && !fy) return { ...rest, ...shape };
  const dx = -fx * shape.w, dy = -fy * shape.h;
  return { ...rest, ...shape, x: item.x + dx, y: item.y + dy, d: shape.d && svgpath(shape.d).translate(dx, dy).round(2).toString() };
}

/** Arrowheads, computed once so the server render and the iPad draw the same shapes. */
function withHeads<T extends ItemInput>(item: T): T & { head_d?: string } {
  if (item.type === "arrow") {
    const mode = item.head ?? "end", w = item.width ?? 3, filled = item.head_filled ?? false;
    const angle = Math.atan2(item.to[1] - item.from[1], item.to[0] - item.from[0]);
    if (item.from[0] === item.to[0] && item.from[1] === item.to[1]) return item;
    const parts = [
      ...(mode === "end" || mode === "both" ? [arrowHead(item.to, angle, w, filled)] : []),
      ...(mode === "start" || mode === "both" ? [arrowHead(item.from, angle + Math.PI, w, filled)] : []),
    ];
    return parts.length ? { ...item, head_d: parts.join("") } : item;
  }
  if ((item.type === "path" || item.type === "svg") && item.head && item.head !== "none") {
    const d = item.type === "path" ? pathData(item) : item.d;
    const head_d = headsFor(d, item.head as HeadMode, item.width ?? 3, item.head_filled ?? false);
    return head_d ? { ...item, head_d } : item;
  }
  return item;
}

/** Stamp ids and prepare outlines atomically before anything lands on the page. */
export function prepareItems(items: ItemInput[], existing: Item[] = []): Item[] {
  const available = [...existing];
  return items.map(input => {
    const item = prepareItem(input, available);
    // Rotation follows outline preparation and anchor positioning on both renderers.
    if ("rotation" in item && item.rotation) {
      const b = unrotatedBBox(item);
      item.rotation_center = [b.x + b.w / 2, b.y + b.h / 2];
    }
    available.push(item);
    return item;
  });
}

function prepareItem(input: ItemInput, available: Item[]): Item {
    // The iPad's path parser has no arcs, so store SVG paths with arcs already turned into curves.
    const i = input.type === "svg" ? { ...input, d: normalizeSvg(input.d) } : input;
    const base = withHeads({ ...i, id: nanoid(8), createdAt: new Date().toISOString() });
    if (i.type === "spring" || i.type === "ground") return { ...base, parts: preparePhysics(i) };
    if ((i.type === "rect" || i.type === "ellipse" || i.type === "svg") && i.fill_pattern) {
      const d = i.type === "rect" ? rectOutline(i.x, i.y, i.w, i.h) : i.type === "ellipse" ? ellipseOutline(i.center, i.rx, i.ry ?? i.rx) : i.d;
      const parts = patternParts(d, i.fill_pattern, i.pattern_spacing, i.pattern_angle, i.color, i.width, i.fill, outlined(i), i.type === "svg" && i.dashed ? [10, 8] : undefined);
      if (base.head_d) parts.push({ d: base.head_d, stroke: i.color ?? DEFAULT_COLOR, fill: i.type === "svg" && i.head_filled ? i.color ?? DEFAULT_COLOR : "none", width: i.width ?? 3 });
      return { ...base, parts };
    }
    if (i.type === "axes" || i.type === "plot" || i.type === "shade" || i.type === "angle" || i.type === "point") return { ...base, ...prepareGraph(i, available) };
    if (i.type === "curly" || i.type === "curved_arrow") {
      const head = i.head ?? (i.half_head ? "half" : "full");
      const paths = curvedArrowPaths(i.from, i.to, i.width ?? 3, i.bend ?? 40, head === "half");
      return { ...i, id: base.id, createdAt: base.createdAt, type: "curved_arrow" as const, head, d: paths.shaft, head_d: paths.head, head_filled: true };
    }
    if (i.type === "text") return anchored(base as typeof i & { id: string; createdAt: string }, renderHandwriting(i.text, i.x, i.y, i.size ?? 32)) as Item;
    if (i.type === "molecule") return { ...base, ...renderMolecule(i.smiles, i.x, i.y, i.size ?? 180, i) };
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
      return anchored(base as typeof i & { id: string; createdAt: string }, renderMath(i.latex, i.x, i.y, i.size ?? 36)) as Item;
    } catch (e) {
      throw new Error(`LaTeX error in "${i.latex}": ${(e as Error).message}`);
    }
}

const DEFAULT_COLOR = "#D97757";

function normalizeSvg(d: string) {
  const path = svgpath(d);
  if ("err" in path && path.err) throw new Error(`Invalid SVG path: ${path.err}`);
  return /[aA]/.test(d) ? path.abs().unarc().round(2).toString() : d;
}

/** Ellipses, rects and SVG shapes with a fill but no color are fill-only, not orange-outlined. */
const outlined = (item: ItemInput) => !("fill" in item && item.fill && item.fill !== "none" && item.color === undefined);

/** Every key each item type accepts, so unknown keys can be reported instead of silently dropped. */
const itemKeys = new Map(ItemSchema.options.map((o) => [String((o.shape.type as z.ZodLiteral<string>).value), new Set(Object.keys(o.shape))]));

/** Keep real types first for tool discovery; let malformed items reach per-item validation. */
export const LooseItemSchema = z.union([
  ...ItemSchema.options.map((o) => (o.description ? o.loose().describe(o.description) : o.loose())),
  z.object({ type: z.string() }).loose().describe('Invalid items are skipped individually, e.g. {type:"squiggle"}; use one of the real types above'),
] as unknown as [z.ZodTypeAny, z.ZodTypeAny, ...z.ZodTypeAny[]]);

export interface ItemWarning { item: number; type?: string; id?: string; warning: string }

/**
 * Prepare a batch item by item: an item with unknown keys or one that fails to render (bad LaTeX,
 * bad SMILES, bad SVG) is skipped with a warning while the rest still draw.
 */
export function prepareBatch(raw: Record<string, unknown>[], existing: Item[] = []): { items: Item[]; indexes: number[]; warnings: ItemWarning[] } {
  const items: Item[] = [], indexes: number[] = [], warnings: ItemWarning[] = [];
  raw.forEach((input, index) => {
    const type = String(input.type);
    if (type === "web") { warnings.push({ item: index, type, warning: "Skipped: use add_web_block for interactive HTML, e.g. {x:100,y:200,w:800,h:500,title:\"Simulation\",html:\"<canvas></canvas>\"}" }); return; }
    const allowed = itemKeys.get(type);
    if (!allowed) {
      warnings.push({ item: index, type, warning: `Skipped: unknown type "${type}". Types: ${[...itemKeys.keys()].join(", ")}` });
      return;
    }
    const unknown = allowed ? Object.keys(input).filter((k) => !allowed.has(k)) : [];
    if (unknown.length) {
      warnings.push({ item: index, type, warning: `Skipped: ${type} has no ${unknown.map((k) => `"${k}"`).join(", ")}. It accepts ${[...allowed!].join(", ")}` });
      return;
    }
    // Validate against the known type so errors name its fields, not every union option.
    const schema = ItemSchema.options.find((o) => String(o.shape.type.value) === type)!;
    const parsed = schema.safeParse(input);
    if (!parsed.success) {
      const details = parsed.error.issues.map((issue) => {
        const field = issue.path.join(".");
        return issue.code === "invalid_type" ? `${type} needs "${field}" (${issue.expected})` : `${type} "${field}": ${issue.message}`;
      });
      warnings.push({ item: index, type, warning: `Skipped: ${details.join("; ")}` });
      return;
    }
    try {
      const [item] = prepareItems([parsed.data], [...existing, ...items]);
      itemBBox(item);
      items.push(item);
      indexes.push(index);
    } catch (e) {
      warnings.push({ item: index, type, warning: `Skipped: ${(e as Error).message}` });
    }
  });
  return { items, indexes, warnings };
}

/** Bounding boxes that leave the page, for a per-item warning after drawing or moving. */
export function offPageWarning(box: BBox): string | undefined {
  // A few units of slack so a stroke drawn right on the page edge doesn't count.
  const slack = 4;
  const out = [box.x < -slack && "left", box.y < -slack && "top", box.x + box.w > PAGE_W + slack && "right", box.y + box.h > PAGE_H + slack && "bottom"].filter(Boolean);
  if (!out.length) return;
  return `Goes off the ${out.join(" and ")} edge of the page (bbox ${[box.x, box.y, box.w, box.h].map((v) => Math.round(v)).join(", ")}; the page is ${PAGE_W} x ${PAGE_H})`;
}

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
  const box = unrotatedBBox(item);
  return "rotation" in item && item.rotation ? rotatedBBox(box, item.rotation, item.rotation_center) : box;
}
function unrotatedBBox(item: Item): BBox {
  if (item.parts) return partsBBox(item.parts, item.graph?.origin);
  const stroked = ["path", "line", "arrow", "curved_arrow", "ellipse", "rect", "svg"].includes(item.type) && outlined(item);
  const padding = stroked ? (("width" in item ? item.width : undefined) ?? 3) / 2 : 0;
  switch (item.type) {
    case "spring": case "ground": case "axes": case "plot": case "shade": case "angle": case "point": return itemBBox(prepareItems([item])[0]);
    case "path": return pathBounds(pathData(item) + (item.head_d ?? ""), padding);
    case "line": return pointBounds([item.from, item.to], padding);
    case "arrow": return pathBounds(item.head_d !== undefined || item.head === "none" ? `M${item.from.join(",")}L${item.to.join(",")}${item.head_d ?? ""}` : arrowPath(item.from, item.to, item.width), (item.width ?? 3) / 2);
    case "curly": case "curved_arrow": {
      const shape = item.d === undefined ? prepareItems([item])[0] : item;
      return pathBounds((shape.d ?? "") + (shape.head_d ?? ""), padding);
    }
    case "ellipse": return pointBounds([[item.center[0] - item.rx, item.center[1] - (item.ry ?? item.rx)], [item.center[0] + item.rx, item.center[1] + (item.ry ?? item.rx)]], padding);
    case "web": case "rect": case "highlight": return pointBounds([[item.x, item.y], [item.x + item.w, item.y + item.h]], padding);
    case "svg": return pathBounds(item.d + (item.head_d ?? ""), item.head_d ? Math.max(padding, (item.width ?? 3) / 2) : padding);
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
    : item.type === "web" ? item.title : item.type === "molecule" ? item.smiles : item.group ?? item.type;
  return value.replace(/\s+/g, " ").slice(0, 80);
}

/** Translate the prepared outline instead of re-typesetting and changing its geometry. */
export function translateItem(item: Item, dx: number, dy: number): Item {
  if (![dx, dy].every(Number.isFinite)) throw new Error("Move offsets must be finite numbers");
  const point = ([x, y]: Point): Point => [x + dx, y + dy];
  const moved = { ...item };
  if ("x" in moved && typeof moved.x === "number" && typeof moved.y === "number") { moved.x += dx; moved.y += dy; }
  if ("from" in moved && Array.isArray(moved.from) && Array.isArray(moved.to)) { moved.from = point(moved.from); moved.to = point(moved.to); }
  if (moved.type === "axes") moved.origin = point(moved.origin);
  if (moved.type === "angle") moved.vertex = point(moved.vertex);
  if (moved.type === "point" && !moved.graph) moved.at = point(moved.at);
  if (moved.rotation_center) moved.rotation_center = point(moved.rotation_center);
  if (moved.graph) moved.graph = { ...moved.graph, origin: point(moved.graph.origin) };
  if (moved.parts) moved.parts = translateParts(moved.parts, dx, dy);
  if (moved.type === "ellipse") moved.center = point(moved.center);
  if (moved.type === "path") moved.points = moved.points.map(point);
  if (moved.atoms) moved.atoms = Object.fromEntries(Object.entries(moved.atoms).map(([id, at]) => [id, point(at)]));
  for (const key of ["d", "head_d"] as const) {
    if (!moved[key]) continue;
    const outline = svgpath(moved[key]);
    if ("err" in outline && outline.err) throw new Error(`Invalid SVG path: ${outline.err}`);
    moved[key] = outline.translate(dx, dy).round(4).toString();
  }
  // Inputs may be finite while arithmetic overflows. Validate the complete
  // result before the store replaces any items or JSON turns Infinity into null.
  itemBBox(moved);
  return moved;
}

type RenderItem = ItemInput & { d?: string; head_d?: string; head_filled?: boolean; parts?: Part[]; rotation_center?: Point };
export function itemToSvg(item: RenderItem): string {
  if ("rotation" in item && item.rotation) {
    const prepared = item.rotation_center ? item : prepareItems([item])[0];
    const center = prepared.rotation_center!;
    return `<g transform="rotate(${item.rotation % 360} ${center[0]} ${center[1]})">${unrotatedSvg(prepared)}</g>`;
  }
  return unrotatedSvg(item);
}
function unrotatedSvg(item: RenderItem): string {
  if (item.parts) return partsToSvg(item.parts);
  if ("fill_pattern" in item && item.fill_pattern) return partsToSvg(prepareItems([item])[0].parts!);
  const c = esc(("color" in item ? item.color : undefined) ?? DEFAULT_COLOR);
  const w = "width" in item && item.width ? item.width : 3;
  const strokeOf = (color: string) => `stroke="${color}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"`;
  const stroke = strokeOf(c);
  const dash = "dashed" in item && item.dashed ? ' stroke-dasharray="10 8"' : "";
  // Heads are never dashed; filled heads are also stroked so their tips match the line's round cap.
  const heads = item.head_d ? `<path d="${item.head_d}" fill="${"head_filled" in item && item.head_filled ? c : "none"}" ${stroke}/>` : "";
  switch (item.type) {
    case "spring": case "ground": case "axes": case "plot": case "shade": case "angle": case "point": return partsToSvg(prepareItems([item])[0].parts!);
    case "path":
      return `<path d="${pathData(item)}" fill="none" ${stroke}${dash}/>${heads}`;
    case "line":
      return `<line x1="${item.from[0]}" y1="${item.from[1]}" x2="${item.to[0]}" y2="${item.to[1]}" ${stroke}${item.dashed ? ' stroke-dasharray="10 8"' : ""}/>`;
    case "arrow":
      // Arrows drawn before head_d existed keep their original single-path shape.
      if (item.head_d === undefined && item.head === undefined) return `<path d="${arrowPath(item.from, item.to, w)}" fill="none" ${stroke}${dash}/>`;
      return `<path d="M${item.from.join(",")}L${item.to.join(",")}" fill="none" ${stroke}${dash}/>${heads}`;
    case "curly": case "curved_arrow": {
      if (item.d === undefined) return itemToSvg(prepareItems([item])[0]);
      return `<path d="${item.d}" fill="none" ${stroke.replace('stroke-linecap="round"', 'stroke-linecap="butt"')}/>${heads}`;
    }
    case "ellipse":
      return `<ellipse cx="${item.center[0]}" cy="${item.center[1]}" rx="${item.rx}" ry="${item.ry ?? item.rx}" fill="${esc(item.fill ?? "none")}" ${outlined(item) ? stroke : 'stroke="none"'}/>`;
    case "web": return `<g><rect x="${item.x}" y="${item.y}" width="${item.w}" height="${item.h}" fill="#f5f1e9" stroke="#888"/><text x="${item.x + 12}" y="${item.y + 28}" font-family="sans-serif" font-size="18">${esc(item.title.slice(0, 70))}</text><text x="${item.x + 12}" y="${item.y + 52}" font-family="sans-serif" font-size="13">Interactive block, open it on the iPad</text></g>`;
    case "rect":
      return `<rect x="${item.x}" y="${item.y}" width="${item.w}" height="${item.h}" rx="4" fill="${esc(item.fill ?? "none")}" ${outlined(item) ? stroke : 'stroke="none"'}/>`;
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
      return `<path d="${esc(item.d)}" fill="${esc(item.fill ?? "none")}" ${outlined(item) ? stroke : 'stroke="none"'}${dash}/>${heads}`;
    case "hint": {
      const shape = item.d === undefined ? prepareItems([item])[0] : item as Item;
      const label = shape.d ? `<path d="${esc(shape.d)}" fill="${c}"/>` : "";
      return item.revealed ? label : `<rect x="${item.x}" y="${item.y}" width="${shape.w}" height="${shape.h}" rx="8" fill="${c}" fill-opacity="0.1" stroke="${c}" stroke-width="1.5"/>${label}`;
    }
    case "molecule": {
      const shape = item.d === undefined ? renderMolecule(item.smiles, item.x, item.y, item.size ?? 180, item) : item;
      return shape.d ? `<path d="${esc(shape.d)}" fill="${c}"/>` : "";
    }
    case "math":
      return item.d ? `<path d="${esc(item.d)}" fill="${c}"/>` : "";
  }
}
