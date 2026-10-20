// Pack an addon folder into a .gma.
//
//   node tools/build_gma.js <addonFolder> <output.gma> [name] [description]
//
// The format is the one the Garry's Mod publisher writes:
//
//   "GMAD" | version (1 byte, 3) | steam id (8) | timestamp (8)
//   required content (1 byte, 0)
//   name | description | author | version (4 bytes)   - all null terminated
//   per file: number (4) | path | size (8) | crc (4)   - path null terminated
//   a zero (4)
//   the file contents, in the order they were listed
//   the crc of the whole archive (4)
//
// Paths are relative to the addon folder, use backslashes and are lower case:
// the game matches them case insensitively, and an upper case path in the
// archive is a file the game cannot find.
//
// Why a script and not the publisher: the publisher is a GUI, and a release
// that is packed by hand is a release nobody can repeat. This is the same
// tree the deploy script stamps, so the build it produces says which commit
// it came from.
//
// The ignore list in addon.json is honoured, so what ships is what the
// manifest says ships.

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const SRC = process.argv[2];
const OUT = process.argv[3];
const NAME = process.argv[4] || "NTx Audio";
const DESC = process.argv[5] || "A live audio rig: amplifiers, cabinets, mixers and fallback buses, wired with Wiremod.";

if (!SRC || !OUT) {
  console.error("usage: node tools/build_gma.js <addonFolder> <output.gma> [name] [description]");
  process.exit(1);
}

// ---------------------------------------------------------------- crc32

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

// ---------------------------------------------------------------- the tree

function readManifest(folder) {
  try {
    return JSON.parse(fs.readFileSync(path.join(folder, "addon.json"), "utf8"));
  } catch (e) {
    return {};
  }
}

// The publisher's ignore list is a list of globs. This is the same shape,
// matched against the path relative to the addon folder.
function ignored(rel, patterns) {
  return patterns.some((pat) => {
    const rx = new RegExp(
      "^" + pat.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join("[^\\\\]*") + "$"
    );
    if (rx.test(rel)) return true;
    // A directory pattern takes everything under it.
    if (pat.endsWith("/*")) {
      const dir = pat.slice(0, -2);
      return rel.startsWith(dir.replace(/\*/g, "") + "/");
    }
    return false;
  });
}

const manifest = readManifest(SRC);
const patterns = manifest.ignore || [];

const files = [];
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === ".git") continue;
    const full = path.join(dir, e.name);
    const rel = path.relative(SRC, full).split(path.sep).join("/");
    if (ignored(rel, patterns)) continue;
    if (e.isDirectory()) walk(full);
    else files.push({ full, rel });
  }
})(SRC);

files.sort((a, b) => (a.rel < b.rel ? -1 : 1));

// The archive wants lower case paths, and the file list order is the order
// the contents are written in - so both come from the same array.
const entries = files.map((f, i) => ({
  id: i + 1,
  name: f.rel.split("/").join("\\").toLowerCase(),
  data: fs.readFileSync(f.full),
}));

// ---------------------------------------------------------------- write

const chunks = [];
const parts = [];
function put(buf) {
  parts.push(Buffer.isBuffer(buf) ? buf : Buffer.from(buf));
}
function putStr(s) {
  put(Buffer.from(s + "\0", "binary"));
}
function putU8(v) {
  put(Buffer.from([v & 0xff]));
}
function putU32(v) {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(v >>> 0, 0);
  put(b);
}
function putU64(v) {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(v), 0);
  put(b);
}

put(Buffer.from("GMAD", "binary"));
putU8(3);                                  // version
putU64(0);                                 // steam id, unused
putU64(Math.floor(Date.now() / 1000));     // timestamp
putU8(0);                                  // required content: none
putStr(NAME);
putStr(DESC);
putStr("MINERODO-ZEN");
putU32(1);                                 // addon version, unused

for (const e of entries) {
  putU32(e.id);
  putStr(e.name);
  putU64(e.data.length);
  putU32(crc32(e.data));
}
putU32(0);                                 // the end-of-list marker

for (const e of entries) put(e.data);

// The crc of the whole archive, with the crc field itself read as zero.
const body = Buffer.concat(parts);
const bodyCrc = crc32(body);
const out = Buffer.concat([body, (() => { const b = Buffer.alloc(4); b.writeUInt32LE(bodyCrc, 0); return b; })()]);
fs.writeFileSync(OUT, out);

// ---------------------------------------------------------------- report

let total = 0;
for (const e of entries) total += e.data.length;
console.log(`packed ${entries.length} file(s), ${(total / 1048576).toFixed(1)} MiB -> ${OUT}`);
try {
  const head = execSync("git rev-parse --short HEAD", { cwd: SRC, encoding: "utf8" }).trim();
  console.log(`  built from commit ${head}`);
} catch (e) {
  /* not a git tree, nothing to say */
}
const big = entries.filter((e) => e.data.length > 4 * 1048576);
for (const e of big) console.log(`  large: ${e.name} ${(e.data.length / 1048576).toFixed(1)} MiB`);
