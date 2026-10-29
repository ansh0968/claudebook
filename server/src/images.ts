import fs from "node:fs";
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Router } from "express";
import { renderPage } from "./render.js";
import { downloadBytes } from "./download.js";
import { IMAGE_FILE, MAX_IMAGE_BYTES, imageDir, imagePath, normalizeImage, sweepImages } from "./image-assets.js";
import { itemBBox, offPageWarning, prepareItems } from "./items.js";
import type { Store } from "./store.js";

export const imageAnchor = z.enum(["top-left", "top-center", "top-right", "left-center", "center", "right-center", "bottom-left", "bottom-center", "bottom-right"]);
export const imageFields = {
  x: z.number().describe("Horizontal page coordinate of the chosen anchor (0..1000 is on page)"),
  y: z.number().describe("Vertical page coordinate of the chosen anchor (0..1414 is on page)"),
  w: z.number().positive().max(10000).optional().describe("Width in page units; alone keeps aspect ratio; omitted defaults to natural size capped at 600 wide"),
  h: z.number().positive().max(10000).optional().describe("Height in page units; alone keeps aspect ratio; with w uses fit"),
  anchor: imageAnchor.optional().describe('Point placed at x,y, before rotation; default top-left. Example: anchor:"top-right"'),
  rotation: z.number().optional().describe("Clockwise degrees about the positioned image centre, default 0"),
  opacity: z.number().min(0).max(1).optional().describe("0 transparent to 1 opaque, default 1"),
  fit: z.enum(["contain", "cover", "stretch"]).optional().describe("When both w and h are supplied: contain (default), cover (crop), or stretch"),
  alt: z.string().max(1000).optional().describe("Short description of the diagram for page descriptions"), group: z.string().optional().describe("Optional name for related items, so they can be erased together"),
};
export const placeImageSchema = z.object({
  page_id: z.string().optional().describe("Destination page id, default the page open on iPad"), ...imageFields,
  url: z.string().max(8192).optional().describe("HTTPS image URL, at most 15MB. Exactly one of url, data, source"),
  data: z.string().max(Math.ceil(MAX_IMAGE_BYTES / 3) * 4 + 200, { error: "Image is larger than 15MB" }).optional().describe("Base64 image bytes or image data URI, at most 15MB decoded. Exactly one of url, data, source"),
  source: z.object({ page_id: z.string(), region: z.object({ x: z.number().min(0), y: z.number().min(0), w: z.number().min(1), h: z.number().min(1) }) }).optional()
    .describe('Crop an existing notebook/PDF page. Example: source:{page_id:"pdf-page-id",region:{x:100,y:200,w:400,h:300}}'),
});
export type PlaceImageInput = z.infer<typeof placeImageSchema>;

function decodeData(data: string) {
  const match = data.match(/^data:image\/[a-z0-9.+-]+;base64,(.*)$/is);
  const encoded = (data.startsWith("data:") ? match?.[1] : data)?.replace(/\s/g, "");
  if (!encoded || encoded.length % 4 === 1 || !/^[a-zA-Z0-9+/]*={0,2}$/.test(encoded)) throw new Error("data must be base64 image bytes or a base64 image data URI");
  if (encoded.length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4) throw new Error("Image is larger than 15MB");
  return Buffer.from(encoded, "base64");
}

export async function placeImage(store: Store, input: PlaceImageInput,
  download = (url: string) => downloadBytes(url, { maxBytes: MAX_IMAGE_BYTES, label: "Image" })) {
  const value = placeImageSchema.parse(input);
  if ([value.url, value.data, value.source].filter(v => v !== undefined).length !== 1) throw new Error("Provide exactly one image source: url, data, or source");
  const pageId = value.page_id ?? store.view().pageId;
  if (!pageId || !store.findPage(pageId)) throw new Error("Destination page not found");
  let bytes: Buffer;
  if (value.source) {
    const source = store.findPage(value.source.page_id);
    if (!source) throw new Error("Source page not found");
    const r = value.source.region;
    if (r.x + r.w > 1000 || r.y + r.h > 1414) throw new Error("Source region must fit within the 1000 x 1414 page");
    bytes = await renderPage(store, source.page, { region: r, exactRegion: true });
  } else bytes = value.url !== undefined ? await download(value.url) : decodeData(value.data!);
  const image = await normalizeImage(bytes);
  const w = value.w ?? (value.h ? value.h * image.w / image.h : Math.min(600, image.w));
  const h = value.h ?? w * image.h / image.w;
  const a = value.anchor ?? "top-left";
  const fx = a.endsWith("right") || a.startsWith("right") ? 1 : a.includes("center") || a === "center" ? 0.5 : 0;
  const fy = a.startsWith("bottom") ? 1 : a.endsWith("center") || a === "center" ? 0.5 : 0;
  // Left/right-center have x at the edge; top/bottom-center have y at the edge.
  const xFraction = a === "left-center" ? 0 : a === "right-center" ? 1 : fx;
  const yFraction = a.startsWith("top") ? 0 : a.startsWith("bottom") ? 1 : fy;
  const [item] = prepareItems([{ type: "image", x: value.x - w * xFraction, y: value.y - h * yFraction, w, h,
    file: image.file, fit: value.fit ?? "contain", opacity: value.opacity ?? 1, rotation: value.rotation,
    alt: value.alt, group: value.group }]);
  const bbox = itemBBox(item), warning = offPageWarning(bbox);
  // No await between the disk write and metadata save: another sweep cannot
  // collect a just-normalized resource before its first reference is saved.
  fs.mkdirSync(imageDir(store), { recursive: true });
  const dest = imagePath(store, image.file);
  if (!fs.existsSync(dest)) {
    const temporary = dest + ".tmp";
    try { fs.writeFileSync(temporary, image.bytes); fs.renameSync(temporary, dest); }
    finally { fs.rmSync(temporary, { force: true }); }
  }
  try { store.addClaudeItems(pageId, [item]); }
  catch (error) { sweepImages(store); throw error; }
  return { item, bbox, warnings: warning ? [{ item: 0, type: "image", id: item.id, warning }] : [] };
}

export function registerImageTools(server: McpServer, store: Store) {
  server.registerTool("place_image", {
    title: "Place an image on a page",
    description: 'Paste one image from an HTTPS URL, small base64 image, or a crop of an existing notebook/PDF page. Neither Claude nor ChatGPT can forward images pasted in chat: use a URL, page crop, or ask the user to import the file. w alone preserves aspect ratio; default natural size capped to 600 wide. x,y names anchor before rotation. Example: {x:900,y:100,w:300,anchor:"top-right",source:{page_id:"pdf-page",region:{x:100,y:200,w:400,h:300}}}. Check view_page afterwards.',
    inputSchema: placeImageSchema.shape,
  }, async input => {
    try {
      const { item, bbox, warnings } = await placeImage(store, input);
      return { content: [{ type: "text" as const, text: JSON.stringify({ page_id: input.page_id ?? store.view().pageId, id: item.id, bbox, warnings }) }] };
    } catch (error) { return { isError: true, content: [{ type: "text" as const, text: (error as Error).message }] }; }
  });
}

export function registerImageRoutes(api: Router, store: Store) {
  api.get("/images/:file", (req, res) => {
    if (!IMAGE_FILE.test(req.params.file)) return res.status(400).end();
    const dest = imagePath(store, req.params.file);
    return fs.existsSync(dest) ? res.set("Cache-Control", "private, max-age=31536000, immutable").sendFile(dest) : res.status(404).end();
  });
}
