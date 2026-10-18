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

-- Signal ports.
--
-- In1..In16 take the four-value bus array a source carries. The four outputs
-- are one pair per bus/side: the level, and the identifier saying which bus that
-- is. An amplifier wired to "SubR" reads its type off the identifier beside the
-- level rather than being told in a panel, which is what keeps a SUB channel
-- from being fed the fullrange mix.
--
-- Faders stay Derma-only - no wire for those.
function ENT:CreateWirePorts()
  -- Entity files load before lua/autorun, so the shared constant may not exist
  -- yet on a cold start. 16 is the real limit either way.
  local maxCh = (NTx and NTx.WIRE_MAX_MIX_CH) or 16
  local inNames, inDesc = {}, {}
  for i = 1, maxCh do
    inNames[i] = "In" .. i
    inDesc[i] = "Source bus levels on channel " .. i .. " [MidL, MidR, SubL, SubR]"
  end
  local outNames, outDesc = {}, {}
  local ids = (NTx and NTx.BUS_ID_PORTS) or { "MidLBus", "MidRBus", "SubLBus", "SubRBus" }
  local levels = (NTx and NTx.BUS_PORTS) or { "MidL", "MidR", "SubL", "SubR" }
  for i = 1, 4 do
    outNames[i] = levels[i]
    outDesc[i] = "Mix level for " .. levels[i] .. ", 0 to 1"
  end
  for i = 1, 4 do
    outNames[4 + i] = ids[i]
    outDesc[4 + i] = "Bus identifier for " .. levels[i] .. " (" .. (i - 1) .. ")"
  end
  -- Signal ports are the 16 inputs plus all 8 outputs, and they are the only
  -- ports on this entity, so every one of them is signal typed.
  NTx.WireSetup(self, inNames, inDesc, outNames, outDesc, maxCh, 8,
    (function()
      local t = {}
      for i = 1, maxCh do t[i] = "ARRAY" end
      return t
    end)())
end
