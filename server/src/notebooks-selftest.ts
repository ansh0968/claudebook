// Renaming and deleting notebooks from the app's library.
const base = process.env.CLAUDEBOOK_URL ?? "http://localhost:8787";
const secret = process.env.CLAUDEBOOK_SECRET!;
const api = async (path: string, init: RequestInit = {}) => {
  const res = await fetch(`${base}/api${path}`, { ...init, headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json", ...init.headers } });
  return { status: res.status, body: (await res.json().catch(() => ({}))) as any };
};

const made = await api("/notebooks", { method: "POST", body: JSON.stringify({ title: "Temp", pages: 2 }) });
const id = made.body.id as string;
const renamed = await api(`/notebooks/${id}`, { method: "PATCH", body: JSON.stringify({ title: "  Renamed  " }) });
if (renamed.status !== 200 || renamed.body.title !== "Renamed") throw new Error("rename should trim and save the title");
if ((await api(`/notebooks/${id}`, { method: "PATCH", body: JSON.stringify({ title: " " }) })).status !== 400) throw new Error("blank titles should be refused");
if ((await api(`/notebooks/${id}`, { method: "DELETE" })).status !== 200) throw new Error("delete failed");
if ((await api(`/notebooks/${id}`)).status !== 404) throw new Error("deleted notebook should be gone");
if ((await api(`/notebooks/${id}`, { method: "DELETE" })).status !== 404) throw new Error("second delete should 404");
console.log("[notebooks] rename and delete work");
