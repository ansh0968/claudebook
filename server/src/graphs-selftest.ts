import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import sharp from "sharp";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { flattenPath, pathBounds } from "./geometry.js";
import { parseExpression, expressionNumber } from "./expression.js";
import { ItemSchema, itemBBox, itemToSvg, prepareBatch, prepareItems, translateItem, type ItemInput } from "./items.js";

const near = (a: number, b: number, tolerance = 0.025) => assert.ok(Math.abs(a - b) < tolerance, `${a} != ${b}`);
for (const [expr, x, expected] of [["-x^2", 3, -9], ["2^3^2", 0, 512], ["2^-2", 0, 0.25], ["2x+3(x+1)", 2, 13], ["2pi", 0, 2 * Math.PI], ["2e", 0, 2 * Math.E], [".5x + 1e-2", 2, 1.01]] as const) near(parseExpression(expr)(x), expected);
for (const name of ["sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "exp", "sqrt", "abs", "floor", "ceil"] as const) near(parseExpression(`${name}(x)`)(0.4), Math[name](0.4));
near(parseExpression("log(100)+ln(e)")(0), 3);
near(parseExpression("sin(t)", "t")(Math.PI / 2), 1);
for (const invalid of ["process.exit()", "constructor", "x;y", "x.y", "x[0]", "2**3", "sin()", "foo(x)", "(x+1", "", "(".repeat(70) + "1" + ")".repeat(70)]) assert.throws(() => parseExpression(invalid), /position/);
assert.throws(() => expressionNumber("t"), /finite/);
const inputs: ItemInput[] = [
  { type: "axes", origin: [300, 700], xrange: [-2, 5], yrange: [-1, 4], unit: [70, 90], name: "g1", grid: true, color: "black" },
  { type: "shade", axes: "g1", fn1: "x^2/2", fn2: "axis", from: 0, to: 2, color: "#3B82F6" },
  { type: "plot", axes: "g1", fn: "x^2/2", from: -2, to: 4, color: "#3B82F6" },
  { type: "point", axes: "g1", at: [1, 2], label: "P(1,2)", filled: false },
  { type: "angle", vertex: [300, 700], from: [400, 700], to: [360, 620], label: "θ" },
  { type: "plot", axes: "g1", x: "cos(t)", y: "sin(t)", t: [0, "2pi"], dashed: true, color: "#30A46C" },
];
const items = prepareItems(inputs.map(i => ItemSchema.parse(i)));
const axesBox = itemBBox(items[0]), plotBox = itemBBox(items[2]);
assert.ok(plotBox.x >= axesBox.x && plotBox.y >= axesBox.y && plotBox.x + plotBox.w <= axesBox.x + axesBox.w && plotBox.y + plotBox.h <= axesBox.y + axesBox.h);
for (const item of items) {
  const before = itemBBox(item), moved = translateItem(item, 27.5, -11.25), after = itemBBox(moved);
  near(after.x, before.x + 27.5); near(after.y, before.y - 11.25); near(after.w, before.w); near(after.h, before.h);
  assert.equal(moved.id, item.id); assert.ok(!itemToSvg(moved).includes("undefined"));
}
const unchangedPlot = itemToSvg(items[2]);
translateItem(items[0], 200, 200);
assert.equal(itemToSvg(items[2]), unchangedPlot);
assert.notEqual(items[0].graph, items[2].graph);
const byId = prepareItems([{ type: "plot", axes: items[0].id, fn: "x" }], items);
assert.ok(byId[0].parts!.length > 0);
assert.throws(() => prepareItems([{ type: "plot", axes: "missing", fn: "x" }]), /Unknown axes/);
assert.throws(() => prepareItems([{ type: "plot", axes: "g1", fn: "constructor" }], items), /position/);
assert.throws(() => prepareItems([{ type: "axes", origin: [0, 0], xrange: [1, 1], yrange: [-1, 1] }]), /increasing/);
assert.throws(() => prepareItems([{ type: "axes", origin: [0, 0], xrange: [-1, 1], yrange: [-1, 1], tick_step: 0.000001 }]), /1000 ticks/);
const tan = prepareItems([{ type: "axes", origin: [400, 500], xrange: [-3, 3], yrange: [-3, 3], unit: 60, name: "tan" }, { type: "plot", axes: "tan", fn: "tan(x)", from: -3, to: 3 }])[1];
const tanPolys = flattenPath(tan.parts![0].d);
assert.ok(tanPolys.length > 3, "Expected actual sampled stroke polygons");
for (const polygon of tanPolys) for (let n = 1; n < polygon.length; n++) {
  assert.ok(Math.hypot(polygon[n][0] - polygon[n - 1][0], polygon[n][1] - polygon[n - 1][1]) <= 360, "Asymptote segment crosses axes height");
}
// The draw handler's singleton preparation retains only earlier successful items.
const older = prepareItems([{ ...inputs[0], origin: [100, 100] } as ItemInput]);
const batch = prepareBatch([
  inputs[0],
  { type: "plot", axes: "g1", fn: "constructor" },
  { type: "plot", axes: "g1", fn: "x", invented: true },
  ...inputs.slice(1),
] as Record<string, unknown>[], older);
assert.equal(batch.items.length, inputs.length);
assert.deepEqual(batch.indexes, [0, 3, 4, 5, 6, 7]);
assert.equal(batch.warnings.length, 2);
assert.match(batch.warnings[0].warning, /position/);
assert.match(batch.warnings[1].warning, /invented/);
assert.deepEqual(batch.items[1].graph?.origin, [300, 700], "Earlier batch axes take precedence over page axes");
assert.deepEqual(prepareBatch([{ type: "plot", axes: older[0].id, fn: "x" }], older).items[0].graph?.origin, [100, 100]);
assert.equal(prepareBatch([{ type: "plot", axes: "future", fn: "x" }, { ...inputs[0], name: "future" }]).warnings.length, 1);
const clipped = prepareItems([{ type: "shade", axes: "g1", fn1: "10x", fn2: "-10x", from: -10, to: 10 }], items)[0];
for (const part of clipped.parts!) {
  const b = pathBounds(part.d);
  assert.ok(b.x >= 160 && b.x + b.w <= 650 && b.y >= 340 && b.y + b.h <= 790, "Shade polygon should be geometrically clipped");
}
const output = path.join(process.env.CLAUDEBOOK_TEST_ARTIFACTS ?? os.tmpdir(), "claudebook-graphs.png");
fs.mkdirSync(path.dirname(output), { recursive: true });
await sharp(Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000"><rect width="1000" height="1000" fill="white"/>${items.map(itemToSvg).join("")}</svg>`)).png().toFile(output);
console.log(`[graphs] safe parser, every function, clipping, discontinuities, batch names, ids and translations passed; preview ${output}`);

if (process.env.CLAUDEBOOK_SECRET) {
  const client = new Client({ name: "graphs-selftest", version: "1" });
  const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787";
  await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${process.env.CLAUDEBOOK_SECRET}`)));
  try {
    const draw = await client.callTool({ name: "draw_on_page", arguments: { items: inputs } });
    assert.ok(!draw.isError, JSON.stringify(draw.content));
    const result = JSON.parse((draw.content as { text: string }[])[0].text);
    assert.equal(result.items.length, inputs.length);
    const move = await client.callTool({ name: "move_items", arguments: { ids: result.items.slice(0, 3).map((i: { id: string }) => i.id), dx: 25, dy: 10 } });
    assert.ok(!move.isError);
    const moved = JSON.parse((move.content as { text: string }[])[0].text);
    for (let n = 0; n < 3; n++) { near(moved.items[n].bbox.x, result.items[n].bbox.x + 25); near(moved.items[n].bbox.y, result.items[n].bbox.y + 10); }
    const more = await client.callTool({ name: "draw_on_page", arguments: { items: [{ type: "plot", axes: result.items[0].id, fn: "x" }] } });
    assert.ok(!more.isError);
    const mixed = await client.callTool({ name: "draw_on_page", arguments: { items: [{ type: "plot", axes: result.items[0].id, fn: "constructor" }, { type: "point", at: [500, 500] }] } });
    const mixedResult = JSON.parse((mixed.content as { text: string }[])[0].text);
    assert.equal(mixedResult.items.length, 1); assert.equal(mixedResult.warnings.length, 1);
    console.log("[graphs MCP] single-batch graph, stored axes references and move_items passed");
  } finally { await client.close(); }
}
