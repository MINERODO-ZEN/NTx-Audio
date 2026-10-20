-- Amplifier and speaker electrical model, shared by both realms.
--
-- Everything here is a pure function of (profile, mains, load, temperatures).
-- The authoritative integration lives in lua/autorun/server/ntx_amp_sim.lua;
-- this file only holds the physics, the two hardware profiles and the speaker
-- profiles, so the client can label and draw the same numbers the server
-- simulates.
--
-- Load order: lua/autorun/*.lua runs alphabetically, so this file executes
-- BEFORE ntx_audio_shared.lua. Never call into NTx.FaderToGain / BusForType at
-- load time here - only from inside functions, which run long after both.
NTx = NTx or {}

-- The fields the simulation and the panels read off a profile. A profile
-- missing one is a crash waiting for the first tick, and the check is here
-- because a profile is assembled from a shared template and a per-model
-- literal: naming every field in one place is how two of them got dropped
-- already, silently, and the symptom each time was something else entirely.
NTx.AMP_PROFILE_FIELDS = {
  "id", "name", "model", "body", "channels", "class", "power", "ratedLoad",
  "minLoad", "ilim", "sens", "psu", "standbySwing", "mainsWin",
  "mainsSwallow", "pfFull", "pfIdle", "eta", "idleW", "fan", "thermal",
  "tau", "modes", "zmin", "ratedW", "clipHold", "crestDb", "robust",
  "snrDb", "thdPct", "hiz", "stock", "variant", "category",
}

-- Names what is missing rather than letting it fail later. Returns true when
-- the profile is complete.
function NTx.CheckAmpProfile(id, p)
  if not p then return false end
  local missing = {}
  for _, k in ipairs(NTx.AMP_PROFILE_FIELDS) do
    if p[k] == nil then missing[#missing + 1] = k end
  end
  if #missing == 0 then return true end
  print(string.format("[NTx] amplifier profile '%s' is missing %s", id,
    table.concat(missing, ", ")))
  return false
end


-- ---------------------------------------------------------------- level model

-- 0 dBFS is a full-scale digital sine, which every mixer we care about maps to
-- professional line level: +4 dBu = 1.23 V RMS. The whole sim hangs off this
-- pair, so both are named and derived once.
NTx.AMP_FS_DBU = 4
NTx.AMP_FS_VOLTS = 1.2309

-- Crown's thermal sheets test with pink noise at a 12 dB crest factor; that is
-- the default peak-to-RMS relationship a program signal shows.
NTx.AMP_CREST_DEFAULT = 12

function NTx.AmpDb(x)
  x = tonumber(x) or 0
  if x <= 0.000001 then return -120 end
  -- The two-argument form works: three amplifiers read plausible levels while
  -- a fourth did not, which is a fault in that amplifier's record rather than
  -- in the conversion.
  return 20 * math.log(x, 10)
end

function NTx.AmpVoltRatio(db)
  return 10 ^ ((tonumber(db) or 0) / 20)
end

-- Fader-shaped 0..1.23 V signal level (0 dBFS = 1.23 V) to volts RMS.
function NTx.AmpLinToVolts(lin)
  return NTx.AMP_FS_VOLTS * NTx.AmpVoltRatio(NTx.AmpDb(lin))
end

-- ------------------------------------------------------------- amp profiles

-- Per-channel published power, Crown Macro-Tech series brochure / reference
-- manual 130252 and the CDi series data sheet 139648. Interpolated in linear
-- space; the 16 ohm point is not published by Crown and is estimated at the
-- usual ~0.6x of the 8 ohm figure for these topologies.
--
-- Ilim is the output current ceiling implied by the lowest-impedance rating
-- (sqrt(W*Z)/Z at 2 ohms): the model clamps to it, which is how a low-Z load
-- stops being "more power" and becomes a current fault.
NTx.AmpProfiles = {
  ma2400 = {
    id = "ma2400",
    name = "Crown MA2400 (Macro-Tech 2400)",
    model = "models/props_lab/reciever01b.mdl",
    box = Vector(12, 12, 4),
    mass = 22.7,
    channels = 2,
    class = "AB",
    modeLabel = "AB (toroidal + linear supply)",
    -- 2 x 520 W into 8 ohm, 2 x 800 W into 4 ohm, 2 x 1050 W into 2 ohm.
    -- The Macro-Tech 2400 is a two-channel amplifier; "2400" is the total.
    power = { { 2, 1050 }, { 4, 800 }, { 8, 520 }, { 16, 320 } },
    ratedLoad = 8,
    minLoad = 2,
    ilim = 23,
    -- 0.775 V (US) / 1.4 V (intl) / 26 dB gain for full rated power into 8 ohm.
    sens = 0.775,
    sensOptions = { 0.775, 1.4, 3.22 },
    psu = { ratio = 1.42, droop = 0.12, swing = 0.97, dropV = 8 },
    standbySwing = 0.55,
    mainsWin = 0.10,
    mainsSwallow = 0.25,
    pfFull = 0.62,
    pfIdle = 0.35,
    eta = 0.65,
    idleW = 100,
    idleDf = 9,
    -- 2.4 kW of heat at full 4-ohm power: fine with the fan running in an open
    -- rack, thermal protect in a minute with it blocked. That sensitivity is
    -- the whole reason this amplifier has ODEP.
    fan = { free = 0.024, blocked = 0.110, onT = 55, fullT = 78, rpm = 3200 },
    thermal = { kdev = 0.035, twarn = 90, tderate = 105, tprotect = 120, tdestroy = 145, tsink = 92 },
    tau = { dev = 10, sink = 600, fan = 6 },
    limiters = { "odep" },
    modes = { "dual", "bridge", "parallel" },
    zmin = { dual = 2, bridge = 4, parallel = 1 },
    ratedW = { dual = 520, bridge = 1585, parallel = 1605 },
    clipHold = 0.5,
    crestDb = 6,
    robust = 1,
    snrDb = 105,
    thdPct = 0.05,
    hiz = false,
    stock = { pfc = false, fanNoise = true, autoStandby = true, meters = 1 },
    note = "Country-tapped toroidal supply (+/-10% per tap). ODEP limits drive instead of tripping; IOC LED holds 0.5 s. Standby mode per manual 4.3.2.",
  },
  cdi1000 = {
    id = "cdi1000",
    name = "Crown CDi 1000 (DriveCore 100)",
    model = "models/props_lab/reciever01b.mdl",
    box = Vector(12, 12, 4),
    mass = 10,
    channels = 2,
    class = "D",
    modeLabel = "D (switch-mode supply)",
    -- 2 x 275 W into 8 ohm, 2 x 500 W into 4 ohm, 2 x 700 W into 2 ohm (1% THD).
    power = { { 2, 700 }, { 4, 500 }, { 8, 275 }, { 16, 150 } },
    ratedLoad = 8,
    minLoad = 2,
    ilim = 19,
    -- 1.4 V for full rated power into 8 ohm (1.3 V at 4 ohm, 1.1 V at 2 ohm).
    sens = 1.4,
    sensOptions = { 1.4, 1.3, 1.1 },
    psu = { ratio = 1.65, droop = 0.01, swing = 0.92, dropV = 2 },
    standbySwing = 0.6,
    mainsWin = 0.15,
    mainsSwallow = 0.40,
    pfFull = 0.95,
    pfIdle = 0.55,
    eta = 0.72,
    idleW = 38,
    idleDf = 12,
    fan = { free = 0.082, blocked = 0.31, onT = 48, fullT = 74, rpm = 3800 },
    thermal = { kdev = 0.04, twarn = 80, tderate = 100, tprotect = 115, tdestroy = 135, tsink = 88 },
    tau = { dev = 8, sink = 420, fan = 5 },
    limiters = { "tlc" },
    modes = { "dual", "bridge" },
    zmin = { dual = 2, bridge = 4 },
    ratedW = { dual = 275, bridge = 1000 },
    clipHold = 0.06,
    crestDb = 6,
    robust = 1.35,
    snrDb = 100,
    thdPct = 0.5,
    hiz = true,
    stock = { pfc = true, fanNoise = true, autoStandby = true, meters = 2 },
    note = "Crown publishes no power factor for the switch-mode supply, so PFC is a modelling assumption (toggle it off for non-PFC rail sag). TLC auto-ramps output as it heats; TEMP LED from 80 C.",
  },
}

-- Powersoft K Series. One chassis, five model numbers on the front panel, so
-- every profile points at the same model and differs only in body group.
--
-- psU ratio is derived from the datasheet's max output voltage against
-- nominal mains: a switching rail has to sit at about Vpeak to swing it.
-- eta is Green Audio Power's ">85%"; idleW, idleA and the sensitivity
-- options come straight off the consumption and audio tables. kdev is
-- DERIVED, not published - see the note on each.
local K_SERIES = {
  model = "models/minerodo/powersoft/powersoft_k.mdl",
  channels = 2,
  class = "D",
  modeLabel = "D (universal switch mode, PFC)",
  ratedLoad = 8,
  -- "absolutely stable with 2 ohm loads" - the whole selling point of the
  -- series, so the minimum is a datasheet fact rather than a caution.
  minLoad = 2,
  sensOptions = { 26, 29, 32, 35 },
  psuSwing = 0.98,
  psuDroop = 0.02,
  psuDropV = 4,
  standbySwing = 0.35,
  -- 100-240 V +/-10% against a 230 V nominal.
  mainsWin = 0.10,
  mainsSwallow = 0.60,
  pfFull = 0.95,
  eta = 0.85,
  fan = { free = 0.10, blocked = 0.38, onT = 45, fullT = 70, rpm = 3000 },
  thermal = { kdev = 0.030, twarn = 85, tderate = 100, tprotect = 115, tdestroy = 135, tsink = 80 },
  tau = { dev = 6, sink = 300, fan = 5 },
  limiters = { "tlc", "truepower" },
  modes = { "dual", "bridge" },
  zmin = { dual = 2, bridge = 4 },
  clipHold = 0.35,
  crestDb = 6,
  robust = 1.2,
  snrDb = 110,
  thdPct = 0.5,
  hiz = false,
  stock = { pfc = true, fanNoise = true, autoStandby = false, meters = 2 },
  -- Hardware facts, taken from the datasheet and not the player's to edit.
  -- Channel count because the series is two-channel and nothing else exists;
  -- the rest because the published figures are what the simulation is for.
  -- Mode, trim and standby stay editable - a K really is bridgeable and does
  -- have a standby - and so does the fault injection below the list.
  locked = {
    "channels", "ratedw", "ratedz", "minz", "sens", "ilime",
    "thbias", "fan", "fandb",
  },
  -- Each of the five model numbers is its own button in the spawn menu.
  -- Without this they would all be the one ntx_amplifier class and collapse
  -- into a single entry.
  variant = true,
  category = "Powersoft K Series",
  -- The faceplates are the "panel" body group; group 0 is the chassis and has
  -- only one sub-model. The sub-model order is K2, K3, K6, K10, K20.
  bodyGroup = 1,
}

for _, spec in ipairs({
  { id = "k2", vpeak = 140,  body = 0, w = 2400, w4 = 1950, w8 = 1000, bw4 = 4800, bw8 = 3900,
    sens = { 4.48, 3.17, 2.47, 1.59 }, idleW = 75, idleA = 1.3, apeak = 102, mass = 8, depth = 15,
    eta = 0.82, kdev = 0.021 },
  { id = "k3", vpeak = 165,  body = 1, w = 2800, w4 = 2600, w8 = 1400, bw4 = 5600, bw8 = 5200,
    sens = { 5.30, 3.75, 2.66, 1.88 }, idleW = 75, idleA = 1.3, apeak = 102, mass = 8, depth = 15,
    eta = 0.82, kdev = 0.021 },
  { id = "k6", vpeak = 153,  body = 2, w = 3600, w4 = 2500, w8 = 1300, bw4 = 7200, bw8 = 5000,
    sens = { 5.11, 3.62, 2.56, 1.81 }, idleW = 84, idleA = 1.03, apeak = 125, mass = 12, depth = 18.7,
    eta = 0.84, kdev = 0.030 },
  { id = "k10", vpeak = 200, body = 3, w = 6000, w4 = 4000, w8 = 2000, bw4 = 12000, bw8 = 8000,
    sens = { 6.34, 4.49, 3.18, 2.25 }, idleW = 84, idleA = 1.03, apeak = 125, mass = 12, depth = 18.7,
    eta = 0.85, kdev = 0.033 },
  { id = "k20", vpeak = 225, body = 4, w = 9000, w4 = 5200, w8 = 2700, bw4 = 18000, bw8 = 10400,
    sens = { 7.37, 5.22, 3.68, 2.62 }, idleW = 88, idleA = 1.17, apeak = 125, mass = 12, depth = 18.7,
    eta = 0.86, kdev = 0.034 },
}) do
  local K = K_SERIES
  local prof = {
    id = spec.id,
    name = "Powersoft " .. spec.id:upper(),
    body = spec.body,
    box = Vector(19, spec.depth, 1.75),
    mass = spec.mass,
    -- EIAJ, 1 kHz, 1% THD. Real bridged power here runs close to the sum of
    -- the pair rather than the published doubling, which is what the sheet
    -- reports (K10: 6000 into 2 ohm per channel, 12000 bridged at 4 ohm).
    power = { { 2, spec.w }, { 4, spec.w4 }, { 8, spec.w8 }, { 16, math.floor(spec.w8 / 2) } },
    -- Current limit straight off the sheet: the published peak output current,
    -- as RMS. AmpChannelCeiling multiplies this by the load to get a voltage
    -- ceiling, so it has to be an ampere figure and not a peak one.
    -- math.sqrt, not math.Sqrt: GLua's math library is lowercase and the
    -- capitalised spelling is nil, which aborts this file and takes every
    -- profile with it.
    ilim = math.Round(spec.apeak / math.sqrt(2), 1),
    -- Default to the 32 dB setting, the middle of the four.
    sens = spec.sens[3],
    sensOptions = spec.sens,
    psu = {
      ratio = spec.vpeak / 230,
      droop = K.psuDroop,
      swing = K.psuSwing,
      dropV = K.psuDropV,
    },
    -- Idle power factor off the consumption table: idle watts over idle
    -- volts-times-amps. Switch-mode supplies pull badly at light load and
    -- AmpsPf interpolates from here up to pfFull.
    pfIdle = math.Round(spec.idleW / (230 * spec.idleA), 3),
    eta = spec.eta,
    idleW = spec.idleW,
    -- kdev is DERIVED from the published dissipation, not published itself:
    -- losses at a quarter of rated power against a sink 45 C above ambient.
    thermal = { kdev = spec.kdev, twarn = 85, tderate = 100, tprotect = 115,
                tdestroy = 135, tsink = 80 },
    ratedW = { dual = spec.w8, bridge = spec.bw8 },
    note = "Powersoft K" .. spec.id:upper() .. ": universal 100-240 V +/-10% regulated switch mode with PFC, so output power is flat across the mains range and only the current draw moves (K10 draws 2500 W at both 230 V and 115 V, 11.3 A against 22.6 A). 7 front-panel LEDs per channel: 5 x green meter, then yellow and red for alarms. Peak limiter plus TruePower RMS voltage/current limiting. Thermal numbers are derived from the published dissipation, not published.",
  }
  -- Everything shared comes from the template. Merged rather than copied
  -- field by field: an explicit list drops anything added to the template
  -- later, and that is not a mistake to make twice. The fields above are set
  -- first, so they win.
  for k, v in pairs(K) do
    if prof[k] == nil then prof[k] = v end
  end
  NTx.AmpProfiles[spec.id] = prof
  NTx.CheckAmpProfile(spec.id, prof)
end

function NTx.AmpProfile(id)
  return NTx.AmpProfiles[tostring(id or "")] or nil
end


-- Register a spawnable entity class for one amplifier profile.
--
-- A profile is not a spawn button. GMod's spawn menu lists ENTITY CLASSES, so
-- five profiles sharing one class collapse into a single entry that spawns
-- whichever profile the class defaults to - the thing the Powersoft models
-- were doing before this existed.
--
-- The class is a flat COPY of the base amplifier's table, not a derivation
-- from it. GMod's scripted-entity inheritance snapshots the class table when
-- it registers, and a class file that derives from a base can be registered
-- BEFORE that base has finished loading - GMod says so itself. The result here
-- was an amplifier with no profile, no lamps, and one channel of ports. A copy
-- taken at InitPostEntity, when every file has loaded, cannot go wrong that
-- way, and it needs no class file at all.
-- Register a spawn-menu entry for one amplifier profile.
--
-- The entry is NOT an amplifier. It is a thin class whose only job is to put
-- an ordinary ntx_amplifier into the world with this model's profile - and the
-- entity it creates is a plain ntx_amplifier, the class every other part of
-- the addon already knows about.
--
-- That is deliberate. Making the variant a whole entity class meant twenty
-- places in the addon that test the class name exactly had to learn about it:
-- the panel would not open, the lamps were not drawn, the simulation skipped
-- it, the wire topology ignored it. A menu entry that spawns a normal
-- amplifier needs none of that, and the profile - which carries the model, the
-- body group and every published figure - does the rest.
function NTx.RegisterAmpVariant(class, spec)
  if scripted_ents.GetStored(class) then return false end
  local ENT = {
    Type = "anim",
    Base = "ntx_amplifier",
    PrintName = spec.name or class,
    Author = "NTx port",
    Category = spec.category or "NTx Audio",
    Spawnable = true,
    AdminOnly = false,
    Editable = true,
  }
  -- GMod calls this as SpawnFunction(sentTable, ply, tr, EntityName), so it
  -- is a METHOD: self is the class table, and the player and the trace follow.
  -- Written as a plain function it received the class table as the player and
  -- the player as the trace, so tr.Hit was nil and it returned without
  -- spawning anything - and without an error to say so.
  ENT.SpawnFunction = function(self, ply, tr)
    if not tr.Hit then return end
    -- ClassName is a global the engine sets to the class being spawned while
    -- SpawnFunction runs, and an entity's own table is resolved from it. It is
    -- cleared for the whole create-and-spawn so the entity is unambiguously
    -- the plain amplifier and not this menu entry.
    local savedClass = ClassName
    ClassName = nil
    local ent = ents.Create("ntx_amplifier")
    if IsValid(ent) then
      ent:SetPos(tr.HitPos + tr.HitNormal * 8)
      -- Before Spawn, so the entity's Initialize applies this profile - and
      -- does so before the collision shape is built, which is taken from
      -- whatever model is in place at that moment.
      ent.AmpProfileId = spec.id
      ent:Spawn()
      ent:Activate()
      if CPPI then ent:CPPISetOwner(ply) end
      undo.Create("NTx " .. tostring(spec.name or class))
      undo.AddEntity(ent)
      undo.SetPlayer(ply)
      undo.Finish()
    end
    ClassName = savedClass
    return ent
  end
  scripted_ents.Register(ENT, class)
  return true
end

function NTx.RegisterAmpVariants()
  local n = 0
  for _, id in ipairs(NTx.AmpProfileIds()) do
    local p = NTx.AmpProfile(id)
    if p and p.variant then
      -- entityClass, not "class": a profile's own class field is the
      -- amplifier topology (D, AB, A), and reading that gave every model the
      -- same entity class name - so one registered and four found it taken.
      local class = p.entityClass or ("ntx_ampvar_" .. id)
      if NTx.RegisterAmpVariant(class, {
        id = id,
        name = p.print_name or p.name,
        category = p.category,
      }) then n = n + 1 end
    end
  end
  -- Printed here rather than by the caller, because the callers run at more
  -- than one point and a second run registers nothing - so a caller that
  -- printed its own count would say "0" after the real one.
  if n > 0 then
    print(string.format("[NTx] %d amplifier variant(s) registered.", n))
    -- What each class actually ended up with. Every failure in this area has
    -- been the same shape: the class existed and was missing something from
    -- the base - no Initialize, no profile, no lamps, no menu entry - and the
    -- symptom pointed somewhere else entirely. This says it in one line.
    for _, id in ipairs(NTx.AmpProfileIds()) do
      local p = NTx.AmpProfile(id)
      if p and p.variant then
        local class = p.entityClass or ("ntx_ampvar_" .. id)
        local t = scripted_ents.GetStored(class)
        local tab = t and t.t or nil
        print(string.format("[NTx]   %-22s cat=%-22s profile=%-6s spawn=%s menu=%s",
          class, tostring(p.category), id,
          tostring(tab and tab.SpawnFunction ~= nil),
          tostring(list.HasEntry("SpawnableEntities", class))))
      end
    end
  end
  return n
end

function NTx.AmpProfileIds()
  local ids = {}
  for id in pairs(NTx.AmpProfiles) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- Published per-channel power at a load, interpolated between the profile's
-- data points. Clamps outside the table: below the lowest impedance the amp is
-- current limited anyway (NTx.AmpChannelCeiling), above the highest the power
-- simply rolls off.
function NTx.AmpRatedW(p, z)
  z = math.max(tonumber(z) or 8, 0.1)
  local t = p and p.power
  if not t or #t == 0 then return 0 end
  if z <= t[1][1] then return t[1][2] end
  for i = 1, #t - 1 do
    local z0, w0 = t[i][1], t[i][2]
    local z1, w1 = t[i + 1][1], t[i + 1][2]
    if z <= z1 then
      return w0 + (w1 - w0) * ((z - z0) / (z1 - z0))
    end
  end
  return t[#t][2]
end

function NTx.AmpRatedV(p, z)
  return math.sqrt(math.max(NTx.AmpRatedW(p, z), 0) * math.max(z, 0.1))
end

-- ------------------------------------------------------------ amp modifiers

-- Amplifier mode: 0 dual, 1 bridge-mono, 2 parallel-mono. Returns the mode
-- record so callers do not repeat the profile lookup, plus how many single
-- channels the mode leaves usable (a pair in bridge or parallel is one output).
function NTx.AmpMode(p, mode)
  local name = p and p.modes and p.modes[math.Clamp(math.floor(tonumber(mode) or 0), 0, 2)]
  return (name and name ~= "dual") and name or "dual"
end

function NTx.AmpUsableChannels(p, mode)
  local total = math.Clamp(math.floor((p and p.channels) or 2), 1, 8)
  return (NTx.AmpMode(p, mode) == "dual") and total or math.max(1, math.floor(total / 2))
end

-- Pairs of single channels that a bridge/parallel mode fuses together.
function NTx.AmpChannelPairs(p, mode)
  local out = {}
  if NTx.AmpMode(p, mode) == "dual" then return out end
  local n = NTx.AmpUsableChannels(p, mode)
  for i = 1, n do out[i] = { 2 * i - 1, 2 * i } end
  return out
end

function NTx.AmpMinLoad(p, mode)
  local z = p and p.zmin
  if not z then return 2 end
  return z[NTx.AmpMode(p, mode)] or z.dual or 2
end

function NTx.AmpModeRatedW(p, mode)
  local z = p and p.ratedW
  if not z then return 0 end
  return z[NTx.AmpMode(p, mode)] or z.dual or 0
end

-- Peak/RMS crest for a channel, per-amp override falling back to the global
-- ConVar and then the profile's test condition.
function NTx.AmpCrestDb(crestOverride)
  local crest = tonumber(crestOverride) or 0
  if crest <= 0 then
    local cv = GetConVar and GetConVar("ntx_crest_db")
    crest = cv and cv:GetFloat() or NTx.AMP_CREST_DEFAULT
  end
  return math.Clamp(crest, 0, 30)
end

-- Rail voltage. psu.ratio is the UNLOADED rail (mains * sqrt(2) for a toroid
-- with a bridge, the regulated bus of a switch-mode supply); droop takes it
-- down as the amplifier loads up, which is what makes a no-PFC supply clip
-- before it trips when the mains sags.
function NTx.AmpRail(p, mains, loadFrac)
  local psu = p and p.psu or { ratio = 1.42, droop = 0.05 }
  local lf = math.Clamp(tonumber(loadFrac) or 0, 0, 1.5)
  return math.max(0, (tonumber(mains) or 0) * psu.ratio * (1 - psu.droop * lf))
end

-- Peak output voltage the output stage can swing. Standby keeps the front end
-- alive on a reduced supply with the output stage off, so the ceiling collapses.
function NTx.AmpSwingPeak(p, rail, standby)
  local psu = p and p.psu or { swing = 0.9, dropV = 4 }
  if standby then
    return rail * (psu.swing or 0.9) * (p and p.standbySwing or 0.55)
  end
  return math.min((psu.swing or 0.9) * rail, rail - (psu.dropV or 4))
end

-- Output ceiling for one channel: rail swing, current limit and thermal
-- foldback, whichever bites first. `iScale` widens the current ceiling for a
-- parallel-mono pair, where both halves feed one load together.
function NTx.AmpChannelCeiling(p, mains, z, loadFrac, derateDb, standby, iScale)
  local rail = NTx.AmpRail(p, mains, loadFrac)
  local swing = NTx.AmpSwingPeak(p, rail, standby) / math.sqrt(2)
  local cur = (tonumber(p and p.ilim) or 20) * (tonumber(iScale) or 1) * math.max(z, 0.1)
  local v = math.min(swing, cur)
  if derateDb and derateDb < 0 then v = v * NTx.AmpVoltRatio(derateDb) end
  return math.max(0, v), rail
end

-- Efficiency against load ratio. Class AB falls apart at low level (that is
-- why a 600 W amplifier is the hottest thing in a quiet room); class D stays
-- flat until the aux supply starts to dominate.
function NTx.AmpEta(p, r)
  local etaMax = math.Clamp((p and p.eta) or 0.5, 0.05, 0.99)
  local cls = (p and p.class) or "AB"
  r = math.max(tonumber(r) or 0, 0)
  if cls == "D" then
    return math.Clamp(etaMax * (0.35 + 0.65 * math.Clamp(r / 0.3, 0, 1)), 0.04, 0.99)
  end
  if cls == "A" then
    return math.Clamp(etaMax * (0.55 + 0.45 * math.Clamp(r / 0.6, 0, 1)), 0.05, 0.99)
  end
  if cls == "B" then
    return math.Clamp(etaMax * (2 * r) / (1 + r * r), 0.03, 0.99)
  end
  return math.Clamp(etaMax * (2 * r) / (1 + r * r), 0.03, 0.99)
end

-- 0 dB until Twarn, ramping to DerateMax dB of gain reduction at Tprotect.
-- This is the coupling that makes an overheating amplifier clip: foldback
-- lowers the ceiling, and programme peaks that used to fit now do not.
function NTx.AmpDerateDb(p, tdev)
  local th = p and p.thermal
  if not th then return 0 end
  local span = math.max((th.tprotect or 110) - (th.twarn or 80), 1)
  local k = math.Clamp(((tonumber(tdev) or 0) - (th.twarn or 80)) / span, 0, 1)
  return -8 * k
end

-- Heat-sink thermal resistance at a given fan position. Linear between the
-- free-air and fully blocked values, scaled by the per-amp ThermalBias dial.
function NTx.AmpRth(p, fanFrac, bias)
  local f = p and p.fan
  if not f then return 0.1 end
  local free = (f.free or 0.05) * (tonumber(bias) or 1)
  local blocked = (f.blocked or 0.3) * (tonumber(bias) or 1)
  return free + (blocked - free) * (1 - math.Clamp(fanFrac or 0, 0, 1))
end

function NTx.AmpFanFrac(p, tsink)
  local f = p and p.fan
  if not f then return 0 end
  return math.Clamp(((tonumber(tsink) or 0) - (f.onT or 50)) / math.max((f.fullT or 75) - (f.onT or 50), 1), 0, 1)
end

function NTx.AmpFanRpm(p, fanFrac)
  return math.Round((p and p.fan and p.fan.rpm or 3000) * math.Clamp(fanFrac or 0, 0, 1))
end

-- Power factor: pulsed capacitor-input supplies pull badly at light load.
function NTx.AmpPf(p, loadFrac)
  local pfFull = math.Clamp((p and p.pfFull) or 0.7, 0.1, 1)
  local pfIdle = math.Clamp((p and p.pfIdle) or 0.4, 0.05, 1)
  local k = math.Clamp(tonumber(loadFrac) or 0, 0, 1)
  return pfIdle + (pfFull - pfIdle) * math.sqrt(k)
end

-- Mains acceptance. A country-tapped transformer or a no-PFC supply only
-- tolerates its own tap (+/-10% per the MA2400 manual); outside that the PSU
-- locks out. A PFC supply rides a much wider range with stiff rails. Inside
-- the window but low, the rails sag and the amplifier clips instead of
-- tripping - that is the undervoltage failure the sim has to show.
function NTx.AmpMainsState(p, mains, nominal, pfc)
  nominal = math.max(tonumber(nominal) or 230, 1)
  mains = tonumber(mains) or 0
  local win = pfc and (p and p.mainsWin or 0.15) or (p and p.mainsWin or 0.1)
  local ratio = mains / nominal
  if ratio <= 0 then return "none", ratio end
  if ratio >= 1 + win then return "overvoltage", ratio end
  if ratio < 1 - (pfc and (p and p.mainsSwallow or 0.4) or (p and p.mainsSwallow or 0.25)) then
    return "brownout", ratio
  end
  if ratio < 1 - win then return "undervoltage", ratio end
  return "ok", ratio
end

-- ------------------------------------------------------- speaker profiles

-- Generic archetypes rather than brand clones: these exist to give a rig a
-- defensible power budget, not to clone a catalogue. Players can save their
-- own profiles on top of these (server-side, shared with the whole server).
NTx.SpeakerProfiles = {
  sub18 = { id = "sub18", name = "Sub 18\" (8 ohm)", stype = "SUB", ohm = 8, rmsW = 800, peakW = 1600, minAmpW = 500, hifov = 180, vifov = 180 },
  sub21 = { id = "sub21", name = "Sub 21\" (4 ohm)", stype = "SUB", ohm = 4, rmsW = 1200, peakW = 2400, minAmpW = 800, hifov = 180, vifov = 180 },
  pa12 = { id = "pa12", name = "Full range 12\" (8 ohm)", stype = "MID", ohm = 8, rmsW = 300, peakW = 600, minAmpW = 200, hifov = 110, vifov = 80 },
  pa15 = { id = "pa15", name = "Full range 15\" PA (8 ohm)", stype = "MID", ohm = 8, rmsW = 500, peakW = 1000, minAmpW = 350, hifov = 90, vifov = 70 },
  wedge12 = { id = "wedge12", name = "Monitor wedge 12\" (4 ohm)", stype = "MID", ohm = 4, rmsW = 250, peakW = 500, minAmpW = 150, hifov = 100, vifov = 100 },
  hiz100 = { id = "hiz100", name = "100 V distributed tap", stype = "MID", ohm = 100, rmsW = 25, peakW = 50, minAmpW = 15, tapVolt = 100, hifov = 120, vifov = 120 },
}

function NTx.SpeakerProfile(id)
  return NTx.SpeakerProfiles[tostring(id or "")] or nil
end

function NTx.SpeakerProfileIds()
  local ids = {}
  for id in pairs(NTx.SpeakerProfiles) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- Names are written to a server file, so they are reduced to something that
-- cannot escape the id space or bloat the table.
function NTx.SpkSanitiseName(name)
  name = string.sub(tostring(name or ""), 1, 32)
  name = name:gsub("[^%w%-%_ ]", "")
  name = name:gsub("%s+", " ")
  return name
end

function NTx.SpkMakeId(name)
  local id = NTx.SpkSanitiseName(name):lower():gsub(" ", "_")
  return string.sub(id, 1, 32)
end

-- Compact load text for labels and panels: what the cabinet is, and how it is
-- wired to its amplifier channel.
-- Describes what a cabinet presents. Series is deliberately NOT reported from
-- the old hand-set group: that number is no longer what the simulation uses, it
-- is derived from the wire chain, and the true group impedance is published on
-- each cabinet's SeriesOhm wire output.
function NTx.SpkOhmText(spk)
  if not IsValid(spk) then return "?" end
  local ohm = tonumber(spk:GetImpedance()) or 8
  local tap = math.floor(tonumber(spk:GetTapVolt()) or 0)
  if tap > 0 then return string.format("%d V tap / %g ohm", tap, ohm) end
  return string.format("%g ohm", ohm)
end

-- Which amplifier channel a cabinet lands on. Channel 0 means "auto": the first
-- channel whose bus matches the cabinet, which is what you want for the usual
-- one-cabinet-per-channel rig. Shared by the server simulation and the client
-- audio path so a tap is always attributed to the same channel the simulation
-- charged for it.
function NTx.AmpSpeakerChannel(amp, spk)
  if not IsValid(amp) or not IsValid(spk) then return 0 end
  local usable = NTx.AmpUsableChannels(amp:Prof(), amp:GetMode())
  local ch = math.floor(tonumber(spk:GetAmpChannel()) or 0)
  if ch >= 1 and ch <= usable then return ch end
  local want = spk:GetSpeakerType() == "SUB" and "sub" or "mid"
  for i = 1, usable do
    -- The channel's bus is derived from what the mixer published on it, not
    -- from the retired BusMask bitfield, which is no longer the truth.
    local isSub = amp.ChannelIsSub and amp:ChannelIsSub(i) or false
    if (want == "sub") == isSub then return i end
  end
  return usable > 0 and 1 or 0
end

-- ------------------------------------------------------- speaker load maths

-- Resolve one amplifier channel into its electrical load.
--
-- `list` is a flat array of speaker records:
--   { ent, ohm, tapVolt, group, stype, blown }
--
-- Series groups: speakers sharing a non-zero group id sit in series with each
-- other; every group (including each ungrouped speaker) is then in parallel.
-- A blown driver goes open circuit, which is what actually happens to a burnt
-- voice coil - and it stops loading the amplifier, so the amp cools down.
--
-- Constant-voltage outputs are wired differently: every speaker hangs off the
-- same tap voltage, so each one is its own parallel branch and series groups
-- do not exist. `hiZ` forces that.
function NTx.SpkChannelLoad(list, hiZ)
  local groups, order = {}, {}
  local openCount, shortCount, memberCount = 0, 0, 0
  for _, sp in ipairs(list or {}) do
    -- group is now a key derived from the wire chain (NTx.SpkSeriesKey), so it
    -- is usually a string like "w123". A number is still accepted for an older
    -- caller or a hand-set value. Either way the key just has to be equal for
    -- cabinets in one series group, which is what makes their impedances add.
    local key
    if hiZ then
      key = "hiZ" .. tostring(sp.ent)
    elseif type(sp.group) == "string" then
      key = sp.group
    else
      local g = math.Clamp(math.floor(tonumber(sp.group) or 0), 0, 8)
      key = (g == 0) and ("s" .. tostring(sp.ent)) or g
    end
    if sp.blown then
      openCount = openCount + 1
    else
      local ohm = math.Clamp(tonumber(sp.ohm) or 8, 0.1, 100000)
      if ohm < 0.5 then shortCount = shortCount + 1 end
      local grp = groups[key]
      if not grp then
        grp = { key = key, members = {}, ohm = 0 }
        groups[key] = grp
        order[#order + 1] = grp
      end
      grp.members[#grp.members + 1] = sp
      grp.ohm = grp.ohm + ohm
      memberCount = memberCount + 1
    end
  end
  local inv = 0
  for _, grp in ipairs(order) do
    grp.inverse = 1 / math.max(grp.ohm, 0.05)
    inv = inv + grp.inverse
  end
  return {
    ohm = (inv > 0) and (1 / inv) or 100000,
    groups = order,
    members = memberCount,
    openCount = openCount,
    shortCount = shortCount,
  }
end

-- Power delivered to every speaker on a channel, given the channel output
-- voltage. Series members share the group current (I^2 * Z); every other
-- arrangement reduces to the same expression, because a single-member group is
-- exactly a parallel branch.
function NTx.SpkApplyVoltages(res, vch)
  for _, grp in ipairs(res.groups or {}) do
    local i = vch / math.max(grp.ohm, 0.05)
    for _, sp in ipairs(grp.members) do
      sp.pI = i
      sp.pW = i * i * (tonumber(sp.ohm) or 8)
    end
  end
  return res
end

-- Voice-coil temperature above ambient, driven by how hard the driver is being
-- pushed relative to its own RMS rating. At its rating a driver sits about
-- 50 C over ambient; 1.5x rating is where it starts cooking, and roughly 2x is
-- where the coil is gone in a few minutes.
function NTx.SpkCoilTemp(pRms, rmsW, ambient)
  local rated = math.max(tonumber(rmsW) or 0, 1)
  local r = math.max((tonumber(pRms) or 0) / rated, 0)
  return (tonumber(ambient) or 22) + 30 * r * (1 + 0.7 * r)
end

-- ------------------------------------------------------- client-writable data

-- Every setting a client is allowed to change on an amplifier, as a clamped
-- setter. The net receiver looks names up here and applies them itself, so a
-- hand-crafted packet cannot write a negative channel count or a 40 000 W
-- amplifier; anything not in this list is ignored.
local function f(name, minv, maxv, step, label, set)
  return { name = name, min = minv, max = maxv, step = step or 1, label = label, set = set }
end

-- Some fields have no sensible single control. busmask is a bitfield: as a raw
-- 0-255 slider it was a second writer for a property the per-channel MID/SUB
-- dropdowns already own, and the two could disagree. Hidden keeps the entry in
-- AmpFields so the server-side lookup and the patch window still work, while
-- buildFields leaves it out of the panel.
local function hidden(name, minv, maxv, step, label, set)
  local e = f(name, minv, maxv, step, label, set)
  e.hidden = true
  return e
end

NTx.AmpFields = {
  f("channels", 1, 8, 1, "Channels", function(a, v) a:SetChannels(math.Clamp(math.floor(v + 0.5), 1, 8)) end),
  f("ratedw", 1, 20000, 5, "Rated W", function(a, v) a:SetRatedW(math.Clamp(v, 1, 20000)) end),
  f("ratedz", 1, 1000, 1, "Rated load", function(a, v) a:SetRatedLoad(math.Clamp(v, 1, 1000)) end),
  f("minz", 0.1, 100, 0.5, "Min load", function(a, v) a:SetMinLoad(math.Clamp(v, 0.1, 100)) end),
  f("sens", 0.05, 10, 0.025, "Sensitivity (V)", function(a, v) a:SetSens(math.Clamp(v, 0.05, 10)) end),
  f("trim", -40, 24, 0.5, "Level trim (dB)", function(a, v) a:SetTrim(math.Clamp(v, -40, 24)) end),
  f("ilime", 1, 60, 0.5, "Current limit (A)", function(a, v) a:SetIlime(math.Clamp(v, 1, 60)) end),
  f("mode", 0, 2, 1, "Mode", function(a, v) a:SetMode(math.Clamp(math.floor(v + 0.5), 0, 2)) end),
  f("hizv", 0, 240, 1, "Hi-Z tap (V)", function(a, v) a:SetHizVolt(math.Clamp(math.floor(v + 0.5), 0, 240)) end),
  hidden("busmask", 0, 255, 1, "Bus per channel", function(a, v) a:SetBusMask(math.Clamp(math.floor(v + 0.5), 0, 255)) end),
  f("meters", 0, 2, 1, "Meters", function(a, v) a:SetMeters(math.Clamp(math.floor(v + 0.5), 0, 2)) end),
  f("pfc", 0, 1, 1, "Active PFC", function(a, v) a:SetPFC(v > 0.5) end),
  f("fan", 0, 1, 1, "Fan noise", function(a, v) a:SetFanNoise(v > 0.5) end),
  f("fandb", -120, 0, 1, "Fan level (dB)", function(a, v) a:SetFanNoiseDb(math.Clamp(v, -120, 0)) end),
  f("standby", 0, 1, 1, "Auto standby", function(a, v) a:SetAutoStandby(v > 0.5) end),
  f("sbdelay", 0, 600, 5, "Standby after (s)", function(a, v) a:SetStandbyDelay(math.Clamp(v, 0, 600)) end),
  f("cliphold", 0, 2, 0.05, "Clip LED hold (s)", function(a, v) a:SetClipHold(math.Clamp(v, 0, 2)) end),
  f("crest", 0, 30, 0.5, "Crest (dB)", function(a, v) a:SetCrestDb(math.Clamp(v, 0, 30)) end),
  f("thbias", 0.4, 3, 0.05, "Thermal bias", function(a, v) a:SetThermalBias(math.Clamp(v, 0.4, 3)) end),
  f("mainsov", 0, 400, 1, "Mains override (V)", function(a, v) a:SetMainsOverride(math.Clamp(v, 0, 400)) end),
  f("ambient", -20, 60, 1, "Ambient override (C)", function(a, v) a:SetAmbient(math.Clamp(v, -20, 60)) end),
  f("power", 0, 1, 1, "Power", function(a, v) a:SetPower(v > 0.5) end),
  f("fanon", 0, 1, 1, "Fan running", function(a, v) a:SetFanOn(v > 0.5) end),
}

function NTx.AmpField(name)
  for _, entry in ipairs(NTx.AmpFields) do
    if entry.name == name then return entry end
  end
  return nil
end

-- Same idea for cabinets, minus the settings a client has no business touching.
NTx.SpkFields = {
  f("profile", 0, 0, 1, "Profile", function(s, v) local id = tostring(v); if NTx.SpeakerProfile(id) or NTx.SavedSpeakerProfile(id) then s:ApplySpeakerProfile(id) end end),
  f("imp", 0.1, 100000, 0.5, "Impedance", function(s, v) s:SetImpedance(math.Clamp(v, 0.1, 100000)) end),
  f("rmsw", 0, 100000, 5, "RMS watts", function(s, v) s:SetRmsW(math.Clamp(v, 0, 100000)) end),
  f("peakw", 0, 200000, 5, "Peak watts", function(s, v) s:SetPeakW(math.Clamp(v, 0, 200000)) end),
  f("minampw", 0, 100000, 5, "Min amp watts", function(s, v) s:SetMinAmpW(math.Clamp(v, 0, 100000)) end),
  f("tapv", 0, 240, 1, "Hi-Z tap", function(s, v) s:SetTapVolt(math.Clamp(math.floor(v + 0.5), 0, 240)) end),
  hidden("seriesgrp", 0, 8, 1, "Series group", function(s, v) s:SetSeriesGroup(math.Clamp(math.floor(v + 0.5), 0, 8)) end),
  f("active", 0, 1, 1, "Active (self-powered)", function(s, v) s:SetActive(v > 0.5) end),
  -- Channel is owned by the wire graph, which overwrites anything set here.
  hidden("ampch", 0, 8, 1, "Amp channel", function(s, v) s:SetAmpChannel(math.Clamp(math.floor(v + 0.5), 0, 8)) end),
}

function NTx.SpkField(name)
  for _, entry in ipairs(NTx.SpkFields) do
    if entry.name == name then return entry end
  end
  return nil
end

-- Player-saved cabinet profiles. Server owned (written to garrysmod/data) and
-- mirrored to clients so a dropdown can be filled from either realm; both realms
-- resolve ids through this one lookup.
NTx.SavedSpeakerProfiles = NTx.SavedSpeakerProfiles or {}

function NTx.SavedSpeakerProfile(id)
  return NTx.SavedSpeakerProfiles[tostring(id or "")]
end

function NTx.SpeakerProfileById(id)
  return NTx.SpeakerProfile(id) or NTx.SavedSpeakerProfile(id)
end

-- Every profile, built-ins first, for the dropdowns.
function NTx.AllSpeakerProfiles()
  local out = {}
  for _, id in ipairs(NTx.SpeakerProfileIds()) do out[#out + 1] = NTx.SpeakerProfiles[id] end
  for id, p in pairs(NTx.SavedSpeakerProfiles) do out[#out + 1] = p end
  return out
end
-- ---------------------------------------------------------------- wire glue

-- Wiremod ships with GMod but servers do remove it, and an amplifier without a
-- wire view is still a working amplifier. Every port call goes through these
-- guards so a Wiremod-less server never errors on spawn.

-- Custom signal type. Wiremod's port types are plain strings in WireLib.DT
-- (wire/server/wirelib.lua), and the linker only accepts identical types
-- (wirelib.lua:848), so giving signal ports their own type means a Ch1In can
-- never be wired to a Watt readout or to an unrelated entity's input by
-- accident. Telemetry stays NORMAL so generic wire readers still work on it.
NTx.WIRE_SIG_TYPE = "NTXSIG"

-- Types that carry the rig's audio signal. Two names, because a signal
-- travelling from a mixer to an amplifier is a [level, bus id] PAIR and so is
-- typed ARRAY, while a plain scalar level is NTXSIG. Any scan that decides
-- "is this entity wired?" has to accept both: matching only NTXSIG reports
-- every amplifier and every mixer as unwired, and the topology walk then
-- skips them in silence.
function NTx.IsWireSignalType(t)
  return t == NTx.WIRE_SIG_TYPE or t == "ARRAY"
end

local function registerWireTypes()
  if not WireLib or not WireLib.DT then return end
  if WireLib.DT[NTx.WIRE_SIG_TYPE] then return end
  WireLib.DT[NTx.WIRE_SIG_TYPE] = {
    Zero = function() return 0 end,
    Validator = function(v) return isnumber(v) end,
  }
  if WireLib.registerDebuggerFormat then
    pcall(WireLib.registerDebuggerFormat, NTx.WIRE_SIG_TYPE, function(v)
      return string.format("%.3f", tonumber(v) or 0)
    end)
  end
end
NTx.RegisterWireTypes = registerWireTypes

-- Both sides are Adjust-aware: the amplifier's port list follows its channel
-- count, so a rebuild has to be able to replace an existing port table instead
-- of failing on a duplicate create. Inputs and outputs are handled separately
-- because an entity can legitimately have one and not the other.
-- Reports a failed port create instead of swallowing it. A bare pcall here is
-- the worst possible place for one: when CreateSpecialInputs throws, the entity
-- simply ends up with NO wire ports, so the wire tool shows no gizmos and there
-- is nothing on screen to say why. Almost always an unregistered type name -
-- WireLib.GetDefaultForType indexes WireLib.DT[type] unguarded, so a type that
-- was never registered throws and takes every port on that side with it.
local function wireAdjust(fn, ent, names, types, desc, side)
  if #names == 0 then return end
  local ok, err = pcall(fn, ent, names, types, desc)
  if not ok then
    local msg = string.format("[NTx wire] %s could not create its %s ports: %s",
      IsValid(ent) and ent:GetClass() or tostring(ent), tostring(side), tostring(err))
    if SERVER then ErrorNoHalt(msg) else print(msg) end
    return
  end
  -- Wiremod can also "succeed" and still leave the table empty. Verify rather
  -- than trust, because the symptom - no gizmos - is indistinguishable from an
  -- entity that legitimately has no ports.
  local tbl = side == "input" and ent.Inputs or ent.Outputs
  if istable(tbl) and tbl[names[1]] == nil then
    local msg = string.format("[NTx wire] %s reports %d %s ports but %s is missing from the table",
      IsValid(ent) and ent:GetClass() or tostring(ent), #names, tostring(side), tostring(names[1]))
    if SERVER then ErrorNoHalt(msg) else print(msg) end
  end
end

-- sigNames/nSig marks the leading ports as signal-level so they get the custom
-- type; everything else stays NORMAL telemetry.
--
-- An overrides table maps a port INDEX to an explicit type name, for ports that
-- are neither signal nor plain number. Overrides win over the signal heuristic.
--
-- Inputs and outputs have SEPARATE override tables because they are genuinely
-- different ports: the mixer takes arrays on its 16 inputs while publishing
-- pairs of numbers on its 4 outputs. One table cannot describe both, and
-- passing an input-shaped table here mistyped the mixer's outputs as ARRAY
-- while leaving its inputs NTXSIG - which Wiremod then refused to link.
function NTx.WireSetup(ent, inNames, inDesc, outNames, outDesc, sigIns, sigOuts, outOverrides, inOverrides)
  if not Wire_CreateInputs or not Wire_CreateOutputs then return false end
  inNames, inDesc = inNames or {}, inDesc or {}
  outNames, outDesc = outNames or {}, outDesc or {}
  registerWireTypes()
  local sig = NTx.WIRE_SIG_TYPE

  local function typeList(names, count, overrides)
    local t = {}
    for i = 1, #names do
      if overrides and overrides[i] then
        t[i] = overrides[i]
      else
        t[i] = (tonumber(count) and i <= tonumber(count)) and sig or "NORMAL"
      end
    end
    return t
  end

  if #inNames > 0 then
    local fn = (ent.Inputs and WireLib.AdjustSpecialInputs) and WireLib.AdjustSpecialInputs
      or WireLib.CreateSpecialInputs
    wireAdjust(fn, ent, inNames, typeList(inNames, sigIns, inOverrides), inDesc, "input")
  end
  if #outNames > 0 then
    local fn = (ent.Outputs and WireLib.AdjustSpecialOutputs) and WireLib.AdjustSpecialOutputs
      or WireLib.CreateSpecialOutputs
    wireAdjust(fn, ent, outNames, typeList(outNames, sigOuts, outOverrides), outDesc, "output")
  end
  return true
end

function NTx.WireOut(ent, name, value)
  if not Wire_TriggerOutput then return end
  if not ent.Outputs or ent.Outputs[name] == nil then return end
  pcall(Wire_TriggerOutput, ent, name, value)
end

-- Wiremod is REQUIRED.
--
-- The guards above stop a server without it from erroring, but the addon
-- cannot work without it: the wire graph IS the topology, and the topology
-- is the rig. A rig that cannot be wired is a rig that cannot be built, so
-- this is said once and loudly rather than left to be discovered as a rig
-- that does nothing.
NTx.WIREMOD_WORKSHOP_ID = "160250458"

function NTx.HasWiremod()
  return not not (Wire_CreateInputs and Wire_TriggerOutput and WireLib and WireLib.DT)
end

if SERVER then
  hook.Add("InitPostEntity", "NTx.RequireWiremod", function()
    if NTx.HasWiremod() then return end
    print("[NTx] Wiremod is REQUIRED by this addon and is not installed.")
    print("[NTx] Install Wiremod from the Workshop (item " .. NTx.WIREMOD_WORKSHOP_ID
      .. "): the rig is wired, not configured.")
  end)
end

-- ---------------------------------------------------------------- wire codes

-- Single number a wire readout can carry; the client and the Utilities page
-- both translate it back through this table.
NTx.AmpFaultCodes = {
  [0] = "none",
  [1] = "brownout",
  [2] = "overvoltage",
  [3] = "mains absent",
  [4] = "thermal protect",
  [5] = "overload",
  [6] = "short circuit",
  [7] = "DC offset",
  [8] = "burnt out",
  [9] = "standby",
}

function NTx.AmpFaultName(code)
  return NTx.AmpFaultCodes[math.floor(tonumber(code) or 0)] or "unknown"
end

-- ------------------------------------------------------------------ GUI verbs

-- Which panel an entity gets, by class. Every tool shift-clicks through this,
-- so any tool can open any NTx entity's panel: which tool happens to be in your
-- hands is not a reason to be unable to look at a cabinet.
function NTx.GuiVerb(ent)
  if not IsValid(ent) then return "" end
  local cls = ent:GetClass()
  if cls == "ntx_amplifier" then return "ntx_open_amp " .. ent:EntIndex() end
  if cls == "ntx_speaker" then return "ntx_open_cabinet " .. ent:EntIndex() end
  if cls == "ntx_mixer" then return "ntx_open_mixer " .. ent:EntIndex() end
  return ""
end

-- Shift-click is the one gesture that opens a panel. The tools run their click
-- handlers on the server, so this is driven by a player and sends the console
-- command to that player's client. Returns true when it consumed the click.
function NTx.OpenEntityGui(ply, ent)
  local cmd = NTx.GuiVerb(ent)
  if cmd == "" or not IsValid(ply) then return false end
  ply:ConCommand(cmd)
  return true
end

-- The shift state of a tool click.
--
-- TOOL:LeftClick runs on the server, so it reads the owning player's key state
-- directly. Advanced Duplicator 2 does the same with ply:KeyDown(IN_SPEED)
-- (advdupe2.lua:263) and it works server-side -- the key state reaches the
-- server with the owning player's usercmd, so it is this player's own keys we
-- read, which is all we need.
function NTx.ToolShift(ply)
  if not IsValid(ply) then return false end
  return ply:KeyDown(IN_SPEED)
end

-- Build stamp. Tool panels and entity panels are two different code paths that
-- both have to be current before anything can be tested; printing the stamp on
-- load makes "the game is still running yesterday's Lua" a one-glance answer
-- instead of a guessing game.
--
-- The stamp is the commit hash, written into ntx_version.lua by the deploy
-- script. It used to be a literal here that nobody ever changed, which made
-- it worse than nothing: it looked like a version and never moved.
if not NTx.COMMIT then NTx.COMMIT = "unknown" end

if SERVER then
  util.AddNetworkString("NTx.Hello")
  hook.Add("PlayerInitialSpawn", "NTx.Hello", function(ply)
    timer.Simple(1, function()
      if not IsValid(ply) then return end
      net.Start("NTx.Hello")
      net.WriteString(tostring(NTx.COMMIT))
      net.Send(ply)
    end)
  end)
else
  net.Receive("NTx.Hello", function()
    print("[NTx] client build " .. tostring(net.ReadString())
      .. " (shift-click opens any NTx entity panel)")
  end)
end

-- ------------------------------------------------------- combo boxes
--
-- GMod's DComboBox is only reliable about one thing: GetSelectedID. Two other
-- things this addon depends on do not hold:
--
--   - AddChoice calls SortItems, so insertion order is NOT the option index.
--     "Bridge-mono" sorts ahead of "Dual (stereo)", so an index accumulated
--     while adding pointed at the wrong choice, and mode/tap preselection
--     opened on the wrong entry.
--   - the data argument OnSelect passes did not carry the value that was added.
--     A dropdown that compared it always compared false and silently took the
--     wrong branch - which is why a MID/SUB choice always landed on MID.
--
-- So values are stored against the option TEXT, which this addon supplies and
-- controls, and which is unique within any one combo. Both directions go
-- through the text and neither depends on ordering or on the payload.

function NTx.ComboAdd(combo, text, data)
  combo:AddChoice(text, data)
  combo._ntxData = combo._ntxData or {}
  combo._ntxLabel = combo._ntxLabel or {}
  combo._ntxData[tostring(text)] = data
  combo._ntxLabel[tostring(data)] = tostring(text)
end

function NTx.ComboText(combo)
  local id = combo:GetSelectedID()
  if not id then return nil end
  return combo:GetOptionText(id)
end

-- The value the selected option was added with, or nil.
function NTx.ComboGet(combo)
  local txt = NTx.ComboText(combo)
  if txt ~= nil and combo._ntxData then
    local v = combo._ntxData[tostring(txt)]
    if v ~= nil then return v end
  end
  local id = combo:GetSelectedID()
  return (id and combo:GetOptionData(id)) or nil
end

-- Select the option carrying this value, by text rather than by index.
function NTx.ComboPick(combo, data)
  local want = combo._ntxLabel and combo._ntxLabel[tostring(data)]
  if not want then return false end
  for id = 1, 64 do
    local t = combo:GetOptionText(id)
    if not t then return false end
    if t == want then
      combo:ChooseOptionID(id)
      return true
    end
  end
  return false
end
