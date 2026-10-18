AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
  self:SetModel("models/props_lab/reciever01a.mdl")
  self:PhysicsInit(SOLID_VPHYSICS)
  self:SetMoveType(MOVETYPE_VPHYSICS)
  self:SetSolid(SOLID_VPHYSICS)
  local phys = self:GetPhysicsObject()
  if IsValid(phys) then phys:Wake() end
  if self:GetInputVolume() == 0 then self:SetInputVolume(1) end
  if self:GetMaxDist() == 0 then self:SetMaxDist(1200) end
  self:CreateWirePorts()
end

function ENT:Think()
  self:NextThink(CurTime())
  if WireLib then
    WireLib.TriggerOutput(self, "Out", self:GetInputVolume())
  end
  return true
end

function ENT:SpawnFunction(ply, tr)
  if not tr.Hit then return end
  local ent = ents.Create("ntx_input_url")
  ent:SetPos(tr.HitPos + tr.HitNormal * 8)
  ent:Spawn()
  ent:Activate()
  if CPPI then ent:CPPISetOwner(ply) end
  undo.Create("NTx Input")
  undo.AddEntity(ent)
  undo.SetPlayer(ply)
  undo.Finish()
  return ent
end

function ENT:PreEntityCopy()
  duplicator.StoreEntityModifier(self, "NtxInput", {
    url = self:GetStreamUrl(),
    vol = self:GetInputVolume(), maxd = self:GetMaxDist(),
  })
end

function ENT:PostEntityPaste(ply, ent, created)
  local d = ent.EntityMods and ent.EntityMods.NtxInput
  if d then
    self:SetStreamUrl(tostring(d.url or ""))
    self:SetInputVolume(NTx.ClampFader(d.vol))
    self:SetMaxDist(math.Clamp(tonumber(d.maxd) or 1200, 100, 10000))
  end
end
