import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Store, type Notebook } from "./store.js";

function samplePdf(pageCount: number): Uint8Array<ArrayBuffer> {
  const objects: string[] = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "", // placeholder for /Pages
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ];
  const kids: string[] = [];
  for (let i = 0; i < pageCount; i++) {
    const pageObjNum = objects.length + 1;
    const contentObjNum = pageObjNum + 1;
    const stream = `BT /F1 18 Tf 72 720 Td (Imported Handout Page ${i + 1}) Tj ET`;
    kids.push(`${pageObjNum} 0 R`);
    objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents ${contentObjNum} 0 R >>`);
    objects.push(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
  }
  objects[1] = `<< /Type /Pages /Kids [${kids.join(" ")}] /Count ${pageCount} >>`;

  let pdf = "%PDF-1.4\n";
  const offsets: number[] = [];
  objects.forEach((obj, idx) => {
    offsets.push(pdf.length);
    pdf += `${idx + 1} 0 obj\n${obj}\nendobj\n`;
  });
  const xref = pdf.length;
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const off of offsets) pdf += `${String(off).padStart(10, "0")} 00000 n \n`;
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  const buf = Buffer.from(pdf, "ascii");
  return new Uint8Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
}

const hasPdfInfo = (() => {
  try {
    execFileSync("pdfinfo", ["-v"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
})();

// Store-level unit checks (always run, no external binaries needed).
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-pdf-import-"));
try {
  const store = new Store(tempDir);
  const folder = store.createFolder("Chemistry");

  // 1. Library PDF import into a folder still creates a new notebook in that folder.
  const libImport = store.addPdfPages("pdf_lib_file", 3, "Lecture Slides", undefined, folder.id);
  assert.equal(libImport.firstIndex, 0);
  assert.equal(libImport.notebook.title, "Lecture Slides");
  assert.equal(libImport.notebook.folderId, folder.id);
  assert.deepEqual(
    libImport.notebook.pages.map(p => p.pdf),
    [
      { file: "pdf_lib_file", page: 1 },
      { file: "pdf_lib_file", page: 2 },
      { file: "pdf_lib_file", page: 3 },
    ],
  );

  // 2. In-notebook PDF import after a chosen page, at the start (0), and at the end (undefined).
  const active = store.createNotebook("Organic Lab", 3, "lined");
  const [p1, p2, p3] = active.pages.map(p => p.id);

  // Insert 2 pages right after page 1 (afterPage = 1 -> indices 1, 2).
  const midInsert = store.addPdfPages("handout_mid", 2, "Ignored Title", active.id, undefined, 1);
  assert.equal(midInsert.firstIndex, 1);
  assert.equal(midInsert.notebook.id, active.id);
  assert.equal(midInsert.notebook.title, "Organic Lab");
  assert.equal(midInsert.notebook.pages.length, 5);
  assert.equal(midInsert.notebook.pages[0].id, p1);
  assert.deepEqual(midInsert.notebook.pages[1].pdf, { file: "handout_mid", page: 1 });
  assert.deepEqual(midInsert.notebook.pages[2].pdf, { file: "handout_mid", page: 2 });
  assert.equal(midInsert.notebook.pages[3].id, p2);
  assert.equal(midInsert.notebook.pages[4].id, p3);

  // Insert 1 page at the very beginning (afterPage = 0 -> index 0).
  const startInsert = store.addPdfPages("handout_cover", 1, "Cover", active.id, undefined, 0);
  assert.equal(startInsert.firstIndex, 0);
  assert.deepEqual(startInsert.notebook.pages[0].pdf, { file: "handout_cover", page: 1 });
  assert.equal(startInsert.notebook.pages[1].id, p1);

  // Append 2 pages at the end (afterPage omitted).
  const endInsert = store.addPdfPages("handout_end", 2, "Appendix", active.id);
  assert.equal(endInsert.firstIndex, 6);
  assert.equal(endInsert.notebook.pages.length, 8);
  assert.deepEqual(endInsert.notebook.pages[6].pdf, { file: "handout_end", page: 1 });
  assert.deepEqual(endInsert.notebook.pages[7].pdf, { file: "handout_end", page: 2 });

  // Insert into an empty notebook with afterPage = 0.
  const emptyNb = store.createNotebook("Empty Notebook", 1);
  store.deletePages(emptyNb.id, [emptyNb.pages[0].id]);
  assert.equal(emptyNb.pages.length, 0);
  const intoEmpty = store.addPdfPages("handout_empty", 2, "Refill", emptyNb.id, undefined, 0);
  assert.equal(intoEmpty.firstIndex, 0);
  assert.equal(intoEmpty.notebook.pages.length, 2);

  // Validation errors leave existing pages untouched.
  const snapshotBefore = active.pages.map(p => p.id);
  assert.throws(() => store.addPdfPages("bad", 1, "Bad", active.id, undefined, -1), RangeError);
  assert.throws(() => store.addPdfPages("bad", 1, "Bad", active.id, undefined, 99), RangeError);
  assert.throws(() => store.addPdfPages("bad", 1, "Bad", active.id, undefined, 1.5), RangeError);
  assert.throws(() => store.addPdfPages("bad", 1, "Bad", undefined, undefined, 0), RangeError);
  assert.throws(() => store.addPdfPages("bad", 1, "Bad", "missing-nb", undefined, 0), /No notebook/);
  assert.deepEqual(active.pages.map(p => p.id), snapshotBefore);

  console.log("[PDF import store] library folder import, mid-notebook/start/end/empty insertion, and bounds checks passed");
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}

// REST endpoint integration checks against the live server when pdfinfo + CLAUDEBOOK_SECRET are present.
if (process.env.CLAUDEBOOK_SECRET && hasPdfInfo) {
  const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787";
  const secret = process.env.CLAUDEBOOK_SECRET;
  const authHeaders = { Authorization: `Bearer ${secret}` };

  const jsonReq = async <T>(route: string, method = "GET", body?: unknown, expectedStatus = 200): Promise<T> => {
    const res = await fetch(`${base}/api${route}`, {
      method,
      headers: { ...authHeaders, ...(body !== undefined ? { "Content-Type": "application/json" } : {}) },
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    });
    assert.equal(res.status, expectedStatus, `${method} ${route}: ${await res.clone().text()}`);
    return (await res.json()) as T;
  };

  const pdfBytes = samplePdf(2);
  const folder = await jsonReq<{ id: string }>("/folders", "POST", { name: "PDF Import Folder" }, 201);
  const createdIds: string[] = [];

  try {
    // Library import into folder creates a new notebook in that folder.
    const libRes = await fetch(`${base}/api/notebooks/import-pdf?title=ShelfImport&folderId=${folder.id}`, {
      method: "POST",
      headers: { ...authHeaders, "Content-Type": "application/pdf" },
      body: pdfBytes,
    });
    assert.equal(libRes.status, 200);
    const libNb = (await libRes.json()) as Notebook;
    createdIds.push(libNb.id);
    assert.equal(libNb.title, "ShelfImport");
    assert.equal(libNb.folderId, folder.id);
    assert.equal(libNb.pages.length, 2);

    // Open notebook import right after page 1 (afterPage=1) inserts into the same notebook.
    const hostNb = await jsonReq<Notebook>("/notebooks", "POST", { title: "Host Notebook", pages: 2, background: "lined" });
    createdIds.push(hostNb.id);
    const [origFirst, origSecond] = hostNb.pages.map(p => p.id);

    const insertRes = await fetch(`${base}/api/notebooks/import-pdf?title=Supplement&notebookId=${hostNb.id}&afterPage=1`, {
      method: "POST",
      headers: { ...authHeaders, "Content-Type": "application/pdf" },
      body: pdfBytes,
    });
    assert.equal(insertRes.status, 200);
    const updated = (await insertRes.json()) as Notebook;
    assert.equal(updated.id, hostNb.id);
    assert.equal(updated.pages.length, 4);
    assert.equal(updated.pages[0].id, origFirst);
    assert.equal(updated.pages[1].pdf?.page, 1);
    assert.equal(updated.pages[2].pdf?.page, 2);
    assert.equal(updated.pages[3].id, origSecond);

    // Append at end when afterPage is omitted.
    const appendRes = await fetch(`${base}/api/notebooks/import-pdf?notebookId=${hostNb.id}`, {
      method: "POST",
      headers: { ...authHeaders, "Content-Type": "application/pdf" },
      body: samplePdf(1),
    });
    assert.equal(appendRes.status, 200);
    const appended = (await appendRes.json()) as Notebook;
    assert.equal(appended.pages.length, 5);
    assert.equal(appended.pages[4].pdf?.page, 1);

    // Error cases: missing notebook -> 404, out-of-range afterPage -> 400, afterPage without notebookId -> 400.
    const missingRes = await fetch(`${base}/api/notebooks/import-pdf?notebookId=nonexistent&afterPage=0`, {
      method: "POST",
      headers: { ...authHeaders, "Content-Type": "application/pdf" },
      body: pdfBytes,
    });
    assert.equal(missingRes.status, 404);

    const badAfterRes = await fetch(`${base}/api/notebooks/import-pdf?notebookId=${hostNb.id}&afterPage=99`, {
      method: "POST",
      headers: { ...authHeaders, "Content-Type": "application/pdf" },
      body: pdfBytes,
    });
    assert.equal(badAfterRes.status, 400);

    const orphanAfterRes = await fetch(`${base}/api/notebooks/import-pdf?afterPage=1`, {
      method: "POST",
      headers: { ...authHeaders, "Content-Type": "application/pdf" },
      body: pdfBytes,
    });
    assert.equal(orphanAfterRes.status, 400);

    console.log("[PDF import REST] shelf import, in-notebook afterPage insertion/append, and 400/404 validation passed");
  } finally {
    for (const id of createdIds) await fetch(`${base}/api/notebooks/${id}`, { method: "DELETE", headers: authHeaders });
    await fetch(`${base}/api/folders/${folder.id}`, { method: "DELETE", headers: authHeaders });
  }
}
