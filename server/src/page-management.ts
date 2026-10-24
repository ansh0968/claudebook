// Page structure operations are shared by the app and assistant connectors.
import type { Router } from "express";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { Store, Notebook } from "./store.js";

const ids = z.array(z.string().min(1)).min(1).max(5000).describe("Page ids in the desired order; use list_pages to get them");
const position = z.number().int().min(0).optional();
const text = (value: unknown, isError = false) => ({ content: [{ type: "text" as const, text: typeof value === "string" ? value : JSON.stringify(value) }], ...(isError ? { isError: true } : {}) });
const error = (e: unknown) => text((e as Error).message, true);
const publicNotebook = (store: Store, nb: Notebook) => nb.scratch ? { ...nb, expiresAt: store.scratchExpiry(nb) } : nb;

export function registerPageRoutes(api: Router, store: Store) {
  api.post("/notebooks/:id/pages/delete", (req, res) => {
    try {
      const body = z.object({ pageIds: ids }).strict().parse(req.body);
      res.json(publicNotebook(store, store.deletePages(req.params.id, body.pageIds)));
    } catch (e) { res.status(400).json({ error: (e as Error).message }); }
  });
  api.post("/notebooks/:id/pages/reorder", (req, res) => {
    try {
      const body = z.object({ pageIds: z.array(z.string().min(1)).max(5000) }).strict().parse(req.body);
      res.json(publicNotebook(store, store.reorderPages(req.params.id, body.pageIds)));
    } catch (e) { res.status(400).json({ error: (e as Error).message }); }
  });
  api.post("/pages/duplicate", (req, res) => {
    try {
      const body = z.object({ pageIds: ids, targetNotebookId: z.string().optional(), afterPage: position }).strict().parse(req.body);
      const result = store.duplicatePages(body.pageIds, body.targetNotebookId, body.afterPage);
      res.json({ ...result, notebook: publicNotebook(store, result.notebook) });
    } catch (e) { res.status(400).json({ error: (e as Error).message }); }
  });
  api.post("/pages/move", (req, res) => {
    try {
      const body = z.object({ pageIds: ids, targetNotebookId: z.string().min(1), afterPage: position }).strict().parse(req.body);
      const result = store.movePages(body.pageIds, body.targetNotebookId, body.afterPage);
      res.json({ ...result, notebook: publicNotebook(store, result.notebook) });
    } catch (e) { res.status(400).json({ error: (e as Error).message }); }
  });

}

export function registerPageTools(server: McpServer, store: Store) {
  server.registerTool("list_pages", {
    title: "List notebook pages",
    description: "List every page's id, 1-based number, background, PDF reference and ink/drawing state. Use ids for deleting, reordering, duplicating and moving pages. Defaults to the open notebook.",
    inputSchema: { notebook_id: z.string().optional() }, annotations: { readOnlyHint: true },
  }, async ({ notebook_id }) => {
    const nb = store.getNotebook(notebook_id ?? store.view().notebookId ?? "");
    if (!nb) return text("Notebook not found.", true);
    return text({ notebook_id: nb.id, title: nb.title, pages: nb.pages.map((p, i) => ({ id: p.id, page_number: i + 1, background: p.background, ...(p.pdf ? { pdf: p.pdf } : {}), items: p.claudeLayer.length, snapshot_version: p.snapshotVersion, ...(p.strokeCount !== undefined ? { stroke_count: p.strokeCount } : {}), updated_at: p.updatedAt })), view: store.view() });
  });
  server.registerTool("delete_pages", {
    title: "Delete notebook pages",
    description: "Delete the selected pages, including user ink, PDF page references and assistant drawings. This acts immediately when requested; use only for pages the user wants removed. All ids must belong to one notebook; invalid ids delete nothing. A notebook may become empty. Example: {page_ids:[\"page-id\"]}.",
    inputSchema: { page_ids: ids, notebook_id: z.string().optional() }, annotations: { destructiveHint: true },
  }, async ({ page_ids, notebook_id }) => {
    try {
      const nbId = notebook_id ?? store.findPage(page_ids[0])?.notebook.id;
      if (!nbId) throw new Error("Page not found.");
      const nb = store.deletePages(nbId, page_ids);
      return text({ deleted_page_ids: page_ids, notebook_id: nb.id, remaining_page_ids: nb.pages.map(p => p.id), view: store.view() });
    } catch (e) { return error(e); }
  });
  server.registerTool("reorder_pages", {
    title: "Rearrange notebook pages",
    description: "Put all pages of a notebook in the supplied order. page_ids must be an exact permutation of its existing page ids; missing, duplicate or unknown ids change nothing. Ink and PDF identity stay with each page. Example: {notebook_id:\"book-id\",page_ids:[\"second-id\",\"first-id\"]}.",
    inputSchema: { notebook_id: z.string(), page_ids: z.array(z.string()).max(5000) },
  }, async ({ notebook_id, page_ids }) => {
    try { const nb = store.reorderPages(notebook_id, page_ids); return text({ notebook_id: nb.id, page_ids: nb.pages.map(p => p.id), view: store.view() }); }
    catch (e) { return error(e); }
  });
  server.registerTool("duplicate_pages", {
    title: "Duplicate notebook pages",
    description: "Copy selected pages with independent new page/item ids, user ink, recognized text, PDF references, drawings and doubts. Defaults to the first source notebook's end. Optional target_notebook_id copies into another notebook; after_page is the insertion count (0=front, default=end). Example: {page_ids:[\"page-id\"],after_page:1}.",
    inputSchema: { page_ids: ids, target_notebook_id: z.string().optional(), after_page: position },
  }, async ({ page_ids, target_notebook_id, after_page }) => {
    try { const r = store.duplicatePages(page_ids, target_notebook_id, after_page); return text({ notebook_id: r.notebook.id, pages: r.pages.map(p => ({ id: p.id, page_number: r.notebook.pages.findIndex(x => x.id === p.id) + 1 })), view: store.view() }); }
    catch (e) { return error(e); }
  });
  server.registerTool("move_pages", {
    title: "Move pages between notebooks",
    description: "Move existing pages in the listed order, preserving page ids and all ink/PDF/drawing data. after_page is an insertion count in the target after removing any selected target pages (0=front, default=end). Sources may become empty. Invalid requests move nothing. Example: {page_ids:[\"page-id\"],target_notebook_id:\"other-book\",after_page:0}.",
    inputSchema: { page_ids: ids, target_notebook_id: z.string(), after_page: position },
  }, async ({ page_ids, target_notebook_id, after_page }) => {
    try { const r = store.movePages(page_ids, target_notebook_id, after_page); return text({ notebook_id: r.notebook.id, page_ids: r.pages.map(p => p.id), view: store.view() }); }
    catch (e) { return error(e); }
  });
}
