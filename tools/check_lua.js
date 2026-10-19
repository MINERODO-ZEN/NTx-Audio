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
        i = end === -1 ? src.length : end + 2;
        out += " ";
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

function lint(name, src) {
  // Both checks run against `code`, never `src`: a comment that mentions a
  // banned operator ("bit.lshift, not <<") is not a violation, and matching raw
  // source flagged the very comment written to prevent the mistake.
  const code = src
    .replace(/--\[\[[\s\S]*?\]\]/g, blank)
    .replace(/--[^\n]*/g, blank)
    .replace(/"(\\.|[^"\\])*"/g, blank)
    .replace(/'(\\.|[^'\\])*'/g, blank);
  const lineOf = (i) => src.slice(0, i).split("\n").length;

  for (const [re, why] of GLUA_BANNED) {
    const m = code.match(re);
    if (m) {
      return `${name}:${lineOf(m.index)} GLua does not support ${why}`;
    }
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
    luaparse.parse(preprocess(src), { luaVersion: "5.1" });
    const problem = lint(f, src);
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