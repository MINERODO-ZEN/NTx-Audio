-- Third-party amplifier packs.
--
-- The addon used to bake everything a model needs into its own files: the
-- profile table was a Lua table in ntx_amp_shared.lua and the lamp layouts
-- were a generated file. That welded a model's identity to the addon, so an
-- author could publish a model and nothing else - a pack had no way to say
-- "this is a 1200 W amplifier with these lamps".
--
-- A pack is a folder of assets plus two JSON files:
--
--   ntx_pack.json        profiles, and the category they spawn under
--   ntx_pack_lamps.json  lamp rows, produced by the PAC3 baker
--
-- and it lives inside an addon, so a Workshop upload works with no changes
-- here. Both realms read the same files: the server needs the profile to
-- simulate and spawn, the client needs the lamps to draw them.
--
-- Loaded from lua/autorun/ on purpose - autorun runs BEFORE lua/entities/,
-- so a pack's profile is known by the time anything asks for it.
--
-- Packs never override a profile the addon ships. The addon's own names win,
-- so a pack cannot shadow the Powersoft models by accident, and a broken
-- pack cannot break the built-in rig.
AddCSLuaFile()

NTx = NTx or {}
NTx.Packs = NTx.Packs or {}
-- Lamps live in their own table rather than being merged into the baked
-- PAC3_LEDS, because the baked file is a client file in a different folder
-- and the load order between the two is not something to depend on.
NTx.PackLamps = NTx.PackLamps or { byModel = {}, byProfile = {} }

local PACK_FILE = "ntx_pack.json"
local PACK_LAMPS_FILE = "ntx_pack_lamps.json"

-- Where a pack may live, as a path prefix relative to the game folder.
--
-- "addons/*" is the Workshop case: a mounted addon is a folder under
-- garrysmod/addons/. The other two are for packs dropped in by hand.
local function packRoots()
  local roots = {}
  -- file.IsDir rather than a trailing slash on the pattern: whether a
  -- trailing slash restricts a find to directories is not something worth
  -- relying on, and a stray file named like an addon would be a broken root.
  local function addSub(base, path)
    for _, name in ipairs(file.Find(path, "GAME")) do
      if file.IsDir(base .. name, "GAME") then roots[#roots + 1] = base .. name end
    end
  end
  addSub("addons/", "addons/*")
  addSub("ntx_packs/", "ntx_packs/*")
  for _, name in ipairs(file.Find("packs/*", "THIRDPARTY")) do
    if file.IsDir("THIRDPARTY/packs/" .. name, "THIRDPARTY") then
      roots[#roots + 1] = "THIRDPARTY/packs/" .. name
    end
  end
  return roots
end

-- What a pack profile must state, and what it may leave out.
--
-- The required list is the physical truth of the amplifier: without a thermal
-- block the simulation indexes nil on the first tick, and a pack that is
-- accepted and then crashes the rig is worse than one that is refused. The
-- optional list has defaults that are safe for any amplifier.
local PACK_REQUIRED = {
  "name", "model", "channels", "class", "power", "ratedLoad", "minLoad",
  "ilim", "sens", "psu", "mainsWin", "mainsSwallow", "pfFull", "pfIdle",
  "eta", "idleW", "fan", "thermal", "tau", "modes", "zmin", "ratedW", "stock",
}

local PACK_DEFAULTS = {
  standbySwing = 0.4,
  clipHold = 0.1,
  crestDb = 6,
  robust = 1,
  snrDb = 100,
  thdPct = 0.5,
  hiz = false,
  limiters = {},
  modeLabel = "",
  sensOptions = nil,
  box = nil,
  locked = {},
}

local function validateProfile(id, prof)
  local missing = {}
  for _, k in ipairs(PACK_REQUIRED) do
    if prof[k] == nil then missing[#missing + 1] = k end
  end
  if #missing > 0 then
    print(string.format("[NTx] pack profile '%s' is missing %s - skipped.",
      id, table.concat(missing, ", ")))
    return false
  end
  for k, v in pairs(PACK_DEFAULTS) do
    if prof[k] == nil and v ~= nil then prof[k] = v end
  end
  return true
end

local function readJSON(path)
  local raw = file.Read(path, "GAME")
  if not raw or raw == "" then return nil end
  local ok, t = pcall(util.JSONToTable, raw)
  if not ok or type(t) ~= "table" then return nil end
  return t
end

local function mergeLamps(dst, src)
  for key, rows in pairs(src.byModel or {}) do
    dst.byModel[key] = dst.byModel[key] or {}
    for _, r in ipairs(rows) do dst.byModel[key][#dst.byModel[key] + 1] = r end
  end
  for key, rows in pairs(src.byProfile or {}) do
    dst.byProfile[key] = dst.byProfile[key] or {}
    for _, r in ipairs(rows) do dst.byProfile[key][#dst.byProfile[key] + 1] = r end
  end
end

-- Load every pack we can find. Returns the count and the list of names, for
-- the diagnostic command and for the startup line.
function NTx.LoadPacks()
  local loaded = {}
  for _, root in ipairs(packRoots()) do
    local manifest = readJSON(root .. "/" .. PACK_FILE)
    if manifest then
      local name = tostring(manifest.category or "NTx Audio")
      for id, prof in pairs(manifest.profiles or {}) do
        if type(id) == "string" and type(prof) == "table" then
          -- A pack profile carries the same fields as a built-in one, so it
          -- goes straight into the same table and every consumer of a profile
          -- works on it without knowing where it came from.
          prof.id = id
          prof.name = prof.name or id
          prof.print_name = prof.print_name or prof.name
          prof.category = prof.category or name
          -- A pack model is a new model, so it gets its own button. A pack
          -- that only wants to add a profile to an existing class can say
          -- "variant": false.
          if prof.variant == nil then prof.variant = true end
          -- JSON has no Vector. A pack states its box as three numbers.
          if type(prof.box) == "table" and not isvector(prof.box) then
            prof.box = Vector(prof.box[1] or 0, prof.box[2] or 0, prof.box[3] or 0)
          end
          if not validateProfile(id, prof) then
            -- Refused, with the reason. A pack that half-loads is the worst
            -- outcome: the amp appears and then behaves like a different
            -- machine, or indexes nil on the first simulation tick.
          elseif not NTx.AmpProfiles[id] then
            NTx.AmpProfiles[id] = prof
            loaded[#loaded + 1] = id
            NTx.Packs[id] = { id = id, root = root, profile = prof, addon = root }
          end
        end
      end
      -- Lamps may ride in the manifest, or sit beside it in the file the
      -- baker writes. Both are accepted so a pack author can start with one
      -- file and add the other later.
      if manifest.lamps then mergeLamps(NTx.PackLamps, manifest.lamps) end
      local lamps = readJSON(root .. "/" .. PACK_LAMPS_FILE)
      if lamps then mergeLamps(NTx.PackLamps, lamps) end
      -- Workshop id, so the server can ask clients to download the pack.
      -- Without this a player who does not have the addon gets an amplifier
      -- they cannot see.
      local ws = tostring(manifest.workshop or "")
      if ws ~= "" and SERVER then
        pcall(AddMountedAddon, ws)
      end
    end
  end
  return #loaded, loaded
end

-- The spawn buttons. One registration path for the built-in variants and the
-- pack ones, because they are the same thing: a profile that wants its own
-- entry in the menu.
--
-- Registering on the server and the client independently is deliberate. The
-- class name is the same in both, and the profile travels as a string, so
-- nothing has to be sent over the wire for the client to draw the right face.
hook.Add("InitPostEntity", "NTx.AmpVariants", function()
  local n = NTx.RegisterAmpVariants()
  if n > 0 then
    print(string.format("[NTx] %d amplifier variant(s) registered.", n))
  end
end)

-- What the loader found. A pack that does not appear here is a pack that did
-- not load, and the reason is usually a path that did not match.
concommand.Add("ntx_packs", function()
  local n, ids = NTx.LoadPacks()
  print(string.format("[NTx] %d pack profile(s) loaded: %s", n, table.concat(ids, ", ")))
  local roots = packRoots()
  print(string.format("[NTx] %d pack root(s) searched:", #roots))
  for _, r in ipairs(roots) do
    local has = file.Exists(r .. "/" .. PACK_FILE, "GAME")
    print(string.format("    %-46s %s", r, has and "manifest" or "-"))
  end
  print("[NTx] pack profiles:")
  for id, pack in pairs(NTx.Packs) do
    local p = pack.profile
    print(string.format("    %-14s %-26s %s  body=%s  category=%s",
      id, tostring(p.name), tostring(p.model), tostring(p.body), tostring(p.category)))
  end
end)

-- Profiles have to exist before anything asks for one, and the packs are
-- loaded in both realms: the server simulates from the profile, the client
-- draws the lamps and fills the panels.
do
  local n, ids = NTx.LoadPacks()
  if n > 0 then
    print(string.format("[NTx] %d pack profile(s) loaded: %s", n, table.concat(ids, ", ")))
  end
end
