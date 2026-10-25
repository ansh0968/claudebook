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

export function normalizeMathSearch(value: string): string {
  let key = scripts(scripts(value, superscripts, "^"), subscripts, "_")
    .toLowerCase()
    .replace(/\\(?:left|right)\b/g, "")
    .replace(/π|\\pi\b/g, "pi")
    .replace(/×|·|\\(?:times|cdot)\b/g, "*")
    .replace(/[−–]/g, "-").replace(/\s+/gu, "");
  // Reduce innermost fractions first, so nested fractions also lose their
  // LaTeX wrappers without a regex mistaking a brace for an argument boundary.
  let previous: string;
  do {
    previous = key;
    key = key.replace(/\\(?:d?frac|tfrac)\{([^{}]*)\}\{([^{}]*)\}/g, "$1/$2");
  } while (key !== previous);
  return key.replace(/[{}]/g, "");
}
