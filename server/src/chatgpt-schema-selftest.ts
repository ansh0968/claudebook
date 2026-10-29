import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { z } from "zod";
import { buildMcpServer } from "./mcp.js";
import { Store } from "./store.js";

type Schema = Record<string, unknown>;
const object = (value: unknown): value is Schema => typeof value === "object" && value !== null && !Array.isArray(value);
const childPath = (at: string, key: string) => `${at}[${JSON.stringify(key)}]`;

function checkSchema(tool: string, schema: unknown) {
  const fail = (at: string, message: string): never => { throw new Error(`[ChatGPT schema] ${tool} ${at}: ${message}`); };
  if (!object(schema) || schema.type !== "object") fail("$", 'top-level input schema must have type: "object"');
  const walk = (value: unknown, at: string) => {
    if (!object(value)) return;
    if ("oneOf" in value) fail(childPath(at, "oneOf"), "oneOf is unsupported; use z.union (anyOf), not z.discriminatedUnion");
    if (Array.isArray(value.items)) fail(childPath(at, "items"), "array-form items is unsupported; use z.array with a single items schema, not z.tuple");
    if (value.type === "array" && !("items" in value)) fail(at, 'type: "array" requires a single items schema');

    // Visit schema positions only: property names and const/example data may themselves
    // contain words like "oneOf" or "items" without being schema keywords.
    for (const key of ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas", "dependencies"]) {
      const entries = value[key];
      if (object(entries)) for (const [name, child] of Object.entries(entries)) walk(child, childPath(childPath(at, key), name));
    }
    for (const key of ["items", "additionalItems", "additionalProperties", "unevaluatedItems", "unevaluatedProperties", "contains", "propertyNames", "not", "if", "then", "else"]) {
      walk(value[key], childPath(at, key));
    }
    for (const key of ["allOf", "anyOf", "prefixItems"]) {
      const entries = value[key];
      if (Array.isArray(entries)) entries.forEach((child, i) => walk(child, `${childPath(at, key)}[${i}]`));
    }
  };
  walk(schema, "$");
}

// Guard the guard, including nested schema positions and names that are just data.
assert.throws(() => checkSchema("root", { type: "array", items: {} }), /root \$: top-level input schema must have type: "object"/);
assert.throws(() => checkSchema("missing", { type: "object", properties: { points: { type: "array" } } }), /missing \$\["properties"\]\["points"\]: type: "array" requires a single items schema/);
assert.throws(() => checkSchema("nested", { type: "object", $defs: { value: { anyOf: [{ additionalProperties: { oneOf: [] } }] } } }), /nested \$\["\$defs"\]\["value"\]\["anyOf"\]\[0\]\["additionalProperties"\]\["oneOf"\]: oneOf is unsupported/);
checkSchema("data", { type: "object", properties: { oneOf: { const: { oneOf: [], type: "array" } }, items: { type: "array", items: { type: "number" } } } });

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-schema-"));
const server = buildMcpServer(new Store(dir));
const client = new Client({ name: "chatgpt-schema-selftest", version: "1" });
const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
try {
  await server.connect(serverTransport);
  await client.connect(clientTransport);
  let count = 0;
  let cursor: string | undefined;
  do {
    const result = await client.listTools(cursor ? { cursor } : undefined);
    for (const tool of result.tools) {
      checkSchema(tool.name, tool.inputSchema);
      count++;
    }
    cursor = result.nextCursor;
  } while (cursor);
  assert.ok(count > 0, "tools/list must contain registered tools");

  // Exercise Zod -> MCP tools/list conversion too, so changes in the SDK cannot
  // silently make the negative regression fixtures stop testing the real wire shape.
  server.registerTool("schema_regression_union", { inputSchema: { value: z.discriminatedUnion("kind", [z.object({ kind: z.literal("a") }), z.object({ kind: z.literal("b") })]) } }, async () => ({ content: [] }));
  server.registerTool("schema_regression_tuple", { inputSchema: { point: z.tuple([z.number(), z.number()]) } }, async () => ({ content: [] }));
  const fixtures = (await client.listTools()).tools;
  const union = fixtures.find((tool) => tool.name === "schema_regression_union")!;
  const tuple = fixtures.find((tool) => tool.name === "schema_regression_tuple")!;
  assert.throws(() => checkSchema(union.name, union.inputSchema), /schema_regression_union \$\["properties"\]\["value"\]\["oneOf"\]: oneOf is unsupported; use z.union/);
  assert.throws(() => checkSchema(tuple.name, tuple.inputSchema), /schema_regression_tuple \$\["properties"\]\["point"\]\["items"\]: array-form items is unsupported; use z.array/);
  console.log(`[ChatGPT schema] ${count} registered tools passed; discriminatedUnion, tuple, missing items and root regressions passed`);
} finally {
  await client.close();
  await server.close();
  fs.rmSync(dir, { recursive: true, force: true });
}
