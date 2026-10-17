include("shared.lua")

function ENT:Draw()
  self:DrawModel()
end

function ENT:DrawTranslucent()
  self:DrawModel()
  -- Label is part of the gizmo set: owner-only and toggle-gated, so it never
  -- leaks rig state (or the backend hint) to other players.
  local cv = GetConVar("ntx_gizmo_speakers")
  if not cv or not cv:GetBool() then return end
  if not (NTx.IsMine and NTx.IsMine(self)) then return end
  local pos = self:GetPos() + Vector(0, 0, 18)
  local ang = EyeAngles()
  ang:RotateAroundAxis(ang:Forward(), 90)
  ang:RotateAroundAxis(ang:Right(), 90)
  cam.Start3D2D(pos, Angle(0, ang.y, 90), 0.25)
    local label = self:GetSpeakerType() .. (self:GetReversed() and " REV" or "") .. " [" .. self:GetArrayId() .. "]"
    if self:GetSelfCardioid() then label = label .. " SC" end
    -- Speakers only make sound on the WebAudio / module backend; under
    -- BASS fallback they are placement markers, so say so on the box.
    if not (NTx.EffectiveBackend and NTx.EffectiveBackend() == "webaudio") then
      label = label .. " (inactive: needs WebAudio)"
    end
    draw.SimpleText(label, "DermaDefault", 0, 0, Color(255, 255, 255, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
  cam.End3D2D()
end
