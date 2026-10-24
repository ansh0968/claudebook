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
const scene = "graphs";
const notebook = await (await api("notebooks", { title: `Drawing acceptance: ${scene}`, pages: 1, background: "blank" })).json();
const page = notebook.pages[0];
if (scene === "graphs") {
  await draw(page.id, [
    { type: "text", x: 70, y: 70, text: "Graphs: one coordinate system", size: 40, color: "#254E49" },
    { type: "axes", origin: [300, 760], xrange: [-2, 5], yrange: [-1, 4], unit: 85, name: "g1", grid: true, color: "black" },
    { type: "shade", axes: "g1", fn1: "x^2/2", fn2: "axis", from: 0, to: 2, color: "#3B82F6" },
    { type: "plot", axes: "g1", fn: "x^2/2", from: -2, to: 4, color: "#3B82F6" },
    { type: "point", axes: "g1", at: [2, 2], label: "P(2,2)", label_pos: "nw", filled: false },
    { type: "angle", vertex: [300, 760], from: [400, 760], to: [360, 680], label: "θ", radius: 40 },
    { type: "plot", axes: "g1", x: "cos(t)", y: "sin(t)", t: [0, "2pi"], dashed: true, color: "#30A46C" },
    { type: "text", x: 70, y: 1050, text: "Blue: y = x^2/2. Green: parametric circle.", size: 30, color: "#254E49" },
  ]);
} else throw new Error(`Unknown scene: ${scene}`);
await api("view", { notebookId: notebook.id, pageId: page.id });
fs.mkdirSync("shots", { recursive: true });
fs.writeFileSync(`shots/16-${scene}-server.png`, Buffer.from(await (await api(`pages/${page.id}/render.png`)).arrayBuffer()));
console.log(`Seeded ${scene} acceptance scene on ${page.id}`);
