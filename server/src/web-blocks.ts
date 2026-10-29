// Blocks never execute on the server. Only the sandboxed clients produce feedback and posters.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import sharp from "sharp";
import { z } from "zod";
import { nanoid } from "nanoid";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Router } from "express";
import { itemBBox, offPageWarning, type Item } from "./items.js";
import type { Store } from "./store.js";

export const BLOCK_CSP = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com; style-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com; img-src data: blob: https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com; media-src data: blob: https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com; font-src data: https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com; connect-src https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com; worker-src blob:; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
const bridge = `<script data-claudebook-bridge>(()=>{if(window.__claudebookBridge)return;window.__claudebookBridge=true;let count=0;const send=(kind,message)=>{if(count++>=100)return;try{window.webkit?.messageHandlers?.claudebook?.postMessage({kind,message:String(message).slice(0,1000)})}catch{}};const printable=v=>{try{return typeof v==='string'?v:JSON.stringify(v)}catch{return String(v)}};for(const kind of ['error','warn']){const original=console[kind];console[kind]=(...args)=>{send(kind,args.map(printable).join(' '));original.apply(console,args)}}window.addEventListener('error',e=>send('error',e.message+' (line '+e.lineno+')'));window.addEventListener('unhandledrejection',e=>send('error','Unhandled rejection: '+printable(e.reason)));window.addEventListener('load',()=>{requestAnimationFrame(()=>requestAnimationFrame(()=>send('poster-ready','ready')))});})();</script>`;

export function wrapBlock(html: string) {
  if (Buffer.byteLength(html, "utf8") > 1024 * 1024) throw new Error("html must be at most 1 MB (UTF-8)");
  // Prefix the policy before *any* authored content, including malformed full documents and scripts.
  // Browser HTML parsing merges a supplied full document's body into this skeleton.
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="${BLOCK_CSP}"><style>html,body{margin:0;height:100%;color-scheme:light dark}</style>${bridge}</head><body>${html}</body></html>`;
}
export function blockPath(store: Store, file: string) {
  if (!/^[a-f0-9]{64}\.(html|png)$/.test(file)) throw new Error("Invalid block file");
  return path.join(store.dataDir, "blocks", file);
}
function writeAsset(store: Store, bytes: Buffer, ext: "html" | "png") {
  const file = `${crypto.createHash("sha256").update(bytes).digest("hex")}.${ext}`;
  fs.mkdirSync(path.join(store.dataDir, "blocks"), { recursive: true });
  if (!fs.existsSync(blockPath(store, file))) fs.writeFileSync(blockPath(store, file), bytes);
  return file;
}
function findBlock(store: Store, page: string, id: string) {
  const item = store.findPage(page)?.page.claudeLayer.find(i => i.id === id);
  if (!item || item.type !== "web") throw new Error("Web block not found");
  return item;
}
const dimension = z.number().finite().positive().max(10000);
const geometry = { x: z.number().finite(), y: z.number().finite(), w: dimension, h: dimension };
const title = z.string().min(1).max(200);
export const addBlockSchema = z.object({ page_id: z.string().optional(), ...geometry, title, html: z.string().describe('Full HTML or fragment, at most 1 MB. Example: <button onclick="this.textContent=\'Clicked\'">Try it</button>'), autoplay: z.boolean().optional(), group: z.string().optional() });
export const updateBlockSchema = z.object({ page_id: z.string().optional(), id: z.string(), html: z.string().optional(), title: title.optional(), x: geometry.x.optional(), y: geometry.y.optional(), w: dimension.optional(), h: dimension.optional() });
export function addBlock(store: Store, pageId: string, raw: unknown) {
  const { page_id: _, html, ...fields } = addBlockSchema.parse(raw);
  if (!store.findPage(pageId)) throw new Error("Page not found");
  const file = writeAsset(store, Buffer.from(wrapBlock(html)), "html");
  const item: Item = { type: "web", ...fields, autoplay: fields.autoplay ?? true, file, rev: 1, id: nanoid(8), createdAt: new Date().toISOString() };
  store.addClaudeItems(pageId, [item]);
  return item;
}
export function updateBlock(store: Store, pageId: string, raw: unknown) {
  const { page_id: _, id, html, ...fields } = updateBlockSchema.parse(raw);
  const old = findBlock(store, pageId, id);
  const file = html === undefined ? old.file : writeAsset(store, Buffer.from(wrapBlock(html)), "html");
  const item: Item = { ...old, ...fields, file, rev: old.rev + 1, poster: undefined, posterAt: undefined, logs: [] };
  store.replaceClaudeItem(pageId, item);
  return item;
}
export function logBlock(store: Store, pageId: string, id: string, rev: number, lines: string[]) {
  const item = findBlock(store, pageId, id);
  if (rev !== item.rev) throw new Error("Stale block revision; reload the block");
  store.replaceClaudeItem(pageId, { ...item, logs: [...(item.logs ?? []), ...lines.map(l => l.slice(0, 1000))].slice(-20) });
}
export async function posterBlock(store: Store, pageId: string, id: string, rev: number, bytes: Buffer) {
  findBlock(store, pageId, id);
  if (bytes.length > 2 * 1024 * 1024) throw new Error("Poster PNG must be at most 2 MB");
  const image = sharp(bytes, { limitInputPixels: 16 * 1024 * 1024 });
  if ((await image.metadata()).format !== "png") throw new Error("Poster must be PNG");
  const png = await image.resize({ width: 2048, height: 2048, fit: "inside", withoutEnlargement: true }).png().toBuffer();
  // Decode is async: verify the revision again before saving to avoid a stale poster replacing a fix.
  const item = findBlock(store, pageId, id);
  if (rev !== item.rev) throw new Error("Stale block revision; reload the block");
  const file = writeAsset(store, png, "png");
  store.replaceClaudeItem(pageId, { ...item, poster: file, posterAt: new Date().toISOString() });
}
export function describeBlock(item: Item) {
  if (item.type !== "web") return "";
  const age = item.posterAt ? `${Math.max(0, Math.round((Date.now()-Date.parse(item.posterAt))/1000))}s ago` : "none (open on iPad)";
  return `web ${item.id} ${JSON.stringify(item.title)} (${item.x},${item.y} ${item.w}x${item.h}) rev ${item.rev}; poster ${age}${item.logs?.length ? ": " + item.logs.join(" | ") : "; no reported errors"}`;
}
export function registerWebTools(server: McpServer, store: Store) {
  const result = (item: Item) => ({ content: [{ type: "text" as const, text: JSON.stringify({ id: item.id, bbox: itemBBox(item), rev: item.type === "web" ? item.rev : undefined, warning: offPageWarning(itemBBox(item)), message: "Open on the iPad to run; call view_page to check the poster and latest errors." }) }] });
  const failure = (error: unknown) => ({ isError: true, content: [{ type: "text" as const, text: String(error) }] });
  const pageId = (id?: string) => { const p = id ?? store.view().pageId; if (!p) throw new Error("Open a notebook page first, or provide page_id"); return p; };
  server.registerTool("add_web_block", { title: "Add interactive HTML", description: 'Run self-contained HTML/JS on an iPad page. Put the block in empty space and check view_page after it runs. Example: {x:100,y:200,w:800,h:500,title:"Projectile",html:"<input type=range oninput=console.warn(this.value)><canvas></canvas>"}. Inline canvas/SVG animations and sliders work. Libraries may load only from HTTPS cdnjs.cloudflare.com, cdn.jsdelivr.net, unpkg.com, e.g. <script src="https://cdn.jsdelivr.net/npm/p5@1.9.4/lib/p5.min.js"></script>. No other network or navigation. autoplay defaults true. Use update_web_block to fix errors listed by get_current_page.', inputSchema: addBlockSchema.shape }, async args => { try { return result(addBlock(store, pageId(args.page_id), args)); } catch(e) { return failure(e); } });
  server.registerTool("update_web_block", { title: "Update interactive HTML", description: 'Fix HTML, change title or resize an existing block without changing its id. Each update starts a new revision and clears stale poster/errors. Example: {id:"b7",html:"<button>Fixed</button>",w:700}. Check view_page after the iPad runs it.', inputSchema: updateBlockSchema.shape }, async args => { try { return result(updateBlock(store, pageId(args.page_id), args)); } catch(e) { return failure(e); } });
}
export function webBlockRoutes(api: Router, store: Store) {
  api.get("/blocks/:file", (req, res) => {
    try {
      const file = blockPath(store, req.params.file);
      if (!fs.existsSync(file)) return res.status(404).end();
      res.set("Cache-Control", "no-store").set("X-Content-Type-Options", "nosniff");
      if (file.endsWith(".html")) res.set("Content-Security-Policy", `${BLOCK_CSP}; sandbox allow-scripts`).type("html"); else res.type("png");
      res.sendFile(file);
    } catch { res.status(404).end(); }
  });
  api.post("/pages/:id/blocks/:itemId/log", (req, res) => {
    try { const body = z.object({ rev: z.number().int().positive(), lines: z.array(z.string().max(1000)).max(20) }).parse(req.body); logBlock(store, req.params.id, req.params.itemId, body.rev, body.lines); res.json({ ok: true }); }
    catch(e) { res.status(400).json({ error: String(e) }); }
  });
  // JSON base64 avoids an extra raw-body parser and uses the same upload convention as ink snapshots.
  api.put("/pages/:id/blocks/:itemId/poster", async (req, res) => {
    try { const body = z.object({ rev: z.number().int().positive(), png: z.string().max(2800000) }).parse(req.body); await posterBlock(store, req.params.id, req.params.itemId, body.rev, Buffer.from(body.png, "base64")); res.json({ ok: true }); }
    catch(e) { res.status(400).json({ error: String(e) }); }
  });
}
