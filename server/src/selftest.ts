// End-to-end check: boots nothing itself, talks to a running server like the Claude app would.
// Usage: CLAUDEBOOK_URL=http://localhost:8787 CLAUDEBOOK_SECRET=... npm test
import fs from "node:fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787";
const secret = process.env.CLAUDEBOOK_SECRET!;
const client = new Client({ name: "selftest", version: "0" });
await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));

const tools = await client.listTools();
console.log("tools:", tools.tools.map((t) => t.name).join(", "));

const call = async (name: string, args: Record<string, unknown> = {}) => {
  const r = (await client.callTool({ name, arguments: args })) as { content: any[]; isError?: boolean };
  for (const c of r.content) {
    if (c.type === "text") console.log(`[${name}]`, c.text);
    if (c.type === "image") fs.writeFileSync(`/tmp/claude-selftest-${name}.png`, Buffer.from(c.data, "base64"));
  }
  if (r.isError) throw new Error(`${name} failed`);
};

await call("list_notebooks");
await call("draw_on_page", {
  items: [
    { type: "text", x: 80, y: 80, text: "Hey Sufi, Claude was here\nsecond line", size: 40 },
    { type: "ellipse", center: [300, 105], rx: 240, ry: 60, color: "#E5484D" },
    { type: "arrow", from: [600, 300], to: [420, 160] },
    { type: "path", points: [[100, 400], [200, 350], [300, 420], [400, 360], [500, 410]], color: "#30A46C", width: 4 },
    { type: "highlight", x: 80, y: 500, w: 400, h: 50 },
    { type: "svg", d: "M 600 600 L 800 600 L 700 450 Z", fill: "#D9775733" },
  ],
});
await call("get_current_page");
await call("erase_my_drawings", { count: 1 });
await call("add_pages", { count: 2, background: "lined" });
await call("create_notebook", { title: "Physics", pages: 3, background: "grid" });
await call("list_notebooks");
await client.close();
console.log("selftest passed");
