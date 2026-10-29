import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import sharp from "sharp";
import type { Store } from "./store.js";

export const IMAGE_FILE = /^[a-f0-9]{64}\.(png|jpg)$/;
export const MAX_IMAGE_BYTES = 15 * 1024 * 1024;
export const imageDir = (store: Store) => path.join(store.dataDir, "images");
export function imagePath(store: Store, file: string) {
  if (!IMAGE_FILE.test(file)) throw new Error("Invalid image filename");
  return path.resolve(imageDir(store), file);
}

export async function normalizeImage(bytes: Buffer) {
  if (bytes.length > MAX_IMAGE_BYTES) throw new Error("Image is larger than 15MB");
  try {
    // Bound decoded pixels as well as compressed bytes; animated GIF/WebP use frame 1.
    const input = sharp(bytes, { limitInputPixels: 40_000_000, pages: 1 });
    const meta = await input.metadata();
    if (!["png", "jpeg", "webp", "gif", "svg"].includes(meta.format ?? "")) throw new Error("Unsupported image format");
    if (meta.format === "svg") {
      // SVG is accepted as drawing input, never as a way to fetch subresources
      // or read files. Rasterize only self-contained content.
      const source = bytes.toString("utf8");
      if (/<!DOCTYPE|<!ENTITY|@import/i.test(source)) throw new Error("SVG external resources aren't allowed");
      for (const match of source.matchAll(/(?:href\s*=\s*["']([^"']*)["']|url\(\s*["']?([^)'"\s]+))/gi)) {
        if (!/^(?:#|data:image\/)/i.test(match[1] ?? match[2])) throw new Error("SVG external resources aren't allowed");
      }
    }
    const output = input.rotate().resize(2048, 2048, { fit: "inside", withoutEnlargement: true });
    const { data, info } = await (meta.hasAlpha ? output.png() : output.jpeg({ quality: 85 })).toBuffer({ resolveWithObject: true });
    return { bytes: data, w: info.width, h: info.height, file: `${createHash("sha256").update(data).digest("hex")}.${meta.hasAlpha ? "png" : "jpg"}` };
  } catch (error) {
    throw new Error(`Cannot decode image (PNG, JPEG, WebP, GIF or SVG, at most 40 million pixels): ${(error as Error).message}`);
  }
}

/** Metadata is authoritative, including all duplicated pages and copied items. */
export function sweepImages(store: Store) {
  const dir = imageDir(store);
  if (!fs.existsSync(dir)) return;
  const referenced = new Set(store.listNotebooks().flatMap(nb => nb.pages.flatMap(p =>
    p.claudeLayer.flatMap(i => i.type === "image" ? [i.file] : []))));
  for (const file of fs.readdirSync(dir)) {
    const orphan = IMAGE_FILE.test(file) && !referenced.has(file);
    const interruptedWrite = file.endsWith(".tmp") && IMAGE_FILE.test(file.slice(0, -4));
    if (!orphan && !interruptedWrite) continue;
    try { fs.rmSync(path.join(dir, file), { force: true }); }
    catch (error) { console.warn(`Could not remove unused image: ${(error as Error).message}`); }
  }
}

/** Embed raster bytes so SVG clients and librsvg need no authenticated subrequests. */
export function imageHref(store: Store, file: string) {
  const dest = imagePath(store, file);
  return fs.existsSync(dest) ? `data:image/${file.endsWith("png") ? "png" : "jpeg"};base64,${fs.readFileSync(dest).toString("base64")}` : "";
}
