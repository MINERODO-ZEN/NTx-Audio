-- NTx Audio port: shared constants + math.
-- Ported behavior: AudioConfig (80 Hz crossover), SpeakerType MID/SUB,
-- SpeakerDirectivity cones, cardioid/endfire rear attenuation floors.
NTx = NTx or {}

NTx.CROSSOVER_HZ = 80
NTx.CROSSOVER_SLOPE_DEFAULT = 24

-- Directivity cones (degrees). MID derived from NTx spread 1.9 (30*1.9, 80*1.9).
NTx.DIR = {
  MID = { Inner = 57, Outer = 152, OuterVol = 0.2 },
  SUB = { Inner = 180, Outer = 360, OuterVol = 0.8 },
}

-- Rear-hemisphere attenuation floors for simplified cardioid shading.
NTx.CARDIOID_MIN_GAIN = 0.06
NTx.ENDFIRE_MIN_GAIN = 0.1

NTx.MAX_FADER = 2.0
NTx.MAX_SOURCES = 16

function NTx.IsSpeakerType(v)
  return v == "MID" or v == "SUB"
end

function NTx.ClampFader(v)
  return math.Clamp(tonumber(v) or 1, 0, NTx.MAX_FADER)
end

-- Simplified cardioid rear attenuation: 1 in front, floor behind.
-- facingDot: dot(arrayForward, dirToListener), -1 = directly behind.
function NTx.CardioidShade(facingDot, mode)
  if mode == "cardioid" then
    if facingDot >= 0 then return 1 end
    local t = math.Clamp(-facingDot, 0, 1)
    return 1 + (NTx.CARDIOID_MIN_GAIN - 1) * t
  elseif mode == "endfire" then
    if facingDot >= 0 then return 1 end
    local t = math.Clamp(-facingDot, 0, 1)
    return 1 + (NTx.ENDFIRE_MIN_GAIN - 1) * t
  end
  return 1
end

function NTx.BusForType(t)
  return t == "SUB" and "sub" or "mid"
end

-- Manual distance fade for 2D (non-positional) taps, where the engine
-- provides no attenuation. Port of StreamRadio CalcDistanceVolume
-- (3D-Stream-Radio lua/streamradio_core/client/cl_lib.lua:183-197):
-- full volume out to max/12, 0.25 at max/3, linear to silence at max.
function NTx.CalcDistanceVolume(dist, maxd)
  maxd = math.max(tonumber(maxd) or 0, 1)
  dist = tonumber(dist) or 0
  local min = maxd / 3
  local fullmin = min / 4
  if dist > maxd then return 0 end
  if dist <= fullmin then return 1 end
  if dist <= min then
    return 1 - 0.75 * (dist - fullmin) / (min - fullmin)
  end
  return 0.25 * (1 - (dist - min) / (maxd - min))
end

-- Logarithmic fader taper. Stored values stay 0..2 with unity at 1, so
-- existing maps, dupes and the network format are untouched; only the
-- gain computation is curved. 0 = -60 dB, 1 = 0 dB, 2 = +6 dB.
function NTx.FaderToGain(p)
  p = math.Clamp(tonumber(p) or 1, 0, 2)
  local db = (p <= 1) and (-60 * (1 - p)) or (6 * (p - 1))
  return 10 ^ (db / 20)
end

function NTx.GainToDb(g)
  g = tonumber(g) or 0
  if g <= 0.000001 then return -60 end
  return math.Clamp(20 * math.log(g) / math.log(10), -60, 6)
end

-- Mix headroom: the audibility normaliser parks total audible ENERGY at this
-- linear gain instead of at 1.0. Parking at 1.0 puts the master on the
-- safety limiter's threshold, and a limiter compresses AWAY the differences
-- we worked to make: an off-axis cabinet at 0.2 and an on-axis one at 1.0 both
-- got pinned to the same ceiling, so the cone "did nothing". Keeping the mix
-- under the threshold lets cone ratios through and leaves the limiter to do
-- its stated job - catching true overs only.
-- Read through GetConVar so a partial load (or the server realm, where this
-- ConVar does not exist) falls back to the default instead of erroring.
function NTx.MixHeadroomGain()
  local cv = CLIENT and GetConVar("ntx_headroom_db") or nil
  local db = cv and cv:GetFloat() or -6
  return 10 ^ (math.Clamp(db, -12, 0) / 20)
end

-- Given summed audible energy E, the factor to apply so the mix lands on the
-- headroom target. Identical in both backends (they cross-normalise against
-- each other's published energy, so the target MUST match or they fight).
function NTx.HeadroomNorm(totalEnergy)
  local target = NTx.MixHeadroomGain()
  local targetE = target * target
  if not (totalEnergy > targetE) then return 1 end
  return math.Clamp(math.sqrt(targetE / totalEnergy), 0.12, 1)
end

-- Web Audio "inverse" distance model, mirrored so Lua can estimate audible
-- energy the same way the PannerNode will attenuate it:
--   ref / (ref + rolloff * (max(d, ref) - ref))
function NTx.DistanceGain(dist, ref, rolloff)
  ref = tonumber(ref) or 300
  rolloff = tonumber(rolloff) or 1
  dist = math.max(tonumber(dist) or 0, ref)
  return ref / (ref + rolloff * (dist - ref))
end

-- PannerNode cone gain: 1 inside the inner cone, linear down to
-- coneOuterGain at the outer cone edge, flat outside it.
function NTx.ConeGain(fwd, toListener, dir)
  if not IsVector(fwd) or not IsVector(toListener) then return 1 end
  dir = dir or NTx.DIR.MID
  local inner = (dir.Inner or 360) * 0.5
  local outer = (dir.Outer or 360) * 0.5
  local outerGain = dir.OuterVol == nil and 1 or dir.OuterVol
  if outer >= 180 then return 1 end
  local ang = math.acos(math.Clamp(fwd:Dot(toListener), -1, 1)) * 180 / math.pi
  if ang <= inner then return 1 end
  if ang >= outer then return outerGain end
  if outer <= inner then return outerGain end
  local t = (ang - inner) / (outer - inner)
  return 1 + (outerGain - 1) * t
end

-- MID directivity is an ELLIPSE: horizontal and vertical full angles are
-- independently adjustable (a wide-but-shallow main PA, or a narrow tall
-- column, without changing cabinets). The inner cone keeps NTx's inner:outer
-- ratio so changing FOV alters throw, not tonal balance.
NTx.MID_CONE_RATIO = 57 / 152
NTx.MID_FOV_MIN = 5
NTx.MID_FOV_MAX = 360

function NTx.MidConeAngles(hFov, vFov)
  hFov = math.Clamp(tonumber(hFov) or 152, NTx.MID_FOV_MIN, NTx.MID_FOV_MAX)
  vFov = math.Clamp(tonumber(vFov) or 57, NTx.MID_FOV_MIN, NTx.MID_FOV_MAX)
  local r = NTx.MID_CONE_RATIO
  return {
    HOut = hFov * 0.5, VOut = vFov * 0.5,
    HIn = hFov * 0.5 * r, VIn = vFov * 0.5 * r,
    HOutFull = hFov, VOutFull = vFov,
  }
end

-- Elliptical cone gain in the cabinet's own frame (yaw + pitch + roll), so
-- a tilted or rolled MID keeps its throw aligned with its grille.
-- delta = listenerPos - pos. The forward component is NOT mirrored: a
-- listener behind the grille is outside the coverage, full stop (the old
-- math.abs here treated the rear hemisphere as on-axis, so cabinets
-- blasted full volume backwards).
function NTx.MidConeGain(pos, ang, delta, hFov, vFov, outerGain)
  if delta:Length() < 0.001 then return 1 end
  local a = NTx.MidConeAngles(hFov, vFov)
  local f = ang:Forward()
  local df = delta:Dot(f)
  if df <= 0 then return outerGain end
  local r = ang:Right()
  local u = ang:Up()
  local hAng = math.deg(math.atan2(math.abs(delta:Dot(r)), df))
  local vAng = math.deg(math.atan2(math.abs(delta:Dot(u)), df))
  if hAng <= a.HIn and vAng <= a.VIn then return 1 end
  if hAng >= a.HOut or vAng >= a.VOut then return outerGain end
  -- Between the cones: blend by whichever axis is further out, normalised
  -- against the outer angle, so the two axes stay independent.
  local t = math.max(hAng / a.HOut, vAng / a.VOut)
  local k = math.Clamp((t - NTx.MID_CONE_RATIO) / (1 - NTx.MID_CONE_RATIO), 0, 1)
  return 1 + (outerGain - 1) * k
end

-- Rig coverage factor for a listener against every MID cabinet of one
-- mixer: the best (loudest) cone gain any cabinet gives. A listener inside
-- at least one throw hears full level; outside all of them the rig floors
-- at the cabinets' outer volume - 0.2 for plain cabinets, lower (0.06) for
-- self-cardioid ones. No MID cabinets, or no usable transform, means no
-- attenuation (1). Used by backends that render a whole mixer through one
-- tap (BASS fallback bus); the WebAudio path applies MidConeGain per tap.
function NTx.CoverageGain(allSpeakers, mixerEnt, listenerPos)
  local best = nil
  for _, s in ipairs(allSpeakers or {}) do
    if s.stype == "MID" and s.mixer == mixerEnt then
      local pos = (IsValid(s.ent) and s.ent:GetPos()) or s.pos
      local ang = (IsValid(s.ent) and s.ent:GetAngles()) or s.ang
      if pos and ang then
        local hFov = (s.hFov ~= 0) and s.hFov or 152
        local vFov = (s.vFov ~= 0) and s.vFov or 57
        local outerVol = NTx.DIR.MID.OuterVol
        if s.selfcard then hFov, vFov, outerVol = 90, 180, NTx.CARDIOID_MIN_GAIN end
        local g = NTx.MidConeGain(pos, ang, listenerPos - pos, hFov, vFov, outerVol)
        if not best or g > best then best = g end
      end
    end
  end
  return best or 1
end

-- ------------------------------------------------------------------ bus ids
--
-- A source carries four independent levels: MID and SUB, left and right. They
-- are separate because a MID bus and a SUB bus are genuinely different mixes -
-- each has its own fader and mute - and the amplifier channel a signal lands on
-- decides which of them the cabinets there should play.
--
-- The id is the wire contract between the mixer and the amplifier: the mixer
-- publishes it on a port beside the level, so an amplifier learns what it is
-- being fed by being wired, not by being told in a panel.
--
-- MidL/MidR and SubL/SubR select one SIDE of the stereo programme: a cabinet
-- on MidL plays the left channel and nothing else, which is what stops both
-- sides arriving from every box. SubMono is the odd one out - it is the
-- genuine sum of both channels, because a sub is fed a mono signal in a real
-- rig and picking a side there would throw half the content away.
NTx.BUS_MIDL, NTx.BUS_MIDR, NTx.BUS_SUBL, NTx.BUS_SUBR = 0, 1, 2, 3
NTx.BUS_SUBMONO = 4
NTx.BUS_COUNT = 5

-- Width of one channel's bus in the amplifier's packed NetworkVar. Three bits,
-- not two: five buses no longer fit in two, and eight channels of three bits is
-- 24 - comfortably inside the Int that carries them.
NTx.BUS_PACK_BITS = 3
NTx.BUS_PACK_MASK = 7

-- Index of a bus inside the array a source carries. Same order as the ids
-- above, which keeps the array index and the published identifier equal -
-- one number means the same thing on both sides of the wire.
NTx.BUS_NAMES = { "MidL", "MidR", "SubL", "SubR", "SubMono" }
NTx.BUS_PORTS = { "MidL", "MidR", "SubL", "SubR", "SubMono" }

function NTx.BusIsSub(id)
  return NTx.BusClamp(id) >= NTx.BUS_SUBL
end

-- Which channel of the source a bus plays. 0 = left only, 1 = right only,
-- 2 = both, summed. BusSide is the two-valued form for callers that only ever
-- deal with a stereo pair.
function NTx.BusSideOf(id)
  local n = NTx.BusClamp(id)
  if n == NTx.BUS_SUBMONO then return 2 end
  return n % 2
end

function NTx.BusSide(id)
  -- 0 = left, 1 = right. SubMono reports left here deliberately: a caller
  -- with only a two-way choice must never be handed half of a mono sum.
  local s = NTx.BusSideOf(id)
  return (s == 2) and 0 or s
end

function NTx.BusName(id)
  return NTx.BUS_NAMES[NTx.BusClamp(id) + 1] or "MidL"
end

function NTx.BusClamp(id)
  return math.Clamp(math.floor(tonumber(id) or 0), 0, NTx.BUS_COUNT - 1)
end

-- Port name to id, for the amplifier reading what the mixer published:
-- "SubR" -> 3, "SubMono" -> 4.
function NTx.BusOfPort(port)
  if type(port) ~= "string" then return nil end
  local base = port:gsub("Bus$", "")
  for i, name in ipairs(NTx.BUS_PORTS) do
    if base == name then return i - 1 end
  end
  return nil
end
