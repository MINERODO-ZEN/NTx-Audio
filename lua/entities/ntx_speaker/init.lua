AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
  self:CreateWirePorts()
  self:SetModel("models/hunter/blocks/cube025x025x025.mdl")
  self:SetMaterial("models/debug/debugwhite")
  self:SetColor(Color(30, 30, 30, 120))
  self:SetRenderMode(RENDERMODE_TRANSALPHA)
  self:PhysicsInit(SOLID_VPHYSICS)
  self:SetMoveType(MOVETYPE_VPHYSICS)
  self:SetSolid(SOLID_VPHYSICS)
  local phys = self:GetPhysicsObject()
  if IsValid(phys) then phys:Wake() end
  if self:GetSpeakerType() == "" then self:SetSpeakerType("MID") end
  if self:GetArrayId() == "" then self:SetArrayId("A") end
  -- MID coverage defaults: wide/shallow main PA (NTx-derived throw).
  if self:GetMidHFov() <= 0 then self:SetMidHFov(152) end
  if self:GetMidVFov() <= 0 then self:SetMidVFov(57) end
  -- Electrical defaults. An existing rig that predates the amplifier work
  -- still needs a sane impedance and power budget, so an empty profile picks up
  -- the archetype for its type instead of staying at zero (which the sim would
  -- read as a dead short).
  if self:GetProfile() == "" then
    self:ApplySpeakerProfile(self:GetSpeakerType() == "SUB" and "sub18" or "pa15")
  end
  if self:GetImpedance() <= 0 then self:SetImpedance(self:GetTapVolt() > 0 and 100 or 8) end
  if self:GetRmsW() <= 0 then self:SetRmsW(100) end
  if self:GetPeakW() <= 0 then self:SetPeakW(self:GetRmsW() * 2) end
end

function ENT:SpawnFunction(ply, tr)
  if not tr.Hit then return end
  local ent = ents.Create("ntx_speaker")
  ent:SetPos(tr.HitPos + tr.HitNormal * 8)
  ent:Spawn()
  ent:Activate()
  if CPPI then ent:CPPISetOwner(ply) end
  undo.Create("NTx Speaker")
  undo.AddEntity(ent)
  undo.SetPlayer(ply)
  undo.Finish()
  return ent
end

function ENT:PreEntityCopy()
  local d = {}
  d.stype, d.arrayid, d.reversed = self:GetSpeakerType(), self:GetArrayId(), self:GetReversed()
  d.selfcard = self:GetSelfCardioid()
  d.hfov, d.vfov = self:GetMidHFov(), self:GetMidVFov()
  d.profile = self:GetProfile()
  d.imp, d.rmsw, d.peakw, d.minampw = self:GetImpedance(), self:GetRmsW(), self:GetPeakW(), self:GetMinAmpW()
  d.tapv, d.seriesgrp, d.active = self:GetTapVolt(), self:GetSeriesGroup(), self:GetActive()
  d.ampch = self:GetAmpChannel()
  duplicator.StoreEntityModifier(self, "NtxSpeaker", d)
end

function ENT:PostEntityPaste(ply, ent, created)
  local d = ent.EntityMods and ent.EntityMods.NtxSpeaker
  if d then
    self:SetSpeakerType(NTx.IsSpeakerType(d.stype) and d.stype or "MID")
    self:SetArrayId(tostring(d.arrayid or "A"))
    self:SetReversed(d.reversed == true)
    self:SetSelfCardioid(d.selfcard == true)
    self:SetMidHFov(math.Clamp(tonumber(d.hfov) or 152, 5, 360))
    self:SetMidVFov(math.Clamp(tonumber(d.vfov) or 57, 5, 360))
    self:SetProfile(tostring(d.profile or ""))
    self:SetImpedance(math.Clamp(tonumber(d.imp) or 8, 0.1, 100000))
    self:SetRmsW(math.Clamp(tonumber(d.rmsw) or 100, 0, 100000))
    self:SetPeakW(math.Clamp(tonumber(d.peakw) or 200, 0, 200000))
    self:SetMinAmpW(math.Clamp(tonumber(d.minampw) or 50, 0, 100000))
    self:SetTapVolt(math.Clamp(math.floor(tonumber(d.tapv) or 0), 0, 240))
    self:SetSeriesGroup(math.Clamp(math.floor(tonumber(d.seriesgrp) or 0), 0, 8))
    self:SetActive(d.active == true)
    self:SetAmpChannel(math.Clamp(math.floor(tonumber(d.ampch) or 0), 0, 8))
  end
  -- Duplication hands the rig to the player doing the work, so gizmos and
  -- link lines stay private to whoever is building.
  if ply and CPPI then self:CPPISetOwner(ply) end
end