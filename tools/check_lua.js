// Rough GLua -> Lua 5.1 syntax check. Not a linter: it strips the GLua-isms the
// new files use (comments, `continue`, the shift operator) and hands the rest to
// luaparse, so a mismatched `end` or an unterminated string still shows up.
const fs = require("fs");
const path = require("path");
const luaparse = require("./vendor/luaparse.js");

function strip(src) {
  let out = "";
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    // long comment
    if (c === "-" && src[i + 1] === "-") {
      if (src[i + 2] === "[" && src[i + 3] === "[") {
        const end = src.indexOf("]]", i);
        const stop = end === -1 ? src.length : end + 2;
        // The newlines are KEPT. A long comment can span many lines, and
        // collapsing it to one space would shift the line number of every
        // statement after it - which is how a file can parse cleanly and still
        // report the wrong line for everything.
        for (let k = i; k < stop; k++) out += src[k] === "\n" ? "\n" : " ";
        i = stop;
        continue;
      }
      let j = i;
      while (j < src.length && src[j] !== "\n") {
        // a comment ends at the newline unless escaped
        if (src[j] === "\\") { j += 2; continue; }
        j++;
      }
      i = j;
      out += " ";
      continue;
    }
    if (c === '"' || c === "'") {
      const quote = c;
      out += c; i++;
      while (i < src.length) {
        if (src[i] === "\\") { out += src[i] + (src[i + 1] || ""); i += 2; continue; }
        out += src[i];
        if (src[i] === quote) { i++; break; }
        i++;
      }
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

function preprocess(src) {
  let s = strip(src);
  s = s.replace(/\bcontinue\b/g, "break");
  return s;
}

// GLua is Lua 5.1: it has the `bit` library but NOT the C-style operators.
// `1 << x` is a parse error that takes the whole file (and anything the file
// defines) down with it, so it gets its own lint rule rather than being
// quietly papered over.
const GLUA_BANNED = [
  [/<<|>>/, "shift operator (use bit.lshift / bit.rshift)"],
  [/&&|\|\|/, "logical operator (use and / or)"],
  [/(^|[^%w])[^%w=~][01]\s*\/\/[^\/]/, "C-style comment (use --)"],
  // GLua's math library is lowercase. The capitalised spelling is nil, and
  // calling it aborts the whole file at load time - which cost the whole
  // Powersoft profile table once, because the failure surfaced as "no
  // amplifiers in the spawn menu" rather than as a typo.
  //
  // Clamp, Round and Random are deliberately absent: those really are
  // capitalised in GLua.
  [
    /math\.(Sqrt|Abs|Floor|Ceil|Max|Min|Pow|Log|Log10|Sin|Cos|Tan|Sinh|Cosh|Tanh|Atan|Atan2|Asin|Acos|Exp|Fmod|Modf|Frexp|Ldexp|Huge|Pi|Deg|Rad)(?![A-Za-z0-9_])/,
    "capitalised math name (GLua's are lowercase: math.sqrt, math.abs, ...)",
  ],
];

// Server-only globals. Calling one from a file under lua/autorun/client/ is a
// nil error at load time that aborts the REST OF THAT FILE, so a console
// command defined after the call silently never registers and looks like a
// command that does not exist. Worth catching statically.
//
// ents.FindByClass is deliberately absent: it does exist client-side.
// AddCSLuaFile is absent because it is guarded by convention, not by rule.
const SERVER_ONLY = [
  "util.AddNetworkString",
  "util.AddNetworkableType",
  "CreateConVar",
  "player.GetHumans",
  "game.SinglePlayer",
];

// Blanks comments and strings instead of deleting them, so offsets still line
// up with src and the reported line number is the real one.
const blank = (m) => " ".repeat(m.length);

// Definitions and file-scope uses of a function inside one file. Returns the
// first use that comes before the definition, if any.
//
// The AST is used rather than counting braces: only a call at FILE SCOPE is a
// problem, because a call inside another function runs later and is fine
// however it is ordered. Guessing file scope by brace counting produced false
// positives on three files that were correct.
//
// Deliberately narrow: only names this same file defines, and only plain
// function names and NTx.<name>.
function declaredAfterUse(code, ast) {
  const defs = new Map();
  const lines = code.split(String.fromCharCode(10));
  const lineOf = (node) => (node.loc && node.loc.start ? node.loc.start.line : 0);

  const visit = (node) => {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) {
      for (const c of node) visit(c);
      return;
    }
    if (node.type === "FunctionDeclaration" && node.identifier) {
      const id = node.identifier;
      let key = null;
      if (id.type === "Identifier") {
        key = id.name;
      } else if (id.type === "MemberExpression" && id.base && id.base.name && id.identifier) {
        // function NTx.Name() - luaparse puts the member in identifier.
        key = id.base.name + "." + id.identifier.name;
      }
      if (key && !defs.has(key)) defs.set(key, lineOf(node));
    }
    for (const k of Object.keys(node)) {
      if (k === "loc" || k === "range") continue;
      visit(node[k]);
    }
  };
  visit(ast);

  // Also catch "NTx.Name = function" assignments.
  const re = new RegExp("(?:^|" + String.fromCharCode(10) + ")\s*NTx\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*function", "g");
  let m;
  while ((m = re.exec(code)) !== null) {
    if (!defs.has(m[1])) defs.set(m[1], code.slice(0, m.index).split(String.fromCharCode(10)).length);
  }
  if (defs.size === 0) return null;

  // Walk only the top level of the file: a statement that is not inside a
  // function body.
  const check = (node) => {
    if (!node || typeof node !== "object") return null;
    if (node.type === "CallExpression") {
      // This luaparse puts the callee in `base`, not `callee`.
      const callee = node.base;
      let name = null;
      if (callee && callee.type === "MemberExpression"
          && callee.base && callee.base.type === "Identifier"
          && callee.base.name === "NTx"
          && callee.identifier && callee.identifier.name) {
        // luaparse spells a member access base/identifier, not object/property.
        name = "NTx." + callee.identifier.name;
      } else if (callee && callee.type === "Identifier") {
        name = callee.name;
      }
      if (name) {
        const at = defs.get(name);
        if (at !== undefined && at > lineOf(node)) {
          return { line: lineOf(node), what: name, def: at };
        }
      }
    }
    // A call inside a function body runs later - the function is only
    // invoked after the file has loaded - so it is not a use-before-define.
    // Only the file's own top-level statements count.
    const isFunc = node.type === "FunctionDeclaration" || node.type === "FunctionExpression";
    for (const k of Object.keys(node)) {
      if (k === "loc" || k === "range") continue;
      if (isFunc && k === "body") continue;
      const v = node[k];
      if (Array.isArray(v)) {
        for (const c of v) {
          const hit = check(c);
          if (hit) return hit;
        }
      } else if (v && typeof v === "object" && v.type) {
        const hit = check(v);
        if (hit) return hit;
      }
    }
    return null;
  };

  for (const stmt of ast.body) {
    const hit = check(stmt);
    if (hit) return hit;
  }
  return null;
}

// A length-preserving version of the source: comments and strings become
// spaces of the same width, so offsets and LINE NUMBERS still match the
// original. strip() does not preserve them - it collapses a long comment to a
// single space, taking its newlines with it - which is why the AST is parsed
// from this rather than from strip()'s output.
function blankCode(src) {
  const blank = (m) => " ".repeat(m.length);
  return src
    .replace(/--\[\[[\s\S]*?\]\]/g, blank)
    .replace(/--[^\n]*/g, blank)
    .replace(/"(\\.|[^"\\])*"/g, blank)
    .replace(/'(\\.|[^'\\])*'/g, blank)
    .replace(/\bcontinue\b/g, "break");
}

function lint(name, src, ast) {
  // Both checks run against `code`, never `src`: a comment that mentions a
  // banned operator ("bit.lshift, not <<") is not a violation, and matching raw
  // source flagged the very comment written to prevent the mistake.
  const code = blankCode(src);
  const lineOf = (i) => src.slice(0, i).split("\n").length;

  for (const [re, why] of GLUA_BANNED) {
    const m = code.match(re);
    if (m) {
      return `${name}:${lineOf(m.index)} GLua does not support ${why}`;
    }
  }
  // A SpawnFunction written as a plain function instead of a method receives
  // the class table as its first argument, so the player and the trace arrive
  // shifted by one - and tr.Hit is nil, so it returns without spawning
  // anything and without an error. GMod calls it as
  // SpawnFunction(sentTable, ply, tr, EntityName).
  const sf = /SpawnFunction\s*=\s*function\s*\(([^)]*)\)/g;
  let sm;
  while ((sm = sf.exec(code)) !== null) {
    const args = sm[1].split(",").map((a) => a.trim()).filter((a) => a.length);
    if (args.length === 2) {
      return `${name}:${lineOf(sm.index)} SpawnFunction takes (ply, tr) - it is called with the class table first, so it must be a method: function(self, ply, tr)`;
    }
  }

  // IsValid wants an entity. Handing it a METHOD - `IsValid(ent.GetAmp)` -
  // indexes a function and throws inside whatever called it, which here meant
  // the whole rig graph was collected wrong and every level read 1. The
  // method's existence is checked with `and` instead.
  //
  // A member name alone cannot tell a method from a field, so the name has to
  // be used as a call somewhere in the same file to count as a method.
  const isValidMethod = /IsValid\(\s*[A-Za-z_][\w.]*\.([A-Z][\w]*)\s*\)/g;
  let ivm;
  while ((ivm = isValidMethod.exec(code)) !== null) {
    const called = new RegExp(":" + ivm[1] + "\\s*\\(").test(code);
    if (called) {
      return `${name}:${lineOf(ivm.index)} IsValid(${ivm[1]}) is a method, not an entity - check it with "and" instead`;
    }
  }

  // A function used at file scope before it is defined is nil at that point,
  // and calling it aborts the whole file - taking every definition after it
  // with it. Lua has no forward declarations, so the order in the file IS the
  // order things happen in.
  const early = declaredAfterUse(code, ast);
  if (early) {
    return `${name}:${early.line} calls ${early.what} before it is defined (line ${early.def})`;
  }

  if (name.replace(/\\/g, "/").includes("/lua/autorun/client/")) {
    for (const fn of SERVER_ONLY) {
      const m = code.match(new RegExp("(?<![\\w.])" + fn.replace(/\./g, "\\.") + "\\s*\\("));
      if (m) {
        return name + ":" + lineOf(m.index) + " " + fn + " is server-only and would abort this client file";
      }
    }
  }
  return null;
}

const root = process.argv[2];
const files = [];
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (p.endsWith(".lua")) files.push(p);
  }
})(root);

let bad = 0;
const dump = process.argv[3];
for (const f of files) {
  const src = fs.readFileSync(f, "utf8");
  if (dump && f.endsWith(dump)) {
    const out = preprocess(src).split("\n");
    for (let i = 0; i < out.length; i++) console.log(String(i + 1) + ": " + out[i]);
    continue;
  }
  try {
    // locations: true, or every node's loc is empty and every line reads 0.
    // strip keeps the newlines of a long comment, so the AST's line numbers
    // match the file.
    const ast = luaparse.parse(preprocess(src), { luaVersion: "5.1", locations: true });
    const problem = lint(f, src, ast);
    if (problem) {
      bad++;
      console.log("LINT " + problem);
    } else {
      console.log("ok   " + f);
    }
  } catch (e) {
    bad++;
    console.log("FAIL " + f + "\n     " + e.message);
  }
}
console.log(bad === 0 ? "\nall files parsed" : `\n${bad} file(s) failed`);