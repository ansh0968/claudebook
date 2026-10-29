// Only the disposable simulator server; saves one clear scene for each requested acceptance paper.
const base = process.env.BASE ?? "http://127.0.0.1:8787", secret = process.env.SECRET;
if (!secret || new URL(base).hostname !== "127.0.0.1") throw new Error("Paper fixture requires a local server");
async function api(route, body) {
  const response = await fetch(`${base}/api/${route}`, { method: body ? "POST" : "GET", headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" }, body: body && JSON.stringify(body) });
  if (!response.ok) throw new Error(await response.text());
  return response.json();
}
const hex = process.argv[2] === "hex";
const notebook = await api("notebooks", { title: hex ? "Hex paper acceptance" : "Cornell black acceptance", background: hex ? "hex" : "cornell", paper: hex ? "white" : "black", pages: 1 });
await api("view", { notebookId: notebook.id, pageId: notebook.pages[0].id });
const response = await fetch(`${base}/mcp/${secret}`, { method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "draw_on_page", arguments: { page_id: notebook.pages[0].id, items: [{ type: "text", x: 340, y: 160, text: hex ? "Hex paper" : "Cornell on black", color: "black", size: 40 }] } } }) });
const result = await response.json();
if (!response.ok || result.error || result.result?.isError) throw new Error(JSON.stringify(result));
console.log(`${notebook.title}: ${notebook.pages[0].id}`);
