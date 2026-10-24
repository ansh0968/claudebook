// OpenChemLib produces an SVG depiction with stroked bonds and text labels.
// Flatten those into one filled outline, matching math and text on the iPad.
import { Molecule } from "openchemlib";
import svgpath from "svgpath";
import { renderFontLabel } from "./handwriting.js";

type Attrs = Record<string, string>;
function attributes(tag: string): Attrs {
  const result: Attrs = {};
  for (const match of tag.matchAll(/([\w-]+)="([^"]*)"/g)) result[match[1]] = match[2];
  return result;
}
function number(a: Attrs, key: string, fallback = 0): number {
  return Number(a[key] ?? fallback);
}
function lineShape(x1: number, y1: number, x2: number, y2: number, width: number): string {
  const length = Math.hypot(x2 - x1, y2 - y1);
  if (!length) return "";
  const nx = (y2 - y1) / length * width / 2;
  const ny = (x1 - x2) / length * width / 2;
  return `M${x1 + nx},${y1 + ny}L${x2 + nx},${y2 + ny}L${x2 - nx},${y2 - ny}L${x1 - nx},${y1 - ny}Z`;
}

/** Size is the longest side of the structure's visible bounding box. */
export function renderMolecule(smiles: string, x: number, y: number, size = 180) {
  if (!smiles.trim()) throw new Error("SMILES is empty");
  if (!(size > 0) || !Number.isFinite(size)) throw new Error("Molecule size must be positive");
  const molecule = Molecule.fromSmiles(smiles);
  if (!molecule.getAllAtoms()) throw new Error("SMILES contains no atoms");
  molecule.setMoleculeColor(Molecule.cMoleculeColorNeutral);
  const svg = molecule.toSVG(500, 500, undefined, { autoCrop: true, autoCropMargin: 4, suppressChiralText: true });
  const root = svg.match(/<svg\b[^>]*>/)?.[0];
  if (!root) throw new Error("OpenChemLib produced no SVG");
  const box = attributes(root).viewBox?.split(/\s+/).map(Number);
  if (!box || box.length !== 4 || box.some((v) => !Number.isFinite(v))) throw new Error("Invalid molecule viewBox");
  const [bx, by, bw, bh] = box;
  const scale = size / Math.max(bw, bh);
  const parts: string[] = [];
  for (const match of svg.matchAll(/<(text|line|polygon|path|rect|circle)\b([^>]*?)(?:\/>|>([^<]*)<\/text>)/g)) {
    const [, kind, raw, value = ""] = match;
    const a = attributes(raw);
    if (a.opacity === "0" || a.class === "event") continue;
    if (kind === "line") {
      parts.push(lineShape(number(a, "x1"), number(a, "y1"), number(a, "x2"), number(a, "y2"), number(a, "stroke-width", 1.44)));
    } else if (kind === "text") {
      const label = value.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
      parts.push(renderFontLabel(label, number(a, "x"), number(a, "y"), number(a, "font-size", 14)));
    } else if (kind === "circle") {
      // Radical electrons are visible circles; event hit targets are skipped above.
      const cx = number(a, "cx"), cy = number(a, "cy"), r = number(a, "r"), k = r * 0.5522847498;
      parts.push(`M${cx + r},${cy}C${cx + r},${cy + k} ${cx + k},${cy + r} ${cx},${cy + r}C${cx - k},${cy + r} ${cx - r},${cy + k} ${cx - r},${cy}C${cx - r},${cy - k} ${cx - k},${cy - r} ${cx},${cy - r}C${cx + k},${cy - r} ${cx + r},${cy - k} ${cx + r},${cy}Z`);
    } else if (kind === "polygon") {
      const points = (a.points ?? "").trim().split(/\s+/).join("L");
      if (points) parts.push(`M${points}Z`);
    } else if (kind === "rect") {
      const rx = number(a, "x"), ry = number(a, "y"), rw = number(a, "width"), rh = number(a, "height");
      parts.push(`M${rx},${ry}h${rw}v${rh}h${-rw}Z`);
    } else if (kind === "path") {
      if (a.stroke && a.stroke !== "none" && (a.fill === "none" || !a.fill)) {
        throw new Error("OpenChemLib produced an unsupported stroked path");
      }
      parts.push(a.d ?? "");
    }
  }
  if (!parts.some(Boolean)) throw new Error("OpenChemLib produced no visible structure");
  const transform = `translate(${x},${y}) scale(${scale}) translate(${-bx},${-by})`;
  return {
    d: parts.filter(Boolean).map((part) => svgpath(part).transform(transform).round(2).toString()).join(""),
    w: +(bw * scale).toFixed(1),
    h: +(bh * scale).toFixed(1),
  };
}
