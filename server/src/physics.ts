import { z } from "zod";
import svgpath from "svgpath";
import { pathBounds, pointBounds, type BBox, type Point } from "./geometry.js";
import type { Part } from "./parts.js";

const pt = z.tuple([z.number(), z.number()]);
const style = { color: z.string().optional(), width: z.number().positive().optional(), group: z.string().optional() };
export const rotation = z.number().optional().describe('Degrees clockwise on screen around the positioned item bbox centre. Example: rotation:30');
export const patternFields = {
  fill_pattern: z.enum(["cross", "dot", "hatch"]).optional().describe('Clipped field pattern: cross = into page (⊗), dot = out (⊙), hatch = parallel lines. Example: fill_pattern:"cross"'),
  pattern_spacing: z.number().positive().optional().describe('Pattern spacing in page units, default 20. Example: pattern_spacing:25'),
  pattern_angle: z.number().optional().describe('Hatch angle in clockwise screen degrees, default 45. Example: pattern_angle:30'),
};
export const PhysicsSchemas = [
  z.object({ type: z.literal("spring"), from: pt, to: pt, coils: z.number().int().min(1).max(100).optional(), amplitude: z.number().positive().optional(), ...style })
    .describe('Zigzag spring with straight end leads, coils default 6, amplitude default 15 page units. Example: {type:"spring",from:[100,400],to:[400,400],coils:6,amplitude:15}'),
  z.object({ type: z.literal("ground"), from: pt, to: pt, side: z.enum(["below", "above", "left", "right"]).optional(), hatch_length: z.number().positive().optional(), spacing: z.number().positive().optional(), ...style })
    .describe('Surface with diagonal hatching on the requested screen side, including slanted inclines. side defaults below, hatch_length 14, spacing 12. Example: {type:"ground",from:[100,600],to:[650,350],side:"below"}'),
] as const;
export type PhysicsInput = z.infer<typeof PhysicsSchemas[number]>;
const path = (points: Point[], close = false) => `M${points.join("L")}${close ? "Z" : ""}`;
export function preparePhysics(i: PhysicsInput): Part[] {
  const dx = i.to[0] - i.from[0], dy = i.to[1] - i.from[1], length = Math.hypot(dx, dy);
  if (!Number.isFinite(length) || !length) throw new Error(`${i.type} endpoints must differ and have finite separation`);
  const ux = dx / length, uy = dy / length, nx = -uy, ny = ux;
  const at = (along: number, normal = 0): Point => [i.from[0] + ux * along + nx * normal, i.from[1] + uy * along + ny * normal];
  let d: string;
  if (i.type === "spring") {
    const lead = Math.min(20, length * 0.12), coils = i.coils ?? 6, amplitude = i.amplitude ?? 15;
    const points: Point[] = [i.from, at(lead)];
    for (let n = 0; n < coils * 2; n++) points.push(at(lead + (length - lead * 2) * (n + 0.5) / (coils * 2), n % 2 ? -amplitude : amplitude));
    points.push(at(length - lead), i.to);
    d = path(points);
  } else {
    const spacing = i.spacing ?? 12, hatch = i.hatch_length ?? 14;
    if (length / spacing > 2000) throw new Error("Ground spacing produces more than 2000 hatch marks");
    const direction: Point = ({ below: [0, 1], above: [0, -1], left: [-1, 0], right: [1, 0] } as Record<string, Point>)[i.side ?? "below"];
    const sign = nx * direction[0] + ny * direction[1] >= 0 ? 1 : -1;
    d = path([i.from, i.to]);
    for (let t = spacing / 2; t <= length; t += spacing) d += path([at(t), at(t - hatch * 0.5, sign * hatch * Math.sqrt(3) / 2)]);
  }
  return [{ d, stroke: i.color ?? "#D97757", width: i.width ?? 3 }];
}

export function ellipseOutline(center: Point, rx: number, ry: number): string {
  const [x, y] = center, k = 0.5522847498;
  return `M${x + rx},${y}C${x + rx},${y + ry * k} ${x + rx * k},${y + ry} ${x},${y + ry}C${x - rx * k},${y + ry} ${x - rx},${y + ry * k} ${x - rx},${y}C${x - rx},${y - ry * k} ${x - rx * k},${y - ry} ${x},${y - ry}C${x + rx * k},${y - ry} ${x + rx},${y - ry * k} ${x + rx},${y}Z`;
}
export function rectOutline(x: number, y: number, w: number, h: number): string {
  const r = Math.min(4, Math.abs(w) / 2, Math.abs(h) / 2);
  if (w < 0 || h < 0) throw new Error("Patterned rectangles need non-negative dimensions");
  return `M${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + h - r}Q${x + w},${y + h} ${x + w - r},${y + h}H${x + r}Q${x},${y + h} ${x},${y + h - r}V${y + r}Q${x},${y} ${x + r},${y}Z`;
}
export function patternParts(outline: string, pattern: "cross" | "dot" | "hatch", spacing = 20, angle = 45, color = "#D97757", width = 3, fill = "none"): Part[] {
  // Prepared paths use cubics so the generic iPad path parser needs no arc special case.
  outline = svgpath(outline).unarc().toString();
  const b = pathBounds(outline), parts: Part[] = [{ d: outline, fill }];
  if (!Number.isFinite(spacing) || spacing <= 0 || Math.max(1, Math.ceil(b.w / spacing)) * Math.max(1, Math.ceil(b.h / spacing)) > 10000) throw new Error("Pattern spacing must be positive and produce at most 10000 marks");
  const diagonal = Math.hypot(b.w, b.h), cx = b.x + b.w / 2, cy = b.y + b.h / 2;
  if (pattern === "hatch") {
    if (diagonal / spacing > 10000) throw new Error("Pattern spacing produces too many hatch lines");
    const theta = (angle % 360) * Math.PI / 180, ux = Math.cos(theta), uy = Math.sin(theta);
    let d = "";
    for (let offset = -diagonal; offset <= diagonal; offset += spacing) {
      const x = cx - uy * offset, y = cy + ux * offset;
      d += path([[x - ux * diagonal, y - uy * diagonal], [x + ux * diagonal, y + uy * diagonal]]);
    }
    parts.push({ d, stroke: color, width: 1.2, clip: outline });
  } else {
    let rings = "", symbols = "", dots = "";
    const radius = Math.min(7, spacing * 0.22), mark = radius * 0.5;
    // Anchor the grid to the shape, so moving it preserves the pattern phase.
    for (let x = b.x + spacing / 2; x < b.x + b.w; x += spacing) for (let y = b.y + spacing / 2; y < b.y + b.h; y += spacing) {
      rings += ellipseOutline([x, y], radius, radius);
      if (pattern === "cross") symbols += path([[x - mark, y - mark], [x + mark, y + mark]]) + path([[x - mark, y + mark], [x + mark, y - mark]]);
      else dots += ellipseOutline([x, y], Math.max(0.6, radius * 0.2), Math.max(0.6, radius * 0.2));
    }
    if (rings) parts.push({ d: rings + symbols, stroke: color, width: 1.2, clip: outline });
    if (dots) parts.push({ d: dots, fill: color, clip: outline });
  }
  parts.push({ d: outline, stroke: color, width });
  return parts;
}
export function rotatedBBox(b: BBox, degrees: number, center: Point = [b.x + b.w / 2, b.y + b.h / 2]): BBox {
  const angle = (degrees % 360) * Math.PI / 180, c = Math.cos(angle), s = Math.sin(angle);
  return pointBounds(([ [b.x, b.y], [b.x + b.w, b.y], [b.x + b.w, b.y + b.h], [b.x, b.y + b.h] ] as Point[]).map(([x, y]) => [center[0] + (x - center[0]) * c - (y - center[1]) * s, center[1] + (x - center[0]) * s + (y - center[1]) * c]));
}
