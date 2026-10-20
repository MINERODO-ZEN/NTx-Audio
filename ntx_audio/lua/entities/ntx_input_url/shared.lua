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

-- Signal port. "Buses" is an ARRAY of four levels, one per bus/side
-- (MidL, MidR, SubL, SubR), because a source can feed any of them and the
-- mixer decides which. Carrying them together keeps the whole routing
-- decision downstream of the source, where the mixer faders live.
--
-- This replaces the single "Out" port. Only the fallback bus keeps a plain
-- In/Out: it is one full-spectrum channel by design and has no bus split.
function ENT:CreateWirePorts()
  NTx.WireSetup(self, {}, {}, { "Buses" }, { "Level per bus [MidL, MidR, SubL, SubR]" },
    0, 1, { [1] = "ARRAY" })
end
