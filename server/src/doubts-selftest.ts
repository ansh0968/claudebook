// Run against a local server: npx tsx src/doubts-selftest.ts
import { execFileSync } from "node:child_process";
import { once } from "node:events";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import sharp from "sharp";
import WebSocket from "ws";

const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787";
const secret = process.env.CLAUDEBOOK_SECRET;
if (!secret) throw new Error("Set CLAUDEBOOK_SECRET");
const client = new Client({ name: "study-selftest", version: "0" });
await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));

async function api(route: string, method = "GET", body?: unknown) {
  const res = await fetch(`${base}/api${route}`, {
    method,
    headers: { Authorization: `Bearer ${secret}`, ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json() as Record<string, any>;
  return { status: res.status, json };
}

async function call(name: string, args: Record<string, unknown> = {}) {
  const result = await client.callTool({ name, arguments: args }) as { isError?: boolean; content: { type: string; text?: string }[] };
  if (result.isError) throw new Error(`${name}: ${result.content.find((c) => c.type === "text")?.text}`);
  return result.content.filter((c) => c.type === "text").map((c) => c.text).join("\n");
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function available(binary: string) {
  try { execFileSync(binary, [binary === "typst" ? "--version" : "-v"], { stdio: "ignore" }); return true; }
  catch { return false; }
}

try {
  const made = await api("/notebooks", "POST", { title: `Study test ${Date.now()}` });
  assert(made.status === 200, "notebook creation failed");
  const notebookId = made.json.id as string;
  const pageId = made.json.pages[0].id as string;
  await api("/view", "POST", { notebookId, pageId });

  const socket = new WebSocket(`${base.replace(/^http/, "ws")}/live?token=${secret}`);
  const hello = once(socket, "message", { signal: AbortSignal.timeout(5000) });
  await once(socket, "open", { signal: AbortSignal.timeout(5000) });
  await hello;
  const event = once(socket, "message", { signal: AbortSignal.timeout(5000) });
  const region = { x: 100, y: 200, w: 300, h: 180 };
  const added = await api(`/pages/${pageId}/doubts`, "POST", { pageId, region });
  assert(added.status === 201 && added.json.doubt.pageId === pageId, "doubt creation failed");
  const doubtId = added.json.doubt.id as string;
  const [raw] = await event;
  const live = JSON.parse(raw.toString());
  assert(live.type === "doubts" && live.pageId === pageId && live.doubts[0].id === doubtId, "doubt live event missing");
  const bad = await api(`/pages/${pageId}/doubts`, "POST", { region: { x: 999, y: 0, w: 10, h: 10 } });
  assert(bad.status === 400, "out-of-bounds doubt should fail");
  const page = await api(`/notebooks/${notebookId}`);
  assert(page.json.pages[0].doubts[0].id === doubtId, "doubt absent from notebook page");
  const described = await call("get_current_page");
  assert(described.includes(doubtId) && described.includes("zoom into each"), "Claude was not told to zoom into the doubt");
  await call("resolve_doubt", { id: doubtId });
  const open = await api(`/pages/${pageId}/doubts?status=open`);
  assert(open.json.doubts.length === 0, "resolved doubt still open");
  socket.close();

  console.log("doubt selftest passed");
} finally {
  await client.close();
}
