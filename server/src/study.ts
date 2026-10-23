import { compileTypst, savePdf } from "./pdf.js";
import { renderPage } from "./render.js";
import { type PageRegion, type Store } from "./store.js";
import { parsePageRegion } from "./regions.js";
import sharp from "sharp";

/** Save a marked page crop and Claude's explanation as a PDF page in one persistent notebook. */
export async function logMistake(store: Store, pageId: string, region: PageRegion, correction: string, title?: string) {
  const found = store.findPage(pageId);
  if (!found) throw new Error("Page not found");
  if (!parsePageRegion(region)) throw new Error("Region must fit within the page");
  // The viewing zoom expands tiny regions for legibility. Preserve the actual selection in the log.
  const full = await renderPage(store, found.page, { scale: 2, grid: false });
  const left = Math.floor(region.x * 2), top = Math.floor(region.y * 2);
  const crop = await sharp(full).extract({ left, top,
    width: Math.ceil((region.x + region.w) * 2) - left,
    height: Math.ceil((region.y + region.h) * 2) - top,
  }).png().toBuffer();
  const source = `${found.notebook.title}, page ${found.index + 1}`;
  const heading = title?.trim() || "Mistake and correction";
  const typst = `#set page(paper: "a4", margin: 20mm)\n#set text(size: 11pt)\n= Error Log\n#text(weight: "bold", ${JSON.stringify(heading)})\n#v(3mm)\nSource: #text(${JSON.stringify(source)})\n#v(5mm)\n#image("mistake.png", width: 100%, height: 11cm, fit: "contain")\n#v(5mm)\n== Correction\n#text(${JSON.stringify(correction.trim())})\n`;
  const pdf = await compileTypst(typst, { "mistake.png": crop });
  const { file, pages } = await savePdf(store, pdf);
  const existing = store.listNotebooks().find((n) => n.title === "Error Log");
  const { notebook, firstIndex } = store.addPdfPages(file, pages, "Error Log", existing?.id);
  return { notebookId: notebook.id, pageId: notebook.pages[firstIndex].id, pageNumber: firstIndex + 1, pages };
}
