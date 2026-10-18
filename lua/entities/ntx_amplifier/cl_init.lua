-- Client: the amplifier's world presence.
--
-- The chassis is a plain model; the front-panel LEDs are drawn as
-- models/led.mdl by ntx_amp_meters.lua, from the exact meter state the Derma
-- panel paints in 2D. (The old cam.Start3D2D panel is gone: 3D2D inside
-- ENT:Draw also runs in the halo stencil pass, where a nested camera corrupts
-- the frame's model rendering.)
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
