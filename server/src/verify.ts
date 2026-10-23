// Read-only production check, run from CI after each deploy. Never writes to notebooks.
// Usage: CLAUDEBOOK_URL=https://book.clarifiq.in CLAUDEBOOK_SECRET=... npx tsx src/verify.ts
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import WebSocket from "ws";

const base = process.env.CLAUDEBOOK_URL!;
const secret = process.env.CLAUDEBOOK_SECRET!;
let failed = false;
const check = (name: string, ok: boolean, detail = "") => {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` (${detail})` : ""}`);
  if (!ok) failed = true;
};

const health = await fetch(`${base}/health`);
check("https health", health.ok);

const httpUrl = base.replace(/^https:/, "http:");
const redirect = await fetch(`${httpUrl}/health`, { redirect: "manual" });
check("http redirects to https", redirect.status === 301 && (redirect.headers.get("location") ?? "").startsWith("https://"), String(redirect.status));

check("api rejects missing token", (await fetch(`${base}/api/notebooks`)).status === 401);
check("mcp rejects wrong secret", (await fetch(`${base}/mcp/wrong-secret-000000`, { method: "POST" })).status === 404);

const api = await fetch(`${base}/api/notebooks`, { headers: { Authorization: `Bearer ${secret}` } });
check("api with token", api.ok);

const client = new Client({ name: "verify", version: "0" });
await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));
const tools = (await client.listTools()).tools.map((t) => t.name);
check("mcp lists tools", tools.includes("get_current_page") && tools.includes("draw_on_page"), tools.join(","));
const page = (await client.callTool({ name: "get_current_page", arguments: {} })) as { content: { type: string }[] };
check("mcp returns page image", page.content.some((c) => c.type === "image"));
await client.close();

const wsUrl = `${base.replace(/^http/, "ws")}/live?token=${encodeURIComponent(secret)}`;
const hello = await new Promise<string>((resolve) => {
  const ws = new WebSocket(wsUrl);
  const timer = setTimeout(() => { ws.terminate(); resolve("timeout"); }, 8000);
  ws.on("message", (m) => { clearTimeout(timer); ws.close(); resolve(String(m)); });
  ws.on("error", (e) => { clearTimeout(timer); resolve(`error: ${e.message}`); });
});
check("websocket through nginx", hello.includes("hello"), hello.slice(0, 60));

process.exit(failed ? 1 : 0);
