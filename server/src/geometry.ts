import svgpath from "svgpath";

export type Point = [number, number];
export interface BBox { x: number; y: number; w: number; h: number }

export function pointBounds(points: Point[], padding = 0): BBox {
  if (!Number.isFinite(padding)) throw new Error("Drawing bounds must be finite numbers");
  if (!points.length) return { x: 0, y: 0, w: 0, h: 0 };
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  // A long imported SVG/freehand path can exceed the argument limit of
  // Math.min(...points), so reduce bounds without spreading the coordinates.
  for (const [x, y] of points) {
    if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error("Drawing coordinates must remain finite numbers");
    minX = Math.min(minX, x); minY = Math.min(minY, y);
    maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
  }
  const box = { x: minX - padding, y: minY - padding, w: maxX - minX + 2 * padding, h: maxY - minY + 2 * padding };
  if (!Object.values(box).every(Number.isFinite)) throw new Error("Drawing bounds must remain finite numbers");
  return box;
}

/** Bounds of the actual curve, including extrema between its end points. */
export function pathBounds(d: string, padding = 0): BBox {
  const path = svgpath(d).abs().unshort().unarc();
  if ("err" in path && path.err) throw new Error(`Invalid SVG path: ${path.err}`);
  const points: Point[] = [];
  let current: Point = [0, 0], start: Point = [0, 0];
  const addCurve = (controls: Point[]) => {
    const at = (t: number): Point => {
      let values = controls;
      while (values.length > 1) values = values.slice(1).map((p, i) => [values[i][0] * (1 - t) + p[0] * t, values[i][1] * (1 - t) + p[1] * t]);
      return values[0];
    };
    points.push(controls[0], controls[controls.length - 1]);
    for (const axis of [0, 1]) {
      const p = controls.map((v) => v[axis]);
      let roots: number[];
      if (p.length === 3) {
        const denominator = p[0] - 2 * p[1] + p[2];
        roots = denominator === 0 ? [] : [(p[0] - p[1]) / denominator];
      } else {
        const a = -p[0] + 3 * p[1] - 3 * p[2] + p[3];
        const b = 2 * (p[0] - 2 * p[1] + p[2]);
        const c = p[1] - p[0], discriminant = b * b - 4 * a * c;
        roots = Math.abs(a) < 1e-12 ? (Math.abs(b) < 1e-12 ? [] : [-c / b])
          : discriminant < 0 ? [] : [(-b + Math.sqrt(discriminant)) / (2 * a), (-b - Math.sqrt(discriminant)) / (2 * a)];
      }
      for (const t of roots) if (t > 0 && t < 1) points.push(at(t));
    }
  };
  path.iterate((s) => {
    const n = s.slice(1) as number[];
    switch (s[0]) {
      case "M": current = [n[0], n[1]]; start = current; break;
      case "L": points.push(current, [n[0], n[1]]); current = [n[0], n[1]]; break;
      case "H": points.push(current, [n[0], current[1]]); current = [n[0], current[1]]; break;
      case "V": points.push(current, [current[0], n[0]]); current = [current[0], n[0]]; break;
      case "Q": addCurve([current, [n[0], n[1]], [n[2], n[3]]]); current = [n[2], n[3]]; break;
      case "C": addCurve([current, [n[0], n[1]], [n[2], n[3]], [n[4], n[5]]]); current = [n[4], n[5]]; break;
      case "Z": points.push(current, start); current = start; break;
    }
  });
  return pointBounds(points, padding);
}

export function arrowPath(from: Point, to: Point, width = 3, bend?: number, halfHead = false): string {
  const [x1, y1] = from, [x2, y2] = to;
  const dx = x2 - x1, dy = y2 - y1, length = Math.hypot(dx, dy);
  // Coincident endpoints have no meaningful tangent, so draw only the point.
  if (!length) return `M${x1},${y1}L${x1},${y1}`;
  const control: Point = [(x1 + x2) / 2 - dy / length * (bend ?? 0), (y1 + y2) / 2 + dx / length * (bend ?? 0)];
  const angle = Math.atan2(y2 - control[1], x2 - control[0]), head = 10 + width * 2;
  const barb = (side: number) => [x2 - head * Math.cos(angle + side * 0.45), y2 - head * Math.sin(angle + side * 0.45)];
  const sides = halfHead ? [(bend ?? 0) >= 0 ? 1 : -1] : [-1, 1];
  return `M${x1},${y1}${bend === undefined ? `L${x2},${y2}` : `Q${control.join(",")} ${x2},${y2}`}`
    + sides.map((side) => `M${barb(side).join(",")}L${x2},${y2}`).join("");
}

/** Closed polygons approximating each subpath, with curves sampled into short segments. */
export function flattenPath(d: string, steps = 12): Point[][] {
  const polys: Point[][] = [];
  let poly: Point[] = [], current: Point = [0, 0];
  const curve = (controls: Point[]) => {
    for (let i = 1; i <= steps; i++) {
      const t = i / steps;
      let values = controls;
      while (values.length > 1) values = values.slice(1).map((p, j) => [values[j][0] * (1 - t) + p[0] * t, values[j][1] * (1 - t) + p[1] * t]);
      poly.push(values[0]);
    }
  };
  svgpath(d).abs().unshort().unarc().iterate((s) => {
    const n = s.slice(1) as number[];
    switch (s[0]) {
      case "M": if (poly.length > 1) polys.push(poly); poly = [[n[0], n[1]]]; current = [n[0], n[1]]; return;
      case "L": current = [n[0], n[1]]; break;
      case "H": current = [n[0], current[1]]; break;
      case "V": current = [current[0], n[0]]; break;
      case "Q": curve([current, [n[0], n[1]], [n[2], n[3]]]); current = [n[2], n[3]]; return;
      case "C": curve([current, [n[0], n[1]], [n[2], n[3]], [n[4], n[5]]]); current = [n[4], n[5]]; return;
      case "Z": if (poly.length > 1) polys.push(poly); poly = [poly[0] ?? current]; current = poly[0]; return;
    }
    poly.push(current);
  });
  if (poly.length > 1) polys.push(poly);
  return polys;
}

/** Clip a filled path to a rectangle, like an SVG viewport does. Paths already inside are returned untouched. */
export function clipPathToRect(d: string, r: BBox): string {
  const b = pathBounds(d), eps = 0.5;
  if (b.x >= r.x - eps && b.y >= r.y - eps && b.x + b.w <= r.x + r.w + eps && b.y + b.h <= r.y + r.h + eps) return d;
  const edges: [(p: Point) => boolean, (a: Point, b: Point) => Point][] = [
    [(p) => p[0] >= r.x, (a, c) => [r.x, a[1] + (c[1] - a[1]) * (r.x - a[0]) / (c[0] - a[0])]],
    [(p) => p[0] <= r.x + r.w, (a, c) => [r.x + r.w, a[1] + (c[1] - a[1]) * (r.x + r.w - a[0]) / (c[0] - a[0])]],
    [(p) => p[1] >= r.y, (a, c) => [a[0] + (c[0] - a[0]) * (r.y - a[1]) / (c[1] - a[1]), r.y]],
    [(p) => p[1] <= r.y + r.h, (a, c) => [a[0] + (c[0] - a[0]) * (r.y + r.h - a[1]) / (c[1] - a[1]), r.y + r.h]],
  ];
  // Sutherland-Hodgman: the clip rectangle is convex, so each subpath clips independently.
  return flattenPath(d).map((poly) => {
    let out = poly;
    for (const [inside, cross] of edges) {
      const input = out;
      out = [];
      input.forEach((p, i) => {
        const prev = input[(i + input.length - 1) % input.length];
        if (inside(p)) {
          if (!inside(prev)) out.push(cross(prev, p));
          out.push(p);
        } else if (inside(prev)) out.push(cross(prev, p));
      });
      if (!out.length) return "";
    }
    return `M${out.map((p) => `${+p[0].toFixed(2)} ${+p[1].toFixed(2)}`).join("L")}Z`;
  }).join("");
}

/** A stroke as filled quads (all wound the same way so overlaps stay filled). Interior joints are squared off. */
export function strokePolyline(points: Point[], width: number): string {
  const h = width / 2, last = points.length - 2;
  return points.slice(0, -1).map((a, i) => {
    const b = points[i + 1], len = Math.hypot(b[0] - a[0], b[1] - a[1]);
    if (!len) return "";
    const ux = (b[0] - a[0]) / len, uy = (b[1] - a[1]) / len, nx = -uy * h, ny = ux * h;
    const s = i > 0 ? h : 0, e = i < last ? h : 0;
    const p0: Point = [a[0] - ux * s, a[1] - uy * s], p1: Point = [b[0] + ux * e, b[1] + uy * e];
    return `M${p0[0] + nx} ${p0[1] + ny}L${p1[0] + nx} ${p1[1] + ny}L${p1[0] - nx} ${p1[1] - ny}L${p0[0] - nx} ${p0[1] - ny}Z`;
  }).join("");
}

export interface PathEnd { tip: Point; angle: number }

/** Where a path starts and ends, with the direction of travel there (pointing out of the path), for arrowheads. */
export function pathEnds(d: string): { start: PathEnd; end: PathEnd } | undefined {
  const segments: Point[][] = [];
  let current: Point = [0, 0], start: Point = [0, 0];
  svgpath(d).abs().unshort().unarc().iterate((s) => {
    const n = s.slice(1) as number[];
    let points: Point[] | undefined;
    switch (s[0]) {
      case "M": current = [n[0], n[1]]; start = current; return;
      case "L": points = [[n[0], n[1]]]; break;
      case "H": points = [[n[0], current[1]]]; break;
      case "V": points = [[current[0], n[0]]]; break;
      case "Q": points = [[n[0], n[1]], [n[2], n[3]]]; break;
      case "C": points = [[n[0], n[1]], [n[2], n[3]], [n[4], n[5]]]; break;
      case "Z": points = [start]; break;
    }
    if (!points) return;
    segments.push([current, ...points]);
    current = points[points.length - 1];
  });
  // Control points can sit on their end point; use the nearest distinct one for the direction.
  const direction = (from: Point, toward: Point[]): number | undefined => {
    const other = toward.find((p) => Math.hypot(p[0] - from[0], p[1] - from[1]) > 1e-6);
    return other && Math.atan2(from[1] - other[1], from[0] - other[0]);
  };
  const drawn = segments.filter((s) => s.some((p) => Math.hypot(p[0] - s[0][0], p[1] - s[0][1]) > 1e-6));
  if (!drawn.length) return;
  const first = drawn[0], last = drawn[drawn.length - 1];
  const startAngle = direction(first[0], first.slice(1)), endAngle = direction(last[last.length - 1], [...last].reverse().slice(1));
  if (startAngle === undefined || endAngle === undefined) return;
  return { start: { tip: first[0], angle: startAngle }, end: { tip: last[last.length - 1], angle: endAngle } };
}

/** Arrowhead at `tip` pointing along `angle`: an open V of two barbs, or a closed triangle to fill. */
export function arrowHead(tip: Point, angle: number, width = 3, filled = false): string {
  const head = 10 + width * 2;
  const barb = (side: number) => `${+(tip[0] - head * Math.cos(angle + side * 0.45)).toFixed(2)},${+(tip[1] - head * Math.sin(angle + side * 0.45)).toFixed(2)}`;
  return filled ? `M${tip.join(",")}L${barb(-1)}L${barb(1)}Z` : `M${barb(-1)}L${tip.join(",")}L${barb(1)}`;
}

export type HeadMode = "none" | "end" | "start" | "both";

/** Heads for the chosen ends of a path, or undefined when there is nothing to draw. */
export function headsFor(d: string, mode: HeadMode, width = 3, filled = false): string | undefined {
  if (mode === "none") return;
  const ends = pathEnds(d);
  if (!ends) return;
  const parts: string[] = [];
  if (mode === "start" || mode === "both") parts.push(arrowHead(ends.start.tip, ends.start.angle, width, filled));
  if (mode === "end" || mode === "both") parts.push(arrowHead(ends.end.tip, ends.end.angle, width, filled));
  return parts.join("");
}
