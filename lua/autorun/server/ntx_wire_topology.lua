-- Server: wire topology -> the NetworkVars the audio path already reads.
--
-- Wires are the source of truth. The client audio path (ntx_dsp, ntx_webaudio,
-- ntx_gizmos) asks entities "which amplifier drives you" through the Amp /
-- AmpChannel / Mixer NetworkVars, so instead of rewriting that path we resolve
-- the wire graph here and mirror the answer into those same vars. Clients keep
-- working untouched; only the source of truth moved.
--
-- Walking upstream is Wiremod's own idiom: Inputs[port].Src is a plain field
-- written by Wire_Link (wire/server/wirelib.lua), and Wiremod's extbus, cpu and
-- datasocket all read it the same way. There is no GetLinks helper to call.
AddCSLuaFile()
if not SERVER then return end

NTx = NTx or {}

-- Port name conventions. Signal ports are the only ones the topology walk
-- follows; everything else on these entities is telemetry.
NTx.WIRE_MAX_MIX_CH = 16

local function sigPortIn(ch)
  return "Ch" .. ch .. "In"
end
local function sigPortOut(ch)
  return "Ch" .. ch .. "Out"
end
NTx.WireSigPortIn, NTx.WireSigPortOut = sigPortIn, sigPortOut

-- The entity feeding one of this entity's inputs, or nil.
-- Returns (sourceEntity, sourcePortName).
function NTx.WireUpstream(ent, port)
  if not IsValid(ent) or not ent.Inputs then return nil end
  local inp = ent.Inputs[port]
  if not inp then return nil end
  if not IsValid(inp.Src) then return nil end
  return inp.Src, inp.SrcId
end

-- Everything this entity's named output feeds.
function NTx.WireDownstream(ent, port)
  local out = {}
  if not IsValid(ent) or not ent.Outputs then return out end
  local o = ent.Outputs[port]
  if not o or not o.Connected then return out end
  for _, dst in ipairs(o.Connected) do
    if IsValid(dst.Entity) then out[#out + 1] = { ent = dst.Entity, port = dst.Name } end
  end
  return out
end

-- "Ch3In" or "Ch3Out" -> 3. Returns nil for anything else.
--
-- Both directions matter. The amplifier's own TriggerInput is handed the input
-- port name, but directAmpChannel reads the SOURCE port of whatever is wired to
-- a cabinet, which is an output name. Matching only "In" meant a cabinet wired
-- to Ch2Out resolved to no channel at all and fell through to the first
-- matching bus - which is why everything ended up on channel 1.
function NTx.WireChannelOf(port)
  if type(port) ~= "string" then return nil end
  local n = port:match("^Ch(%d+)In$") or port:match("^Ch(%d+)Out$")
  if not n then return nil end
  return math.Clamp(tonumber(n), 1, 8)
end

-- ------------------------------------------------------------------ resolvers

-- Follow a cabinet's signal chain upstream until something that is not a
-- cabinet. Returns (driver, driverChannel, mixer).
--   driver       amplifier, mixer, input_url or nil
--   driverCh     channel number when driver is an amplifier, else 0
--   mixer        the mixer at the head of the chain, or nil
-- Series cabinets (A -> B -> amp) resolve to the amp behind the last one, which
-- is exactly how the meters charge a stack: one driver, many boxes.
local function resolveChain(ent)
  local seen = {}
  local cur = ent
  while IsValid(cur) and not seen[cur] do
    seen[cur] = true
    local cls = cur:GetClass()
    if cls == "ntx_speaker" then
      local src = NTx.WireUpstream(cur, "In")
      cur = src
    elseif cls == "ntx_amplifier" then
      return cur, 0, nil, true
    else
      -- A mixer, an input, or something else entirely.
      local mixer = (cls == "ntx_mixer") and cur or nil
      if not mixer and cur.GetMixer then mixer = cur:GetMixer() end
      return cur, 0, mixer, false
    end
  end
  return nil, 0, nil, false
end

-- Which amplifier output feeds this cabinet directly (one hop, no series walk).
-- Returns (channel, amplifier), or just nil when this cabinet is not wired
-- straight to an amplifier - the caller then falls through to the chain walk.
--
-- Deliberately NOT `or 0`: zero is truthy in Lua, so returning it made every
-- caller treat "channel unknown" as "channel 0 is a valid answer".
local function directAmpChannel(spk)
  local src, sport = NTx.WireUpstream(spk, "In")
  if not IsValid(src) then return nil end
  if src:GetClass() ~= "ntx_amplifier" then return nil end
  local ch = NTx.WireChannelOf(sport)
  if not ch then return nil end
  return ch, src
end

-- --------------------------------------------------------- legacy migration
--
-- Rebuilding must not silently unpatch rigs that have not been wired yet: the
-- tool gesture still works, and a server full of half-migrated PA would go
-- quiet if every tick cleared the old links. So a rebuild only ever OVERRIDES
-- an entity that is actually part of the wire graph. Anything unwired keeps
-- whatever the legacy link path last set, which also means an existing rig
-- keeps working untouched until somebody rewires it.

-- Does this entity have anything wired to its signal ports at all?
local function wiredUp(ent)
  if not IsValid(ent) or not ent.Inputs then return false end
  for name, inp in pairs(ent.Inputs) do
    if inp.Type == NTx.WIRE_SIG_TYPE and IsValid(inp.Src) then return true end
  end
  return false
end

-- Does anything feed this entity's signal output?
local function wiredDown(ent)
  if not IsValid(ent) or not ent.Outputs then return false end
  for _, o in pairs(ent.Outputs) do
    if o.Type == NTx.WIRE_SIG_TYPE then
      for _, dst in ipairs(o.Connected or {}) do
        if IsValid(dst.Entity) then return true end
      end
    end
  end
  return false
end

-- ------------------------------------------------------------------ rebuild

-- Re-derive every link from the wire graph. Cheap enough to run on demand, and
-- only called when a wire actually changes or an entity moves in/out.
local function rebuild()
  local amps = ents.FindByClass("ntx_amplifier")
  local speakers = ents.FindByClass("ntx_speaker")
  local inputs = ents.FindByClass("ntx_input_url")
  local buses = ents.FindByClass("ntx_fallback_bus")
  local mixers = NTx.Mixers or {}

  -- Amplifiers: which mixer feeds this box, if any. Only touched once the amp
  -- actually has a signal input wired.
  for _, amp in ipairs(amps) do
    if IsValid(amp) and wiredUp(amp) then
      local mixer
      for ch = 1, math.Clamp(math.floor(amp:GetChannels() or 2), 1, 8) do
        local src = NTx.WireUpstream(amp, sigPortIn(ch))
        if IsValid(src) and src:GetClass() == "ntx_mixer" then mixer = src break end
      end
      if amp:GetMixer() ~= mixer then amp:SetMixer(mixer) end
    end
  end

  -- Mixers: a channel exists for every input wired into In1..In16. This is what
  -- gives a fader its label and its value, so it is rebuilt rather than stored.
  for mixer in pairs(mixers) do
    -- An unwired mixer keeps its legacy channel list entirely; overwriting it
    -- with an empty table would erase every fader on a pre-wire rig.
    if IsValid(mixer) and (wiredUp(mixer) or wiredDown(mixer)) then
      local want = {}
      for i = 1, NTx.WIRE_MAX_MIX_CH do
        local src = NTx.WireUpstream(mixer, "In" .. i)
        if IsValid(src) then want[#want + 1] = { Input = src, Fader = 1, Muted = false, Label = "" } end
      end
      local prev = mixer.Channels or {}
      -- Carry fader/mute/label across by input entity so re-patching a rig does
      -- not throw away the mix the user already dialled in.
      local byInput = {}
      for _, ch in ipairs(prev) do
        if IsValid(ch.Input) then byInput[ch.Input] = ch end
      end
      for _, ch in ipairs(want) do
        local old = byInput[ch.Input]
        if old then
          ch.Fader, ch.Muted, ch.Label = old.Fader, old.Muted, old.Label
        end
      end
      mixer.Channels = want
    end
  end

  -- Inputs and fallback buses: the mixer they are patched into. The signal
  -- leaves on "Out" and lands on a mixer input, so the mixer is DOWNSTREAM here.
  local function patchInto(ent)
    local mixer
    for _, dst in ipairs(NTx.WireDownstream(ent, "Out")) do
      if dst.ent:GetClass() == "ntx_mixer" then mixer = dst.ent break end
    end
    -- Unwired inputs keep the legacy mixer link.
    if not mixer and not wiredDown(ent) then return end
    if ent:GetMixer() ~= mixer then ent:SetMixer(mixer) end
  end
  for _, e in ipairs(inputs) do if IsValid(e) then patchInto(e) end end
  for _, e in ipairs(buses) do if IsValid(e) then patchInto(e) end end

  -- Cabinets. Direct-to-amp keeps its channel; a series cabinet inherits the
  -- driver behind it; anything else resolves to the mixer at the head.
  --
  -- A cabinet with nothing wired into its "In" is left alone: the legacy link
  -- path owns it until somebody rewires the rig.
  for _, spk in ipairs(speakers) do
    if IsValid(spk) and wiredUp(spk) then
      local ch, amp = directAmpChannel(spk)
      if ch then
        if spk:GetAmp() ~= amp then spk:SetAmp(amp) end
        if spk:GetAmpChannel() ~= ch then spk:SetAmpChannel(ch) end
        local _, _, mixer = resolveChain(spk)
        spk:SetMixer(amp:GetMixer() or mixer)
      else
        local driver, _, mixer, isAmp = resolveChain(spk)
        if isAmp then
          -- Reached an amplifier through a series cabinet but with no direct
          -- channel: attribute to channel 1 so the load still registers.
          if spk:GetAmp() ~= driver then spk:SetAmp(driver) end
          if spk:GetAmpChannel() ~= 1 then spk:SetAmpChannel(1) end
          spk:SetMixer(driver:GetMixer())
        else
          if spk:GetAmp() ~= NULL then spk:SetAmp(NULL) end
          if spk:GetAmpChannel() ~= 0 then spk:SetAmpChannel(0) end
          spk:SetMixer(IsValid(driver) and driver.GetMixer and driver:GetMixer() or mixer)
        end
      end
    end
  end
end

NTx.RebuildWireTopology = rebuild

-- Any change to the wire graph invalidates the mirror.
local function touch()
  rebuild()
  if NTx.BroadcastGraph then NTx.BroadcastGraph() end
end
NTx.WireTopologyTouch = touch

-- Every cabinet in this speaker's chain, INCLUDING itself, walked both ways.
--
-- "Chain" means the run of cabinets joined by the In/Out signal ports. Walking
-- stops at anything that is not a cabinet (an amplifier, a mixer), which keeps
-- two separate stacks from being merged. The seen set guards against a loop
-- someone wires by accident.
function NTx.WireChain(spk)
  local out, seen = {}, {}
  local function step(ent)
    while IsValid(ent) and ent:GetClass() == "ntx_speaker" and not seen[ent] do
      seen[ent] = true
      out[#out + 1] = ent
      ent = NTx.WireUpstream(ent, "In")
    end
  end
  step(spk)
  for _, d in ipairs(NTx.WireDownstream(spk, "Out")) do step(d.ent) end
  return out
end

-- Stable identity for the electrical series group a cabinet belongs to.
--
-- Series wiring used to be a hand-set "Series group" number on the speaker. Now
-- that In/Out define the chain, the group is derived: every cabinet in one chain
-- gets the same key (the lowest entity index in it), so the simulation adds
-- their impedances together exactly as the old manual setting did, and the
-- number can no longer disagree with the wiring.
function NTx.SpkSeriesKey(spk)
  if not IsValid(spk) then return nil end
  local chain = NTx.WireChain(spk)
  if not chain or #chain < 2 then
    -- A lone cabinet is its own group, which is what the old group 0 meant.
    return "s" .. tostring(spk:EntIndex())
  end
  local min = spk:EntIndex()
  for _, e in ipairs(chain) do
    if e:EntIndex() < min then min = e:EntIndex() end
  end
  return "w" .. tostring(min)
end

-- ------------------------------------------------------------------ events

-- Wiremod fires these as entity methods, not gamemode hooks (wirelib.lua).
-- There is no OnOutputWireUnlink: Wiremod re-fires OnOutputWireLink on unlink,
-- which is an upstream bug, so the destination side is what we listen on.
local function onLink(ent) return function()
  if not IsValid(ent) then return end
  touch()
end end

local function installHooks(ent)
  local cls = ent:GetClass()
  if cls ~= "ntx_input_url" and cls ~= "ntx_mixer" and cls ~= "ntx_fallback_bus"
    and cls ~= "ntx_speaker" and cls ~= "ntx_amplifier" then return end
  if ent.NtxWireHooked then return end
  ent.NtxWireHooked = true
  ent.OnInputWireLink = onLink(ent)
  ent.OnInputWireUnlink = onLink(ent)
  ent.OnOutputWireLink = onLink(ent)
end
NTx.InstallWireHooks = installHooks

hook.Add("OnEntityCreated", "NTx.WireHookWatch", function(ent)
  timer.Simple(0, function() if IsValid(ent) then installHooks(ent) end end)
end)

-- Anything that removes a wire, an entity, or a whole dupe invalidates the
-- mirror; one debounced rebuild covers all of it.
timer.Create("NTx.WireTopoSweep", 1, 0, function()
  local live = 0
  for _, cls in ipairs({ "ntx_input_url", "ntx_mixer", "ntx_fallback_bus", "ntx_speaker", "ntx_amplifier" }) do
    for _, e in ipairs(ents.FindByClass(cls)) do
      if IsValid(e) then installHooks(e) live = live + 1 end
    end
  end
  if live == 0 then return end
  -- Cheap invariant check: if a WIRED cabinet's mirror disagrees with the wire
  -- graph, rebuild. Unwired cabinets are skipped - their Amp link belongs to
  -- the legacy path and flagging it every second would spin forever.
  for _, spk in ipairs(ents.FindByClass("ntx_speaker")) do
    if IsValid(spk) and wiredUp(spk) then
      local ch, amp = directAmpChannel(spk)
      local cur = spk:GetAmp()
      if ch and cur ~= amp then return touch() end
    end
  end
end)