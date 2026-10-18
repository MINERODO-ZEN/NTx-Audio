ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "NTx Mixer"
ENT.Author = "NTx port"
ENT.Category = "NTx Audio"
ENT.Spawnable = true
ENT.AdminOnly = false

function ENT:SetupDataTables()
  self:NetworkVar("Float", 0, "MasterFader")
  self:NetworkVar("Bool", 0, "MasterMuted")
  self:NetworkVar("Float", 1, "MidFader")
  self:NetworkVar("Bool", 1, "MidMuted")
  self:NetworkVar("Float", 2, "SubFader")
  self:NetworkVar("Bool", 2, "SubMuted")
end
