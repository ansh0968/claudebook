// End-to-end check: boots nothing itself, talks to a running server like the Claude app would.
// Usage: CLAUDEBOOK_URL=http://localhost:8787 CLAUDEBOOK_SECRET=... npm test
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787";
const secret = process.env.CLAUDEBOOK_SECRET!;
const client = new Client({ name: "selftest", version: "0" });
await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));

const tools = await client.listTools();
console.log("tools:", tools.tools.map((t) => t.name).join(", "));

const call = async (name: string, args: Record<string, unknown> = {}, expectError = false) => {
  const r = (await client.callTool({ name, arguments: args })) as { content: any[]; isError?: boolean };
  for (const c of r.content) {
    if (c.type === "text") console.log(`[${name}]`, c.text);
    if (c.type === "image") fs.writeFileSync(`/tmp/claude-selftest-${name}.png`, Buffer.from(c.data, "base64"));
  }
  if (!!r.isError !== expectError) throw new Error(`${name} ${expectError ? "should have failed" : "failed"}`);
  return r;
};
const api = async (path: string, init: RequestInit = {}) => {
  const res = await fetch(`${base}/api${path}`, { ...init, headers: { Authorization: `Bearer ${secret}`, ...init.headers } });
  if (!res.ok) throw new Error(`${path}: HTTP ${res.status} ${await res.text()}`);
  return res;
};
const has = (bin: string) => {
  try {
    execFileSync("sh", ["-c", `command -v ${bin}`], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
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
await call("draw_on_page", {
  items: [{ type: "math", latex: "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}", x: 80, y: 700, color: "#30A46C" }],
});
await call("draw_on_page", { items: [{ type: "math", latex: "\\frac{1}{", x: 80, y: 900 }] }, true);
const open = (await (await api("/notebooks")).json()) as { view: { pageId: string } };
const stored = (await (await api(`/pages/${open.view.pageId}/claude`)).json()) as { items: { type: string; d?: string; w?: number }[] };
const math = stored.items.find((i) => i.type === "math");
if (!math?.d || !math.w) throw new Error("math item was not typeset");
console.log(`[math] stored outline, ${math.d.length} chars, ${math.w}px wide`);
await call("get_current_page");
await call("view_page", { zoom: { x: 50, y: 50, w: 600, h: 200 } });
await call("erase_my_drawings", { count: 1 });
await call("add_pages", { count: 2, background: "lined" });
await call("create_notebook", { title: "Physics", pages: 3, background: "grid" });

if (has("typst") && has("pdftoppm") && has("pdfinfo")) {
  const typst = `= Practice\nSolve $x^2 - 5x + 6 = 0$.\n#v(4cm)\n$ x = (-b plus.minus sqrt(b^2 - 4a c)) / (2a) $\n#pagebreak()\n= Page two\nShow your working.`;
  await call("create_pdf", { title: "Worksheet", typst });
  await call("create_pdf", { title: "Broken", typst: "#let x = (" }, true);
  const list = (await (await api("/notebooks")).json()) as { notebooks: { id: string; title: string; pages: { id: string; pdf?: { file: string; page: number } }[] }[] };
  const sheet = list.notebooks.find((n) => n.title === "Worksheet");
  if (sheet?.pages.length !== 2 || !sheet.pages[1].pdf) throw new Error("create_pdf should make 2 PDF pages");
  await call("view_page", { notebook_id: sheet.id, page_number: 2, grid: false });

  const pdf = Buffer.from(await (await api(`/pdfs/${sheet.pages[0].pdf!.file}`)).arrayBuffer());
  const imported = (await (await api("/notebooks/import-pdf?title=Reimported", { method: "POST", headers: { "Content-Type": "application/pdf" }, body: pdf })).json()) as { pages: unknown[] };
  if (imported.pages.length !== 2) throw new Error("import-pdf should make 2 pages");
  console.log("[import-pdf] made a 2-page notebook");
} else {
  console.log("SKIP pdf checks (typst, pdftoppm or pdfinfo not installed here)");
}

await call("list_notebooks");
await client.close();
console.log("selftest passed");
