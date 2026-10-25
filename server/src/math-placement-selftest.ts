import assert from "node:assert/strict";
import { pathBounds } from "./geometry.js";
import { itemBBox, prepareItems } from "./items.js";
import { renderMath } from "./math.js";

const formulas = [
  "x", "x^2", "\\dfrac{a}{b}", "\\dfrac{\\dfrac{a}{b}}{c}", "\\sqrt{\\dfrac{1}{2}}",
  "\\int_0^1 f\\,dx", "\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}", "\\vec{v}", "\\ce{A ->[above][below] B}",
];
const anchors = {
  "top-left": [0, 0], "top-center": [0.5, 0], "top-right": [1, 0],
  "left-center": [0, 0.5], center: [0.5, 0.5], "right-center": [1, 0.5],
  "bottom-left": [0, 1], "bottom-center": [0.5, 1], "bottom-right": [1, 1],
} as const;
const near = (a: number, b: number, label: string) => assert.ok(Math.abs(a - b) < 0.5, `${label}: ${a} != ${b}`);
for (const latex of formulas) {
  const shape = renderMath(latex, 300, 500), ink = pathBounds(shape.d);
  near(ink.x, 300, latex); near(ink.y, 500, latex);
  near(shape.w, ink.w, latex); near(shape.h, ink.h, latex);
  for (const [anchor, [fx, fy]] of Object.entries(anchors)) {
    const [item] = prepareItems([{ type: "math", latex, x: 300, y: 500, anchor: anchor as keyof typeof anchors }]);
    const bounds = pathBounds(item.d!), bbox = itemBBox(item);
    near(bounds.x + fx * bounds.w, 300, `${latex} ${anchor} x`);
    near(bounds.y + fy * bounds.h, 500, `${latex} ${anchor} y`);
    for (const key of ["x", "y", "w", "h"] as const) near(bbox[key], bounds[key], `${latex} ${anchor} ${key}`);
  }
}
// Whitespace-only math still has no ink to place, matching the existing error contract.
assert.throws(() => renderMath("\\,", 300, 500), /Nothing to draw/);
console.log("[math placement] nine formulas, true ink bounds and all nine anchors passed");
