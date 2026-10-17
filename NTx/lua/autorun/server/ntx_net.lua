-- Server: authoritative routing graph + validation.
AddCSLuaFile()
if not SERVER then return end

NTx = NTx or {}
NTx.Mixers = NTx.Mixers or {}

util.AddNetworkString("NTx.GraphSync")
util.AddNetworkString("NTx.MixerSync")
util.AddNetworkString("NTx.MixerEdit")
util.AddNetworkString("NTx.RequestSync")

CreateConVar("ntx_max_channels", "16", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Max audible NTx live sources per client")
CreateConVar("ntx_update_hz", "10", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Graph rebroadcast rate cap (Hz)")

-- Page host is server-owned: it decides where every client's WebAudio page
-- is loaded from, so clients must not be able to point it somewhere else
-- (a malicious value would fetch remote script into a privileged page).
-- FCVAR_REPLICATED syncs it to clients; only the server/console can set it:
--   ntx_page_base "https://host/path/"
-- The host must serve ntx_live_audio/webaudio.html and probe.html.
CreateConVar("ntx_page_base", "https://xta.xenonetwork.moe/dsp/",
  { FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY },
  "Base URL for NTx mixer/probe pages (server-controlled; trailing slash added if missing)")
CreateConVar("ntx_mixer_admin_only", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED,
  "Restrict NTx mixer edits to admins (CPPI owner or admin always allowed)")

local lastBroadcast = 0

-- Last-sent positions, for the movement refresh timer below.
NTx.LastSentPos = NTx.LastSentPos or {}

function NTx.CollectGraph()
  local g = { inputs = {}, speakers = {}, mixers = {}, fallbacks = {} }
  for _, e in ipairs(ents.FindByClass("ntx_input_url")) do
    if IsValid(e) then
      g.inputs[#g.inputs + 1] = {
        ent = e, class = "ntx_input_url",
        url = e:GetStreamUrl(),
        vol = e:GetInputVolume(), maxd = e:GetMaxDist(),
        mixer = IsValid(e:GetMixer()) and e:GetMixer() or nil,
      }
    end
  end
  for _, e in ipairs(ents.FindByClass("ntx_input_mic")) do
    if IsValid(e) then
      g.inputs[#g.inputs + 1] = {
        ent = e, class = "ntx_input_mic",
        url = e:GetStreamUrl(),
        vol = e:GetInputVolume(), maxd = e:GetMaxDist(),
        mixer = IsValid(e:GetMixer()) and e:GetMixer() or nil,
      }
    end
  end
  for _, e in ipairs(ents.FindByClass("ntx_speaker")) do
    if IsValid(e) then
      g.speakers[#g.speakers + 1] = {
        ent = e, stype = e:GetSpeakerType() ~= "" and e:GetSpeakerType() or "MID",
        array = e:GetArrayId() ~= "" and e:GetArrayId() or "A",
        reversed = e:GetReversed() == true, selfcard = e:GetSelfCardioid() == true,
        hFov = e:GetMidHFov(), vFov = e:GetMidVFov(),
        pos = e:GetPos(), ang = e:GetAngles(),
        mixer = IsValid(e:GetMixer()) and e:GetMixer() or nil,
      }
    end
  end
  for _, e in ipairs(ents.FindByClass("ntx_fallback_bus")) do
    if IsValid(e) then
      g.fallbacks[#g.fallbacks + 1] = {
        ent = e, pos = e:GetPos(),
        trim = e:GetTrim(), label = e:GetBusLabel(), flat = e:GetFlat2D() == true,
        mixer = IsValid(e:GetMixer()) and e:GetMixer() or nil,
      }
    end
  end
  for mixer in pairs(NTx.Mixers) do
    if IsValid(mixer) then
      local chs = {}
      for _, ch in ipairs(mixer.Channels or {}) do
        if IsValid(ch.Input) then
          chs[#chs + 1] = { input = ch.Input, fader = ch.Fader, muted = ch.Muted, label = ch.Label }
        end
      end
      g.mixers[#g.mixers + 1] = {
        ent = mixer,
        master = mixer:GetMasterFader(), mm = mixer:GetMasterMuted(),
        mid = mixer:GetMidFader(), midm = mixer:GetMidMuted(),
        sub = mixer:GetSubFader(), subm = mixer:GetSubMuted(),
        channels = chs,
      }
    end
  end
  return g
end

function NTx.BroadcastGraph(target)
  local now = CurTime()
  if now - lastBroadcast < 1 / GetConVar("ntx_update_hz"):GetFloat() then return end
  lastBroadcast = now
  local g = NTx.CollectGraph()
  net.Start("NTx.GraphSync")
  net.WriteUInt(#g.inputs, 8)
  for _, i in ipairs(g.inputs) do
    net.WriteEntity(i.ent)
    net.WriteString(i.class)
    net.WriteString(string.sub(i.url or "", 1, 512))
    net.WriteFloat(math.Clamp(i.vol or 1, 0, 2))
    net.WriteFloat(math.Clamp(i.maxd or 1200, 100, 10000))
    net.WriteEntity(i.mixer or NULL)
  end
  net.WriteUInt(#g.speakers, 12)
  for _, s in ipairs(g.speakers) do
    net.WriteEntity(s.ent)
    net.WriteString(NTx.IsSpeakerType(s.stype) and s.stype or "MID")
    net.WriteString(string.sub(s.array or "A", 1, 32))
    net.WriteBool(s.reversed)
    net.WriteBool(s.selfcard)
    net.WriteFloat(math.Clamp(s.hFov or 152, 5, 360))
    net.WriteFloat(math.Clamp(s.vFov or 57, 5, 360))
    net.WriteVector(s.pos)
    net.WriteAngle(s.ang)
    net.WriteEntity(s.mixer or NULL)
  end
  net.WriteUInt(#g.fallbacks, 8)
  for _, b in ipairs(g.fallbacks) do
    net.WriteEntity(b.ent)
    net.WriteVector(b.pos)
    net.WriteFloat(math.Clamp(b.trim or 1, 0, 2))
    net.WriteBool(b.flat == true)
    net.WriteString(string.sub(b.label or "", 1, 32))
    net.WriteEntity(b.mixer or NULL)
  end
  net.WriteUInt(#g.mixers, 8)
  for _, m in ipairs(g.mixers) do
    net.WriteEntity(m.ent)
    net.WriteFloat(m.master)
    net.WriteBool(m.mm)
    net.WriteFloat(m.mid)
    net.WriteBool(m.midm)
    net.WriteFloat(m.sub)
    net.WriteBool(m.subm)
    net.WriteUInt(#m.channels, 8)
    for _, ch in ipairs(m.channels) do
      net.WriteEntity(ch.input)
      net.WriteFloat(ch.fader)
      net.WriteBool(ch.muted)
      net.WriteString(string.sub(ch.label or "", 1, 24))
    end
  end
  if target then net.Send(target) else net.Broadcast() end
end

-- Movement refresh: the AUDIO paths only know positions from the last
-- broadcast, so poll for moved/rotated/removed speaker and fallback-bus
-- entities and rebroadcast. Gizmos do not need this: they read the live
-- entity transform every frame, so physgunned stacks track exactly with no
-- timer involved.
timer.Create("NTx.PositionRefresh", 0.5, 0, function()
  local moved = false
  local seen = {}
  local function track(e)
    if not IsValid(e) then return end
    seen[e] = true
    -- Full orientation, not yaw alone: a cabinet tilted down with the
    -- physgun (pitch/roll, same yaw) must rebroadcast too, or the audio
    -- cone keeps using the pre-tilt angles.
    local p, a = e:GetPos(), e:GetAngles()
    local last = NTx.LastSentPos[e]
    if not last or last[1]:DistToSqr(p) > 1
      or math.abs(last[2].y - a.y) > 1
      or math.abs(last[2].p - a.p) > 1
      or math.abs(last[2].r - a.r) > 1 then
      NTx.LastSentPos[e] = { p, a }
      moved = true
    end
  end
  for _, e in ipairs(ents.FindByClass("ntx_speaker")) do track(e) end
  for _, e in ipairs(ents.FindByClass("ntx_fallback_bus")) do track(e) end
  for e in pairs(NTx.LastSentPos) do
    if not seen[e] then
      NTx.LastSentPos[e] = nil
      moved = true
    end
  end
  if moved then NTx.BroadcastGraph() end
end)

local function canEdit(ply, ent)
  if not IsValid(ply) or not IsValid(ent) then return false end
  if ply:IsAdmin() then return true end
  local owner = ent.CPPIGetOwner and ent:CPPIGetOwner()
  if owner == ply then return true end
  -- Shared/public rigs (unowned) can optionally be locked to admins so
  -- anyone cannot re-route the whole venue from the mixer panel.
  if not IsValid(owner) then
    local cv = GetConVar("ntx_mixer_admin_only")
    return not (cv and cv:GetBool())
  end
  return false
end

-- Link helper used by the toolgun.
function NTx.LinkToMixer(ply, target, mixer)
  if not IsValid(target) or not IsValid(mixer) or mixer:GetClass() ~= "ntx_mixer" then return false end
  if not canEdit(ply, mixer) then return false end
  target:SetMixer(mixer)
  if target:GetClass() == "ntx_input_url" or target:GetClass() == "ntx_input_mic" then
    mixer:EnsureChannel(target)
  end
  NTx.BroadcastGraph()
  return true
end

net.Receive("NTx.RequestSync", function(_, ply)
  NTx.BroadcastGraph(ply)
end)

-- Client -> server mixer edits. Full validation: entity, ownership, ranges.
net.Receive("NTx.MixerEdit", function(_, ply)
  local mixer = net.ReadEntity()
  if not IsValid(mixer) or mixer:GetClass() ~= "ntx_mixer" then return end
  if not canEdit(ply, mixer) then return end
  local kind = net.ReadString()
  if kind == "bus" then
    local which = net.ReadString()
    local fader = NTx.ClampFader(net.ReadFloat())
    local muted = net.ReadBool()
    if which == "master" then mixer:SetMasterFader(fader) mixer:SetMasterMuted(muted)
    elseif which == "mid" then mixer:SetMidFader(fader) mixer:SetMidMuted(muted)
    elseif which == "sub" then mixer:SetSubFader(fader) mixer:SetSubMuted(muted)
    else return end
  elseif kind == "channel" then
    local input = net.ReadEntity()
    if not IsValid(input) then return end
    local ch = mixer:EnsureChannel(input)
    if not ch then return end
    ch.Fader = NTx.ClampFader(net.ReadFloat())
    ch.Muted = net.ReadBool()
    local label = net.ReadString()
    ch.Label = string.sub(label or "", 1, 24)
  elseif kind == "unlink" then
    local input = net.ReadEntity()
    if IsValid(input) then
      if input.GetMixer and input:GetMixer() == mixer then input:SetMixer(NULL) end
      mixer:RemoveChannel(input)
    end
  else
    return
  end
  NTx.BroadcastGraph()
end)

hook.Add("InitPostEntity", "NTx.InitialSync", function()
  timer.Simple(2, function() NTx.BroadcastGraph() end)
end)

hook.Add("EntityRemoved", "NTx.GraphDirty", function(ent)
  if ent:GetClass() == "ntx_mixer" or ent:GetClass() == "ntx_speaker"
    or ent:GetClass() == "ntx_fallback_bus"
    or ent:GetClass() == "ntx_input_url" or ent:GetClass() == "ntx_input_mic" then
    NTx.BroadcastGraph()
  end
end, -1)
