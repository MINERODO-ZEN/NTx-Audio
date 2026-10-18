ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "NTx Live Input (URL)"
ENT.Author = "NTx port"
ENT.Category = "NTx Audio"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.Editable = true

function ENT:SetupDataTables()
  self:NetworkVar("String", 0, "StreamUrl")
  self:NetworkVar("Float", 0, "InputVolume", { KeyName = "vol", Edit = { type = "Float", min = 0, max = 2, order = 1, category = "NTx" } })
  self:NetworkVar("Float", 1, "MaxDist", { KeyName = "maxdist", Edit = { type = "Float", min = 100, max = 10000, order = 2, category = "NTx" } })
  self:NetworkVar("Bool", 0, "Looping")
  self:NetworkVar("Entity", 0, "Mixer")
end

-- Signal port. "Out" is what the topology walk follows to find the mixer this
-- input is patched into. It carries a nominal 0-1 level, not the audio itself:
-- the real stream is decoded client side from StreamUrl.
function ENT:CreateWirePorts()
  NTx.WireSetup(self, {}, {}, { "Out" }, { "Source level out, 0 to 1" }, 0, 1)
end
