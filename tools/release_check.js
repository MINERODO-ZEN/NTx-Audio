// Release check: is this tree ready to be packed and published?
//
//   node tools/release_check.js [deployedClonePath]
//
// Read-only. It says what a .gma built from here would contain, what is
// missing, and whether the deployed clone - the tree a release is actually
// packed from - is the same commit as the source.
//
// Why a script and not a habit: the version stamp is generated into the
// deployed clone and is gitignored, so a .gma built from the repo reports
// "unknown" as its build. Nothing about the tree itself says which of the
// two you packed. This does.
//
// shortcut: it checks the files the addon is known to need, not every file
// the addon references. A model that a third-party pack brings in cannot be
// checked here - that is the pack author's business.

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const SRC = process.cwd();
const ADDON = process.argv[2]
  || "C:/Program Files (x86)/Steam/steamapps/common/GarrysMod/garrysmod/addons/NTx";
const VERSION_REL = "lua/autorun/ntx_version.lua";

let problems = 0;
let notes = 0;

function bad(msg) {
  problems++;
  console.log(`  FAIL  ${msg}`);
}
function warn(msg) {
  notes++;
  console.log(`  note  ${msg}`);
}
function ok(msg) {
  console.log(`  ok    ${msg}`);
}
function head(msg) {
  console.log(`\n${msg}`);
}

function git(args, cwd) {
  try {
    return execSync(`git ${args}`, { cwd, encoding: "utf8" }).trim();
  } catch (e) {
    return "";
  }
}

// ---------------------------------------------------------------- the source

head("source tree");
const status = git("status --porcelain", SRC);
if (status) {
  bad("uncommitted changes - the deployed clone and the source would differ");
  for (const line of status.split("\n").slice(0, 8)) console.log(`          ${line}`);
} else {
  ok("clean");
}
const branch = git("rev-parse --abbrev-ref HEAD", SRC);
ok(`branch ${branch}${branch === "testing" ? "" : "  (not testing)"}`);

// ---------------------------------------------------------------- the assets

head("files the addon needs");
const required = [
  "addon.json",
  "LICENSE",
  "data_static/ntx_audio/webaudio.html",
  "data_static/ntx_audio/probe.html",
  "lua/autorun/ntx_version.lua",
  "models/minerodo/powersoft/powersoft_k.mdl",
  "materials/minerodo/powersoft/powersoftchassis.vmt",
];
for (const rel of required) {
  if (fs.existsSync(path.join(SRC, rel))) ok(rel);
  else bad(`missing ${rel}`);
}

// The version stamp is generated, so it is missing in the source by design.
// The source copy that exists must not claim a commit it does not have.
const srcVersion = path.join(SRC, VERSION_REL);
if (fs.existsSync(srcVersion)) {
  const body = fs.readFileSync(srcVersion, "utf8");
  const m = body.match(/NTx\.COMMIT\s*=\s*"([^"]*)"/);
  const stamp = m ? m[1] : "";
  if (stamp && stamp !== "unknown") {
    warn(`the source carries a stamp (${stamp}) - it is generated in the deployed clone, so this is stale`);
  }
}

// ---------------------------------------------------------------- what ships

head("what a .gma from this tree would contain");
let addon = null;
try {
  addon = JSON.parse(fs.readFileSync(path.join(SRC, "addon.json"), "utf8"));
} catch (e) {
  bad(`addon.json does not parse: ${e.message}`);
}
if (addon) {
  ok(`title "${addon.title}"`);
  const ignore = addon.ignore || [];
  // The ignore patterns are globs, and the ones that matter here are the
  // directory and file kinds that would be dead weight in a public archive.
  const mustShip = ["data_static/ntx_audio/webaudio.html", "LICENSE"];
  for (const rel of mustShip) {
    const ignored = ignore.some((pat) => {
      const rx = new RegExp("^" + pat.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$");
      return rx.test(rel);
    });
    if (ignored) bad(`ignore excludes ${rel}, which has to ship`);
  }
  // Dead weight: editor config and the pack template.
  for (const rel of ["opencode.json", "packs/example/"]) {
    const ignored = ignore.some((pat) => {
      const p = pat.replace(/\*/g, "");
      return rel === p || rel.startsWith(p);
    });
    if (ignored) ok(`ignored: ${rel}`);
    else warn(`${rel} ships - it is not needed in a public archive`);
  }
}

// ---------------------------------------------------------------- the deploy

head("deployed clone (the tree a release is packed from)");
if (!fs.existsSync(ADDON)) {
  // The clone is removed once the .gma is built: it is a deploy target, not
  // a build artefact, and leaving it in the game's addons folder means the
  // addon is loaded twice.
  const gma = path.join(SRC, "ntx_audio.gma");
  if (fs.existsSync(gma)) {
    const mb = (fs.statSync(gma).size / 1048576).toFixed(1);
    ok(`no deployed clone, and ntx_audio.gma is there (${mb} MiB)`);
    console.log("        verify it with: node tools/verify_gma.js <folder> ntx_audio.gma");
  } else {
    bad("no deployed clone and no .gma - nothing has been built yet");
  }
} else {
  const depVersion = path.join(ADDON, VERSION_REL);
  if (!fs.existsSync(depVersion)) {
    bad("no version stamp in the deployed clone - it was never deployed");
  } else {
    const body = fs.readFileSync(depVersion, "utf8");
    const m = body.match(/NTx\.COMMIT\s*=\s*"([^"]*)"/);
    const stamp = m ? m[1] : "";
    const head_ = git("rev-parse --short HEAD", SRC);
    if (stamp === head_) ok(`stamped ${stamp}, the same as the source`);
    else bad(`stamped ${stamp}, the source is ${head_} - deploy before packing`);
  }
}

// ---------------------------------------------------------------- the gate

head("the automated gate");
function luaFiles(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...luaFiles(p));
    else if (e.name.endsWith(".lua")) out.push(p);
  }
  return out;
}
const luaList = luaFiles(path.join(SRC, "lua"));
for (const [label, cmd] of [
  ["check_lua", `node tools/check_lua.js "${path.join(SRC, "lua")}"`],
  ["check_blocks", `node tools/check_blocks.js ${luaList.map((f) => `"${f}"`).join(" ")}`],
]) {
  try {
    const out = execSync(cmd, { cwd: SRC, encoding: "utf8" });
    if (/failed|UNBALANCED|error/i.test(out)) bad(`${label} reported problems`);
    else ok(label);
  } catch (e) {
    bad(`${label} failed: ${(e.stdout || "").toString().split("\n").slice(0, 4).join(" ")}`);
  }
}

console.log("");
if (problems) {
  console.log(`NOT READY: ${problems} problem(s), ${notes} note(s).`);
  process.exitCode = 1;
} else {
  console.log(`READY to pack${notes ? ` (${notes} note(s))` : ""}.`);
  if (fs.existsSync(ADDON)) {
    console.log(`Pack ${ADDON}, not the source tree.`);
    console.log("  node tools/build_gma.js \"<that folder>\" ntx_audio.gma");
  } else {
    console.log("The .gma is built. Upload it, then remove the deployed clone.");
  }
}
