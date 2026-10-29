// This data is also bundled by ios/project.yml. Keep all new geometry and colours here.
import templates from "./paper-templates.json" with { type: "json" };
export const paperTemplates = templates;
export const backgrounds = Object.keys(templates.templates) as [keyof typeof templates.templates, ...Array<keyof typeof templates.templates>];
export const papers = Object.keys(templates.papers) as [keyof typeof templates.papers, ...Array<keyof typeof templates.papers>];
export type Background = keyof typeof templates.templates;
export type Paper = keyof typeof templates.papers;
export const isBackground = (value: unknown): value is Background => typeof value === "string" && Object.hasOwn(templates.templates, value);
export const isPaper = (value: unknown): value is Paper => typeof value === "string" && Object.hasOwn(templates.papers, value);
export const paperColor = (paper: Paper = "default") => templates.papers[paper].color;
export const darkPaper = (paper: Paper = "default") => templates.papers[paper].dark;
export function paperRegions(background: Background): string[] {
  return (templates.templates[background] as { regions?: string[] }).regions ?? [];
}
type Primitive = { kind: string; x: number; y: number; x2?: number; y2?: number; width?: number; role: string; r?: number; dash?: number[] };
export function paperPatternSvg(background: Background, paper: Paper = "default") {
  const palette = templates.palettes[darkPaper(paper) ? "dark" : "light"];
  return (templates.templates[background].primitives as Primitive[]).map(p => {
    const color = palette[p.role as keyof typeof palette];
    return p.kind === "dot" ? `<circle cx="${p.x}" cy="${p.y}" r="${p.r}" fill="${color}"/>`
      : `<line x1="${p.x}" y1="${p.y}" x2="${p.x2}" y2="${p.y2}" stroke="${color}" stroke-width="${p.width}"${p.dash ? ` stroke-dasharray="${p.dash.join(" ")}"` : ""}/>`;
  }).join("");
}
