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

-- Emits the input volume scaled by the measured programme level, once for each
-- bus the source could feed. This is not the audio: the client decodes StreamUrl
-- itself. The wire carries the level the source is producing so a mixer wired
-- downstream can route it into the right bus and the amplifier's load, heat and
-- speaker drive follow the music.
--
-- Every slot carries the same level. Which one the mixer consumes is its
-- decision, per channel - that is what the per-channel bus picker is for. With
-- no measurement this stays at the fader value alone.
function ENT:Think()
  self:NextThink(CurTime() + 0.1)
  local lvl = math.Clamp(tonumber(self:GetInputVolume()) or 0, 0, 2)
    * ((NTx.MeasuredRms and NTx.MeasuredRms(self)) or 1)
  local n = (NTx and NTx.BUS_COUNT) or 4
  local changed = false
  if not istable(self.WireBuses) then self.WireBuses = {} end
  for i = 1, n do
    if self.WireBuses[i] ~= lvl then
      self.WireBuses[i] = lvl
      changed = true
    end
  end
  if changed or self.WireOut == nil then
    self.WireOut = lvl
    -- A fresh table each time: Wiremod holds ARRAY values by reference, and
    -- mutating the one it already stores would not re-trigger the fan-out.
    local buses = {}
    for i = 1, n do buses[i] = lvl end
    NTx.WireOut(self, "Buses", buses)
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
