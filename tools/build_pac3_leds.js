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

// Pack mode: emit the lamp rows for ONE pac3 file as the JSON a third-party
// pack ships, instead of baking them into the addon's own generated file.
//
//   node tools/build_pac3_leds.js --pack <pac3File> <outFile>
//
// A pack cannot ship a PAC3 file for the game to parse: PAC3 layouts are Lua
// table bodies, and parsing user-authored Lua inside the game means
// CompileString on it. The rows are baked here instead, and the pack ships
// the result.
const PACK_MODE = process.argv[2] === '--pack';

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
// A plain number, not a string literal. PAC3 stores Size as one, so the
// string-literal reader above finds nothing and every lamp came out at zero.
const numLit = (v) => {
  if (!v) return 0;
  if (v.type === "NumericLiteral") return v.value;
  if (v.arguments && v.arguments[0]) {
    const a = v.arguments[0];
    return parseFloat(a.raw || a.value || 0) || 0;
  }
  return 0;
};
const str = (v) => (v && v.raw ? String(v.raw).replace(/^["']|["']$/g, '') : null);

// Lamp names come in two spellings. The original packs the channel onto the
// kind: "signal2" is channel 2. The Powersoft K spells it out, "green3_ch2",
// because its greens are a five-segment ladder rather than one lamp - the
// trailing digit is the ladder STEP and _chN is the channel.
function splitName(name) {
  const s = String(name || '').toLowerCase();
  const tall = /^([a-z]+)([0-9]*)_ch([0-9]+)$/.exec(s);
  if (tall) {
    return { kind: tall[1], ch: parseInt(tall[3], 10), step: tall[2] === '' ? null : parseInt(tall[2], 10) };
  }
  const m = /^([a-z]+)([0-9]*)$/.exec(s);
  if (!m) return null;
  return { kind: m[1], ch: m[2] === '' ? null : parseInt(m[2], 10), step: null };
}

// Kinds the runtime knows how to drive. A name outside this set is reported
// rather than baked, so a typo shows up at build time instead of as a lamp
// that silently stays dark in game.
const KINDS = new Set(['power', 'fault', 'signal', 'odep', 'clip', 'protect', 'temp', 'meter']);

// Powersoft K Series: "7 meter LEDs: 5 x green, 1 x yellow, 1 x red, top
// yellow and red show alarm with protect description on LCD panel" - so the
// greens are a level ladder and the top two are alarms, not level. Yellow
// below red, which makes yellow the onset of protection and red the fault.
const ALIAS = { green: 'meter', yellow: 'protect', red: 'fault' };

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
          const kind = ALIAS[s.kind] || s.kind;
          if (!KINDS.has(kind)) {
            console.warn(`  ! ${path.basename(file)}: unknown lamp name "${str(f.Name)}" - skipped`);
          } else if (kind === 'meter' && (s.step === null || s.step > 4)) {
            console.warn(`  ! ${path.basename(file)}: ladder lamp "${str(f.Name)}" needs a step of 0-4 - skipped`);
          } else {
            lamps.push({
              kind: kind,
              step: s.step,
              ch: s.ch,
              pos: lit(f.Position) || [0, 0, 0],
              ang: lit(f.Angles) || [0, 0, 0],
              col: lit(f.Color) || [0, 0, 0],
              size: numLit(f.Size),
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

if (PACK_MODE) {
  const src = process.argv[3];
  const dst = process.argv[4];
  if (!src || !dst) {
    console.error('usage: node tools/build_pac3_leds.js --pack <pac3File> <outFile>');
    process.exit(1);
  }
  const parsed = parseFile(src);
  const { model, lamps } = parsed;
  if (lamps.length === 0) {
    console.error('  x ' + src + ': no models/led.mdl entries');
    process.exit(1);
  }
  // Real arrays, not the strings num() produces for the Lua emitter. The
  // game reads these as numbers and indexes them positionally.
  const jnum = (n) => Math.round(Number(n) * 1e4) / 1e4;
  const rows = lamps.map(
    (l) =>
      [l.kind, l.ch === null ? 0 : l.ch, l.step === null || l.step === undefined ? 0 : l.step,
        jnum(l.pos[0]), jnum(l.pos[1]), jnum(l.pos[2]),
        jnum(l.ang[0]), jnum(l.ang[1]), jnum(l.ang[2]),
        Math.round(l.col[0] * 255), Math.round(l.col[1] * 255), Math.round(l.col[2] * 255),
        jnum(l.size || 0)]
  );
  const out = {
    byModel: { [model]: rows },
    byProfile: { [path.basename(src, '.txt')]: rows },
  };
  fs.writeFileSync(dst, JSON.stringify(out, null, 2) + String.fromCharCode(10));
  console.log('wrote ' + dst + '  (' + lamps.length + ' lamp(s), model ' + model + ')');
  process.exit(0);
}

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
        `      { ${q(l.kind)}, ${l.ch === null ? 0 : l.ch}, ${l.step === null || l.step === undefined ? 0 : l.step}, ` +
        `${num(l.pos[0])}, ${num(l.pos[1])}, ${num(l.pos[2])}, ` +
        `${num(l.ang[0])}, ${num(l.ang[1])}, ${num(l.ang[2])}, ` +
        `${Math.round(l.col[0] * 255)}, ${Math.round(l.col[1] * 255)}, ${Math.round(l.col[2] * 255)}, ` +
        `${num(l.size || 0)} },`
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
          `      { ${q(l.kind)}, ${l.ch === null ? 0 : l.ch}, ${l.step === null || l.step === undefined ? 0 : l.step}, ` +
          `${num(l.pos[0])}, ${num(l.pos[1])}, ${num(l.pos[2])}, ` +
          `${num(l.ang[0])}, ${num(l.ang[1])}, ${num(l.ang[2])}, ` +
          `${Math.round(l.col[0] * 255)}, ${Math.round(l.col[1] * 255)}, ${Math.round(l.col[2] * 255)}, ` +
        `${num(l.size || 0)} },`
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
--   3 step      ladder step, 0 when it has none
--   4,5,6 position   model space, x y z
--   7,8,9 rotation   degrees, pitch yaw roll
--   10,11,12 lens tint 0-255, used only while the lamp is dark
--   13 size     diameter in model units, 0 when the layout records none
--
-- Everything is written exactly as PAC3 stored it. The size IS baked, because
-- a layout that records one means it: drawn at native scale instead, the lamps
-- of a model with small lenses came out eight times too big and merged into
-- blobs. PAC3's Scale is still not applied - it is a multiplier on the model
-- rather than a size, and no layout here uses it.
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