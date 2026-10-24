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
const scene = process.argv[2] ?? "chemistry";
const notebook = await (await api("notebooks", { title: `Drawing acceptance: ${scene}`, pages: 1, background: "blank" })).json();
const page = notebook.pages[0];
if (scene === "chemistry") {
  const molecules = await draw(page.id, [
    { type: "text", x: 70, y: 70, text: "SN2: follow the electron pair", size: 40, color: "#254E49" },
    { type: "molecule", smiles: "CBr", x: 440, y: 410, size: 280, show_carbons: true, explicit_h: true, color: "black" },
    { type: "molecule", smiles: "[OH-]", x: 90, y: 420, size: 130, color: "black" },
  ]);
  const substrate = molecules[1], nucleophile = molecules[2];
  await draw(page.id, [
    { type: "ellipse", center: [nucleophile.atoms["0"][0] + 35, nucleophile.atoms["0"][1] - 28], rx: 3, fill: "black", color: "black" },
    { type: "ellipse", center: [nucleophile.atoms["0"][0] + 45, nucleophile.atoms["0"][1] - 28], rx: 3, fill: "black", color: "black" },
    { type: "curly", from: [nucleophile.atoms["0"][0] + 40, nucleophile.atoms["0"][1] - 28], to: substrate.atoms["0"], bend: -160, head: "full", width: 3 },
    { type: "curved_arrow", from: [(substrate.atoms["0"][0] + substrate.atoms["1"][0]) / 2, (substrate.atoms["0"][1] + substrate.atoms["1"][1]) / 2], to: substrate.atoms["1"], bend: 70, head: "full", width: 3 },
    { type: "text", x: 70, y: 850, text: "Fishhook: one-electron movement", size: 32, color: "#254E49" },
    { type: "curly", from: [180, 1050], to: [650, 1050], bend: -110, head: "half", width: 4 },
    { type: "curved_arrow", from: [180, 1200], to: [650, 1200], bend: 90, half_head: true, width: 4 },
  ]);
} else throw new Error(`Unknown scene: ${scene}`);
await api("view", { notebookId: notebook.id, pageId: page.id });
fs.mkdirSync("shots", { recursive: true });
fs.writeFileSync(`shots/14-${scene}-server.png`, Buffer.from(await (await api(`pages/${page.id}/render.png`)).arrayBuffer()));
console.log(`Seeded ${scene} acceptance scene on ${page.id}`);
