-- Server: authoritative amplifier and speaker simulation.
--
-- One 10 Hz pass over every amplifier. Nothing here is predicted and nothing
-- here is client-authored: the faders, speaker wiring and mains voltage are all
-- server-known, so two players looking at the same rig see the same numbers.
--
-- Per channel the chain is:
--   mixer bus level -> amplifier gain -> rail / current / thermal ceiling ->
--   clipping -> speaker load -> watts -> dissipation -> two-node thermal ->
--   protection -> damage
--
-- State lives in NTx.AmpState (amplifiers) and NTx.SpkState (drivers); the sync
-- message in ntx_net.lua reads it, and the wire outputs are driven here.
AddCSLuaFile()
if not SERVER then return end

NTx = NTx or {}
NTx.AmpState = NTx.AmpState or {}
NTx.SpkState = NTx.SpkState or {}

local SIM_HZ = 10
local TICK = 1 / SIM_HZ

CreateConVar("ntx_amp_sim", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
  "Run the amplifier/speaker simulation (0 = amplifiers are inert boxes, audio passes through untouched)")
CreateConVar("ntx_amp_damage", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
  "Amplifiers and drivers accumulate permanent damage when abused (0 = faults still happen, nothing ever dies)")
CreateConVar("ntx_spk_damage", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
  "Drivers accumulate damage from sustained over-power or peak overload (0 = speakers never blow)")
CreateConVar("ntx_crest_db", "6", FCVAR_ARCHIVE + FCVAR_REPLICATED,
  "Crest factor turning RMS output power into peak power (dB). 6 dB is typical programme material; Crown's thermal sheets test with 12 dB pink noise")
CreateConVar("ntx_mains_nominal", "230", FCVAR_ARCHIVE + FCVAR_REPLICATED,
  "Nominal mains voltage for amplifiers with no wire input and no override (V)")
CreateConVar("ntx_ambient_c", "22", FCVAR_ARCHIVE + FCVAR_REPLICATED,
  "Ambient temperature amplifiers and drivers sit in (C)")
CreateConVar("ntx_mains_hz", "50", FCVAR_ARCHIVE + FCVAR_REPLICATED,
  "Mains frequency (Hz); drives the pitch of audible mains hum")

function NTx.AmpSimEnabled()
  local cv = GetConVar("ntx_amp_sim")
  return cv == nil or cv:GetBool()
end

function NTx.AmpDamageEnabled()
  local cv = GetConVar("ntx_amp_damage")
  return cv == nil or cv:GetBool()
end

function NTx.SpkDamageEnabled()
  local cv = GetConVar("ntx_spk_damage")
  return cv == nil or cv:GetBool()
end

function NTx.AmpNominalMains()
  local cv = GetConVar("ntx_mains_nominal")
  return cv and cv:GetFloat() or 230
end

function NTx.AmpAmbient(ent)
  local ov = tonumber(ent and ent.GetAmbient and ent:GetAmbient()) or 0
  if ov ~= 0 then return ov end
  local cv = GetConVar("ntx_ambient_c")
  return cv and cv:GetFloat() or 22
end

function NTx.AmpSimDrop(ent)
  NTx.AmpState[ent] = nil
end

-- ---------------------------------------------------------------- gathering

-- Speakers wired to one amplifier channel. Active cabinets are skipped: they
-- are self-powered and sit outside the simulation entirely.
local function speakersOn(amp)
  local out = {}
  for _, spk in ipairs(ents.FindByClass("ntx_speaker")) do
    if IsValid(spk) and spk:GetAmp() == amp and not spk:GetActive() then out[#out + 1] = spk end
  end
  return out
end

-- Which channel a cabinet lands on. Shared with the client audio path so a tap
-- is always attributed to the channel the simulation charged for it.
local function channelOf(amp, spk)
  return NTx.AmpSpeakerChannel(amp, spk)
end

-- Input level reaching one amplifier channel: the matching mixer bus, summed
-- in energy across the inputs linked to that mixer. Mirrors the client gain
-- path exactly (master x bus x channel x input volume) so the meters and the
-- heat agree with what the speakers are actually being fed.
local function busLevel(mixer, bus)
  if not IsValid(mixer) then return 0 end
  if mixer.GetMasterMuted and mixer:GetMasterMuted() then return 0 end
  local busFader
  if bus == "sub" then
    if mixer.GetSubMuted and mixer:GetSubMuted() then return 0 end
    busFader = mixer:GetSubFader()
  else
    if mixer.GetMidMuted and mixer:GetMidMuted() then return 0 end
    busFader = mixer:GetMidFader()
  end
  local base = NTx.FaderToGain(mixer:GetMasterFader()) * NTx.FaderToGain(busFader)
  local energy = 0
  for _, inp in ipairs(ents.FindByClass("ntx_input_url")) do
    if IsValid(inp) and inp.GetMixer and inp:GetMixer() == mixer then
      local g = base
      local chFader, muted = 1, false
      for _, ch in ipairs(mixer.Channels or {}) do
        if ch.Input == inp then
          chFader, muted = ch.Fader, ch.Muted
          break
        end
      end
      if muted then return 0 end
      -- The input volume is applied linearly by the audio path, not tapered.
      g = g * NTx.FaderToGain(chFader) * (tonumber(inp:GetInputVolume()) or 1)
      energy = energy + g * g
    end
  end
  return math.sqrt(energy)
end

-- ------------------------------------------------------------ integration

local function approach(cur, target, dt, tau)
  if not tau or tau <= 0 then return target end
  return cur + (target - cur) * (1 - math.exp(-dt / tau))
end

-- One amplifier, one tick.
local function stepAmp(amp, now, dt)
  local p = amp:Prof()
  if not p then return end
  local st = NTx.AmpState[amp]
  if not st then
    st = { tsink = NTx.AmpAmbient(amp), tdev = NTx.AmpAmbient(amp), fan = 0, loadFrac = 0,
      bad = 0, good = 0, quiet = 0 }
    for i = 1, 8 do st[i] = { spk = {} } end
    NTx.AmpState[amp] = st
  end
  local th = p.thermal
  local ambient = NTx.AmpAmbient(amp)
  local damageEnabled = NTx.AmpDamageEnabled()
  local crest = NTx.AmpCrestDb(amp:GetCrestDb())
  local hizV = math.floor(tonumber(amp:GetHizVolt()) or 0)
  local busMask = amp:GetBusMask()

  -- Mains and the supply's opinion of it.
  local mains = amp:MainsVoltage(NTx.AmpNominalMains())
  local mainsState = NTx.AmpMainsState(p, mains, NTx.AmpNominalMains(), amp:GetPFC())
  local injected = amp.Injected or ""
  local powered = amp:GetPower() == true and not amp:GetBlown()

  -- Lockout: outside the supply's window the PSU stops trying. Mains-lockout is
  -- the difference between "the rig is quiet for a minute" and "it is dead".
  if mainsState ~= "ok" then
    st.bad = (st.bad or 0) + dt
    st.good = 0
  else
    st.good = (st.good or 0) + dt
    if st.good > 2 then st.bad = 0 end
  end
  local locked = (st.bad or 0) > 1

  -- Auto standby: no signal for the configured dwell time drops the output
  -- stage into its reduced supply (MA2400 manual 4.3.2, CDi Power Save).
  local standby = false
  if powered and amp:GetAutoStandby() and not locked and amp:UsableChannels() > 0 then
    local quiet = true
    local mixer = amp:GetMixer()
    if IsValid(mixer) then
      for _, ch in ipairs(amp:ActiveChannels()) do
        local bus = bit.band(busMask, bit.lshift(1, ch - 1)) ~= 0 and "sub" or "mid"
        if busLevel(mixer, bus) > 0.001 then quiet = false break end
      end
    end
    if quiet then
      st.quiet = (st.quiet or 0) + dt
      if st.quiet > math.max(amp:GetStandbyDelay(), 1) then standby = true end
    else
      st.quiet = 0
    end
  end

  local speakers = speakersOn(amp)
  local totalOut, totalDiss, peakDev, worstClip = 0, 0, -999, 1
  local anyProtect, anyClip, railAny = false, false, 0

  for _, ch in ipairs(amp:ActiveChannels()) do
    local c = st[ch]
    local pair = amp:ChannelPair(ch)
    local mode = NTx.AmpMode(p, amp:GetMode())
    local isSub = bit.band(busMask, bit.lshift(1, ch - 1)) ~= 0

    -- Load: every cabinet assigned to either half of a fused pair.
    local list, spkEnts = {}, {}
    for _, spk in ipairs(speakers) do
      local sc = channelOf(amp, spk)
      if sc == pair[1] or sc == pair[2] then
        list[#list + 1] = {
          ent = spk, ohm = spk:GetImpedance(), tapVolt = spk:GetTapVolt(),
          group = spk:GetSeriesGroup(), stype = spk:GetSpeakerType(),
          blown = spk:GetBlown(),
        }
        spkEnts[#spkEnts + 1] = spk
      end
    end
    local res = NTx.SpkChannelLoad(list, hizV > 0)
    local z = res.ohm

    -- Amplifier gain. Bridge and parallel-mono fuse a pair: both halves swing
    -- together, so the pair shares one current ceiling and doubles the voltage
    -- in bridge.
    local paired = (pair[1] ~= pair[2])
    local pairHalf = paired and 2 or 1
    local ratedZ = math.max(amp:GetRatedLoad(), 0.1)
    local sens = math.max(amp:GetSens(), 0.05)
    -- A constant-voltage output is set up for its tap, not for the low-Z
    -- rating: the switch on the back of the amplifier changes the gain as well.
    local targetV = (hizV > 0) and hizV or NTx.AmpRatedV(p, ratedZ)
    local gainDb = NTx.AmpDb(targetV / sens)
    if paired and mode == "bridge" then gainDb = gainDb + 6.02 end
    gainDb = gainDb + (amp:GetTrim() or 0)

    local mixer = amp:GetMixer()
    local lin = (not powered or locked or standby) and 0 or busLevel(mixer, isSub and "sub" or "mid")
    local vScaled = NTx.AmpLinToVolts(lin) * NTx.AmpVoltRatio(gainDb)

    -- Damage already taken costs clean output before anything else does.
    local dmgDerate = -12 * math.Clamp(((amp:GetDamage() or 0) - 0.5) * 2, 0, 1)
    local tdevPrev = c.tdev or ambient
    local derate = NTx.AmpDerateDb(p, tdevPrev) + dmgDerate

    local iScale = (paired and mode == "parallel") and 2 or 1
    local vmax, rail = NTx.AmpChannelCeiling(p, mains, z, st.loadFrac or 0, derate, standby, iScale)
    railAny = rail

    -- Constant-voltage outputs regulate to the tap and simply cannot deliver
    -- more, whatever the input asks for.
    local vIdeal = vScaled
    if hizV > 0 then vIdeal = math.min(hizV, vScaled) end

    -- A parallel-mono pair runs two current ceilings into one load; a bridge
    -- pair runs one, at double voltage.
    local minLoad = NTx.AmpMinLoad(p, amp:GetMode()) / (iScale == 2 and 2 or 1)
    local overload = (z < minLoad) and (vIdeal > 0.5)
    local shorted = z < 0.5

    local v = math.min(vIdeal, vmax)
    local clip = vIdeal / math.max(v, 0.01)
    if vIdeal <= 0.001 then clip = 1 end

    -- Protection. Overload trips on current limit, thermal trips on the
    -- device temperature, and a DC offset trips instantly. Injected faults
    -- bypass protection on purpose, so the damage path can be tested without
    -- waiting out a real protection cycle.
    local hardFault = (injected == "short" or injected == "dc" or injected == "overload")
    local protect = false
    if powered and not standby then
      if (overload or shorted) and not hardFault then
        c.protT = (c.protT or 0) + dt
        if c.protT > 1.5 then protect = true end
      else
        c.protT = 0
      end
      if (tdevPrev >= th.tprotect) and not hardFault then
        c.thT = (c.thT or 0) + dt
        if c.thT > 0.5 then protect = true end
      else
        c.thT = math.max((c.thT or 0) - dt * 0.5, 0)
      end
    else
      c.protT, c.thT = 0, 0
    end

    local muted = protect or locked or standby or (not powered)
    local vOut = muted and 0 or v
    local amps = vOut / math.max(z, 0.05)
    local watts = amps * vOut
    local clipLit = (not muted) and clip > 1

    -- Speaker power for this channel.
    NTx.SpkApplyVoltages(res, vOut)
    for _, grp in ipairs(res.groups) do
      for _, sp in ipairs(grp.members) do
        local ss = NTx.SpkState[sp.ent]
        if not ss then
          ss = { rms = 0, temp = NTx.AmpAmbient(sp.ent), group = grp.ohm, rmsW = sp.ent:GetRmsW(), peakW = sp.ent:GetPeakW() }
          NTx.SpkState[sp.ent] = ss
        end
        ss.group = grp.ohm
        -- Slow average: what actually cooks a voice coil is minutes of RMS, not
        -- the peak of a snare hit.
        ss.rms = approach(ss.rms, sp.pW or 0, dt, 4)
        -- Peak power from the crest factor. A crest is an AMPLITUDE ratio, so
        -- the power ratio is the amplitude ratio squared.
        ss.peak = math.min((sp.pW or 0) * NTx.AmpVoltRatio(crest * 2),
          (vOut * vOut) / math.max(grp.ohm, 0.05))
        ss.z = tonumber(sp.ohm) or 8
        ss.rmsW = sp.ent:GetRmsW()
        ss.peakW = sp.ent:GetPeakW()
      end
    end

    -- Heat. One device node per channel on the shared sink.
    local tdev = st.tsink + th.kdev * watts
    c.tdev = tdev
    peakDev = math.max(peakDev, tdev)
    if clipLit then worstClip = math.min(worstClip, clip) end
    anyClip = anyClip or clipLit
    anyProtect = anyProtect or protect

    c.linDb = NTx.AmpDb(lin) + NTx.AMP_FS_DBU
    c.lin = lin
    c.vout = vOut
    c.vmax = vmax
    c.clip = clip
    c.i = amps
    c.w = watts
    c.z = z
    c.protect = protect
    c.muted = muted
    c.sub = isSub
    c.gainred = derate
    c.rail = rail
    c.overload = overload
    c.shorted = shorted
    c.dc = (injected == "dc")
    c.hiZ = hizV > 0 and hizV or nil
    c.spkEnts = spkEnts

    totalOut = totalOut + watts
    -- Dissipation: the profile's efficiency curve at this level, plus the
    -- quiescent draw the manual quotes for an amplifier sitting on the rack.
    local ratedW = math.max(NTx.AmpRatedW(p, z) * pairHalf, 1)
    if hizV > 0 then ratedW = math.max(watts, 1) end
    totalDiss = totalDiss + math.max((watts / math.max(NTx.AmpEta(p, watts / ratedW), 0.03)) - watts, 0)
  end

  -- Quiescent draw: bias, front end and fans, always present, and the reason a
  -- class AB amplifier is hot in an empty room. Quoted per unit, so it does not
  -- scale with the channel count.
  local idleScale = standby and 0.4 or (1 + (p.fan and (NTx.AmpFanFrac(p, st.tsink) * 0.12) or 0))
  totalDiss = totalDiss + (p.idleW or 0) * idleScale

  -- Fan and the heat sink it cools.
  local fanTarget = (not amp:GetFanOn()) and 0 or NTx.AmpFanFrac(p, st.tsink)
  st.fan = approach(st.fan or 0, fanTarget, dt, (p.tau and p.tau.fan) or 5)
  local rth = NTx.AmpRth(p, st.fan, amp:GetThermalBias())
  local tau = (p.tau and p.tau.sink) or 420
  local cool = (st.tsink - ambient) / math.max(rth, 0.001)
  st.tsink = st.tsink + ((totalDiss - cool) * dt / math.max(tau, 1))
  st.tsink = math.Clamp(st.tsink, ambient, 260)
  if peakDev < -900 then peakDev = st.tsink end

  -- Damage. Protection mutes the amplifier, which is exactly why protected
  -- amplifiers usually survive: heat and current stop when the output stops.
  local dmg = 0
  local ratedTot = math.max(NTx.AmpModeRatedW(p, amp:GetMode()) * amp:UsableChannels(), 1)
  -- Well past the device limit is minutes, not seconds.
  dmg = dmg + math.max(0, (peakDev - th.tdestroy) / 40) * 0.01
  -- Sustained clipping at or above rated power is what cooks an output stage,
  -- and it has to persist: the foldback usually steps in first.
  if worstClip < 1 then
    dmg = dmg + math.max(0, worstClip - 1.02) ^ 1.5 * math.Clamp(totalOut / ratedTot, 0, 3) * 0.01
  end
  for _, ch in ipairs(amp:ActiveChannels()) do
    local c = st[ch]
    if c and not c.muted then
      if c.overload and c.z < NTx.AmpMinLoad(p, amp:GetMode()) * 0.7 then dmg = dmg + 0.35 end
      if c.shorted then dmg = dmg + 0.5 end
      if c.dc then dmg = dmg + 0.6 end
    end
  end
  if mainsState == "overvoltage" then dmg = dmg + 0.06 end
  if damageEnabled then
    amp:SetDamage(math.Clamp((amp:GetDamage() or 0) + dmg * (p.robust or 1) * dt, 0, 1))
  end
  if amp:GetDamage() >= 1 and not amp:GetBlown() then
    amp:SetBlown(true)
    print("[NTx] amplifier ent " .. amp:EntIndex() .. " (" .. (amp:GetProfile() or "?")
      .. ") burnt out - replace it.")
    hook.Run("NTx.AmpBurnt", amp)
  end

  -- Mains power and power factor, so a wire readout can show what the rig draws.
  local loadFrac = math.Clamp(totalOut / ratedTot, 0, 1.5)
  st.loadFrac = approach(st.loadFrac or 0, loadFrac, dt, 1)
  local pf = NTx.AmpPf(p, st.loadFrac)
  local acWatts = totalOut + totalDiss
  st.mainsA = math.Clamp(acWatts / math.max(mains * pf, 1), 0, 100)
  st.pf = pf
  st.rail = railAny
  st.totalW = totalDiss
  st.tdevMax = peakDev
  st.fanRpm = NTx.AmpFanRpm(p, st.fan)
  st.mainsV = mains
  st.mainsState = mainsState
  st.standby = standby
  st.locked = locked

  -- Reported fault, most serious first.
  local fault = 0
  if amp:GetBlown() then fault = 8
  elseif not powered then fault = 0
  elseif locked and mainsState == "none" then fault = 3
  elseif locked and mainsState == "overvoltage" then fault = 2
  elseif locked and mainsState == "brownout" then fault = 1
  elseif standby then fault = 9
  elseif anyProtect then fault = 4
  else
    for _, ch in ipairs(amp:ActiveChannels()) do
      local c = st[ch]
      if c then
        if c.dc then fault = 7 break end
        if c.shorted then fault = 6 break end
        if c.overload then fault = 5 break end
      end
    end
  end
  if amp:GetFaultCode() ~= fault then
    amp:SetFaultCode(fault)
    if fault ~= 0 and fault ~= 9 then
      print("[NTx] amplifier ent " .. amp:EntIndex() .. ": " .. NTx.AmpFaultName(fault)
        .. " (" .. math.Round(totalOut, 1) .. " W out, " .. math.Round(st.tsink, 1) .. " C sink)")
    end
  end

  -- Clip latch: the MA series holds its IOC LED, the CDi does not.
  if anyClip then
    amp:SetClipLatch(true)
    st.clipAt = now
  elseif amp:GetClipLatch() and (now - (st.clipAt or 0)) > math.max(amp:GetClipHold(), 0) then
    amp:SetClipLatch(false)
  end

  amp:SetTempSink(math.Round(st.tsink, 1))
  amp:SetTempDev(math.Round(peakDev, 1))
  amp:SetFanRpm(st.fanRpm)
  amp:SetStandby(standby)

  -- Effective audible extras. Mains hum rides the power factor, so a toroidal
  -- supply that is also drawing badly hums worst - and a PFC supply with the
  -- hum switch left on has nothing to hum with.
  st.humDb = -120
  if amp:GetMainsHum() and not amp:GetBlown() and amp:GetPower() then
    st.humDb = math.Clamp((amp:GetHumDb() or -120)
      + (1 - pf) * 46 - math.Clamp(loadFrac, 0, 1) * 8, -120, -20)
  end
  st.fanDb = -120
  if amp:GetFanNoise() and amp:GetFanOn() and amp:GetPower() and not amp:GetBlown() then
    st.fanDb = math.Clamp((amp:GetFanNoiseDb() or -120) + 26 * (st.fan or 0), -120, 0)
  end
end

-- Drivers step here: the slow RMS average, the voice-coil temperature and the
-- damage a hot coil or a clipping excursion does to it. Temperature is part of
-- the simulation and always runs; only the permanent damage is switchable, so a
-- server can keep the meters honest without letting anyone destroy a rig.
local function stepSpeakers(now, dt)
  local damageOn = NTx.SpkDamageEnabled()
  for spk, ss in pairs(NTx.SpkState) do
    if not IsValid(spk) then
      NTx.SpkState[spk] = nil
    else
      if not spk:GetActive() then
        local rms = ss.rms or 0
        local rmsW = math.max(ss.rmsW or spk:GetRmsW() or 100, 1)
        local peakW = math.max(ss.peakW or spk:GetPeakW() or 200, 1)
        local target = NTx.SpkCoilTemp(rms, rmsW, NTx.AmpAmbient(spk))
        -- Heats in well under a minute, cools over several: that asymmetry is
        -- why "it sounded fine for ten minutes" is how drivers die.
        local tau = target > (ss.temp or 22) and 30 or 180
        ss.temp = approach(ss.temp or target, target, dt, tau)
        if damageOn then
          local rate = 0
          -- Peak overload. The printed peak rating is a single-pulse figure, so
          -- the driver is allowed to take twice it before that counts as abuse:
          -- at unity fader a correctly sized amplifier and cabinet produce peaks
          -- right at that line and must survive indefinitely. Push the
          -- amplifier past the cabinet and they separate in minutes.
          rate = rate + math.max(0, (ss.peak or 0) / math.max(peakW * 2, 1) - 1) ^ 1.5 * 0.02
          -- Sustained thermal abuse, which is what really kills coils: about
          -- three minutes at 1.5x the RMS rating, half a minute at 2x.
          rate = rate + math.max(0, (ss.temp - 150) / 20) * 0.008
          local nxt = math.Clamp((spk:GetDamage() or 0) + rate * dt, 0, 1)
          spk:SetDamage(nxt)
          if nxt >= 1 and not spk:GetBlown() then
            spk:SetBlown(true)
            print("[NTx] speaker ent " .. spk:EntIndex() .. " blown: "
              .. math.Round(rms, 1) .. " W rms into a " .. math.Round(rmsW, 1)
              .. " W driver (" .. math.Round(ss.peak or 0, 1) .. " W peak, coil "
              .. math.Round(ss.temp or 0, 1) .. " C).")
            hook.Run("NTx.SpeakerBlown", spk)
          end
        end
        spk:SetCoilTemp(math.Round(ss.temp or 22, 1))
      else
        -- Active cabinet: no coil, no simulation, nothing to report but zero.
        ss.rms, ss.temp = 0, NTx.AmpAmbient(spk)
        spk:SetDamage(0)
        spk:SetBlown(false)
        spk:SetCoilTemp(NTx.AmpAmbient(spk))
      end
      -- Wire readouts, driven from here so the numbers on the wire are the same
      -- numbers the simulation just computed.
      NTx.WireOut(spk, "TempC", ss.temp or 22)
      NTx.WireOut(spk, "Damage", spk:GetDamage() or 0)
      NTx.WireOut(spk, "Blown", spk:GetBlown() and 1 or 0)
      NTx.WireOut(spk, "PRms", ss.rms or 0)
      NTx.WireOut(spk, "PPeak", ss.peak or 0)
      NTx.WireOut(spk, "PRated", spk:GetRmsW() or 0)
      NTx.WireOut(spk, "PPeakRated", spk:GetPeakW() or 0)
      NTx.WireOut(spk, "LoadOhm", spk:GetImpedance() or 8)
      NTx.WireOut(spk, "SeriesOhm", ss.group or spk:GetImpedance() or 8)
      NTx.WireOut(spk, "PrmsLimit", spk:GetRmsW() or 0)
      NTx.WireOut(spk, "PpeakLimit", spk:GetPeakW() or 0)
    end
  end
end

-- ---------------------------------------------------------------- the tick

local nextTick = 0

hook.Add("Think", "NTx.AmpSim", function()
  if CurTime() < nextTick then return end
  local now = CurTime()
  local dt = math.min(now - (nextTick - TICK), 0.5)
  if dt <= 0 then dt = TICK end
  nextTick = now + TICK

  local live = {}
  for _, amp in ipairs(ents.FindByClass("ntx_amplifier")) do
    if IsValid(amp) then
      live[amp] = true
      if NTx.AmpSimEnabled() then
        stepAmp(amp, now, dt)
        local st = NTx.AmpState[amp]
        if st then
          for _, ch in ipairs(amp:ActiveChannels()) do
            local c = st[ch]
            if c then
              local tag = "Ch" .. ch
              NTx.WireOut(amp, tag .. "Amps", c.i or 0)
              NTx.WireOut(amp, tag .. "Volt", c.vout or 0)
              NTx.WireOut(amp, tag .. "Watt", c.w or 0)
              NTx.WireOut(amp, tag .. "Ohm", c.z or 100000)
              NTx.WireOut(amp, tag .. "Clip", (c.clip or 1) > 1 and 1 or 0)
              NTx.WireOut(amp, tag .. "Protect", c.protect and 1 or 0)
            end
          end
          NTx.WireOut(amp, "MainsV", st.mainsV or 0)
          NTx.WireOut(amp, "MainsA", st.mainsA or 0)
          NTx.WireOut(amp, "PF", st.pf or 0)
          NTx.WireOut(amp, "RailV", st.rail or 0)
          NTx.WireOut(amp, "TotalW", st.totalW or 0)
          NTx.WireOut(amp, "TempC", st.tsink or 22)
          NTx.WireOut(amp, "TempDevC", st.tdevMax or 22)
          NTx.WireOut(amp, "FanRpm", st.fanRpm or 0)
          local red = 0
          for _, ch in ipairs(amp:ActiveChannels()) do
            red = math.min(red, (st[ch] and st[ch].gainred) or 0)
          end
          NTx.WireOut(amp, "GainRedDb", red)
          NTx.WireOut(amp, "Damage", amp:GetDamage() or 0)
          NTx.WireOut(amp, "FaultCode", amp:GetFaultCode() or 0)
        end
      end
    end
  end
  for amp in pairs(NTx.AmpState) do
    if not live[amp] then NTx.AmpState[amp] = nil end
  end
  stepSpeakers(now, dt)
  if NTx.BroadcastAmpSync then NTx.BroadcastAmpSync() end
end)

-- Fault injection for testing: the tool and ntx_amp_fault drive this, and
-- "none" clears whatever is latched.
function NTx.AmpInjectFault(amp, name)
  if not IsValid(amp) then return false end
  name = string.lower(tostring(name or ""))
  local allowed = {
    [""] = true, ["none"] = true, ["clear"] = true,
    ["brownout"] = true, ["overvoltage"] = true, ["overload"] = true,
    ["dc"] = true, ["short"] = true, ["thermal"] = true, ["kill"] = true,
  }
  if not allowed[name] then return false end
  if name == "none" or name == "clear" or name == "" then
    amp.Injected = ""
    amp:SetDamage(0)
    amp:SetBlown(false)
    amp:SetFaultCode(0)
    amp:SetClipLatch(false)
    return true
  end
  if name == "brownout" then amp:SetMainsOverride(math.max(math.Round(NTx.AmpNominalMains() * 0.55), 20)) end
  if name == "overvoltage" then amp:SetMainsOverride(math.Round(NTx.AmpNominalMains() * 1.45)) end
  if name == "thermal" then amp:SetFanOn(false) end
  if name == "kill" then amp:SetDamage(1) end
  amp.Injected = name
  return true
end