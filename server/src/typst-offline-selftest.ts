import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { buildMcpServer } from "./mcp.js";
import { Store } from "./store.js";
import { TYPST_IMPORTS, TYPST_PACKAGES, typstFailureMessage } from "./typst-packages.js";

const source = '#import "@preview/fletcher:0.5.0": diagram';
const expected = `Package @preview/fletcher:0.5.0 isn't available offline. Available: ${TYPST_PACKAGES.join(", ")}`;
assert.equal(typstFailureMessage(source, "main.typ:1:8: error: failed to download package (Network Error: OpenSSL error)"), expected);
assert.equal(typstFailureMessage(source, "error: failed to download package @preview/fletcher:0.5.0"), expected);
assert.equal(typstFailureMessage(source, "main.typ:1:8: error: unknown variable"), "main.typ:1:8: error: unknown variable");
assert.ok(TYPST_PACKAGES.includes("@preview/cetz:0.3.2"));
assert.ok(TYPST_PACKAGES.includes("@preview/cetz-plot:0.1.1"));
assert.ok(TYPST_IMPORTS.includes("@preview/cetz:0.4.0") && !TYPST_IMPORTS.includes("0.3.2"));
console.log("[Typst offline] readable package errors and default/compatibility pins passed");

const has = (bin: string, args: string[]) => {
  try { execFileSync(bin, args, { stdio: "ignore", timeout: 5000 }); return true; } catch { return false; }
};
if (has(process.env.TYPST_BIN ?? "typst", ["--version"]) && has("pdfinfo", ["-v"])) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claudebook-offline-"));
  const store = new Store(dir), server = buildMcpServer(store), client = new Client({ name: "typst-offline-selftest", version: "1" });
  const [ct, st] = InMemoryTransport.createLinkedPair();
  await server.connect(st); await client.connect(ct);
  try {
    for (const version of ["0.3.2", "0.4.0"]) {
      const result = await client.callTool({ name: "create_pdf", arguments: { title: `CeTZ ${version}`, typst: `#import "@preview/cetz:${version}": canvas, draw\n#canvas({ draw.line((0,0),(2,1)); draw.circle((1,1),radius:0.4) })` } });
      assert.ok(!result.isError, JSON.stringify(result.content));
      assert.equal(store.listNotebooks().find(n => n.title === `CeTZ ${version}`)?.pages.length, 1);
    }
    // Isolate the package cache and refuse network connections, even on online CI runners.
    const env = { TYPST_PACKAGE_CACHE_PATH: path.join(dir, "empty-cache"), HTTPS_PROXY: "http://127.0.0.1:1", HTTP_PROXY: "http://127.0.0.1:1", ALL_PROXY: "http://127.0.0.1:1" };
    const previous = Object.fromEntries(Object.keys(env).map(k => [k, process.env[k]]));
    try {
      Object.assign(process.env, env);
      const result = await client.callTool({ name: "create_pdf", arguments: { title: "Unavailable", typst: source } });
      assert.ok(result.isError);
      assert.equal((result.content as { text: string }[])[0].text, `Typst error:\n${expected}`);
      assert.ok(!store.listNotebooks().some(n => n.title === "Unavailable"));
    } finally {
      for (const [key, value] of Object.entries(previous)) if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    console.log("[Typst offline MCP] create_pdf CeTZ 0.3.2/0.4.0 and unavailable-package error passed");
  } finally { await client.close(); await server.close(); fs.rmSync(dir, { recursive: true, force: true }); }
} else console.log("SKIP Typst offline MCP checks (Typst/pdfinfo not installed)");
