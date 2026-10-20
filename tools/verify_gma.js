// Verify a .gma: read it back and check it against the tree it was packed
// from.
//
//   node tools/verify_gma.js <addonFolder> <file.gma>
//
// The packer and this reader were written from the same description of the
// format, so a round trip alone would only prove they agree with each
// other. The content check is the part that matters: every file in the
// archive has to be byte for byte the file on disk, and every crc has to
// match its content.

const fs = require("fs");
const path = require("path");

const SRC = process.argv[2];
const GMA = process.argv[3];
if (!SRC || !GMA) {
  console.error("usage: node tools/verify_gma.js <addonFolder> <file.gma>");
  process.exit(1);
}

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

const buf = fs.readFileSync(GMA);
let p = 0;
const magic = buf.toString("binary", 0, 4); p = 4;
const version = buf.readUInt8(p); p += 1;
const steam = buf.readBigUInt64LE(p); p += 8;
const ts = buf.readBigUInt64LE(p); p += 8;
const req = buf.readUInt8(p); p += 1;
const cstr = () => { const e = buf.indexOf(0, p); const s = buf.toString("binary", p, e); p = e + 1; return s; };
const name = cstr();
const desc = cstr();
const author = cstr();
const addonVersion = buf.readUInt32LE(p); p += 4;

let bad = 0;
function check(ok, msg) {
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${msg}`);
  if (!ok) bad++;
}

console.log("header");
check(magic === "GMAD", `magic ${magic}`);
check(version === 3, `version ${version}`);
check(req === 0, "required content list empty");
check(name.length > 0, `name "${name}"`);
check(author.length > 0, `author "${author}"`);
console.log(`        description: ${desc}`);
console.log(`        timestamp: ${ts}  steam id: ${steam}  addon version: ${addonVersion}`);

const files = [];
for (;;) {
  const id = buf.readUInt32LE(p); p += 4;
  if (id === 0) break;
  const n = cstr();
  const size = Number(buf.readBigUInt64LE(p)); p += 8;
  const crc = buf.readUInt32LE(p); p += 4;
  files.push({ id, n, size, crc });
}
const dataStart = p;

// The archive carries no offsets: the contents follow the list back to back,
// in the order the list names them. So the offsets are the cumulative sizes.
let off = dataStart;
for (const f of files) { f.off = off; off += f.size; }

console.log("\nentries");
let crcBad = 0;
for (const f of files) {
  const d = buf.slice(f.off, f.off + f.size);
  if (crc32(d) !== f.crc) { crcBad++; if (crcBad < 5) console.log(`        crc mismatch: ${f.n}`); }
}
check(files.length > 0, `${files.length} file(s) listed`);
check(crcBad === 0, `every crc matches its content (${crcBad} bad)`);

const ids = files.map((f) => f.id);
check(ids.every((v, i) => v === i + 1), "file numbers run from one");

console.log("\ncontent");
let same = 0, diff = 0, missing = 0;
for (const f of files) {
  const disk = path.join(SRC, f.n.split("\\").join(path.sep));
  if (!fs.existsSync(disk)) { missing++; if (missing < 5) console.log(`        not on disk: ${f.n}`); continue; }
  if (fs.readFileSync(disk).equals(buf.slice(f.off, f.off + f.size))) same++;
  else { diff++; if (diff < 5) console.log(`        differs: ${f.n}`); }
}
check(missing === 0, `every archived file is on disk (${missing} missing)`);
check(diff === 0, `every archived file is byte for byte the one on disk (${diff} differ)`);

const end = dataStart + files.reduce((a, f) => a + f.size, 0);
check(end + 4 === buf.length, "the archive ends with the crc and nothing else");
check(crc32(buf.slice(0, end)) === buf.readUInt32LE(end), "the archive crc matches its own bytes");

console.log("");
if (bad) {
  console.log(`INVALID: ${bad} problem(s).`);
  process.exitCode = 1;
} else {
  console.log(`valid: ${files.length} file(s), ${(buf.length / 1048576).toFixed(1)} MiB.`);
}
