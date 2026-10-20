AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

NTx = NTx or {}
NTx.Mixers = NTx.Mixers or {}

local MAX_CHANNELS = 16

function ENT:Initialize()
  -- Never sleep. GMod puts an entity that is out of sight to sleep and stops
  -- calling its Think entirely, so a source that slept stopped publishing its
  -- level - and the mixer, the amplifier's input and the cabinets all
  -- inherited that rate. It looked like a slow measurement; it was a sleeping
  -- prop. These entities are the signal path, so they have to keep running.
  if self.SetNeverSleep then self:SetNeverSleep(true) end
  self:SetModel("models/props_lab/reciever01b.mdl")
  self:PhysicsInit(SOLID_VPHYSICS)
  self:SetMoveType(MOVETYPE_VPHYSICS)
  self:SetSolid(SOLID_VPHYSICS)
  local phys = self:GetPhysicsObject()
  if IsValid(phys) then phys:Wake() end
  if self:GetMasterFader() == 0 then self:SetMasterFader(1) end
  if self:GetMidFader() == 0 then self:SetMidFader(1) end
  if self:GetSubFader() == 0 then self:SetSubFader(1) end
  self.Channels = {}
  self.WireLevels = {}
  -- Per-bus output cache, indexed by bus id, with the published identifiers
  -- alongside under "id<n>". This has to be a table: it used to be a single
  -- number back when the mixer published one summed level.
  self.WireOut = {}
  self:CreateWirePorts()
  if NTx.InstallWireHooks then NTx.InstallWireHooks(self) end
  NTx.Mixers[self] = true
end

function ENT:OnRemove()
  NTx.Mixers[self] = nil
  for _, e in ipairs(ents.FindByClass("ntx_input_url")) do
    if IsValid(e) and e:GetMixer() == self then e:SetMixer(NULL) end
  end
  for _, e in ipairs(ents.FindByClass("ntx_fallback_bus")) do
    if IsValid(e) and e:GetMixer() == self then e:SetMixer(NULL) end
  end
  for _, e in ipairs(ents.FindByClass("ntx_speaker")) do
    if IsValid(e) and e:GetMixer() == self then e:SetMixer(NULL) end
  end
  if NTx.BroadcastGraph then NTx.BroadcastGraph() end
end

function ENT:TriggerInput(name, value)
  local n = tonumber(name:match("^In(%d+)$"))
  if not n then return end
  self.WireLevels = self.WireLevels or {}
  -- The source sends its four bus levels as one ARRAY; keep them per channel
  -- rather than collapsing to a single number, so the per-channel bus picker
  -- decides which slot this source feeds.
  local buses = nil
  if istable(value) then buses = value end
  self.WireLevels[n] = buses
end

-- Level of one bus/side, summed in energy across the channels assigned to it.
-- Master and bus faders and mutes apply here, exactly as the client gain path
-- does, so the level the amplifier sees is the level its cabinets are fed.
function ENT:ComputeBusOut(bus)
  if self:GetMasterMuted() then return 0 end
  local isSub = NTx.BusIsSub(bus)
  if isSub and self:GetSubMuted() then return 0 end
  if not isSub and self:GetMidMuted() then return 0 end
  local busFader = isSub and self:GetSubFader() or self:GetMidFader()
  local base = NTx.FaderToGain(self:GetMasterFader()) * NTx.FaderToGain(busFader)

  -- Every channel feeds every bus: whatever comes out of the player into a
  -- mixer input goes out on all five. What separates them is not the routing
  -- but the slot each one reads - src[bus + 1] - so MidL gets the left side,
  -- MidR the right, and SubMono their band-limited sum.
  local energy = 0
  for _, ch in ipairs(self.Channels or {}) do
    local idx = nil
    -- The channel's own position in the array of inputs, not its list index.
    for i = 1, (NTx.WIRE_MAX_MIX_CH or 16) do
      if NTx.WireUpstream(self, "In" .. i) == ch.Input then idx = i break end
    end
    local src = idx and (self.WireLevels or {})[idx]
    local lvl = istable(src) and (tonumber(src[bus + 1]) or 0) or 0
    local g = ch.Muted and 0 or (base * NTx.FaderToGain(ch.Fader))
    local e = g * lvl
    energy = energy + e * e
  end
  return math.Clamp(math.sqrt(energy), 0, 2)
end

function ENT:Think()
  -- The signal chain's rate, not a tenth of a second: this is one of three
  -- stages the measured level passes through on its way to the amplifier, and
  -- at ten hertz the level arriving there only changed ten times a second.
  self:NextThink(CurTime() + (NTx.SignalInterval and NTx.SignalInterval() or 1 / 60))
  local levels = (NTx and NTx.BUS_PORTS) or { "MidL", "MidR", "SubL", "SubR", "SubMono" }
  local nBus = (NTx and NTx.BUS_COUNT) or 5
  -- istable, not `or {}`: a mixer saved before this change carries a number
  -- here, and indexing that would error on every tick.
  if not istable(self.WireOut) then self.WireOut = {} end
  for b = 0, nBus - 1 do
    local out = self:ComputeBusOut(b)
    -- The level and the bus identifier travel together as a pair, so a signal
    -- and the bus it belongs to can never be wired to the wrong channel. A
    -- fresh table each time: Wiremod holds ARRAY values by reference, and
    -- mutating the one it already stores would not re-trigger the fan-out.
    local pair = { out, b }
    local key = tostring(b)
    if self.WireOut[key] ~= out then
      self.WireOut[key] = out
      NTx.WireOut(self, levels[b + 1], pair)
    end
  end
end

function ENT:SpawnFunction(ply, tr)
  if not tr.Hit then return end
  local ent = ents.Create("ntx_mixer")
  ent:SetPos(tr.HitPos + tr.HitNormal * 8)
  ent:Spawn()
  ent:Activate()
  if CPPI then ent:CPPISetOwner(ply) end
  undo.Create("NTx Mixer")
  undo.AddEntity(ent)
  undo.SetPlayer(ply)
  undo.Finish()
  return ent
end

-- Channel management (port of AudioMixerBE MixerChannel list).
function ENT:EnsureChannel(input)
  for _, ch in ipairs(self.Channels) do
    if ch.Input == input then return ch end
  end
  if #self.Channels >= MAX_CHANNELS then return nil end
  -- Bus this channel feeds, as a bus id (MidL/MidR/SubL/SubR). Defaults to
  -- MID left; set from the mixer panel.

  local ch = { Input = input, Fader = 1, Muted = false, Label = "" }
  self.Channels[#self.Channels + 1] = ch
  return ch
end

function ENT:RemoveChannel(input)
  for i, ch in ipairs(self.Channels) do
    if ch.Input == input then table.remove(self.Channels, i) return end
  end
end

-- Port of getRouteGainForSource: channel * bus * master, per speaker type.
-- Logarithmic faders, mirroring the client gain path exactly.
function ENT:GetRouteGain(input, speakerType)
  if self:GetMasterMuted() then return 0 end
  local bus = NTx.BusForType(speakerType)
  if bus == "mid" and self:GetMidMuted() then return 0 end
  if bus == "sub" and self:GetSubMuted() then return 0 end
  local gain = NTx.FaderToGain(self:GetMasterFader())
  gain = gain * NTx.FaderToGain(bus == "mid" and self:GetMidFader() or self:GetSubFader())
  for _, ch in ipairs(self.Channels) do
    if ch.Input == input then
      if ch.Muted then return 0 end
      return gain * NTx.FaderToGain(ch.Fader)
    end
  end
  return gain
end

function ENT:PreEntityCopy()
  local chd = {}
  for _, ch in ipairs(self.Channels) do
    chd[#chd + 1] = { fader = ch.Fader, muted = ch.Muted, label = ch.Label }
  end
  duplicator.StoreEntityModifier(self, "NtxMixer", {
    master = self:GetMasterFader(), mm = self:GetMasterMuted(),
    mid = self:GetMidFader(), midm = self:GetMidMuted(),
    sub = self:GetSubFader(), subm = self:GetSubMuted(),
    channels = chd,
  })
end

function ENT:PostEntityPaste(ply, ent, created)
  local d = ent.EntityMods and ent.EntityMods.NtxMixer
  if d then
    self:SetMasterFader(NTx.ClampFader(d.master))
    self:SetMasterMuted(d.mm == true)
    self:SetMidFader(NTx.ClampFader(d.mid))
    self:SetMidMuted(d.midm == true)
    self:SetSubFader(NTx.ClampFader(d.sub))
    self:SetSubMuted(d.subm == true)
  end
  if NTx.BroadcastGraph then NTx.BroadcastGraph() end
end
