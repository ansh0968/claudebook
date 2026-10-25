// The tools Claude sees once ClaudeBook is added as a connector in the Claude app.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { LooseItemSchema, itemBBox, itemLabel, moleculeAtomsForDisplay, offPageWarning, prepareBatch, translateItem, type Item, type ItemWarning } from "./items.js";
import { compileTypst, downloadPdf, savePdf } from "./pdf.js";
import { pdfTextPage, describePdfText } from "./pdf-text.js";
import { TYPST_COMPATIBILITY, TYPST_IMPORTS } from "./typst-packages.js";
import { clampRegion, renderPage, type Region } from "./render.js";
import { PAGE_H, PAGE_W, type Notebook, type Page, type Store } from "./store.js";
import { parsePageRegion } from "./regions.js";
import { logMistake } from "./study.js";
import { registerPageTools } from "./page-management.js";

const INSTRUCTIONS = `ClaudeBook is the user's handwritten notebook app on iPad. You can see their pages and draw on them.
Pages use a fixed coordinate space: x 0..${PAGE_W} left to right, y 0..${PAGE_H} top to bottom.
Workflow: call get_current_page first (it shows what the user has open, with a labelled blue coordinate grid and the positions of recognized handwriting).
When checking work or reading small handwriting, zoom into each region (the zoom parameter) before judging it; the full-page image is too small to read every symbol.
When the user says to check their doubts, inspect the open doubts listed on the page, zoom into each marked region, explain it, and resolve_doubt only after addressing it.
Use those coordinates to aim. Prefer simple shapes: an ellipse with padding around a mistake, an arrow pointing at it, short text next to it.
Write equations and corrected working with "math" items (LaTeX), one line per item; use "text" items for words. A single line of math is about 0.55 x size tall. Math x,y positions the true ink top-left (or the chosen anchor), including tall fractions; e.g. {type:"math",latex:"x^2",x:300,y:500,anchor:"center"} centers its ink at (300,500).
Text supports Unicode symbols with font fallbacks, Unicode sub/superscripts and inline scripts such as H_2O, OH^- and x^{2}. If a text character is unsupported the draw fails clearly; use math for that symbol.
For chemistry use mhchem inside math items: \\ce{H2O}, \\ce{OH-}, \\ce{SO4^2-}, \\ce{^{14}_{6}C}, \\ce{A + B -> C}, \\ce{A <=> B}, \\ce{A ->[above][below] B}.
Your drawings live on a separate layer the user can hide or undo, so don't be shy, but keep the page readable and never cover the user's writing with text.
Every draw returns each item's id and bbox, plus per-item warnings (unknown types, invalid fields, bad LaTeX, unknown keys, off-page): read them, they mean an item was skipped or misplaced. Invalid items are skipped individually, including in dry_run; e.g. a valid rect beside {type:"squiggle"} still draws. x,y on text and math is the top-left unless you set anchor. Use dry_run to measure before placing, and offset to shift a whole batch.
After drawing, call view_page to check the result and fix anything that landed in the wrong place.
Page descriptions list item ids, labels and bounding boxes. Use erase_my_drawings with ids or group to remove selected items, move_items with ids, dx, dy to reposition them, and copy_items to duplicate them. Name related drawings with an item group.
Use curved_arrow (alias curly) for reaction mechanisms: {type:"curly",from:[100,200],to:[250,200],bend:-60,head:"half"}. head:"full" draws an electron pair; half_head:true remains supported.
Use molecule with SMILES for structures: {type:"molecule",smiles:"CC(=O)O",x:100,y:200,size:180,show_carbons:true,explicit_h:true}. Results include atoms (index to [x,y]) and elements maps; use these coordinates as arrow endpoints. Use path smooth:false for straight segments. Hints are hidden until the user taps their chip.
Graphs: define {type:"axes",origin:[300,650],xrange:[-2,5],yrange:[-1,4],unit:60,name:"g1",grid:true}; then reference its name (or an existing axes id) in later items of the same batch: {type:"plot",axes:"g1",fn:"x^2/2",from:-2,to:3,samples:200,dashed:true}, {type:"shade",axes:"g1",fn1:"x^2/2",fn2:"axis",from:0,to:2,opacity:0.25}, {type:"point",axes:"g1",at:[1,2],label:"P(1,2)",label_pos:"ne",filled:true}. Plot transforms are copied so moving or erasing axes leaves plots intact. Parametric example: {type:"plot",axes:"g1",x:"cos(t)",y:"sin(t)",t:[0,"2pi"]}. Expressions support arithmetic, implicit multiplication, pi/e and sin cos tan asin acos atan sinh cosh tanh log(base 10) ln exp sqrt abs floor ceil.
Angles use page coordinates: {type:"angle",vertex:[300,650],from:[400,650],to:[360,570],radius:30,label:"θ"}; right_angle:true forces a square (automatic near 90°). Without axes, point.at also uses page coordinates.
Physics: rect, ellipse, text, math, molecule and svg accept rotation in clockwise screen degrees about the positioned bbox centre; e.g. {type:"rect",x:200,y:400,w:100,h:60,rotation:30}. Text/math anchors apply before rotation: {type:"text",x:500,y:500,text:"block",anchor:"center",rotation:30}. Pattern fills on rect/ellipse/svg: {type:"rect",x:600,y:400,w:200,h:150,fill_pattern:"cross",pattern_spacing:25}; cross uses ⊗ (into page), dot uses ⊙ (out), hatch uses parallel lines with pattern_angle (default 45; e.g. pattern_angle:30). Patterns clip to the shape and work with normal fill and rotation; fill without color keeps the shape outline hidden.
Draw springs: {type:"spring",from:[100,400],to:[400,400],coils:6,amplitude:15}. Draw floors/walls/inclines: {type:"ground",from:[100,600],to:[650,350],side:"below",hatch_length:14,spacing:12}; side can also be above/left/right.
To give the user something to write on (worksheets, notes, practice questions), use create_pdf; to bring in an existing PDF from the web, use import_pdf_from_url.
PDF-backed pages include their own text with page-coordinate line boxes, filtered when zoomed. This is separate from recognized handwriting; scanned pages may have no text layer.
create_pdf ships these exact Typst imports offline (Typst 0.13.1):
${TYPST_IMPORTS}
${TYPST_COMPATIBILITY}
Notebook/page management: use list_pages to get stable page ids, delete_pages to remove requested pages (including user ink), reorder_pages with a complete ordered id list, duplicate_pages for independent copies, and move_pages to move existing page ids to another notebook. after_page counts target pages before insertion (0=front, default=end), after removal for moves. For a notebook the user explicitly wants deleted, use delete_notebook with direct:true; otherwise omit direct to request iPad confirmation. Empty notebooks can be refilled with add_pages.
Example drawing: #canvas({ draw.line((0,0),(2,1)); draw.circle((1,1),radius:0.4) }). Chemistry: #ch("H2O").
The library is organised in folders (list_notebooks shows them). Put new notebooks and PDFs in the folder that fits with the folder parameter, and file notebooks with move_notebook. Scratch pads are temporary and delete themselves a week after their last edit unless the user keeps them.`;

type ToolResult = { content: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[]; isError?: boolean };

const text = (t: string): ToolResult => ({ content: [{ type: "text", text: t }] });
const fail = (t: string): ToolResult => ({ content: [{ type: "text", text: t }], isError: true });
function ago(iso: string) {
  const s = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 1000));
  return s < 90 ? `${s}s ago` : s < 5400 ? `${Math.round(s / 60)} min ago` : s < 172800 ? `${Math.round(s / 3600)} h ago` : `${Math.round(s / 86400)} days ago`;
}
const describeItem = (item: Item) => ({ id: item.id, type: item.type, label: itemLabel(item), bbox: itemBBox(item), ...(item.group !== undefined ? { group: item.group } : {}), ...(item.atoms ? { atoms: moleculeAtomsForDisplay(item), elements: item.elements } : {}) });

export function buildMcpServer(store: Store) {
  const server = new McpServer({ name: "claudebook", version: "0.1.0" }, { instructions: INSTRUCTIONS });
  registerPageTools(server, store);

  /** Resolve a page from optional ids, falling back to whatever the user has open. */
  function resolvePage(pageId?: string, notebookId?: string, pageNumber?: number) {
    if (pageId) return store.findPage(pageId);
    const nbId = notebookId ?? store.view().notebookId;
    const nb = nbId ? store.getNotebook(nbId) : undefined;
    if (!nb || !nb.pages.length) return;
    if (pageNumber !== undefined) {
      const page = nb.pages[pageNumber - 1];
      return page && { notebook: nb, page, index: pageNumber - 1 };
    }
    return store.view().pageId ? store.findPage(store.view().pageId!) : { notebook: nb, page: nb.pages[0], index: 0 };
  }

  async function describe(found: { notebook: { title: string; id: string; pages: Page[] }; page: Page; index: number }, region?: Region) {
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
    lines.push(syncStatus(page));
    if (page.pdf) {
      try { lines.push(...describePdfText(await pdfTextPage(store, page.pdf.file, page.pdf.page), region)); }
      catch (error) { lines.push(`PDF text unavailable: ${(error as Error).message}`); }
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

  /** What the image can be trusted to show of the user's ink, and how fresh it is. */
  function syncStatus(page: Page) {
    if (page.inkSyncedAt) {
      const strokes = page.strokeCount === undefined ? "" : page.strokeCount === 0 ? " The user has no ink on this page." : ` The page has ${page.strokeCount} stroke(s) of user ink.`;
      return `User ink last synced ${page.inkSyncedAt} (${ago(page.inkSyncedAt)}).${strokes}`;
    }
    const seen = store.view().updatedAt;
    // The app uploads a few seconds after every change, so a page with no upload has almost always never been written on.
    return `No user ink has ever synced for this page: the user hasn't written on it${page.pdf ? " (you see only the PDF)" : ""}, or wrote while offline.`
      + (seen ? ` The iPad last reported which page is open ${ago(seen)}.` : "");
  }

  async function pageWithImage(found: NonNullable<ReturnType<typeof resolvePage>>, grid: boolean, zoom?: Region): Promise<ToolResult> {
    const region = zoom && clampRegion(zoom);
    const png = await renderPage(store, found.page, { grid, region });
    let text = await describe(found, region);
    if (region) text += `\nZoomed into x ${region.x}..${region.x + region.w}, y ${region.y}..${region.y + region.h}; grid labels are still page coordinates.`;
    return { content: [{ type: "text", text }, { type: "image", data: png.toString("base64"), mimeType: "image/png" }] };
  }

  /** A folder by id, or by a "Subject/Topic" name path (case insensitive). Missing names are created when `create` is set. */
  function resolveFolder(ref: string, create: boolean): string | undefined {
    if (store.getFolder(ref)) return ref;
    let parentId: string | undefined;
    for (const name of ref.split("/").map((n) => n.trim()).filter(Boolean)) {
      const match = store.listFolders().find((f) => f.parentId === parentId && f.name.toLocaleLowerCase() === name.toLocaleLowerCase());
      if (match) parentId = match.id;
      else if (create) parentId = store.createFolder(name.slice(0, 100), parentId).id;
      else return;
    }
    return parentId;
  }

  const folderParam = z.string().trim().min(1).optional()
    .describe('Folder id or name path such as "Chemistry" or "Chemistry/Organic". Missing folders are created. Omit for the top level.');

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
      description: "All notebooks grouped by folder, with their ids and page counts, which one is open, and the user's temporary scratch pads.",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => {
      const view = store.view();
      const row = (n: Notebook, indent: string) => `${indent}- "${n.title}" id ${n.id}, ${n.pages.length} page(s)${n.id === view.notebookId ? " (open)" : ""}${n.deleteRequestedAt ? " (waiting for the user to confirm deletion on the iPad)" : ""}`;
      const notebooks = store.listNotebooks();
      const lines: string[] = [];
      const walk = (parentId: string | undefined, depth: number) => {
        const indent = "  ".repeat(depth);
        const folders = store.listFolders().filter((f) => f.parentId === parentId).sort((a, b) => a.name.localeCompare(b.name));
        for (const f of folders) {
          lines.push(`${indent}- Folder "${f.name}" id ${f.id}`);
          walk(f.id, depth + 1);
        }
        for (const n of notebooks) if (!n.scratch && n.folderId === parentId) lines.push(row(n, indent));
      };
      walk(undefined, 0);
      const scratch = notebooks.filter((n) => n.scratch);
      if (scratch.length) {
        lines.push("Scratch pads (temporary):");
        for (const n of scratch) lines.push(`${row(n, "")}, deletes itself after ${store.scratchExpiry(n)} unless kept`);
      }
      return text(lines.join("\n") || "No notebooks yet.");
    },
  );

  /** Each item's summary plus an off-page warning where its box leaves the page. */
  function placed(items: Item[], indexes?: number[]) {
    const warnings: ItemWarning[] = [];
    const summaries = items.map((item, i) => {
      const summary = describeItem(item), off = offPageWarning(summary.bbox);
      if (off) warnings.push({ item: indexes?.[i] ?? i, type: item.type, id: item.id, warning: off });
      return summary;
    });
    return { summaries, warnings };
  }

  const offset = z.array(z.number()).length(2).optional().describe("[dx, dy] added to every item, to place a whole figure at once");

  server.registerTool(
    "draw_on_page",
    {
      title: "Draw on a page",
      description: `Add ink to a page on your own layer: circles, straight or curved arrows, lines, paths, highlights, text, LaTeX math, SMILES molecules, hidden hints or SVG paths. Returns every item's id and bbox, and per-item warnings: an item with bad LaTeX/SMILES/SVG or an unknown key is skipped while the rest draw, and items that leave the page are flagged. Coordinates are 0..${PAGE_W} x 0..${PAGE_H}. Defaults to the open page.`,
      inputSchema: {
        items: z.array(LooseItemSchema).min(1).describe('Drawing items. Unknown types and invalid fields are skipped with indexed warnings; e.g. [{type:"rect",x:100,y:100,w:50,h:40},{type:"squiggle"}] draws the rect'),
        offset,
        dry_run: z.boolean().optional().describe("Measure only: return ids, bboxes and warnings without drawing anything"),
        page_id: z.string().optional(),
        notebook_id: z.string().optional(),
        page_number: z.number().int().min(1).optional(),
      },
    },
    async ({ items, offset, dry_run, page_id, notebook_id, page_number }) => {
      const found = resolvePage(page_id, notebook_id, page_number);
      if (!found) return fail("Page not found.");
      const batch = prepareBatch(items as Record<string, unknown>[], found.page.claudeLayer);
      let stamped = batch.items;
      if (offset && (offset[0] || offset[1])) {
        try {
          stamped = stamped.map((item) => translateItem(item, offset[0], offset[1]));
        } catch (e) {
          return fail(`${(e as Error).message}. Nothing was drawn.`);
        }
      }
      const { summaries, warnings: off } = placed(stamped, batch.indexes);
      const warnings = [...batch.warnings, ...off].sort((a, b) => a.item - b.item);
      const skipped = items.length - stamped.length;
      if (!stamped.length) return { ...text(JSON.stringify({ message: `Nothing was drawn: all ${items.length} item(s) were skipped.`, warnings })), isError: true };
      const where = `page ${found.index + 1} of "${found.notebook.title}"`;
      if (!dry_run) store.addClaudeItems(found.page.id, stamped);
      const message = dry_run
        ? `Dry run: measured ${stamped.length} item(s) for ${where}; nothing was drawn and these ids are not on the page.`
        : `Drew ${stamped.length} item(s) on ${where}${skipped ? `, skipped ${skipped} (see warnings)` : ""}. Call view_page to check placement.`;
      return text(JSON.stringify({ message, page_id: found.page.id, items: summaries, ...(warnings.length ? { warnings } : {}) }));
    },
  );

  server.registerTool(
    "copy_items",
    {
      title: "Copy Claude's drawings",
      description: "Duplicate your items by id, shifted by offset [dx, dy], onto the same page or target_page_id. Copies keep their group and get new ids. Returns the new ids and bboxes.",
      inputSchema: {
        ids: z.array(z.string()).min(1),
        offset: z.array(z.number()).length(2).optional().describe("[dx, dy], default [0, 0]"),
        target_page_id: z.string().optional().describe("Page to put the copies on, default the source page"),
        page_id: z.string().optional(), notebook_id: z.string().optional(), page_number: z.number().int().min(1).optional(),
      },
    },
    async ({ ids, offset, target_page_id, page_id, notebook_id, page_number }) => {
      const found = resolvePage(page_id, notebook_id, page_number);
      if (!found) return fail("Page not found.");
      if (target_page_id && !store.findPage(target_page_id)) return fail("Target page not found.");
      try {
        const copies = store.copyClaudeItems(found.page.id, ids, offset?.[0] ?? 0, offset?.[1] ?? 0, target_page_id ?? found.page.id);
        const { summaries, warnings } = placed(copies);
        const missing = ids.filter((id) => !found.page.claudeLayer.some((item) => item.id === id));
        return text(JSON.stringify({
          message: `Copied ${copies.length} item(s)${missing.length ? `; not found on the source page: ${missing.join(", ")}` : ""}.`,
          page_id: target_page_id ?? found.page.id, items: summaries, ...(warnings.length ? { warnings } : {}),
        }));
      } catch (error) {
        return fail(`${(error as Error).message}. Nothing was copied.`);
      }
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
        const { summaries, warnings } = placed(moved);
        return text(JSON.stringify({ message: `Moved ${moved.length} item(s).`, page_id: found.page.id, items: summaries, ...(warnings.length ? { warnings } : {}) }));
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
    "search_notes",
    {
      title: "Search recognized handwriting",
      description: "Find matching recognized handwriting across all notebooks (case insensitive). Returns notebook and page ids, page numbers and the matching text boxes in page coordinates. Use view_page with zoom to inspect a match.",
      inputSchema: { query: z.string().trim().min(1) },
      annotations: { readOnlyHint: true },
    },
    async ({ query }) => text(JSON.stringify({ results: store.searchNotes(query) })),
  );

  server.registerTool(
    "log_mistake",
    {
      title: "Save a mistake and correction",
      description: "Copy a marked region of the page with its correction into an Error Log notebook as a PDF. The crop includes the user's writing and Claude's marks. Use after explaining the correction.",
      inputSchema: {
        page_id: z.string().optional(),
        region: z.object({ x: z.number().finite(), y: z.number().finite(), w: z.number().finite().positive(), h: z.number().finite().positive() }),
        correction: z.string().trim().min(1).max(20000),
        title: z.string().trim().min(1).max(200).optional(),
      },
    },
    async ({ page_id, region, correction, title }) => {
      const found = resolvePage(page_id);
      if (!found) return fail("Page not found.");
      const crop = parsePageRegion(region);
      if (!crop) return fail(`Region must fit within ${PAGE_W} x ${PAGE_H} page coordinates.`);
      try {
        const result = await logMistake(store, found.page.id, crop, correction, title);
        return text(`Saved to Error Log: ${JSON.stringify(result)}`);
      } catch (e) {
        return fail(`Couldn't save the mistake: ${(e as Error).message}`);
      }
    },
  );

  server.registerTool(
    "create_notebook",
    {
      title: "Create a notebook",
      description: "Make a new notebook for the user, optionally inside a folder.",
      inputSchema: { title: z.string(), pages: z.number().int().min(1).max(200).optional(), background, folder: folderParam },
    },
    async ({ title, pages, background, folder }) => {
      const folderId = folder ? resolveFolder(folder, true) : undefined;
      const nb = store.createNotebook(title, pages ?? 1, background ?? "blank", { folderId });
      const where = folderId ? ` in folder "${store.folderPath(folderId).join("/")}"` : "";
      return text(`Created "${nb.title}" (id ${nb.id}) with ${nb.pages.length} page(s)${where}.`);
    },
  );

  server.registerTool(
    "move_notebook",
    {
      title: "File a notebook in a folder",
      description: 'Move a notebook into a folder (created if missing), or to the top level with folder "". Moving a scratch pad into a folder keeps it for good.',
      inputSchema: {
        notebook_id: z.string(),
        folder: z.string().trim().describe('Folder id or name path such as "Physics/Mechanics"; "" for the top level'),
      },
    },
    async ({ notebook_id, folder }) => {
      const nb = store.getNotebook(notebook_id);
      if (!nb) return fail("Notebook not found.");
      const folderId = folder ? resolveFolder(folder, true) : null;
      store.updateNotebook(nb.id, { folderId, ...(folderId && nb.scratch ? { scratch: false as const } : {}) });
      return text(`Moved "${nb.title}" to ${folderId ? `folder "${store.folderPath(folderId).join("/")}"` : "the top level"}.`);
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

  server.registerTool(
    "rename_notebook",
    {
      title: "Rename a notebook",
      description: "Change a notebook's title.",
      inputSchema: { notebook_id: z.string(), title: z.string().trim().min(1).max(200) },
    },
    async ({ notebook_id, title }) => {
      const before = store.getNotebook(notebook_id)?.title;
      const nb = store.renameNotebook(notebook_id, title);
      return nb ? text(`Renamed "${before}" to "${nb.title}".`) : fail("Notebook not found.");
    },
  );

  server.registerTool(
    "delete_notebook",
    {
      title: "Delete a notebook",
      description: 'Delete a notebook and all its pages/ink. Set direct:true when the user explicitly requested deletion; it works even when the iPad is closed. Omit direct to request iPad confirmation instead. Example: {notebook_id:"book-id",direct:true}.',
      inputSchema: { notebook_id: z.string(), direct: z.boolean().optional().describe("Delete now when the user explicitly requested it; default asks on iPad") },
      annotations: { destructiveHint: true },
    },
    async ({ notebook_id, direct }) => {
      if (direct) {
        const notebook = store.getNotebook(notebook_id);
        if (!notebook) return fail("Notebook not found.");
        const pages = notebook.pages.length;
        store.deleteNotebook(notebook_id);
        return text(JSON.stringify({ deleted_notebook_id: notebook_id, pages_deleted: pages, view: store.view() }));
      }
      const nb = store.requestDelete(notebook_id);
      if (!nb) return fail("Notebook not found.");
      return text(`Asked the user to confirm deleting "${nb.title}" (${nb.pages.length} page(s)) on their iPad. It is only deleted if they tap Delete there; list_notebooks shows it as waiting until then.`);
    },
  );

  server.registerTool(
    "open_page",
    {
      title: "Open a page on the iPad",
      description: "Flip the user's iPad to a notebook page, by page_id or by notebook_id + 1-based page_number (page 1 if neither number nor id). Works while the app is open.",
      inputSchema: { notebook_id: z.string().optional(), page_number: z.number().int().min(1).optional(), page_id: z.string().optional() },
    },
    async ({ notebook_id, page_number, page_id }) => {
      const found = page_id ? store.findPage(page_id) : notebook_id ? resolvePage(undefined, notebook_id, page_number ?? 1) : undefined;
      if (!found) return fail(page_id || notebook_id ? "Page not found." : "Give a page_id, or a notebook_id with an optional page_number.");
      store.openPage(found.notebook.id, found.page.id);
      return text(`Asked the iPad to open page ${found.index + 1} of "${found.notebook.title}" (page id ${found.page.id}). If the app is closed nothing happens; get_current_page shows what is open.`);
    },
  );

  /** Store a PDF and turn it into notebook pages; shared by the two PDF tools. */
  async function addPdf(bytes: Buffer, title: string, notebookId?: string, folder?: string): Promise<ToolResult> {
    if (notebookId && !store.getNotebook(notebookId)) return fail("Notebook not found.");
    const { file, pages } = await savePdf(store, bytes);
    const folderId = !notebookId && folder ? resolveFolder(folder, true) : undefined;
    const { notebook, firstIndex } = store.addPdfPages(file, pages, title, notebookId, folderId);
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
        "Pages are A4. Leave generous blank space under each question for handwriting, e.g. #v(6cm). Makes a new notebook unless notebook_id is given (then pages are appended). " +
        `Offline packages (exact imports):\n${TYPST_IMPORTS}\n${TYPST_COMPATIBILITY}\nExample: #canvas({ draw.line((0,0),(2,1)); draw.circle((1,1),radius:0.4) }). PDF text with coordinates appears in view_page/get_current_page.`,
      inputSchema: { title: z.string(), typst: z.string().describe(`Complete Typst source. Offline package imports:\n${TYPST_IMPORTS}\n${TYPST_COMPATIBILITY}`), notebook_id: z.string().optional(), folder: folderParam },
    },
    async ({ title, typst, notebook_id, folder }) => {
      const prefixed = !/#set page\(/.test(typst);
      let pdf: Buffer;
      try {
        pdf = await compileTypst(prefixed ? `#set page(paper: "a4")\n${typst}` : typst);
      } catch (e) {
        // Shift line numbers back so they match the source Claude wrote.
        const msg = (e as Error).message.replace(/main\.typ:(\d+)/g, (_, n) => `main.typ:${prefixed ? Number(n) - 1 : n}`);
        return fail(`Typst error:\n${msg}`);
      }
      return addPdf(pdf, title, notebook_id, folder);
    },
  );

  server.registerTool(
    "import_pdf_from_url",
    {
      title: "Import a PDF from the web",
      description: "Download a PDF (https, up to 50MB) into ClaudeBook as pages the user can annotate. Makes a new notebook unless notebook_id is given.",
      inputSchema: { url: z.string().url(), title: z.string().optional(), notebook_id: z.string().optional(), folder: folderParam },
    },
    async ({ url, title, notebook_id, folder }) => {
      try {
        const bytes = await downloadPdf(url);
        const name = title || decodeURIComponent(new URL(url).pathname.split("/").pop() || "Imported PDF").replace(/\.pdf$/i, "");
        return await addPdf(bytes, name, notebook_id, folder);
      } catch (e) {
        return fail(`Couldn't import that PDF: ${(e as Error).message}`);
      }
    },
  );

  return server;
}
