-- Client: BASS FALLBACK backend. Renders ONLY ntx_fallback_bus entities:
-- one full-spectrum tap per input at the nearest bus of its mixer.
-- Regular speakers are never touched here; they belong to the WebAudio /
-- binary-module backend. (BASS exposes no DSP, so no HP/LP, no cardioid
-- delay and no array shading exist on this path by design.)
if not CLIENT then return end
if NTx_DspLoaded then return end
NTx_DspLoaded = true

NTx = NTx or {}
NTx.Graph = { inputs = {}, speakers = {}, mixers = {}, fallbacks = {} }
NTx.Stations = NTx.Stations or {}
NTx.WantStations = NTx.WantStations or {}
-- IGModAudioChannel is userdata: arbitrary fields cannot be stamped on it,
-- so the URL behind each station key lives here instead.
NTx.StationURL = NTx.StationURL or {}
NTx.StationFlat = NTx.StationFlat or {}
-- Next allowed (re)open time per key. Stops a failing stream from opening
-- a new Icecast connection every Think tick.
NTx.StationRetry = NTx.StationRetry or {}
NTx.BassTaps = NTx.BassTaps or {}

-- Backend selector. "auto" uses WebAudio once the probe passes, else BASS.
-- Effective backend is webaudio only when selected AND capable AND the
-- WebAudio manager file is present; everything else renders BASS fallback.
local cvBackend = CreateClientConVar("ntx_backend", "auto", true, false,
  "Audio backend: auto = WebAudio if capable else BASS fallback buses; webaudio / bass force one")
local cvMuteDist = CreateClientConVar("ntx_mute_distance", "5000", true, false,
  "Beyond min(input range + 1000, this) in units, fallback taps hard-mute (Icecast slot freed)")
-- Cone/coverage tracer: when on, both backends print the per-tap factors
-- (type, distance, cone/coverage gain, range fade, final gain) every 2 s.
-- This is how you tell "math says full volume" apart from "gain lost downstream".
NTx.CvConeDebug = CreateClientConVar("ntx_cone_debug", "0", true, false,
  "Print per-tap cone/coverage factors every 2 s (WebAudio taps + BASS bus)")
-- Mix headroom in dB below the limiter threshold. 0 = park the mix on the
-- limiter (which flattens directivity); -6 = safe default. Clamped -12..0.
-- Created here (first client module) so the ConVar exists before the
-- Utilities page reads it; the value is read by NTx.MixHeadroomGain through
-- GetConVar, which is why this local is never dereferenced here.
CreateClientConVar("ntx_headroom_db", "-6", true, false,
  "Audibility-normaliser target in dBFS (-12..0): keep the mix under the limiter so cone ratios survive")
NTx.WebAudioOK = NTx.WebAudioOK or false
NTx.Tainted = NTx.Tainted or {}
NTx.MuteState = NTx.MuteState or {}
NTx.StationAttempts = NTx.StationAttempts or {}
NTx.Downgraded = NTx.Downgraded or {}

function NTx.EffectiveBackend()
  local want = string.lower(cvBackend:GetString() or "auto")
  if (want == "auto" or want == "webaudio") and NTx.WebAudioOK and NTx.WebAudio ~= nil then
    return "webaudio"
  end
  return "bass"
end

local function mixerRecFor(mixerEnt)
  for _, m in ipairs(NTx.Graph.mixers) do
    if m.ent == mixerEnt then return m end
  end
  return nil
end

-- Fallback gain: master + channel only, logarithmic. Bus faders/mutes are
-- ignored because the fallback tap is a single full-spectrum channel by design.
local function fallbackGain(mixerRec, inputEnt)
  if not mixerRec then return 0 end
  if mixerRec.mm then return 0 end
  local gain = NTx.FaderToGain(mixerRec.master)
  for _, ch in ipairs(mixerRec.channels) do
    if ch.input == inputEnt then
      if ch.muted then return 0 end
      return gain * NTx.FaderToGain(ch.fader)
    end
  end
  return gain
end

-- Nearest fallback bus linked to this mixer. Only one bus per mixer renders,
-- so the same stream is never opened twice (no phase drift).
local function nearestFallback(mixerEnt, listenerPos)
  local best, bestD
  for _, b in ipairs(NTx.Graph.fallbacks) do
    if IsValid(b.ent) and b.mixer == mixerEnt then
      local d = listenerPos:DistToSqr(b.pos)
      if not bestD or d < bestD then best, bestD = b, d end
    end
  end
  return best
end

local FB_CONE = { Inner = 360, Outer = 360, OuterVol = 1 }

-- BASS error codes that mean "plain stereo may still work" (StreamRadio
-- retry_errors_non3d set: 3D-Stream-Radio lua/streamradio_core/stream.lua).
local DOWNGRADE_ERRS = { [41] = true, [21] = true, [22] = true, [2] = true, [-1] = true }

-- 2D taps are plain stereo (flags "") while 3D taps need "3d mono".
-- BASS flags are fixed at creation, so the mode is part of the key:
-- flipping a bus reopens its taps instead of corrupting them.
local function ensureStation(key, url, flat)
  flat = flat == true
  local st = NTx.Stations[key]
  if IsValid(st) then
    if NTx.StationURL[key] ~= url or (NTx.StationFlat[key] or false) ~= flat then
      st:Stop()
      NTx.Stations[key] = nil
      NTx.StationURL[key] = nil
      NTx.StationFlat[key] = nil
    else
      return st
    end
  else
    NTx.Stations[key] = nil
    NTx.StationURL[key] = nil
    NTx.StationFlat[key] = nil
  end
  if NTx.WantStations[key] then return nil end
  if (NTx.StationRetry[key] or 0) > CurTime() then return nil end
  -- Minimum gap between opens: a tap that dies after playing must not
  -- reconnect every Think tick (same listener-climb as a failing stream).
  NTx.StationRetry[key] = CurTime() + 2
  NTx.WantStations[key] = true
  sound.PlayURL(url, flat and "" or "3d mono", function(chan, err, errStr)
    NTx.WantStations[key] = nil
    if IsValid(chan) then
      NTx.Stations[key] = chan
      NTx.StationURL[key] = url
      NTx.StationFlat[key] = flat
      NTx.StationAttempts[key] = nil
      chan:Play()
    else
      local att = (NTx.StationAttempts[key] or 0) + 1
      NTx.StationAttempts[key] = att
      -- 3 strikes at 5 s, then maintenance polling: live radio never
      -- gives up, but never hammers either.
      NTx.StationRetry[key] = CurTime() + (att <= 3 and 5 or 30)
      local dgkey = "dg|" .. url
      if not flat and DOWNGRADE_ERRS[err] and not NTx.Downgraded[dgkey] then
        NTx.Downgraded[dgkey] = true
        print("[NTx] BASS 3D open failed (err " .. tostring(err) .. "); retrying as 2D stereo: " .. url)
      else
        print("[NTx] PlayURL failed (" .. tostring(err) .. "): " .. tostring(errStr) .. " url=" .. url)
      end
    end
  end)
  return nil
end

-- 3D taps glide toward their target every frame (see the per-frame hook):
-- SetPos at push rate alone is a staircase and clicks when a bus moves.
local function driveStation(key, url, flat, pos, maxd, gain)
  local chan = ensureStation(key, url, flat)
  if not IsValid(chan) then return end
  if not flat then
    NTx.BassTaps[key] = NTx.BassTaps[key] or { cur = pos }
    NTx.BassTaps[key].tgt = pos
    NTx.BassTaps[key].chan = chan
    if not NTx.BassTaps[key].cur then NTx.BassTaps[key].cur = pos end
    pcall(chan.Set3DCone, chan, FB_CONE.Inner, FB_CONE.Outer, FB_CONE.OuterVol)
    chan:Set3DFadeDistance(300, maxd)
  end
  chan:SetVolume(math.Clamp(gain, 0, 3))
  if chan:GetState() ~= GMOD_CHANNEL_PLAYING then chan:Play() end
end

-- Per-frame position smoothing for BASS 3D taps, matching the WebAudio
-- backend's time constant so both paths feel the same.
local cvBassSmooth = CreateClientConVar("ntx_bass_smooth", "60", true, false,
  "BASS 3D tap position smoothing time constant in ms")

hook.Add("Think", "NTx.DspMotion", function()
  local dt = FrameTime()
  if dt <= 0 then return end
  local tau = math.Clamp(cvBassSmooth:GetFloat() or 60, 0, 500) / 1000
  local a = (tau > 0) and (1 - math.exp(-dt / tau)) or 1
  for key, t in pairs(NTx.BassTaps) do
    if IsValid(t.chan) and t.tgt and t.cur then
      local step = (t.tgt - t.cur) * a
      t.cur = t.cur + step
      t.chan:SetPos(t.cur)
    end
  end
end)

local nextTick = 0
local lastBackend = nil

hook.Add("Think", "NTx.DspThink", function()
  if CurTime() < nextTick then return end
  nextTick = CurTime() + 0.1
  -- No silent backends: the operator always knows what is making sound.
  local backend = NTx.EffectiveBackend()
  if backend ~= lastBackend then
    lastBackend = backend
    print("[NTx] effective backend: " .. backend
      .. " (probe: " .. tostring(NTx.WebAudioDetail or "not run") .. ")")
  end
  local maxCv = GetConVar("ntx_max_channels")
  local maxSrc = maxCv and maxCv:GetInt() or 16
  local seen = {}
  local count = 0

  local function budgetOk()
    count = count + 1
    return count <= math.Clamp(maxSrc, 1, NTx.MAX_SOURCES)
  end

  -- Under WebAudio, BASS only covers CORS-tainted inputs the page graph
  -- cannot touch; each of those still gets exactly one tap at a bus.
  -- Under BASS, every input renders here and speakers stay dark.
  local taintedOnly = NTx.EffectiveBackend() ~= "bass"
  local now = CurTime()
  local lp = LocalPlayer():GetPos()
  local muteDist = cvMuteDist:GetInt() or 5000
  local usedUrl = {}
  local wallCache = {}
  local bassEnergy = 0
  local pendingTaps = {}
  for iIdx, input in ipairs(NTx.Graph.inputs) do
    if not IsValid(input.mixer) then continue end
    if taintedOnly and not ((NTx.Tainted and NTx.Tainted[input.ent])
      or (NTx.PageBroken and NTx.PageBroken[input.ent])) then continue end
    local mrec = mixerRecFor(input.mixer)
    if not mrec then continue end
    local bus = nearestFallback(input.mixer, lp)
    if not bus then continue end
    local url = input.url or ""
    if url == "" then continue end
    -- Same stream linked twice (or on two inputs) still opens once.
    local dukey = input.mixer:EntIndex() .. "|" .. url
    if usedUrl[dukey] then continue end
    usedUrl[dukey] = true
    local maxd = math.Clamp(input.maxd or 1200, 100, 10000)
    local distSqr = lp:DistToSqr(bus.pos)
    local flat = bus.flat == true or NTx.Downgraded["dg|" .. url] == true
    local key = (flat and "fb2d|" or "fb|") .. iIdx .. "|" .. url
    -- Hard mute beyond min(maxd + 1000, mute distance) with 1 s
    -- hysteresis: the tap is stopped (frees the Icecast slot).
    local muteRange = math.min(maxd + 1000, muteDist)
    if distSqr > muteRange * muteRange then
      if now - (NTx.MuteState[key] or 0) > 1 then continue end
    else
      NTx.MuteState[key] = now
    end
    -- One star-trace set per bus per tick, shared by its inputs.
    local bkey = bus.ent:EntIndex()
    local wall = wallCache[bkey]
    if wall == nil then
      wall = (NTx.WallFactor and NTx.WallFactor(bus.ent, bus.pos)) or 1
      wallCache[bkey] = wall
    end
    local dist = math.sqrt(distSqr)
    local baseGain = fallbackGain(mrec, input.ent) * (input.vol or 1) * (bus.trim or 1) * wall
    -- Rig coverage: the bus tap stands in for the whole mixer, so it gets
    -- the best cone gain any of the mixer's MID cabinets gives the
    -- listener (1 in a throw, 0.2/0.06 floor outside it).
    local coverage = NTx.CoverageGain(NTx.Graph.speakers, input.mixer, lp)
    local gain = baseGain * coverage
    if NTx.CvConeDebug and NTx.CvConeDebug:GetBool() and CurTime() >= (NTx.NextBassConeDbg or 0) then
      NTx.NextBassConeDbg = CurTime() + 2
      print(string.format("[NTx cone/BASS] in=%s bus=%s coverage=%.3f gain=%.4f dist=%.0f/%.0f",
        tostring(IsValid(input.ent) and input.ent:EntIndex() or "?"),
        tostring(IsValid(bus.ent) and bus.ent:EntIndex() or "?"),
        coverage, gain, dist, maxd))
    end
    if flat then
      -- 2D taps get no engine attenuation: manual triangular fade.
      gain = gain * NTx.CalcDistanceVolume(dist, maxd)
    end
    if gain <= 0.001 then continue end
    -- Estimate audible energy the same way the WebAudio path does, so both
    -- backends normalise against each other consistently. For BASS the gain
    -- already carries distance fade + wall occlusion, so square it.
    bassEnergy = bassEnergy + (gain * gain)
    pendingTaps[#pendingTaps + 1] = { key = key, url = url, flat = flat,
      pos = bus.pos, maxd = maxd, gain = gain }
    seen[key] = true
    if not budgetOk() then continue end
    driveStation(key, url, flat, bus.pos, maxd, gain)
  end

  -- Publish for the WebAudio path and normalise our own taps against it, so
  -- whichever backend is live the summed level stays under control.
  NTx.BassEnergy = math.Clamp(bassEnergy, 0, 64)
  NTx.BassEnergyAt = now
  local webEnergy = 0
  if tonumber(NTx.WebEnergyAt or 0) > 0 and (now - NTx.WebEnergyAt) < 1 then
    webEnergy = math.Clamp(tonumber(NTx.WebEnergy) or 0, 0, 64)
  end
  local totalEnergy = bassEnergy + webEnergy
  local norm = NTx.HeadroomNorm(totalEnergy)
  for _, t in ipairs(pendingTaps) do
    local chan = NTx.Stations[t.key]
    if IsValid(chan) then chan:SetVolume(math.Clamp(t.gain * norm, 0, 3)) end
  end

  for key, chan in pairs(NTx.Stations) do
    if not seen[key] then
      if IsValid(chan) then chan:Stop() end
      NTx.Stations[key] = nil
      NTx.StationURL[key] = nil
      NTx.StationFlat[key] = nil
      NTx.MuteState[key] = nil
      NTx.StationAttempts[key] = nil
      NTx.BassTaps[key] = nil
    end
  end
end)

net.Receive("NTx.GraphSync", function()
  local g = { inputs = {}, speakers = {}, mixers = {}, fallbacks = {} }
  local nIn = net.ReadUInt(8)
  for _ = 1, nIn do
    g.inputs[#g.inputs + 1] = {
      ent = net.ReadEntity(), class = net.ReadString(),
      url = net.ReadString(),
      vol = net.ReadFloat(), maxd = net.ReadFloat(), mixer = net.ReadEntity(),
    }
  end
  local nSp = net.ReadUInt(12)
  for _ = 1, nSp do
    g.speakers[#g.speakers + 1] = {
      ent = net.ReadEntity(), stype = net.ReadString(), array = net.ReadString(),
      reversed = net.ReadBool(), selfcard = net.ReadBool(),
      hFov = net.ReadFloat(), vFov = net.ReadFloat(),
      pos = net.ReadVector(), ang = net.ReadAngle(),
      mixer = net.ReadEntity(),
    }
  end
  local nFb = net.ReadUInt(8)
  for _ = 1, nFb do
    g.fallbacks[#g.fallbacks + 1] = {
      ent = net.ReadEntity(), pos = net.ReadVector(),
      trim = net.ReadFloat(), flat = net.ReadBool(), label = net.ReadString(),
      mixer = net.ReadEntity(),
    }
  end
  local nMx = net.ReadUInt(8)
  for _ = 1, nMx do
    local m = {
      ent = net.ReadEntity(), master = net.ReadFloat(), mm = net.ReadBool(),
      mid = net.ReadFloat(), midm = net.ReadBool(),
      sub = net.ReadFloat(), subm = net.ReadBool(), channels = {},
    }
    local nCh = net.ReadUInt(8)
    for _ = 1, nCh do
      m.channels[#m.channels + 1] = {
        input = net.ReadEntity(), fader = net.ReadFloat(),
        muted = net.ReadBool(), label = net.ReadString(),
      }
    end
    g.mixers[#g.mixers + 1] = m
  end
  NTx.Graph = g
end)

hook.Add("InitPostEntity", "NTx.AskSync", function()
  net.Start("NTx.RequestSync")
  net.SendToServer()
end)

hook.Add("OnReloaded", "NTx.AskSyncReload", function()
  net.Start("NTx.RequestSync")
  net.SendToServer()
end)
