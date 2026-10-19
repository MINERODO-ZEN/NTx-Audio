AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

NTx = NTx or {}
NTx.Amplifiers = NTx.Amplifiers or {}

function ENT:Initialize()
  self:SetModel("models/props_lab/reciever01b.mdl")
  -- The profile, and the model with it, BEFORE the physics is built. The
  -- collision shape is taken from whatever model is in place when PhysicsInit
  -- runs, so applying the profile afterwards left a Powersoft amplifier
  -- wearing the default chassis's collision.
  --
  -- AmpProfileId is set by whoever spawned it - the model-specific spawn menu
  -- entry, or the duplicator. A plain amplifier has neither and falls back to
  -- the default profile.
  self:ApplyAmpProfile(self.AmpProfileId or self:GetProfile() or "cdi1000")
  self:PhysicsInit(SOLID_VPHYSICS)
  self:SetMoveType(MOVETYPE_PHYSICS)
  self:SetSolid(SOLID_VPHYSICS)
  local phys = self:GetPhysicsObject()
  if IsValid(phys) then phys:Wake() end
  self:CreateWirePorts()
  if self:GetTempSink() == 0 then self:SetTempSink(22) end
  if self:GetTempDev() == 0 then self:SetTempDev(22) end
  -- Wire-fed mains take over as soon as anything drives the input; until then
  -- the amp reads the server's external grid value.
  self.WireMains = {}
  self.WireSignal = {}
  self.WireLevelsOut = {}
  if NTx.InstallWireHooks then NTx.InstallWireHooks(self) end
  -- Wrapped, not replaced: InstallWireHooks already owns the rebuild trigger.
  -- PowerIn latches because a wire only fires on change, so it needs an unlink
  -- to let go - otherwise a pulled cable is indistinguishable from a closed
  -- contactor and the amplifier stays dead.
  local prevUnlink = self.OnInputWireUnlink
  self.OnInputWireUnlink = function()
    self:SetPowerWire(0)
    if prevUnlink then prevUnlink() end
  end
  self.Injected = ""
  NTx.Amplifiers[self] = true
end

-- The simulation writes the per-channel output level here once per tick, so the
-- wire value reflects what the amp is really doing rather than what was fed in.
function ENT:SetWireChannelLevel(ch, level)
  self.WireLevelsOut = self.WireLevelsOut or {}
  local v = math.Clamp(tonumber(level) or 0, 0, 2)
  if self.WireLevelsOut[ch] == v then return end
  self.WireLevelsOut[ch] = v
  if NTx.WireChannelOf then NTx.WireOut(self, NTx.WireSigPortOut(ch), v) end
end

function ENT:OnRemove()
  NTx.Amplifiers[self] = nil
  -- Speakers driven by this amp fall back to being driven straight off the
  -- mixer rather than pointing at a dead entity.
  for _, e in ipairs(ents.FindByClass("ntx_speaker")) do
    if IsValid(e) and e.GetAmp and e:GetAmp() == self then e:SetAmp(NULL) end
  end
  if NTx.AmpSimDrop then NTx.AmpSimDrop(self) end
  if NTx.BroadcastGraph then NTx.BroadcastGraph() end
end

function ENT:SpawnFunction(ply, tr)
  if not tr.Hit then return end
  -- GMod calls this as ENT.SpawnFunction, so self is the CLASS TABLE, not an
  -- entity - self:GetClass() does not exist here. GMod puts the class name on
  -- the class table as ClassName when it registers, so that is what to use:
  -- it is already correct for the variant classes, which are the whole point.
  local ent = ents.Create(self.ClassName or "ntx_amplifier")
  ent:SetPos(tr.HitPos + tr.HitNormal * 8)
  ent:Spawn()
  ent:Activate()
  if CPPI then ent:CPPISetOwner(ply) end
  undo.Create("NTx " .. tostring(self.PrintName or "Amplifier"))
  undo.AddEntity(ent)
  undo.SetPlayer(ply)
  undo.Finish()
  return ent
end

-- Wire inputs. MainsV is the interesting one: whatever the external power
  -- simulation puts on it wins over the amp's own override, which is how a
  -- venue-wide brownout reaches every amplifier at once.
  --
  -- Ch<N>In is the signal level per channel. Wiremod fires this on connect and
  -- on every output change, so the value is simply the latest one received;
  -- the simulation reads it instead of summing the mixer bus itself.
function ENT:TriggerInput(name, value)
  self.WireMains = self.WireMains or {}
  local v = tonumber(value) or 0
  if name == "PowerIn" then
    -- Latched, like a real switch: a wire only fires on change, so holding the
    -- value is what makes a latching contactor behave. Reset to 0 when the
    -- wire comes out, or unplugging would leave the amplifier off forever.
    self:SetPowerWire(v > 0.5 and 1 or 2)
  elseif name == "MainsV" then
    self.WireMains.v = v
  elseif name == "MainsHz" then
    self.WireMains.hz = v
  else
    local ch = NTx.WireChannelOf and NTx.WireChannelOf(name) or nil
    if ch then
      -- The mixer sends a PAIR: level and bus identifier, in one array.
      -- Splitting it here is what makes the channel's type a consequence of
      -- the wiring rather than of a panel setting.
      if istable(value) then
        self:SetChannelBus(ch, value[2])
        self.WireSignal = self.WireSignal or {}
        self.WireSignal[ch] = math.Clamp(tonumber(value[1]) or 0, 0, 2)
      else
        -- A bare number still works, for a source that only carries a level.
        self.WireSignal = self.WireSignal or {}
        self.WireSignal[ch] = math.Clamp(v, 0, 2)
      end
    end
  end
end

-- Mains voltage this amplifier believes it has, in precedence order.
function ENT:MainsVoltage(nominal)
  local w = self.WireMains or {}
  if tonumber(w.v) and w.v > 0 then return math.Clamp(w.v, 0, 500) end
  local ov = tonumber(self:GetMainsOverride()) or 0
  if ov > 0 then return math.Clamp(ov, 0, 500) end
  return math.Clamp(tonumber(nominal) or 230, 0, 500)
end

function ENT:PreEntityCopy()
  duplicator.StoreEntityModifier(self, "NtxAmp", {
    profile = self:GetProfile(),
    chans = self:GetChannels(), ratedw = self:GetRatedW(), ratedz = self:GetRatedLoad(),
    minz = self:GetMinLoad(), sens = self:GetSens(), trim = self:GetTrim(), ilime = self:GetIlime(),
    mode = self:GetMode(), hizv = self:GetHizVolt(), busmask = self:GetBusMask(), meters = self:GetMeters(),
    chanbus = self:GetChannelBuses(), chanfed = self:GetChannelFed(),
    pfc = self:GetPFC(),
    fan = self:GetFanNoise(), fandb = self:GetFanNoiseDb(),
    standby = self:GetAutoStandby(), sbdelay = self:GetStandbyDelay(),
    cliphold = self:GetClipHold(), crest = self:GetCrestDb(), thbias = self:GetThermalBias(),
    mainsov = self:GetMainsOverride(), ambient = self:GetAmbient(),
    power = self:GetPower(), fanon = self:GetFanOn(),
  })
end

function ENT:PostEntityPaste(ply, ent, created)
  local d = ent.EntityMods and ent.EntityMods.NtxAmp
  if d then
    self:SetProfile(tostring(d.profile or ""))
    -- A profile the addon no longer knows about leaves the entity with its
    -- stamped numbers instead of nothing at all.
    if not self:ApplyAmpProfile(self:GetProfile()) then
      self:SetProfile("")
    end
    self:SetChannels(math.Clamp(math.floor(tonumber(d.chans) or 2), 1, 8))
    self:SetRatedW(math.Clamp(tonumber(d.ratedw) or 100, 1, 50000))
    self:SetRatedLoad(math.Clamp(tonumber(d.ratedz) or 8, 1, 1000))
    self:SetMinLoad(math.Clamp(tonumber(d.minz) or 2, 0.1, 100))
    self:SetSens(math.Clamp(tonumber(d.sens) or 1.4, 0.05, 10))
    self:SetTrim(math.Clamp(tonumber(d.trim) or 0, -40, 24))
    self:SetIlime(math.Clamp(tonumber(d.ilime) or 20, 1, 60))
    self:SetMode(math.Clamp(math.floor(tonumber(d.mode) or 0), 0, 2))
    self:SetHizVolt(math.Clamp(math.floor(tonumber(d.hizv) or 0), 0, 240))
    self:SetBusMask(math.Clamp(math.floor(tonumber(d.busmask) or 0), 0, 255))
    self:SetChannelBuses(math.Clamp(math.floor(tonumber(d.chanbus) or 0), 0, 65535))
    self:SetChannelFed(math.Clamp(math.floor(tonumber(d.chanfed) or 0), 0, 255))
    self:SetMeters(math.Clamp(math.floor(tonumber(d.meters) or 0), 0, 2))
    self:SetPFC(d.pfc == true)
    self:SetFanNoise(d.fan == true)
    self:SetFanNoiseDb(math.Clamp(tonumber(d.fandb) or -120, -120, 0))
    self:SetAutoStandby(d.standby == true)
    self:SetStandbyDelay(math.Clamp(tonumber(d.sbdelay) or 180, 0, 600))
    self:SetClipHold(math.Clamp(tonumber(d.cliphold) or 0.1, 0, 2))
    self:SetCrestDb(math.Clamp(tonumber(d.crest) or 12, 0, 30))
    self:SetThermalBias(math.Clamp(tonumber(d.thbias) or 1, 0.4, 3))
    self:SetMainsOverride(math.Clamp(tonumber(d.mainsov) or 0, 0, 400))
    self:SetAmbient(math.Clamp(tonumber(d.ambient) or 0, -20, 60))
    self:SetPower(d.power ~= false)
    self:SetFanOn(d.fanon ~= false)
    self:CreateWirePorts()
  end
  if NTx.Amplifiers then NTx.Amplifiers[self] = true end
  if NTx.BroadcastGraph then NTx.BroadcastGraph() end
end

-- The variant classes, registered HERE and not at InitPostEntity.
--
-- Two things make this the right moment. The spawn menu takes its list of
-- entity classes once, and InitPostEntity is after that - registering there
-- produced classes the menu never saw, and the Powersoft tab simply was not
-- there. And this is the end of the base's own file, so the table handed on
-- is complete: shared.lua is included at the top of the file, and the
-- Initialize below is added after it.
--
-- The table is handed over rather than looked up. The engine registers the
-- base class only after this file returns, so scripted_ents.GetStored finds
-- nothing here - which is why an earlier version registered nothing at all
-- and fell back to InitPostEntity, too late for the menu.
NTx.AmpBaseTable = ENT
if NTx.RegisterAmpVariants then NTx.RegisterAmpVariants() end