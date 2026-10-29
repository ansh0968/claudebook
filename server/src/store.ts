import { sweepImages } from "./image-assets.js";
// Tiny file-backed store. One JSON file for metadata, PNGs on disk for page snapshots.
// Fine for a single user; swap for SQLite if it ever gets big.
import fs from "node:fs";
import path from "node:path";
import { nanoid } from "nanoid";
import type { Item } from "./items.js";
import { translateItem } from "./items.js";
import { renderHandwriting } from "./handwriting.js";
import { normalizeMathSearch } from "./math-search.js";

// Every page uses the same logical coordinate space so Claude can reason in round numbers.
// A4 ratio. The iPad app scales this to whatever size it draws at.
export const PAGE_W = 1000;
export const PAGE_H = 1414;

import { isBackground, isPaper, type Background, type Paper } from "./paper.js";
export type { Background, Paper } from "./paper.js";

export interface TextBox {
  text: string;
  /** Up to three Vision candidates, including the best candidate in text. */
  alts?: string[];
  confidence?: number;
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface PageRegion { x: number; y: number; w: number; h: number }

export interface Transcript {
  id: string;
  source: "claude";
  region: PageRegion;
  text: string;
  latex?: string;
  createdAt: string;
  snapshotVersion: number;
  strokeCount?: number;
  stale: boolean;
}

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
  paper?: Paper;
  /** The last snapshot contains the previous paper until the iPad refreshes it. */
  paperSnapshotStale?: boolean;
  /** Set when the page came from a PDF; the app renders the PDF page underneath the ink. */
  pdf?: { file: string; page: number };
  /** Bumped every time the app uploads a fresh snapshot of the user's ink. */
  snapshotVersion: number;
  /** When the app last uploaded this page's ink (snapshot or drawing), and how many strokes it had. */
  inkSyncedAt?: string;
  strokeCount?: number;
  /** Handwriting recognized on device, in page coordinates. */
  textBoxes: TextBox[];
  /** Claude's image readings survive Vision refreshes. */
  transcripts: Transcript[];
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
  /** Set when Claude asked to delete the notebook; the iPad asks the user and deletes or cancels. */
  deleteRequestedAt?: string;
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
    const existingDatabase = fs.existsSync(this.file);
    this.db = existingDatabase
      ? JSON.parse(fs.readFileSync(this.file, "utf8"))
      : { notebooks: [], folders: [], view: { notebookId: null, pageId: null, updatedAt: null } };
    this.db.folders ??= [];
    // Older db.json files have no doubts field. Normalize once so every API response has an array.
    for (const notebook of this.db.notebooks) for (const page of notebook.pages) {
      page.doubts ??= [];
      page.transcripts ??= [];
    }
    if (!existingDatabase) this.seed();
    sweepImages(this);
    this.sweepBlocks();
  }

  private seed() {
    const nb = this.createNotebook("First notebook", 1, "grid");
    this.setView(nb.id, nb.pages[0].id);
  }

  private save() {
    const tmp = this.file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(this.db, null, 1));
    fs.renameSync(tmp, this.file);
    sweepImages(this);
    this.sweepBlocks();
  }

  on(fn: (e: StoreEvent) => void) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private emit(e: StoreEvent) {
    for (const fn of this.listeners) {
      try { fn(e); }
      catch (error) { console.warn(`Live update listener failed: ${(error as Error).message}`); }
    }
  }

  listNotebooks() {
    return this.db.notebooks;
  }

  /** Rename a notebook. Returns undefined if it doesn't exist. */
  renameNotebook(id: string, title: string) {
    return this.updateNotebook(id, { title });
  }

  /** Ask the iPad to confirm deleting a notebook. Nothing is removed until the user agrees there. */
  requestDelete(id: string) {
    const nb = this.getNotebook(id);
    if (!nb) return;
    nb.deleteRequestedAt = now();
    this.save();
    this.emit({ type: "deleteRequest", notebookId: id });
    return nb;
  }

  cancelDeleteRequest(id: string) {
    const nb = this.getNotebook(id);
    if (!nb) return false;
    delete nb.deleteRequestedAt;
    this.save();
    this.emit({ type: "notebook", notebookId: id });
    return true;
  }

  /** Flip the iPad to a page. The app only hears this while it is open. */
  openPage(notebookId: string, pageId: string) {
    this.emit({ type: "openPage", notebookId, pageId });
  }

  /** Remove a notebook and its page files. PDFs stay, since another notebook may share one. */
  deleteNotebook(id: string) {
    const nb = this.getNotebook(id);
    if (!nb) return false;
    const previous = this.pageCheckpoint();
    this.db.notebooks = this.db.notebooks.filter((n) => n.id !== id);
    if (this.db.view.notebookId === id) this.db.view = { notebookId: null, pageId: null, updatedAt: now() };
    this.savePageChange(previous);
    for (const page of nb.pages) this.removePageFiles(page.id);
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

  private selectedPages(ids: string[]) {
    if (!ids.length || ids.length > 5000 || new Set(ids).size !== ids.length) throw new Error("Choose 1-5000 distinct page ids. Nothing was changed.");
    return ids.map(id => {
      const found = this.findPage(id);
      if (!found) throw new Error(`Page not found: ${id}. Nothing was changed.`);
      return found;
    });
  }

  private removePageFiles(id: string) {
    // Metadata is authoritative. A locked cache file must not turn a completed
    // deletion into a reported failure or make the notebook reappear on restart.
    for (const file of [this.snapshotPath(id), this.drawingPath(id)]) {
      try { fs.rmSync(file, { force: true }); }
      catch (e) { console.warn(`Could not remove deleted page cache ${id}: ${(e as Error).message}`); }
    }
  }

  private insertionCount(afterPage: number | undefined, count: number) {
    const at = afterPage ?? count;
    if (!Number.isInteger(at) || at < 0 || at > count) throw new Error(`after_page must be an integer from 0 to ${count}. Nothing was changed.`);
    return at;
  }

  /** Structural edits replace page arrays, never their ink/path payloads. */
  private pageCheckpoint(): DB {
    return { ...this.db, notebooks: this.db.notebooks.map(nb => ({ ...nb, pages: [...nb.pages] })), view: { ...this.db.view } };
  }

  private savePageChange(previous: DB) {
    try { this.save(); }
    catch (error) { this.db = previous; throw error; }
  }

  /** Preserve the selected page by id through reorders and cross-notebook moves. */
  private finishPageChange(notebooks: Notebook[], previousDatabase: DB, fallbackIndex = 0) {
    const previous = this.db.view;
    const current = previous.pageId ? this.findPage(previous.pageId) : undefined;
    const nb = current?.notebook ?? (previous.notebookId ? this.getNotebook(previous.notebookId) : undefined);
    const page = current?.page ?? nb?.pages[Math.min(fallbackIndex, Math.max(0, nb.pages.length - 1))];
    const notebookId = nb?.id ?? null, pageId = page?.id ?? null;
    const changed = notebookId !== previous.notebookId || pageId !== previous.pageId;
    if (changed) this.db.view = { notebookId, pageId, updatedAt: now() };
    for (const notebook of notebooks) notebook.updatedAt = now();
    this.savePageChange(previousDatabase);
    for (const notebook of notebooks) this.emit({ type: "notebook", notebookId: notebook.id });
    if (changed && notebookId && pageId) this.openPage(notebookId, pageId);
  }

  /** Remove exactly these pages, including ink. Empty notebooks stay empty. */
  deletePages(notebookId: string, ids: string[]): Notebook {
    const nb = this.getNotebook(notebookId);
    if (!nb) throw new Error("Notebook not found. Nothing was changed.");
    const selected = this.selectedPages(ids);
    if (selected.some(p => p.notebook.id !== nb.id)) throw new Error("All deleted page ids must belong to this notebook. Nothing was changed.");
    const previous = this.pageCheckpoint();
    const currentIndex = nb.pages.findIndex(p => p.id === this.db.view.pageId), chosen = new Set(ids);
    const survivingBefore = nb.pages.slice(0, Math.max(0, currentIndex)).filter(p => !chosen.has(p.id)).length;
    nb.pages = nb.pages.filter(p => !chosen.has(p.id));
    this.finishPageChange([nb], previous, survivingBefore);
    for (const { page } of selected) this.removePageFiles(page.id);
    return nb;
  }

  reorderPages(notebookId: string, ids: string[]): Notebook {
    const nb = this.getNotebook(notebookId);
    if (!nb) throw new Error("Notebook not found. Nothing was changed.");
    const byId = new Map(nb.pages.map(p => [p.id, p]));
    if (ids.length !== nb.pages.length || new Set(ids).size !== ids.length || ids.some(id => !byId.has(id))) throw new Error("page_ids must list every existing page exactly once. Nothing was changed.");
    const previous = this.pageCheckpoint();
    nb.pages = ids.map(id => byId.get(id)!);
    this.finishPageChange([nb], previous);
    return nb;
  }

  movePages(ids: string[], targetNotebookId: string, afterPage?: number) {
    const selected = this.selectedPages(ids), target = this.getNotebook(targetNotebookId);
    if (!target) throw new Error("Target notebook not found. Nothing was changed.");
    const chosen = new Set(ids), remaining = target.pages.filter(p => !chosen.has(p.id));
    const at = this.insertionCount(afterPage, remaining.length);
    const previous = this.pageCheckpoint();
    const affected = [...new Set([...selected.map(p => p.notebook), target])];
    for (const nb of affected) nb.pages = nb.pages.filter(p => !chosen.has(p.id));
    const pages = selected.map(p => p.page);
    target.pages.splice(at, 0, ...pages);
    this.finishPageChange(affected, previous);
    return { notebook: target, pages };
  }

  duplicatePages(ids: string[], targetNotebookId?: string, afterPage?: number) {
    const selected = this.selectedPages(ids), target = this.getNotebook(targetNotebookId ?? selected[0].notebook.id);
    if (!target) throw new Error("Target notebook not found. Nothing was changed.");
    const at = this.insertionCount(afterPage, target.pages.length), copiedFiles: string[] = [];
    const previous = this.pageCheckpoint();
    let pages: Page[];
    try {
      pages = selected.map(({ page }) => {
        const copy = structuredClone(page);
        copy.id = nanoid(10); copy.updatedAt = now();
        const itemIds = new Map(copy.claudeLayer.map(i => [i.id, nanoid(8)]));
        for (const item of copy.claudeLayer) {
          item.id = itemIds.get(item.id)!; item.createdAt = now();
          if ("axes" in item && item.axes && itemIds.has(item.axes)) item.axes = itemIds.get(item.axes)!;
        }
        copy.doubts = copy.doubts.map(d => ({ ...d, id: nanoid(10), pageId: copy.id, createdAt: now() }));
        copy.transcripts = copy.transcripts.map(t => ({ ...t, id: nanoid(10) }));
        for (const file of [this.snapshotPath.bind(this), this.drawingPath.bind(this)]) {
          if (fs.existsSync(file(page.id))) {
            copiedFiles.push(file(copy.id));
            fs.copyFileSync(file(page.id), file(copy.id));
          }
        }
        return copy;
      });
      target.pages.splice(at, 0, ...pages);
      this.finishPageChange([target], previous);
    } catch (e) {
      for (const file of copiedFiles) fs.rmSync(file, { force: true });
      throw e;
    }
    return { notebook: target, pages };
  }

  newPage(background: Background = "blank", paper?: Paper): Page {
    return { id: nanoid(10), background, ...(paper === undefined ? {} : { paper }), snapshotVersion: 0, textBoxes: [], transcripts: [], doubts: [], claudeLayer: [], updatedAt: now() };
  }

  /** Validate the whole selection before changing anything; preserve ink and PDFs. */
  setBackground(pageIds: string[], background?: Background, paper?: Paper) {
    if (background === undefined && paper === undefined) throw new Error("Send background and/or paper");
    if (background !== undefined && !isBackground(background)) throw new Error("Invalid background");
    if (paper !== undefined && !isPaper(paper)) throw new Error("Invalid paper");
    const found = [...new Set(pageIds)].map(id => { const page = this.findPage(id); if (!page) throw new Error(`No page ${id}`); return page; });
    for (const { page, notebook } of found) {
      if (background !== undefined) page.background = background;
      if (paper !== undefined) page.paper = paper;
      if (fs.existsSync(this.snapshotPath(page.id))) page.paperSnapshotStale = true;
      page.updatedAt = notebook.updatedAt = now();
    }
    this.save();
    for (const id of new Set(found.map(f => f.notebook.id))) this.emit({ type: "notebook", notebookId: id });
    return found.map(f => f.page);
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
    const needle = normalizeMathSearch(query);
    if (!needle) return [];
    return this.db.notebooks.flatMap(notebook => notebook.pages.flatMap((page, index) => {
      const location = { notebookId: notebook.id, notebookTitle: notebook.title, pageId: page.id, pageNumber: index + 1 };
      const matches = (value: string) => normalizeMathSearch(value).includes(needle);
      return [
        ...page.transcripts.filter(t => matches(t.text) || (t.latex !== undefined && matches(t.latex))).map(t => ({
          ...location, source: "claude" as const, stale: t.stale, transcript: t,
          box: { ...t.region, text: t.text },
        })),
        ...page.textBoxes.filter(b => matches(b.text) || b.alts?.some(matches)).map(box => ({
          ...location, source: "vision" as const, box,
        })),
      ];
    }));
  }

  /** Saving the same rectangle replaces its reading and clears its stale flag. */
  setTranscript(pageId: string, region: PageRegion, text: string, latex?: string): Transcript {
    const found = this.findPage(pageId);
    if (!found) throw new Error(`No page ${pageId}`);
    if (![region.x, region.y, region.w, region.h].every(Number.isFinite) || region.x < 0 || region.y < 0 ||
      region.w <= 0 || region.h <= 0 || region.x + region.w > PAGE_W || region.y + region.h > PAGE_H) {
      throw new RangeError(`Transcript region must fit within ${PAGE_W} x ${PAGE_H} page coordinates`);
    }
    if (!text.trim()) throw new Error("Transcript text must not be empty");
    const page = found.page;
    const at = page.transcripts.findIndex(t => t.region.x === region.x && t.region.y === region.y && t.region.w === region.w && t.region.h === region.h);
    const transcript: Transcript = {
      id: at < 0 ? nanoid(10) : page.transcripts[at].id, source: "claude", region: { ...region }, text,
      ...(latex === undefined ? {} : { latex }), createdAt: now(), snapshotVersion: page.snapshotVersion,
      ...(page.strokeCount === undefined ? {} : { strokeCount: page.strokeCount }), stale: false,
    };
    if (at < 0) page.transcripts.push(transcript);
    else page.transcripts[at] = transcript;
    page.updatedAt = now();
    this.save();
    return transcript;
  }

  private invalidateTranscripts(page: Page, strokeCount?: number) {
    // Uploads expose only a page-wide stroke count, not per-region ink. Flag
    // every reading on count changes; equal-count replacements cannot be detected.
    // Missing counts cannot prove freshness, so those uploads are conservative too.
    for (const t of page.transcripts) {
      if (strokeCount === undefined || t.strokeCount === undefined || strokeCount !== t.strokeCount) t.stale = true;
    }
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

  createNotebook(title: string, pageCount = 1, background: Background = "blank", options: { folderId?: string; scratch?: boolean; paper?: Paper } = {}): Notebook {
    if (options.folderId && !this.getFolder(options.folderId)) throw new RangeError(`No folder ${options.folderId}`);
    const nb: Notebook = {
      id: nanoid(10),
      title,
      pages: Array.from({ length: Math.max(1, pageCount) }, () => this.newPage(background, options.paper)),
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
    if (afterIndex !== undefined && (!Number.isInteger(afterIndex) || afterIndex < -1 || afterIndex >= nb.pages.length)) throw new Error(`afterIndex must be from -1 to ${nb.pages.length - 1}`);
    const at = afterIndex === undefined ? nb.pages.length : afterIndex + 1;
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
    if (this.findPage(pageId)?.notebook.id !== notebookId) throw new Error("Page does not belong to this notebook");
    this.db.view = { notebookId, pageId, updatedAt: now() };
    this.save();
  }

  snapshotPath(pageId: string) {
    return path.join(this.snapshotsDir, `${pageId}.png`);
  }

  saveSnapshot(pageId: string, png: Buffer, textBoxes?: TextBox[], strokeCount?: number) {
    const found = this.findPage(pageId);
    if (!found) throw new Error(`No page ${pageId}`);
    fs.writeFileSync(this.snapshotPath(pageId), png);
    delete found.page.paperSnapshotStale;
    this.invalidateTranscripts(found.page, strokeCount);
    found.page.snapshotVersion++;
    found.page.inkSyncedAt = now();
    if (strokeCount !== undefined) found.page.strokeCount = strokeCount;
    if (textBoxes) found.page.textBoxes = textBoxes;
    found.page.updatedAt = now();
    this.save();
  }

  /** Raw PKDrawing bytes from the app, kept as a backup so ink survives an app reinstall. */
  drawingPath(pageId: string) {
    return path.join(this.drawingsDir, `${pageId}.pkdrawing`);
  }

  saveDrawing(pageId: string, data: Buffer, strokeCount?: number) {
    const found = this.findPage(pageId);
    if (!found) throw new Error(`No page ${pageId}`);
    fs.writeFileSync(this.drawingPath(pageId), data);
    this.invalidateTranscripts(found.page, strokeCount);
    found.page.inkSyncedAt = now();
    if (strokeCount !== undefined) found.page.strokeCount = strokeCount;
    this.save();
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

  replaceClaudeItem(pageId: string, item: Item) {
    const found = this.findPage(pageId);
    if (!found || !found.page.claudeLayer.some(i => i.id === item.id)) throw new Error("Block not found");
    found.page.claudeLayer = found.page.claudeLayer.map(i => i.id === item.id ? item : i);
    found.page.updatedAt = now();
    this.save();
    this.emit({ type: "claudeLayer", notebookId: found.notebook.id, pageId });
  }

  /** Content-addressed blocks/posters are shared by copies; only unreferenced assets can be removed. */
  sweepBlocks() {
    const referenced = new Set<string>();
    for (const notebook of this.db.notebooks) for (const page of notebook.pages) for (const item of page.claudeLayer) {
      if (item.type === "web") { referenced.add(item.file); if (item.poster) referenced.add(item.poster); }
    }
    const directory = path.join(this.dataDir, "blocks");
    try {
      if (fs.existsSync(directory)) for (const file of fs.readdirSync(directory)) {
        if (/^[a-f0-9]{64}\.(html|png)$/.test(file) && !referenced.has(file)) fs.unlinkSync(path.join(directory, file));
      }
    } catch (error) {
      // Metadata is already saved. Retry cleanup later rather than fail an unrelated edit.
      console.warn("Block cleanup deferred:", (error as Error).message);
    }
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

  /** Duplicate items (new ids, same group) onto this or another page, shifted by dx,dy. Unknown ids are ignored. */
  copyClaudeItems(pageId: string, ids: string[], dx: number, dy: number, targetPageId = pageId): Item[] {
    const source = this.findPage(pageId), target = this.findPage(targetPageId);
    if (!source || !target) throw new Error(`No page ${source ? targetPageId : pageId}`);
    const selected = new Set(ids);
    // In the order Claude listed them, so the returned ids line up with the request.
    const byId = new Map(source.page.claudeLayer.filter((item) => selected.has(item.id)).map((item) => [item.id, item]));
    const copies = ids.flatMap((id) => byId.has(id) ? [{ ...translateItem(byId.get(id)!, dx, dy), id: nanoid(8), createdAt: now() }] : []);
    if (copies.length) this.addClaudeItems(target.page.id, copies);
    return copies;
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
  | { type: "deleteRequest"; notebookId: string }
  | { type: "openPage"; notebookId: string; pageId: string }
  | { type: "folders" }
  | { type: "claudeLayer"; notebookId: string; pageId: string }
  | { type: "doubts"; notebookId: string; pageId: string; doubts: Doubt[] };
