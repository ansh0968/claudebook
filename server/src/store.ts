// Tiny file-backed store. One JSON file for metadata, PNGs on disk for page snapshots.
// Fine for a single user; swap for SQLite if it ever gets big.
import fs from "node:fs";
import path from "node:path";
import { nanoid } from "nanoid";
import type { Item } from "./items.js";
import { translateItem } from "./items.js";
import { renderHandwriting } from "./handwriting.js";

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

export interface PageRegion { x: number; y: number; w: number; h: number }

export interface Doubt {
  id: string;
  pageId: string;
  region: PageRegion;
  createdAt: string;
  resolvedAt?: string;
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
  doubts: Doubt[];
  claudeLayer: Item[];
  updatedAt: string;
}

export interface Notebook {
  id: string;
  title: string;
  pages: Page[];
  createdAt: string;
  updatedAt: string;
  /** Unset means the notebook sits at the top level of the library. */
  folderId?: string;
  /** Scratch pads delete themselves SCRATCH_TTL_MS after their last edit unless the user keeps them. */
  scratch?: boolean;
}

export interface Folder {
  id: string;
  name: string;
  /** Unset means a top-level folder. */
  parentId?: string;
  createdAt: string;
  updatedAt: string;
}

export const SCRATCH_TTL_MS = 7 * 24 * 60 * 60 * 1000;

export interface ViewState {
  notebookId: string | null;
  pageId: string | null;
  updatedAt: string | null;
}

interface DB {
  notebooks: Notebook[];
  folders: Folder[];
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
      : { notebooks: [], folders: [], view: { notebookId: null, pageId: null, updatedAt: null } };
    this.db.folders ??= [];
    // Older db.json files have no doubts field. Normalize once so every API response has an array.
    for (const notebook of this.db.notebooks) for (const page of notebook.pages) page.doubts ??= [];
    if (this.db.notebooks.length === 0) this.seed();
  }

  private seed() {
    const nb = this.createNotebook("First notebook", 1, "grid");
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

  /** Rename a notebook. Returns undefined if it doesn't exist. */
  renameNotebook(id: string, title: string) {
    return this.updateNotebook(id, { title });
  }

  /** Remove a notebook and its page files. PDFs stay, since another notebook may share one. */
  deleteNotebook(id: string) {
    const nb = this.getNotebook(id);
    if (!nb) return false;
    this.db.notebooks = this.db.notebooks.filter((n) => n.id !== id);
    for (const page of nb.pages) {
      fs.rmSync(this.snapshotPath(page.id), { force: true });
      fs.rmSync(this.drawingPath(page.id), { force: true });
    }
    if (this.db.view.notebookId === id) this.db.view = { notebookId: null, pageId: null, updatedAt: now() };
    if (this.db.notebooks.length === 0) this.seed();
    this.save();
    this.emit({ type: "notebook", notebookId: id });
    return true;
  }

  getNotebook(id: string) {
    return this.db.notebooks.find((n) => n.id === id);
  }

  /** Latest change to the notebook or any of its pages. ISO strings sort by time. */
  lastActivity(nb: Notebook) {
    return nb.pages.reduce((latest, p) => (p.updatedAt > latest ? p.updatedAt : latest), nb.updatedAt);
  }

  /** When a scratch pad will delete itself, or undefined for normal notebooks. */
  scratchExpiry(nb: Notebook) {
    return nb.scratch ? new Date(Date.parse(this.lastActivity(nb)) + SCRATCH_TTL_MS).toISOString() : undefined;
  }

  /** Move a notebook into a folder (null = top level), rename it, or keep a scratch pad for good. */
  updateNotebook(id: string, changes: { title?: string; folderId?: string | null; scratch?: false }) {
    const nb = this.getNotebook(id);
    if (!nb) return;
    if (changes.folderId && !this.getFolder(changes.folderId)) throw new RangeError(`No folder ${changes.folderId}`);
    if (changes.title !== undefined) nb.title = changes.title;
    if (changes.folderId !== undefined) {
      if (changes.folderId) nb.folderId = changes.folderId;
      else delete nb.folderId;
    }
    if (changes.scratch === false) delete nb.scratch;
    // Filing a notebook away isn't an edit, so it shouldn't jump to the front of "recent".
    if (changes.title !== undefined || changes.scratch === false) nb.updatedAt = now();
    this.save();
    this.emit({ type: "notebook", notebookId: id });
    return nb;
  }

  /** Delete scratch pads nobody has touched for a week. Skips the one the user is looking at right now. */
  purgeExpiredScratchPads(at = Date.now()) {
    const recentlyViewed = this.db.view.updatedAt && at - Date.parse(this.db.view.updatedAt) < 60 * 60 * 1000 ? this.db.view.notebookId : null;
    const expired = this.db.notebooks.filter((nb) => nb.scratch && nb.id !== recentlyViewed && Date.parse(this.scratchExpiry(nb)!) <= at);
    for (const nb of expired) this.deleteNotebook(nb.id);
    return expired.map((nb) => nb.title);
  }

  listFolders() {
    return this.db.folders;
  }

  getFolder(id: string) {
    return this.db.folders.find((f) => f.id === id);
  }

  /** Folder names from the top level down, e.g. ["Chemistry", "Organic"]. */
  folderPath(id: string | undefined): string[] {
    const names: string[] = [];
    for (let f = id ? this.getFolder(id) : undefined; f; f = f.parentId ? this.getFolder(f.parentId) : undefined) names.unshift(f.name);
    return names;
  }

  createFolder(name: string, parentId?: string) {
    if (parentId && !this.getFolder(parentId)) throw new RangeError(`No folder ${parentId}`);
    const folder: Folder = { id: nanoid(10), name, ...(parentId ? { parentId } : {}), createdAt: now(), updatedAt: now() };
    this.db.folders.push(folder);
    this.save();
    this.emit({ type: "folders" });
    return folder;
  }

  /** Rename a folder or move it under another one (null = top level). Refuses to move a folder inside itself. */
  updateFolder(id: string, changes: { name?: string; parentId?: string | null }) {
    const folder = this.getFolder(id);
    if (!folder) return;
    if (changes.parentId) {
      if (!this.getFolder(changes.parentId)) throw new RangeError(`No folder ${changes.parentId}`);
      for (let f = this.getFolder(changes.parentId); f; f = f.parentId ? this.getFolder(f.parentId) : undefined) {
        if (f.id === id) throw new RangeError("A folder can't go inside itself");
      }
    }
    if (changes.name !== undefined) folder.name = changes.name;
    if (changes.parentId !== undefined) {
      if (changes.parentId) folder.parentId = changes.parentId;
      else delete folder.parentId;
    }
    folder.updatedAt = now();
    this.save();
    this.emit({ type: "folders" });
    return folder;
  }

  /** Remove a folder without losing anything: its notebooks and subfolders move up to its parent. */
  deleteFolder(id: string) {
    const folder = this.getFolder(id);
    if (!folder) return false;
    this.db.folders = this.db.folders.filter((f) => f.id !== id);
    for (const f of this.db.folders) if (f.parentId === id) {
      if (folder.parentId) f.parentId = folder.parentId;
      else delete f.parentId;
    }
    for (const nb of this.db.notebooks) if (nb.folderId === id) {
      if (folder.parentId) nb.folderId = folder.parentId;
      else delete nb.folderId;
    }
    this.save();
    this.emit({ type: "folders" });
    return true;
  }

  findPage(pageId: string): { notebook: Notebook; page: Page; index: number } | undefined {
    for (const notebook of this.db.notebooks) {
      const index = notebook.pages.findIndex((p) => p.id === pageId);
      if (index >= 0) return { notebook, page: notebook.pages[index], index };
    }
  }

  newPage(background: Background = "blank"): Page {
    return { id: nanoid(10), background, snapshotVersion: 0, textBoxes: [], doubts: [], claudeLayer: [], updatedAt: now() };
  }

  addDoubt(pageId: string, region: PageRegion): Doubt {
    const found = this.findPage(pageId);
    if (!found) throw new Error(`No page ${pageId}`);
    const valid = [region.x, region.y, region.w, region.h].every(Number.isFinite) &&
      region.w > 0 && region.h > 0 && region.x >= 0 && region.y >= 0 &&
      region.x + region.w <= PAGE_W && region.y + region.h <= PAGE_H;
    if (!valid) throw new RangeError(`Doubt region must fit within ${PAGE_W} x ${PAGE_H} page coordinates`);
    const doubt: Doubt = { id: nanoid(10), pageId, region: { ...region }, createdAt: now() };
    found.page.doubts.push(doubt);
    found.page.updatedAt = now();
    this.save();
    this.emit({ type: "doubts", notebookId: found.notebook.id, pageId, doubts: found.page.doubts });
    return doubt;
  }

  resolveDoubt(id: string): Doubt | undefined {
    for (const notebook of this.db.notebooks) for (const page of notebook.pages) {
      const doubt = page.doubts.find((d) => d.id === id);
      if (!doubt) continue;
      if (!doubt.resolvedAt) {
        doubt.resolvedAt = now();
        page.updatedAt = now();
        this.save();
        this.emit({ type: "doubts", notebookId: notebook.id, pageId: page.id, doubts: page.doubts });
      }
      return doubt;
    }
  }

  searchNotes(query: string) {
    const needle = query.trim().toLocaleLowerCase();
    if (!needle) return [];
    return this.db.notebooks.flatMap((notebook) => notebook.pages.flatMap((page, index) =>
      page.textBoxes.filter((box) => box.text.toLocaleLowerCase().includes(needle)).map((box) => ({
        notebookId: notebook.id, notebookTitle: notebook.title, pageId: page.id, pageNumber: index + 1, box,
      })),
    ));
  }

  revealHint(pageId: string, itemId: string) {
    const found = this.findPage(pageId);
    if (!found) return;
    const item = found.page.claudeLayer.find((i) => i.id === itemId);
    if (!item || item.type !== "hint") return;
    if (!item.revealed) {
      Object.assign(item, renderHandwriting(item.text, item.x, item.y, item.size ?? 32), { revealed: true });
      found.page.updatedAt = now();
      this.save();
      this.emit({ type: "claudeLayer", notebookId: found.notebook.id, pageId });
    }
    return item;
  }

  createNotebook(title: string, pageCount = 1, background: Background = "blank", options: { folderId?: string; scratch?: boolean } = {}): Notebook {
    if (options.folderId && !this.getFolder(options.folderId)) throw new RangeError(`No folder ${options.folderId}`);
    const nb: Notebook = {
      id: nanoid(10),
      title,
      pages: Array.from({ length: Math.max(1, pageCount) }, () => this.newPage(background)),
      createdAt: now(),
      updatedAt: now(),
      ...(options.folderId ? { folderId: options.folderId } : {}),
      ...(options.scratch ? { scratch: true } : {}),
    };
    this.db.notebooks.push(nb);
    this.save();
    this.emit({ type: "notebook", notebookId: nb.id });
    return nb;
  }

  /** One page per PDF page. Appends to `notebookId` if given, else makes a new notebook titled `title`. */
  addPdfPages(file: string, count: number, title: string, notebookId?: string, folderId?: string) {
    const pages = Array.from({ length: count }, (_, i) => ({ ...this.newPage("blank"), pdf: { file, page: i + 1 } }));
    if (notebookId) {
      const at = this.insertPages(notebookId, pages);
      return { notebook: this.getNotebook(notebookId)!, firstIndex: at };
    }
    const nb = this.createNotebook(title, 1, "blank", { folderId });
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

  /** Target ids and a named group without affecting neighboring items. */
  removeClaudeItemsByIds(pageId: string, ids: string[], group?: string) {
    const found = this.findPage(pageId);
    if (!found) throw new Error(`No page ${pageId}`);
    const selected = new Set(ids);
    const before = found.page.claudeLayer.length;
    found.page.claudeLayer = found.page.claudeLayer.filter((item) => !selected.has(item.id) && !(group !== undefined && item.group === group));
    const removed = before - found.page.claudeLayer.length;
    if (removed) {
      found.page.updatedAt = now();
      this.save();
      this.emit({ type: "claudeLayer", notebookId: found.notebook.id, pageId });
    }
    return removed;
  }

  moveClaudeItems(pageId: string, ids: string[], dx: number, dy: number): Item[] {
    const found = this.findPage(pageId);
    if (!found) throw new Error(`No page ${pageId}`);
    if (![dx, dy].every(Number.isFinite)) throw new Error("Move offsets must be finite numbers");
    const selected = new Set(ids);
    // Prepare every translation first so a malformed legacy path cannot leave a partial move.
    const moved = found.page.claudeLayer.filter((item) => selected.has(item.id)).map((item) => translateItem(item, dx, dy));
    if (moved.length) {
      const byId = new Map(moved.map((item) => [item.id, item]));
      found.page.claudeLayer = found.page.claudeLayer.map((item) => byId.get(item.id) ?? item);
      found.page.updatedAt = now();
      this.save();
      this.emit({ type: "claudeLayer", notebookId: found.notebook.id, pageId });
    }
    return moved;
  }
}

export type StoreEvent =
  | { type: "notebook"; notebookId: string }
  | { type: "folders" }
  | { type: "claudeLayer"; notebookId: string; pageId: string }
  | { type: "doubts"; notebookId: string; pageId: string; doubts: Doubt[] };
