import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787";
const secret = process.env.CLAUDEBOOK_SECRET!;
const clientId = randomUUID();
const created: string[] = [];
type View = { notebookId: string; pageId: string };
type TestNotebook = { id: string; pages: { id: string; claudeLayer: { text?: string }[] }[] };

async function request<T>(route: string, method = "GET", body?: object): Promise<T> {
  const response = await fetch(`${base}/api/${route}`, {
    method,
    headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" },
    body: body && JSON.stringify(body),
  });
  assert.ok(response.ok, `${method} ${route}: ${response.status}`);
  return await response.json() as T;
}

async function create(title: string, scratch: boolean, sequence: number) {
  const notebook = await request<TestNotebook>("notebooks", "POST", { title, scratch, activateView: { clientId, sequence } });
  created.push(notebook.id);
  return notebook;
}

const { view: previous } = await request<{ view: View }>("notebooks");
const client = new Client({ name: "view-sync-selftest", version: "1" });
await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));
try {
  const scratch = await create("Old scratch", true, 1);
  const notebook = await create("New notebook", false, 3);
  const first = notebook.pages[0].id;
  const oldView = { notebookId: scratch.id, pageId: scratch.pages[0].id };
  const lateResponse = await request<View>("view", "POST", { ...oldView, report: { clientId, sequence: 2 } });
  assert.equal(lateResponse.pageId, first, "Late navigation must leave the newly opened notebook selected");
  const active = await client.callTool({ name: "get_current_page", arguments: {} }) as {
    content: { type: string; text?: string }[];
  };
  assert.ok(active.content.some(item => item.type === "text" && item.text?.includes(`page id ${first}`)),
    "MCP should see the new notebook immediately");

  await request("view", "POST", { ...oldView, report: { clientId, sequence: 4 } });
  const marker = "Draw inside the named notebook";
  const drawn = await client.callTool({
    name: "draw_on_page",
    arguments: { notebook_id: notebook.id, items: [{ type: "text", x: 100, y: 100, text: marker }] },
  });
  assert.equal(!!drawn.isError, false);
  const named = await request<TestNotebook>(`notebooks/${notebook.id}`);
  const other = await request<TestNotebook>(`notebooks/${scratch.id}`);
  assert.ok(named.pages[0].claudeLayer.some(item => item.text === marker));
  assert.ok(other.pages[0].claudeLayer.every(item => item.text !== marker));
  console.log("[view sync] new notebook activation, stale report ordering, and explicit MCP notebook targeting passed");
} finally {
  for (const id of created) await request(`notebooks/${id}`, "DELETE");
  if (previous.notebookId && previous.pageId) await request("view", "POST", previous);
  await client.close();
}
