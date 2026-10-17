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
    channels = 4,
    class = "AB",
    modeLabel = "AB (toroidal + linear supply)",
    -- 4 x 520 W into 8 ohm, 4 x 800 W into 4 ohm, 4 x 1050 W into 2 ohm.
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
    humDb = -74,
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
    stock = { pfc = false, mainsHum = true, fanNoise = true, autoStandby = true, meters = 1 },
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
    humDb = -120,
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
    stock = { pfc = true, mainsHum = false, fanNoise = true, autoStandby = true, meters = 2 },
    note = "Crown publishes no power factor for the switch-mode supply, so PFC is a modelling assumption (toggle it off for non-PFC rail sag). TLC auto-ramps output as it heats; TEMP LED from 80 C.",
  },
}

function NTx.AmpProfile(id)
  return NTx.AmpProfiles[tostring(id or "")] or nil
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
function NTx.SpkOhmText(spk)
  if not IsValid(spk) then return "?" end
  local ohm = tonumber(spk:GetImpedance()) or 8
  local tap = math.floor(tonumber(spk:GetTapVolt()) or 0)
  if tap > 0 then return string.format("%d V tap / %g ohm", tap, ohm) end
  local g = math.floor(tonumber(spk:GetSeriesGroup()) or 0)
  if g > 0 then return string.format("%g ohm (series %d)", ohm, g) end
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
    local isSub = bit.band(amp:GetBusMask(), bit.lshift(1, i - 1)) ~= 0
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
    local g = hiZ and 0 or math.Clamp(math.floor(tonumber(sp.group) or 0), 0, 8)
    local key = g
    if g == 0 then
      -- Ungrouped speakers are their own series group.
      key = "s" .. tostring(sp.ent)
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
  f("busmask", 0, 255, 1, "Bus per channel", function(a, v) a:SetBusMask(math.Clamp(math.floor(v + 0.5), 0, 255)) end),
  f("meters", 0, 2, 1, "Meters", function(a, v) a:SetMeters(math.Clamp(math.floor(v + 0.5), 0, 2)) end),
  f("pfc", 0, 1, 1, "Active PFC", function(a, v) a:SetPFC(v > 0.5) end),
  f("hum", 0, 1, 1, "Mains hum", function(a, v) a:SetMainsHum(v > 0.5) end),
  f("humdb", -120, -20, 1, "Hum level (dB)", function(a, v) a:SetHumDb(math.Clamp(v, -120, -20)) end),
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
  f("seriesgrp", 0, 8, 1, "Series group", function(s, v) s:SetSeriesGroup(math.Clamp(math.floor(v + 0.5), 0, 8)) end),
  f("active", 0, 1, 1, "Active (self-powered)", function(s, v) s:SetActive(v > 0.5) end),
  f("ampch", 0, 8, 1, "Amp channel", function(s, v) s:SetAmpChannel(math.Clamp(math.floor(v + 0.5), 0, 8)) end),
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
-- two guards so a Wiremod-less server never errors on spawn.
function NTx.WireSetup(ent, inNames, inDesc, outNames, outDesc)
  if not Wire_CreateInputs or not Wire_CreateOutputs then return false end
  if #inNames > 0 then pcall(Wire_CreateInputs, ent, inNames, inDesc) end
  if #outNames == 0 then return true end
  if ent.Outputs and Wire_AdjustOutputs then
    pcall(Wire_AdjustOutputs, ent, outNames, outDesc)
  else
    pcall(Wire_CreateOutputs, ent, outNames, outDesc)
  end
  return true
end

function NTx.WireOut(ent, name, value)
  if not Wire_TriggerOutput then return end
  if not ent.Outputs or ent.Outputs[name] == nil then return end
  pcall(Wire_TriggerOutput, ent, name, value)
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