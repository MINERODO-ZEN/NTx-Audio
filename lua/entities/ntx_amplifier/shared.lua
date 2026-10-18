ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "NTx Power Amplifier"
ENT.Author = "NTx port"
ENT.Category = "NTx Audio"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.Editable = true

-- Mode and meter style are enums shared with the model and the panels, so they
-- are named once here instead of being magic numbers in five files.
ENT.MODE = { ["Dual"] = 0, ["Bridge-mono"] = 1, ["Parallel-mono"] = 2 }
ENT.METERS = { ["Off"] = 0, ["Crown MA (IOC / ODEP)"] = 1, ["Crown CDi (3 LED)"] = 2 }

function ENT:SetupDataTables()
  self:NetworkVar("String", 0, "Profile", { KeyName = "ampprof", Edit = { type = "Generic", order = 1, category = "NTx Amp" } })

  -- Output stage. These mirror the profile the amp was built from, and stay
  -- editable so two "MA2400"s on one rack can disagree (as they do in life).
  self:NetworkVar("Int", 0, "Channels", { KeyName = "ampchans", Edit = { type = "Float", min = 1, max = 8, step = 1, order = 2, category = "NTx Amp" } })
  self:NetworkVar("Float", 0, "RatedW", { KeyName = "ratedw", Edit = { type = "Float", min = 1, max = 20000, step = 5, order = 3, category = "NTx Amp" } })
  self:NetworkVar("Float", 1, "RatedLoad", { KeyName = "ratedz", Edit = { type = "Float", min = 1, max = 1000, step = 1, order = 4, category = "NTx Amp" } })
  self:NetworkVar("Float", 2, "MinLoad", { KeyName = "minz", Edit = { type = "Float", min = 0.1, max = 100, step = 0.5, order = 5, category = "NTx Amp" } })
  self:NetworkVar("Float", 3, "Sens", { KeyName = "sensv", Edit = { type = "Float", min = 0.05, max = 10, step = 0.025, order = 6, category = "NTx Amp" } })
  -- The front-panel level control, in dB around the profile's nominal
  -- sensitivity. Trim changes gain without changing what the amp can deliver.
  self:NetworkVar("Float", 4, "Trim", { KeyName = "amptrim", Edit = { type = "Float", min = -40, max = 24, step = 0.5, order = 7, category = "NTx Amp" } })
  self:NetworkVar("Float", 5, "Ilime", { KeyName = "ilime", Edit = { type = "Float", min = 1, max = 60, step = 0.5, order = 8, category = "NTx Amp" } })
  -- self.MODE, not ENT.MODE: the global ENT only exists while the file is being
  -- loaded. SetupDataTables runs later, at spawn, when ENT is gone - and an
  -- error here silently aborts every NetworkVar declared after it.
  self:NetworkVar("Int", 1, "Mode", { KeyName = "ampmode", Edit = { type = "Combo", values = self.MODE, order = 9, category = "NTx Amp" } })
  -- Constant-voltage tap for installed-sound runs (CDi only). 0 = low-Z.
  self:NetworkVar("Int", 2, "HizVolt", { KeyName = "hizv", Edit = { type = "Combo", values = { ["low-Z"] = "0", ["70 V"] = "70", ["100 V"] = "100" }, order = 10, category = "NTx Amp" } })
  -- One bit per channel: set = SUB bus, clear = MID bus. The amp reads the
  -- matching mixer bus, so the meters and the heat are honest about what the
  -- channel is actually driving.
  self:NetworkVar("Int", 3, "BusMask", { KeyName = "busmask", Edit = { type = "Float", min = 0, max = 255, step = 1, order = 11, category = "NTx Amp" } })
  self:NetworkVar("Int", 4, "Meters", { KeyName = "ampmeters", Edit = { type = "Combo", values = self.METERS, order = 12, category = "NTx Amp" } })

  -- Behaviour that differs between one amplifier and the next, each on its own
  -- switch rather than a single "realistic" flag: a car amplifier has no
  -- transformer hum and no 1200 W heatsink worth listening to, a vintage
  -- class AB rack has both.
  self:NetworkVar("Bool", 0, "PFC", { KeyName = "amppfc", Edit = { type = "Boolean", order = 13, category = "NTx Amp Behaviour" } })
  self:NetworkVar("Bool", 1, "MainsHum", { KeyName = "ampthum", Edit = { type = "Boolean", order = 14, category = "NTx Amp Behaviour" } })
  self:NetworkVar("Float", 9, "HumDb", { KeyName = "humdb", Edit = { type = "Float", min = -120, max = -20, step = 1, order = 15, category = "NTx Amp Behaviour" } })
  self:NetworkVar("Bool", 2, "FanNoise", { KeyName = "ampfan", Edit = { type = "Boolean", order = 16, category = "NTx Amp Behaviour" } })
  self:NetworkVar("Float", 10, "FanNoiseDb", { KeyName = "fandb", Edit = { type = "Float", min = -60, max = 0, step = 1, order = 17, category = "NTx Amp Behaviour" } })
  self:NetworkVar("Bool", 3, "AutoStandby", { KeyName = "ampstandby", Edit = { type = "Boolean", order = 18, category = "NTx Amp Behaviour" } })
  self:NetworkVar("Float", 11, "StandbyDelay", { KeyName = "standbydelay", Edit = { type = "Float", min = 0, max = 600, step = 5, order = 19, category = "NTx Amp Behaviour" } })
  self:NetworkVar("Float", 6, "ClipHold", { KeyName = "cliphold", Edit = { type = "Float", min = 0, max = 2, step = 0.05, order = 20, category = "NTx Amp Behaviour" } })
  self:NetworkVar("Float", 7, "CrestDb", { KeyName = "crestdb", Edit = { type = "Float", min = 0, max = 30, step = 0.5, order = 21, category = "NTx Amp Behaviour" } })
  self:NetworkVar("Float", 8, "ThermalBias", { KeyName = "thbias", Edit = { type = "Float", min = 0.4, max = 3, step = 0.05, order = 22, category = "NTx Amp Behaviour" } })
  self:NetworkVar("Float", 12, "MainsOverride", { KeyName = "mainsov", Edit = { type = "Float", min = 0, max = 400, step = 1, order = 23, category = "NTx Amp Behaviour" } })
  self:NetworkVar("Float", 13, "Ambient", { KeyName = "ambientov", Edit = { type = "Float", min = -20, max = 60, step = 1, order = 24, category = "NTx Amp Behaviour" } })

  -- Runtime state, networked so a client far from the amplifier (or outside the
  -- sync radius) still shows a truthful panel instead of a dead one.
  -- Derived, not authored: two bits per channel holding the bus id the mixer
  -- published on Ch<N>Bus. This is the mirror the client panel reads, exactly
  -- as Amp/AmpChannel are - wires own the truth, this replicates it.
  self:NetworkVar("Int", 6, "ChannelBuses", { KeyName = "chanbus", Edit = { type = "Float", min = 0, max = 65535, step = 1, order = 14, category = "NTx Amp" } })
  self:NetworkVar("Bool", 4, "Power", { KeyName = "amppower", Edit = { type = "Boolean", order = 1, category = "NTx Amp Sim" } })
  self:NetworkVar("Bool", 5, "FanOn", { KeyName = "ampfanon", Edit = { type = "Boolean", order = 2, category = "NTx Amp Sim" } })
  self:NetworkVar("Bool", 6, "Standby", { KeyName = "ampstand", Edit = { type = "Boolean", order = 3, category = "NTx Amp Sim" } })
  self:NetworkVar("Float", 14, "Damage", { KeyName = "ampdamage", Edit = { type = "Float", min = 0, max = 1, step = 0.01, order = 4, category = "NTx Amp Sim" } })
  self:NetworkVar("Bool", 7, "Blown", { KeyName = "ampblown", Edit = { type = "Boolean", order = 5, category = "NTx Amp Sim" } })
  self:NetworkVar("Float", 15, "TempSink", { KeyName = "tsink", Edit = { type = "Float", min = -20, max = 200, step = 1, order = 6, category = "NTx Amp Sim" } })
  self:NetworkVar("Float", 16, "TempDev", { KeyName = "tdev", Edit = { type = "Float", min = -20, max = 300, step = 1, order = 7, category = "NTx Amp Sim" } })
  self:NetworkVar("Float", 17, "FanRpm", { KeyName = "fanrpm", Edit = { type = "Float", min = 0, max = 12000, step = 10, order = 8, category = "NTx Amp Sim" } })
  self:NetworkVar("Int", 5, "FaultCode", { KeyName = "faultcode", Edit = { type = "Combo", values = { ["none"] = "0", ["brownout"] = "1", ["overvoltage"] = "2", ["mains absent"] = "3", ["thermal protect"] = "4", ["overload"] = "5", ["short circuit"] = "6", ["DC offset"] = "7", ["burnt out"] = "8", ["standby"] = "9" }, order = 9, category = "NTx Amp Sim" } })
  self:NetworkVar("Bool", 8, "ClipLatch", { KeyName = "cliplatch", Edit = { type = "Boolean", order = 10, category = "NTx Amp Sim" } })

  self:NetworkVar("Entity", 0, "Mixer")

  -- Wire ports follow the channel count. NetworkVarNotify has to be called from
  -- here: it is an entity method, injected at runtime, so it does not exist on
  -- the ENT table at file scope. self.OnChannelsChanged is safe to look up at
  -- this point because SetupDataTables runs when an entity SPAWNS, long after
  -- this whole file has finished loading.
  self:NetworkVarNotify("Channels", self.OnChannelsChanged)
end

-- Stamp a profile onto the entity. Every "this amp is a different kind of box"
-- field comes from here, which is what makes MA2400 and CDi 1000 behave like
-- different machines off the same code path.
function ENT:ApplyAmpProfile(id)
  local p = NTx.AmpProfile(id)
  if not p then return false end
  self:SetProfile(p.id)
  self:SetChannels(p.channels)
  self:SetRatedW(NTx.AmpModeRatedW(p, 0))
  self:SetRatedLoad(p.ratedLoad)
  self:SetMinLoad(p.minLoad)
  self:SetIlime(p.ilim)
  self:SetSens(p.sens)
  -- Level control parked so that 0 dBFS (+4 dBu) lands on rated power at the
  -- rated load: trim = 20 log10(sens / 1.2309). Moving the sensitivity switch
  -- afterwards really does move the gain, exactly like the real switch.
  self:SetTrim(math.Round(NTx.AmpDb(p.sens / NTx.AMP_FS_VOLTS), 2))
  self:SetHizVolt(0)
  self:SetMeters(p.stock.meters)
  self:SetPFC(p.stock.pfc == true)
  self:SetMainsHum(p.stock.mainsHum == true)
  self:SetHumDb(p.humDb)
  self:SetFanNoise(p.stock.fanNoise == true)
  self:SetFanNoiseDb(p.stock.fanNoise and -24 or -120)
  self:SetAutoStandby(p.stock.autoStandby == true)
  self:SetStandbyDelay(180)
  self:SetClipHold(p.clipHold)
  self:SetCrestDb(p.crestDb)
  self:SetThermalBias(1)
  self:SetMainsOverride(0)
  self:SetAmbient(0)
  self:SetPower(true)
  self:SetFanOn(true)
  self:SetStandby(false)
  self:SetDamage(0)
  self:SetBlown(false)
  self:SetTempSink(22)
  self:SetTempDev(22)
  self:SetFanRpm(0)
  self:SetFaultCode(0)
  self:SetClipLatch(false)
  if p.model then self:SetModel(p.model) end
  if p.mass then
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:SetMass(math.Clamp(p.mass, 1, 200)) end
  end
  return true
end

function ENT:Prof()
  return NTx.AmpProfile(self:GetProfile())
end

function ENT:UsableChannels()
  return NTx.AmpUsableChannels(self:Prof(), self:GetMode())
end

-- Does this channel take SUB cabinets? Bit n of BusMask.

-- Channels that feed this output, honouring bridge/parallel pairing.
function ENT:ChannelPair(ch)
  local p = self:Prof()
  for i, pair in ipairs(NTx.AmpChannelPairs(p, self:GetMode())) do
    if ch == pair[1] or ch == pair[2] then return pair end
  end
  return { ch, ch }
end

-- Which single channels the current mode actually uses (bridge/parallel skip
-- the second element of every pair).
function ENT:ActiveChannels()
  local n, out = self:UsableChannels(), {}
  for i = 1, n do out[i] = i end
  return out
end

-- Wire ports. Created in BOTH realms: the server owns the values, but the wire
-- view is drawn on the client and needs the port list to exist here too. Called
-- from Initialize in both realms and whenever the channel count changes.
function ENT:CreateWirePorts()
  local n = math.Clamp(math.floor(self:GetChannels() or 2), 1, 8)
  local inNames, inDesc = {}, {}
  local outNames, outDesc = {}, {}
  local function add(list, dlist, name, desc)
    list[#list + 1] = name
    dlist[#dlist + 1] = desc
  end

  -- ORDER MATTERS. WireSetup types every port up to sigCount as signal, so the
  -- signal ports have to come FIRST. Getting this wrong types the mains inputs
  -- as signal too, which then refuses a wire from an external power-line
  -- simulator (its voltage output is NORMAL, not NTXSIG).
  --
  -- Signal in/out is the pair the topology walk follows: a mixer's bus level
  -- lands on Ch<N>In and Ch<N>Bus feeds the cabinets, and Ch<N>Out drives
  -- whatever is on that channel's outputs. The identifier beside the level is
  -- what tells the amplifier what bus it is being fed.
  for i = 1, n do
    add(inNames, inDesc, "Ch" .. i .. "In", "Signal level into channel " .. i .. ", 0 to 1")
    add(inNames, inDesc, "Ch" .. i .. "Bus", "Bus identifier for channel " .. i
      .. " (0 MidL / 1 MidR / 2 SubL / 3 SubR)")
  end
  -- Numeric telemetry, NORMAL type, so external wiring can reach them.
  add(inNames, inDesc, "MainsV", "Mains voltage, volts RMS")
  add(inNames, inDesc, "MainsA", "Mains current, amperes")
  add(inNames, inDesc, "MainsHz", "Mains frequency, hertz")

  for i = 1, n do
    add(outNames, outDesc, "Ch" .. i .. "Out", "Output signal level on channel " .. i .. ", 0 to 1")
  end
  for i = 1, n do
    add(outNames, outDesc, "Ch" .. i .. "Amps", "Output current, amperes RMS (load)")
    add(outNames, outDesc, "Ch" .. i .. "Volt", "Output voltage, volts RMS")
    add(outNames, outDesc, "Ch" .. i .. "Watt", "Output power, watts")
    add(outNames, outDesc, "Ch" .. i .. "Ohm", "Measured load, ohms")
    add(outNames, outDesc, "Ch" .. i .. "Clip", "1 while clipping, 0 otherwise")
    add(outNames, outDesc, "Ch" .. i .. "Protect", "1 while protecting, 0 otherwise")
  end
  add(outNames, outDesc, "MainsV", "Mains voltage in use, volts RMS")
  add(outNames, outDesc, "MainsA", "Mains current draw, amperes RMS")
  add(outNames, outDesc, "PF", "Power factor (PFC supply near 1.0)")
  add(outNames, outDesc, "PinW", "Real power drawn from the mains, watts (output plus overhead)")
  add(outNames, outDesc, "LoadA", "Total load current on the incoming supply, amperes RMS")
  add(outNames, outDesc, "RailV", "Internal supply rail, volts DC")
  add(outNames, outDesc, "TotalW", "Dissipation only, watts - heat, NOT what the supply delivers")
  add(outNames, outDesc, "TempC", "Heatsink temperature, C")
  add(outNames, outDesc, "TempDevC", "Hottest output device, C")
  add(outNames, outDesc, "FanRpm", "Fan speed, rpm")
  add(outNames, outDesc, "GainRedDb", "Thermal gain reduction, dB")
  add(outNames, outDesc, "Damage", "Cumulative damage, 0 to 1")
  add(outNames, outDesc, "FaultCode", "0 none / 1 brownout / 2 overvoltage / 3 no mains / 4 thermal / 5 overload / 6 short / 7 DC / 8 burnt")
  -- Signal ports are the n Ch<N>In and the n Ch<N>Bus pairs, and they are the
  -- only ports before the mains block below.
  NTx.WireSetup(self, inNames, inDesc, outNames, outDesc, 2 * n, n)
end

-- The bus this channel is fed, derived from the identifier the mixer publishes
-- beside the level. This is what the channel IS: not a panel setting that can
-- disagree with the wiring. Returns nil when nothing identifies it yet.
function ENT:ChannelBusId(ch)
  local packed = self:GetChannelBuses() or 0
  local shift = (math.floor(tonumber(ch) or 1) - 1) * 2
  if shift < 0 then return nil end
  local id = bit.band(bit.rshift(packed, shift), 3)
  return NTx.BusClamp(id)
end

-- Records one channel's bus. Called from TriggerInput when the mixer's
-- identifier arrives, and from the duplicator.
function ENT:SetChannelBus(ch, id)
  local shift = (math.floor(tonumber(ch) or 1) - 1) * 2
  if shift < 0 then return end
  local packed = self:GetChannelBuses() or 0
  packed = bit.band(packed, bit.bnot(bit.lshift(3, shift)))
  packed = bit.bor(packed, bit.lshift(NTx.BusClamp(id), shift))
  self:SetChannelBuses(packed)
end

function ENT:ChannelBus(ch)
  local id = self:ChannelBusId(ch)
  return id or NTx.BUS_MIDL
end

-- Kept for the code that asks "does this channel feed SUB cabinets". Now
-- derived rather than read from a hand-set bitfield.
function ENT:ChannelIsSub(ch)
  return NTx.BusIsSub(self:ChannelBus(ch))
end

function ENT:OnChannelsChanged()
  self:CreateWirePorts()
end