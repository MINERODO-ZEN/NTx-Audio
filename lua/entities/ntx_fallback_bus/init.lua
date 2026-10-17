AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
  self:SetModel("models/hunter/blocks/cube025x025x025.mdl")
  self:SetMaterial("models/debug/debugwhite")
  self:SetColor(Color(200, 120, 20, 140))
  self:SetRenderMode(RENDERMODE_TRANSALPHA)
  self:PhysicsInit(SOLID_VPHYSICS)
  self:SetMoveType(MOVETYPE_VPHYSICS)
  self:SetSolid(SOLID_VPHYSICS)
  local phys = self:GetPhysicsObject()
  if IsValid(phys) then phys:Wake() end
  if self:GetTrim() == 0 then self:SetTrim(1) end
end

function ENT:SpawnFunction(ply, tr)
  if not tr.Hit then return end
  local ent = ents.Create("ntx_fallback_bus")
  ent:SetPos(tr.HitPos + tr.HitNormal * 8)
  ent:Spawn()
  ent:Activate()
  if CPPI then ent:CPPISetOwner(ply) end
  undo.Create("NTx Fallback Bus")
  undo.AddEntity(ent)
  undo.SetPlayer(ply)
  undo.Finish()
  return ent
end

function ENT:PreEntityCopy()
  duplicator.StoreEntityModifier(self, "NtxFallback", {
    trim = self:GetTrim(), label = self:GetBusLabel(), flat = self:GetFlat2D(),
  })
end

function ENT:PostEntityPaste(ply, ent, created)
  local d = ent.EntityMods and ent.EntityMods.NtxFallback
  if d then
    self:SetTrim(NTx.ClampFader(d.trim))
    self:SetBusLabel(string.sub(tostring(d.label or ""), 1, 32))
    self:SetFlat2D(d.flat == true)
  end
end
