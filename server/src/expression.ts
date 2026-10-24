// A closed arithmetic grammar: expressions never access JavaScript objects or code.
type Expr = (value: number) => number;
const functions: Record<string, (x: number) => number> = {
  sin: Math.sin, cos: Math.cos, tan: Math.tan, asin: Math.asin, acos: Math.acos, atan: Math.atan,
  sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh, log: Math.log10, ln: Math.log,
  exp: Math.exp, sqrt: Math.sqrt, abs: Math.abs, floor: Math.floor, ceil: Math.ceil,
};
export function parseExpression(source: string, variable: "x" | "t" = "x"): Expr {
  if (source.length > 2000) throw new Error("Expression exceeds 2000 characters at position 2000");
  let pos = 0, depth = 0;
  let token = "", tokenPos = 0;
  const error = (message: string): never => { throw new Error(`${message} at position ${tokenPos + 1} in ${JSON.stringify(source)}`); };
  const next = () => {
    while (/\s/.test(source[pos] ?? "") && pos < source.length) pos++;
    tokenPos = pos;
    if (pos === source.length) { token = ""; return; }
    const match = source.slice(pos).match(/^(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|^[a-zA-Z]+|^[+\-*/^()]/);
    if (!match) error("Unexpected character");
    token = match![0]; pos += token.length;
  };
  const nested = (parse: () => Expr): Expr => {
    if (++depth > 64) error("Expression nesting exceeds 64");
    const result = parse(); depth--; return result;
  };
  const primary = (): Expr => {
    const name = token;
    if (/^(?:\d|\.)/.test(name)) {
      const value = Number(name); if (!Number.isFinite(value)) error("Number must be finite");
      next(); return () => value;
    }
    if (name === variable) { next(); return value => value; }
    if (name === "pi" || name === "e") { next(); return () => name === "pi" ? Math.PI : Math.E; }
    if (name === "(") {
      next(); const inside = nested(sum);
      if (token !== ")") error("Expected closing parenthesis");
      next(); return inside;
    }
    if (Object.hasOwn(functions, name)) {
      next(); if (token !== "(") error(`Expected ( after ${name}`);
      next(); const arg = nested(sum);
      if (token !== ")") error("Expected closing parenthesis");
      next(); return value => functions[name](arg(value));
    }
    return error(name ? `Unknown name ${JSON.stringify(name)}` : "Expected expression");
  };
  const power = (): Expr => {
    const left = primary();
    if (token !== "^") return left;
    next(); const right = nested(unary);
    return v => left(v) ** right(v);
  };
  const unary = (): Expr => {
    if (token !== "+" && token !== "-") return power();
    const sign = token; next(); const arg = nested(unary);
    return v => sign === "-" ? -arg(v) : arg(v);
  };
  const product = (): Expr => {
    let left = unary();
    while (token === "*" || token === "/" || /^(?:[\d.a-zA-Z]|\()/.test(token)) {
      const op = token === "/" ? "/" : "*", before = left;
      if (token === "*" || token === "/") next();
      const right = unary();
      left = op === "/" ? v => before(v) / right(v) : v => before(v) * right(v);
    }
    return left;
  };
  const sum = (): Expr => {
    let left = product();
    while (token === "+" || token === "-") {
      const op = token, before = left; next(); const right = product();
      left = op === "+" ? v => before(v) + right(v) : v => before(v) - right(v);
    }
    return left;
  };
  next(); const expression = sum();
  if (token) error("Unexpected token");
  return expression;
}

export function expressionNumber(value: number | string): number {
  const result = typeof value === "number" ? value : parseExpression(value, "t")(NaN);
  if (!Number.isFinite(result)) throw new Error(`Expected a finite constant expression, got ${JSON.stringify(value)}`);
  return result;
}
