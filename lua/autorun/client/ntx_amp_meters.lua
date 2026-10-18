-- Client: amplifier readouts, meter state and the front-panel painter.
--
-- The simulation runs on the server and arrives here in NTx.AmpSync; this file
-- turns it into three things the rest of the addon needs:
--   NTx.AmpRecord(ent)     the per-amplifier numbers, for panels and status
--   NTx.AmpChannelMeter()  what the LEDs should show, refined by the page's own
--                          RMS reading when the hosted page supports it
--   NTx.DrawAmpPanel()     the LEDs themselves, painted in 2D inside the Derma
--                          panel; in the world the same lamps render as
--                          models/led.mdl via NTx.DrawAmpWorldLeds below
--
-- LED layouts follow the hardware manuals:
--   Crown MA2400   one multifunction green Signal/IOC LED per channel that
--                  blinks with the signal and holds bright on a clip, plus an
--                  ODEP LED that dims in proportion to drive limiting.
--   Crown CDi 1000 three green LEDs per channel (SIGNAL above -40 dBu at the
--                  input, -20 and -10 dB below the output ceiling) plus red CLIP
--                  and TEMP, and a blue POWER lamp.
if not CLIENT then return end
if NTx_AmpMetersLoaded then return end
NTx_AmpMetersLoaded = true

NTx.Amps = NTx.Amps or {}
-- RMS reported by each WebAudio page, keyed by page key. Only pages speaking
-- the optional level API (v6) ever fill this in.
NTx.PageRms = NTx.PageRms or {}
-- Per channel LED memory: hold timers and blink phase.
NTx.AmpLeds = NTx.AmpLeds or {}

CreateClientConVar("ntx_amp_leds", "1", true, false,
  "Master switch for amplifier panel LEDs (0 = dark panels, state still simulated)")
CreateClientConVar("ntx_amp_debug", "0", true, false,
  "Print the full amplifier simulation table every 2 s")
local cvRmsDb = CreateClientConVar("ntx_amp_rms_db", "-70", true, false,
  "Assumed source level (dBFS) for an input whose page does not report RMS")

-- Console readout. The whole point of a testing branch is being able to see the
-- numbers the simulation is actually using instead of guessing from the LEDs.
concommand.Add("ntx_amp_status", function()
  if not next(NTx.Amps) then print("[NTx] no amplifier state received yet (is one spawned?)") end
  for _, rec in pairs(NTx.Amps) do
    local ent = rec.ent
    local p = ent:Prof()
    print(string.format("[NTx] amp %s ent %s  %s  %s ch%s  mode %s  tap %d V%s",
      ent:GetProfile(), tostring(IsValid(ent) and ent:EntIndex() or "?"),
      p and p.class or "?", ent:GetChannels(),
      (ent:GetMode() == 0 and "dual" or (ent:GetMode() == 1 and "bridge" or "parallel")),
      ent:GetHizVolt(), ent:GetBlown() and "  BURNT" or ""))
    print(string.format("   mains %.0f V  %.2f A  PF %.2f  rail %.0f V  %.0f W heat  sink %.0f C  device %.0f C  fan %.0f rpm  damage %.0f%%  fault %s",
      rec.mainsV, rec.mainsA, rec.pf, rec.railV, rec.totalW, rec.tsink, rec.tdev,
      rec.fanrpm, (ent:GetDamage() or 0) * 100, NTx.AmpFaultName(rec.fault)))
    for i, c in ipairs(rec.ch) do
      print(string.format("   CH%d %s  in %.1f dBu  %s dB below clip  %.1f A  %.0f W into %.1f ohm%s%s",
        i, c.sub and "SUB" or "MID", c.linDb, c.below, c.i, c.w,
        math.min(c.z, 16000), c.clip and "  CLIP" or "", c.protect and "  PROTECT" or ""))
    end
    for _, s in pairs(rec.spk) do
      print(string.format("   cab %d  %.0f W rms / %.0f W peak (limits %.0f / %.0f)  coil %.0f C  %s",
        s.ent:EntIndex(), s.rms, s.peak, s.ent:GetRmsW(), s.ent:GetPeakW(), s.temp,
        s.blown and "BLOWN" or string.format("damage %.0f%%", (s.ent:GetDamage() or 0) * 100)))
    end
  end
end)

local nextDebug = 0
hook.Add("Think", "NTx.AmpDebug", function()
  local cv = GetConVar("ntx_amp_debug")
  if not cv or not cv:GetBool() then return end
  if CurTime() < nextDebug then return end
  nextDebug = CurTime() + 2
  RunConsoleCommand("ntx_amp_status")
end)

-- ------------------------------------------------------------------ decoding

local function ru() return net.ReadUInt(16) end
local function rd(scale) return net.ReadUInt(16) / scale - 130 end
local function rt() return net.ReadUInt(16) / 10 - 40 end

net.Receive("NTx.AmpSync", function()
  local rec = {}
  local n = net.ReadUInt(8)
  for _ = 1, n do
    -- Every value is read before the entity is trusted: a null entity must
    -- still consume its share of the stream or the whole read desyncs.
    local ent = net.ReadEntity()
    local a = {
      tsink = net.ReadFloat(), tdev = net.ReadFloat(), fanrpm = ru(),
      mainsV = net.ReadFloat(), mainsA = ru() / 100, railV = net.ReadFloat(),
      totalW = net.ReadFloat(), pf = ru() / 1000,
      humDb = rd(10), fanDb = rd(10), red = rd(20), damage = ru() / 1000,
      fault = net.ReadUInt(8), standby = net.ReadBool(), blown = net.ReadBool(),
      clipLatch = net.ReadBool(),
      ch = {}, spk = {},
    }
    local nch = net.ReadUInt(4)
    for _ = 1, nch do
      local flags = net.ReadUInt(8)
      a.ch[#a.ch + 1] = {
        sub = bit.band(flags, 1) ~= 0,
        protect = bit.band(flags, 2) ~= 0,
        muted = bit.band(flags, 4) ~= 0,
        clip = bit.band(flags, 8) ~= 0,
        overload = bit.band(flags, 16) ~= 0,
        dc = bit.band(flags, 32) ~= 0,
        shorted = bit.band(flags, 64) ~= 0,
        linDb = rd(20),
        below = rd(20),
        i = ru() / 100, w = ru() / 2, z = ru() / 4,
        gainred = rd(20),
      }
    end
    local nspk = net.ReadUInt(6)
    for _ = 1, nspk do
      local spk = net.ReadEntity()
      -- Separate statements, not a multi-assignment: the evaluation order of
      -- several expressions on one left-hand side is not something to rely on
      -- when every read consumes part of a bit-packed stream.
      local rms = ru() / 2
      local peak = ru() / 2
      local temp = rt()
      local dmg = ru() / 1000
      local group = ru() / 4
      local sflags = net.ReadUInt(8)
      if IsValid(spk) then
        a.spk[spk:EntIndex()] = {
          ent = spk, rms = rms, peak = peak, temp = temp, damage = dmg, group = group,
          blown = bit.band(sflags, 1) ~= 0, active = bit.band(sflags, 2) ~= 0,
        }
      end
    end
    if IsValid(ent) then
      a.ent = ent
      rec[ent:EntIndex()] = a
    end
  end
  -- Anything absent from this message is out of range or gone; drop it rather
  -- than leaving a panel frozen on numbers that stopped being true.
  NTx.Amps = rec
  if NTx.AmpLedThink then NTx.AmpLedThink() end
end)

function NTx.AmpRecord(ent)
  if not IsValid(ent) then return nil end
  return NTx.Amps[ent:EntIndex()]
end

-- ------------------------------------------------------------- meter inputs

-- Linear (0 dBFS = 1) level the mixer is commanding into a channel's bus.
function NTx.AmpCmdLin(rec, ch)
  local c = rec and rec.ch[ch]
  if not c then return 0 end
  return NTx.AmpVoltRatio(c.linDb - NTx.AMP_FS_DBU)
end

-- Per-input gain from its mixer bus, matching the server's busLevel exactly.
local function inputGain(input, mixer, bus)
  if not IsValid(input) or not IsValid(mixer) or input.GetMixer == nil then return nil end
  if input:GetMixer() ~= mixer then return nil end
  if mixer.GetMasterMuted and mixer:GetMasterMuted() then return 0 end
  local busFader
  if bus == "sub" then
    if mixer.GetSubMuted and mixer:GetSubMuted() then return 0 end
    busFader = mixer:GetSubFader()
  else
    if mixer.GetMidMuted and mixer:GetMidMuted() then return 0 end
    busFader = mixer:GetMidFader()
  end
  local g = NTx.FaderToGain(mixer:GetMasterFader()) * NTx.FaderToGain(busFader)
  for _, c in ipairs(mixer.Channels or {}) do
    if c.Input == input then
      if c.Muted then return 0 end
      g = g * NTx.FaderToGain(c.Fader)
      break
    end
  end
  return g * (tonumber(input:GetInputVolume()) or 1)
end

-- True when at least one page for this rig reports a level, which is what makes
-- the meters move with the music instead of sitting still.
local function anyRms(mixer, bus)
  for _, input in ipairs((NTx.Graph and NTx.Graph.inputs) or {}) do
    if IsValid(input.ent) and input.mixer == mixer then
      local r = NTx.PageRms["wai|" .. input.ent:EntIndex()]
      if r and r.at and (CurTime() - r.at) < 1 then return true end
    end
  end
  return false
end

-- What the meters should read for one channel: dBu at the amplifier input and
-- the output level relative to that channel's own clipping ceiling.
--
-- The server's numbers are a commanded-level estimate (identical for everyone,
-- because the simulation has to be deterministic). When the page is reporting a
-- real RMS the estimate gets scaled by how much quieter or louder the actual
-- signal turned out to be, so the LEDs dance with the programme while the rail,
-- clip and thermal state stay authoritative.
function NTx.AmpChannelMeter(ent, ch)
  local rec = NTx.AmpRecord(ent)
  local c = rec and rec.ch[ch]
  if not c then return { linDb = -120, below = -120 } end
  local linDb, below = c.linDb, c.below
  local mixer = ent.GetMixer and ent:GetMixer()
  local bus = c.sub and "sub" or "mid"
  if IsValid(mixer) and anyRms(mixer, bus) then
    local energy = 0
    for _, input in ipairs((NTx.Graph and NTx.Graph.inputs) or {}) do
      local g = inputGain(input.ent, mixer, bus)
      if g then
        local r = NTx.PageRms["wai|" .. input.ent:EntIndex()]
        local rms = (r and r.at and (CurTime() - r.at) < 1) and r.v
          or NTx.AmpVoltRatio(cvRmsDb:GetFloat())
        energy = energy + (g * rms) * (g * rms)
      end
    end
    local lin = math.sqrt(energy)
    local cmd = NTx.AmpCmdLin(rec, ch)
    local scale = math.Clamp(cmd > 0.001 and (lin / cmd) or 0, 0, 4)
    linDb = NTx.AmpDb(lin) + NTx.AMP_FS_DBU
    below = below + NTx.AmpDb(scale)
  end
  return { linDb = linDb, below = below, clip = c.clip, protect = c.protect }
end

-- ---------------------------------------------------------------- LED state

local function ledKey(ent, ch)
  return ent:EntIndex() * 16 + ch
end

-- Ten times a second is plenty for LEDs with a half second of hold, and it
-- keeps the hold running whether or not anybody is looking at the amplifier.
-- Exposed (not just a hook) because a fresh AmpSync can land between ticks and
-- the LEDs should not wait up to 100 ms to show it.
function NTx.AmpLedThink()
  if CurTime() < (NTx.NextAmpLed or 0) then return end
  NTx.NextAmpLed = CurTime() + 0.1
  local now = CurTime()
  for _, rec in pairs(NTx.Amps) do
    local ent = rec.ent
    if not IsValid(ent) then continue end
    local hold = math.max(tonumber(ent:GetClipHold()) or 0.1, 0)
    for ch, c in ipairs(rec.ch) do
      local s = NTx.AmpLeds[ledKey(ent, ch)]
      if not s then s = { on = 0, holdUntil = 0, phase = 0 } NTx.AmpLeds[ledKey(ent, ch)] = s end
      if c.clip then s.holdUntil = now + hold end
      local meter = NTx.AmpChannelMeter(ent, ch)
      -- Crown's IOC lamp flashes in step with the signal it is showing. The
      -- brighter the signal, the longer it stays lit, so a hot channel reads
      -- as steady rather than as a strobe.
      local over = math.Clamp((meter.linDb + 40) / 40, 0, 1)
      s.on = (now < s.holdUntil) and 1 or (over > 0.05 and 1 or 0)
      s.hot = (now < s.holdUntil)
      s.duty = over
      s.meter = meter
    end
  end
end

hook.Add("Think", "NTx.AmpLedThink", NTx.AmpLedThink)

function NTx.AmpLedState(ent, ch)
  return NTx.AmpLeds[ledKey(ent, ch)]
end

-- -------------------------------------------------------------- the panel

-- Virtual panel space. The 3D version scales this down onto the amplifier face;
-- the Derma version draws it at 1:1 in a panel.
NTx.AMP_PANEL_W = 512
NTx.AMP_PANEL_H = 112

local LED_R = 5
local OFF = Color(28, 30, 32)
local GREEN = Color(70, 235, 110)
local AMBER = Color(245, 190, 60)
local RED = Color(240, 70, 60)
local BLUE = Color(70, 150, 245)
local DIM = Color(120, 122, 126)

local function led(x, y, col, alpha, radius)
  radius = radius or LED_R
  surface.SetDrawColor(OFF.r, OFF.g, OFF.b)
  surface.DrawRect(x - radius, y - radius, radius * 2, radius * 2)
  -- alpha is a number (0 = dark), not a Color: every call site passes the
  -- brightness directly. 0 is truthy in Lua, so test it as a number.
  if tonumber(alpha) and alpha > 0 then
    surface.SetDrawColor(col.r, col.g, col.b, alpha)
    surface.DrawRect(x - radius + 1.5, y - radius + 1.5, radius * 2 - 3, radius * 2 - 3)
  end
end

-- The MA-series IOC lamp: green while the signal is there, bright for the
-- documented hold when it clips. A latched signal is what makes a two-second
-- clipping burst read as "that was me" after the fact.
local function iocLamp(s, x, y)
  if not s then led(x, y, GREEN, 0) return end
  if s.hot then
    -- Clipping: bright and held, which is exactly what the IOC lamp is for.
    led(x, y, Color(170, 255, 190), 255, LED_R + 1)
  elseif s.on then
    -- Blink in step with the programme: duty cycle follows the level.
    local duty = math.Clamp((s.duty or 0) * 0.9 + 0.1, 0.1, 1)
    local on = (math.sin(CurTime() * 22) * 0.5 + 0.5) < duty
    led(x, y, GREEN, on and 255 or 40)
  else
    led(x, y, GREEN, 0)
  end
end

-- Draw one amplifier front panel into the current 2D space, origin at (0,0).
-- opts.x / opts.y offset the whole panel (the Derma face draws it inside a
-- rounded box); the 3D version needs no offset because cam.Start3D2D already
-- owns the transform. opts.text adds the per-channel readout the Derma panel
-- shows instead of LEDs alone.
function NTx.DrawAmpPanel(ent, opts)
  opts = opts or {}
  if not IsValid(ent) then return end
  local rec = NTx.AmpRecord(ent)
  local w = NTx.AMP_PANEL_W
  local ox, oy = opts.x or 0, opts.y or 0
  local ledsOn = GetConVar("ntx_amp_leds")
  ledsOn = ledsOn == nil or ledsOn:GetBool()
  local style = math.floor(tonumber(ent:GetMeters()) or 0)
  local blown = ent:GetBlown() == true
  local powered = ent:GetPower() == true and not blown

  -- Power / enable lamp, left edge.
  if ledsOn then
    led(ox + 10, oy + 10, BLUE, powered and 255 or 0)
    -- Standby breathes rather than sitting dark, so a sleeping amplifier is
    -- visibly asleep instead of looking broken.
    if ent:GetStandby() and powered then
      led(ox + 10, oy + 10, BLUE, math.floor(CurTime() * 1.5) % 2 == 0 and 90 or 0)
    end
  end

  local usable = ent:UsableChannels()
  local stripW = math.floor((w - 24) / math.max(usable, 1))
  local chans = ent:ActiveChannels()
  for idx, ch in ipairs(chans) do
    local x0 = ox + 22 + (idx - 1) * stripW
    local y0 = oy + 10
    local s = NTx.AmpLedState(ent, ch)
    local c = rec and rec.ch[idx]
    local meter = (s and s.meter) or { linDb = -120, below = -120, clip = false }
    local label = "CH" .. ch .. (c and c.sub and " SUB" or " MID")

    if style == 1 then
      -- Crown MA: one multifunction lamp plus the ODEP lamp beside it.
      if ledsOn then
        iocLamp(s, x0 + 8, y0)
        local red = math.min(0, (c and c.gainred) or 0)
        local lim = math.Clamp(-red / 8, 0, 1)
        led(x0 + 24, y0, AMBER, lim > 0.02 and 90 + lim * 165 or 0)
      end
      if opts.text then
        draw.SimpleText(label, "DermaDefaultBold", x0, y0 + 12, opts.textCol or Color(230, 230, 230),
          TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        draw.SimpleText(string.format("%s ohm  %.1f A  %.0f W",
          (c and (c.z < 1000)) and string.format("%.1f", c.z) or "open",
          c and c.i or 0, c and c.w or 0),
          "DermaDefault", x0, y0 + 26, opts.dimCol or DIM, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
      end
    else
      -- Crown CDi: three greens, then clip and temp in red.
      local sig = ledsOn and meter.linDb > -40
      local d20 = ledsOn and meter.below > -20
      local d10 = ledsOn and meter.below > -10
      local clipNow = ledsOn and ((c and c.clip) or (s and s.hot))
      local tempNow = ledsOn and (ent:GetTempDev() >= 80 or (c and c.protect))
      if ledsOn then
        led(x0 + 8, y0, GREEN, sig and 255 or 0)
        led(x0 + 22, y0, GREEN, d20 and 255 or 0)
        led(x0 + 36, y0, GREEN, d10 and 255 or 0)
        led(x0 + 54, y0, RED, clipNow and 255 or 0)
        led(x0 + 68, y0, RED, tempNow and 255 or 0)
      end
      if opts.text then
        draw.SimpleText(label, "DermaDefaultBold", x0, y0 + 12, opts.textCol or Color(230, 230, 230),
          TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        draw.SimpleText(string.format("%s ohm  %.1f A / %.0f W",
          (c and (c.z < 1000)) and string.format("%.1f", c.z) or "open",
          c and c.i or 0, c and c.w or 0),
          "DermaDefault", x0, y0 + 26, opts.dimCol or DIM, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
      end
    end
  end

  -- Right edge: the fault lamp, and the readout the Derma panel adds.
  if ledsOn then
    local fault = (rec and rec.fault) or 0
    local faultOn = fault ~= 0 and fault ~= 9
    local blink = faultOn and (math.floor(CurTime() * 4) % 2 == 0) or false
    led(ox + w - 12, oy + 10, (fault == 8) and DIM or RED, faultOn and (blink and 255 or 60) or 0)
  end
  if opts.text then
    local lines = {
      string.format("sink %.0f C   device %.0f C   fan %.0f rpm",
        ent:GetTempSink(), ent:GetTempDev(), rec and rec.fanrpm or 0),
      string.format("mains %.0f V  %.1f A  PF %.2f  rail %.0f V  %.0f W heat",
        rec and rec.mainsV or 0, rec and rec.mainsA or 0, rec and rec.pf or 0,
        rec and rec.railV or 0, rec and rec.totalW or 0),
    }
    if (ent:GetDamage() or 0) > 0.01 then
      lines[#lines + 1] = string.format("DAMAGE %.0f%%", ent:GetDamage() * 100)
    end
    for i, text in ipairs(lines) do
      draw.SimpleText(text, "DermaDefault", ox, oy + 48 + (i - 1) * 14,
        (i == #lines) and AMBER or (opts.dimCol or DIM), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end
  end
end

-- ----------------------------------------------------------- in-world LEDs

-- The Derma panel paints its lamps with surface.DrawRect in the 512x112
-- virtual space; in the world each lamp position becomes a real models/led.mdl.
-- Same layout, same state, same conditions - only the ink differs.
--
-- render.Model() cannot scale its staging entity, so the model is a cached
-- ClientsideModel driven by hand (SetPos/SetAngles/DrawModel); the material is
-- swapped per lamp with render.MaterialOverride so the LED colour never
-- depends on what the model's own textures happen to look like.
local LED_NATIVE = 1.37      -- models/led.mdl bounding size, in model units
local LED_PX = 12            -- target lamp diameter, in virtual panel pixels
local LED_LIFT = 0.5         -- how far the domes sit off the chassis face
-- PAC3 layouts carry a position but no diameter, so lamps there are drawn at
-- a fixed fraction of the led.mdl native size. Close enough to the authored
-- dome on a rack chassis, and it cannot drift with the chassis dimensions the
-- way the panel layout does.
local PAC3_LED_SCALE = 0.05

local ledModels = {}         -- amp entity -> its cached ClientsideModel
local ledMats = {}           -- quantised colour -> material

-- col is the lit colour and may be nil for a dark lamp, in which case `lens`
-- (the tint PAC3 recorded) supplies the plastic colour. A dark lamp is never
-- pure black: a lens keeps its own colour when the emitter is off.
local function ledMaterial(col, alpha, lens)
  alpha = math.Clamp(tonumber(alpha) or 0, 0, 255)
  local r, g, b
  if alpha == 0 then
    local base = lens or OFF
    -- Off lamps read as dark tinted plastic, not as their lit colour.
    r, g, b = base.r * 0.28, base.g * 0.28, base.b * 0.28
  else
    local f = alpha / 255
    r, g, b = col.r * f, col.g * f, col.b * f
  end
  -- Quantise so blink and dim levels share cached materials.
  r = math.floor(r / 32) * 32
  g = math.floor(g / 32) * 32
  b = math.floor(b / 32) * 32
  local key = r .. "_" .. g .. "_" .. b
  local m = ledMats[key]
  if m == nil then
    m = CreateMaterial("ntx_led_" .. key, "UnlitGeneric", {
      ["$basetexture"] = "vgui/white",
      ["$nocull"] = "1",
      ["$color2"] = string.format("[%f %f %f]", r / 255, g / 255, b / 255),
    })
    ledMats[key] = m
  end
  return m
end

-- Lamp positions on the virtual panel, straight from the same conditions
-- DrawAmpPanel uses. x/y are panel pixels; alpha 0 means the lens is dark.
local function ledPoints(ent, rec)
  local pts = {}
  local W = NTx.AMP_PANEL_W
  local style = math.floor(tonumber(ent:GetMeters()) or 0)
  local blown = ent:GetBlown() == true
  local powered = ent:GetPower() == true and not blown

  -- Power lamp, left edge; standby breathes instead of going dark.
  local power = powered and 255 or 0
  if powered and ent:GetStandby() then
    power = math.floor(CurTime() * 1.5) % 2 == 0 and 90 or 0
  end
  pts[#pts + 1] = { x = 10, y = 10, col = BLUE, alpha = power }

  local usable = ent:UsableChannels()
  local stripW = math.floor((W - 24) / math.max(usable, 1))
  local chans = ent:ActiveChannels()
  for idx, ch in ipairs(chans) do
    local x0 = 22 + (idx - 1) * stripW
    local y0 = 10
    local s = NTx.AmpLedState(ent, ch)
    local c = rec and rec.ch[idx]
    local meter = (s and s.meter) or { linDb = -120, below = -120 }
    if style == 1 then
      -- Crown MA: the multifunction IOC lamp plus the ODEP lamp beside it.
      if s and s.hot then
        pts[#pts + 1] = { x = x0 + 8, y = y0, col = Color(170, 255, 190), alpha = 255 }
      elseif s and s.on then
        -- Blink in step with the programme, exactly like iocLamp().
        local duty = math.Clamp((s.duty or 0) * 0.9 + 0.1, 0.1, 1)
        local on = (math.sin(CurTime() * 22) * 0.5 + 0.5) < duty
        pts[#pts + 1] = { x = x0 + 8, y = y0, col = GREEN, alpha = on and 255 or 40 }
      else
        pts[#pts + 1] = { x = x0 + 8, y = y0, col = GREEN, alpha = 0 }
      end
      local red = math.min(0, (c and c.gainred) or 0)
      local lim = math.Clamp(-red / 8, 0, 1)
      pts[#pts + 1] = { x = x0 + 24, y = y0, col = AMBER,
        alpha = lim > 0.02 and (90 + lim * 165) or 0 }
    else
      -- Crown CDi: three greens, then clip and temp in red.
      pts[#pts + 1] = { x = x0 + 8, y = y0, col = GREEN,
        alpha = meter.linDb > -40 and 255 or 0 }
      pts[#pts + 1] = { x = x0 + 22, y = y0, col = GREEN,
        alpha = meter.below > -20 and 255 or 0 }
      pts[#pts + 1] = { x = x0 + 36, y = y0, col = GREEN,
        alpha = meter.below > -10 and 255 or 0 }
      pts[#pts + 1] = { x = x0 + 54, y = y0, col = RED,
        alpha = ((c and c.clip) or (s and s.hot)) and 255 or 0 }
      pts[#pts + 1] = { x = x0 + 68, y = y0, col = RED,
        alpha = (ent:GetTempDev() >= 80 or (c and c.protect)) and 255 or 0 }
    end
  end

  -- Fault lamp, right edge; blinks like the panel's.
  local fault = (rec and rec.fault) or 0
  local faultOn = fault ~= 0 and fault ~= 9
  local blink = faultOn and (math.floor(CurTime() * 4) % 2 == 0) or false
  pts[#pts + 1] = { x = W - 12, y = 10, col = (fault == 8) and DIM or RED,
    alpha = faultOn and (blink and 255 or 60) or 0 }
  return pts
end

-- Put the lamp models on the amplifier's leading face. Model bounds are in
-- model space (x depth, y width, z height), so the face plane is at max x and
-- the strip is centred on the bounding box, then scaled so the whole virtual
-- panel fits the real face.
--
-- Two layout sources. A baked PAC3 layout wins when present, because it places
-- lamps in model space and so works for any chassis. Without one, the
-- virtual-panel layout above is used, which keeps every amplifier that has never
-- been authored in PAC3 looking exactly as it did.
local function pac3LampsFor(ent)
  if not NTx.Pac3Lamps then return nil end
  local ok, lamps = pcall(NTx.Pac3Lamps, ent)
  if ok and lamps and #lamps > 0 then return lamps end
  return nil
end

local function drawPac3Lamps(ent, rec, lamps)
  local model = ledModels[ent]
  if not IsValid(model) then
    model = ClientsideModel("models/led.mdl", RENDERGROUP_OTHER)
    if not IsValid(model) then return end
    model:SetNoDraw(true)
    ledModels[ent] = model
  end
  for _, lamp in ipairs(lamps) do
    local alpha, col = NTx.Pac3LampState(ent, lamp, rec)
    -- Unlit lamps keep the lens tint PAC3 gave them; lit lamps take the
    -- semantic colour so the world matches the Derma panel.
    local base = col or lamp.lens or OFF
    -- A PAC3 position is model space, so the chassis transform does the work
    -- the virtual-panel arithmetic used to do.
    model:SetPos(ent:LocalToWorld(lamp.pos))
    model:SetAngles(ent:GetAngles() + lamp.ang)
    -- Scale from the model itself rather than a panel constant: PAC3 does not
    -- record a diameter, so match the native led.mdl at a fixed size.
    model:SetModelScale(PAC3_LED_SCALE, 0)
    render.MaterialOverride(ledMaterial(base, alpha))
    model:DrawModel()
  end
  render.MaterialOverride()
end

function NTx.DrawAmpWorldLeds(ent, rec)
  local lamps = pac3LampsFor(ent)
  if lamps then
    return drawPac3Lamps(ent, rec, lamps)
  end

  local mn, mx = ent:GetModelBounds()
  if not mn or not mx then return end
  local size = mx - mn
  if size.y < 1 or size.z < 1 then return end
  local scale = math.min((size.y * 0.86) / NTx.AMP_PANEL_W,
    (size.z * 0.8) / NTx.AMP_PANEL_H)
  if scale <= 0 then return end

  local ang = ent:GetAngles()
  local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()
  local cy = (mn.y + mx.y) * 0.5
  local cz = (mn.z + mx.z) * 0.5
  local face = ent:GetPos() + fwd * mx.x + right * cy + up * cz
  local topLeft = face
    - right * (NTx.AMP_PANEL_W * scale * 0.5)
    + up * (NTx.AMP_PANEL_H * scale * 0.5)

  local model = ledModels[ent]
  if not IsValid(model) then
    model = ClientsideModel("models/led.mdl", RENDERGROUP_OTHER)
    if not IsValid(model) then return end
    model:SetNoDraw(true)
    model:SetModelScale((LED_PX * scale) / LED_NATIVE, 0)
    ledModels[ent] = model
  end

  for _, p in ipairs(ledPoints(ent, rec)) do
    local pos = topLeft + right * (p.x * scale) - up * (p.y * scale)
      + fwd * LED_LIFT
    model:SetPos(pos)
    model:SetAngles(ang)
    render.MaterialOverride(ledMaterial(p.col, p.alpha))
    model:DrawModel()
  end
  render.MaterialOverride()
end

-- The front panels are part of the hardware: every amplifier shows its LEDs to
-- every player, all the time. The master LED switch and the obvious visibility
-- culls still apply.
hook.Add("PostDrawOpaqueRenderables", "NTx.AmpWorldLeds", function()
  local leds = GetConVar("ntx_amp_leds")
  if leds and not leds:GetBool() then return end
  local eye = EyePos()
  for _, rec in pairs(NTx.Amps) do
    local ent = rec.ent
    if IsValid(ent) and not ent:IsDormant()
      and eye:DistToSqr(ent:GetPos()) < 4000 * 4000 then
      NTx.DrawAmpWorldLeds(ent, rec)
    end
  end
end)

-- Lamp models and LED memory follow their amplifier out of the world.
hook.Add("EntityRemoved", "NTx.AmpLedCleanup", function(ent)
  local model = ledModels[ent]
  if model ~= nil then
    ledModels[ent] = nil
    if IsValid(model) then model:Remove() end
  end
  local base = ent:EntIndex() * 16
  for key in pairs(NTx.AmpLeds) do
    if key > base and key <= base + 15 then NTx.AmpLeds[key] = nil end
  end
end)

-- -------------------------------------------------------------- audio taps

-- Per-channel audio data for the tap payload: how much the amplifier is holding
-- the signal back, and how hard it is clipping (which is what the page turns
-- into real distortion).
function NTx.AmpTapData(ent, ch)
  local rec = NTx.AmpRecord(ent)
  if not rec then return { g = 1, cl = 1 } end
  local c = rec.ch[ch]
  if not c then return { g = 1, cl = 1 } end
  local gain = 1
  if c.muted or rec.blown then gain = 0 end
  -- A clipped channel is not quieter, it is flat-topped: the page's shaper does
  -- that, and the drive it needs is the ratio the output is being held back by.
  -- Only foldback and muting cut the level here.
  if gain > 0 and c.protect then gain = gain * 0.05 end
  local cl = 1
  if c.clip and not c.muted and c.below > -60 then
    cl = math.Clamp(NTx.AmpVoltRatio(-c.below), 1, 20)
  end
  return { g = gain, cl = cl, below = c.below, fault = rec.fault }
end

-- Mains hum and fan noise belong to the amplifier, not the cabinet, so exactly
-- one page per amplifier owns them; otherwise a four-input rig would hum four
-- times over. Mains frequency follows the external grid's setting so a 60 Hz
-- venue hums at 60 Hz.
function NTx.AmpExtras(ent, isHost)
  local rec = NTx.AmpRecord(ent)
  if not rec or not isHost then return nil end
  if rec.blown or not ent:GetPower() then return nil end
  local cv = GetConVar("ntx_mains_hz")
  local hz = math.floor((cv and cv:GetFloat() or 50) + 0.5)
  return {
    hum = { hz = (hz > 0 and hz or 50), db = rec.humDb or -120 },
    fan = { db = rec.fanDb or -120, rpm = rec.fanrpm or 0 },
  }
end