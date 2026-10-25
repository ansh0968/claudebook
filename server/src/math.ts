// LaTeX -> one flat SVG path in page coordinates, so the server and the iPad app can both
// draw typeset math as plain filled ink without shipping a math engine to the app.
import { mathjax } from "mathjax-full/js/mathjax.js";
import { TeX } from "mathjax-full/js/input/tex.js";
import { SVG } from "mathjax-full/js/output/svg.js";
import { liteAdaptor, type LiteAdaptor } from "mathjax-full/js/adaptors/liteAdaptor.js";
import { RegisterHTMLHandler } from "mathjax-full/js/handlers/html.js";
import { AllPackages } from "mathjax-full/js/input/tex/AllPackages.js";
import type { LiteElement } from "mathjax-full/js/adaptors/lite/Element.js";
import svgpath from "svgpath";
import { clipPathToRect, pathBounds, strokePolyline, type Point } from "./geometry.js";

let engine: { adaptor: LiteAdaptor; doc: ReturnType<typeof mathjax.document> } | undefined;

function init() {
  if (engine) return engine;
  const adaptor = liteAdaptor();
  RegisterHTMLHandler(adaptor);
  const tex = new TeX({
    // noundefined would draw an unknown \command as red text; we want it to fail so Claude hears about it.
    packages: AllPackages.filter((p) => p !== "bussproofs" && p !== "noundefined"),
    // Surface bad LaTeX as an error instead of drawing a red error box on the user's page.
    formatError: (_jax: unknown, err: Error) => {
      throw err;
    },
  });
  const doc = mathjax.document("", { InputJax: tex, OutputJax: new SVG({ fontCache: "none" }) });
  engine = { adaptor, doc };
  return engine;
}

export interface MathShape {
  d: string;
  w: number;
  h: number;
}

/** MathJax's CSS strokes table rules and frames 0.07em wide; the SVG itself only carries the class. */
const RULE = 70;

/** A rectangle outline as a filled ring: outer clockwise, inner counter-clockwise, so nonzero fill leaves a hole. */
function ring(x: number, y: number, w: number, h: number, sw: number) {
  const o = sw / 2;
  const outer = `M${x - o} ${y - o}H${x + w + o}V${y + h + o}H${x - o}Z`;
  if (w <= sw || h <= sw) return outer;
  return `${outer}M${x + o} ${y + o}V${y + h - o}H${x + w - o}V${y + o}Z`;
}

/** A stroked line as filled quads, optionally dashed like MathJax's mjx-dashed / mjx-dotted rules. */
function rule(a: Point, b: Point, sw: number, dash?: [number, number]) {
  if (!dash) return strokePolyline([a, b], sw);
  const len = Math.hypot(b[0] - a[0], b[1] - a[1]);
  const parts: string[] = [];
  for (let t = 0; t < len; t += dash[0] + dash[1]) {
    const t2 = Math.min(len, t + dash[0]);
    const at = (s: number): Point => [a[0] + (b[0] - a[0]) * s / len, a[1] + (b[1] - a[1]) * s / len];
    parts.push(strokePolyline([at(t), at(t2)], sw));
  }
  return parts.join("");
}

const dashOf = (cls: string): [number, number] | undefined =>
  /mjx-dashed/.test(cls) ? [140, 140] : /mjx-dotted/.test(cls) ? [40, 100] : undefined;

/**
 * Typeset `latex` with its top-left at (x, y). `size` is roughly the height of one line of text,
 * matching the `text` item, so math and handwriting-style text sit nicely together.
 * The visible ink and returned box start exactly at (x, y), excluding layout padding.
 */
export function renderMath(latex: string, x: number, y: number, size = 36): MathShape {
  const { adaptor, doc } = init();
  const node = doc.convert(latex, { display: true }) as LiteElement;
  const svg = adaptor.tags(node, "svg")[0];
  if (!svg) throw new Error("MathJax produced no SVG");
  const attr = (el: LiteElement, k: string) => adaptor.getAttribute(el, k) as string | undefined;
  const num = (el: LiteElement, k: string, fallback = 0) => {
    const v = parseFloat(attr(el, k) ?? "");
    return Number.isFinite(v) ? v : fallback;
  };

  /** Outlines of `el` in its parent's coordinate system. */
  const collect = (el: LiteElement): string[] => {
    const kind = adaptor.kind(el);
    let parts: string[] = [];
    const cls = String(attr(el, "class") ?? "");
    if (kind === "path") {
      const d = String(attr(el, "d") ?? "");
      // Glyphs are filled; the few MathJax paths drawn with fill="none" (e.g. \longdiv) are strokes.
      if (attr(el, "fill") === "none") {
        const sw = num(el, "stroke-width", RULE);
        const pts: Point[] = [];
        svgpath(d).abs().unshort().unarc().iterate((s) => { const n = s.slice(1) as number[]; if (n.length >= 2) pts.push([n[n.length - 2], n[n.length - 1]]); });
        if (pts.length > 1) parts.push(strokePolyline(pts, sw));
      } else if (d) parts.push(d);
    } else if (kind === "rect") {
      const [rx, ry, rw, rh] = [num(el, "x"), num(el, "y"), num(el, "width"), num(el, "height")];
      // Fraction bars and sqrt vinculums are filled; table frames and \boxed are stroked outlines.
      const stroked = attr(el, "data-frame") !== undefined || attr(el, "fill") === "none";
      if (stroked) parts.push(ring(rx, ry, rw, rh, num(el, "stroke-width", RULE)));
      else if (rw > 0 && rh > 0) parts.push(`M${rx} ${ry}H${rx + rw}V${ry + rh}H${rx}Z`);
    } else if (kind === "line") {
      const sw = num(el, "stroke-width", RULE);
      parts.push(rule([num(el, "x1"), num(el, "y1")], [num(el, "x2"), num(el, "y2")], sw, dashOf(cls)));
    } else if (kind === "ellipse" || kind === "circle") {
      const cx = num(el, "cx"), cy = num(el, "cy"), rx = num(el, "rx", num(el, "r")), ry = num(el, "ry", num(el, "r"));
      const sw = num(el, "stroke-width", RULE);
      const pts = Array.from({ length: 49 }, (_, i): Point => [cx + rx * Math.cos(i * Math.PI / 24), cy + ry * Math.sin(i * Math.PI / 24)]);
      parts.push(strokePolyline(pts, sw));
    } else if (kind === "polygon" || kind === "polyline") {
      const n = String(attr(el, "points") ?? "").trim().split(/[\s,]+/).map(Number);
      const pts: Point[] = [];
      for (let i = 0; i + 1 < n.length; i += 2) pts.push([n[i], n[i + 1]]);
      if (pts.length > 1) parts.push(attr(el, "fill") === "none" ? strokePolyline(pts, num(el, "stroke-width", RULE)) : `M${pts.map((p) => p.join(" ")).join("L")}Z`);
    }
    for (const child of adaptor.childNodes(el)) {
      if (adaptor.kind(child as LiteElement) !== "#text") parts.push(...collect(child as LiteElement));
    }
    if (kind === "svg") {
      // Stretchy delimiters and extensible arrows are nested viewports: a glyph scaled past the
      // viewport and clipped to it. Without the clip, vmatrix bars overshoot and \xrightarrow's
      // shaft pokes through its labels.
      const vb = String(attr(el, "viewBox") ?? "").split(/[\s,]+/).map(Number);
      const w = num(el, "width"), h = num(el, "height");
      if (vb.length === 4 && vb.every(Number.isFinite) && vb[2] > 0 && vb[3] > 0) {
        const [bx, by, bw, bh] = vb;
        parts = parts.map((d) => clipPathToRect(d, { x: bx, y: by, w: bw, h: bh })).filter(Boolean);
        const t = `translate(${num(el, "x")},${num(el, "y")}) scale(${(w || bw) / bw},${(h || bh) / bh}) translate(${-bx},${-by})`;
        parts = parts.map((d) => svgpath(d).transform(t).toString());
      } else {
        parts = parts.map((d) => svgpath(d).translate(num(el, "x"), num(el, "y")).toString());
      }
    }
    const t = attr(el, "transform");
    return t ? parts.map((d) => svgpath(d).transform(t).toString()) : parts;
  };

  const parts: string[] = [];
  for (const child of adaptor.childNodes(svg)) {
    if (adaptor.kind(child as LiteElement) !== "#text") parts.push(...collect(child as LiteElement));
  }
  if (!parts.length) throw new Error("Nothing to draw for that LaTeX");

  // MathJax units are 1/1000 em. Make 1em = 0.8 * size, same ratio the text item uses.
  const s = (size * 0.8) / 1000;
  // Layout struts and side bearings are invisible. Anchors and placement must use ink,
  // including the real curve extrema, so even tall formulas land at the requested point.
  const raw = parts.join("");
  const ink = pathBounds(raw);
  const toPage = `translate(${x},${y}) scale(${s}) translate(${-ink.x},${-ink.y})`;
  // Absolute, unshortened commands keep the iPad's small path parser on its well-trodden paths.
  const d = parts.map((p) => svgpath(p).transform(toPage).abs().unshort().round(2).toString()).join("");
  return { d, w: +(ink.w * s).toFixed(1), h: +(ink.h * s).toFixed(1) };
}
