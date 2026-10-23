import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import express, { type NextFunction, type Request, type Response } from "express";
import { WebSocketServer, type WebSocket } from "ws";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { renderHandwriting } from "./handwriting.js";
import { buildMcpServer } from "./mcp.js";
import { PDF_ID, pdfPath, savePdf } from "./pdf.js";
import { claudeLayerSvg, renderPage } from "./render.js";
import { Store, type Background, type TextBox } from "./store.js";
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
const upgraded = store.upgradeItems((item) =>
  item.type === "text" && !item.d ? { ...item, ...renderHandwriting(item.text, item.x, item.y, item.size ?? 32) } : undefined,
);
if (upgraded) console.log(`gave ${upgraded} text item(s) handwriting outlines`);
const app = express();
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

api.get("/notebooks", (_req, res) => res.json({ notebooks: store.listNotebooks(), view: store.view() }));

api.post("/notebooks", (req, res) => {
  const { title, pages, background } = req.body as { title?: string; pages?: number; background?: Background };
  res.json(store.createNotebook(title || "Untitled", pages ?? 1, background ?? "blank"));
});

/** The app uploads a PDF from Files; every PDF page becomes a notebook page. */
api.post("/notebooks/import-pdf", express.raw({ type: "application/pdf", limit: "100mb" }), async (req, res) => {
  if (!Buffer.isBuffer(req.body) || req.body.length === 0) return res.status(400).json({ error: "send the PDF as the body with Content-Type application/pdf" });
  try {
    const { file, pages } = await savePdf(store, req.body);
    const title = typeof req.query.title === "string" && req.query.title.trim() ? req.query.title.trim() : "Imported PDF";
    res.json(store.addPdfPages(file, pages, title).notebook);
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
  nb ? res.json(nb) : res.status(404).json({ error: "not found" });
});

api.post("/notebooks/:id/pages", (req, res) => {
  const { count, afterIndex, background } = req.body as { count?: number; afterIndex?: number; background?: Background };
  try {
    const pages = Array.from({ length: count ?? 1 }, () => store.newPage(background ?? "blank"));
    store.insertPages(req.params.id, pages, afterIndex);
    res.json({ pages });
  } catch (e) {
    res.status(404).json({ error: String(e) });
  }
});

/** The app reports what's on screen so Claude knows what "this page" means. */
api.post("/view", (req, res) => {
  const { notebookId, pageId } = req.body as { notebookId: string; pageId: string };
  if (!store.findPage(pageId)) return res.status(404).json({ error: "no such page" });
  store.setView(notebookId, pageId);
  res.json(store.view());
});

/** The app uploads a render of the user's ink (PNG, base64) plus on-device handwriting recognition. */
api.put("/pages/:id/snapshot", (req, res) => {
  const { png, textBoxes } = req.body as { png: string; textBoxes?: TextBox[] };
  try {
    store.saveSnapshot(req.params.id, Buffer.from(png, "base64"), textBoxes);
    res.json({ ok: true });
  } catch (e) {
    res.status(404).json({ error: String(e) });
  }
});

api.put("/pages/:id/drawing", express.raw({ type: "*/*", limit: "50mb" }), (req, res) => {
  try {
    store.saveDrawing(req.params.id, req.body as Buffer);
    res.json({ ok: true });
  } catch (e) {
    res.status(404).json({ error: String(e) });
  }
});

api.get("/pages/:id/drawing", (req, res) => {
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
  res.type("svg").set("Cache-Control", "no-store").send(claudeLayerSvg(found.page));
});

api.get("/pages/:id/claude", (req, res) => {
  const found = store.findPage(req.params.id);
  found ? res.json({ items: found.page.claudeLayer }) : res.status(404).end();
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
