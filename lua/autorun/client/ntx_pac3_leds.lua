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

local RED = Color(240, 70, 60)
local GREEN = Color(70, 235, 110)
local AMBER = Color(245, 190, 60)
local BLUE = Color(70, 150, 245)
local DIM = Color(120, 122, 126)

-- Lamp kind -> state resolver. Each gets (ent, ch, rec) and returns brightness
-- 0-255 plus the lit colour, or 0 and nil for a dark lamp.
--
-- Colours come from here and never from PAC3, so a lamp means the same thing
-- on the Derma panel as it does in the world. The authored tint is only used
-- for the unlit lens, which keeps a dark red lens looking like dark plastic
-- rather than a black dot.
local KINDS = {}

-- Whole-amplifier lamps.
KINDS.power = function(ent)
  if ent:GetPower() and not ent:GetBlown() then
    -- Standby breathes rather than going dark, same as the panel.
    if ent:GetStandby() then
      return (math.floor(CurTime() * 1.5) % 2 == 0) and 90 or 0, BLUE
    end
    return 255, BLUE
  end
  return 0, nil
end

KINDS.fault = function(ent, ch, rec)
  local code = (rec and rec.fault) or 0
  if code == 0 or code == 9 then return 0, nil end   -- none / standby
  local blink = (math.floor(CurTime() * 4) % 2 == 0)
  return blink and 255 or 60, (code == 8) and DIM or RED
end

-- Per-channel lamps. A baked row with channel 0 means the author did not put a
-- number on the lamp name, so it is treated as channel 1.
local function chOf(ch)
  return tonumber(ch) or 1
end

KINDS.signal = function(ent, ch)
  local s = NTx.AmpLedState(ent, chOf(ch))
  if not s then return 0, nil end
  if s.hot then return 255, Color(170, 255, 190) end
  if s.on then
    local duty = math.Clamp((s.duty or 0) * 0.9 + 0.1, 0.1, 1)
    local on = (math.sin(CurTime() * 22) * 0.5 + 0.5) < duty
    return on and 255 or 40, GREEN
  end
  return 0, nil
end

-- ODEP is the amber thermal-gain-reduction lamp of the MA series.
KINDS.odep = function(ent, ch, rec)
  local rc = rec and rec.ch and rec.ch[chOf(ch)]
  local red = math.min(0, (rc and rc.gainred) or 0)
  local lim = math.Clamp(-red / 8, 0, 1)
  return lim > 0.02 and (90 + lim * 165) or 0, AMBER
end

KINDS.clip = function(ent, ch, rec)
  local c = chOf(ch)
  local rc = rec and rec.ch and rec.ch[c]
  local s = NTx.AmpLedState(ent, c)
  return ((rc and rc.clip) or (s and s.hot)) and 255 or 0, RED
end

-- "protect" lights when the channel is protecting OR the output device is hot,
-- which is how the CDi-style lamp behaves.
KINDS.protect = function(ent, ch, rec)
  local rc = rec and rec.ch and rec.ch[chOf(ch)]
  if ent:GetTempDev() >= 80 or (rc and rc.protect) then return 255, RED end
  return 0, nil
end

KINDS.temp = function(ent)
  return ent:GetTempDev() >= 80 and 255 or 0, RED
end

-- ------------------------------------------------------------ lookup

local cache = {}

-- Row layout matches the generated file:
--   kind, ch, px, py, pz, ap, ay, ar, lr, lg, lb, scaleMul
local function decode(row)
  local kind, ch = row[1], row[2]
  return {
    kind = kind,
    ch = tonumber(ch) or nil,
    pos = Vector(row[3], row[4], row[5]),
    ang = Angle(row[6], row[7], row[8]),
    lens = Color(row[9] or 0, row[10] or 0, row[11] or 0),
    -- 0 means the PAC3 file recorded no Scale, so the diameter comes from the
    -- chassis instead of from the authored value.
    scale = (tonumber(row[12]) or 0) > 0 and tonumber(row[12]) or nil,
  }
end

-- One-off sanity check per chassis.
--
-- Two failure modes, and only one of them is a bounds violation:
--   * a lamp outside the model's bounds means PAC3 and GMod disagree about
--     where the model origin is
--   * a lamp INSIDE the bounds can still be buried in the solid mesh, which is
--     exactly what happened with reciever01b.mdl: PAC3 authored x=6.351 while
--     the face sits at 7.353, so every lamp was ~0.85 units under the surface
--     and invisible. Bounds alone cannot catch that, so the depth is checked
--     against the front face separately.
local originWarned = {}
local function warnIfOutsideBounds(ent, lamps)
  local key = ent:GetModel()
  if originWarned[key] then return end
  local mn, mx = ent:GetModelBounds()
  if not mn or not mx then return end
  -- A little slack: a lamp legitimately authored just proud of the face is
  -- still inside, so only a clear excursion counts.
  local pad = Vector(2, 2, 2)
  for _, lamp in ipairs(lamps) do
    if lamp.pos.x < mn.x - pad.x or lamp.pos.x > mx.x + pad.x
      or lamp.pos.y < mn.y - pad.y or lamp.pos.y > mx.y + pad.y
      or lamp.pos.z < mn.z - pad.z or lamp.pos.z > mx.z + pad.z then
      originWarned[key] = true
      print(string.format(
        "[NTx] PAC3 lamp %q on %s is outside the model bounds (model %s..%s). "
        .. "PAC3 and GMod disagree about the model origin, so the lamps will "
        .. "render in the wrong place.", tostring(lamp.kind), key,
        tostring(mn), tostring(mx)))
      return
    end
  end
  -- Inside the bounds, but sunk below the face.
  local front = lamps.maxX
  if front and front < mx.x - 0.5 then
    originWarned[key] = true
    print(string.format(
      "[NTx] PAC3 lamps on %s sit at x=%.3f but the front face is x=%.3f, "
      .. "so they were authored %.2f units inside the chassis. They are being "
      .. "pinned to the face instead; re-author them in PAC3 against the model "
      .. "surface if the depth matters.",
      key, front, mx.x, mx.x - front))
  end
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
    -- Frontmost authored depth, used by the renderer to turn PAC3's absolute x
    -- into a depth relative to whatever it measures against. See
    -- drawPac3Lamps - PAC3's absolute x does not line up with GMod's face.
    local maxX
    for i = 1, #rows do
      local ok, lamp = pcall(decode, rows[i])
      if ok and lamp then
        lamps[#lamps + 1] = lamp
        if not maxX or lamp.pos.x > maxX then maxX = lamp.pos.x end
      end
    end
    lamps.maxX = maxX or 0
  end
  cache[key] = lamps or false
  return lamps
end

-- Lamps are baked at build time, so a reload can only mean a code reload; this
-- exists so the console command still has something sensible to call.
function NTx.ReloadPac3Lamps()
  cache = {}
end

NTx.Pac3CheckBounds = warnIfOutsideBounds

-- Evaluate one lamp for this frame.
function NTx.Pac3LampState(ent, lamp, rec)
  local fn = KINDS[lamp.kind]
  if not fn then return 0, nil end
  local ok, alpha, col = pcall(fn, ent, lamp.ch, rec)
  if not ok then return 0, nil end
  return alpha or 0, col
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
    print(string.format("    [%d] %-8s ch%s pos=%s ang=%s lens=%s scale=%s world=%s",
      i, tostring(lamp.kind), tostring(lamp.ch), tostring(lamp.pos), tostring(lamp.ang),
      tostring(lamp.lens), tostring(lamp.scale), tostring(world)))
  end
  NTx.Pac3CheckBounds(target, lamps)
end)
