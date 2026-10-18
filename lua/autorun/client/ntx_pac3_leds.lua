-- PAC3 lamp layouts for amplifiers.
--
-- Positions, rotations and lens tints are BAKED into lua/autorun/client/
-- ntx_pac3_data.lua by tools/build_pac3_leds.js. This file only interprets
-- them. Parsing PAC3 at runtime was the obvious first move and the wrong one:
--   - it meant CompileString on user-authored text inside the game
--   - it only worked on the machine the files were authored on, because a
--     client never has the server's garrysmod/data folder
--   - a Workshop install would have needed the layouts shipped separately
-- Baking puts the data in the addon, so all three problems go away and the
-- per-frame cost is a table lookup instead of a file read.
--
-- What is left here is the part that has to be in the game: deciding what
-- colour and brightness each lamp is this frame.
AddCSLuaFile()
if not CLIENT then return end

NTx = NTx or {}

-- Lamp kind -> state resolver. Each gets (ent, ch, rec) and returns a
-- brightness from 0 to 255. Nothing here decides colour: the lens tint PAC3
-- recorded is used for both the lit and the unlit state, so a lamp looks the
-- same in the world as it does in the editor. These functions only answer
-- "how bright", never "what hue".
local KINDS = {}

-- Whole-amplifier lamps.
KINDS.power = function(ent)
  if ent:GetPower() and not ent:GetBlown() then
    -- Standby breathes rather than going dark, same as the panel.
    if ent:GetStandby() then
      return (math.floor(CurTime() * 1.5) % 2 == 0) and 90 or 0
    end
    return 255
  end
  return 0
end

KINDS.fault = function(ent, ch, rec)
  local code = (rec and rec.fault) or 0
  if code == 0 or code == 9 then return 0 end   -- none / standby
  local blink = (math.floor(CurTime() * 4) % 2 == 0)
  return blink and 255 or 60
end

-- Per-channel lamps. A baked row with channel 0 means the author did not put a
-- number on the lamp name, so it is treated as channel 1. Note that 0 is truthy
-- in Lua, so this cannot be written as `tonumber(ch) or 1` - that would hand
-- back 0 and the lamp would look up a channel that does not exist.
local function chOf(ch)
  local n = tonumber(ch) or 1
  return n > 0 and n or 1
end

KINDS.signal = function(ent, ch)
  local s = NTx.AmpLedState(ent, chOf(ch))
  if not s then return 0 end
  if s.hot then return 255 end
  if s.on then
    local duty = math.Clamp((s.duty or 0) * 0.9 + 0.1, 0.1, 1)
    local on = (math.sin(CurTime() * 22) * 0.5 + 0.5) < duty
    return on and 255 or 40
  end
  return 0
end

-- ODEP is the amber thermal-gain-reduction lamp of the MA series.
KINDS.odep = function(ent, ch, rec)
  local rc = rec and rec.ch and rec.ch[chOf(ch)]
  local red = math.min(0, (rc and rc.gainred) or 0)
  local lim = math.Clamp(-red / 8, 0, 1)
  return lim > 0.02 and (90 + lim * 165) or 0
end

KINDS.clip = function(ent, ch, rec)
  local c = chOf(ch)
  local rc = rec and rec.ch and rec.ch[c]
  local s = NTx.AmpLedState(ent, c)
  return ((rc and rc.clip) or (s and s.hot)) and 255 or 0
end

-- "protect" lights when the channel is protecting OR the output device is hot,
-- which is how the CDi-style lamp behaves.
KINDS.protect = function(ent, ch, rec)
  local rc = rec and rec.ch and rec.ch[chOf(ch)]
  if ent:GetTempDev() >= 80 or (rc and rc.protect) then return 255 end
  return 0
end

KINDS.temp = function(ent)
  return ent:GetTempDev() >= 80 and 255 or 0
end

-- ------------------------------------------------------------ lookup

local cache = {}

-- Row layout matches the generated file:
--   kind, ch, px, py, pz, ap, ay, ar, lr, lg, lb
local function decode(row)
  local kind, ch = row[1], row[2]
  return {
    kind = kind,
    ch = tonumber(ch) or nil,
    pos = Vector(row[3], row[4], row[5]),
    ang = Angle(row[6], row[7], row[8]),
    lens = Color(row[9] or 0, row[10] or 0, row[11] or 0),
  }
end

function NTx.Pac3Lamps(ent)
  local id = ent:GetProfile()
  local model = ent:GetModel()
  local key = tostring(id) .. "|" .. tostring(model)
  local hit = cache[key]
  if hit ~= nil then return hit end

  local data = NTx.PAC3_LEDS
  local rows = nil
  if data and data.byProfile and tostring(id) ~= "" then
    rows = data.byProfile[tostring(id)]
  end
  if not rows and data and data.byModel and tostring(model) ~= "" then
    rows = data.byModel[tostring(model)]
  end

  local lamps
  if rows and #rows > 0 then
    lamps = {}
    for i = 1, #rows do
      local ok, lamp = pcall(decode, rows[i])
      if ok and lamp then lamps[#lamps + 1] = lamp end
    end
  end
  cache[key] = lamps or false
  return lamps
end

-- Lamps are baked at build time, so a reload can only mean a code reload; this
-- exists so the console command still has something sensible to call.
function NTx.ReloadPac3Lamps()
  cache = {}
end

-- Evaluate one lamp for this frame: returns brightness 0-255 only. The colour
-- is whatever PAC3 recorded, so nothing here picks a hue.
function NTx.Pac3LampState(ent, lamp, rec)
  local fn = KINDS[lamp.kind]
  if not fn then return 0 end
  local ok, alpha = pcall(fn, ent, lamp.ch, rec)
  if not ok then return 0 end
  return alpha or 0
end

concommand.Add("ntx_leds_reload", function()
  -- Layouts are baked into Lua now, so this cannot pick up a PAC3 edit on its
  -- own - the bake has to be re-run. It is kept because it clears the cache
  -- after a code reload and reports what the game can actually see.
  NTx.ReloadPac3Lamps()
  local data = NTx.PAC3_LEDS or { byProfile = {}, byModel = {} }
  local models, profiles = {}, {}
  for k in pairs(data.byProfile or {}) do profiles[#profiles + 1] = k end
  for k in pairs(data.byModel or {}) do models[#models + 1] = k end
  print(string.format(
    "[NTx] baked lamp layouts: %d profile(s) [%s], %d model(s) [%s]",
    #profiles, table.concat(profiles, ", "),
    #models, table.concat(models, ", ")))
end)
-- Reports the baked layout and where it lands on a chosen amplifier. The lamp
-- size and placement were both wrong once already, and the failure mode
-- (nothing visible) gives no clue which, so this prints the numbers instead.
concommand.Add("ntx_leds_debug", function(_, _, args)
  local target
  for _, e in ipairs(ents.FindByClass("ntx_amplifier")) do
    if IsValid(e) and (not IsValid(target) or e:EntIndex() < target:EntIndex()) then target = e end
  end
  if args[1] then target = Entity(tonumber(args[1])) end
  if not IsValid(target) then print("[NTx] no amplifier found") return end

  local lamps = NTx.Pac3Lamps(target)
  local mn, mx = target:GetModelBounds()
  print(string.format("[NTx] amplifier %d profile=%q model=%s", target:EntIndex(),
    tostring(target:GetProfile()), tostring(target:GetModel())))
  print(string.format("    bounds  %s .. %s", tostring(mn), tostring(mx)))
  print(string.format("    lamps   %s", lamps and #lamps or 0))
  if not lamps or #lamps == 0 then
    print("    -> falling back to the built-in panel layout")
    return
  end
  for i, lamp in ipairs(lamps) do
    local world = target:LocalToWorld(lamp.pos)
    print(string.format("    [%d] %-8s ch%s pos=%s ang=%s lens=%s world=%s",
      i, tostring(lamp.kind), tostring(lamp.ch), tostring(lamp.pos), tostring(lamp.ang),
      tostring(lamp.lens), tostring(world)))
  end
end)
