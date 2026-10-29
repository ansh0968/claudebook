import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Store } from "./store.js";
import { backgrounds, papers } from "./paper.js";
export const backgroundSchema = z.enum(backgrounds).describe('Paper pattern, e.g. "cornell", "hex", "graph", "lined". Coordinates stay 1000 x 1414.');
export const paperSchema = z.enum(papers).describe('Paper colour, e.g. "black" or "white". Use light ink on black/slate paper.');
export function registerPaperTools(server: McpServer, store: Store) {
  server.registerTool("set_page_background", {
    title: "Set page type and paper",
    description: 'Change the open page, page_ids, or all_pages in notebook_id. Omitted fields are preserved. Example: {background:"cornell",paper:"black"}. Dark paper needs a light pen. PDF artwork still covers its paper.',
    inputSchema: { page_ids: z.array(z.string()).min(1).max(1000).optional(), notebook_id: z.string().optional(), all_pages: z.boolean().optional(), background: backgroundSchema.optional(), paper: paperSchema.optional() },
  }, async ({ page_ids, notebook_id, all_pages, background, paper }) => {
    try {
      if (page_ids && all_pages) throw new Error("Use page_ids or all_pages, not both");
      const notebook = store.getNotebook(notebook_id ?? store.view().notebookId ?? "");
      if (notebook_id && !notebook) throw new Error("Notebook not found");
      const ids = page_ids ?? (all_pages ? notebook?.pages.map(p => p.id) : [store.view().pageId ?? ""]);
      if (!ids?.length || ids.some(id => !id)) throw new Error("No page selected");
      if (notebook_id && ids.some(id => store.findPage(id)?.notebook.id !== notebook_id)) throw new Error("Page does not belong to this notebook");
      const pages = store.setBackground(ids, background, paper);
      return { content: [{ type: "text" as const, text: `Updated ${pages.length} page(s): ${pages.map(p => `${p.id}: ${p.background} on ${p.paper ?? "default"} paper`).join(", ")}` }] };
    } catch (error) { return { isError: true, content: [{ type: "text" as const, text: (error as Error).message }] }; }
  });
}
