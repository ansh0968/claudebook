import assert from "node:assert/strict";
import { renderHandwriting, renderLegacyHandwriting } from "./handwriting.js";

// Rendering throws rather than emitting glyph zero; this exercises every
// required symbol through the same font selection used by saved page outlines.
const symbols = "ΔH ⇒ ⊖ ‡ ⑤ H₂O";
const result = renderHandwriting(symbols, 80, 100, 32);
assert.ok(result.d.length > 1000);
assert.ok(result.w > 100 && result.h === 32);
for (const character of symbols.replaceAll(" ", "")) {
  assert.ok(renderHandwriting(character, 0, 0).d, `No visible outline for ${character}`);
}
assert.equal(renderHandwriting("H₂O", 0, 0).d, renderHandwriting("H_2O", 0, 0).d);
assert.equal(renderHandwriting("x²", 0, 0).d, renderHandwriting("x^{2}", 0, 0).d);
assert.equal(renderHandwriting("OH⁻", 0, 0).d, renderHandwriting("OH^-", 0, 0).d);
assert.ok(renderHandwriting("SO_{4}^{2-}", 0, 0).w > 0);
assert.equal(renderHandwriting("first\nsecond", 0, 0, 36).h, 72);
assert.throws(() => renderHandwriting("\u{10FFFF}", 0, 0), /No text font supports.*U\+10FFFF/);
assert.equal(renderLegacyHandwriting("Hello", 0, 0).unsupported, false);
const legacy = renderLegacyHandwriting("\u{10FFFF}", 0, 0);
assert.equal(legacy.unsupported, true);
assert.equal(legacy.d, renderHandwriting("[unsupported text]", 0, 0).d);
console.log("[font] Unicode fallbacks, scripts and unsupported-character errors passed");
