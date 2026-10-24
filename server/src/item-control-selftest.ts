import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { itemBBox, prepareItems, translateItem, type Item, type ItemInput } from "./items.js";
import { pointBounds } from "./geometry.js";

const inputs: ItemInput[] = [
  { type: "path", points: [[40, 160], [90, 110], [140, 160]], smooth: false, group: "geometry" },
  { type: "line", from: [180, 120], to: [280, 160], dashed: true },
  { type: "arrow", from: [320, 160], to: [440, 120] },
  { type: "ellipse", center: [100, 230], rx: 50, ry: 30 },
  { type: "rect", x: 200, y: 200, w: 100, h: 60 },
  { type: "highlight", x: 350, y: 210, w: 120, h: 40 },
  { type: "text", x: 40, y: 35, text: "Hello", size: 42 },
  { type: "svg", d: "M530,210h80v40h-80Z", fill: "#D9775755" },
  { type: "math", x: 650, y: 210, latex: "x^2" },
];
const near = (actual: number, expected: number) => assert.ok(Math.abs(actual - expected) < 0.025, `${actual} != ${expected}`);
assert.deepEqual(pointBounds(Array.from({ length: 150_000 }, (_, i) => [i, i % 2])), { x: 0, y: 0, w: 149_999, h: 1 });
const legacy = { type: "svg", d: "M broken", id: "legacy", createdAt: "old" } as Item;
assert.throws(() => translateItem(legacy, 10, 20), /Invalid SVG/);
assert.throws(() => translateItem(legacy, Infinity, 20), /finite/);
assert.equal(legacy.d, "M broken");
assert.throws(() => itemBBox(prepareItems([{ type: "path", points: [[1e308, 0], [-1e308, 10], [1e308, 20]] }])[0]), /Invalid SVG|finite/);
assert.throws(() => pointBounds([[0, 0], [Infinity, 10]]), /finite/);
assert.throws(() => pointBounds([[-1e308, 0], [1e308, 10]]), /finite/);
const extremeLine = prepareItems([{ type: "line", from: [1e308, 10], to: [1e308, 20] }])[0];
assert.throws(() => translateItem(extremeLine, 1e308, 0), /finite/);
assert.deepEqual(extremeLine.type === "line" && extremeLine.from, [1e308, 10]);
assert.doesNotThrow(() => itemBBox(extremeLine));
assert.deepEqual(itemBBox(prepareItems([{ type: "line", from: [10, 20], to: [30, 40] }])[0]), { x: 8.5, y: 18.5, w: 23, h: 23 });
assert.deepEqual(itemBBox(prepareItems([{ type: "rect", x: 10, y: 20, w: 30, h: 40 }])[0]), { x: 8.5, y: 18.5, w: 33, h: 43 });
assert.deepEqual(itemBBox(prepareItems([{ type: "highlight", x: 10, y: 20, w: 30, h: 40 }])[0]), { x: 10, y: 20, w: 30, h: 40 });
for (const item of prepareItems(inputs)) {
  const before = itemBBox(item), moved = translateItem(item, 27.5, -11.25), after = itemBBox(moved);
  near(after.x, before.x + 27.5); near(after.y, before.y - 11.25); near(after.w, before.w); near(after.h, before.h);
  assert.equal(moved.id, item.id); assert.equal(moved.group, item.group); assert.equal(moved.createdAt, item.createdAt);
}
console.log("[item control] default stroke bounds and translations passed");

if (process.env.CLAUDEBOOK_SECRET) {
  const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787", secret = process.env.CLAUDEBOOK_SECRET;
  const client = new Client({ name: "item-control-selftest", version: "1" });
  const api = async (route: string, init: RequestInit = {}) => {
    const response = await fetch(`${base}/api${route}`, { ...init, headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json", ...init.headers } });
    assert.ok(response.ok, `${route}: HTTP ${response.status}`);
    return response;
  };
  await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));
  try {
    const notebook = await (await api("/notebooks", { method: "POST", body: JSON.stringify({ title: "Item control self-test", pages: 1 }) })).json() as { id: string; pages: { id: string }[] };
    const page_id = notebook.pages[0].id;
    const call = async (name: string, args: Record<string, unknown>, expectError = false) => {
      const result = await client.callTool({ name, arguments: { page_id, ...args } });
      assert.equal(!!result.isError, expectError, `${name}: ${JSON.stringify(result.content)}`);
      return result.content as { type: string; text?: string }[];
    };
    const savedItems = async () => ((await (await api(`/pages/${page_id}/claude`)).json()) as { items: Item[] }).items;
    const draw = JSON.parse((await call("draw_on_page", { items: inputs.slice(0, 3) }))[0].text!) as { items: { id: string; bbox: { x: number; y: number; w: number; h: number } }[] };
    assert.equal(draw.items.length, 3); assert.ok(draw.items.every((i) => i.id && i.bbox.w > 0));
    await call("erase_my_drawings", { ids: [draw.items[1].id] });
    assert.deepEqual((await savedItems()).map((i) => i.id), [draw.items[0].id, draw.items[2].id]);
    const moved = JSON.parse((await call("move_items", { ids: [draw.items[0].id, "unknown-id"], dx: 40, dy: 20 }))[0].text!);
    assert.equal(moved.items.length, 1); assert.equal(moved.items[0].id, draw.items[0].id);
    near(moved.items[0].bbox.x, draw.items[0].bbox.x + 40); near(moved.items[0].bbox.y, draw.items[0].bbox.y + 20);
    const view = await call("view_page", { grid: false });
    assert.ok(view[0].text?.includes(draw.items[0].id)); assert.ok(view[0].text?.includes('"bbox"'));
    await call("erase_my_drawings", { count: 1, ids: [draw.items[0].id] }, true); assert.equal((await savedItems()).length, 2);
    const beforeInvalidDraw = await savedItems();
    await call("draw_on_page", { items: [{ type: "path", points: [[1e308, 0], [-1e308, 10], [1e308, 20]] }] }, true);
    assert.deepEqual(await savedItems(), beforeInvalidDraw, "A bounds failure must not persist the failing item");
    const extreme = JSON.parse((await call("draw_on_page", { items: [{ type: "line", from: [1e308, 10], to: [1e308, 20] }] }))[0].text!);
    const beforeInvalidMove = await savedItems();
    await call("move_items", { ids: [draw.items[0].id, extreme.items[0].id], dx: 1e308, dy: 0 }, true);
    assert.deepEqual(await savedItems(), beforeInvalidMove, "Overflow must not persist part of a move batch");
    await call("erase_my_drawings", { ids: [extreme.items[0].id] });
    await call("erase_my_drawings", { group: "geometry" });
    assert.deepEqual((await savedItems()).map((i) => i.id), [draw.items[2].id]);
    await call("erase_my_drawings", { count: 1 }); assert.equal((await savedItems()).length, 0);
    await call("draw_on_page", { items: inputs }); await call("erase_my_drawings", {}); assert.equal((await savedItems()).length, 0);
    console.log("[item control MCP] returned ids/bounds, selective erase, groups, move and erase-all passed");
  } finally { await client.close(); }
}
