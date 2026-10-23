// Disposable chemistry notebook used by the simulator. Never points at the live server.
const base = process.env.BASE ?? "http://127.0.0.1:8787";
const secret = process.env.SECRET;
if (!secret || new URL(base).hostname !== "127.0.0.1") throw new Error("Smoke fixtures require a local server");
async function api(route, body) {
  const response = await fetch(`${base}/api/${route}`, {
    method: body ? "POST" : "GET",
    headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!response.ok) throw new Error(`${route}: ${response.status} ${await response.text()}`);
  return response.json();
}
async function tool(name, args) {
  const response = await fetch(`${base}/mcp/${secret}`, {
    method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }),
  });
  const result = await response.json();
  if (!response.ok || result.error || result.result?.isError) throw new Error(JSON.stringify(result));
}
const title = "Organic chemistry";
if (["reveal", "focus"].includes(process.argv[2])) {
  const list = await api("notebooks");
  const notebook = list.notebooks.find(n => n.title === title);
  const page = notebook?.pages[0];
  if (!page) throw new Error("Missing chemistry smoke page");
  await api("view", { notebookId: notebook.id, pageId: page.id });
  if (process.argv[2] === "focus") {
    console.log("Focused the chemistry smoke page");
    process.exit(0);
  }
  const hint = page?.claudeLayer.find(i => i.type === "hint");
  if (!hint) throw new Error("Missing smoke hint");
  await api(`pages/${page.id}/hints/${hint.id}/reveal`, {});
  console.log("Revealed the chemistry hint");
} else {
  const notebook = await api("notebooks", { title, pages: 2, background: "dotted" });
  const page = notebook.pages[0];
  await tool("draw_on_page", { page_id: page.id, items: [
    { type: "text", x: 75, y: 70, text: "Small steps. Clear mechanisms.", size: 42, color: "#254E49", group: "heading" },
    { type: "text", x: 75, y: 155, text: "ΔH ⇒ ⊖ ‡ ⑤ H₂O", size: 38, color: "#253A46", group: "symbols" },
    { type: "line", from: [75, 225], to: [925, 225], color: "#CFDCD7", width: 2 },
    { type: "text", x: 75, y: 260, text: "01   Read the structure", size: 30, color: "#64776D" },
    { type: "molecule", smiles: "CCO", x: 120, y: 330, size: 200, color: "#253A46", group: "molecules" },
    { type: "molecule", smiles: "c1ccccc1O", x: 590, y: 330, size: 230, color: "#253A46", group: "molecules" },
    { type: "text", x: 120, y: 570, text: "ethanol", size: 28, color: "#253A46" },
    { type: "text", x: 590, y: 570, text: "phenol", size: 28, color: "#253A46" },
    { type: "text", x: 75, y: 665, text: "02   Follow the electrons", size: 30, color: "#64776D" },
    { type: "curved_arrow", from: [160, 800], to: [430, 800], bend: -110, color: "#C16F52", width: 4 },
    { type: "curved_arrow", from: [560, 800], to: [830, 800], bend: 110, half_head: true, color: "#357A73", width: 4 },
    { type: "text", x: 150, y: 855, text: "electron pair", size: 24, color: "#64776D" },
    { type: "text", x: 550, y: 855, text: "one electron", size: 24, color: "#64776D" },
    { type: "path", points: [[100, 970], [170, 920], [240, 970], [310, 920]], smooth: false, color: "#253A46", width: 3 },
    { type: "hint", x: 500, y: 950, label: "Hint 1", text: "Start at the electron-rich site.", size: 25, color: "#357A73" },
    { type: "text", x: 75, y: 1100, text: "What makes phenol more acidic?", size: 32, color: "#253A46" },
  ] });
  await api(`pages/${page.id}/doubts`, { region: { x: 65, y: 1060, w: 800, h: 150 } });
  await api("view", { notebookId: notebook.id, pageId: page.id });
  await api("notebooks", { title: "Past papers", pages: 3, background: "lined" });
  await api("notebooks", { title: "Reaction notes", pages: 2, background: "grid" });
  console.log(`Seeded chemistry smoke notebook ${notebook.id}`);
}
