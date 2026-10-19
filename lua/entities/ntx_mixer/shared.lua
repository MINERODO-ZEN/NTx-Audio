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
-- each carry a PAIR - the level and the bus identifier - in one ARRAY, so a
-- signal and the bus it belongs to always travel together and cannot be wired
-- to the wrong channel. An amplifier wired to "SubR" therefore learns what it
-- is being fed from the wire itself, rather than being told in a panel.
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
  local levels = (NTx and NTx.BUS_PORTS) or { "MidL", "MidR", "SubL", "SubR", "SubMono" }
  local nBus = (NTx and NTx.BUS_COUNT) or 5
  for i = 1, nBus do
    outNames[i] = levels[i]
    outDesc[i] = "Level and bus identifier for " .. levels[i] .. " [level, id]"
  end
  local inOv = {}
  for i = 1, maxCh do inOv[i] = "ARRAY" end
  local outOv = {}
  for i = 1, nBus do outOv[i] = "ARRAY" end
  -- Every port on this entity is signal typed; the overrides say the shape.
  NTx.WireSetup(self, inNames, inDesc, outNames, outDesc, maxCh, nBus, outOv, inOv)
end
