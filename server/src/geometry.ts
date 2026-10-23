import svgpath from "svgpath";

export type Point = [number, number];
export interface BBox { x: number; y: number; w: number; h: number }

export function pointBounds(points: Point[], padding = 0): BBox {
  if (!points.length) return { x: 0, y: 0, w: 0, h: 0 };
  const xs = points.map(([x]) => x), ys = points.map(([, y]) => y);
  const x = Math.min(...xs) - padding, y = Math.min(...ys) - padding;
  return { x, y, w: Math.max(...xs) + padding - x, h: Math.max(...ys) + padding - y };
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
