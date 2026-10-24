// Feature acceptance scenes. Only a disposable loopback server is allowed.
import fs from "node:fs";
const base = process.env.BASE ?? "http://127.0.0.1:8787", secret = process.env.SECRET;
if (!secret || new URL(base).hostname !== "127.0.0.1") throw new Error("Drawing fixtures require a local server");
async function api(route, body) {
  const r = await fetch(`${base}/api/${route}`, { method: body ? "POST" : "GET", headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  if (!r.ok) throw new Error(`${route}: ${r.status} ${await r.text()}`);
  return r;
}
async function draw(page_id, items) {
  const r = await fetch(`${base}/mcp/${secret}`, { method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "draw_on_page", arguments: { page_id, items } } }) });
  const result = await r.json();
  if (!r.ok || result.error || result.result?.isError) throw new Error(JSON.stringify(result));
  const payload = JSON.parse(result.result.content[0].text);
  if (payload.warnings?.length) throw new Error(JSON.stringify(payload.warnings));
  return payload.items;
}
const scene = "physics";
const notebook = await (await api("notebooks", { title: `Drawing acceptance: ${scene}`, pages: 1, background: "blank" })).json();
const page = notebook.pages[0];
if (scene === "physics") {
  await draw(page.id, [
    { type: "text", x: 70, y: 70, text: "Forces on an inclined plane", size: 40, color: "#254E49" },
    { type: "ground", from: [90, 690], to: [850, 251], side: "below", color: "black" },
    { type: "ground", from: [90, 400], to: [90, 690], side: "left", color: "black" },
    { type: "rect", x: 350, y: 400, w: 180, h: 110, rotation: -30, fill: "#DCE8F5", color: "black" },
    { type: "spring", from: [90, 600], to: [360, 443], coils: 7, amplitude: 14, color: "#3B82F6" },
    { type: "text", x: 380, y: 345, text: "block", rotation: -30, color: "black" },
    { type: "math", x: 680, y: 400, latex: "F = kx", rotation: 30 },
    { type: "rect", x: 100, y: 900, w: 200, h: 160, fill_pattern: "cross", pattern_spacing: 25, rotation: 30, fill: "#EBF2F9", color: "#253A46" },
    { type: "ellipse", center: [500, 980], rx: 100, ry: 65, fill_pattern: "dot", rotation: -20, color: "#253A46" },
    { type: "svg", d: "M700,900L900,900L800,1060Z", fill_pattern: "hatch", pattern_angle: 30, pattern_spacing: 12, rotation: 10, color: "#253A46" },
    { type: "text", x: 70, y: 1180, text: "Into the page      Out of the page      Hatching", size: 28, color: "#254E49" },
  ]);
} else throw new Error(`Unknown scene: ${scene}`);
await api("view", { notebookId: notebook.id, pageId: page.id });
fs.mkdirSync("shots", { recursive: true });
fs.writeFileSync(`shots/18-${scene}-server.png`, Buffer.from(await (await api(`pages/${page.id}/render.png`)).arrayBuffer()));
console.log(`Seeded ${scene} acceptance scene on ${page.id}`);
