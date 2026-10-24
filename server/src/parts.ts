import { createHash } from "node:crypto";
import svgpath from "svgpath";
import { pathBounds, pointBounds, type BBox, type Point } from "./geometry.js";

export interface Part { d: string; stroke?: string; fill?: string; width?: number; dash?: number[]; opacity?: number; clip?: string }
export const escapeSvg = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
export function partsToSvg(parts: Part[]) {
  return parts.map(p => {
    const id = p.clip && `clip-${createHash("sha1").update(p.clip).digest("hex").slice(0, 16)}`;
    return (p.clip ? `<defs><clipPath id="${id}" clipPathUnits="userSpaceOnUse"><path d="${escapeSvg(p.clip)}"/></clipPath></defs>` : "")
      + `<path d="${escapeSvg(p.d)}" stroke="${escapeSvg(p.stroke ?? "none")}" fill="${escapeSvg(p.fill ?? "none")}" stroke-width="${p.width ?? 3}" stroke-linecap="round" stroke-linejoin="round"${p.dash ? ` stroke-dasharray="${p.dash.join(" ")}"` : ""}${p.opacity !== undefined ? ` opacity="${p.opacity}"` : ""}${id ? ` clip-path="url(#${id})"` : ""}/>`;
  }).join("");
}
export function partsBBox(parts: Part[], fallback: Point = [0, 0]): BBox {
  const points: Point[] = [];
  for (const p of parts) {
    let b = pathBounds(p.d, p.stroke && p.stroke !== "none" ? (p.width ?? 3) / 2 : 0);
    if (p.clip) {
      const c = pathBounds(p.clip), x = Math.max(b.x, c.x), y = Math.max(b.y, c.y);
      b = { x, y, w: Math.min(b.x + b.w, c.x + c.w) - x, h: Math.min(b.y + b.h, c.y + c.h) - y };
      if (b.w < 0 || b.h < 0) continue;
    }
    points.push([b.x, b.y], [b.x + b.w, b.y + b.h]);
  }
  return pointBounds(points.length ? points : [fallback]);
}
export function translateParts(parts: Part[], dx: number, dy: number): Part[] {
  const move = (d: string) => svgpath(d).translate(dx, dy).round(4).toString();
  return parts.map(p => ({ ...p, d: move(p.d), ...(p.clip ? { clip: move(p.clip) } : {}) }));
}
