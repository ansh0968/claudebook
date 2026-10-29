// Run against a local server: npx tsx src/study-selftest.ts
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

function available(binary: string, versionFlag: string) {
  try { execFileSync(binary, [versionFlag], { stdio: "ignore", timeout: 5000 }); return true; }
  catch { return false; }
}

let socket: WebSocket | undefined;
try {
  const made = await api("/notebooks", "POST", { title: `Study test ${Date.now()}` });
  assert(made.status === 200, "notebook creation failed");
  const notebookId = made.json.id as string;
  const pageId = made.json.pages[0].id as string;
  await api("/view", "POST", { notebookId, pageId });

  socket = new WebSocket(`${base.replace(/^http/, "ws")}/live?token=${secret}`);
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

  const png = await sharp({ create: { width: 1000, height: 1414, channels: 4, background: "white" } }).png().toBuffer();
  const saved = await api(`/pages/${pageId}/snapshot`, "PUT", {
    png: png.toString("base64"), textBoxes: [{ text: "enthalpy change", x: 50, y: 70, w: 200, h: 30 }],
  });
  assert(saved.status === 200, "snapshot upload failed");
  const search = await api("/search?q=ENTHALPY");
  assert(search.json.results.some((r: any) => r.pageId === pageId && r.box.text === "enthalpy change"), "REST handwriting search failed");
  assert((await api("/search?q=%20")).status === 400, "empty handwriting search should fail");
  assert((await api("/search?q=no-such-study-text")).json.results.length === 0, "unmatched search should be empty");
  const mcpSearch = await call("search_notes", { query: "enthalpy" });
  assert(mcpSearch.includes(pageId), "MCP handwriting search failed");

  await call("draw_on_page", { page_id: pageId, items: [{ type: "hint", x: 70, y: 350, text: "Try conservation of mass", label: "Hint 1" }] });
  const layer = await api(`/pages/${pageId}/claude`);
  const hint = layer.json.items.find((i: any) => i.type === "hint");
  assert(hint?.id && !hint.revealed, "hidden hint was not stored");
  const revealed = await api(`/pages/${pageId}/hints/${hint.id}/reveal`, "POST", {});
  assert(revealed.status === 200 && revealed.json.item.revealed === true, "hint reveal failed");
  assert(revealed.json.item.d === hint.d && revealed.json.item.w === hint.w && revealed.json.item.id === hint.id, "revealing a hint must keep its chip (the text opens in a pad) and preserve its id");
  const again = await api(`/pages/${pageId}/hints/${hint.id}/reveal`, "POST", {});
  assert(again.status === 200 && again.json.item.id === hint.id && again.json.item.revealed, "hint reveal must be idempotent");
  assert((await api(`/pages/${pageId}/hints/missing/reveal`, "POST", {})).status === 404, "unknown hint should return 404");

  if (available(process.env.TYPST_BIN ?? "typst", "--version") && available("pdfinfo", "-v") && available("pdftoppm", "-v")) {
    const logged = await call("log_mistake", { page_id: pageId, region, correction: "The correct sign is negative.", title: "Enthalpy sign" });
    assert(logged.includes("Error Log"), "mistake log failed");
    const notebooks = await api("/notebooks");
    assert(notebooks.json.notebooks.some((n: any) => n.title === "Error Log" && n.pages.some((p: any) => p.pdf)), "Error Log PDF page missing");
    const errorLog = notebooks.json.notebooks.find((n: any) => n.title === "Error Log");
    const pageCount = errorLog.pages.length;
    await call("log_mistake", { page_id: pageId, region, correction: "Keep the units in the final answer." });
    const reused = await api(`/notebooks/${errorLog.id}`);
    assert(reused.json.pages.length > pageCount, "second mistake should append to the same Error Log");
  } else {
    console.log("SKIP mistake log (Typst or Poppler unavailable)");
  }
  console.log("study selftest passed");
} finally {
  socket?.close();
  await client.close();
}
