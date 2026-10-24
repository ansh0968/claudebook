// Folders and scratch pads, through the app's REST API, Claude's tools, and the expiry sweep.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { SCRATCH_TTL_MS, Store } from "./store.js";

const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787";
const secret = process.env.CLAUDEBOOK_SECRET!;
const api = async (path: string, init: RequestInit = {}) => {
  const res = await fetch(`${base}/api${path}`, { ...init, headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json", ...init.headers } });
  return { status: res.status, body: (await res.json().catch(() => ({}))) as any };
};
const post = (path: string, body: unknown) => api(path, { method: "POST", body: JSON.stringify(body) });
const patch = (path: string, body: unknown) => api(path, { method: "PATCH", body: JSON.stringify(body) });
function assert(ok: unknown, message: string): asserts ok {
  if (!ok) throw new Error(message);
}

// Folders: create, nest, refuse cycles, delete without losing notebooks.
const subject = await post("/folders", { name: "  Chemistry  " });
assert(subject.status === 201 && subject.body.name === "Chemistry", "folder name should be trimmed");
const topic = await post("/folders", { name: "Organic", parentId: subject.body.id });
assert(topic.body.parentId === subject.body.id, "subfolder should keep its parent");
assert((await post("/folders", { name: " " })).status === 400, "blank folder names should be refused");
assert((await post("/folders", { name: "Orphan", parentId: "nope" })).status === 400, "unknown parents should be refused");
assert((await patch(`/folders/${subject.body.id}`, { parentId: topic.body.id })).status === 400, "a folder can't move inside its own child");

const filed = await post("/notebooks", { title: "Alkenes", folderId: topic.body.id });
assert(filed.body.folderId === topic.body.id, "notebook should be created inside the folder");
const loose = await post("/notebooks", { title: "Loose notes" });
const moved = await patch(`/notebooks/${loose.body.id}`, { folderId: subject.body.id });
assert(moved.status === 200 && moved.body.folderId === subject.body.id, "notebook should move into a folder");
assert(moved.body.updatedAt === loose.body.updatedAt, "filing a notebook shouldn't count as an edit");
const unfiled = await patch(`/notebooks/${loose.body.id}`, { folderId: "" });
assert(unfiled.body.folderId === undefined, "empty folderId should move a notebook to the top level");
assert((await patch(`/notebooks/${loose.body.id}`, { folderId: "nope" })).status === 400, "unknown folders should be refused");
assert((await patch(`/notebooks/${loose.body.id}`, {})).status === 400, "an empty patch should be refused");

assert((await api(`/folders/${topic.body.id}`, { method: "DELETE" })).status === 200, "folder delete failed");
const afterDelete = await api("/notebooks");
assert(afterDelete.body.notebooks.find((n: any) => n.id === filed.body.id)?.folderId === subject.body.id, "notebooks should move up when their folder is deleted");
assert(!afterDelete.body.folders.some((f: any) => f.id === topic.body.id), "deleted folder should be gone");

// Scratch pads: one call to make, carry an expiry, can be kept and filed.
const scratch = await post("/notebooks", { scratch: true });
assert(scratch.body.scratch === true && scratch.body.title === "Scratch pad" && scratch.body.pages[0].background === "grid", "scratch pad defaults");
const expires = Date.parse(scratch.body.expiresAt) - Date.parse(scratch.body.updatedAt);
assert(Math.abs(expires - SCRATCH_TTL_MS) < 1000, "scratch pads should expire a week after their last edit");
assert((await post("/notebooks", { scratch: true, folderId: subject.body.id })).status === 400, "scratch pads live outside folders");
assert((await patch(`/notebooks/${scratch.body.id}`, { folderId: subject.body.id })).status === 400, "filing a scratch pad needs it kept first");
assert((await patch(`/notebooks/${scratch.body.id}`, { scratch: true })).status === 400, "only scratch: false is allowed");
const kept = await patch(`/notebooks/${scratch.body.id}`, { scratch: false, title: "Kept idea", folderId: subject.body.id });
assert(kept.status === 200 && kept.body.scratch === undefined && kept.body.expiresAt === undefined && kept.body.folderId === subject.body.id, "keeping a scratch pad should make it a normal notebook");

// Claude's tools see the folder tree and can file things by name.
const client = new Client({ name: "folders-selftest", version: "0" });
await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp/${secret}`)));
const call = async (name: string, args: Record<string, unknown>) => {
  const r = (await client.callTool({ name, arguments: args })) as { content: { type: string; text?: string }[]; isError?: boolean };
  if (r.isError) throw new Error(`${name} failed: ${r.content[0]?.text}`);
  return r.content.map((c) => c.text ?? "").join("\n");
};
const made = await call("create_notebook", { title: "Kinematics", folder: "Physics/Mechanics" });
assert(made.includes('folder "Physics/Mechanics"'), "create_notebook should create the folder path");
const tree = await api("/notebooks");
const physics = tree.body.folders.find((f: any) => f.name === "Physics" && !f.parentId);
const mechanics = tree.body.folders.find((f: any) => f.name === "Mechanics" && f.parentId === physics?.id);
assert(mechanics && tree.body.notebooks.some((n: any) => n.title === "Kinematics" && n.folderId === mechanics.id), "Kinematics should sit in Physics/Mechanics");
await call("create_notebook", { title: "Projectiles", folder: "physics/MECHANICS" });
assert((await api("/notebooks")).body.folders.filter((f: any) => f.name === "Mechanics").length === 1, "folder names should match case insensitively");
const pad = await post("/notebooks", { scratch: true });
await call("move_notebook", { notebook_id: pad.body.id, folder: "Chemistry" });
const padAfter = (await api(`/notebooks/${pad.body.id}`)).body;
const padFolder = (await api("/notebooks")).body.folders.find((f: any) => f.id === padAfter.folderId);
assert(padFolder?.name === "Chemistry" && !padFolder.parentId && !padAfter.scratch, "move_notebook should keep a scratch pad it files");
await post("/notebooks", { scratch: true, title: "Quick sum" });
const listed = await call("list_notebooks", {});
assert(listed.includes('Folder "Physics"') && listed.includes('  - Folder "Mechanics"') && listed.includes("Scratch pads (temporary):"), `list_notebooks should show folders and scratch pads:\n${listed}`);
await client.close();

// The sweep deletes stale scratch pads only, and never the one open right now.
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-scratch-"));
const seeded = new Store(dir);
const stale = seeded.createNotebook("Stale", 1, "grid", { scratch: true });
const onScreen = seeded.createNotebook("On screen", 1, "grid", { scratch: true });
const fresh = seeded.createNotebook("Fresh", 1, "grid", { scratch: true });
const old = seeded.createNotebook("Old but kept");
// Backdate everything but the fresh pad by eight days, as if nobody had touched them since.
const dbFile = path.join(dir, "db.json");
const db = JSON.parse(fs.readFileSync(dbFile, "utf8"));
const eightDaysAgo = new Date(Date.now() - SCRATCH_TTL_MS - 24 * 60 * 60 * 1000).toISOString();
for (const nb of db.notebooks) if (nb.id !== fresh.id) {
  nb.updatedAt = eightDaysAgo;
  for (const page of nb.pages) page.updatedAt = eightDaysAgo;
}
fs.writeFileSync(dbFile, JSON.stringify(db));
const store = new Store(dir);
store.setView(onScreen.id, onScreen.pages[0].id);
const purged = store.purgeExpiredScratchPads();
assert(purged.length === 1 && purged[0] === "Stale" && !store.getNotebook(stale.id), `only the stale scratch pad should go, got ${JSON.stringify(purged)}`);
assert(store.getNotebook(onScreen.id) && store.getNotebook(fresh.id) && store.getNotebook(old.id), "open, fresh and normal notebooks should stay");
fs.rmSync(dir, { recursive: true, force: true });
console.log("[folders] folders, scratch pads and the expiry sweep work");
