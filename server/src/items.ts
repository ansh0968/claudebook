// What Claude can put on a page. Kept deliberately high level: Claude is much better at
// "circle this box" than at plotting hundreds of exact points.
import { z } from "zod";

const pt = z.tuple([z.number(), z.number()]).describe("[x, y] in page coordinates");
const color = z.string().optional().describe("CSS color, default Claude orange #D97757. Use red #E5484D for mistakes, green #30A46C for corrections");
const width = z.number().optional().describe("Stroke width in page units, default 3");

export const ItemSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("path"), points: z.array(pt).min(2), color, width, closed: z.boolean().optional() })
    .describe("Freehand stroke through the points, smoothed"),
  z.object({ type: z.literal("line"), from: pt, to: pt, color, width, dashed: z.boolean().optional() }),
  z.object({ type: z.literal("arrow"), from: pt, to: pt, color, width }),
  z.object({ type: z.literal("ellipse"), center: pt, rx: z.number(), ry: z.number().optional(), color, width, fill: z.string().optional() })
    .describe("Circle or ellipse. Great for circling mistakes: wrap the text box with some padding"),
  z.object({ type: z.literal("rect"), x: z.number(), y: z.number(), w: z.number(), h: z.number(), color, width, fill: z.string().optional() }),
  z.object({ type: z.literal("highlight"), x: z.number(), y: z.number(), w: z.number(), h: z.number(), color: z.string().optional() })
    .describe("Translucent marker over a region, default yellow"),
  z.object({ type: z.literal("text"), x: z.number(), y: z.number(), text: z.string(), size: z.number().optional(), color })
    .describe("Handwritten-style text. x,y is the top-left. size is the line height, default 32. Use \\n for new lines"),
  z.object({ type: z.literal("svg"), d: z.string(), color, width, fill: z.string().optional() })
    .describe("Raw SVG path data in page coordinates, for figures and diagrams"),
]);

export type ItemInput = z.infer<typeof ItemSchema>;
export type Item = ItemInput & { id: string; createdAt: string };

const DEFAULT_COLOR = "#D97757";

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** Catmull-Rom through the points, as cubic beziers. Makes Claude's strokes look like ink, not polylines. */
function smoothPath(points: [number, number][], closed = false) {
  if (points.length < 3) return `M${points.map((p) => p.join(",")).join(" L")}`;
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

export function itemToSvg(item: ItemInput): string {
  const c = esc(item.color ?? DEFAULT_COLOR);
  const w = "width" in item && item.width ? item.width : 3;
  const stroke = `stroke="${c}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"`;
  switch (item.type) {
    case "path":
      return `<path d="${smoothPath(item.points, item.closed)}" fill="none" ${stroke}/>`;
    case "line":
      return `<line x1="${item.from[0]}" y1="${item.from[1]}" x2="${item.to[0]}" y2="${item.to[1]}" ${stroke}${item.dashed ? ' stroke-dasharray="10 8"' : ""}/>`;
    case "arrow": {
      const [x1, y1] = item.from, [x2, y2] = item.to;
      const a = Math.atan2(y2 - y1, x2 - x1), head = 10 + w * 2;
      const h1 = [x2 - head * Math.cos(a - 0.45), y2 - head * Math.sin(a - 0.45)];
      const h2 = [x2 - head * Math.cos(a + 0.45), y2 - head * Math.sin(a + 0.45)];
      return `<path d="M${x1},${y1} L${x2},${y2} M${h1.join(",")} L${x2},${y2} L${h2.join(",")}" fill="none" ${stroke}/>`;
    }
    case "ellipse":
      return `<ellipse cx="${item.center[0]}" cy="${item.center[1]}" rx="${item.rx}" ry="${item.ry ?? item.rx}" fill="${esc(item.fill ?? "none")}" ${stroke}/>`;
    case "rect":
      return `<rect x="${item.x}" y="${item.y}" width="${item.w}" height="${item.h}" rx="4" fill="${esc(item.fill ?? "none")}" ${stroke}/>`;
    case "highlight":
      return `<rect x="${item.x}" y="${item.y}" width="${item.w}" height="${item.h}" fill="${esc(item.color ?? "#FFE066")}" fill-opacity="0.45"/>`;
    case "text": {
      const size = item.size ?? 32;
      const lines = item.text.split("\n").map((l, i) => `<tspan x="${item.x}" dy="${i === 0 ? size * 0.8 : size}">${esc(l)}</tspan>`);
      return `<text x="${item.x}" y="${item.y}" font-family="Caveat, 'Comic Neue', 'DejaVu Sans', sans-serif" font-size="${size}" fill="${c}">${lines.join("")}</text>`;
    }
    case "svg":
      return `<path d="${esc(item.d)}" fill="${esc(item.fill ?? "none")}" ${stroke}/>`;
  }
}
