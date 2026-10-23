// The tools Claude sees once ClaudeBook is added as a connector in the Claude app.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { ItemSchema, prepareItems } from "./items.js";
import { compileTypst, downloadPdf, savePdf } from "./pdf.js";
import { renderPage } from "./render.js";
import { PAGE_H, PAGE_W, type Page, type Store } from "./store.js";

const INSTRUCTIONS = `ClaudeBook is the user's handwritten notebook app on iPad. You can see their pages and draw on them.
Pages use a fixed coordinate space: x 0..${PAGE_W} left to right, y 0..${PAGE_H} top to bottom.
Workflow: call get_current_page first (it shows what the user has open, with a labelled blue coordinate grid and the positions of recognized handwriting).
Use those coordinates to aim. Prefer simple shapes: an ellipse with padding around a mistake, an arrow pointing at it, short text next to it.
Write equations and corrected working with "math" items (LaTeX), one line per item; use "text" items for words.
Your drawings live on a separate layer the user can hide or undo, so don't be shy, but keep the page readable and never cover the user's writing with text.
After drawing, call view_page to check the result and fix anything that landed in the wrong place.
To give the user something to write on (worksheets, notes, practice questions), use create_pdf; to bring in an existing PDF from the web, use import_pdf_from_url.`;

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
    if (page.snapshotVersion === 0) {
      lines.push(page.pdf ? "The user hasn't written on this page yet, so you only see the PDF." : "The app hasn't uploaded any ink for this page yet, so it looks empty.");
    }
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
      description: `Add ink to a page on your own layer: circles, arrows, lines, freehand paths, highlights, handwritten text, typeset math (LaTeX, the way to write equations and corrections) or SVG paths. Coordinates are 0..${PAGE_W} x 0..${PAGE_H}. Defaults to the page the user has open.`,
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
      let stamped;
      try {
        stamped = prepareItems(items);
      } catch (e) {
        return fail(`${(e as Error).message}. Nothing was drawn.`);
      }
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

  /** Store a PDF and turn it into notebook pages; shared by the two PDF tools. */
  async function addPdf(bytes: Buffer, title: string, notebookId?: string): Promise<ToolResult> {
    if (notebookId && !store.getNotebook(notebookId)) return fail("Notebook not found.");
    const { file, pages } = await savePdf(store, bytes);
    const { notebook, firstIndex } = store.addPdfPages(file, pages, title, notebookId);
    const range = pages === 1 ? `page ${firstIndex + 1}` : `pages ${firstIndex + 1}-${firstIndex + pages}`;
    return text(`${notebookId ? "Added" : "Created"} "${notebook.title}" (id ${notebook.id}), ${range} from a ${pages}-page PDF. The user can open it in ClaudeBook and write on it.`);
  }

  server.registerTool(
    "create_pdf",
    {
      title: "Create a PDF to write on",
      description:
        "Typeset a document and drop it into ClaudeBook as notebook pages the user can write on. Use it for worksheets, revision notes and practice questions. " +
        "Write Typst markup, not LaTeX (math is $x^2$ inline or $ x = (-b plus.minus sqrt(b^2 - 4a c)) / (2a) $ on its own line, #pagebreak() for new pages). " +
        "Pages are A4. Leave generous blank space under each question for handwriting, e.g. #v(6cm). Makes a new notebook unless notebook_id is given (then pages are appended).",
      inputSchema: { title: z.string(), typst: z.string().describe("Complete Typst source"), notebook_id: z.string().optional() },
    },
    async ({ title, typst, notebook_id }) => {
      const prefixed = !/#set page\(/.test(typst);
      let pdf: Buffer;
      try {
        pdf = await compileTypst(prefixed ? `#set page(paper: "a4")\n${typst}` : typst);
      } catch (e) {
        // Shift line numbers back so they match the source Claude wrote.
        const msg = (e as Error).message.replace(/main\.typ:(\d+)/g, (_, n) => `main.typ:${prefixed ? Number(n) - 1 : n}`);
        return fail(`Typst error:\n${msg}`);
      }
      return addPdf(pdf, title, notebook_id);
    },
  );

  server.registerTool(
    "import_pdf_from_url",
    {
      title: "Import a PDF from the web",
      description: "Download a PDF (https, up to 50MB) into ClaudeBook as pages the user can annotate. Makes a new notebook unless notebook_id is given.",
      inputSchema: { url: z.string().url(), title: z.string().optional(), notebook_id: z.string().optional() },
    },
    async ({ url, title, notebook_id }) => {
      try {
        const bytes = await downloadPdf(url);
        const name = title || decodeURIComponent(new URL(url).pathname.split("/").pop() || "Imported PDF").replace(/\.pdf$/i, "");
        return await addPdf(bytes, name, notebook_id);
      } catch (e) {
        return fail(`Couldn't import that PDF: ${(e as Error).message}`);
      }
    },
  );

  return server;
}
