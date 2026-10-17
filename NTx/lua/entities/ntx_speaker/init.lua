AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
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
  end
  -- Duplication hands the rig to the player doing the work, so gizmos and
  -- link lines stay private to whoever is building.
  if ply and CPPI then self:CPPISetOwner(ply) end
end
