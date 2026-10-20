-- Client: WebAudio backend. ONE hidden DHTML page per input streams the
-- URL exactly once; every speaker gets its own filtered tap inside the
-- page (Biquad HP/LP cascade + gain + delay/polarity + PannerNode), so all
-- taps are phase-coherent by construction. Lua owns topology and gains and
-- pushes state at 10 Hz; the page owns decoding, filtering and panning.
--
-- Limits, stated plainly: page audio bypasses the GMod master volume, and
-- a stream without CORS headers reads as silence to the page graph. Tainted
-- or load-broken inputs stay silent on a capable client: the BASS fallback is
-- never mixed in underneath WebAudio (NTx.FallbackAllowed in ntx_dsp.lua).
if not CLIENT then return end
if NTx_WebAudioLoaded then return end
NTx_WebAudioLoaded = true

NTx.WebAudio = NTx.WebAudio or { Pages = {} }
-- The amplifier SFX page: a second instance of the same page, in its own mode
-- and therefore its own AudioContext. It is kept apart from the programme's
-- pages so a fan cannot colour the music, and so the two are summed by the
-- device rather than mixed in one graph.
NTx.AmpSfx = NTx.AmpSfx or { panel = nil, url = nil, lastAt = 0 }
NTx.PAGE_API_VERSION = 5
NTx.PageHello = NTx.PageHello or {}
NTx.PagePong = NTx.PagePong or {}
NTx.PagePing = NTx.PagePing or {}
NTx.PagePongDead = NTx.PagePongDead or {}
NTx.Tainted = NTx.Tainted or {}
NTx.TaintedUrl = NTx.TaintedUrl or {}
NTx.TaintedNoticed = NTx.TaintedNoticed or {}
-- Load failures are transient-worthy (server restarts), unlike CORS policy:
-- broken inputs are retried periodically and stay silent until they recover.
NTx.PageBroken = NTx.PageBroken or {}
NTx.PageErrors = NTx.PageErrors or {}
NTx.BrokenRetryAt = NTx.BrokenRetryAt or {}
NTx.WebAudioRunning = NTx.WebAudioRunning or false

-- Mark a page's input as load-broken: this is what hands the input to the
-- BASS bus. Every page-level failure funnels through here so the rig is
-- never silently mute.
local function markPageBroken(pkey, why)
  local P = NTx.WebAudio and NTx.WebAudio.Pages[pkey]
  local ent = P and P.inputEnt
  if not (ent and IsValid(ent)) then return end
  if not NTx.PageBroken[ent] then
    NTx.PageBroken[ent] = true
    NTx.BrokenRetryAt[ent] = CurTime() + 30
  end
  NTx.PageErrors[ent] = math.max(tonumber(NTx.PageErrors[ent]) or 0, 3)
  if not NTx.TaintedNoticed[ent] then
    NTx.TaintedNoticed[ent] = true
    print("[NTx] WebAudio page unusable: " .. why
      .. " Input ent " .. tostring(ent:EntIndex())
      .. " stays silent on this client (WebAudio-capable clients do not get BASS cover); page retries in 30 s.")
  end
  -- Tear the dead page down instead of leaving it around: a failed remote
  -- document may be rendering an error page (harmless while hidden, but it
  -- keeps a dead CEF view and a queued document alive for nothing).
  if P and IsValid(P.panel) then P.panel:Remove() end
  NTx.WebAudio.Pages[pkey] = nil
  NTx.PageHello[pkey] = nil
  NTx.PagePong[pkey] = nil
  NTx.PagePing[pkey] = nil
  NTx.PagePongDead[pkey] = nil
  NTx.PageRms[pkey] = nil
end

local cvMaxPages = CreateClientConVar("ntx_max_pages", "4", true, false,
  "Max simultaneous WebAudio mixer pages (one per input)")
local cvCardioidMs = CreateClientConVar("ntx_cardioid_ms", "2.9", true, false,
  "Rear-box delay for cardioid SUB setups, milliseconds (approx 1 m spacing)")
local cvEndfireM = CreateClientConVar("ntx_endfire_m", "1.0", true, false,
  "Cabinet spacing for endfire SUB setups, meters")
-- Safety limiter only: -0.5 dBFS threshold at 20:1 stays silent in normal
-- use and catches true overs. The old -9 dB / 14:1 setting was audible
-- compression (pumping), which is why it is gone.
local cvLimiter = CreateClientConVar("ntx_limiter", "1", true, false,
  "Safety limiter on the WebAudio master bus (1 = on, 0 = off)")
local cvLimiterDb = CreateClientConVar("ntx_limiter_db", "-0.5", true, false,
  "Limiter threshold in dBFS (only bites above this)")
-- Motion smoothing: positions are interpolated in-page every frame, so the
-- push rate is just a target refresh, not the smoothness.
NTx.TapSide = NTx.TapSide or {}

local cvPushHz = CreateClientConVar("ntx_push_hz", "15", true, false,
  "State push rate to WebAudio pages (Hz); in-page interpolation smooths motion regardless")
local cvMotionSmooth = CreateClientConVar("ntx_motion_smooth", "60", true, false,
  "Motion smoothing time constant in ms (higher = smoother, slightly laggier)")
local cvMotionRate = CreateClientConVar("ntx_motion_max_rate", "0", true, false,
  "Max motion speed in units/s for speakers/listener (0 = uncapped, so teleports snap)")

-- Resolved per panel (not once at load) so ntx_page_base edits apply to
-- newly opened pages without a client restart.
local function mixerPageURL()
  if NTx.PageURL then return NTx.PageURL("webaudio.html") end
  return "https://xenonetwork.moe/dsp/webaudio.html"
end

-- Mirror of the mixer gain model, per bus (the split is real here: each tap is
-- filtered, so MID and SUB busses genuinely diverge). Takes the bus the tap
-- actually plays, resolved from the amplifier channel rather than the cabinet.
-- Faders are logarithmic (NTx.FaderToGain: -60 dB .. +6 dB, unity at 1).
local function waGain(mrec, inputEnt, playSub)
  if not mrec or mrec.mm then return 0 end
  local bus = playSub and "sub" or "mid"
  if bus == "mid" and mrec.midm then return 0 end
  if bus == "sub" and mrec.subm then return 0 end
  local gain = NTx.FaderToGain(mrec.master) * NTx.FaderToGain(bus == "mid" and mrec.mid or mrec.sub)
  for _, ch in ipairs(mrec.channels) do
    if ch.input == inputEnt then
      if ch.muted then return 0 end
      return gain * NTx.FaderToGain(ch.fader)
    end
  end
  return gain
end

local function mixerRecFor(mixerEnt)
  for _, m in ipairs(NTx.Graph.mixers) do
    if m.ent == mixerEnt then return m end
  end
  return nil
end

-- Per-speaker taps for one input: exact positions, cardioid/endfire
-- delay+polarity for reversed SUB boxes (approximation: fixed rear delay,
-- progressive endfire steps along the array facing), self-cardioid cones.
-- Returns the taps plus their estimated audible energy at the listener.
-- The SFX page is the same file with a flag on the URL, so there is no second
-- asset to host: the mode is read by the page from its own address.
local function sfxPageURL()
  local base = mixerPageURL()
  if base:find("%?") then return base .. "&sfx=1" end
  return base .. "?sfx=1"
end

-- Open the SFX page if it is not open yet, and hand it the state of every
-- amplifier. It is a separate page and therefore a separate AudioContext, so
-- the fan is summed by the device with the programme rather than mixed into
-- it, and it is buried under the programme rather than sitting on top.
local function pushAmpSfx(listener)
  local A = NTx.AmpSfx
  if not A or not IsValid(A.panel) then return end
  -- Not until the page says hello: calling a function that does not exist yet
  -- throws inside the page and only shows up in the browser console.
  if not A.ready then return end
  if CurTime() - (A.lastAt or 0) < 0.05 then return end
  A.lastAt = CurTime()

  local amps = {}
  for _, amp in ipairs(ents.FindByClass("ntx_amplifier")) do
    if IsValid(amp) then
      local rec = NTx.AmpRecord and NTx.AmpRecord(amp) or nil
      local db = -120
      if rec and rec.fanDb then db = rec.fanDb end
      if not amp:RunState() then db = -120 end
      local pos = amp:GetPos()
      amps[#amps + 1] = {
        id = amp:EntIndex(),
        x = pos.x, y = pos.y, z = pos.z,
        db = db, rpm = rec and rec.fanrpm or 0,
      }
    end
  end

  -- How loud the programme is, so the SFX can be buried under it.
  --
  -- The measured level is what the SOURCE is playing, before the mixer. A PA
  -- turned down still measured loud, which buried the fan while the room was
  -- silent. So it is scaled by what the mixer actually sends out of that bus -
  -- the same master, bus and channel faders the audio path uses - which makes
  -- the fan come back when the desk is pulled down.
  local prog = 0
  for _, input in ipairs((NTx.Graph and NTx.Graph.inputs) or {}) do
    if IsValid(input.ent) then
      local r = NTx.PageRms["wai|" .. input.ent:EntIndex()]
      if r and r.b then
        local mrec = mixerRecFor(input.mixer)
        for i = 1, #r.b do
          local lvl = tonumber(r.b[i]) or 0
          if mrec then
            local isSub = NTx.BusIsSub(i - 1)
            local g = NTx.FaderToGain(mrec.master) * NTx.FaderToGain(isSub and mrec.sub or mrec.mid)
            if mrec.mm or (isSub and mrec.subm) or (not isSub and mrec.midm) then g = 0 end
            for _, ch in ipairs(mrec.channels) do
              if ch.input == input.ent then
                g = g * NTx.FaderToGain(ch.fader)
                if ch.muted then g = 0 end
                break
              end
            end
            lvl = lvl * g * (tonumber(input.vol) or 1)
          end
          if lvl > prog then prog = lvl end
        end
      end
    end
  end

  local payload = {
    amps = amps,
    prog = prog,
    listener = listener,
  }
  pcall(A.panel.Call, A.panel, "ntxSfx(" .. util.TableToJSON(payload) .. ")")
end

-- Open the SFX page when there is an amplifier to make a noise for. The panel
-- is hidden and off-screen, like the programme pages: a failing remote
-- document would otherwise paint its error page over the screen.
local function ensureAmpSfxPage()
  local A = NTx.AmpSfx
  if IsValid(A.panel) then return A.panel end
  if not ents.FindByClass("ntx_amplifier")[1] then return nil end
  local panel = vgui.Create("DHTML")
  panel:SetSize(1, 1)
  panel:SetPos(-64, -64)
  panel:SetAlpha(0)
  panel:SetMouseInputEnabled(false)
  panel:SetKeyboardInputEnabled(false)
  panel.Paint = function() end
  panel.PaintOver = function() end
  local dbg = GetConVar("ntx_cef_visible")
  if dbg and dbg:GetBool() then
    panel:SetAlpha(255)
    panel:SetSize(480, 360)
    panel:SetPos(ScrW() - 500, ScrH() - 400)
    panel:SetMouseInputEnabled(true)
  end
  A.panel = panel
  A.url = sfxPageURL()
  A.ready = false
  -- The bridge, so the page can say it has loaded. Calling ntxSfx before the
  -- document is there throws a ReferenceError in the page, and the message
  -- ends up in the browser console where it explains nothing.
  panel.OnFinishLoadingDocument = function()
    local ok = pcall(panel.AddFunction, panel, "ntx", "status",
      function(json)
        local ok2, data = pcall(util.JSONToTable, json)
        if ok2 and type(data) == "table" and data.t == "hello" then A.ready = true end
      end)
    if not ok then
      print("[NTx] amplifier SFX page bridge registration failed")
    end
  end
  panel:OpenURL(A.url)
  return panel
end

local function buildTaps(input, mrec, listenerPos)
  listenerPos = listenerPos or Vector(0, 0, 0)
  local groups = {}
  for _, s in ipairs(NTx.Graph.speakers) do
    if IsValid(s.ent) and s.mixer == input.mixer then
      local key = s.array .. "|" .. s.stype
      local g = groups[key]
      if not g then
        g = { stype = s.stype, members = {} }
        groups[key] = g
      end
      g.members[#g.members + 1] = s
    end
  end
  local taps = {}
  local energy = 0
  local cardioidMs = math.Clamp(cvCardioidMs:GetFloat() or 2.9, 0, 50)
  local stepMs = math.Clamp((cvEndfireM:GetFloat() or 1.0) * 1000 / 343, 0, 50)
  for _, g in pairs(groups) do
    local subs, revs = 0, 0
    for _, s in ipairs(g.members) do
      if s.stype == "SUB" then
        subs = subs + 1
        if s.reversed then revs = revs + 1 end
      end
    end
    local mode = "omni"
    if g.stype == "SUB" and revs > 0 then mode = (subs >= 3) and "endfire" or "cardioid" end
    local order = {}
    if mode == "endfire" then
      local fwd = g.members[1].ang:Forward()
      for _, s in ipairs(g.members) do order[#order + 1] = s end
      table.sort(order, function(a, b)
        return a.pos:Dot(fwd) > b.pos:Dot(fwd)
      end)
    end
    local rank = {}
    for i, s in ipairs(order) do rank[s] = i - 1 end
    for _, s in ipairs(g.members) do
      -- Amplifier in the chain, resolved FIRST because it decides which bus
      -- this cabinet plays.
      --
      -- The bus comes from the amplifier channel, not the cabinet's type. The
      -- wiring is the truth: a cabinet on a channel the mixer published as
      -- SubL plays the SUB bus even if its own type says MID. Choosing by
      -- cabinet type let the audio path and the simulation disagree, which is
      -- the thing that made a channel's type seem to do nothing.
      local ampGain, ampClip = 1, 1
      local playSub = s.stype == "SUB"
      -- nil means "no bus": the tap takes the full source, as it always did.
      local busId = nil
      local ampEnt = IsValid(s.ent) and s.ent.GetAmp and s.ent:GetAmp() or nil
      if IsValid(ampEnt) and ampEnt:GetClass() == "ntx_amplifier" and not s.ent:GetActive() then
        local ch = NTx.AmpSpeakerChannel(ampEnt, s.ent)
        local data = ch > 0 and NTx.AmpTapData(ampEnt, ch) or nil
        if data then
          ampGain = data.g
          ampClip = data.cl
        end
        -- Only when a wire feeds the channel. An unwired channel packs as
        -- MidL, so asking it for a bus would quietly force every unamplified
        -- or unwired cabinet to play the MID bus.
        if ch > 0 and ampEnt.ChannelIsFed and ampEnt:ChannelIsFed(ch) then
          busId = ampEnt:ChannelBusId(ch)
          playSub = NTx.BusIsSub(busId)
        end
        -- Recorded so ntx_audio_status can say WHICH of the four conditions
        -- above failed. A cabinet on a channel with no bus takes the whole
        -- source, which is exactly the "full stereo from one cabinet" symptom,
        -- and the tap payload alone cannot tell you whether side was never
        -- computed or merely dropped downstream.
        NTx.TapSide[(s.ent:EntIndex())] = string.format(
          "ch=%d fed=%s bus=%s side=%s", ch,
          tostring(ampEnt.ChannelIsFed and ampEnt:ChannelIsFed(ch)),
          tostring(busId), tostring(busId ~= nil and NTx.BusSideOf(busId) or nil))
      else
        NTx.TapSide[(s.ent:EntIndex())] = string.format(
          "no amp ch=0 bus=nil side=nil%s", s.ent:GetActive() and " (active)" or "")
      end
      -- Everything downstream (bus fader, tap kind, directivity branch) reads
      -- playSub rather than the cabinet's type.
      local gain = waGain(mrec, input.ent, playSub) * (input.vol or 1)
      -- The tool's max distance is a cutoff, not a suggestion: silent
      -- beyond it, with a linear fade over the last 15% so crossing the
      -- boundary does not click. (The PannerNode's own maxDistance only
      -- softens the inverse curve, it never reaches silence.)
      local maxd = math.Clamp(input.maxd or 1200, 100, 10000)
      local rangeFade = math.Clamp((maxd - (listenerPos - s.pos):Length()) / math.max(maxd * 0.15, 1), 0, 1)
      -- A burnt driver is an open circuit: nothing comes out of it.
      if s.ent:GetBlown() then ampGain = 0 end
      if gain > 0.001 and rangeFade > 0 and ampGain > 0 then
        gain = gain * rangeFade
        local delayMs, inv = 0, false
        if mode == "cardioid" and s.reversed then delayMs, inv = cardioidMs, true end
        if mode == "endfire" then delayMs = (rank[s] or 0) * stepMs end
        local delta = listenerPos - s.pos
        local dist = delta:Length()
        local coneGain = 1
        local occlp = 20000 -- bypass unless a cabinet loses line of sight
        -- Directivity is computed here rather than in the PannerNode, so
        -- horizontal and vertical FOV can differ per cabinet (PannerNode
        -- only has one circular cone). The panner keeps position, HRTF and
        -- distance; its cone is disabled below.
        if not playSub then
          local hFov, vFov = (s.hFov ~= 0) and s.hFov or 152, (s.vFov ~= 0) and s.vFov or 57
          local outerVol = NTx.DIR.MID.OuterVol
          -- Self-cardioid overrides the throw: front hemisphere full, rear
          -- floored, with no partner box or delay path.
          if s.selfcard then hFov, vFov, outerVol = 90, 180, NTx.CARDIOID_MIN_GAIN end
          coneGain = NTx.MidConeGain(s.pos, s.ang, delta, hFov, vFov, outerVol)
          -- No line of sight (wall, pillar, other room): lose level AND highs.
          local occGain, occLp = NTx.SpeakerOcclusion(s.ent, s.pos, listenerPos)
          gain = gain * occGain
          occlp = occLp
        elseif s.selfcard then
          coneGain = NTx.MidConeGain(s.pos, s.ang, delta, 90, 180, NTx.CARDIOID_MIN_GAIN)
        end
        gain = gain * coneGain * ampGain
        -- Throttle lives in the NTx table, not a file-local: after a
        -- lua_refresh or a partial file sync a file-local declared further
        -- down can be nil while the Think hook already references it, which
        -- crashed buildTaps at this exact comparison.
        if NTx.CvConeDebug and NTx.CvConeDebug:GetBool() and CurTime() >= (NTx.NextWaConeDbg or 0) then
          NTx.NextWaConeDbg = CurTime() + 2
          print(string.format("[NTx cone/WA] %s%s ent=%s dist=%.0f/%.0f cone=%.3f range=%.2f amp=%.2f cl=%.2f g=%.4f",
            playSub and "SUB" or "MID", s.selfcard and "(SC)" or "",
            tostring(IsValid(s.ent) and s.ent:EntIndex() or "?"),
            dist, maxd, coneGain, rangeFade, ampGain, ampClip, gain))
        end
        -- Estimated audible energy at the listener, mirroring the
        -- PannerNode's distance attenuation and the directivity we just
        -- applied. Normalisation uses this, so distant or off-axis taps
        -- contribute almost nothing instead of dragging the rig down.
        local audible = gain * NTx.DistanceGain(dist)
        energy = energy + audible * audible
        taps[#taps + 1] = {
          id = tostring(s.ent:EntIndex()), kind = playSub and "SUB" or "MID",
          -- Which part of the programme this tap plays: 0 left, 1 right, 2 the
          -- sum of both. Absent for a cabinet with no fed channel, and the page
          -- then feeds it the whole source unchanged.
          side = busId ~= nil and NTx.BusSideOf(busId) or nil,
          g = math.Round(gain, 4), d = math.Round(delayMs, 3), inv = inv,
          px = math.Round(s.pos.x, 2), py = math.Round(s.pos.y, 2), pz = math.Round(s.pos.z, 2),
          -- Cone disabled on the panner (directivity already in g); HRTF and
          -- distance attenuation still apply.
          ci = 360, co = 360, cov = 1,
          maxd = maxd,
          -- 20000 = no occlusion lowpass (audible path untouched); lower =
          -- cabinet without line of sight, highs rolled off by the page.
          occlp = math.Round(occlp, 1),
          -- Amplifier clip ratio: 1 = clean, >1 = held back by that much, which
          -- the page turns into drive + a waveshaper. Optional field: a page
          -- that predates it ignores it and the tap is just attenuated.
          cl = math.Round(ampClip, 3),
        }
      end
    end
  end
  return taps, energy
end

local function ensurePage(pkey, url)
  local P = NTx.WebAudio.Pages[pkey]
  if IsValid(P and P.panel) then
    if P.url ~= url then
      P.panel:Call("setUrl(" .. string.format("%q", url) .. ")")
      P.url = url
    end
    return P
  end
  -- Hidden, off-screen, non-interactive CEF host: see NTx.MakeHiddenCef in
  -- ntx_probe.lua for why this cannot be a HUD-docked FILL panel (a failing
  -- remote document would paint its error page over the whole screen).
  local panel = vgui.Create("DHTML")
  panel:SetSize(1, 1)
  panel:SetPos(-64, -64)
  panel:SetAlpha(0)
  panel:SetMouseInputEnabled(false)
  panel:SetKeyboardInputEnabled(false)
  -- DHTML has no SetPaintBackground; Paint/PaintOver overrides suffice.
  panel.Paint = function() end
  panel.PaintOver = function() end
  local dbg = GetConVar("ntx_cef_visible")
  if dbg and dbg:GetBool() then
    panel:SetAlpha(255)
    panel:SetSize(480, 360)
    panel:SetPos(ScrW() - 500, ScrH() - 400)
    panel:SetMouseInputEnabled(true)
  end
  P = { panel = panel, url = url, registered = false }
  NTx.WebAudio.Pages[pkey] = P
  -- A page born after the server assigned this client a cadence would never be
  -- told its interval and would keep the built-in 20 Hz, so apply it here too.
  -- ntx_amp_rms owns the cadence value.
  if NTx.RmsCadence then
    timer.Simple(1, function()
      if IsValid(P.panel) then
        pcall(P.panel.Call, P.panel,
          "ntxSetMeterInterval(" .. string.format("%.4f", NTx.RmsCadence) .. ")")
      end
    end)
  end
  local keyCopy = pkey
  panel.ConsoleMessage = function(_, msg)
    local c = GetConVar("ntx_webaudio_debug")
    if c and c:GetBool() then print("[NTx:JS " .. keyCopy .. "] " .. tostring(msg)) end
  end
  panel.OnFinishLoadingDocument = function()
    local pg = NTx.WebAudio.Pages[keyCopy]
    if not pg or not IsValid(pg.panel) then return end
    local ok = pcall(pg.panel.AddFunction, pg.panel, "ntx", "status",
      function(json) NTx.WebAudioOnStatus(keyCopy, json) end)
    if ok then
      pg.registered = true
      pg.openedAt = CurTime()
      if pg.url then pg.panel:Call("setUrl(" .. string.format("%q", pg.url) .. ")") end
    else
      print("[NTx] WebAudio bridge registration failed for " .. keyCopy)
    end
  end
  panel:OpenURL(mixerPageURL())
  -- Watchdog: a page that never finishes loading (asset:// blocked,
  -- engine without CEF/Awesomium page support) must say so, not hang mute.
  timer.Simple(12, function()
    local pg = NTx.WebAudio.Pages[keyCopy]
    if pg and IsValid(pg.panel) and not pg.registered then
      print("[NTx] WebAudio page for " .. keyCopy .. " never signalled ready; that input stays silent on this backend (run ntx_audio_probe).")
    end
  end)
  return P
end

function NTx.WebAudioOnStatus(pkey, json)
  local r = nil
  pcall(function() r = util.JSONToTable(tostring(json or "")) end)
  if not istable(r) then return end
  if r.t == "hello" then
    NTx.PageHello[pkey] = tonumber(r.v)
    NTx.PagePong[pkey] = CurTime()
    local P = NTx.WebAudio.Pages[pkey]
    if P and tonumber(r.v) ~= NTx.PAGE_API_VERSION and not P.apiWarned then
      P.apiWarned = true
      print("[NTx] page " .. tostring(pkey) .. " speaks API v" .. tostring(r.v)
        .. " but this addon wants v" .. tostring(NTx.PAGE_API_VERSION)
        .. " - re-upload data_static/ntx_audio/webaudio.html to your page host.")
    end
    return
  end
  if r.t == "pong" then
    NTx.PagePong[pkey] = CurTime()
    return
  end
  if r.t == "jserror" then
    print("[NTx] WebAudio page JS error (" .. tostring(pkey) .. "): "
      .. tostring(r.msg) .. " line " .. tostring(tonumber(r.line) or 0)
      .. " - re-upload data_static/ntx_audio/webaudio.html to your page host.")
    markPageBroken(pkey, "page JS error: " .. tostring(r.msg))
    return
  end
  if r.t == "stalled" then
    markPageBroken(pkey, "audio element will not start after 8 s (stale hosted page file?)")
    return
  end
  if r.t == "state" then
    NTx.WebAudioRunning = (r.state == "running")
  elseif r.t == "tainted" then
    local P = NTx.WebAudio.Pages[pkey]
    -- Missing fields = old hosted page: fall back to the ambiguous case.
    local srcMean = tonumber(r.srcMean) or 128
    local srcVar = tonumber(r.srcVar) or 0
    NTx.LastTaint = {
      srcAudible = r.srcAudible == true, srcMean = srcMean, srcVar = srcVar,
      chains = tonumber(r.chains) or 0,
      fq = tonumber(r.fq), pan = tonumber(r.pan), cgain = tonumber(r.g),
      when = os.date("%H:%M:%S"),
    }
    -- Per-stage energy: fq = after filters, pan = after panner, g = last
    -- commanded gain. Missing fields = stale hosted page file.
    local bis = "[bisect"
      .. (tonumber(r.fq) ~= nil and (" fq=" .. tonumber(r.fq)) or "")
      .. (tonumber(r.pan) ~= nil and (" pan=" .. tonumber(r.pan)) or "")
      .. (tonumber(r.g) ~= nil and (" g=" .. tonumber(r.g)) or "") .. "]"
    if tonumber(r.fq) == nil then
      bis = bis .. " STALE page file - re-upload webaudio.html!"
    end
    if not (P and P.inputEnt and IsValid(P.inputEnt)) then return end
    -- Three silences, three responses:
    -- (1) real energy in, nothing out = chain anomaly, latch loudly;
    -- (2) exact digital zeros = CORS taint OR true silence, latch + bus test;
    -- (3) DC-offset/dead air = correctly filtered to nothing, no latch.
    if srcVar >= 2 then
      NTx.Tainted[P.inputEnt] = true
      if not NTx.TaintedNoticed[P.inputEnt] then
        NTx.TaintedNoticed[P.inputEnt] = true
        local blame = "unmeasured (stale page file?)"
        local fqN, panN = tonumber(r.fq), tonumber(r.pan)
        if fqN ~= nil and panN ~= nil then
          if fqN <= 0 then
            blame = "filters output zeros despite source energy (biquad stage)"
          elseif panN <= 0 then
            blame = "panner outputs zeros despite filter energy (HRTF/cone stage)"
          else
            blame = "energy survives to panner output; master/analyser stage suspect"
          end
        end
        print("[NTx] WebAudio anomaly: audible energy enters (var " .. srcVar .. ") but master silent. "
          .. "Blame: " .. blame .. ". " .. bis
          .. " Send this line plus ntx_audio_status. Input latched silent meanwhile.")
      end
    elseif srcVar == 0 and srcMean == 128 then
      if not NTx.Tainted[P.inputEnt] then
        NTx.Tainted[P.inputEnt] = true
        if not NTx.TaintedNoticed[P.inputEnt] then
          NTx.TaintedNoticed[P.inputEnt] = true
          print("[NTx] WebAudio: exact digital silence for 3 s - CORS taint or a dead mount, "
            .. "indistinguishable here. This client renders WebAudio only, so its fallback "
            .. "buses stay silent by design: set ntx_backend bass to tell a CORS/page fault "
            .. "from a mount that emits nothing. " .. bis .. " See probe: ntx_audio_probe <url>")
        end
      end
    else
      print("[NTx] WebAudio: source near-silent (mean " .. srcMean .. ", variance " .. srcVar
        .. ") - dead air or subsonic/DC content suspected; highpass chains correctly pass nothing. "
        .. "No latch: audio resumes on its own if the source returns. " .. bis)
    end
  elseif r.t == "playing" then
    local P = NTx.WebAudio.Pages[pkey]
    if P and IsValid(P.inputEnt) then
      NTx.PageErrors[P.inputEnt] = nil
      NTx.PageBroken[P.inputEnt] = nil
      NTx.BrokenRetryAt[P.inputEnt] = nil
    end
  elseif r.t == "rms" then
    -- Optional (page v6): the source level measured in the page, which is what
    -- makes the amplifier meters move with the music instead of sitting on the
    -- mixer faders. A page that never reports it just leaves the meters on the
    -- server's commanded estimate.
    -- How often the page's measurements arrive, measured.
    local now = CurTime()
    NTx.PageRmsCount = (NTx.PageRmsCount or 0) + 1
    if not NTx.PageRmsAt or (now - NTx.PageRmsAt) >= 1 then
      NTx.PageRmsRate = (NTx.PageRmsCount - (NTx.PageRmsBase or 0)) / math.max(now - (NTx.PageRmsAt or (now - 1)), 0.001)
      NTx.PageRmsAt = now
      NTx.PageRmsBase = NTx.PageRmsCount
    end
    -- How often the page's measurements arrive, and how many the page says
    -- it has taken. Two different numbers: the first is what reached us, the
    -- second is what the page did, and a gap between them means the bridge or
    -- the gate is the problem.
    local now = CurTime()
    NTx.PageRmsCount = (NTx.PageRmsCount or 0) + 1
    if not NTx.PageRmsAt or (now - NTx.PageRmsAt) >= 1 then
      NTx.PageRmsRate = math.Round((NTx.PageRmsCount - (NTx.PageRmsBase or 0))
        / math.max(now - (NTx.PageRmsAt or (now - 1)), 0.001), 1)
      NTx.PageRmsAt = now
      NTx.PageRmsBase = NTx.PageRmsCount
    end
    NTx.PageSamples = tonumber(r.n) or NTx.PageSamples
    NTx.PageRms[pkey] = {
      v = math.Clamp(tonumber(r.v) or 0, 0, 4),
      -- One level per bus, each already band-limited in the page. This is the
      -- array the buses are indexed by, so a MID channel is measured from the
      -- MID band and a SUB one from the SUB band - they are genuinely different
      -- loads rather than the same figure relabelled. Absent on an older page,
      -- and the server falls back to v.
      b = istable(r.b) and r.b or nil,
      c = tonumber(r.c) or 0,
      at = CurTime(),
    }
  elseif r.t == "error" then
    local code = tonumber(r.code) or 0
    local P = NTx.WebAudio.Pages[pkey]
    local ent = P and P.inputEnt
    if ent and IsValid(ent) then
      local n = (NTx.PageErrors[ent] or 0) + 1
      NTx.PageErrors[ent] = n
      if n >= 3 and not NTx.PageBroken[ent] then
        NTx.PageBroken[ent] = true
        NTx.BrokenRetryAt[ent] = CurTime() + 30
        print("[NTx] WebAudio page cannot load the stream (media error " .. code
          .. ": 1=aborted 2=network 3=decode 4=unsupported"
          .. "; netstate " .. tostring(r.ns) .. " readystate " .. tostring(r.rs) .. ")"
          .. " That input stays silent on this client"
          .. " and the page retries in 30 s. Check the mount/URL first: ntx_audio_probe <url>")
      end
    else
      print("[NTx] WebAudio page error (" .. tostring(pkey) .. "): " .. tostring(r.err or "?")
        .. " code " .. code)
    end
  end
end

function NTx.WebAudioResume()
  for _, P in pairs(NTx.WebAudio.Pages) do
    if IsValid(P.panel) then P.panel:Call("ntxResume()") end
  end
end

concommand.Add("ntx_audio_resume", function() NTx.WebAudioResume() end)

-- One-click gesture panel: modern Chromium needs a real DOM click to start
-- audio; game clicks don't count, so this tiny panel IS the gesture.
local noticePanel = nil
local function updateNotice(need)
  if need and not NTx.WebAudioRunning then
    if not IsValid(noticePanel) then
      noticePanel = vgui.Create("DFrame")
      noticePanel:SetTitle("NTx spatial audio")
      noticePanel:SetSize(260, 96)
      noticePanel:SetPos(ScrW() - 280, ScrH() - 200)
      local lbl = vgui.Create("DLabel", noticePanel)
      lbl:Dock(TOP)
      lbl:SetText("Browser audio is suspended.\nClick ENABLE once.")
      local btn = vgui.Create("DButton", noticePanel)
      btn:Dock(BOTTOM)
      btn:SetText("ENABLE")
      btn.DoClick = function() NTx.WebAudioResume() end
    end
  elseif IsValid(noticePanel) and (NTx.WebAudioRunning or not need) then
    noticePanel:Close()
    noticePanel = nil
  end
end

local warnedForce = false
local nextPush = 0

hook.Add("Think", "NTx.WebAudioThink", function()
  if not NTx.EffectiveBackend then return end
  if NTx.EffectiveBackend() ~= "webaudio" then
    updateNotice(false)
    if not warnedForce then
      local c = GetConVar("ntx_backend")
      if c and c:GetString() == "webaudio" then
        warnedForce = true
        print("[NTx] ntx_backend=webaudio but this client is not capable (run ntx_audio_probe); BASS fallback in use.")
      end
    end
    return
  end
  if CurTime() < nextPush then return end
  nextPush = CurTime() + 1 / math.Clamp(cvPushHz:GetFloat() or 15, 5, 60)
  -- Housekeeping: drop fallback state for removed inputs, and let
  -- load-broken inputs re-probe the page every 30 s (server restarts).
  for ent in pairs(NTx.TaintedUrl) do
    if not IsValid(ent) then
      NTx.TaintedUrl[ent] = nil
      NTx.Tainted[ent] = nil
      NTx.TaintedNoticed[ent] = nil
      NTx.PageBroken[ent] = nil
      NTx.PageErrors[ent] = nil
      NTx.BrokenRetryAt[ent] = nil
    end
  end
  for ent, at in pairs(NTx.BrokenRetryAt) do
    if CurTime() >= at then
      NTx.BrokenRetryAt[ent] = nil
      NTx.PageBroken[ent] = nil
      NTx.PageErrors[ent] = nil
    end
  end
  -- Heartbeat: ping each page and treat silence as a dead page. A hosted
  -- copy that lost its JS would otherwise sit mute forever with no verdict.
  for pkey, P in pairs(NTx.WebAudio.Pages) do
    if IsValid(P.panel) then
      local last = NTx.PagePing[pkey] or 0
      if CurTime() - last >= 3 then
        NTx.PagePing[pkey] = CurTime()
        P.panel:Call("ntxPing()")
        local pong = NTx.PagePong[pkey] or 0
        if pong == 0 then
          -- Never answered a single ping: the hosted copy has no ntxPing()
          -- (older file) or its JS is dead. Either way it cannot play.
          if (P.openedAt and CurTime() - P.openedAt > 10) and not NTx.PagePongDead[pkey] then
            NTx.PagePongDead[pkey] = true
            markPageBroken(pkey, "page never answers heartbeats (stale hosted webaudio.html or JS dead)")
          end
        elseif CurTime() - pong > 8 then
          markPageBroken(pkey, "no pong from page for 8 s (JS dead or bridge lost)")
        end
      end
    end
  end
  local maxPages = math.Clamp(cvMaxPages:GetInt() or 4, 1, 8)
  local seen, count, pending = {}, 0, {}
  -- Rebuilt each pass, so a cabinet that was removed stops being reported.
  NTx.TapSide = {}
  local ply = LocalPlayer()
  if not IsValid(ply) then return end
  local ep, ea = ply:EyePos(), ply:EyeAngles()
  local fw = ea:Forward()
  -- Real camera up, orthogonalised against forward. The page rebuilds an
  -- orthonormal basis itself, but a sane starting vector keeps the
  -- projection well-conditioned while you look straight up or down.
  local uw = ea:Up()
  local dp = uw:Dot(fw)
  uw = uw - fw * dp
  if uw:Length() < 0.001 then uw = fw:Cross(Vector(1, 0, 0)) end
  uw:Normalize()
  local listener = {
    px = math.Round(ep.x, 2), py = math.Round(ep.y, 2), pz = math.Round(ep.z, 2),
    fx = math.Round(fw.x, 3), fy = math.Round(fw.y, 3), fz = math.Round(fw.z, 3),
    upx = math.Round(uw.x, 3), upy = math.Round(uw.y, 3), upz = math.Round(uw.z, 3),
  }
  for _, input in ipairs(NTx.Graph.inputs) do
    if not IsValid(input.mixer) then continue end
    if not IsValid(input.ent) then continue end
    local url = input.url or ""
    if url == "" then continue end
    if NTx.TaintedUrl[input.ent] ~= url then
      NTx.TaintedUrl[input.ent] = nil
      NTx.Tainted[input.ent] = nil
      NTx.TaintedNoticed[input.ent] = nil
    end
    NTx.TaintedUrl[input.ent] = url
    if NTx.Tainted[input.ent] then continue end
    -- Load-broken inputs hold no page (else the 5 s error loop churns
    -- Icecast slots); they stay silent until the re-probe above reopens one.
    if NTx.PageBroken[input.ent] then continue end
    local mrec = mixerRecFor(input.mixer)
    if not mrec then continue end
    -- The page stays open even with no audible taps. The band analysers hang
    -- off the source splitter, not off cabinet chains, so with every amplifier
    -- off or every cabinet out of range the page is still measuring and still
    -- reporting - which is the whole reason to keep it open. Closing it here
    -- meant a switched-off rig reported nothing and came back blind.
    local taps, energy = buildTaps(input, mrec, ep)
    local pkey = "wai|" .. input.ent:EntIndex()
    seen[pkey] = true
    count = count + 1
    if count > maxPages then continue end
    pending[#pending + 1] = { pkey = pkey, url = url, ent = input.ent,
      taps = taps, energy = energy }
  end
  -- Audibility-weighted headroom. Summing *commanded* gains (the old law)
  -- counted distant speakers as loud and quietened everything near you;
  -- this sums estimated audible ENERGY (fader x distance x cone) instead, so
  -- a far stack contributes almost nothing. Energy adds, so sqrt(target/E)
  -- holds the sum steady at ntx_headroom_db instead of at full scale -
  -- see NTx.HeadroomNorm for why parking at 1.0 destroyed directivity.
  -- Below the target nothing is touched: a single quiet source stays exactly
  -- as loud as it asked to be.
  local webEnergy = 0
  for _, pend in ipairs(pending) do webEnergy = webEnergy + (pend.energy or 0) end
  NTx.WebEnergy = webEnergy
  NTx.WebEnergyAt = CurTime()
  -- Cross-path: BASS fallback taps are separate channels that also sum at the
  -- device. The BASS renderer publishes its energy here; ignore it if stale.
  local bassEnergy = 0
  if tonumber(NTx.BassEnergyAt or 0) > 0 and (CurTime() - NTx.BassEnergyAt) < 1 then
    bassEnergy = math.Clamp(tonumber(NTx.BassEnergy) or 0, 0, 64)
  end
  local totalEnergy = webEnergy + bassEnergy
  local norm = NTx.HeadroomNorm(totalEnergy)
  -- The amplifier SFX page is separate from the programme pages, so it gets
  -- its own state and its own context. Opened here rather than on demand so
  -- the fan is already running when a rig is switched on.
  ensureAmpSfxPage()
  pushAmpSfx(listener)
  for _, pend in ipairs(pending) do
    local P = ensurePage(pend.pkey, pend.url)
    if P then
      P.inputEnt = pend.ent
      local payload = {
        url = pend.url, listener = listener, sp = pend.taps, norm = norm,
        lim = (cvLimiter:GetBool() and 1) or 0,
        limDb = cvLimiterDb:GetFloat(),
        smoothMs = cvMotionSmooth:GetFloat(),
        maxRate = cvMotionRate:GetFloat(),
      }
      -- The amplifier's own noise is NOT sent to the programme page. It used
      -- to be, and the page synthesised it there: a noise source with no
      -- position on it, summed into the programme's master bus, so it was
      -- audible from the whole map. The SFX page owns it now, panned at the
      -- amplifier and buried under the programme.
      if IsValid(P.panel) then
        P.panel:Call("ntxUpdate(" .. util.TableToJSON(payload) .. ")")
      end
    end
  end
  for pkey, P in pairs(NTx.WebAudio.Pages) do
    if not seen[pkey] then
      if IsValid(P.panel) then P.panel:Remove() end
      NTx.WebAudio.Pages[pkey] = nil
      NTx.PageHello[pkey] = nil
      NTx.PagePong[pkey] = nil
      NTx.PagePing[pkey] = nil
      NTx.PagePongDead[pkey] = nil
      NTx.PageRms[pkey] = nil
    end
  end
  -- No open pages means nothing is running, regardless of the last
  -- reported context state (stale "running" lies to status + notice).
  if next(NTx.WebAudio.Pages) == nil then NTx.WebAudioRunning = false end
  updateNotice(next(NTx.WebAudio.Pages) ~= nil)
end)
