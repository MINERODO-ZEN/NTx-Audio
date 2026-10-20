include("shared.lua")

function ENT:Draw()
  self:DrawModel()
end

function ENT:DrawTranslucent()
  self:DrawModel()
  local cv = GetConVar("ntx_gizmo_speakers")
  if not cv or not cv:GetBool() then return end
  if not (NTx.IsMine and NTx.IsMine(self)) then return end
  local pos = self:GetPos() + Vector(0, 0, 18)
  local ang = EyeAngles()
  ang:RotateAroundAxis(ang:Forward(), 90)
  ang:RotateAroundAxis(ang:Right(), 90)
  cam.Start3D2D(pos, Angle(0, ang.y, 90), 0.25)
    local label = "FALLBACK " .. (self:GetFlat2D() and "2D" or "3D") .. " x" .. math.Round(self:GetTrim(), 2)
    if self:GetBusLabel() ~= "" then label = label .. " " .. self:GetBusLabel() end
    draw.SimpleText(label, "DermaDefault", 0, 0, Color(255, 200, 100, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
  cam.End3D2D()
end
