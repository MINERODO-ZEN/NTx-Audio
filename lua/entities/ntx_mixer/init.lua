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
