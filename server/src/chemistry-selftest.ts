import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { arrowHead, curvedArrowPaths, flattenPath, pathBounds, type Point } from "./geometry.js";
import { ItemSchema, itemBBox, itemToSvg, moleculeAtomsForDisplay, prepareBatch, prepareItems, translateItem } from "./items.js";

const arrows = prepareItems([
  ItemSchema.parse({ type: "curly", from: [100, 200], to: [300, 200] }),
  ItemSchema.parse({ type: "curved_arrow", from: [100, 400], to: [300, 400], head: "half" }),
  ItemSchema.parse({ type: "curved_arrow", from: [100, 600], to: [300, 600], half_head: true }),
]);
assert.ok(arrows.every(i => i.type === "curved_arrow"));
assert.ok(arrows.every(i => i.d && i.head_d && i.head_filled === true));
const mixed = prepareBatch([
  { type: "curly", from: [20, 20], to: [150, 20], head: "half" },
  { type: "molecule", smiles: "invalid!", x: 100, y: 100 },
  { type: "molecule", smiles: "CCO", x: 100, y: 100, show_carbon: true },
]);
assert.deepEqual(mixed.indexes, [0]); assert.equal(mixed.warnings.length, 2);
assert.ok(mixed.warnings.every(w => w.warning.startsWith("Skipped:")));
for (const bend of [-80, 0, 80]) {
  const paths = curvedArrowPaths([100, 200], [300, 200], 3, bend, true);
  const head = pathBounds(paths.head), shaft = pathBounds(paths.shaft);
  const full = curvedArrowPaths([100, 200], [300, 200], 3, bend);
  const angle = Math.atan2(-bend, 100);
  assert.equal(full.head, arrowHead([300, 200], angle, 3, true));
  const vertices = flattenPath(paths.head)[0], base = vertices[1], barb = vertices[2];
  const outside = -Math.sin(angle) * (barb[0] - base[0]) + Math.cos(angle) * (barb[1] - base[1]);
  assert.ok(bend < 0 ? outside < 0 : outside > 0, "Fishhook sits outside the bend");
  assert.ok(head.w > 0 && head.h > 0);
  assert.ok(shaft.x + shaft.w < 300, "No shaft through the head tip");
  assert.match(itemToSvg({ type: "curly", from: [100, 200], to: [300, 200], bend }), /fill="#D97757"/);
}
// Oblique arrows must preserve the same terminal tangent and signed outside barb.
for (const to of [[260, 320], [40, 320], [40, 80]] as Point[]) for (const bend of [-80, 80]) {
  const from: Point = [100, 200], dx = to[0] - from[0], dy = to[1] - from[1], length = Math.hypot(dx, dy);
  const control: Point = [(from[0] + to[0]) / 2 - dy / length * bend, (from[1] + to[1]) / 2 + dx / length * bend];
  const angle = Math.atan2(to[1] - control[1], to[0] - control[0]);
  const full = curvedArrowPaths(from, to, 3, bend), half = curvedArrowPaths(from, to, 3, bend, true);
  assert.equal(full.head, arrowHead(to, angle, 3, true));
  const [, base, barb] = flattenPath(half.head)[0];
  assert.ok(Math.abs((base[0] - control[0]) * Math.sin(angle) - (base[1] - control[1]) * Math.cos(angle)) < 0.01, "Shaft endpoint preserves the terminal tangent");
  const outside = -Math.sin(angle) * (barb[0] - base[0]) + Math.cos(angle) * (barb[1] - base[1]);
  assert.ok(bend < 0 ? outside < 0 : outside > 0);
}
const molecule = prepareItems([{ type: "molecule", smiles: "CC(=O)O", x: 100, y: 100, size: 200, show_carbons: true }])[0];
assert.deepEqual(molecule.elements, { "0": "C", "1": "C", "2": "O", "3": "O" });
assert.equal(Object.keys(molecule.atoms!).length, 4);
// Synthetic optional physics metadata exercises integration without importing that branch.
const rotated = { ...molecule, atoms: { "0": [110, 100] as Point, "1": [100, 80] as Point }, rotation: 90, rotation_center: [100, 100] as Point };
const storedAtoms = structuredClone(rotated.atoms);
const display = moleculeAtomsForDisplay(rotated)!;
assert.ok(Math.abs(display["0"][0] - 100) < 1e-10 && Math.abs(display["0"][1] - 110) < 1e-10);
assert.ok(Math.abs(display["1"][0] - 120) < 1e-10 && Math.abs(display["1"][1] - 100) < 1e-10);
assert.deepEqual(rotated.atoms, storedAtoms, "Displaying rotated atoms must not change stored coordinates");
assert.equal(moleculeAtomsForDisplay(molecule), molecule.atoms);
assert.equal(moleculeAtomsForDisplay({ ...rotated, rotation: 0 }), rotated.atoms);
assert.deepEqual(moleculeAtomsForDisplay({ ...rotated, rotation: 1e308 }), moleculeAtomsForDisplay({ ...rotated, rotation: 1e308 % 360 }));
assert.ok(Object.values(moleculeAtomsForDisplay({ ...rotated, rotation: 1e308 })!).flat().every(Number.isFinite));
// Physics translates its rotation centre alongside the prepared geometry.
const shifted = { ...translateItem(rotated, 25, -12), rotation: rotated.rotation, rotation_center: [125, 88] as Point };
const shiftedDisplay = moleculeAtomsForDisplay(shifted)!;
for (const [id, [x, y]] of Object.entries(display)) {
  assert.ok(Math.abs(shiftedDisplay[id][0] - (x + 25)) < 1e-10);
  assert.ok(Math.abs(shiftedDisplay[id][1] - (y - 12)) < 1e-10);
}
const box = itemBBox(molecule);
for (const [x, y] of Object.values(molecule.atoms!)) assert.ok(x >= box.x && x <= box.x + box.w && y >= box.y && y <= box.y + box.h);
const aim = prepareItems([{ type: "curved_arrow", from: molecule.atoms!["2"], to: molecule.atoms!["3"] }])[0];
assert.ok(aim.type === "curved_arrow");
assert.deepEqual(aim.from, molecule.atoms!["2"]); assert.deepEqual(aim.to, molecule.atoms!["3"]);
const hydrogens = prepareItems([{ type: "molecule", smiles: "CC(=O)O", x: 100, y: 100, explicit_h: true }])[0];
assert.equal(Object.values(hydrogens.elements!).filter(e => e === "H").length, 4);
for (const i of [...arrows, molecule, hydrogens]) {
  const before = itemBBox(i), moved = translateItem(i, 25, -12), after = itemBBox(moved);
  for (const [a, b] of [[after.x, before.x + 25], [after.y, before.y - 12], [after.w, before.w], [after.h, before.h]]) assert.ok(Math.abs(a - b) < 0.025);
  if (i.atoms) for (const [id, [x, y]] of Object.entries(i.atoms)) assert.deepEqual(moved.atoms![id], [x + 25, y - 12]);
}
console.log("[chemistry] alias, filled heads, carbon labels, explicit H, atom aiming and translations passed");

if (process.env.CLAUDEBOOK_SECRET) {
  const client = new Client({ name: "chemistry-selftest", version: "1" });
  const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787";
  await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${process.env.CLAUDEBOOK_SECRET}`)));
  try {
    const draw = await client.callTool({ name: "draw_on_page", arguments: { items: [{ type: "molecule", smiles: "CC(=O)O", x: 100, y: 100, show_carbons: true }] } });
    assert.ok(!draw.isError);
    const text = (draw.content as { text: string }[])[0].text;
    const summary = JSON.parse(text).items[0];
    assert.deepEqual(summary.elements, molecule.elements);
    assert.equal(Object.keys(summary.atoms).length, 4);
    const view = await client.callTool({ name: "get_current_page", arguments: {} });
    assert.ok((view.content as { text?: string }[])[0].text?.includes('"atoms"'));
    const arrow = await client.callTool({ name: "draw_on_page", arguments: { items: [{ type: "curly", from: summary.atoms["2"], to: summary.atoms["3"], head: "half" }] } });
    assert.ok(!arrow.isError);
    assert.equal(JSON.parse((arrow.content as { text: string }[])[0].text).items[0].type, "curved_arrow");
    console.log("[chemistry MCP] atom maps in draw/describe and atom-targeted curly alias passed");
  } finally { await client.close(); }
}
