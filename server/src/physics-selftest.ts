import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import sharp from "sharp";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { ItemSchema, itemBBox, itemToSvg, prepareItems, translateItem, type ItemInput } from "./items.js";

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
for (const side of ["below", "above", "left", "right"] as const) {
  const from: [number, number] = [200, 200], to: [number, number] = side === "left" || side === "right" ? [230, 400] : [400, 250];
  const ground = prepareItems([{ type: "ground", from, to, side }])[0];
  const segments = [...ground.parts![0].d.matchAll(/M([\d.e+-]+),([\d.e+-]+)L([\d.e+-]+),([\d.e+-]+)/g)].slice(1);
  for (const s of segments) {
    const dx = Number(s[3]) - Number(s[1]), dy = Number(s[4]) - Number(s[2]);
    assert.ok(side === "below" ? dy > 0 : side === "above" ? dy < 0 : side === "left" ? dx < 0 : dx > 0);
  }
}
assert.throws(() => prepareItems([{ type: "spring", from: [10, 10], to: [10, 10] }]), /endpoints/);
assert.throws(() => prepareItems([{ type: "rect", x: 0, y: 0, w: 1000, h: 1000, fill_pattern: "cross", pattern_spacing: 0.001 }]), /10000/);
const output = path.join(process.env.CLAUDEBOOK_TEST_ARTIFACTS ?? os.tmpdir(), "claudebook-physics.png");
fs.mkdirSync(path.dirname(output), { recursive: true });
await sharp(Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000"><rect width="1000" height="1000" fill="white"/>${items.map(itemToSvg).join("")}</svg>`)).png().toFile(output);
console.log(`[physics] rotations, all patterns, spring, ground sides, bbox corners and translations passed; preview ${output}`);

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
