import fs from "node:fs";

// Tool guidance comes from the same pins Docker and CI actually compile.
export const TYPST_IMPORTS = fs.readFileSync(new URL("../typst-packages.typ", import.meta.url), "utf8")
  .split(/\r?\n/).filter(line => line.startsWith("#import ")).join("\n");
