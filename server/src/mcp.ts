// The tools Claude sees once ClaudeBook is added as a connector in the Claude app.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { ItemSchema, itemBBox, itemLabel, prepareItems, type Item } from "./items.js";
import { compileTypst, downloadPdf, savePdf } from "./pdf.js";
import { clampRegion, renderPage, type Region } from "./render.js";
import { PAGE_H, PAGE_W, type Page, type Store } from "./store.js";

const INSTRUCTIONS = `ClaudeBook is the user's handwritten notebook app on iPad. You can see their pages and draw on them.
Pages use a fixed coordinate space: x 0..${PAGE_W} left to right, y 0..${PAGE_H} top to bottom.
Workflow: call get_current_page first (it shows what the user has open, with a labelled blue coordinate grid and the positions of recognized handwriting).
When checking work or reading small handwriting, zoom into each region (the zoom parameter) before judging it; the full-page image is too small to read every symbol.
When the user says to check their doubts, inspect the open doubts listed on the page, zoom into each marked region, explain it, and resolve_doubt only after addressing it.
Use those coordinates to aim. Prefer simple shapes: an ellipse with padding around a mistake, an arrow pointing at it, short text next to it.
Write equations and corrected working with "math" items (LaTeX), one line per item; use "text" items for words.
Text supports Unicode symbols with font fallbacks, Unicode sub/superscripts and inline scripts such as H_2O, OH^- and x^{2}. If a text character is unsupported the draw fails clearly; use math for that symbol.
For chemistry use mhchem inside math items: \\ce{H2O}, \\ce{OH-}, \\ce{SO4^2-}, \\ce{^{14}_{6}C}, \\ce{A + B -> C}, \\ce{A <=> B}.
Your drawings live on a separate layer the user can hide or undo, so don't be shy, but keep the page readable and never cover the user's writing with text.
After drawing, call view_page to check the result and fix anything that landed in the wrong place.
Draw results and page descriptions list item ids, labels and bounding boxes. Use erase_my_drawings with ids or group to remove selected items, and move_items with ids, dx, dy to reposition them. Name related drawings with an item group.
Use curved_arrow for reaction mechanisms (signed bend, half_head for a fishhook), path smooth:false for straight segments, and molecule with SMILES for chemical structures. Hints are hidden until the user taps their chip.
To give the user something to write on (worksheets, notes, practice questions), use create_pdf; to bring in an existing PDF from the web, use import_pdf_from_url.`;

type ToolResult = { content: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[]; isError?: boolean };

const text = (t: string): ToolResult => ({ content: [{ type: "text", text: t }] });
const fail = (t: string): ToolResult => ({ content: [{ type: "text", text: t }], isError: true });
const describeItem = (item: Item) => ({ id: item.id, type: item.type, label: itemLabel(item), bbox: itemBBox(item), ...(item.group !== undefined ? { group: item.group } : {}) });

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

  function describe(found: { notebook: { title: string; id: string; pages: Page[] }; page: Page; index: number }, region?: Region) {
    const { notebook, page, index } = found;
    const lines = [
      `Notebook "${notebook.title}" (id ${notebook.id}), page ${index + 1} of ${notebook.pages.length} (page id ${page.id}).`,
      `Background: ${page.background}${page.pdf ? `, PDF page ${page.pdf.page}` : ""}. Your layer has ${page.claudeLayer.length} item(s).`,
    ];
    const doubts = page.doubts.filter((d) => !d.resolvedAt);
    if (doubts.length) {
      lines.push("Open doubts: zoom into each marked region with view_page before explaining or resolving it (x, y, w, h):");
      for (const d of doubts) lines.push(`- ${d.id}: [${d.region.x}, ${d.region.y}, ${d.region.w}, ${d.region.h}]`);
    }
    if (page.snapshotVersion === 0) {
      lines.push(page.pdf ? "The user hasn't written on this page yet, so you only see the PDF." : "The app hasn't uploaded any ink for this page yet, so it looks empty.");
    }
    // When zoomed, only list handwriting that overlaps the zoomed area.
    const boxes = region
      ? page.textBoxes.filter((b) => b.x < region.x + region.w && b.x + b.w > region.x && b.y < region.y + region.h && b.y + b.h > region.y)
      : page.textBoxes;
    if (boxes.length) {
      lines.push("Recognized handwriting (x, y, w, h):");
      for (const b of boxes) lines.push(`- [${Math.round(b.x)}, ${Math.round(b.y)}, ${Math.round(b.w)}, ${Math.round(b.h)}] ${b.text}`);
    }
    if (page.claudeLayer.length) {
      lines.push("Your existing items (bbox is {x,y,w,h} in page units):");
      for (const item of page.claudeLayer) lines.push(JSON.stringify(describeItem(item)));
    }
    return lines.join("\n");
  }

  async function pageWithImage(found: NonNullable<ReturnType<typeof resolvePage>>, grid: boolean, zoom?: Region): Promise<ToolResult> {
    const region = zoom && clampRegion(zoom);
    const png = await renderPage(store, found.page, { grid, region });
    let text = describe(found, region);
    if (region) text += `\nZoomed into x ${region.x}..${region.x + region.w}, y ${region.y}..${region.y + region.h}; grid labels are still page coordinates.`;
    return { content: [{ type: "text", text }, { type: "image", data: png.toString("base64"), mimeType: "image/png" }] };
  }

  const zoom = z
    .object({ x: z.number(), y: z.number(), w: z.number(), h: z.number() })
    .optional()
    .describe("Zoom into this rectangle (page coordinates) at high resolution. Use it to read small or messy handwriting, check working line by line, or aim marks precisely. e.g. {x:0,y:300,w:500,h:300}");

  server.registerTool(
    "get_current_page",
    {
      title: "Look at the open page",
      description: "See the notebook page the user currently has open on their iPad, as an image plus recognized handwriting. Start here.",
      inputSchema: { grid: z.boolean().optional().describe("Overlay a labelled coordinate grid, default true"), zoom },
      annotations: { readOnlyHint: true },
    },
    async ({ grid, zoom }) => {
      const found = resolvePage();
      if (!found) return fail("The user has no notebook open.");
      return pageWithImage(found, grid ?? true, zoom);
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
        zoom,
      },
      annotations: { readOnlyHint: true },
    },
    async ({ page_id, notebook_id, page_number, grid, zoom }) => {
      const found = resolvePage(page_id, notebook_id, page_number);
      if (!found) return fail("Page not found.");
      return pageWithImage(found, grid ?? true, zoom);
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
      description: `Add ink to a page on your own layer: circles, straight or curved arrows, lines, paths, highlights, text, LaTeX math, SMILES molecules, hidden hints or SVG paths. Returns item ids and bounding boxes. Coordinates are 0..${PAGE_W} x 0..${PAGE_H}. Defaults to the open page.`,
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
      return text(JSON.stringify({ message: `Drew ${items.length} item(s) on page ${found.index + 1} of "${found.notebook.title}". Call view_page to check placement.`, page_id: found.page.id, items: stamped.map(describeItem) }));
    },
  );

  server.registerTool(
    "erase_my_drawings",
    {
      title: "Erase Claude's drawings",
      description: "Remove selected items by ids and/or group, the most recent items by count, or all your drawings when no selector is supplied. ids and group match either selector; count cannot be combined with them. Never touches the user's ink.",
      inputSchema: {
        count: z.number().int().min(1).optional(),
        ids: z.array(z.string()).min(1).optional(),
        group: z.string().min(1).optional(),
        page_id: z.string().optional(),
        notebook_id: z.string().optional(),
        page_number: z.number().int().min(1).optional(),
      },
      annotations: { destructiveHint: true },
    },
    async ({ count, ids, group, page_id, notebook_id, page_number }) => {
      if (count !== undefined && (ids !== undefined || group !== undefined)) return fail("Choose count or ids/group, not both. Nothing was erased.");
      const found = resolvePage(page_id, notebook_id, page_number);
      if (!found) return fail("Page not found.");
      const n = ids !== undefined || group !== undefined
        ? store.removeClaudeItemsByIds(found.page.id, ids ?? [], group)
        : store.removeClaudeItems(found.page.id, count);
      return text(`Removed ${n} item(s).`);
    },
  );

  server.registerTool(
    "move_items",
    {
      title: "Move Claude's drawings",
      description: "Translate selected item ids by dx,dy page units. Preserves item ids, groups and appearance. Unknown ids are ignored. Returns moved ids and their new bounding boxes.",
      inputSchema: {
        ids: z.array(z.string()).min(1), dx: z.number(), dy: z.number(),
        page_id: z.string().optional(), notebook_id: z.string().optional(), page_number: z.number().int().min(1).optional(),
      },
    },
    async ({ ids, dx, dy, page_id, notebook_id, page_number }) => {
      const found = resolvePage(page_id, notebook_id, page_number);
      if (!found) return fail("Page not found.");
      try {
        const moved = store.moveClaudeItems(found.page.id, ids, dx, dy);
        return text(JSON.stringify({ message: `Moved ${moved.length} item(s).`, page_id: found.page.id, items: moved.map(describeItem) }));
      } catch (error) {
        return fail(`${(error as Error).message}. Nothing was moved.`);
      }
    },
  );

  const background = z.enum(["blank", "lined", "grid", "dotted"]).optional();

  server.registerTool(
    "resolve_doubt",
    {
      title: "Resolve a marked doubt",
      description: "Mark a doubt as resolved after zooming into its region and explaining it to the user.",
      inputSchema: { id: z.string().min(1) },
    },
    async ({ id }) => {
      const doubt = store.resolveDoubt(id);
      return doubt ? text(`Resolved doubt ${doubt.id} on page ${doubt.pageId}.`) : fail("Doubt not found.");
    },
  );

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
