import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import sharp from "sharp";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { ItemSchema, itemBBox, itemToSvg, prepareBatch, prepareItems, translateItem, type ItemInput } from "./items.js";
import { flattenPath } from "./geometry.js";

const near = (a: number, b: number, tolerance = 0.025) => assert.ok(Math.abs(a - b) < tolerance, `${a} != ${b}`);
const inputs: ItemInput[] = [
  { type: "ground", from: [80, 650], to: [750, 350], side: "below", color: "black" },
  { type: "rect", x: 360, y: 410, w: 150, h: 100, rotation: -24.1, fill: "#DCE8F5", color: "black" },
  { type: "spring", from: [100, 580], to: [365, 460], coils: 8, amplitude: 14, color: "#3B82F6" },
  { type: "ground", from: [80, 400], to: [80, 650], side: "left", color: "black" },
  { type: "text", x: 320, y: 360, text: "block", rotation: -24.1, color: "black" },
  { type: "math", x: 620, y: 280, latex: "F = kx", rotation: 30 },
  { type: "molecule", x: 700, y: 90, smiles: "CCO", rotation: 30 },
  { type: "rect", x: 80, y: 750, w: 200, h: 160, fill_pattern: "cross", pattern_spacing: 25, rotation: 30, fill: "#EBF2F9", color: "#253A46" },
  { type: "ellipse", center: [440, 830], rx: 100, ry: 65, fill_pattern: "dot", rotation: -20, color: "#253A46" },
  { type: "svg", d: "M650,750L850,750L750,910Z", fill_pattern: "hatch", pattern_angle: 30, pattern_spacing: 12, rotation: 10, color: "#253A46" },
];
const items = prepareItems(inputs.map(i => ItemSchema.parse(i)));
for (const item of items) {
  const before = itemBBox(item), moved = translateItem(item, 27.5, -11.25), after = itemBBox(moved);
  near(after.x, before.x + 27.5); near(after.y, before.y - 11.25); near(after.w, before.w); near(after.h, before.h);
  if (item.rotation_center) assert.deepEqual(moved.rotation_center, [item.rotation_center[0] + 27.5, item.rotation_center[1] - 11.25]);
  assert.ok(!itemToSvg(item).includes("undefined"));
}
const rect = prepareItems([{ type: "rect", x: 100, y: 200, w: 120, h: 80, width: 2, rotation: 30 }])[0];
const r = itemBBox(rect), radians = Math.PI / 6;
near(r.w, 122 * Math.cos(radians) + 82 * Math.sin(radians), 0.5);
near(r.h, 122 * Math.sin(radians) + 82 * Math.cos(radians), 0.5);
near(r.x + r.w / 2, 160); near(r.y + r.h / 2, 240);
assert.match(itemToSvg(rect), /rotate\(30 160 240\)/);
for (const item of items.slice(7)) {
  assert.ok(item.parts!.some(p => p.clip));
  assert.match(itemToSvg(item), /clipPath/);
}
for (const side of ["below", "above", "left", "right"] as const) for (const delta of [[200, 50], [20, 200], [-200, 50], [20, -200], [0, 200], [200, 0]]) {
  const from: [number, number] = [400, 400], to: [number, number] = [from[0] + delta[0], from[1] + delta[1]];
  const ground = prepareItems([{ type: "ground", from, to, side }])[0];
  const segments = [...ground.parts![0].d.matchAll(/M([\d.e+-]+),([\d.e+-]+)L([\d.e+-]+),([\d.e+-]+)/g)].slice(1);
  for (const s of segments) {
    const dx = Number(s[3]) - Number(s[1]), dy = Number(s[4]) - Number(s[2]);
    assert.ok(side === "below" ? dy > 0 : side === "above" ? dy < 0 : side === "left" ? dx < 0 : dx > 0);
  }
}
for (const type of ["text", "math"] as const) for (const anchor of ["top-left", "top-center", "top-right", "left-center", "center", "right-center", "bottom-left", "bottom-center", "bottom-right"] as const) {
  const input = type === "text" ? { type, x: 500, y: 500, text: "Anchor test", anchor } : { type, x: 500, y: 500, latex: "\\frac{x^2}{2}", anchor };
  const plain = prepareItems([input])[0], rotated = prepareItems([{ ...input, rotation: 30 }])[0];
  const b = itemBBox(plain), r = itemBBox(rotated);
  near(rotated.rotation_center![0], b.x + b.w / 2); near(rotated.rotation_center![1], b.y + b.h / 2);
  near(r.w, b.w * Math.cos(radians) + b.h * Math.sin(radians));
  near(r.h, b.w * Math.sin(radians) + b.h * Math.cos(radians));
  assert.equal("anchor" in rotated, false);
  const moved = itemBBox(translateItem(rotated, 17, -23));
  near(moved.x, r.x + 17); near(moved.y, r.y - 23);
}
for (const shape of [{ type: "rect", x: 100, y: 100, w: 100, h: 80 }, { type: "ellipse", center: [150, 140], rx: 50, ry: 40 }, { type: "svg", d: "M100,100h100v80h-100Z" }] as ItemInput[]) {
  const item = prepareItems([{ ...shape, fill: "blue", fill_pattern: "cross", rotation: 30 } as ItemInput])[0];
  assert.ok(item.parts!.some(p => p.fill === "blue"));
  assert.ok(item.parts!.filter(p => p.stroke).every(p => p.clip), "fill without color must not gain a shape outline");
  const b = itemBBox(prepareItems([{ ...shape, fill: "blue" } as ItemInput])[0]);
  near(item.rotation_center![0], b.x + b.w / 2); near(item.rotation_center![1], b.y + b.h / 2);
}
const patternedHead = prepareItems([{ type: "svg", d: "M100,100h100v80h-100Z", fill_pattern: "hatch", dashed: true, head: "both", head_filled: true, rotation: 20 }])[0];
assert.ok(patternedHead.parts!.some(p => p.d === patternedHead.head_d && p.fill === "#D97757" && !p.dash));
assert.ok(patternedHead.parts!.some(p => p.dash?.join() === "10,8"));
const spring = prepareItems([{ type: "spring", from: [100, 100], to: [400, 100] }])[0];
assert.ok(spring.parts![0].fill && !spring.parts![0].stroke);
const springPoints = flattenPath(spring.parts![0].d).flat();
near(Math.min(...springPoints.map(p => p[0])), 100); near(Math.max(...springPoints.map(p => p[0])), 400);
const partial = prepareBatch([{ type: "spring", from: [10, 10], to: [10, 10] }, { type: "rect", x: 100, y: 100, w: 80, h: 60, rotation: 30 }]);
assert.equal(partial.items.length, 1); assert.equal(partial.warnings.length, 1); assert.match(partial.warnings[0].warning, /endpoints/);
assert.throws(() => prepareItems([{ type: "spring", from: [10, 10], to: [10, 10] }]), /endpoints/);
assert.throws(() => prepareItems([{ type: "rect", x: 0, y: 0, w: 1000, h: 1000, fill_pattern: "cross", pattern_spacing: 0.001 }]), /10000/);
// Keep a regression in a disposable process so a coordinate-increment loop cannot hang the suite.
const physicsModule = new URL(`physics${path.extname(new URL(import.meta.url).pathname)}`, import.meta.url).href;
const extremePattern = spawnSync(process.execPath, ["--import", "tsx", "--input-type=module", "-e", `import { patternParts } from ${JSON.stringify(physicsModule)}; try { patternParts("M100000000000000000000,0h65536v1h-65536Z", "cross"); process.exit(2); } catch (e) { if (!/spacing.*coordinates/.test(e.message)) throw e; }`], { timeout: 10000, encoding: "utf8" });
assert.equal(extremePattern.error, undefined, String(extremePattern.error));
assert.equal(extremePattern.status, 0, extremePattern.stderr);
for (const fill_pattern of ["cross", "dot", "hatch"] as const) for (const d of ["M100,100", "M100,100v100", "M100,100h100"]) {
  const item = prepareItems([{ type: "svg", d, fill_pattern }])[0];
  assert.ok(Object.values(itemBBox(item)).every(Number.isFinite));
}
assert.throws(() => prepareItems([{ type: "rect", x: 1e308, y: 0, w: 7e307, h: 1, fill_pattern: "hatch", pattern_spacing: 1e307 }]), /finite/);
const output = path.join(process.env.CLAUDEBOOK_TEST_ARTIFACTS ?? os.tmpdir(), "claudebook-physics.png");
fs.mkdirSync(path.dirname(output), { recursive: true });
await sharp(Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000"><rect width="1000" height="1000" fill="white"/>${items.map(itemToSvg).join("")}</svg>`)).png().toFile(output);
console.log(`[physics] rotations + all anchors, fill-only patterns, SVG heads/dashes, spring leads, all ground sides/slopes, bbox corners and translations passed; preview ${output}`);

if (process.env.CLAUDEBOOK_SECRET) {
  const client = new Client({ name: "physics-selftest", version: "1" });
  await client.connect(new StreamableHTTPClientTransport(new URL(`${process.env.CLAUDEBOOK_URL ?? "http://localhost:8787"}/mcp/${process.env.CLAUDEBOOK_SECRET}`)));
  try {
    const draw = await client.callTool({ name: "draw_on_page", arguments: { items: inputs } });
    assert.ok(!draw.isError, JSON.stringify(draw.content));
    const result = JSON.parse((draw.content as { text: string }[])[0].text);
    const move = await client.callTool({ name: "move_items", arguments: { ids: result.items.map((i: { id: string }) => i.id), dx: 15, dy: 25 } });
    assert.ok(!move.isError);
    const moved = JSON.parse((move.content as { text: string }[])[0].text);
    for (let n = 0; n < inputs.length; n++) { near(moved.items[n].bbox.x, result.items[n].bbox.x + 15); near(moved.items[n].bbox.y, result.items[n].bbox.y + 25); }
    console.log("[physics MCP] all shapes, rotation and patterns through draw/move passed");
  } finally { await client.close(); }
}
