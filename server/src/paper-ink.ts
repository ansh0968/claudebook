// Matches ClaudeRenderer.adapt(_:dark:) on explicit dark paper; saved item colours stay untouched.
export function adaptPaperInk(svg: string) {
  return svg.replace(/\b(fill|stroke)="([^"]+)"/g, (attribute, name: string, value: string) => {
    const named: Record<string, string> = { black: "#000000", navy: "#000080", blue: "#0000ff", green: "#008000", purple: "#800080", maroon: "#800000" };
    let hex = named[value.toLowerCase()] ?? value;
    if (/^#[\da-f]{3}$/i.test(hex)) hex = "#" + [...hex.slice(1)].map(c => c + c).join("");
    if (!/^#[\da-f]{6}([\da-f]{2})?$/i.test(hex)) return attribute;
    const [r, g, b] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255);
    if (0.2126 * r + 0.7152 * g + 0.0722 * b >= 0.3) return attribute;
    const max = Math.max(r, g, b), min = Math.min(r, g, b), delta = max - min;
    const hue = delta === 0 ? 0 : ((max === r ? (g - b) / delta : max === g ? (b - r) / delta + 2 : (r - g) / delta + 4) + 6) % 6;
    const sat = (max === 0 ? 0 : delta / max) * 0.6, brightness = Math.max(0.85, 1 - max * 0.3);
    const c = brightness * sat, x = c * (1 - Math.abs(hue % 2 - 1)), m = brightness - c;
    const rgb = hue < 1 ? [c, x, 0] : hue < 2 ? [x, c, 0] : hue < 3 ? [0, c, x] : hue < 4 ? [0, x, c] : hue < 5 ? [x, 0, c] : [c, 0, x];
    return `${name}="#${rgb.map(v => Math.round((v + m) * 255).toString(16).padStart(2, "0")).join("")}${hex.slice(7)}"`;
  });
}
