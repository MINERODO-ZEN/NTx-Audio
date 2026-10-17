ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "NTx Speaker Node"
ENT.Author = "NTx port"
ENT.Category = "NTx Audio"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.Editable = true

function ENT:SetupDataTables()
  self:NetworkVar("String", 0, "SpeakerType", { KeyName = "stype", Edit = { type = "Combo", values = { MID = "MID", SUB = "SUB" }, order = 1, category = "NTx" } })
  self:NetworkVar("String", 1, "ArrayId", { KeyName = "arrayid", Edit = { type = "Generic", order = 2, category = "NTx" } })
  self:NetworkVar("Bool", 0, "Reversed", { KeyName = "reversed", Edit = { type = "Boolean", order = 3, category = "NTx" } })
  self:NetworkVar("Bool", 1, "SelfCardioid", { KeyName = "selfcard", Edit = { type = "Boolean", order = 4, category = "NTx" } })
  -- MID directivity, independent horizontal / vertical full angles (degrees).
  self:NetworkVar("Float", 0, "MidHFov", { KeyName = "hifov", Edit = { type = "Float", min = 5, max = 360, step = 1, order = 5, category = "NTx" } })
  self:NetworkVar("Float", 1, "MidVFov", { KeyName = "vifov", Edit = { type = "Float", min = 5, max = 360, step = 1, order = 6, category = "NTx" } })
  self:NetworkVar("Entity", 0, "Mixer")
end
