// OpenChemLib produces an SVG depiction with stroked bonds and text labels.
// Flatten those into one filled outline, matching math and text on the iPad.
import { Molecule } from "openchemlib";
import svgpath from "svgpath";
import { renderFontLabel } from "./handwriting.js";
import { pathBounds, strokePolyline, type Point } from "./geometry.js";

type Attrs = Record<string, string>;
function attributes(tag: string): Attrs {
  const result: Attrs = {};
  for (const match of tag.matchAll(/([\w-]+)="([^"]*)"/g)) result[match[1]] = match[2];
  return result;
}
function number(a: Attrs, key: string, fallback = 0): number {
  return Number(a[key] ?? fallback);
}
/** Size is the longest side of the structure's visible bounding box. */
export function renderMolecule(smiles: string, x: number, y: number, size = 180, options: { show_carbons?: boolean; explicit_h?: boolean } = {}) {
  if (!smiles.trim()) throw new Error("SMILES is empty");
  if (!(size > 0) || !Number.isFinite(size)) throw new Error("Molecule size must be positive");
  const molecule = Molecule.fromSmiles(smiles);
  if (!molecule.getAllAtoms()) throw new Error("SMILES contains no atoms");
  if (options.explicit_h) {
    molecule.addImplicitHydrogens();
    molecule.inventCoordinates({ keepHydrogens: true });
  }
  molecule.setMoleculeColor(Molecule.cMoleculeColorNeutral);
  const svg = molecule.toSVG(500, 500, undefined, { autoCrop: true, autoCropMargin: 4, suppressChiralText: true });
  const root = svg.match(/<svg\b[^>]*>/)?.[0];
  if (!root) throw new Error("OpenChemLib produced no SVG");
  const box = attributes(root).viewBox?.split(/\s+/).map(Number);
  if (!box || box.length !== 4 || box.some((v) => !Number.isFinite(v))) throw new Error("Invalid molecule viewBox");
  let [bx, by, bw, bh] = box;
  const rawAtoms: Record<string, Point> = {}, elements: Record<string, string> = {};
  for (const match of svg.matchAll(/<circle\b([^>]*class="event"[^>]*)\/>/g)) {
    const a = attributes(match[1]), id = a.id?.match(/:Atom:(\d+)$/)?.[1];
    if (id === undefined) continue;
    rawAtoms[id] = [number(a, "cx"), number(a, "cy")];
    elements[id] = molecule.getAtomLabel(Number(id));
  }
  if (Object.keys(rawAtoms).length !== molecule.getAllAtoms()) throw new Error("OpenChemLib omitted atom positions");
  // The depictor has no show-all-carbons switch. Fill labels ourselves, leaving
  // isotope/charge labels already emitted by OCL intact, and shorten adjacent bonds.
  const carbons = options.show_carbons ? Object.entries(rawAtoms).filter(([id, at]) => {
    if (elements[id] !== "C") return false;
    return ![...svg.matchAll(/<text\b([^>]*)>([^<]*)<\/text>/g)].some((m) => {
      const a = attributes(m[1]);
      return /^C/.test(m[2]) && Math.hypot(number(a, "x") + 5 - at[0], number(a, "y") - 4.67 - at[1]) < 10;
    });
  }).map(([, at]) => at) : [];
  const parts: string[] = [];
  for (const match of svg.matchAll(/<(text|line|polygon|path|rect|circle)\b([^>]*?)(?:\/>|>([^<]*)<\/text>)/g)) {
    const [, kind, raw, value = ""] = match;
    const a = attributes(raw);
    if (a.opacity === "0" || a.class === "event") continue;
    if (kind === "line") {
      let ax = number(a, "x1"), ay = number(a, "y1"), bx = number(a, "x2"), by = number(a, "y2");
      const length = Math.hypot(bx - ax, by - ay), ux = (bx - ax) / length, uy = (by - ay) / length;
      if (carbons.some(([cx, cy]) => Math.hypot(ax - cx, ay - cy) < 4)) { ax += ux * 7; ay += uy * 7; }
      if (carbons.some(([cx, cy]) => Math.hypot(bx - cx, by - cy) < 4)) { bx -= ux * 7; by -= uy * 7; }
      parts.push(strokePolyline([[ax, ay], [bx, by]], number(a, "stroke-width", 1.44)));
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
  for (const [cx, cy] of carbons) parts.push(renderFontLabel("C", cx - 5, cy + 4.67, 14));
  if (!parts.some(Boolean)) throw new Error("OpenChemLib produced no visible structure");
  // Place the actual outline top-left at x,y, including atom targets for isolated atoms.
  const bounds = pathBounds(parts.join(""));
  bx = Math.min(bounds.x, ...Object.values(rawAtoms).map((at) => at[0]));
  by = Math.min(bounds.y, ...Object.values(rawAtoms).map((at) => at[1]));
  bw = Math.max(bounds.x + bounds.w, ...Object.values(rawAtoms).map((at) => at[0])) - bx;
  bh = Math.max(bounds.y + bounds.h, ...Object.values(rawAtoms).map((at) => at[1])) - by;
  const scale = size / Math.max(bw, bh);
  const transform = `translate(${x},${y}) scale(${scale}) translate(${-bx},${-by})`;
  return {
    d: parts.filter(Boolean).map((part) => svgpath(part).transform(transform).round(2).toString()).join(""),
    w: +(bw * scale).toFixed(1),
    h: +(bh * scale).toFixed(1),
    atoms: Object.fromEntries(Object.entries(rawAtoms).map(([id, at]) => [id, [x + (at[0] - bx) * scale, y + (at[1] - by) * scale] as Point])),
    elements,
  };
}
