// Bake PAC3 lamp layouts into a Lua table the game can load directly.
//
//   node tools/build_pac3_leds.js [pac3Dir] [outFile]
//
// Why bake instead of parsing at runtime:
//   - no CompileString of user-authored text inside the game
//   - clients do not have the server's garrysmod/data folder, so a runtime
//     DATA read only ever worked on the listen server's own machine
//   - the shipped Lua carries the layout, so a Workshop install needs no extra
//     file delivery
//
// Input  : garrysmod/data/pac3/ntx/*.txt   (where PAC3 saves)
// Output : lua/autorun/client/ntx_pac3_data.lua
//
// A PAC3 file is a bare Lua table BODY ("[1] = { ... },", trailing comma, no
// braces), so it gets wrapped in braces before parsing - "return [1] = {...}"
// is not valid Lua, and the brace form is what makes the trailing comma legal.
//
// The root self carries ModelTracker, the model the layout was drawn for. The
// file stem is used as a profile id when it matches one. Both end up as lookup
// keys, and the game tries profile id first, then model path - which is what
// lets a shared file cover several profiles built from the same chassis, and
// lets a per-profile file win once profiles get their own models.

const fs = require('fs');
const path = require('path');
const luaparse = require(path.join(__dirname, 'vendor', 'luaparse.js'));

const REPO = path.resolve(__dirname, '..');
const PAC_DIR = process.argv[2]
  || path.join('C:/Program Files (x86)/Steam/steamapps/common/GarrysMod/garrysmod/data/pac3/ntx');
const OUT = process.argv[3] || path.join(REPO, 'lua/autorun/client/ntx_pac3_data.lua');

// ---- AST helpers --------------------------------------------------------
const keyOf = (f) =>
  f.type !== 'TableKey' ? null : String(f.key.raw).replace(/^["']|["']$/g, '');
const entries = (n) => (n && n.type === 'TableConstructorExpression' ? n.fields.map((f) => [keyOf(f), f.value]) : []);
const field = (n, name) => entries(n).find(([k]) => k === name);
const lit = (v) =>
  v && v.arguments ? v.arguments.map((a) => parseFloat(a.raw || a.argument.raw)) : null;
const str = (v) => (v && v.raw ? String(v.raw).replace(/^["']|["']$/g, '') : null);

// "signal12" -> "signal", 12.  "power" -> "power", null
function splitName(name) {
  const m = /^([a-z]+)([0-9]*)$/.exec(String(name || '').toLowerCase());
  if (!m) return null;
  return { kind: m[1], ch: m[2] === '' ? null : parseInt(m[2], 10) };
}

// Kinds the runtime knows how to drive. A name outside this set is reported
// rather than baked, so a typo shows up at build time instead of as a lamp
// that silently stays dark in game.
const KINDS = new Set(['power', 'fault', 'signal', 'odep', 'clip', 'protect', 'temp']);

function parseFile(file) {
  const raw = fs.readFileSync(file, 'utf8');
  const tree = luaparse.parse('return {\n' + raw.replace(/^\s*return\s+/, '') + '\n}', {
    luaVersion: '5.1',
  });
  const root = tree.body[0].arguments[0];

  let model = null;
  const lamps = [];

  // Each node may carry its own "self". A model2 self is a lamp; a group self
  // carries ModelTracker. The project root is wrapped as
  // [1] = { children = ..., self = ... }, so the walk also descends through
  // indexed entries to reach the group.
  (function walk(node, depth) {
    if (!node || node.type !== 'TableConstructorExpression' || depth > 16) return;

    const self = field(node, 'self');
    if (self) {
      const f = Object.fromEntries(entries(self[1]));
      if (!model && str(f.ModelTracker)) model = str(f.ModelTracker);
      if (str(f.ClassName) === 'model2' && str(f.Model) === 'models/led.mdl') {
        const s = splitName(str(f.Name));
        if (s) {
          if (!KINDS.has(s.kind)) {
            console.warn(`  ! ${path.basename(file)}: unknown lamp name "${str(f.Name)}" - skipped`);
          } else {
            lamps.push({
              kind: s.kind,
              ch: s.ch,
              pos: lit(f.Position) || [0, 0, 0],
              ang: lit(f.Angles) || [0, 0, 0],
              col: lit(f.Color) || [0, 0, 0],
            });
          }
        } else {
          console.warn(`  ! ${path.basename(file)}: unparsable lamp name "${str(f.Name)}" - skipped`);
        }
      }
    }

    const kids = field(node, 'children');
    if (kids) {
      for (const [, child] of entries(kids[1])) walk(child, depth + 1);
    }
    for (const [k, v] of entries(node)) {
      if (k !== 'children' && k !== 'self') walk(v, depth + 1);
    }
  })(root, 0);

  return { model, lamps };
}

// ---- emit ---------------------------------------------------------------
const num = (n) => {
  const r = Math.round(Number(n) * 1e4) / 1e4;
  return Number.isInteger(r) ? String(r) : String(r);
};
const q = (s) => '"' + String(s).replace(/["\\]/g, '\\$&') + '"';

const byModel = {};
const byProfile = {};

if (!fs.existsSync(PAC_DIR)) {
  console.error('PAC3 directory not found: ' + PAC_DIR);
  console.error('Pass the directory as the first argument.');
  process.exit(1);
}

const files = fs.readdirSync(PAC_DIR).filter((f) => f.toLowerCase().endsWith('.txt')).sort();
if (files.length === 0) {
  console.log('No .txt layouts in ' + PAC_DIR + ' - writing an empty table.');
}

for (const f of files) {
  const stem = path.basename(f, '.txt');
  let parsed;
  try {
    parsed = parseFile(path.join(PAC_DIR, f));
  } catch (e) {
    console.error(`  x ${f}: ${e.message}`);
    process.exitCode = 1;
    continue;
  }
  const { model, lamps } = parsed;
  if (lamps.length === 0) {
    console.log(`  - ${f}: no models/led.mdl entries, skipped`);
    continue;
  }
  const rows = lamps
    .map(
      (l) =>
        `      { ${q(l.kind)}, ${l.ch === null ? 0 : l.ch}, ` +
        `${num(l.pos[0])}, ${num(l.pos[1])}, ${num(l.pos[2])}, ` +
        `${num(l.ang[0])}, ${num(l.ang[1])}, ${num(l.ang[2])}, ` +
        `${Math.round(l.col[0] * 255)}, ${Math.round(l.col[1] * 255)}, ${Math.round(l.col[2] * 255)} },`
    )
    .join('\n');

  if (model) {
    if (!byModel[model]) byModel[model] = [];
    byModel[model].push(...lamps);
  }
  if (stem && !byProfile[stem]) byProfile[stem] = lamps;

  console.log(`  + ${f}: ${lamps.length} lamp(s)${model ? '  model=' + model : '  (no ModelTracker)'}`);
  console.log(rows.split('\n').map((l) => '    ' + l.trim()).join('\n'));
}

function emitTable(t) {
  const keys = Object.keys(t);
  if (keys.length === 0) return '  {}';
  const parts = keys.map((k) => {
    const rows = t[k]
      .map(
        (l) =>
          `      { ${q(l.kind)}, ${l.ch === null ? 0 : l.ch}, ` +
          `${num(l.pos[0])}, ${num(l.pos[1])}, ${num(l.pos[2])}, ` +
          `${num(l.ang[0])}, ${num(l.ang[1])}, ${num(l.ang[2])}, ` +
          `${Math.round(l.col[0] * 255)}, ${Math.round(l.col[1] * 255)}, ${Math.round(l.col[2] * 255)} },`
      )
      .join('\n');
    return `    [${q(k)}] = {\n${rows}\n    },`;
  });
  return parts.join('\n');
}

const out = `-- GENERATED FILE - DO NOT EDIT BY HAND.
-- Produced by tools/build_pac3_leds.js from garrysmod/data/pac3/ntx/*.txt.
-- Re-run "node tools/build_pac3_leds.js" after editing a layout in PAC3.
--
-- Row layout, positional on purpose so a rig with many lamps stays cheap to
-- load:
--   1 kind      lamp name with any channel digits stripped ("signal", "odep")
--   2 channel   trailing digit from the lamp name, 0 when it has none
--   3,4,5 position   model space, x y z
--   6,7,8 rotation   degrees, pitch yaw roll
--   9,10,11 lens tint 0-255, used only while the lamp is dark
--
-- Everything is written exactly as PAC3 stored it. Size and Scale are not
-- baked: the game draws the lamp at native model scale, which is what PAC3
-- itself renders when a layout leaves them at their defaults.
NTx = NTx or {}

-- Two lookup keys. The game tries byProfile[profile id] first and falls back
-- to byModel[model path], so one file can cover several profiles that share a
-- chassis and a per-profile file still wins once profiles get their own models.
NTx.PAC3_LEDS = {
  byModel = {
${emitTable(byModel)}
  },
  byProfile = {
${emitTable(byProfile)}
  },
}
`;

fs.writeFileSync(OUT, out);
console.log('\nwrote ' + OUT);
console.log('models: ' + Object.keys(byModel).length + ', profiles: ' + Object.keys(byProfile).length);