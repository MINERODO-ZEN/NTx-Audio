-- Client: wall occlusion. Star-traces N rays from a source toward a spread
-- around the target; the blocked fraction drives a smoothed multiplier.
-- Mirrors StreamRadio TraceWalls/StarTrace sampling and the 0.33 default
-- occluded floor, minus their per-model GUI extras.
--
-- Two consumers with different physics:
--   NTx.WallFactor        fallback bus  - one gain multiplier, wide star
--   NTx.SpeakerOcclusion  MID cabinet   - gain AND high-frequency loss
--                                        (walls/pillars absorb the top end,
--                                         so a hidden cabinet should sound
--                                          muffled, not just quieter)
if not CLIENT then return end
if NTx_OcclusionLoaded then return end
NTx_OcclusionLoaded = true

local cvRays = CreateClientConVar("ntx_occlusion_rays", "48", true, false,
  "Star-trace ray count for wall occlusion (0 disables traces, factor stays 1)")
local cvFloor = CreateClientConVar("ntx_occlusion_min", "0.33", true, false,
  "Volume floor when a fallback bus is fully occluded by walls (0-1)")
-- Cabinet occlusion is its own pair: a speaker behind a wall should lose
-- more than a bus does (the cabinet is the thing you are hiding), and its
-- highs are absorbed by whatever is in the way.
local cvMidFloor = CreateClientConVar("ntx_occ_mid_min", "0.12", true, false,
  "Volume floor for a MID cabinet with no line of sight to the listener (0-1)")
local cvMidLp = CreateClientConVar("ntx_occ_mid_lp", "1400", true, false,
  "Lowpass cutoff (Hz) for a FULLY occluded MID cabinet (0 = gain only, no lowpass)")

-- Fibonacci sphere, precomputed once. Directions are rotated per bus by a
-- fixed hash so neighboring buses don't share identical sample sets.
local SPHERE = {}
do
  local N, golden = 64, math.pi * (3 - math.sqrt(5))
  for i = 0, N - 1 do
    local y = 1 - (i / (N - 1)) * 2
    local r = math.sqrt(math.max(0, 1 - y * y))
    local th = golden * i
    SPHERE[i + 1] = Vector(math.cos(th) * r, y, math.sin(th) * r)
  end
end

local cache = {}

local function wipeDead()
  for k, v in pairs(cache) do
    if not IsValid(v.ent) then cache[k] = nil end
  end
end

-- Core: star-trace from `from` to `to`, smooth the clear-fraction, return it.
-- clearFrac is 1 with line of sight and 0 when fully walled in. Cached per
-- entity for ~0.2 s (staggered) so a rig of cabinets does not trace every
-- push; the smoothing is what keeps a cabinet walking behind a pillar from
-- pumping.
local function traceClear(ent, from, to, spreadScale)
  local n = math.Clamp(cvRays:GetInt() or 48, 0, 128)
  if n <= 0 then return 1 end
  local delta = to - from
  local dist = delta:Length()
  if dist < 0.001 then return 1 end
  local dir = delta / dist
  -- The rays all END at the target and START spread around the source.
  --
  -- The first version spread the ENDS around the target, in a full sphere. The
  -- ends landed inside whatever was next to the listener - the wall they were
  -- standing against, mostly - and every ray that ended in a wall counted as
  -- blocked. A cabinet in the open read as half occluded, and the MID
  -- channels were lowpassed to a few kilohertz for it.
  --
  -- The target is the one point known to be in free space, so the bundle ends
  -- there. The spread belongs at the source, where it reads as the size of
  -- the thing doing the radiating.
  local up = math.abs(dir.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0)
  local right = dir:Cross(up):GetNormalized()
  up = right:Cross(dir):GetNormalized()
  -- A cabinet is a small target: a wide star would leak around its own edge
  -- and read a wall as clear. Buses get the wide spread below.
  local spread = math.Clamp(dist * spreadScale, 2, 96)
  local clear = 0
  local off = ent:EntIndex() % #SPHERE
  local tr = { mask = MASK_SOLID_BRUSHONLY }
  for i = 1, n do
    local d = SPHERE[(i + off - 1) % #SPHERE + 1]
    tr.start = from + (right * d.x + up * d.y) * spread
    tr.endpos = to
    if util.TraceLine(tr).Fraction >= 1 then clear = clear + 1 end
  end
  return clear / n
end

-- Smoothed clear-fraction for one entity, cached. Returns 1 (unblocked)
-- when tracing is disabled or either point is missing.
local function clearFactor(ent, from, to, spreadScale)
  if not IsValid(ent) or not from or not to then return 1 end
  local ply = LocalPlayer()
  if not IsValid(ply) then return 1 end
  local now = CurTime()
  local key = ent:EntIndex()
  local e = cache[key]
  if e and e.ent == ent and e.next > now then return e.clear end
  local target = traceClear(ent, from, to, spreadScale)
  local v = target
  if e and e.ent == ent then
    -- Smoothed like StreamRadio's approach-speed limiter (~2/s at 5 Hz).
    v = math.Approach(e.clear, target, 2 * math.max(now - e.t, 0.05))
  end
  cache[key] = { ent = ent, clear = v, t = now, next = now + 0.2 + (key % 5) * 0.04 }
  if math.random() < 0.05 then wipeDead() end
  return v
end

-- Fallback taps: one full-spectrum channel per input, so this returns a
-- gain multiplier in [floor, 1]. Wide star (a bus is not a point target).
function NTx.WallFactor(busEnt, busPos)
  local ply = LocalPlayer()
  if not IsValid(ply) or not IsValid(busEnt) then return 1 end
  local floor = math.Clamp(cvFloor:GetFloat() or 0.33, 0, 1)
  -- The star belongs to the bus, not to the listener: the bus is the big
  -- thing here, and the question is whether the listener can see any of it.
  local clear = clearFactor(busEnt, busPos, ply:EyePos(), 0.05)
  return floor + (1 - floor) * clear
end

-- MID cabinet occlusion: gain AND high-frequency loss. Returns
-- (gain, lowpassHz) where lowpassHz is 20000 (bypass) with line of sight
-- and cvMidLp when fully walled in.
function NTx.SpeakerOcclusion(speakerEnt, from, to)
  local floor = math.Clamp(cvMidFloor:GetFloat() or 0.12, 0, 1)
  local lpMax = math.Clamp(cvMidLp:GetFloat() or 1400, 0, 20000)
  local clear = clearFactor(speakerEnt, from, to, 0.02)
  local gain = floor + (1 - floor) * clear
  local lp = 20000
  if lpMax > 0 and clear < 0.999 then
    -- Exponential interpolation in Hz so the sweep sounds like air being
    -- absorbed, not a filter being turned.
    lp = lpMax * math.pow(20000 / lpMax, clear)
    lp = math.Clamp(lp, lpMax, 20000)
  end
  return gain, lp
end
