import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import sharp from "sharp";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { compileTypst, savePdf, rasterizePdfPage } from "./pdf.js";
import { describePdfText, parsePdfText, pdfTextPage, type PdfTextPage } from "./pdf-text.js";
import { Store } from "./store.js";
import { TYPST_IMPORTS } from "./typst-packages.js";

const near = (a: number, b: number) => assert.ok(Math.abs(a - b) < 0.02, `${a} != ${b}`);
const parsed = parsePdfText('<doc><page width="600" height="300"><flow><block><line xMin="60" yMin="30" xMax="180" yMax="60"><word xMin="60" yMin="30" xMax="100" yMax="60">Q17.</word><word xMin="110" yMin="30" xMax="180" yMax="60">x &amp; y &#x3B8;</word></line></block></flow></page></doc>');
near(parsed.lines[0].x, 100); near(parsed.lines[0].y, 507); near(parsed.lines[0].w, 200); near(parsed.lines[0].h, 50);
assert.equal(parsed.lines[0].text, "Q17. x & y θ");
assert.equal(parsed.lines[0].words.length, 2);
const many: PdfTextPage = { ...parsed, lines: Array.from({ length: 160 }, (_, i) => ({ ...parsed.lines[0], text: `line ${i}` })) };
assert.ok(describePdfText(many).at(-1)?.includes("10 more lines"));
assert.ok(describePdfText(parsed, { x: 0, y: 0, w: 50, h: 50 }).at(-1)?.includes("No PDF text overlaps"));
assert.ok(describePdfText({ ...parsed, lines: [] })[0].includes("no text layer"));
assert.throws(() => parsePdfText("<doc/>"), /no page/);
console.log("[PDF text] aspect fit, centring, XML entities, words, zoom and line cap passed");

// A real PDF fixture with a rotated, offset media box. Poppler's word boxes are
// rotated while its XML page width/height remain unrotated.
function rotatedPdf(rotation: number): Buffer {
  const stream = "BT /F1 20 Tf 50 500 Td (Rotated Q17) Tj ET";
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    `<< /Type /Page /Parent 2 0 R /MediaBox [10 20 310 620] /Rotate ${rotation} /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>`,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`,
  ];
  let pdf = "%PDF-1.4\n";
  const offsets: number[] = [];
  objects.forEach((o, i) => { offsets.push(pdf.length); pdf += `${i + 1} 0 obj\n${o}\nendobj\n`; });
  const xref = pdf.length;
  pdf += "xref\n0 6\n0000000000 65535 f \n" + offsets.map(o => `${String(o).padStart(10, "0")} 00000 n \n`).join("");
  pdf += `trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(pdf, "ascii");
}

const has = (bin: string) => {
  try { execFileSync(bin === "typst" ? process.env.TYPST_BIN ?? bin : bin, [bin === "typst" ? "--version" : "-v"], { stdio: "ignore" }); return true; }
  catch { return false; }
};
if (has("typst") && has("pdftotext") && has("pdftoppm") && has("pdfinfo")) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-pdf-upgrades-"));
  const store = new Store(temporary);
  try {
    const warmup = fs.readFileSync(new URL("../typst-packages.typ", import.meta.url), "utf8");
    const packages = await compileTypst(warmup);
    assert.ok(packages.subarray(0, 5).toString() === "%PDF-");
    console.log("[PDF packages] pinned CeTZ line/circle, plot, physica and chemistry compiled");
    const source = '#set page(width: 600pt, height: 300pt, margin: 40pt)\nFirst page\n#pagebreak()\nQ17. Find x\n#v(50pt)\nA different line\n';
    const saved = await savePdf(store, await compileTypst(source));
    assert.equal(saved.pages, 2);
    const text = await pdfTextPage(store, saved.file, 2), q = text.lines.find(line => line.text === "Q17. Find x");
    assert.ok(q, JSON.stringify(text));
    assert.ok(q.x >= 0 && q.y >= 0 && q.x + q.w <= 1000 && q.y + q.h <= 1414);
    const cache = path.join(temporary, "pdf-text", `${saved.file}-2.json`), modified = fs.statSync(cache).mtimeMs;
    assert.deepEqual(await pdfTextPage(store, saved.file, 2), text);
    assert.equal(fs.statSync(cache).mtimeMs, modified, "Repeated extraction should read the disk cache");
    fs.writeFileSync(cache, JSON.stringify({ version: 1, width: 600, height: 300, lines: [{}] }));
    assert.deepEqual(await pdfTextPage(store, saved.file, 2), text, "Malformed cached entries must rebuild");
    const png = await rasterizePdfPage(store, saved.file, 2);
    const crop = { left: Math.max(0, Math.floor(q.x) - 2), top: Math.max(0, Math.floor(q.y) - 2), width: Math.ceil(q.w) + 4, height: Math.ceil(q.h) + 4 };
    const ink = await sharp(png).extract(crop).flatten({ background: "white" }).removeAlpha().raw().toBuffer();
    assert.ok([...ink].filter(v => v < 100).length > 20, "The returned PDF bbox must contain visible glyph ink");
    const blank = await savePdf(store, await compileTypst('#set page(width: 300pt, height: 300pt)\n#rect(width: 100pt, height: 100pt, fill: red)'));
    assert.equal((await pdfTextPage(store, blank.file, 1)).lines.length, 0);
    for (const rotation of [0, 90, 180, 270]) {
      const saved = await savePdf(store, rotatedPdf(rotation)), text = await pdfTextPage(store, saved.file, 1);
      const line = text.lines.find(l => l.text === "Rotated Q17");
      assert.ok(line, `Missing rotated text at ${rotation}°`);
      const png = await rasterizePdfPage(store, saved.file, 1);
      const ink = await sharp(png).extract({ left: Math.max(0, Math.floor(line.x) - 2), top: Math.max(0, Math.floor(line.y) - 2), width: Math.ceil(line.w) + 4, height: Math.ceil(line.h) + 4 }).removeAlpha().raw().toBuffer();
      assert.ok([...ink].filter(v => v < 100).length > 20, `Rotated text bbox must align at ${rotation}°`);
    }
    assert.throws(() => parsePdfText('<page width="0" height="300"></page>'), /dimensions/);
    console.log("[PDF text] page 2, cache, landscape/centred image, all rotations/offset media boxes and empty layers passed");
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }

  if (process.env.CLAUDEBOOK_SECRET) {
    const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787", secret = process.env.CLAUDEBOOK_SECRET;
    const client = new Client({ name: "pdf-upgrades-selftest", version: "1" });
    await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));
    try {
      const title = `PDF text acceptance ${Date.now()}`;
      const created = await client.callTool({ name: "create_pdf", arguments: { title, typst: `${TYPST_IMPORTS}\n#canvas({ draw.line((0,0),(2,1)); draw.circle((1,1),radius:0.4) })\n#pagebreak()\nQ17. Find x\n#v(6cm)\nOther question` } });
      assert.ok(!created.isError, JSON.stringify(created.content));
      const response = await fetch(`${base}/api/notebooks`, { headers: { Authorization: `Bearer ${secret}` } });
      const list = await response.json() as { notebooks: { id: string; title: string; pages: { id: string }[] }[] };
      const notebook = list.notebooks.find(n => n.title === title);
      assert.ok(notebook && notebook.pages.length === 2);
      const view = await client.callTool({ name: "view_page", arguments: { notebook_id: notebook.id, page_number: 2, grid: false } });
      assert.ok(!view.isError);
      const description = (view.content as { text?: string }[])[0].text!;
      const match = description.match(/- \[([\d., ]+)\] Q17\. Find x/);
      assert.ok(match, description);
      const [x, y, w, h] = match[1].split(",").map(Number);
      assert.ok(x >= 0 && y >= 0 && x + w <= 1000 && y + h <= 1414);
      const zoom = await client.callTool({ name: "view_page", arguments: { page_id: notebook.pages[1].id, grid: false, zoom: { x: x - 5, y: y - 5, w: w + 10, h: Math.max(50, h + 10) } } });
      const zoomDescription = (zoom.content as { text?: string }[])[0].text!;
      assert.ok(zoomDescription.includes("Q17. Find x") && !zoomDescription.includes("Other question"));
      const image = (zoom.content as { type: string; data?: string }[]).find(c => c.type === "image");
      assert.ok(image?.data);
      const output = path.join(process.env.CLAUDEBOOK_TEST_ARTIFACTS ?? os.tmpdir(), "claudebook-pdf-q17-zoom.png");
      fs.mkdirSync(path.dirname(output), { recursive: true });
      fs.writeFileSync(output, Buffer.from(image.data, "base64"));
      console.log(`[PDF MCP] create_pdf CeTZ, page 2 text bbox and zoom filtering passed; preview ${output}`);
    } finally { await client.close(); }
  }
} else console.log("SKIP PDF integration checks (Typst/Poppler tools not installed)");
