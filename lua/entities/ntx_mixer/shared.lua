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

-- Signal ports. In1..In16 are the patch points the topology walk reads to
-- rebuild the channel list (and therefore the faders); "Out" is the mix that
-- feeds an amplifier's Ch<N>In. Faders stay Derma-only - no wire for those.
function ENT:CreateWirePorts()
  -- Entity files load before lua/autorun, so the shared constant may not exist
  -- yet on a cold start. 16 is the real limit either way.
  local maxCh = (NTx and NTx.WIRE_MAX_MIX_CH) or 16
  local inNames, inDesc = {}, {}
  for i = 1, maxCh do
    inNames[i] = "In" .. i
    inDesc[i] = "Input signal level on channel " .. i .. ", 0 to 1"
  end
  local outNames = { "Out" }
  local outDesc = { "Mixed output level, 0 to 1" }
  NTx.WireSetup(self, inNames, inDesc, outNames, outDesc, #inNames, 1)
end
