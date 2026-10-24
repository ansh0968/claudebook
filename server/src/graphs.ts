import { z } from "zod";
import svgpath from "svgpath";
import { renderHandwriting } from "./handwriting.js";
import { parseExpression, expressionNumber } from "./expression.js";
import type { Part } from "./parts.js";
import { clipPathToRect, headsFor, strokePolyline, type Point } from "./geometry.js";

const pt = z.tuple([z.number(), z.number()]);
const range = z.tuple([z.number(), z.number()]);
const pair = z.union([z.number().positive(), z.tuple([z.number().positive(), z.number().positive()])]);
const style = { color: z.string().optional(), width: z.number().positive().optional(), group: z.string().optional() };
const axesRef = z.string().min(1).describe('Axes item id or name, including earlier axes in this batch. Example: axes:"g1"');
export const GraphSchemas = [
  z.object({ type: z.literal("axes"), origin: pt, xrange: range, yrange: range, unit: pair.optional(), ticks: z.boolean().optional(), tick_step: pair.optional(), labels: z.boolean().optional(), x_label: z.string().optional(), y_label: z.string().optional(), grid: z.boolean().optional(), name: z.string().min(1).optional(), ...style })
    .describe('Coordinate axes with ticks, numbers, arrowheads and optional grid. unit is page units per graph unit (default 40); tick_step defaults 1; ticks/labels default true. Example: {type:"axes",origin:[300,600],xrange:[-2,5],yrange:[-1,4],unit:60,name:"g1",grid:true,x_label:"x",y_label:"y"}'),
  z.object({ type: z.literal("plot"), axes: axesRef, fn: z.string().optional(), from: z.number().optional(), to: z.number().optional(), samples: z.number().int().min(2).max(5000).optional(), x: z.string().optional(), y: z.string().optional(), t: z.tuple([z.union([z.number(), z.string()]), z.union([z.number(), z.string()])]).optional(), dashed: z.boolean().optional(), ...style })
    .describe('Safe expression plot, clipped to axes. samples defaults 200; from/to default xrange. Supports x,t,+ - * / ^, implicit multiplication, pi,e,sin cos tan asin acos atan sinh cosh tanh log(base 10) ln exp sqrt abs floor ceil. Example: {type:"plot",axes:"g1",fn:"x^2/2",from:-2,to:4,dashed:true}. Parametric: {type:"plot",axes:"g1",x:"cos(t)",y:"sin(t)",t:[0,"2pi"]}'),
  z.object({ type: z.literal("shade"), axes: axesRef, fn1: z.string(), fn2: z.string().optional(), from: z.number().optional(), to: z.number().optional(), opacity: z.number().min(0).max(1).optional(), ...style })
    .describe('Fill between fn1 and fn2 (default "axis", meaning y=0), clipped to axes, opacity default 0.25. Example: {type:"shade",axes:"g1",fn1:"x^2/2",fn2:"axis",from:0,to:2}'),
  z.object({ type: z.literal("point"), at: pt, label: z.string().optional(), label_pos: z.enum(["ne", "nw", "se", "sw"]).optional(), filled: z.boolean().optional(), axes: axesRef.optional(), ...style })
    .describe('Dot with label; at is graph units when axes is given, otherwise page units. filled defaults true; label_pos defaults ne. Example: {type:"point",axes:"g1",at:[1,2],label:"P(1,2)",label_pos:"nw",filled:false}'),
  z.object({ type: z.literal("angle"), vertex: pt, from: pt, to: pt, radius: z.number().positive().optional(), label: z.string().optional(), right_angle: z.boolean().optional(), ...style })
    .describe('Short arc between two rays in page coordinates, radius default 30; auto square for 90° ±0.5°. Example: {type:"angle",vertex:[300,600],from:[400,600],to:[360,520],label:"θ",radius:35}'),
] as const;
export type GraphInput = z.infer<typeof GraphSchemas[number]>;
export interface GraphTransform { origin: Point; unit: Point; xrange: Point; yrange: Point }
type Reference = { id: string; type: string; name?: string; graph?: GraphTransform };
const pairValue = (v: number | Point | undefined, fallback: number): Point => typeof v === "number" ? [v, v] : v ?? [fallback, fallback];
const pagePoint = (g: GraphTransform, x: number, y: number): Point => [g.origin[0] + x * g.unit[0], g.origin[1] - y * g.unit[1]];
const path = (points: Point[], close = false) => `M${points.join("L")}${close ? "Z" : ""}`;
export function graphClip(g: GraphTransform) {
  return path([pagePoint(g, g.xrange[0], g.yrange[0]), pagePoint(g, g.xrange[1], g.yrange[0]), pagePoint(g, g.xrange[1], g.yrange[1]), pagePoint(g, g.xrange[0], g.yrange[1])], true);
}
function findAxes(ref: string, available: Reference[]): GraphTransform {
  const axes = [...available].reverse().find(i => i.type === "axes" && (i.id === ref || i.name === ref));
  if (!axes?.graph) throw new Error(`Unknown axes ${JSON.stringify(ref)}; define named axes earlier in the batch or use an existing axes id`);
  return { origin: [...axes.graph.origin], unit: [...axes.graph.unit], xrange: [...axes.graph.xrange], yrange: [...axes.graph.yrange] };
}
function increasing([a, b]: Point, name: string) {
  if (!Number.isFinite(a) || !Number.isFinite(b) || b <= a || !Number.isFinite(b - a)) throw new Error(`${name} must be a finite increasing range`);
}
function label(text: string, at: Point, color: string, alignment = "center"): Part {
  const s = renderHandwriting(text, 0, 0, 22);
  const dx = at[0] - (alignment === "left" ? 0 : alignment === "right" ? s.w : s.w / 2);
  return { d: svgpath(s.d).translate(dx, at[1]).toString(), fill: color };
}
function ticks([a, b]: Point, step: number) {
  if (!Number.isFinite(step) || step <= 0 || (b - a) / step > 1000) throw new Error("Tick step must be positive and produce at most 1000 ticks per axis");
  return Array.from({ length: Math.max(0, Math.floor(b / step) - Math.ceil(a / step) + 1) }, (_, i) => (Math.ceil(a / step) + i) * step);
}

export function prepareGraph(i: GraphInput, available: Reference[]): { parts: Part[]; graph?: GraphTransform } {
  const color = i.color ?? "#D97757", width = i.width ?? 3, parts: Part[] = [];
  const line = (a: Point, b: Point, stroke = color, w = width): Part => ({ d: path([a, b]), stroke, width: w });
  if (i.type === "axes") {
    increasing(i.xrange, "xrange"); increasing(i.yrange, "yrange");
    const g: GraphTransform = { origin: i.origin, unit: pairValue(i.unit, 40), xrange: i.xrange, yrange: i.yrange };
    const [sx, sy] = pairValue(i.tick_step, 1), xs = ticks(g.xrange, sx), ys = ticks(g.yrange, sy);
    if (i.grid) {
      for (const x of xs) parts.push(line(pagePoint(g, x, g.yrange[0]), pagePoint(g, x, g.yrange[1]), "#DDE2E6", 1));
      for (const y of ys) parts.push(line(pagePoint(g, g.xrange[0], y), pagePoint(g, g.xrange[1], y), "#DDE2E6", 1));
    }
    const axis = (a: Point, b: Point) => {
      parts.push(line(a, b));
      parts.push({ d: headsFor(path([a, b]), "end", width, true)!, fill: color });
    };
    axis(pagePoint(g, g.xrange[0], 0), pagePoint(g, g.xrange[1], 0));
    axis(pagePoint(g, 0, g.yrange[0]), pagePoint(g, 0, g.yrange[1]));
    const number = (n: number) => Number(n.toPrecision(8)).toString();
    for (const x of xs) if (Math.abs(x) > 1e-10) {
      const p = pagePoint(g, x, 0);
      if (i.ticks !== false) parts.push(line([p[0], p[1] - 5], [p[0], p[1] + 5], color, 1.5));
      if (i.labels !== false) parts.push(label(number(x), [p[0], p[1] + 9], color));
    }
    for (const y of ys) if (Math.abs(y) > 1e-10) {
      const p = pagePoint(g, 0, y);
      if (i.ticks !== false) parts.push(line([p[0] - 5, p[1]], [p[0] + 5, p[1]], color, 1.5));
      if (i.labels !== false) parts.push(label(number(y), [p[0] - 11, p[1] - 11], color, "right"));
    }
    if (i.labels !== false) {
      parts.push(label("O", [i.origin[0] - 10, i.origin[1] + 9], color, "right"));
      const x = pagePoint(g, g.xrange[1], 0), y = pagePoint(g, 0, g.yrange[1]);
      parts.push(label(i.x_label ?? "x", [x[0] + 15, x[1] - 14], color, "left"), label(i.y_label ?? "y", [y[0], y[1] - 32], color));
    }
    return { parts, graph: g };
  }
  if (i.type === "angle") {
    const a = [i.from[0] - i.vertex[0], i.from[1] - i.vertex[1]], b = [i.to[0] - i.vertex[0], i.to[1] - i.vertex[1]];
    const al = Math.hypot(...a), bl = Math.hypot(...b);
    if (!al || !bl) throw new Error("Angle rays must differ from the vertex");
    const start = Math.atan2(a[1], a[0]), delta = Math.atan2(a[0] * b[1] - a[1] * b[0], a[0] * b[0] + a[1] * b[1]), r = i.radius ?? 30;
    const at = (theta: number, radius = r): Point => [i.vertex[0] + Math.cos(theta) * radius, i.vertex[1] + Math.sin(theta) * radius];
    if (i.right_angle || Math.abs(Math.abs(delta) - Math.PI / 2) <= Math.PI / 360) {
      const p = at(start), q = at(start + delta);
      parts.push({ d: path([p, [p[0] + q[0] - i.vertex[0], p[1] + q[1] - i.vertex[1]], q]), stroke: color, width });
    } else {
      parts.push({ d: path(Array.from({ length: 41 }, (_, n) => at(start + delta * n / 40))), stroke: color, width });
    }
    if (i.label) parts.push(label(i.label, [at(start + delta / 2, r + 24)[0], at(start + delta / 2, r + 24)[1] - 11], color));
    return { parts };
  }
  if (i.type === "point") {
    const g = i.axes ? findAxes(i.axes, available) : undefined, at = g ? pagePoint(g, ...i.at) : i.at;
    const [x, y] = at, r = 4, k = r * 0.5522847498;
    parts.push({ d: `M${x + r},${y}C${x + r},${y + k} ${x + k},${y + r} ${x},${y + r}C${x - k},${y + r} ${x - r},${y + k} ${x - r},${y}C${x - r},${y - k} ${x - k},${y - r} ${x},${y - r}C${x + k},${y - r} ${x + r},${y - k} ${x + r},${y}Z`, stroke: color, width: 2, fill: i.filled === false ? "#FFFFFF" : color });
    const pos = i.label_pos ?? "ne";
    if (i.label) parts.push(label(i.label, [x + (pos.endsWith("e") ? 10 : -10), y + (pos.startsWith("n") ? -28 : 8)], color, pos.endsWith("e") ? "left" : "right"));
    return { parts, graph: g };
  }
  const g = findAxes(i.axes, available), clip = graphClip(g), samples = i.type === "plot" ? i.samples ?? 200 : 200;
  const parametric = i.type === "plot" && (i.x !== undefined || i.y !== undefined || i.t !== undefined);
  if (i.type === "plot" && (parametric ? !i.x || !i.y || !i.t || i.fn !== undefined || i.from !== undefined || i.to !== undefined : !i.fn)) throw new Error("Plot needs either fn/from/to or x/y/t, not both");
  const from = parametric && i.type === "plot" ? expressionNumber(i.t![0]) : i.from ?? g.xrange[0];
  const to = parametric && i.type === "plot" ? expressionNumber(i.t![1]) : i.to ?? g.xrange[1];
  increasing([from, to], "Plot interval");
  const f = parseExpression(i.type === "shade" ? i.fn1 : parametric ? i.y! : i.fn!, parametric ? "t" : "x");
  const fx = parametric && i.type === "plot" ? parseExpression(i.x!, "t") : (x: number) => x;
  const f2 = i.type === "shade" && i.fn2 && i.fn2 !== "axis" ? parseExpression(i.fn2) : () => 0;
  const data = Array.from({ length: samples + 1 }, (_, n) => {
    const v = from + (to - from) * (n / samples);
    return [fx(v), f(v), f2(v)];
  });
  const spanX = g.xrange[1] - g.xrange[0], spanY = g.yrange[1] - g.yrange[0];
  if (i.type === "plot") {
    // Split discontinuities before outlining the stroke, then use the shared
    // filled-path clipper so no viewport edge closes an open plot segment.
    const p0 = pagePoint(g, g.xrange[0], g.yrange[1]);
    const rect = { x: p0[0], y: p0[1], w: spanX * g.unit[0], h: spanY * g.unit[1] };
    let run: Point[] = [];
    const outlines: string[] = [];
    const dashBudget = { segments: 0 };
    const flush = () => {
      const runs = i.dashed ? dashedRuns(run, dashBudget) : [run];
      for (const points of runs) if (points.length > 1) {
        const d = clipPathToRect(strokePolyline(points, width), rect);
        if (d) outlines.push(d);
      }
      run = [];
    };
    for (const v of data) {
      if (!v.every(Number.isFinite)) { flush(); continue; }
      const p = pagePoint(g, v[0], v[1]), prev = run.at(-1);
      if (!p.every(Number.isFinite)) { flush(); continue; }
      if (prev && (Math.abs(prev[0] - p[0]) > rect.w || Math.abs(prev[1] - p[1]) > rect.h)) flush();
      run.push(p);
    }
    flush();
    if (outlines.length) parts.push({ d: outlines.join(""), fill: color, clip });
  } else {
    const p0 = pagePoint(g, g.xrange[0], g.yrange[1]);
    const rect = { x: p0[0], y: p0[1], w: spanX * g.unit[0], h: spanY * g.unit[1] };
    let run: number[][] = [];
    const flush = () => {
      if (run.length > 1) {
        const d = clipPathToRect(path([...run.map(v => pagePoint(g, v[0], v[1])), ...[...run].reverse().map(v => pagePoint(g, v[0], v[2]))], true), rect);
        if (d) parts.push({ d, fill: color, opacity: i.opacity ?? 0.25, clip });
      }
      run = [];
    };
    for (const v of data) {
      if (!v.every(Number.isFinite)) { flush(); continue; }
      if (run.length && (Math.abs(v[1] - run.at(-1)![1]) > spanY || Math.abs(v[2] - run.at(-1)![2]) > spanY)) flush();
      run.push(v);
    }
    flush();
  }
  return { parts, graph: g };
}

/** Dashes follow page distance along the sampled curve, including across its joints. */
function dashedRuns(points: Point[], budget: { segments: number }): Point[][] {
  const runs: Point[][] = [];
  let on = true, remaining = 10, run: Point[] = [];
  for (let n = 1; n < points.length; n++) {
    const a = points[n - 1], b = points[n], length = Math.hypot(b[0] - a[0], b[1] - a[1]);
    let used = 0;
    while (used < length) {
      // Bound the generated geometry as well as input samples. Very large axes
      // can contain billions of page-length dashes despite having only two samples.
      if (++budget.segments > 20000) throw new Error("Dashed plot exceeds 20000 segments; reduce the axes scale or plot interval");
      const next = Math.min(length, used + remaining);
      if (!Number.isFinite(length) || next <= used) throw new Error("Dashed plot coordinates exceed numeric precision");
      const at = (d: number): Point => [a[0] + (b[0] - a[0]) * d / length, a[1] + (b[1] - a[1]) * d / length];
      if (on) { if (!run.length) run.push(at(used)); run.push(at(next)); }
      remaining -= next - used; used = next;
      if (remaining < 1e-8) {
        if (on) { runs.push(run); run = []; }
        on = !on; remaining = on ? 10 : 8;
      }
    }
  }
  if (run.length > 1) runs.push(run);
  return runs;
}
