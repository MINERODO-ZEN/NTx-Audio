-- Server: measured programme level, reported by clients that can hear it.
--
-- The audio itself never leaves the client: WebAudio decodes the stream in the
-- browser page, so the server only ever saw fader positions. Mains draw, output
-- watts, thermal load and speaker drive were therefore constant no matter what
-- was playing. The page already measures real source RMS through an analyser and
-- hands it to the client (NTx.PageRms); this is the path that gets it into the
-- authoritative simulation.
--
-- Trust: these numbers are client-authored, so they are clamped on arrival, rate
-- limited per player, and dropped once stale - after which the fader-only
-- estimate takes over again. A client can push an amplifier harder than the
-- programme warrants; it cannot request arbitrary behaviour.
--
-- Cadence is assigned by the server, not chosen by the client:
--   - a player who owns at least one amplifier reports every server tick
--   - anyone else with WebAudio available reports every quarter tick
-- Clients that never report - legacy, BASS fallback, no WebAudio - simply leave
-- every input on the fader-only estimate.
AddCSLuaFile()
if not SERVER then return end

NTx = NTx or {}

util.AddNetworkString("NTx.AmpRms")
util.AddNetworkString("NTx.AmpRmsReady")
util.AddNetworkString("NTx.AmpRmsCadence")
util.AddNetworkString("NTx.AmpRmsCadenceReq")

-- input entity -> { v = level 0-1, at = CurTime(), by = Player }
NTx.LiveRms = NTx.LiveRms or {}

-- How long a report stays good. The client ages its own PageRms at one second,
-- so matching that means a reporter that drops out does not freeze the meters
-- at whatever it last said.
local RMS_TTL = 1.0

-- The level for one input, or nil when nobody has reported recently. Callers
-- treat nil as "use the fader estimate".
function NTx.MeasuredRms(ent)
  if not IsValid(ent) then return nil end
  local r = NTx.LiveRms[ent]
  if not r then return nil end
  if (CurTime() - r.at) > RMS_TTL then return nil end
  return r.v
end

-- Anti-spam: a client may claim at most twice its assigned cadence, so one that
-- ignores the assignment cannot flood the server.
local function rateOk(ply)
  local now = CurTime()
  local last = ply.__ntxRmsAt or 0
  if now - last < (ply.__ntxRmsEvery or TICK * 4) * 2 then return false end
  ply.__ntxRmsAt = now
  return true
end

-- Does this player own an amplifier? That is what earns them the faster cadence.
local function ownsAnAmp(ply)
  for _, amp in ipairs(ents.FindByClass("ntx_amplifier")) do
    if IsValid(amp) then
      local owner = amp.CPPIGetOwner and amp:CPPIGetOwner() or NULL
      if owner == ply then return true end
    end
  end
  return false
end

local function setReady(ply, ready)
  ply.__ntxRmsReady = ready == true
  if not ready then
    ply.__ntxRmsEvery = nil
    ply.__ntxRmsOwner = nil
    return
  end
  local isOwner = ownsAnAmp(ply)
  ply.__ntxRmsOwner = isOwner
  local every = isOwner and TICK or (TICK * 4)
  if ply.__ntxRmsEvery == every then return end
  ply.__ntxRmsEvery = every
  net.Start("NTx.AmpRmsCadence")
  net.WriteFloat(every)
  net.Send(ply)
end

-- The client says whether it currently has a working audio page, so the server
-- only ever asks players who can actually answer.
net.Receive("NTx.AmpRmsReady", function(_, ply)
  if not IsValid(ply) then return end
  setReady(ply, net.ReadBool() == true)
end)

net.Receive("NTx.AmpRms", function(_, ply)
  if not IsValid(ply) or not ply.__ntxRmsReady then return end
  if not rateOk(ply) then return end
  local count = net.ReadUInt(6)
  if count > 64 then return end
  local now = CurTime()
  for _ = 1, count do
    local ent = Entity(net.ReadUInt(16))
    local v = net.ReadFloat()
    -- Only real inputs, only a sane level. Anything else is dropped, not
    -- stored, so a crafted packet cannot poison the model.
    if IsValid(ent) and ent:GetClass() == "ntx_input_url" then
      NTx.LiveRms[ent] = {
        v = math.Clamp(tonumber(v) or 0, 0, 1),
        at = now,
        by = ply,
      }
    end
  end
end)

-- Client asks for its cadence, on join and whenever the page state changes.
net.Receive("NTx.AmpRmsCadenceReq", function(_, ply)
  if not IsValid(ply) then return end
  setReady(ply, ply.__ntxRmsReady == true)
end)

hook.Add("PlayerInitialSpawn", "NTx.AmpRmsSpawn", function(ply)
  -- The client's announce usually lands first; this covers the case where the
  -- amplifier ownership is already known by the time the player arrives.
  timer.Simple(4, function()
    if IsValid(ply) and ply.__ntxRmsReady then setReady(ply, true) end
  end)
end)

-- Ownership can change mid-session, so the cadence is re-evaluated on a timer as
-- well as on announce.
timer.Create("NTx.RmsCadenceWatch", 2, 0, function()
  for _, ply in ipairs(player.GetAll()) do
    if IsValid(ply) and ply.__ntxRmsReady then
      local isOwner = ownsAnAmp(ply)
      if ply.__ntxRmsOwner ~= isOwner then setReady(ply, true) end
    end
  end
end)

-- Drop stale entries so the table does not grow with every input anyone ever
-- reported. Runs on Think, like the simulation it feeds.
hook.Add("Think", "NTx.AmpRmsSweep", function()
  local now = CurTime()
  for ent, r in pairs(NTx.LiveRms) do
    if not IsValid(ent) or (now - r.at) > (RMS_TTL * 4) then
      NTx.LiveRms[ent] = nil
    end
  end
end)