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

function ENT:CreateWirePorts()
  local inNames, inDesc, inTypes = {}, {}, {}
  for i = 1, 16 do
    inNames[#inNames + 1] = "In" .. i
    inDesc[#inDesc + 1] = "Audio input " .. i .. " (0-1)"
    inTypes[#inTypes + 1] = "NORMAL"
  end
  self.Inputs = WireLib.CreateSpecialInputs(self, inNames, inDesc, inTypes)
  self.Outputs = WireLib.CreateSpecialOutputs(self, {"Out"}, {"Mixed audio output (0-1)"}, {"NORMAL"})
end
end
