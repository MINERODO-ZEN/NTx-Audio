-- Server: authoritative routing graph + validation.
AddCSLuaFile()
if not SERVER then return end

NTx = NTx or {}

-- Wire format of NTx.GraphSync. Bumped whenever the record changes shape; a
-- client that does not recognise it keeps its last good graph instead of
-- decoding a stream it has lost track of.
NTx.GRAPH_PROTO = 3
NTx.Mixers = NTx.Mixers or {}

util.AddNetworkString("NTx.GraphSync")
util.AddNetworkString("NTx.MixerSync")
util.AddNetworkString("NTx.MixerEdit")
util.AddNetworkString("NTx.RequestSync")
util.AddNetworkString("NTx.AmpSync")
util.AddNetworkString("NTx.AmpEdit")
util.AddNetworkString("NTx.AmpLink")
util.AddNetworkString("NTx.AmpUnlink")
util.AddNetworkString("NTx.SpkProfile")
util.AddNetworkString("NTx.CvarSet")
util.AddNetworkString("NTx.AmplifierEditAll")

CreateConVar("ntx_max_channels", "16", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Max audible NTx live sources per client")
CreateConVar("ntx_update_hz", "67", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Graph rebroadcast rate cap (Hz)")
-- The amplifier state sync carries everything that moves slowly: mains, rail,
-- temperatures, damage, every speaker's state. The level comes on the fast
-- meter path and the signal chain carries the input, so this stays slow.
CreateConVar("ntx_amp_sync_hz", "10", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Amplifier state broadcast rate cap (Hz)")
CreateConVar("ntx_meter_hz", "67", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Meter/level broadcast rate cap (Hz); separate from the slow state sync")
CreateConVar("ntx_signal_hz", "67", FCVAR_ARCHIVE + FCVAR_REPLICATED,
  "Rate the signal chain runs at (Hz): a source publishes its measured level, the mixer republishes it, a cabinet passes it on")
CreateConVar("ntx_amp_sync_dist", "6000", FCVAR_ARCHIVE + FCVAR_REPLICATED,
  "Radius in units around which amplifier state is still broadcast to a client (0 = everywhere)")

-- Page host is server-owned: it decides where every client's WebAudio page
-- is loaded from, so clients must not be able to point it somewhere else
-- (a malicious value would fetch remote script into a privileged page).
-- FCVAR_REPLICATED syncs it to clients; only the server/console can set it:
--   ntx_page_base "https://host/path/"
-- The host must serve ntx_audio/webaudio.html and probe.html.
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
  for _, e in ipairs(ents.FindByClass("ntx_speaker")) do
    if IsValid(e) then
      -- Which amplifier channel drives this cabinet, and which bus that
      -- channel is fed from.
      --
      -- The client cannot read the wire graph, and it used to learn the bus
      -- from a NetworkVar on the amplifier - which could lag behind the
      -- wiring. A cabinet whose channel looked unfed played the whole stereo
      -- programme instead of its bus, and a cabinet on channel 1 did it
      -- whatever bus that channel was carrying. The wiring answers both
      -- questions, and it is the same wiring the simulation uses.
      -- The method's existence is checked, not the method: IsValid wants an
      -- entity, and handing it a function throws inside CollectGraph - which
      -- empties the whole graph, and with it every level in the rig.
      local amp = e.GetAmp and e:GetAmp() or nil
      local ch, bus = 0, nil
      if IsValid(amp) and amp:GetClass() == "ntx_amplifier" then
        ch = NTx.AmpSpeakerChannel(amp, e)
        if ch > 0 then
          local src, srcPort = NTx.WireUpstream(amp, "Ch" .. ch .. "In")
          -- The mixer's output ports are named after the buses, so the port a
          -- channel is fed from says which bus it is.
          if IsValid(src) and src:GetClass() == "ntx_mixer" then
            bus = NTx.BusFromPort(srcPort)
          end
          -- The amplifier's own vars are refreshed here as well, from the same
          -- wiring. The topology walk only runs when a wire changes, so a rig
          -- that was built before a change to it kept the vars it had - and a
          -- channel whose fed flag was missing left the client with no bus at
          -- all, which plays the whole stereo programme.
          if amp.SetChannelFed then amp:SetChannelFed(ch, IsValid(src)) end
          if bus ~= nil and amp.SetChannelBus then amp:SetChannelBus(ch, bus) end
        end
      end
      g.speakers[#g.speakers + 1] = {
        ent = e, stype = e:GetSpeakerType() ~= "" and e:GetSpeakerType() or "MID",
        array = e:GetArrayId() ~= "" and e:GetArrayId() or "A",
        reversed = e:GetReversed() == true, selfcard = e:GetSelfCardioid() == true,
        hFov = e:GetMidHFov(), vFov = e:GetMidVFov(),
        pos = e:GetPos(), ang = e:GetAngles(),
        mixer = IsValid(e:GetMixer()) and e:GetMixer() or nil,
        ch = ch, bus = bus,
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
  -- Format marker. The channel record changed shape twice in a row, and a
  -- stale client reading a field that is no longer sent desynchronises the
  -- whole message: every mixer after the first channel decodes as garbage.
  -- Each net message is self-contained, so refusing an unknown format leaves
  -- the client on its last good graph instead of a corrupted one.
  net.Start("NTx.GraphSync")
  net.WriteUInt(NTx.GRAPH_PROTO, 8)
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
    -- The amplifier channel and the bus it is fed from. 0 means "no bus";
    -- the bus id is stored one higher so the difference is visible.
    net.WriteUInt(math.Clamp(s.ch or 0, 0, 8), 4)
    net.WriteUInt(s.bus and (math.Clamp(s.bus, 0, 4) + 1) or 0, 4)
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
  -- FPP: a buddy can touch the owner's props. FPP's API varies by version,
  -- so every call is guarded; a mod that is not installed leaves these
  -- nil and the check falls through to ownership.
  if FPP then
    if FPP.canTouch then
      local ok, r = pcall(FPP.canTouch, ply, ent)
      if ok and r then return true end
    end
    if ply.FPPCanTouch then
      local ok, r = pcall(ply.FPPCanTouch, ply, ent)
      if ok and r then return true end
    end
  end
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
NTx.CanEditRig = canEdit

-- The old tool-based link gesture is gone. Wiring is done with the stock wire
-- tool, and the wire topology is the single source of truth for who drives
-- whom. Keeping the gesture around meant a plain tool click still wrote
-- SetMixer / SetAmp / SetAmpChannel, which the rebuild then overwrote - two
-- systems disagreeing about the same rig, with the tool silently winning until
-- the next rebuild.
--
-- The link helpers below remain reachable only from the net receivers, which
-- still validate ownership.
-- Link helper used by the toolgun.
function NTx.LinkToMixer(ply, target, mixer)
  if not IsValid(target) or not IsValid(mixer) or mixer:GetClass() ~= "ntx_mixer" then return false end
  if not canEdit(ply, mixer) then return false end
  target:SetMixer(mixer)
  if target:GetClass() == "ntx_input_url" then
    mixer:EnsureChannel(target)
  end
  NTx.BroadcastGraph()
  return true
end

-- Cabinet -> amplifier channel. The bus check is the whole point: a SUB channel
-- feeding a full-range box (or the other way round) would make the meters lie
-- about what the amplifier is actually driving, so it is refused outright
-- rather than quietly corrected.
function NTx.LinkSpeakerToAmp(ply, spk, amp, ch)
  if not IsValid(spk) or not IsValid(amp) or amp:GetClass() ~= "ntx_amplifier" then return false end
  -- An active (self-powered) cabinet still takes its bus from an amplifier
  -- channel: the amplifier processes the signal even though it does not power
  -- the cabinet. Only the load calculation skips it, and that is done in the
  -- simulation, not here.
  if not canEdit(ply, amp) then return false end
  local usable = amp:UsableChannels()
  ch = math.floor(tonumber(ch) or 0)
  if ch < 1 or ch > usable then
    local want = spk:BusType()
    ch = 1
    for i = 1, usable do
      local isSub = amp:ChannelIsSub(i)
      if (want == "sub") == isSub then ch = i break end
    end
  end
  local pair = amp:ChannelPair(ch)
  local wantSub = spk:BusType() == "sub"
  local chanSub = amp:ChannelIsSub(pair[1])
  if wantSub ~= chanSub then return false, "bus" end
  spk:SetAmp(amp)
  spk:SetAmpChannel(ch)
  -- Drop the cached state so the next tick re-derives the load from scratch.
  if NTx.AmpSimDrop then NTx.AmpSimDrop(amp) end
  NTx.BroadcastGraph()
  return true
end

-- ------------------------------------------------------------ amplifier sync

local ampLastSync = 0

-- The amplifier payload is a dozen values per output, so everything is packed
-- into 16-bit quantised integers: a 4-channel amplifier with four cabinets on
-- it costs about 140 bytes, which is what makes a 10 Hz sync affordable.
local function wu(v, scale)
  net.WriteUInt(math.Clamp(math.floor((tonumber(v) or 0) * (scale or 1) + 0.5), 0, 65535), 16)
end
-- Decibels and negative levels: offset 130 dB then scale.
local function wd(v, scale)
  net.WriteUInt(math.Clamp(math.floor(((tonumber(v) or 0) + 130) * (scale or 1) + 0.5), 0, 65535), 16)
end
-- Temperatures: offset 40 C then scale.
local function wt(v)
  net.WriteUInt(math.Clamp(math.floor(((tonumber(v) or 0) + 40) * 10 + 0.5), 0, 65535), 16)
end

function NTx.SendToAmpRange(list, dist)
  if #list == 0 or dist <= 0 then
    net.Broadcast()
    return
  end
  local distSqr = dist * dist
  local recipients = {}
  for _, ply in ipairs(player.GetAll()) do
    if IsValid(ply) then
      local ppos = ply:GetPos()
      for _, e in ipairs(list) do
        if ppos:DistToSqr(e.pos) <= distSqr then
          recipients[#recipients + 1] = ply
          break
        end
      end
    end
  end
  net.Send(recipients)
end

function NTx.BroadcastAmpSync()
  if not NTx.AmpState then return end
  local now = CurTime()
  local cv = GetConVar("ntx_amp_sync_hz")
  if now - ampLastSync < 1 / math.Clamp(cv and cv:GetFloat() or 10, 1, 30) then return end
  ampLastSync = now

  local list = {}
  for amp, st in pairs(NTx.AmpState) do
    if IsValid(amp) then
      list[#list + 1] = { amp = amp, st = st, pos = amp:GetPos() }
    end
  end

  local speakersByAmp = {}
  if #list > 0 then
    for _, spk in ipairs(ents.FindByClass("ntx_speaker")) do
      if IsValid(spk) then
        local a = spk:GetAmp()
        if IsValid(a) then
          local t = speakersByAmp[a]
          if not t then t = {} speakersByAmp[a] = t end
          t[#t + 1] = spk
        end
      end
    end
  end

  net.Start("NTx.AmpSync")
  net.WriteUInt(#list, 8)
  for _, e in ipairs(list) do
    local amp, st = e.amp, e.st
    local red = 0
    local chans = amp:ActiveChannels()
    for _, ci in ipairs(chans) do
      red = math.min(red, (st[ci] and st[ci].gainred) or 0)
    end
    net.WriteEntity(amp)
    net.WriteFloat(math.Round(st.tsink or 22, 1))
    net.WriteFloat(math.Round(st.tdevMax or 22, 1))
    wu(st.fanRpm or 0, 1)
    net.WriteFloat(math.Round(st.mainsV or 0, 1))
    wu(st.mainsA or 0, 100)
    net.WriteFloat(math.Round(st.rail or 0, 1))
    net.WriteFloat(math.Round(st.totalW or 0, 1))
    wu(st.pf or 0, 1000)
    wd(st.fanDb or -120, 10)
    wd(red, 20)
    wu(amp:GetDamage() or 0, 1000)
    net.WriteUInt(math.Clamp(math.floor(amp:GetFaultCode() or 0), 0, 255), 8)
    net.WriteBool(amp:GetStandby() == true)
    net.WriteBool(amp:GetBlown() == true)
    net.WriteBool(amp:GetClipLatch() == true)

    net.WriteUInt(#chans, 4)
    for _, ci in ipairs(chans) do
      local c = st[ci]
      local flags = (c and c.sub and 1 or 0) + (c and c.protect and 2 or 0)
        + (c and c.muted and 4 or 0) + ((c and (c.clip or 1) > 1) and 8 or 0)
        + (c and c.overload and 16 or 0) + (c and c.dc and 32 or 0)
        + (c and c.shorted and 64 or 0)
      net.WriteUInt(flags, 8)
      wd(c and c.linDb or -120, 20)
      wd(c and (NTx.AmpDb(c.vout or 0) - NTx.AmpDb(c.vmax or 1)) or -120, 20)
      wu(c and c.i or 0, 100)
      wu(c and c.w or 0, 2)
      wu(math.min(c and c.z or 16000, 16000), 4)
      wd(c and c.gainred or 0, 20)
    end

    local spks = speakersByAmp[amp] or {}
    net.WriteUInt(#spks, 6)
    for _, spk in ipairs(spks) do
      local ss = NTx.SpkState[spk] or {}
      net.WriteEntity(spk)
      wu(ss.rms or 0, 2)
      wu(ss.peak or 0, 2)
      wt(ss.temp or 22)
      wu(spk:GetDamage() or 0, 1000)
      wu(math.min(ss.group or spk:GetImpedance() or 8, 16000), 4)
      net.WriteUInt((spk:GetBlown() and 1 or 0) + (spk:GetActive() and 2 or 0), 8)
    end
  end

  local dist = GetConVar("ntx_amp_sync_dist")
  dist = math.Clamp(dist and dist:GetFloat() or 0, 0, 20000)
  NTx.SendToAmpRange(list, dist)
end

-- ------------------------------------------------------------ amplifier edits

-- Editing an entity is refused for three different reasons and all of them used
-- to be silent, so "the dropdown did nothing" had no explanation. The reason is
-- reported so the refusal can be told apart from a message that never arrived.
local function editRefusal(ply, ent)
  if not IsValid(ent) then return "it no longer exists" end
  if not IsValid(ply) then return "invalid player" end
  if ply:IsAdmin() then return nil end
  local owner = ent.CPPIGetOwner and ent:CPPIGetOwner() or NULL
  if owner == ply then return nil end
  if not IsValid(owner) then
    local cv = GetConVar("ntx_mixer_admin_only")
    if cv and cv:GetBool() then
      return "it is a shared rig and ntx_mixer_admin_only is on"
    end
    return nil
  end
  return "you do not own it (owner is " .. tostring(owner:Nick()) .. ")"
end

local function applyFields(ply, kind, ent, pairsCount)
  for _ = 1, pairsCount do
    local name = net.ReadString()
    -- The field says what its value IS, and both realms read this same table,
    -- so the encoding is never guessed: a string field is read as a string and
    -- everything else as a float. Before this, a string field rode a float
    -- path and came out as a number.
    local entry = (kind == "amp") and NTx.AmpField(name) or NTx.SpkField(name)
    local value
    if entry and entry.isString then
      value = net.ReadString()
    else
      value = net.ReadFloat()
    end
    -- A profile that owns a spec owns it server-side too. Hiding the row in the
    -- panel is cosmetic; without this a crafted message still sets it, and the
    -- whole point is that the datasheet figure is the one that runs.
    local locked = kind == "amp" and ent.Prof and ent:Prof() and ent:Prof().locked
    local isLocked = false
    if locked then
      for _, n in ipairs(locked) do
        if n == name then isLocked = true break end
      end
    end
    if not entry then
      ply:ChatPrint("[NTx] Rejected: unknown field '" .. tostring(name) .. "'.")
    elseif isLocked then
      ply:ChatPrint("[NTx] Rejected: '" .. tostring(name)
        .. "' is fixed by this amplifier's model.")
    elseif not entry.set then
      ply:ChatPrint("[NTx] Rejected: field '" .. tostring(name) .. "' is read-only.")
    else
      local ok, err = pcall(entry.set, ent, value)
      if not ok then
        -- Previously swallowed: a setter that threw left the value unchanged and
        -- said nothing, which looked exactly like the click never registering.
        ply:ChatPrint("[NTx] Rejected: setting '" .. tostring(name)
          .. "' failed: " .. tostring(err))
      end
    end
  end
end

net.Receive("NTx.AmpEdit", function(_, ply)
  local ent = net.ReadEntity()
  -- The kind is read before the entity is judged. A cabinet edit carries the
  -- CABINET as the first entity, and asking for an amplifier first rejected
  -- every one of them - and returned before reading the rest of the message,
  -- which left the net stream out of step and made the NEXT message read
  -- garbage.
  local kind = net.ReadString()

  if kind == "spkset" then
    if not IsValid(ent) or ent:GetClass() ~= "ntx_speaker" then return end
    if not canEdit(ply, ent) then
      ply:ChatPrint("[NTx] Cannot edit cabinet [" .. ent:EntIndex() .. "]: "
        .. (editRefusal(ply, ent) or "not permitted"))
      return
    end
    applyFields(ply, "spk", ent, net.ReadUInt(5))
    return
  end

  local amp = ent
  if not IsValid(amp) or amp:GetClass() ~= "ntx_amplifier" then
    if IsValid(ply) then ply:ChatPrint("[NTx] Rejected: not an amplifier.") end
    return
  end
  if not canEdit(ply, amp) then
    ply:ChatPrint("[NTx] Cannot edit amplifier [" .. amp:EntIndex() .. "]: "
      .. (editRefusal(ply, amp) or "not permitted"))
    return
  end

  if kind == "set" then
    applyFields(ply, "amp", amp, net.ReadUInt(5))
  elseif kind == "cliplatch" then
    amp:SetClipLatch(false)
  elseif kind == "profile" then
    local id = tostring(net.ReadString() or "")
    if NTx.AmpProfile(id) then
      amp:ApplyAmpProfile(id)
      NTx.AmpSimDrop(amp)
      ply:ChatPrint("[NTx] Model loaded on amplifier [" .. amp:EntIndex() .. "]: "
        .. tostring(NTx.AmpProfile(id).name or id))
    end
  elseif kind == "reset" then
    amp:SetClipLatch(false)
    NTx.AmpInjectFault(amp, "none")
    amp:SetPower(true)
    amp:SetFanOn(true)
    amp:SetStandby(false)
  elseif kind == "fault" then
    NTx.AmpInjectFault(amp, tostring(net.ReadString() or "none"))
  elseif kind == "link" then
    -- Cabinet bus assignment plus the amplifier's mode and tap, sent together
    -- so one undo step covers the whole patch.
    --
    -- A NULL mixer is allowed: it means "not patched yet", and mode and tap
    -- still apply.
    --
    -- The bus mask is read and discarded. What bus a channel carries now comes
    -- from the mixer's identifier arriving on Ch<N>Bus, so honouring a mask from
    -- a panel would let the UI and the wiring disagree again.
    local mixer = net.ReadEntity()
    mixer = (mixer:GetClass() == "ntx_mixer") and mixer or NULL
    net.ReadUInt(8) -- bus mask: obsolete, kept for the wire format
    local mode = net.ReadUInt(2)
    local hiz = net.ReadUInt(8)
    amp:SetMode(mode)
    amp:SetHizVolt(hiz)
    amp:SetMixer(mixer)
    NTx.AmpSimDrop(amp)
    -- A channel that was MID and is now SUB cannot keep its full-range boxes.
    local keep = 0
    for _, spk in ipairs(ents.FindByClass("ntx_speaker")) do
      if IsValid(spk) and spk:GetAmp() == amp then
        local ch = math.Clamp(math.floor(tonumber(spk:GetAmpChannel()) or 0), 1, 8)
        local wantSub = spk:BusType() == "sub"
        local pair = amp:ChannelPair(ch)
        if wantSub ~= amp:ChannelIsSub(pair[1]) then
          spk:SetAmp(NULL)
          spk:SetAmpChannel(0)
        else
          keep = keep + 1
        end
      end
    end
    if IsValid(mixer) then
      ply:ChatPrint("[NTx] Amplifier linked to mixer " .. mixer:EntIndex()
        .. " (" .. keep .. " cabinet(s) still on a matching channel).")
    else
      local subs = 0
      for _, ch in ipairs(amp:ActiveChannels()) do
        if amp:ChannelIsSub(ch) then subs = subs + 1 end
      end
      ply:ChatPrint("[NTx] Amplifier bus set (" .. subs .. " SUB channel(s)); no mixer patched.")
    end
  end

  NTx.BroadcastGraph()
  NTx.AmpSimDrop(amp)
end)

-- Speaker links arrive separately because they are a one-verb tool action.
net.Receive("NTx.AmpLink", function(_, ply)
  local spk = net.ReadEntity()
  local amp = net.ReadEntity()
  local ch = net.ReadUInt(4)
  if not IsValid(spk) or not IsValid(amp) then return end
  if not canEdit(ply, spk) then
    ply:ChatPrint("[NTx] Cannot link cabinet [" .. spk:EntIndex() .. "]: "
      .. (editRefusal(ply, spk) or "not permitted"))
    return
  end
  local ok, why = NTx.LinkSpeakerToAmp(ply, spk, amp, ch)
  if ok then
    ply:ChatPrint("[NTx] Cabinet " .. spk:EntIndex() .. " -> amplifier "
      .. amp:EntIndex() .. " ch" .. ch .. " (" .. NTx.SpkOhmText(spk) .. ").")
  elseif why == "bus" then
    ply:ChatPrint("[NTx] That amplifier channel is set to "
      .. (amp:ChannelIsSub(ch) and "SUB" or "MID") .. " and the cabinet is "
      .. spk:GetSpeakerType() .. ". Change the channel bus first.")
  end
end)

net.Receive("NTx.AmpUnlink", function(_, ply)
  local spk = net.ReadEntity()
  if not IsValid(spk) or spk:GetClass() ~= "ntx_speaker" then return end
  if not IsValid(ply) then return end
  if not canEdit(ply, spk) then
    ply:ChatPrint("[NTx] Cannot unlink cabinet [" .. spk:EntIndex() .. "]: "
      .. (editRefusal(ply, spk) or "not permitted"))
    return
  end
  spk:SetAmp(NULL)
  spk:SetAmpChannel(0)
end)

-- Server-owned simulation ConVars, changeable from the Utilities page. Only the
-- names listed here can be written, and the server rejects anything else, so a
-- client cannot use this as a generic "set any convar" channel.
local SIM_CVARS = {
  ntx_amp_sim = "bool",
  ntx_amp_damage = "bool",
  ntx_spk_damage = "bool",
  ntx_crest_db = { 0, 30 },
  ntx_mains_nominal = { 90, 260 },
  ntx_ambient_c = { -20, 60 },
  ntx_amp_sync_hz = { 1, 30 },
  ntx_amp_sync_dist = { 0, 20000 },
}

net.Receive("NTx.CvarSet", function(_, ply)
  if not IsValid(ply) then return end
  -- Server settings affect everyone on the server, so only admins may
  -- change them. The panel already reports them as server-owned, but the
  -- network message had no permission check at all.
  if not ply:IsAdmin() then
    ply:ChatPrint("[NTx] Server settings require admin.")
    return
  end
  local name = net.ReadString()
  local spec = SIM_CVARS[name]
  local cv = GetConVar(name)
  if not spec or not cv then return end
  if spec == "bool" then
    cv:SetBool(net.ReadBool())
  else
    RunConsoleCommand(name, tostring(math.Clamp(net.ReadFloat(), spec[1], spec[2])))
  end
  -- Push the new value straight out so every open Utilities page agrees.
  cv:Replicate()
  print("[NTx] " .. ply:Nick() .. " set " .. name .. " = " .. cv:GetString())
end)

net.Receive("NTx.AmplifierEditAll", function(_, ply)
  if not IsValid(ply) then return end
  -- Reset/cool applies to every amplifier on the map, so only admins.
  if not ply:IsAdmin() then
    ply:ChatPrint("[NTx] Amplifier-wide actions require admin.")
    return
  end
  local what = net.ReadString()
  local count = 0
  for _, amp in ipairs(ents.FindByClass("ntx_amplifier")) do
    if IsValid(amp) then
      if what == "reset" then
        amp:SetClipLatch(false)
        NTx.AmpInjectFault(amp, "none")
        amp:SetPower(true)
        amp:SetFanOn(true)
      elseif what == "cool" then
        amp:SetFanOn(true)
        amp:SetMainsOverride(0)
        amp:SetAmbient(0)
      end
      count = count + 1
    end
  end
  ply:ChatPrint("[NTx] " .. what .. " applied to " .. count .. " amplifier(s).")
end)

-- ------------------------------------------------- speaker profile storage

-- The saved speaker profiles live in the CLIENT's own data folder: a profile
-- is a cabinet the player built, and it belongs to the player who built it.
-- The server never stores them and never writes a file for them - it is told
-- the values when one is applied to a cabinet.
net.Receive("NTx.SpkProfile", function(_, ply)
  local kind = net.ReadString()
  if kind ~= "apply" then return end
  local spk = net.ReadEntity()
  if not IsValid(spk) or spk:GetClass() ~= "ntx_speaker" then return end
  if not canEdit(ply, spk) then
    ply:ChatPrint("[NTx] You cannot edit that cabinet.")
    return
  end
  local id = tostring(net.ReadString() or "")
  local stype = net.ReadString()
  local ohm, rmsW, peakW = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
  local minAmpW, tapV = net.ReadFloat(), net.ReadFloat()
  local hifov, vifov = net.ReadFloat(), net.ReadFloat()
  spk:ApplySpeakerProfileData({
    id = id, stype = stype, ohm = ohm, rmsW = rmsW, peakW = peakW,
    minAmpW = minAmpW, tapVolt = tapV, hifov = hifov, vifov = vifov,
  })
  -- Said out loud. A profile that is applied and not reported looks exactly
  -- like one that is not applied at all.
  ply:ChatPrint("[NTx] Profile applied to cabinet [" .. spk:EntIndex() .. "]: "
    .. string.format("%.0f ohm, %.0f W rms, %s", ohm, rmsW, stype))
  if NTx.BroadcastGraph then NTx.BroadcastGraph() end
end)

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
    -- Which bus/side this channel feeds. Read last so an older client that
    -- stops after the label leaves the existing value alone.
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
  local cls = ent:GetClass()
  if cls == "ntx_mixer" or cls == "ntx_speaker" or cls == "ntx_fallback_bus"
    or cls == "ntx_input_url" or cls == "ntx_amplifier" then
    NTx.BroadcastGraph()
  end
end, -1)
