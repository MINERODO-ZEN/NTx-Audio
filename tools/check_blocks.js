// Lua block-depth checker.
//
// Counts openers (function / if / for / while / standalone do) against `end`.
// The subtlety this handles: `for ... do`, `while ... do` and `if ... then`
// already contain their terminator keyword, so only a BARE `do` (not preceded
// by for/while on the same statement) opens a new block.
//
// Validated by running it against untouched committed files, which must report
// depth 0.
const fs = require('fs');

const files = process.argv.slice(2);
let bad = 0;

for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  const s = src
    .replace(/--\[\[[\s\S]*?\]\]/g, '')
    .replace(/--[^\n]*/g, '')
    .replace(/"(\\.|[^"\\\n])*"/g, '""')
    .replace(/'(\\.|[^'\\\n])*'/g, "''");

  let depth = 0;
  const re = /\b(function|if|for|while|do|end)\b/g;
  let m;
  let prev = '';
  while ((m = re.exec(s))) {
    const k = m[1];
    if (k === 'function' || k === 'if') depth++;
    else if (k === 'for' || k === 'while') depth++;
    else if (k === 'do') {
      // opens only when for/while did not already account for it
      if (!/\b(for|while)$/.test(prev)) depth++;
    } else if (k === 'end') depth--;
    prev = m[1];
  }
  if (depth !== 0) {
    console.log(`UNBALANCED  ${f}  depth=${depth}`);
    bad++;
  }
}
console.log(bad === 0 ? 'BALANCED: all block depth 0' : `${bad} file(s) unbalanced`);