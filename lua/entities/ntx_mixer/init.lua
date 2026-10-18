AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

NTx = NTx or {}
NTx.Mixers = NTx.Mixers or {}

local MAX_CHANNELS = 16

function ENT:Initialize()
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
  self.WireOut = 0
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

-- ------------------------------------------------------------ wire signal

-- Input levels land here. Wiremod delivers whatever the source entity last
-- output, so this is just a store; the mix itself is computed in Think so the
-- faders still apply after the fact.
function ENT:TriggerInput(name, value)
  local n = tonumber(name:match("^In(%d+)$"))
  if not n then return end
  self.WireLevels = self.WireLevels or {}
  self.WireLevels[n] = math.Clamp(tonumber(value) or 0, 0, 2)
end

-- Mix of every wired input, honouring channel mute/fader plus the bus and
-- master faders. MID and SUB are summed separately because each amplifier
-- channel picks one of them, then the pair is summed in energy.
function ENT:ComputeWireOut()
  local levels = self.WireLevels or {}
  local byInput = {}
  for _, ch in ipairs(self.Channels or {}) do
    if IsValid(ch.Input) then byInput[ch.Input] = ch end
  end
  local mid, sub = 0, 0
  local n = math.min(table.Count(levels), (NTx and NTx.WIRE_MAX_MIX_CH) or 16)
  for i = 1, n do
    local lvl = tonumber(levels[i]) or 0
    if lvl > 0 then
      local src = NTx.WireUpstream(self, "In" .. i)
      local ch = IsValid(src) and byInput[src] or nil
      if ch and ch.Muted then lvl = 0 end
      if ch then lvl = lvl * NTx.FaderToGain(ch.Fader) end
      local bus = "mid"
      if ch and IsValid(ch.Input) and ch.Input.GetSpeakerType then
        bus = ch.Input:GetSpeakerType() == "SUB" and "sub" or "mid"
      end
      if bus == "sub" then sub = sub + lvl * lvl else mid = mid + lvl * lvl end
    end
  end
  if self:GetMasterMuted() then return 0 end
  mid = math.sqrt(mid) * NTx.FaderToGain(self:GetMidFader()) * NTx.FaderToGain(self:GetMasterFader())
  sub = math.sqrt(sub) * NTx.FaderToGain(self:GetSubFader()) * NTx.FaderToGain(self:GetMasterFader())
  if self:GetMidMuted() then mid = 0 end
  if self:GetSubMuted() then sub = 0 end
  return math.Clamp(math.sqrt(mid * mid + sub * sub), 0, 2)
end

function ENT:Think()
  self:NextThink(CurTime() + 0.1)
  local out = self:ComputeWireOut()
  if out ~= self.WireOut then
    self.WireOut = out
    NTx.WireOut(self, "Out", out)
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
