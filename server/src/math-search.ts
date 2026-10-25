// A search key, not a mathematical parser: preserve operators while making
// common handwritten, Unicode and LaTeX spellings find the same notes.
const superscripts = "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱᵃᵇᶜᵈᵉᶠᵍʰʲᵏˡᵐᵒᵖʳˢᵗᵘᵛʷˣʸᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂᵅᵝᵞᵟᵋᶿᶥᶲᵠᵡ";
const subscripts = "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵦᵧᵨᵩᵪ";

function scripts(value: string, chars: string, marker: string) {
  const members = new Set([...chars]);
  let result = "", inScript = false;
  for (const char of value) {
    if (members.has(char)) {
      if (!inScript) result += marker;
      result += char.normalize("NFKC");
      inScript = true;
    } else {
      result += char;
      inScript = false;
    }
  }
  return result;
}

function bracedArgument(value: string, start: number) {
  if (value[start] !== "{") return;
  let depth = 0;
  for (let i = start; i < value.length; i++) {
    if (value[i] === "{") depth++;
    if (value[i] === "}" && --depth === 0) return { text: value.slice(start + 1, i), end: i + 1 };
  }
}

function fractions(value: string): string {
  // Fraction arguments may themselves contain script groups or fractions.
  // Read balanced braces before discarding them from the final search key.
  let result = "", from = 0;
  for (const match of value.matchAll(/\\(?:d?frac|tfrac)\{/g)) {
    const start = match.index;
    if (start < from) continue;
    const numerator = bracedArgument(value, start + match[0].length - 1);
    const denominator = numerator && bracedArgument(value, numerator.end);
    if (!numerator || !denominator) continue;
    result += value.slice(from, start) + fractions(numerator.text) + "/" + fractions(denominator.text);
    from = denominator.end;
  }
  return result + value.slice(from);
}

export function normalizeMathSearch(value: string): string {
  const key = scripts(scripts(value, superscripts, "^"), subscripts, "_")
    .toLowerCase()
    .replace(/\\(?:left|right)\b/g, "")
    .replace(/π|\\pi\b/g, "pi")
    .replace(/×|·|\\(?:times|cdot)\b/g, "*")
    .replace(/[−–]/g, "-").replace(/\s+/gu, "");
  return fractions(key).replace(/[{}]/g, "");
}
