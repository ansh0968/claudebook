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

let engine: { adaptor: LiteAdaptor; doc: ReturnType<typeof mathjax.document> } | undefined;

function init() {
  if (engine) return engine;
  const adaptor = liteAdaptor();
  RegisterHTMLHandler(adaptor);
  const tex = new TeX({
    packages: AllPackages.filter((p) => p !== "bussproofs"),
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

/**
 * Typeset `latex` with its top-left at (x, y). `size` is roughly the height of one line of text,
 * matching the `text` item, so math and handwriting-style text sit nicely together.
 */
export function renderMath(latex: string, x: number, y: number, size = 36): MathShape {
  const { adaptor, doc } = init();
  const node = doc.convert(latex, { display: true }) as LiteElement;
  const svg = adaptor.tags(node, "svg")[0];
  if (!svg) throw new Error("MathJax produced no SVG");
  const [minX, minY, vw, vh] = String(adaptor.getAttribute(svg, "viewBox")).split(/\s+/).map(Number);

  // MathJax units are 1/1000 em. Make 1em = 0.8 * size, same ratio the text item uses.
  const s = (size * 0.8) / 1000;
  const toPage = `translate(${x},${y}) scale(${s}) translate(${-minX},${-minY})`;

  const parts: string[] = [];
  const walk = (el: LiteElement, transforms: string[]) => {
    const t = adaptor.getAttribute(el, "transform");
    const chain = t ? [t, ...transforms] : transforms;
    const kind = adaptor.kind(el);
    let d: string | undefined;
    if (kind === "path") {
      d = String(adaptor.getAttribute(el, "d") ?? "");
    } else if (kind === "rect") {
      // Fraction bars, overlines, sqrt vinculum.
      const n = (k: string) => Number(adaptor.getAttribute(el, k) ?? 0);
      const [rx, ry, rw, rh] = [n("x"), n("y"), n("width"), n("height")];
      if (rw > 0 && rh > 0) d = `M${rx} ${ry}H${rx + rw}V${ry + rh}H${rx}Z`;
    } else if (kind === "line") {
      const n = (k: string) => Number(adaptor.getAttribute(el, k) ?? 0);
      const half = Math.max(n("stroke-width"), 40) / 2;
      const [x1, y1, x2, y2] = [n("x1"), n("y1"), n("x2"), n("y2")];
      // Lines become thin boxes so everything stays fill-only.
      d = x1 === x2
        ? `M${x1 - half} ${y1}H${x1 + half}V${y2}H${x1 - half}Z`
        : `M${x1} ${y1 - half}H${x2}V${y2 + half}H${x1}Z`;
    }
    if (d) {
      let p = svgpath(d);
      for (const tr of chain) p = p.transform(tr);
      parts.push(p.transform(toPage).round(2).toString());
    }
    for (const child of adaptor.childNodes(el)) {
      if (adaptor.kind(child as LiteElement) !== "#text") walk(child as LiteElement, chain);
    }
  };
  for (const child of adaptor.childNodes(svg)) walk(child as LiteElement, []);

  if (!parts.length) throw new Error("Nothing to draw for that LaTeX");
  return { d: parts.join(""), w: +(vw * s).toFixed(1), h: +(vh * s).toFixed(1) };
}
