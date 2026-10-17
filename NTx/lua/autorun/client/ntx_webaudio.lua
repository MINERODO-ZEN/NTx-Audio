-- Client: WebAudio backend. ONE hidden DHTML page per input streams the
-- URL exactly once; every speaker gets its own filtered tap inside the
-- page (Biquad HP/LP cascade + gain + delay/polarity + PannerNode), so all
-- taps are phase-coherent by construction. Lua owns topology and gains and
-- pushes state at 10 Hz; the page owns decoding, filtering and panning.
--
-- Limits, stated plainly: page audio bypasses the GMod master volume, and
-- a stream without CORS headers reads as silence to the page graph
-- (tainted inputs fall back to BASS buses, see NTx.Tainted).
if not CLIENT then return end
if NTx_WebAudioLoaded then return end
NTx_WebAudioLoaded = true

NTx.WebAudio = NTx.WebAudio or { Pages = {} }
NTx.PAGE_API_VERSION = 5
NTx.PageHello = NTx.PageHello or {}
NTx.PagePong = NTx.PagePong or {}
NTx.PagePing = NTx.PagePing or {}
NTx.PagePongDead = NTx.PagePongDead or {}
NTx.Tainted = NTx.Tainted or {}
NTx.TaintedUrl = NTx.TaintedUrl or {}
NTx.TaintedNoticed = NTx.TaintedNoticed or {}
-- Load failures are transient-worthy (server restarts), unlike CORS policy:
-- broken inputs get BASS cover AND a periodic page re-probe.
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
      .. " falls back to a BASS bus (link a fallback bus to its mixer); page retries in 30 s.")
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

-- Mirror of the mixer gain model, per speaker kind (the split is real here:
-- each tap is filtered, so MID and SUB busses genuinely diverge).
-- Faders are logarithmic (NTx.FaderToGain: -60 dB .. +6 dB, unity at 1).
local function waGain(mrec, inputEnt, stype)
  if not mrec or mrec.mm then return 0 end
  local bus = NTx.BusForType(stype)
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
      local gain = waGain(mrec, input.ent, s.stype) * (input.vol or 1)
      -- The tool's max distance is a cutoff, not a suggestion: silent
      -- beyond it, with a linear fade over the last 15% so crossing the
      -- boundary does not click. (The PannerNode's own maxDistance only
      -- softens the inverse curve, it never reaches silence.)
      local maxd = math.Clamp(input.maxd or 1200, 100, 10000)
      local rangeFade = math.Clamp((maxd - (listenerPos - s.pos):Length()) / math.max(maxd * 0.15, 1), 0, 1)
      if gain > 0.001 and rangeFade > 0 then
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
        if s.stype == "MID" then
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
        gain = gain * coneGain
        -- Throttle lives in the NTx table, not a file-local: after a
        -- lua_refresh or a partial file sync a file-local declared further
        -- down can be nil while the Think hook already references it, which
        -- crashed buildTaps at this exact comparison.
        if NTx.CvConeDebug and NTx.CvConeDebug:GetBool() and CurTime() >= (NTx.NextWaConeDbg or 0) then
          NTx.NextWaConeDbg = CurTime() + 2
          print(string.format("[NTx cone/WA] %s%s ent=%s dist=%.0f/%.0f cone=%.3f range=%.2f g=%.4f",
            tostring(s.stype), s.selfcard and "(SC)" or "",
            tostring(IsValid(s.ent) and s.ent:EntIndex() or "?"),
            dist, maxd, coneGain, rangeFade, gain))
        end
        -- Estimated audible energy at the listener, mirroring the
        -- PannerNode's distance attenuation and the directivity we just
        -- applied. Normalisation uses this, so distant or off-axis taps
        -- contribute almost nothing instead of dragging the rig down.
        local audible = gain * NTx.DistanceGain(dist)
        energy = energy + audible * audible
        taps[#taps + 1] = {
          id = tostring(s.ent:EntIndex()), kind = s.stype,
          g = math.Round(gain, 4), d = math.Round(delayMs, 3), inv = inv,
          px = math.Round(s.pos.x, 2), py = math.Round(s.pos.y, 2), pz = math.Round(s.pos.z, 2),
          -- Cone disabled on the panner (directivity already in g); HRTF and
          -- distance attenuation still apply.
          ci = 360, co = 360, cov = 1,
          maxd = maxd,
          -- 20000 = no occlusion lowpass (audible path untouched); lower =
          -- cabinet without line of sight, highs rolled off by the page.
          occlp = math.Round(occlp, 1),
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
        .. " - re-upload data_static/ntx_live_audio/webaudio.html to your page host.")
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
      .. " - re-upload webaudio.html from the addon.")
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
          .. " Send this line plus ntx_audio_status. Input latched to BASS bus cover meanwhile.")
      end
    elseif srcVar == 0 and srcMean == 128 then
      if not NTx.Tainted[P.inputEnt] then
        NTx.Tainted[P.inputEnt] = true
        if not NTx.TaintedNoticed[P.inputEnt] then
          NTx.TaintedNoticed[P.inputEnt] = true
          print("[NTx] WebAudio: exact digital silence for 3 s - CORS taint or a dead mount, "
            .. "indistinguishable here. Decisive test: spawn a fallback bus. Bus plays = page/CORS issue; "
            .. "bus silent too = the mount emits silence. " .. bis .. " See probe: ntx_audio_probe <url>")
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
          .. " That input moves to BASS bus cover"
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
    -- Icecast slots); BASS bus cover handles them, re-probe above reopens.
    if NTx.PageBroken[input.ent] then continue end
    local mrec = mixerRecFor(input.mixer)
    if not mrec then continue end
    -- No audible taps: don't hold a page open. The cleanup sweep below
    -- closes any existing page, so a muted mixer is truly silent.
    local taps, energy = buildTaps(input, mrec, ep)
    if #taps == 0 then continue end
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
    end
  end
  -- No open pages means nothing is running, regardless of the last
  -- reported context state (stale "running" lies to status + notice).
  if next(NTx.WebAudio.Pages) == nil then NTx.WebAudioRunning = false end
  updateNotice(next(NTx.WebAudio.Pages) ~= nil)
end)
