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
];

function lint(name, src) {
  for (const [re, why] of GLUA_BANNED) {
    const m = src.match(re);
    if (m) {
      const line = src.slice(0, m.index).split("\n").length;
      return `${name}:${line} GLua does not support ${why}`;
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