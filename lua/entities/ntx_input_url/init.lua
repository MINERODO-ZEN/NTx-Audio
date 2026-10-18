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
  self.WireOut = -1
  self:CreateWirePorts()
  if NTx.InstallWireHooks then NTx.InstallWireHooks(self) end
end

-- Emits the input volume as a nominal level. This is not the audio: the client
-- decodes StreamUrl itself. It exists so a rig wired entirely on signal levels
-- has something to carry, and so an unplugged chain visibly goes to zero.
function ENT:Think()
  self:NextThink(CurTime() + 0.25)
  local out = math.Clamp(tonumber(self:GetInputVolume()) or 0, 0, 2)
  if out ~= self.WireOut then
    self.WireOut = out
    NTx.WireOut(self, "Out", out)
  end
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
