// Shared bounded downloader. Pin validated DNS answers so redirects and DNS rebinding
// cannot turn a public image/PDF URL into a request to the server's private network.
import { lookup } from "node:dns/promises";
import https from "node:https";
import http from "node:http";
import { isIP } from "node:net";

export function publicAddress(address: string): boolean {
  if (isIP(address) === 4) {
    const [a, b, c] = address.split(".").map(Number);
    return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
      a === 100 && b >= 64 && b <= 127 || a === 169 && b === 254 ||
      a === 172 && b >= 16 && b <= 31 || a === 192 && (b === 168 || b === 0 || b === 2) ||
      a === 198 && (b === 18 || b === 19 || b === 51 && c === 100) || a === 203 && b === 0 && c === 113);
  }
  // Only global unicast IPv6. This also excludes IPv4-mapped and transition
  // addresses (which can tunnel a private IPv4 destination).
  if (isIP(address) !== 6 || !/^[23][0-9a-f]{3}:/i.test(address)) return false;
  const groups = address.toLowerCase().split(":");
  const second = parseInt(groups[1] || "0", 16);
  return !(groups[0] === "2001" && (second < 0x200 || second === 0xdb8) || groups[0] === "2002" || groups[0] === "3fff");
}

async function lookupWithinDeadline(host: string, signal: AbortSignal) {
  signal.throwIfAborted();
  return new Promise<{ address: string; family: number }[]>((resolve, reject) => {
    const aborted = () => reject(new Error("Download timed out after 60s"));
    signal.addEventListener("abort", aborted, { once: true });
    lookup(host, { all: true }).then(resolve, reject).finally(() => signal.removeEventListener("abort", aborted));
  });
}

export interface DownloadOptions {
  maxBytes: number;
  label: string;
  /** Direct unit tests only; no environment variable or tool argument enables it. */
  testOnlyAllowLocalHttp?: boolean;
}

export async function downloadBytes(url: string, options: DownloadOptions): Promise<Buffer> {
  const signal = AbortSignal.timeout(60_000);
  let next = new URL(url);
  for (let redirects = 0; redirects <= 5; redirects++) {
    const host = next.hostname.replace(/^\[|\]$/g, "");
    const testLocal = options.testOnlyAllowLocalHttp === true && ["127.0.0.1", "::1"].includes(host);
    if (next.protocol !== "https:" && !(testLocal && next.protocol === "http:")) throw new Error("Only https URLs are allowed");
    if (next.username || next.password) throw new Error("URL credentials aren't allowed");
    if (!testLocal && (!isIP(host) && (!host.includes(".") || /(?:^|\.)(?:localhost|local|internal|home)\.?$/i.test(host)))) throw new Error("That private/local host isn't allowed");
    signal.throwIfAborted();
    const addresses = isIP(host) ? [{ address: host, family: isIP(host) }] : await lookupWithinDeadline(host, signal);
    if (!addresses.length || !testLocal && addresses.some(a => !publicAddress(a.address))) throw new Error("That private/local host isn't allowed");
    const pinned = addresses[0];
    const response = await new Promise<http.IncomingMessage>((resolve, reject) => {
      const request = (next.protocol === "https:" ? https : http).get(next, {
        signal,
        lookup: ((_hostname: string, opts: { all?: boolean }, callback: Function) => opts.all
          ? callback(null, [pinned]) : callback(null, pinned.address, pinned.family)) as any,
      }, resolve);
      request.on("error", reject);
    });
    if ([301, 302, 303, 307, 308].includes(response.statusCode ?? 0)) {
      response.destroy();
      if (!response.headers.location) throw new Error("Download redirect has no location");
      next = new URL(response.headers.location, next);
      continue;
    }
    const oversized = () => new Error(`${options.label} is larger than ${options.maxBytes / 1024 / 1024}MB`);
    if (response.statusCode !== 200) { response.destroy(); throw new Error(`Download failed: HTTP ${response.statusCode}`); }
    if (Number(response.headers["content-length"] ?? 0) > options.maxBytes) { response.destroy(); throw oversized(); }
    const chunks: Buffer[] = []; let size = 0;
    for await (const chunk of response) {
      size += chunk.length;
      if (size > options.maxBytes) { response.destroy(); throw oversized(); }
      chunks.push(Buffer.from(chunk));
    }
    return Buffer.concat(chunks);
  }
  throw new Error("Too many download redirects");
}
