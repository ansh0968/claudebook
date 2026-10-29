// PDFs: storing them, counting pages, rasterizing a page for Claude, compiling Typst, fetching from URLs.
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { nanoid } from "nanoid";
import sharp from "sharp";
import { PAGE_H, PAGE_W, type Store } from "./store.js";
import { downloadBytes } from "./download.js";
import { typstFailureMessage } from "./typst-packages.js";

const run = promisify(execFile);
const TYPST = process.env.TYPST_BIN ?? "typst";
export const PDF_ID = /^[A-Za-z0-9_-]+$/;

export const pdfPath = (store: Store, file: string) => path.join(store.pdfDir, `${file}.pdf`);

export async function pdfPageCount(file: string) {
  const { stdout } = await run("pdfinfo", [file], { timeout: 20_000 });
  const m = stdout.match(/^Pages:\s+(\d+)/m);
  if (!m) throw new Error("Could not read the PDF's page count");
  return Number(m[1]);
}

/** Validate and store PDF bytes. Returns the new file id and its page count. */
export async function savePdf(store: Store, bytes: Buffer) {
  if (bytes.subarray(0, 1024).indexOf("%PDF") < 0) throw new Error("That isn't a PDF");
  const file = nanoid(12);
  const dest = pdfPath(store, file);
  fs.writeFileSync(dest, bytes);
  try {
    return { file, pages: await pdfPageCount(dest) };
  } catch (e) {
    fs.rmSync(dest, { force: true });
    throw e;
  }
}

/**
 * One PDF page as a 1000x1414 PNG: aspect-fit, centered, white around it. The iPad app draws
 * PDF pages the same way so coordinates line up. Cached on disk.
 */
export async function rasterizePdfPage(store: Store, file: string, page: number) {
  const cacheDir = path.join(store.dataDir, "pdf-renders");
  fs.mkdirSync(cacheDir, { recursive: true });
  const cached = path.join(cacheDir, `${file}-${page}.png`);
  if (fs.existsSync(cached)) return fs.readFileSync(cached);
  const prefix = path.join(cacheDir, `tmp-${nanoid(6)}`);
  await run("pdftoppm", ["-f", String(page), "-l", String(page), "-png", "-singlefile", "-scale-to", String(PAGE_H), pdfPath(store, file), prefix], { timeout: 60_000 });
  const png = await sharp(`${prefix}.png`)
    .resize(PAGE_W, PAGE_H, { fit: "contain", background: "#ffffff" })
    .flatten({ background: "#ffffff" })
    .png()
    .toBuffer();
  fs.rmSync(`${prefix}.png`, { force: true });
  fs.writeFileSync(cached, png);
  return png;
}

/** Compile Typst markup to PDF bytes. Throws with Typst's own error text on failure. */
export async function compileTypst(source: string, assets: Record<string, Buffer> = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-typst-"));
  try {
    fs.writeFileSync(path.join(dir, "main.typ"), source);
    for (const [name, bytes] of Object.entries(assets)) {
      if (!/^[a-zA-Z0-9_-]+\.(png|jpg|jpeg)$/i.test(name)) throw new Error("Invalid Typst asset name");
      fs.writeFileSync(path.join(dir, name), bytes);
    }
    try {
      await run(TYPST, ["compile", "--root", dir, "--diagnostic-format", "short", "main.typ", "out.pdf"], { cwd: dir, timeout: 30_000 });
    } catch (e) {
      const err = e as { stderr?: string; killed?: boolean; message: string };
      throw new Error(err.killed ? "Typst timed out after 30s" : typstFailureMessage(source, err.stderr || err.message));
    }
    return fs.readFileSync(path.join(dir, "out.pdf"));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

/** Download a PDF using the same DNS-pinned, redirect-safe guard as images. */
export const downloadPdf = (url: string) => downloadBytes(url, { maxBytes: 50 * 1024 * 1024, label: "PDF" });
