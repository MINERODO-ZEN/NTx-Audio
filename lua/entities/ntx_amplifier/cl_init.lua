-- Client: the amplifier front panel, drawn on the chassis itself.
--
-- The layout is the virtual 512x112 space that ntx_amp_meters.lua owns, scaled
-- onto the amplifier's leading face, so the in-world panel and the Derma panel
-- are the same drawing code and the same LED semantics.
include("shared.lua")

-- Wire ports exist in both realms; see shared.lua's CreateWirePorts.
function ENT:Initialize()
  self:CreateWirePorts()

  -- Redo the ports once the profile has actually arrived. GMod does not fire
  -- NetworkVarNotify clientside for changes made right after spawn (wiki issue
  -- #324), which is exactly when the server stamps the profile - so at this
  -- instant Channels is still its default and the port list would be wrong.
  timer.Simple(1, function()
    if IsValid(self) then self:CreateWirePorts() end
  end)
end

function ENT:Draw()
  self:DrawModel()
  local cv = GetConVar("ntx_gizmo_amp")
  if not cv or not cv:GetBool() then return end
  if not (NTx.IsMine and NTx.IsMine(self)) then return end
  if not (NTx.DrawAmpPanel and NTx.AMP_PANEL_W) then return end

  -- The panel sits on the rig's leading face (the engine-forward side, which is
  -- where the speaker gizmo's throw arrow points) and is sized to the model's
  -- own bounds so it tracks whatever chassis a profile carries - including the
  -- custom rack models that will replace the stock prop later.
  local mn, mx = self:GetModelBounds()
  if not mn or not mx then return end
  local size = mx - mn
  local wide = math.max(size.y, size.x)
  if wide < 1 then return end
  local scale = (wide * 0.86) / NTx.AMP_PANEL_W

  local pos = self:GetPos() + self:GetAngles():Forward() * (size.z * 0.5 + 0.3)
  cam.Start3D2D(pos, self:GetAngles(), scale)
    NTx.DrawAmpPanel(self, { text = false })
  cam.End3D2D()

  -- Readout under the panel, in plain world text like the speaker labels.
  local rec = NTx.AmpRecord(self)
  local text
  if self:GetBlown() then
    text = "BURNT OUT"
  elseif rec then
    text = string.format("%s  %.0fW  %.1fA  %.0fC", self:GetProfile():upper(),
      rec.mainsA * (rec.mainsV or 0), rec.mainsA, self:GetTempSink())
  else
    text = self:GetProfile():upper()
  end
  local eye = EyeAngles()
  eye:RotateAroundAxis(eye:Forward(), 90)
  eye:RotateAroundAxis(eye:Right(), 90)
  local labelCol = self:GetBlown() and Color(255, 80, 80, 230)
    or Color(200, 220, 240, 210)
  cam.Start3D2D(self:GetPos() + Vector(0, 0, size.z * 0.5 + 6),
    Angle(0, eye.y, 90), 0.18)
    draw.SimpleText(text, "DermaDefault", 0, 0, labelCol, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
  cam.End3D2D()
end

function ENT:DrawTranslucent()
  -- Nothing translucent on an amplifier: the panel rides in Draw so it is
  -- depth tested against the chassis and reads as printed on the front.
end