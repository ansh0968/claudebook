// The tools Claude sees once ClaudeBook is added as a connector in the Claude app.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { nanoid } from "nanoid";
import { z } from "zod";
import { ItemSchema, type Item } from "./items.js";
import { renderPage } from "./render.js";
import { PAGE_H, PAGE_W, type Page, type Store } from "./store.js";

const INSTRUCTIONS = `ClaudeBook is the user's handwritten notebook app on iPad. You can see their pages and draw on them.
Pages use a fixed coordinate space: x 0..${PAGE_W} left to right, y 0..${PAGE_H} top to bottom.
Workflow: call get_current_page first (it shows what the user has open, with a labelled blue coordinate grid and the positions of recognized handwriting).
Use those coordinates to aim. Prefer simple shapes: an ellipse with padding around a mistake, an arrow pointing at it, short text next to it.
Your drawings live on a separate layer the user can hide or undo, so don't be shy, but keep the page readable and never cover the user's writing with text.
After drawing, call view_page to check the result and fix anything that landed in the wrong place.`;

type ToolResult = { content: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[]; isError?: boolean };

const text = (t: string): ToolResult => ({ content: [{ type: "text", text: t }] });
const fail = (t: string): ToolResult => ({ content: [{ type: "text", text: t }], isError: true });

export function buildMcpServer(store: Store) {
  const server = new McpServer({ name: "claudebook", version: "0.1.0" }, { instructions: INSTRUCTIONS });

  /** Resolve a page from optional ids, falling back to whatever the user has open. */
  function resolvePage(pageId?: string, notebookId?: string, pageNumber?: number) {
    if (pageId) return store.findPage(pageId);
    const nbId = notebookId ?? store.view().notebookId;
    const nb = nbId ? store.getNotebook(nbId) : undefined;
    if (!nb) return;
    if (pageNumber !== undefined) {
      const page = nb.pages[pageNumber - 1];
      return page && { notebook: nb, page, index: pageNumber - 1 };
    }
    return store.view().pageId ? store.findPage(store.view().pageId!) : { notebook: nb, page: nb.pages[0], index: 0 };
  }

  function describe(found: { notebook: { title: string; id: string; pages: Page[] }; page: Page; index: number }) {
    const { notebook, page, index } = found;
    const lines = [
      `Notebook "${notebook.title}" (id ${notebook.id}), page ${index + 1} of ${notebook.pages.length} (page id ${page.id}).`,
      `Background: ${page.background}${page.pdf ? `, PDF page ${page.pdf.page}` : ""}. Your layer has ${page.claudeLayer.length} item(s).`,
    ];
    if (page.snapshotVersion === 0) lines.push("The app hasn't uploaded any ink for this page yet, so it looks empty.");
    if (page.textBoxes.length) {
      lines.push("Recognized handwriting (x, y, w, h):");
      for (const b of page.textBoxes) lines.push(`- [${Math.round(b.x)}, ${Math.round(b.y)}, ${Math.round(b.w)}, ${Math.round(b.h)}] ${b.text}`);
    }
    return lines.join("\n");
  }

  async function pageWithImage(found: NonNullable<ReturnType<typeof resolvePage>>, grid: boolean): Promise<ToolResult> {
    const png = await renderPage(store, found.page, { grid });
    return { content: [{ type: "text", text: describe(found) }, { type: "image", data: png.toString("base64"), mimeType: "image/png" }] };
  }

  server.registerTool(
    "get_current_page",
    {
      title: "Look at the open page",
      description: "See the notebook page the user currently has open on their iPad, as an image plus recognized handwriting. Start here.",
      inputSchema: { grid: z.boolean().optional().describe("Overlay a labelled coordinate grid, default true") },
      annotations: { readOnlyHint: true },
    },
    async ({ grid }) => {
      const found = resolvePage();
      if (!found) return fail("The user has no notebook open.");
      return pageWithImage(found, grid ?? true);
    },
  );

  server.registerTool(
    "view_page",
    {
      title: "Look at a page",
      description: "See any page by page id, or by notebook id + 1-based page number. Defaults to the open notebook.",
      inputSchema: {
        page_id: z.string().optional(),
        notebook_id: z.string().optional(),
        page_number: z.number().int().min(1).optional(),
        grid: z.boolean().optional().describe("Overlay a labelled coordinate grid, default true"),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ page_id, notebook_id, page_number, grid }) => {
      const found = resolvePage(page_id, notebook_id, page_number);
      if (!found) return fail("Page not found.");
      return pageWithImage(found, grid ?? true);
    },
  );

  server.registerTool(
    "list_notebooks",
    {
      title: "List notebooks",
      description: "All notebooks with their ids and page counts, and which one is open.",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => {
      const view = store.view();
      const rows = store.listNotebooks().map((n) => `- "${n.title}" id ${n.id}, ${n.pages.length} page(s)${n.id === view.notebookId ? " (open)" : ""}`);
      return text(rows.join("\n") || "No notebooks yet.");
    },
  );

  server.registerTool(
    "draw_on_page",
    {
      title: "Draw on a page",
      description: `Add ink to a page on your own layer: circles, arrows, lines, freehand paths, highlights, handwritten text or SVG paths. Coordinates are 0..${PAGE_W} x 0..${PAGE_H}. Defaults to the page the user has open.`,
      inputSchema: {
        items: z.array(ItemSchema).min(1),
        page_id: z.string().optional(),
        notebook_id: z.string().optional(),
        page_number: z.number().int().min(1).optional(),
      },
    },
    async ({ items, page_id, notebook_id, page_number }) => {
      const found = resolvePage(page_id, notebook_id, page_number);
      if (!found) return fail("Page not found.");
      const stamped: Item[] = items.map((i) => ({ ...i, id: nanoid(8), createdAt: new Date().toISOString() }));
      store.addClaudeItems(found.page.id, stamped);
      return text(`Drew ${items.length} item(s) on page ${found.index + 1} of "${found.notebook.title}". Call view_page to check placement.`);
    },
  );

  server.registerTool(
    "erase_my_drawings",
    {
      title: "Erase Claude's drawings",
      description: "Remove your most recent items from a page (count), or everything you drew there when count is omitted. Never touches the user's ink.",
      inputSchema: {
        count: z.number().int().min(1).optional(),
        page_id: z.string().optional(),
        notebook_id: z.string().optional(),
        page_number: z.number().int().min(1).optional(),
      },
      annotations: { destructiveHint: true },
    },
    async ({ count, page_id, notebook_id, page_number }) => {
      const found = resolvePage(page_id, notebook_id, page_number);
      if (!found) return fail("Page not found.");
      const n = store.removeClaudeItems(found.page.id, count);
      return text(`Removed ${n} item(s).`);
    },
  );

  const background = z.enum(["blank", "lined", "grid", "dotted"]).optional();

  server.registerTool(
    "create_notebook",
    {
      title: "Create a notebook",
      description: "Make a new notebook for the user.",
      inputSchema: { title: z.string(), pages: z.number().int().min(1).max(200).optional(), background },
    },
    async ({ title, pages, background }) => {
      const nb = store.createNotebook(title, pages ?? 1, background ?? "blank");
      return text(`Created "${nb.title}" (id ${nb.id}) with ${nb.pages.length} page(s).`);
    },
  );

  server.registerTool(
    "add_pages",
    {
      title: "Add pages",
      description: "Insert blank pages into a notebook (defaults to the open one), after a 1-based page number or at the end.",
      inputSchema: {
        notebook_id: z.string().optional(),
        count: z.number().int().min(1).max(100).optional(),
        after_page: z.number().int().min(0).optional().describe("0 inserts at the start"),
        background,
      },
    },
    async ({ notebook_id, count, after_page, background }) => {
      const nbId = notebook_id ?? store.view().notebookId;
      if (!nbId || !store.getNotebook(nbId)) return fail("Notebook not found.");
      const pages = Array.from({ length: count ?? 1 }, () => store.newPage(background ?? "blank"));
      const at = store.insertPages(nbId, pages, after_page === undefined ? undefined : after_page - 1);
      return text(`Added ${pages.length} page(s) starting at page ${at + 1}. Page ids: ${pages.map((p) => p.id).join(", ")}`);
    },
  );

  return server;
}
