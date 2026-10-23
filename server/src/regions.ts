import { PAGE_H, PAGE_W, type PageRegion } from "./store.js";

export function parsePageRegion(value: unknown): PageRegion | undefined {
  if (!value || typeof value !== "object") return;
  const r = value as Record<string, unknown>;
  if (![r.x, r.y, r.w, r.h].every((n) => typeof n === "number" && Number.isFinite(n))) return;
  const { x, y, w, h } = r as unknown as PageRegion;
  if (x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > PAGE_W || y + h > PAGE_H) return;
  return { x, y, w, h };
}

