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

-- input entity -> { l = left 0-1, r = right 0-1, v = mono 0-1, at, by = Player }
NTx.LiveRms = NTx.LiveRms or {}

-- How long a report stays good. The client ages its own PageRms at one second,
-- so matching that means a reporter that drops out does not freeze the meters
-- at whatever it last said.
local RMS_TTL = 1.0

-- Wire format marker, matched against the one in the client half.
local RMS_PROTO = 3
local warnedProto = false

-- The level for one input, or nil when nobody has reported recently. Callers
-- treat nil as "use the fader estimate".
--
-- side picks which part of the programme: 0 left, 1 right, nil the mono sum.
-- The buses are side-specific - MidL has to see only the left programme or its
-- meter is reading the wrong signal - so this cannot stay a single number.
function NTx.MeasuredRms(ent, bus)
  if not IsValid(ent) then return nil end
  local r = NTx.LiveRms[ent]
  if not r then return nil end
  if (CurTime() - r.at) > RMS_TTL then return nil end
  local v = istable(r.b) and r.b[(math.floor(tonumber(bus) or 0)) + 1] or nil
  return tonumber(v) or r.v
end


-- Server tick interval. TICK is not dependable on the server realm - it is
-- documented as a client-side global - and reading it at file scope would also
-- depend on load order, so this is resolved per call with a sane fallback.
local function tickInterval()
  if type(TICK) == "number" and TICK > 0 then return TICK end
  local ok, v = pcall(function() return engine.TickInterval() end)
  if ok and type(v) == "number" and v > 0 then return v end
  return 1 / 66
end

-- Anti-spam: a client may claim at most twice its assigned cadence, so one that
-- ignores the assignment cannot flood the server.
local function rateOk(ply)
  local now = CurTime()
  local last = ply.__ntxRmsAt or 0
  if now - last < (ply.__ntxRmsEvery or (tickInterval() * 4)) * 2 then return false end
  ply.__ntxRmsAt = now
  return true
end

-- Does anyone own an amplifier at all?
--
-- An amplifier with no CPPI owner is the normal case on a server where rigs are
-- public, and then NOBODY qualifies for the faster cadence - the owner ran off,
-- or the rig was spawned from console. The result was the person actually
-- watching the rig silently getting quarter rate. So when no player owns an
-- amplifier, the throttle has no purpose and everyone with WebAudio reports at
-- tick rate.
local function anyAmpOwned()
  for _, amp in ipairs(ents.FindByClass("ntx_amplifier")) do
    if IsValid(amp) then
      local owner = amp.CPPIGetOwner and amp:CPPIGetOwner() or NULL
      if IsValid(owner) then return true end
    end
  end
  return false
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
  -- Owner of a rig: tick rate. Otherwise quarter tick rate, but only while
  -- somebody actually owns something - otherwise there is nothing to protect
  -- the tick rate from, so everyone gets it.
  local base = tickInterval()
  local every
  if isOwner or not anyAmpOwned() then
    every = base
  else
    every = base * 4
  end
  if ply.__ntxRmsEvery == every then return end
  ply.__ntxRmsEvery = every
  net.Start("NTx.AmpRmsCadence")
  net.WriteFloat(every)
  net.Send(ply)
  print(string.format("[NTx] %s will report measured levels every %.4fs (%s).",
    ply:Nick(), every,
    isOwner and "owns an amplifier" or (anyAmpOwned() and "no amplifier" or "no amplifier is owned")))
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
  -- Format marker first. A client whose addon Lua is older than the server
  -- sends a different layout, and reading it as this one would consume the
  -- wrong floats - producing plausible-looking but wrong levels everywhere,
  -- which is far worse than having none. Each net message is self-contained,
  -- so abandoning it here simply leaves those inputs on the fader estimate.
  if net.ReadUInt(8) ~= RMS_PROTO then
    if not warnedProto then
      warnedProto = true
      print("[NTx] AmpRms: a client is reporting an older format; "
        .. "its measured levels are ignored until it updates.")
    end
    return
  end
  local count = net.ReadUInt(6)
  if count > 64 then return end
  local now = CurTime()
  for _ = 1, count do
    local ent = Entity(net.ReadUInt(16))
    local b = {}
    for i = 1, 5 do b[i] = net.ReadFloat() end
    -- Only real inputs, only sane levels. Anything else is dropped, not
    -- stored, so a crafted packet cannot poison the model.
    if IsValid(ent) and ent:GetClass() == "ntx_input_url" then
      for i = 1, 5 do b[i] = math.Clamp(tonumber(b[i]) or 0, 0, 1) end
      NTx.LiveRms[ent] = {
        b = b,
        -- Mono of the two sides, kept so an older caller that does not know
        -- about buses still gets a single usable level.
        v = math.sqrt((b[1] * b[1] + b[2] * b[2]) * 0.5),
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

-- Ownership can change mid-session, and so can whether ANY amplifier is owned,
-- so the cadence is re-evaluated on a timer as well as on announce.
timer.Create("NTx.RmsCadenceWatch", 2, 0, function()
  local owned = anyAmpOwned()
  if owned ~= NTx.__ntxAnyAmpOwned then
    NTx.__ntxAnyAmpOwned = owned
  end
  for _, ply in ipairs(player.GetAll()) do
    if IsValid(ply) and ply.__ntxRmsReady then
      local isOwner = ownsAnAmp(ply)
      -- Reassign whenever this player's ownership changed, or whenever the
      -- "is anything owned" state flipped underneath everyone.
      if ply.__ntxRmsOwner ~= isOwner or ply.__ntxRmsOwnedAny ~= owned then
        ply.__ntxRmsOwnedAny = owned
        setReady(ply, true)
      end
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

-- ntx_chain: whole-rig dump, requested by a client and printed in that
-- client's console. It lives here rather than in its own autorun file because
-- every value that matters is server-side, and because a diagnostic that cannot
-- be run is not a diagnostic.
util.AddNetworkString("NTx.ChainReq")
util.AddNetworkString("NTx.ChainRep")

local BUS_ORDER = { "MidL", "MidR", "SubL", "SubR", "SubMono" }


  local function buildDump()
    local L, add = {}, nil
    add = function(s) L[#L + 1] = s end

    add("===== NTx signal chain =====")
    add("build: " .. tostring(NTx.COMMIT or "unknown"))
    add(string.format("convars: sim_hz=%s meter_hz=%s",
      tostring(GetConVar("ntx_amp_sim_hz") and GetConVar("ntx_amp_sim_hz"):GetFloat()),
      tostring(GetConVar("ntx_meter_hz") and GetConVar("ntx_meter_hz"):GetFloat())))
    add("bus ids: MidL=0 MidR=1 SubL=2 SubR=3 SubMono=4")
    add("")

    -- Sources: what they publish, and what they are measuring.
    local anySrc = false
    for _, e in ipairs(ents.FindByClass("ntx_input_url")) do
      anySrc = true
      local vals = {}
      for i = 1, 5 do
        vals[#vals + 1] = string.format("%.3f", tonumber(e.WireBuses and e.WireBuses[i]) or -1)
      end
      add(string.format("source %d  vol=%.2f  publishes=[%s]", e:EntIndex(),
        tonumber(e:GetInputVolume()) or 0, table.concat(vals, " ")))
      local r = NTx.LiveRms and NTx.LiveRms[e]
      if r then
        local mv = {}
        for bi = 1, 5 do
          mv[#mv + 1] = string.format("%.3f", tonumber(r.b and r.b[bi]) or -1)
        end
        add(string.format("    measured [%s]  (%.2fs old, by %s)",
          table.concat(mv, " "),
          CurTime() - (r.at or 0),
          IsValid(r.by) and r.by:Nick() or "?"))
      else
        add("    measured NONE (fader estimate only)")
      end
    end
    if not anySrc then add("source: NONE in the map") end
    add("")

    -- Mixers: their channels, and what each bus actually comes out at.
    local anyMx = false
    for _, mx in ipairs(ents.FindByClass("ntx_mixer")) do
      anyMx = true
      local outs = {}
      for b = 0, 4 do
        local ok, v = pcall(mx.ComputeBusOut, mx, b)
        outs[#outs + 1] = string.format("%s=%s", BUS_ORDER[b + 1],
          ok and string.format("%.3f", tonumber(v) or -1) or "ERR")
      end
      add(string.format("mixer %d  %s", mx:EntIndex(), table.concat(outs, " ")))
      local nCh = #(mx.Channels or {})
      add(string.format("    channels=%d master=%.2f%smid=%.2f%ssub=%.2f", nCh,
        tonumber(mx:GetMasterFader()) or -1, (mx:GetMasterMuted() and " MUTED" or " "),
        tonumber(mx:GetMidFader()) or -1, (mx:GetMidMuted() and " MUTED" or " "),
        tonumber(mx:GetSubFader()) or -1, (mx:GetSubMuted() and " MUTED" or "")))
      for i, ch in ipairs(mx.Channels or {}) do
        local port = "UNWIRED"
        for k = 1, 16 do
          if NTx.WireUpstream(mx, "In" .. k) == ch.Input then port = "In" .. k break end
        end
        local lvl = "?"
        for k = 1, 16 do
          if port == "In" .. k then
            local src = (mx.WireLevels or {})[k]
            lvl = istable(src) and string.format("%.3f", tonumber(src[1]) or -1) or "none"
          end
        end
        add(string.format("    ch%d  %-9s %-14s feeds=%-6s fader=%.2f%s  sees=%s",
          i, IsValid(ch.Input) and ch.Input:GetClass() or "?", port,
          "all", tonumber(ch.Fader) or -1,
          (ch.Muted and " MUTED" or ""), lvl))
      end
    end
    if not anyMx then add("mixer: NONE in the map") end
    add("")

    -- Amplifiers: what each channel is fed, and whether a wire feeds it at all.
    local anyAmp = false
    for _, amp in ipairs(ents.FindByClass("ntx_amplifier")) do
      anyAmp = true
      add(string.format("amp %d  mixer=%s  simHz=%s", amp:EntIndex(),
        IsValid(amp:GetMixer()) and amp:GetMixer():EntIndex() or "NONE",
        tostring(NTx.AmpSimEnabled and NTx.AmpSimEnabled() or "?")))
      for _, ch in ipairs(amp:ActiveChannels()) do
        local name = "Ch" .. ch .. "In"
        local src, srcPort = NTx.WireUpstream(amp, name)
        local id = amp:ChannelBusId(ch)
        add(string.format("    CH%d fed=%-5s bus=%-7s side=%d  src=%s/%s  wireSignal=%s",
          ch, tostring(amp:ChannelIsFed(ch)), NTx.BusName(id), NTx.BusSideOf(id),
          IsValid(src) and src:GetClass() or "NONE", tostring(srcPort),
          tostring(amp.WireSignal and amp.WireSignal[ch])))
      end
    end
    if not anyAmp then add("amp: NONE in the map") end
    return table.concat(L, "\n")
  end

  net.Receive("NTx.ChainReq", function(_, ply)
    if not IsValid(ply) then return end
    local ok, text = pcall(buildDump)
    net.Start("NTx.ChainRep")
    net.WriteString(ok and text or ("dump failed: " .. tostring(text)))
    net.Send(ply)
  end)
