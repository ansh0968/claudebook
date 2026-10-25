import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { buildMcpServer } from "./mcp.js";
import { itemBBox, LooseItemSchema, prepareBatch } from "./items.js";
import { Store } from "./store.js";

const inputs = [
  { type: "rect", x: 100, y: 100, w: 50, h: 40 },
  { type: "squiggle" },
  { type: "rect", x: 200, y: 100, h: 40 },
  { type: "text", x: 300, y: 100, text: "OK" },
];
const batch = prepareBatch(inputs.map((input) => LooseItemSchema.parse(input) as Record<string, unknown>));
assert.deepEqual(batch.indexes, [0, 3]);
assert.deepEqual(batch.warnings.map((w) => w.item), [1, 2]);
assert.match(batch.warnings[0].warning, /^Skipped: unknown type "squiggle"\. Types: .*rect/);
assert.equal(batch.warnings[1].warning, 'Skipped: rect needs "w" (number)');
assert.equal(prepareBatch([{ type: "rect", x: 0, y: 0, w: "wide", h: 2 }]).warnings[0].warning, 'Skipped: rect needs "w" (number)');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-batch-"));
const store = new Store(dir), page = store.listNotebooks()[0].pages[0];
const server = buildMcpServer(store), client = new Client({ name: "batch-skip-selftest", version: "1" });
const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
await server.connect(serverTransport);
await client.connect(clientTransport);
try {
  const tool = (await client.listTools()).tools.find((t) => t.name === "draw_on_page")!;
  assert.ok(JSON.stringify(tool.inputSchema).includes('"anyOf"'));
  assert.ok(!JSON.stringify(tool.inputSchema).includes('"oneOf"'));
  const draw = async (dry_run: boolean) => {
    const result = await client.callTool({ name: "draw_on_page", arguments: { page_id: page.id, items: inputs, dry_run } });
    assert.ok(!result.isError, JSON.stringify(result.content));
    return JSON.parse((result.content as { text: string }[])[0].text);
  };
  const measured = await draw(true);
  assert.equal(page.claudeLayer.length, 0);
  const drawn = await draw(false);
  assert.deepEqual(drawn.warnings, measured.warnings);
  assert.deepEqual(drawn.warnings, batch.warnings);
  assert.equal(page.claudeLayer.length, 2);
  assert.deepEqual(page.claudeLayer.map((i) => i.type), ["rect", "text"]);
  assert.deepEqual(drawn.items.map((i: { id: string }) => i.id), page.claudeLayer.map((i) => i.id));
  assert.deepEqual(drawn.items.map((i: { bbox: unknown }) => i.bbox), page.claudeLayer.map(itemBBox));
  assert.deepEqual(measured.items.map((i: { bbox: unknown }) => i.bbox), drawn.items.map((i: { bbox: unknown }) => i.bbox));
  console.log("[batch skip MCP] malformed items skipped, indexes/ids/bounds, dry run and anyOf schema passed");
} finally {
  await client.close();
  await server.close();
  fs.rmSync(dir, { recursive: true, force: true });
}
