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
  // A small folder tree, like a real study library.
  const chemistry = await api("folders", { name: "Chemistry" });
  const organic = await api("folders", { name: "Organic", parentId: chemistry.id });
  const maths = await api("folders", { name: "Maths" });
  await api("folders", { name: "Physics" });
  const notebook = await api("notebooks", { title, pages: 2, background: "dotted", folderId: organic.id });
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
  // A real raster image on page 1 exercises authenticated fetch, async tile
  // invalidation and rendering alongside ink. The SVG input is normalized by sharp.
  const diagram = `<svg xmlns="http://www.w3.org/2000/svg" width="360" height="140"><rect width="360" height="140" rx="12" fill="#eef8f4"/><path d="M45 110V30M45 110H330M65 100Q160 15 315 60" fill="none" stroke="#357a73" stroke-width="5"/><circle cx="185" cy="53" r="9" fill="#c16f52"/><text x="200" y="115" font-size="20" fill="#253a46">image diagram</text></svg>`;
  await tool("place_image", { page_id: page.id, x: 710, y: 95, w: 220, data: Buffer.from(diagram).toString("base64"), alt: "Image cache smoke diagram", group: "smoke-image" });
  await api(`pages/${page.id}/doubts`, { region: { x: 65, y: 1060, w: 800, h: 150 } });
  await api("view", { notebookId: notebook.id, pageId: page.id });
  await api("notebooks", { title: "Past papers", pages: 3, background: "lined" });
  await api("notebooks", { title: "Reaction notes", pages: 2, background: "grid", folderId: chemistry.id });
  await api("notebooks", { title: "Equilibrium", pages: 1, background: "lined", folderId: chemistry.id });
  await api("notebooks", { title: "Calculus", pages: 4, background: "grid", folderId: maths.id });
  // Two scratch pads, one with something on it so its thumbnail isn't blank.
  const pad = await api("notebooks", { title: "Scratch · quick integral", scratch: true });
  await tool("draw_on_page", { page_id: pad.pages[0].id, items: [
    { type: "math", latex: "\\int_0^1 x e^{x}\\,dx = 1", x: 90, y: 120, size: 64, color: "#253A46" },
    { type: "ellipse", center: [520, 520], rx: 260, ry: 140, color: "#C16F52", width: 6 },
    { type: "text", x: 330, y: 490, text: "by parts!", size: 54, color: "#357A73" },
  ] });
  await api("notebooks", { title: "Scratch · ideas", scratch: true });
  await api("view", { notebookId: notebook.id, pageId: page.id });
  const interactive = await api("notebooks", { title: "Interactive blocks", pages: 2, background: "blank" });
  const webPage = interactive.pages[0];
  await tool("add_web_block", { page_id: webPage.id, x: 100, y: 120, w: 800, h: 400, title: "Animated button", html: `<style>@keyframes orbit{to{transform:translateX(650px)}}.ball{width:40px;height:40px;border-radius:50%;background:coral;animation:orbit 2s infinite alternate}button{font-size:32px;margin:24px}</style><button onclick="this.textContent='Clicked';console.warn('button changed')">Tap animation</button><div class=ball></div><script>console.warn('initial viewport '+innerWidth+'x'+innerHeight);window.addEventListener('load',()=>console.warn('viewport '+innerWidth+'x'+innerHeight));</script>` });
  await tool("add_web_block", { page_id: webPage.id, x: 100, y: 600, w: 800, h: 220, title: "Intentional error", html: "<p>Error feedback test</p><script>throw new Error('smoke load error')</script>" });
  // Restore the chemistry page for all existing screenshot and study tests.
  await api("view", { notebookId: notebook.id, pageId: page.id });
  console.log(`Seeded chemistry smoke notebook ${notebook.id}`);
}
