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

  -- Electrical: what the cabinet is and what it can survive. Profile is the
  -- archetype these came from; the numbers stay individually editable so a
  -- one-off box does not need a saved profile.
  self:NetworkVar("String", 2, "Profile", { KeyName = "spkprof", Edit = { type = "Generic", order = 7, category = "NTx Power" } })
  self:NetworkVar("Float", 2, "Impedance", { KeyName = "imp", Edit = { type = "Float", min = 0.5, max = 1000, step = 0.5, order = 8, category = "NTx Power" } })
  self:NetworkVar("Float", 3, "RmsW", { KeyName = "rmsw", Edit = { type = "Float", min = 0, max = 20000, step = 5, order = 9, category = "NTx Power" } })
  self:NetworkVar("Float", 4, "PeakW", { KeyName = "peakw", Edit = { type = "Float", min = 0, max = 40000, step = 5, order = 10, category = "NTx Power" } })
  self:NetworkVar("Float", 5, "MinAmpW", { KeyName = "minampw", Edit = { type = "Float", min = 0, max = 20000, step = 5, order = 11, category = "NTx Power" } })
  -- 0 = low impedance output, otherwise the constant-voltage tap (70 / 100).
  self:NetworkVar("Int", 0, "TapVolt", { KeyName = "tapv", Edit = { type = "Combo", values = { ["low-Z"] = "0", ["70 V"] = "70", ["100 V"] = "100" }, order = 12, category = "NTx Power" } })
  -- Series wiring: speakers sharing a non-zero group sit in series, groups run
  -- in parallel. 0 = solo branch.
  self:NetworkVar("Int", 1, "SeriesGroup", { KeyName = "seriesgrp", Edit = { type = "Float", min = 0, max = 8, step = 1, order = 13, category = "NTx Power" } })
  -- Self-powered cabinet: driven straight off the mixer, no amplifier in the
  -- chain and no simulation at all.
  self:NetworkVar("Bool", 2, "Active", { KeyName = "active", Edit = { type = "Boolean", order = 14, category = "NTx Power" } })
  self:NetworkVar("Entity", 1, "Amp", { KeyName = "amp" })
  self:NetworkVar("Int", 2, "AmpChannel", { KeyName = "ampch", Edit = { type = "Float", min = 0, max = 8, step = 1, order = 15, category = "NTx Power" } })

  -- Simulation state (server authoritative, networked for panels and wires).
  self:NetworkVar("Float", 6, "CoilTemp", { KeyName = "coiltemp", Edit = { type = "Float", min = -50, max = 400, step = 1, order = 16, category = "NTx Sim" } })
  self:NetworkVar("Float", 7, "Damage", { KeyName = "spkdamage", Edit = { type = "Float", min = 0, max = 1, step = 0.01, order = 17, category = "NTx Sim" } })
  self:NetworkVar("Bool", 3, "Blown", { KeyName = "blown", Edit = { type = "Boolean", order = 18, category = "NTx Sim" } })

  self:NetworkVar("Entity", 0, "Mixer")
end

-- Electrical stamp from a speaker profile. Kept on the entity so the tool, the
-- Utilities page and the duplicator all land on the same code path.
function ENT:ApplySpeakerProfile(id)
  -- ById, not SpeakerProfile: a saved profile lives in the CLIENT's table, not
  -- in the built-in one, and looking it up in the wrong place is what made
  -- "load this profile I saved" do nothing at all.
  local p = NTx.SpeakerProfileById(id)
  if not p then return false end
  return self:ApplySpeakerProfileData(p)
end

-- The stamp from a profile's VALUES rather than from an id.
--
-- The saved profiles live in the client's own folder, so the server has no
-- copy to look up: the client sends the values and the server puts them on the
-- cabinet. The values are clamped here because they come from the client.
function ENT:ApplySpeakerProfileData(p)
  if not istable(p) then return false end
  self:SetProfile(tostring(p.id or ""))
  self:SetSpeakerType(NTx.IsSpeakerType(p.stype) and p.stype or self:GetSpeakerType())
  self:SetImpedance(math.Clamp(tonumber(p.ohm) or 8, 0.1, 100000))
  self:SetRmsW(math.Clamp(tonumber(p.rmsW) or 100, 0, 100000))
  self:SetPeakW(math.Clamp(tonumber(p.peakW) or (tonumber(p.rmsW) or 100) * 2, 0, 200000))
  self:SetMinAmpW(math.Clamp(tonumber(p.minAmpW) or 50, 0, 100000))
  self:SetTapVolt(math.Clamp(math.floor(tonumber(p.tapVolt) or 0), 0, 240))
  if p.hifov then self:SetMidHFov(math.Clamp(tonumber(p.hifov) or 152, 5, 360)) end
  if p.vifov then self:SetMidVFov(math.Clamp(tonumber(p.vifov) or 57, 5, 360)) end
  return true
end

-- The bus this cabinet wants from an amplifier channel, used by the link
-- validation and by the mixer-link panel's pre-selection.
function ENT:BusType()
  return self:GetSpeakerType() == "SUB" and "sub" or "mid"
end

-- Per-cabinet wire readouts, so a driver can be monitored without reading the
-- amplifier's aggregate numbers. Rebuilds with the model's channel list; called
-- from Initialize in both realms because the wire view needs the client side
-- too.
function ENT:CreateWirePorts()
  -- Signal first: "In" is what the topology walk follows, "Out" is how cabinets
  -- are daisy-chained. Both carry a plain 0-1 level; the actual audio is decoded
  -- client side, so the wire is topology, not a signal path.
  --
  -- "Link" is an ARRAY of entities: every OTHER cabinet in this speaker's
  -- chain, walked both upstream and downstream. It exists so a chain can be
  -- inspected or handed to another addon (a delay rack, a metering entity)
  -- without anyone having to walk Inputs[].Src by hand. Values are server-side
  -- only, like every other Wiremod port value.
  local inNames = { "In" }
  local inDesc = { "Signal level in, 0 to 1" }
  local outNames = {
    "Out", "Link", "TempC", "Damage", "Blown", "PRms", "PPeak", "PRated", "PPeakRated",
    "LoadOhm", "SeriesOhm", "PrmsLimit", "PpeakLimit",
  }
  local outDesc = {
    "Signal level out, 0 to 1 (pass-through for series cabinets)",
    "Every other cabinet in this chain [ARRAY]",
    "Voice coil temperature, C", "Cumulative damage, 0 to 1", "1 once the driver is burnt",
    "Power delivered right now, watts RMS", "Power delivered right now, watts peak",
    "Continuous (RMS) power rating, watts", "Peak power rating, watts",
    "Cabinet impedance, ohms", "Impedance of this series group, ohms",
    "RMS power limit, watts", "Peak power limit, watts",
  }
  NTx.WireSetup(self, inNames, inDesc, outNames, outDesc, 1, 1, { [2] = "ARRAY" })
end