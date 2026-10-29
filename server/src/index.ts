import { isBackground, isPaper, type Paper } from "./paper.js";
import { registerImageRoutes } from "./images.js";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import express, { type NextFunction, type Request, type Response } from "express";
import { WebSocketServer, type WebSocket } from "ws";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { renderLegacyHandwriting } from "./handwriting.js";
import { prepareItems } from "./items.js";
import { buildMcpServer } from "./mcp.js";
import { registerPageRoutes } from "./page-management.js";
import { PDF_ID, pdfPath, savePdf } from "./pdf.js";
import { claudeLayerSvg, renderPage } from "./render.js";
import { Store, type Background, type Notebook, type TextBox } from "./store.js";
import { parsePageRegion } from "./regions.js";

const PORT = Number(process.env.PORT ?? 8787);
const DATA_DIR = process.env.DATA_DIR ?? path.resolve("data");
// One secret guards everything: it is part of the connector URL Claude uses, and the bearer token the iPad app sends.
const SECRET = process.env.CLAUDEBOOK_SECRET ?? "";
if (SECRET.length < 16) {
  console.error("CLAUDEBOOK_SECRET must be set to at least 16 characters");
  process.exit(1);
}

const store = new Store(DATA_DIR);
// Text drawn before handwriting outlines existed gets them now, so the app renders it in the same font.
const upgraded = store.upgradeItems((item) => {
  // Legacy mechanisms gain the same prepared geometry as newly drawn chemistry arrows.
  if ((item.type === "curved_arrow" || item.type === "curly") && !item.d) {
    const [prepared] = prepareItems([item]);
    return { ...prepared, id: item.id, createdAt: item.createdAt };
  }
  if (item.type !== "text" || item.d) return;
  const { unsupported, ...outline } = renderLegacyHandwriting(item.text, item.x, item.y, item.size ?? 32);
  if (unsupported) console.warn(`Text item ${item.id} needs a supported font; original text was preserved.`);
  return { ...item, ...outline };
});
if (upgraded) console.log(`gave ${upgraded} text item(s) handwriting outlines`);
const purgeScratch = () => {
  const purged = store.purgeExpiredScratchPads();
  if (purged.length) console.log(`deleted ${purged.length} expired scratch pad(s)`);
};
purgeScratch();
setInterval(purgeScratch, 60 * 60 * 1000).unref();
const app = express();
/** Older app builds don't send a stroke count; anything that isn't a whole number is ignored. */
const strokeCountFrom = (n: unknown) => (typeof n === "number" && Number.isInteger(n) && n >= 0 ? n : undefined);
app.disable("x-powered-by");

const safeEqual = (a: string, b: string) => {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};

function tokenFrom(req: Request) {
  const h = req.headers.authorization;
  if (h?.startsWith("Bearer ")) return h.slice(7);
  return typeof req.query.token === "string" ? req.query.token : "";
}

function requireToken(req: Request, res: Response, next: NextFunction) {
  if (safeEqual(tokenFrom(req), SECRET)) return next();
  res.status(401).json({ error: "unauthorized" });
}

app.get("/health", (_req, res) => res.json({ ok: true }));

// --- MCP endpoint for the Claude app (custom connector URL: https://<host>/mcp/<secret>) ---
app.post("/mcp/:secret", express.json({ limit: "10mb" }), async (req, res) => {
  if (!safeEqual(req.params.secret, SECRET)) return res.status(404).end();
  // We always answer with plain JSON, so don't turn away clients (ChatGPT's included) that
  // send a narrower Accept header than the SDK insists on.
  req.headers.accept = "application/json, text/event-stream";
  // Stateless: a fresh server + transport per request keeps things simple and restart-proof.
  const server = buildMcpServer(store);
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
  res.on("close", () => {
    transport.close();
    server.close();
  });
  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch (err) {
    console.error("mcp error", err);
    if (!res.headersSent) res.status(500).json({ jsonrpc: "2.0", error: { code: -32603, message: "Internal error" }, id: null });
  }
});
app.all("/mcp/:secret", (_req, res) => res.status(405).set("Allow", "POST").end());

// --- REST API for the iPad app and the web viewer ---
const api = express.Router();
api.use(requireToken, express.json({ limit: "25mb" }));
registerPageRoutes(api, store);
registerImageRoutes(api, store);

/** Notebooks as the app sees them: scratch pads carry the time they'll delete themselves. */
const withExpiry = (nb: Notebook) => (nb.scratch ? { ...nb, expiresAt: store.scratchExpiry(nb) } : nb);
const FOLDER_NAME = /^.{1,100}$/su;

api.post("/pages/background", (req, res) => {
  try {
    const { pageIds, background, paper } = req.body ?? {};
    if (!Array.isArray(pageIds) || !pageIds.length || pageIds.length > 1000 || !pageIds.every(id => typeof id === "string")) return res.status(400).json({ error: "pageIds must be a nonempty array of page ids" });
    res.json({ pages: store.setBackground(pageIds, background, paper) });
  } catch (error) { res.status(400).json({ error: (error as Error).message }); }
});

api.get("/notebooks", (_req, res) => res.json({ notebooks: store.listNotebooks().map(withExpiry), folders: store.listFolders(), view: store.view() }));

api.get("/search", (req, res) => {
  if (typeof req.query.q !== "string" || !req.query.q.trim()) return res.status(400).json({ error: "q must be nonempty text" });
  res.json({ results: store.searchNotes(req.query.q) });
});

api.post("/notebooks", (req, res) => {
  const { title, pages, background, paper, folderId, scratch } = req.body as { title?: string; pages?: number; background?: Background; paper?: Paper; folderId?: string; scratch?: boolean };
  if (folderId !== undefined && (typeof folderId !== "string" || (folderId && !store.getFolder(folderId)))) return res.status(400).json({ error: "folderId must name an existing folder" });
  if (scratch && folderId) return res.status(400).json({ error: "scratch pads live outside folders" });
  if (background !== undefined && !isBackground(background)) return res.status(400).json({ error: "invalid background" });
  if (paper !== undefined && !isPaper(paper)) return res.status(400).json({ error: "invalid paper" });
  const nb = store.createNotebook(title || (scratch ? "Scratch pad" : "Untitled"), pages ?? 1, background ?? (scratch ? "grid" : "blank"), { folderId: folderId || undefined, scratch: scratch === true, paper });
  res.json(withExpiry(nb));
});

api.post("/folders", (req, res) => {
  const name = typeof req.body?.name === "string" ? req.body.name.trim() : "";
  const parentId = req.body?.parentId;
  if (!FOLDER_NAME.test(name)) return res.status(400).json({ error: "name must be 1-100 characters" });
  if (parentId !== undefined && parentId !== null && parentId !== "" && (typeof parentId !== "string" || !store.getFolder(parentId))) return res.status(400).json({ error: "parentId must name an existing folder" });
  res.status(201).json(store.createFolder(name, parentId || undefined));
});

api.patch("/folders/:id", (req, res) => {
  const changes: { name?: string; parentId?: string | null } = {};
  if (req.body?.name !== undefined) {
    const name = typeof req.body.name === "string" ? req.body.name.trim() : "";
    if (!FOLDER_NAME.test(name)) return res.status(400).json({ error: "name must be 1-100 characters" });
    changes.name = name;
  }
  if (req.body?.parentId !== undefined) {
    if (req.body.parentId !== null && typeof req.body.parentId !== "string") return res.status(400).json({ error: "parentId must be a folder id, or empty for the top level" });
    changes.parentId = req.body.parentId || null;
  }
  if (!Object.keys(changes).length) return res.status(400).json({ error: "send name and/or parentId" });
  try {
    const folder = store.updateFolder(req.params.id, changes);
    folder ? res.json(folder) : res.status(404).json({ error: "not found" });
  } catch (e) {
    res.status(400).json({ error: (e as Error).message });
  }
});

api.delete("/folders/:id", (req, res) => {
  store.deleteFolder(req.params.id) ? res.json({ ok: true }) : res.status(404).json({ error: "not found" });
});

/** The app uploads a PDF from Files; every PDF page becomes a notebook page. */
api.post("/notebooks/import-pdf", express.raw({ type: "application/pdf", limit: "100mb" }), async (req, res) => {
  if (!Buffer.isBuffer(req.body) || req.body.length === 0) return res.status(400).json({ error: "send the PDF as the body with Content-Type application/pdf" });
  try {
    const { file, pages } = await savePdf(store, req.body);
    const title = typeof req.query.title === "string" && req.query.title.trim() ? req.query.title.trim() : "Imported PDF";
    const folderId = typeof req.query.folderId === "string" && store.getFolder(req.query.folderId) ? req.query.folderId : undefined;
    res.json(store.addPdfPages(file, pages, title, undefined, folderId).notebook);
  } catch (e) {
    res.status(400).json({ error: (e as Error).message });
  }
});

api.get("/pdfs/:file", (req, res) => {
  if (!PDF_ID.test(req.params.file)) return res.status(400).end();
  const file = path.resolve(pdfPath(store, req.params.file));
  fs.existsSync(file) ? res.type("application/pdf").set("Cache-Control", "private, max-age=31536000, immutable").sendFile(file) : res.status(404).end();
});

api.get("/notebooks/:id", (req, res) => {
  const nb = store.getNotebook(req.params.id);
  nb ? res.json(withExpiry(nb)) : res.status(404).json({ error: "not found" });
});

/** Rename, move into a folder (folderId "" or null = top level), and/or keep a scratch pad (scratch: false). */
api.patch("/notebooks/:id", (req, res) => {
  const changes: { title?: string; folderId?: string | null; scratch?: false } = {};
  if (req.body?.title !== undefined) {
    const title = typeof req.body.title === "string" ? req.body.title.trim() : "";
    if (!title || title.length > 200) return res.status(400).json({ error: "title must be 1-200 characters" });
    changes.title = title;
  }
  if (req.body?.folderId !== undefined) {
    if (req.body.folderId !== null && typeof req.body.folderId !== "string") return res.status(400).json({ error: "folderId must be a folder id, or empty for the top level" });
    changes.folderId = req.body.folderId || null;
  }
  if (req.body?.scratch !== undefined) {
    if (req.body.scratch !== false) return res.status(400).json({ error: "scratch can only be set to false, to keep a scratch pad" });
    changes.scratch = false;
  }
  if (!Object.keys(changes).length) return res.status(400).json({ error: "send title, folderId and/or scratch" });
  const nb = store.getNotebook(req.params.id);
  if (!nb) return res.status(404).json({ error: "not found" });
  if (changes.folderId && nb.scratch && changes.scratch !== false) return res.status(400).json({ error: "keep the scratch pad (scratch: false) to file it in a folder" });
  try {
    res.json(withExpiry(store.updateNotebook(req.params.id, changes)!));
  } catch (e) {
    res.status(400).json({ error: (e as Error).message });
  }
});

/** The user said no to Claude's request to delete this notebook. */
api.delete("/notebooks/:id/delete-request", (req, res) => {
  store.cancelDeleteRequest(req.params.id) ? res.json({ ok: true }) : res.status(404).json({ error: "not found" });
});

api.delete("/notebooks/:id", (req, res) => {
  const notebook = store.getNotebook(req.params.id);
  if (!notebook) return res.status(404).json({ error: "not found" });
  const deletedPageIds = notebook.pages.map(p => p.id);
  store.deleteNotebook(req.params.id);
  res.json({ ok: true, deletedPageIds });
});

api.post("/notebooks/:id/pages", (req, res) => {
  const { count, afterIndex, background, paper } = req.body as { count?: number; afterIndex?: number; background?: Background; paper?: Paper };
  try {
    if (count !== undefined && (!Number.isInteger(count) || count < 1 || count > 100)) return res.status(400).json({ error: "count must be an integer from 1 to 100" });
    if (background !== undefined && !isBackground(background)) return res.status(400).json({ error: "invalid background" });
    if (paper !== undefined && !isPaper(paper)) return res.status(400).json({ error: "invalid paper" });
    const pages = Array.from({ length: count ?? 1 }, () => store.newPage(background ?? "blank", paper));
    store.insertPages(req.params.id, pages, afterIndex);
    res.json({ pages });
  } catch (e) {
    res.status(400).json({ error: String(e) });
  }
});

/** The app reports what's on screen so Claude knows what "this page" means. */
api.post("/view", (req, res) => {
  const { notebookId, pageId } = req.body as { notebookId: string; pageId: string };
  const found = store.findPage(pageId);
  if (!found) return res.status(404).json({ error: "no such page" });
  if (found.notebook.id !== notebookId) return res.status(400).json({ error: "page does not belong to this notebook" });
  store.setView(notebookId, pageId);
  res.json(store.view());
});

/** The app uploads a render of the user's ink (PNG, base64) plus on-device handwriting recognition. */
api.put("/pages/:id/snapshot", (req, res) => {
  const { png, textBoxes, strokeCount } = req.body as { png: string; textBoxes?: TextBox[]; strokeCount?: number };
  try {
    store.saveSnapshot(req.params.id, Buffer.from(png, "base64"), textBoxes, strokeCountFrom(strokeCount));
    res.json({ ok: true });
  } catch (e) {
    res.status(404).json({ error: String(e) });
  }
});

api.put("/pages/:id/drawing", express.raw({ type: "*/*", limit: "50mb" }), (req, res) => {
  try {
    store.saveDrawing(req.params.id, req.body as Buffer, strokeCountFrom(req.query.strokes === undefined ? undefined : Number(req.query.strokes)));
    res.json({ ok: true });
  } catch (e) {
    res.status(404).json({ error: String(e) });
  }
});

api.get("/pages/:id/drawing", (req, res) => {
  if (!store.findPage(req.params.id)) return res.status(404).end();
  const file = store.drawingPath(req.params.id);
  fs.existsSync(file) ? res.type("application/octet-stream").sendFile(file) : res.status(404).end();
});

api.get("/pages/:id/render.png", async (req, res) => {
  const found = store.findPage(req.params.id);
  if (!found) return res.status(404).end();
  const png = await renderPage(store, found.page, { grid: req.query.grid === "1" });
  res.type("png").set("Cache-Control", "no-store").send(png);
});

api.get("/pages/:id/claude.svg", (req, res) => {
  const found = store.findPage(req.params.id);
  if (!found) return res.status(404).end();
  res.type("svg").set("Cache-Control", "no-store").send(claudeLayerSvg(found.page, store));
});

api.get("/pages/:id/claude", (req, res) => {
  const found = store.findPage(req.params.id);
  found ? res.json({ items: found.page.claudeLayer }) : res.status(404).end();
});

api.post("/pages/:id/hints/:itemId/reveal", (req, res) => {
  const item = store.revealHint(req.params.id, req.params.itemId);
  item ? res.json({ item }) : res.status(404).json({ error: "hint not found on this page" });
});

api.post("/pages/:id/doubts", (req, res) => {
  if (!store.findPage(req.params.id)) return res.status(404).json({ error: "no such page" });
  const region = parsePageRegion(req.body?.region);
  if (!region || (req.body?.pageId !== undefined && req.body.pageId !== req.params.id)) {
    return res.status(400).json({ error: "pageId must match the URL and region must fit within the page" });
  }
  res.status(201).json({ doubt: store.addDoubt(req.params.id, region) });
});

api.get("/pages/:id/doubts", (req, res) => {
  const found = store.findPage(req.params.id);
  if (!found) return res.status(404).json({ error: "no such page" });
  if (req.query.status !== undefined && req.query.status !== "open") return res.status(400).json({ error: "status must be open" });
  res.json({ doubts: found.page.doubts.filter((d) => req.query.status !== "open" || !d.resolvedAt) });
});

api.delete("/pages/:id/claude", (req, res) => {
  try {
    const count = req.query.count ? Number(req.query.count) : undefined;
    res.json({ removed: store.removeClaudeItems(req.params.id, count) });
  } catch (e) {
    res.status(404).json({ error: String(e) });
  }
});

app.use("/api", api);

// --- Web viewer, handy for testing from any browser before the iPad app exists ---
const viewerHtml = fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "public", "viewer.html"), "utf8");
app.get("/view", requireToken, (_req, res) => res.type("html").send(viewerHtml));

// --- Live updates: the app/viewer listens here and re-renders when Claude draws ---
const httpServer = http.createServer(app);
const wss = new WebSocketServer({ noServer: true });
const sockets = new Set<WebSocket>();

httpServer.on("upgrade", (req, socket, head) => {
  const url = new URL(req.url ?? "", "http://x");
  const token = url.searchParams.get("token") ?? req.headers.authorization?.replace(/^Bearer /, "") ?? "";
  if (url.pathname !== "/live" || !safeEqual(token, SECRET)) {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    return socket.destroy();
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    sockets.add(ws);
    ws.send(JSON.stringify({ type: "hello" }));
    ws.on("close", () => sockets.delete(ws));
  });
});

store.on((event) => {
  const msg = JSON.stringify(event);
  for (const ws of sockets) if (ws.readyState === ws.OPEN) ws.send(msg);
});

// Keep connections alive through proxies.
setInterval(() => {
  for (const ws of sockets) if (ws.readyState === ws.OPEN) ws.ping();
}, 25_000).unref();

httpServer.listen(PORT, () => console.log(`claudebook server on :${PORT}, data in ${DATA_DIR}`));
