import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import sharp from "sharp";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { arrowPath, curvedArrowPaths, pathBounds } from "./geometry.js";
import { ItemSchema, itemBBox, itemLabel, itemToSvg, prepareItems, translateItem, type Item, type ItemInput } from "./items.js";
import { renderMolecule } from "./molecule.js";

const near = (actual: number, expected: number) => assert.ok(Math.abs(actual - expected) < 0.025, `${actual} != ${expected}`);
assert.deepEqual(pathBounds("M0,0Q50,100 100,0"), { x: 0, y: 0, w: 100, h: 50 });
assert.deepEqual(pathBounds("M0,0C0,100 100,100 100,0"), { x: 0, y: 0, w: 100, h: 75 });
assert.deepEqual(pathBounds("m10,20h30v40h-30z", 2), { x: 8, y: 18, w: 34, h: 44 });
const arc = pathBounds("M0,50A50,50 0 0 1 100,50");
near(arc.w, 100); near(arc.h, 50);
assert.throws(() => prepareItems([{ type: "svg", d: "M nonsense" }]), /Invalid SVG/);

const jagged: ItemInput = { type: "path", points: [[20, 10], [50, 80], [80, 10]], smooth: false, closed: true };
assert.match(itemToSvg(jagged), /M20,10 L50,80 L80,10 Z/);
assert.doesNotMatch(itemToSvg(jagged), / C/);
assert.match(itemToSvg({ ...jagged, smooth: true }), / C/);
assert.match(itemToSvg({ type: "path", points: [[0, 0], [10, 10]], closed: true }), / Z/);

for (const bend of [-70, 0, 70]) {
  const curve = arrowPath([0, 0], [100, 0], 3, bend);
  assert.match(curve, new RegExp(`Q50,${bend} `));
  assert.equal((curve.match(/M/g) ?? []).length, 2);
  assert.ok(curve.endsWith("Z"), "Chemistry heads are filled triangles");
  const fishhook = arrowPath([0, 0], [100, 0], 3, bend, true);
  assert.equal((fishhook.match(/M/g) ?? []).length, 2);
  const paths = curvedArrowPaths([0, 0], [100, 0], 3, bend, true);
  assert.ok(paths.head.startsWith("M100,0L"));
  assert.ok(!paths.shaft.endsWith("100,0"), "Shaft stops before the tip");
}
assert.doesNotMatch(arrowPath([10, 10], [10, 10], 3, 40, true), /NaN|Infinity/);

const inputs: ItemInput[] = [
  { type: "path", points: [[40, 160], [90, 110], [140, 160]], smooth: false, group: "geometry" },
  { type: "line", from: [180, 120], to: [280, 160], dashed: true },
  { type: "arrow", from: [320, 160], to: [440, 120] },
  { type: "curved_arrow", from: [500, 150], to: [630, 150], bend: -70 },
  { type: "curved_arrow", from: [690, 120], to: [820, 150], bend: 70, half_head: true },
  { type: "ellipse", center: [100, 230], rx: 50, ry: 30 },
  { type: "rect", x: 200, y: 200, w: 100, h: 60 },
  { type: "highlight", x: 350, y: 210, w: 120, h: 40 },
  { type: "text", x: 40, y: 35, text: "ΔH ⇒ ⊖ ‡ ⑤ H₂O  OH^-  x^{2}", size: 42 },
  { type: "svg", d: "M530,210h80v40h-80Z", fill: "#D9775755" },
  { type: "math", x: 650, y: 210, latex: "\\ce{H2O <=> H+ + OH-}" },
  { type: "hint", x: 40, y: 300, label: "Hint 1", text: "hidden-answer-sentinel" },
  { type: "hint", x: 240, y: 300, text: "Use charge balance", revealed: true },
  { type: "molecule", x: 40, y: 390, smiles: "CC(=O)Oc1ccccc1C(=O)O", size: 170 },
  { type: "molecule", x: 260, y: 390, smiles: "N[C@@H](C)C(=O)O", size: 170 },
  { type: "molecule", x: 480, y: 390, smiles: "[O-][N+](=O)c1ccccc1", size: 170 },
  { type: "molecule", x: 700, y: 390, smiles: "[CH3]", size: 130 },
];
const prepared = prepareItems(inputs.map((i) => ItemSchema.parse(i)));
assert.equal(new Set(prepared.map((i) => i.id)).size, prepared.length);
for (const item of prepared) {
  const before = itemBBox(item), moved = translateItem(item, 27.5, -11.25), after = itemBBox(moved);
  assert.ok(Object.values(before).every(Number.isFinite), item.type);
  assert.ok(before.w > 0 && before.h > 0, item.type);
  near(after.x, before.x + 27.5); near(after.y, before.y - 11.25);
  near(after.w, before.w); near(after.h, before.h);
  assert.equal(moved.id, item.id); assert.equal(moved.createdAt, item.createdAt); assert.equal(moved.group, item.group);
  assert.notEqual(itemToSvg(item), itemToSvg(moved), item.type);
  assert.ok(!itemToSvg(item).includes("undefined"), item.type);
}
const hint = prepared.find((i) => i.type === "hint" && !i.revealed)!;
assert.equal(itemLabel(hint), "Hint 1");
assert.ok(!itemToSvg(hint).includes("hidden-answer-sentinel"));
assert.match(itemToSvg(hint), /<rect.*rx="8"/);
for (const smiles of ["c1ccccc1", "[Na+].[Cl-]", "[13CH3][C@H](O)C#N", "C/C=C\\C", "[O]"]) {
  const shape = renderMolecule(smiles, 12, 30, 160), bounds = pathBounds(shape.d);
  assert.ok(shape.d && shape.w > 0 && shape.h > 0, smiles);
  near(Math.max(shape.w, shape.h), 160);
  assert.ok(bounds.x >= 12 && bounds.y >= 30 && bounds.x + bounds.w <= 12 + shape.w + 1 && bounds.y + bounds.h <= 30 + shape.h + 1, `Structure exceeds its box: ${smiles}`);
}
assert.match(renderMolecule("[CH3]", 0, 0).d, /C/, "Radical electrons must survive conversion to filled outlines");
assert.throws(() => renderMolecule("", 0, 0), /SMILES/);
assert.throws(() => renderMolecule("not-a-smiles", 0, 0));
assert.throws(() => renderMolecule("CCO", 0, 0, 0), /positive/);

const output = path.join(process.env.CLAUDEBOOK_TEST_ARTIFACTS ?? os.tmpdir(), "claudebook-drawing-features.png");
fs.mkdirSync(path.dirname(output), { recursive: true });
await sharp(Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="650"><rect width="1000" height="650" fill="white"/>${prepared.map(itemToSvg).join("")}</svg>`)).png().toFile(output);
console.log(`[drawing] bounds, translation, arrows, SMILES and hints passed; preview ${output}`);

// Run the acceptance flow through real MCP and REST whenever the server test
// environment is present; standalone invocation also supports geometry QA.
if (process.env.CLAUDEBOOK_SECRET) {
  const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787";
  const secret = process.env.CLAUDEBOOK_SECRET;
  const client = new Client({ name: "drawing-selftest", version: "1" });
  const api = async (route: string, init: RequestInit = {}) => {
    const response = await fetch(`${base}/api${route}`, { ...init, headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json", ...init.headers } });
    assert.ok(response.ok, `${route}: HTTP ${response.status}`);
    return response;
  };
  await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));
  try {
    const notebook = await (await api("/notebooks", { method: "POST", body: JSON.stringify({ title: "Drawing feature self-test", pages: 1 }) })).json() as { id: string; pages: { id: string }[] };
    const page_id = notebook.pages[0].id;
    const call = async (name: string, args: Record<string, unknown>, expectError = false) => {
      const result = await client.callTool({ name, arguments: { page_id, ...args } });
      assert.equal(!!result.isError, expectError, `${name}: ${JSON.stringify(result.content)}`);
      return result.content as { type: string; text?: string }[];
    };
    const savedItems = async () => ((await (await api(`/pages/${page_id}/claude`)).json()) as { items: Item[] }).items;
    await call("draw_on_page", { items: inputs });
    const beforeFailure = await savedItems();
    await call("draw_on_page", { items: [{ type: "molecule", smiles: "invalid!", x: 10, y: 10 }] }, true);
    assert.deepEqual(await savedItems(), beforeFailure, "A batch where every item fails must draw nothing");
    const partial = JSON.parse((await call("draw_on_page", { items: [{ type: "line", from: [0, 0], to: [10, 10] }, { type: "molecule", smiles: "invalid!", x: 10, y: 10 }] }))[0].text!);
    assert.equal(partial.items.length, 1); assert.equal(partial.warnings.length, 1); assert.equal(partial.warnings[0].item, 1);
    assert.match(partial.warnings[0].warning, /^Skipped/);
    assert.equal((await savedItems()).length, beforeFailure.length + 1, "The valid item in a partly bad batch still draws");
    assert.ok(!(await call("view_page", { grid: false }))[0].text?.includes("hidden-answer-sentinel"));
    await call("erase_my_drawings", {}); assert.equal((await savedItems()).length, 0);
    console.log("[drawing MCP] Unicode text, curves, molecules, hidden hints and per-item failure passed");
  } finally {
    await client.close();
  }
}
