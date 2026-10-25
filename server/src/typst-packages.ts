import fs from "node:fs";

// Tool guidance and offline errors come from the same pins Docker and CI compile.
const imports = fs.readFileSync(new URL("../typst-packages.typ", import.meta.url), "utf8")
  .split(/\r?\n/).filter(line => line.startsWith("#import "));
export const TYPST_PACKAGES = imports.map(line => line.match(/"(@preview\/[^\"]+)"/)![1]);
export const TYPST_IMPORTS = imports.filter(line => !line.includes("// offline-compat")).join("\n");
export const TYPST_COMPATIBILITY = "Prefer cetz:0.4.0 with cetz-plot:0.1.2. Compatibility cetz:0.3.2 and cetz-plot:0.1.1 also work offline; e.g. #import \"@preview/cetz:0.3.2\": canvas, draw.";

/** Short diagnostics name the import's source line, rather than the unavailable package. */
export function typstFailureMessage(source: string, stderr: string) {
  if (!/failed to download package/i.test(stderr)) return stderr.trim();
  const spec = /@preview\/[\w-]+:[\d.]+/;
  const line = stderr.match(/main\.typ:(\d+):\d+:/)?.[1];
  const name = stderr.match(spec)?.[0]
    ?? (line ? source.split(/\r?\n/)[Number(line) - 1]?.match(spec)?.[0] : undefined)
    ?? [...source.matchAll(/@preview\/[\w-]+:[\d.]+/g)].map(m => m[0]).find(p => !TYPST_PACKAGES.includes(p));
  return `Package ${name ?? "requested by this document"} isn't available offline. Available: ${TYPST_PACKAGES.join(", ")}`;
}
