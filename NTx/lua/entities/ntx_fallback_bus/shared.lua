ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "NTx Fallback Bus"
ENT.Author = "NTx port"
ENT.Category = "NTx Audio"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.Editable = true

-- Fallback-only anchor: legacy clients (no WebAudio, no DSP module) play
-- ONE unfiltered tap per input at the nearest fallback bus of each mixer.
-- No HP/LP, no cardioid delay, no line-array shading by design.
function ENT:SetupDataTables()
  self:NetworkVar("Float", 0, "Trim", { KeyName = "trim", Edit = { type = "Float", min = 0, max = 2, order = 1, category = "NTx" } })
  self:NetworkVar("String", 0, "BusLabel", { KeyName = "buslabel", Edit = { type = "Generic", order = 2, category = "NTx" } })
  self:NetworkVar("Bool", 0, "Flat2D", { KeyName = "flat2d", Edit = { type = "Boolean", order = 3, category = "NTx" } })
  self:NetworkVar("Entity", 0, "Mixer")
end
