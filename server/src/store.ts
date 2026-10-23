// Tiny file-backed store. One JSON file for metadata, PNGs on disk for page snapshots.
// Fine for a single user; swap for SQLite if it ever gets big.
import fs from "node:fs";
import path from "node:path";
import { nanoid } from "nanoid";
import type { Item } from "./items.js";

// Every page uses the same logical coordinate space so Claude can reason in round numbers.
// A4 ratio. The iPad app scales this to whatever size it draws at.
export const PAGE_W = 1000;
export const PAGE_H = 1414;

export type Background = "blank" | "lined" | "grid" | "dotted";

export interface TextBox {
  text: string;
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface Page {
  id: string;
  background: Background;
  /** Set when the page came from a PDF; the app renders the PDF page underneath the ink. */
  pdf?: { file: string; page: number };
  /** Bumped every time the app uploads a fresh snapshot of the user's ink. */
  snapshotVersion: number;
  /** Handwriting recognized on device, in page coordinates. */
  textBoxes: TextBox[];
  claudeLayer: Item[];
  updatedAt: string;
}

export interface Notebook {
  id: string;
  title: string;
  pages: Page[];
  createdAt: string;
  updatedAt: string;
}

export interface ViewState {
  notebookId: string | null;
  pageId: string | null;
  updatedAt: string | null;
}

interface DB {
  notebooks: Notebook[];
  view: ViewState;
}

const now = () => new Date().toISOString();

export class Store {
  private db: DB;
  private file: string;
  readonly snapshotsDir: string;
  readonly pdfDir: string;
  readonly drawingsDir: string;
  private listeners = new Set<(e: StoreEvent) => void>();

  constructor(readonly dataDir: string) {
    this.file = path.join(dataDir, "db.json");
    this.snapshotsDir = path.join(dataDir, "snapshots");
    this.pdfDir = path.join(dataDir, "pdfs");
    this.drawingsDir = path.join(dataDir, "drawings");
    fs.mkdirSync(this.drawingsDir, { recursive: true });
    fs.mkdirSync(this.snapshotsDir, { recursive: true });
    fs.mkdirSync(this.pdfDir, { recursive: true });
    this.db = fs.existsSync(this.file)
      ? JSON.parse(fs.readFileSync(this.file, "utf8"))
      : { notebooks: [], view: { notebookId: null, pageId: null, updatedAt: null } };
    if (this.db.notebooks.length === 0) this.seed();
  }

  private seed() {
    const nb = this.createNotebook("Scratchpad", 1, "grid");
    this.setView(nb.id, nb.pages[0].id);
  }

  private save() {
    const tmp = this.file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(this.db, null, 1));
    fs.renameSync(tmp, this.file);
  }

  on(fn: (e: StoreEvent) => void) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private emit(e: StoreEvent) {
    for (const fn of this.listeners) fn(e);
  }

  listNotebooks() {
    return this.db.notebooks;
  }

  getNotebook(id: string) {
    return this.db.notebooks.find((n) => n.id === id);
  }

  findPage(pageId: string): { notebook: Notebook; page: Page; index: number } | undefined {
    for (const notebook of this.db.notebooks) {
      const index = notebook.pages.findIndex((p) => p.id === pageId);
      if (index >= 0) return { notebook, page: notebook.pages[index], index };
    }
  }

  newPage(background: Background = "blank"): Page {
    return { id: nanoid(10), background, snapshotVersion: 0, textBoxes: [], claudeLayer: [], updatedAt: now() };
  }

  createNotebook(title: string, pageCount = 1, background: Background = "blank"): Notebook {
    const nb: Notebook = {
      id: nanoid(10),
      title,
      pages: Array.from({ length: Math.max(1, pageCount) }, () => this.newPage(background)),
      createdAt: now(),
      updatedAt: now(),
    };
    this.db.notebooks.push(nb);
    this.save();
    this.emit({ type: "notebook", notebookId: nb.id });
    return nb;
  }

  /** One page per PDF page. Appends to `notebookId` if given, else makes a new notebook titled `title`. */
  addPdfPages(file: string, count: number, title: string, notebookId?: string) {
    const pages = Array.from({ length: count }, (_, i) => ({ ...this.newPage("blank"), pdf: { file, page: i + 1 } }));
    if (notebookId) {
      const at = this.insertPages(notebookId, pages);
      return { notebook: this.getNotebook(notebookId)!, firstIndex: at };
    }
    const nb = this.createNotebook(title, 1);
    nb.pages = pages;
    this.save();
    this.emit({ type: "notebook", notebookId: nb.id });
    return { notebook: nb, firstIndex: 0 };
  }

  /** Insert pages after `afterIndex` (-1 = at the start, undefined = at the end). */
  insertPages(notebookId: string, pages: Page[], afterIndex?: number) {
    const nb = this.getNotebook(notebookId);
    if (!nb) throw new Error(`No notebook ${notebookId}`);
    const at = afterIndex === undefined ? nb.pages.length : Math.min(nb.pages.length, afterIndex + 1);
    nb.pages.splice(at, 0, ...pages);
    nb.updatedAt = now();
    this.save();
    this.emit({ type: "notebook", notebookId });
    return at;
  }

  view(): ViewState {
    return this.db.view;
  }

  setView(notebookId: string, pageId: string) {
    this.db.view = { notebookId, pageId, updatedAt: now() };
    this.save();
  }

  snapshotPath(pageId: string) {
    return path.join(this.snapshotsDir, `${pageId}.png`);
  }

  saveSnapshot(pageId: string, png: Buffer, textBoxes?: TextBox[]) {
    const found = this.findPage(pageId);
    if (!found) throw new Error(`No page ${pageId}`);
    fs.writeFileSync(this.snapshotPath(pageId), png);
    found.page.snapshotVersion++;
    if (textBoxes) found.page.textBoxes = textBoxes;
    found.page.updatedAt = now();
    this.save();
  }

  /** Raw PKDrawing bytes from the app, kept as a backup so ink survives an app reinstall. */
  drawingPath(pageId: string) {
    return path.join(this.drawingsDir, `${pageId}.pkdrawing`);
  }

  saveDrawing(pageId: string, data: Buffer) {
    if (!this.findPage(pageId)) throw new Error(`No page ${pageId}`);
    fs.writeFileSync(this.drawingPath(pageId), data);
  }

  /** Rewrite stored Claude items in place (one-off upgrades at startup). Returns how many changed. */
  upgradeItems(fn: (item: Item) => Item | undefined) {
    let changed = 0;
    for (const nb of this.db.notebooks) {
      for (const page of nb.pages) {
        page.claudeLayer = page.claudeLayer.map((item) => {
          const next = fn(item);
          if (next) changed++;
          return next ?? item;
        });
      }
    }
    if (changed) this.save();
    return changed;
  }

  addClaudeItems(pageId: string, items: Item[]) {
    const found = this.findPage(pageId);
    if (!found) throw new Error(`No page ${pageId}`);
    found.page.claudeLayer.push(...items);
    found.page.updatedAt = now();
    this.save();
    this.emit({ type: "claudeLayer", notebookId: found.notebook.id, pageId });
  }

  /** Remove the last `count` Claude items, or all of them when count is undefined. */
  removeClaudeItems(pageId: string, count?: number) {
    const found = this.findPage(pageId);
    if (!found) throw new Error(`No page ${pageId}`);
    const layer = found.page.claudeLayer;
    const removed = count === undefined ? layer.length : Math.min(count, layer.length);
    layer.splice(layer.length - removed, removed);
    found.page.updatedAt = now();
    this.save();
    this.emit({ type: "claudeLayer", notebookId: found.notebook.id, pageId });
    return removed;
  }
}

export type StoreEvent =
  | { type: "notebook"; notebookId: string }
  | { type: "claudeLayer"; notebookId: string; pageId: string };
