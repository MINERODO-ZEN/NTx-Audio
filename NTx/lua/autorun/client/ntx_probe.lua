-- Client: WebAudio capability probe. Answers whether this client's
-- embedded browser can run the single-stream mixer page (AudioContext +
-- Biquad + Panner + Delay) and whether a stream URL survives
-- createMediaElementSource (CORS taint check). Sets NTx.WebAudioOK, which
-- drives the ntx_backend "auto" selector in ntx_dsp.lua.
if not CLIENT then return end
if NTx_ProbeLoaded then return end
NTx_ProbeLoaded = true

NTx.WebAudioDetail = NTx.WebAudioDetail or "not run"

CreateClientConVar("ntx_webaudio_debug", "0", true, false,
  "Mirror WebAudio page console output to the game console")

local DEFAULT_PAGE_BASE = "https://xta.xenonetwork.moe/dsp/"

-- Single knob for both pages, owned by the SERVER (created in ntx_net.lua as a
-- replicated ConVar). Clients only read it; they cannot change where the page
-- is fetched from. Same-origin hosting removes CORS from the picture.
local warnedBase = false
function NTx.PageURL(name)
  local c = GetConVar("ntx_page_base")
  local base = (c and c:GetString() or "")
  if base == "" then base = DEFAULT_PAGE_BASE end
  -- GMod console strips //comments: an unquoted https://... arrives as
  -- just "https:". Catch that here instead of failing silent pages.
  if not string.match(base, "^%w+://") then
    if not warnedBase then
      warnedBase = true
      print("[NTx] ntx_page_base looks truncated (" .. base
        .. '); server must set it quoted: ntx_page_base "' .. DEFAULT_PAGE_BASE .. '". Using default.')
    end
    base = DEFAULT_PAGE_BASE
  end
  if string.sub(base, -1) ~= "/" then base = base .. "/" end
  return base .. name
end

local panel = nil
local probeReady = false
local pendingRun = false
local pendingUrl = nil
local onResult

-- Hidden CEF hosting.
--
-- These pages load a REMOTE URL, so a 404, DNS failure or CEF timeout paints
-- an error document across the whole screen. Docking FILL to the HUD (the
-- pattern used for local, always-present pages) is therefore unsafe here.
--
-- SetVisible(false) is not an option: an invisible panel does not run Think,
-- and Think is what drains the queued JavaScript (AddFunction/Call), which
-- would silently stall every mixer page. So the panel stays logically visible
-- but is parked off-screen at 1x1 with alpha 0 and no input, which renders
-- nothing regardless of what the document contains.
local cvCefVisible = CreateClientConVar("ntx_cef_visible", "0", true, false,
  "Debug: park NTx CEF pages on screen instead of hiding them")

function NTx.MakeHiddenCef()
  local p = vgui.Create("DHTML")
  p:SetSize(1, 1)
  p:SetPos(-64, -64)
  p:SetAlpha(0)
  p:SetMouseInputEnabled(false)
  p:SetKeyboardInputEnabled(false)
  -- No SetPaintBackground here: DHTML does not expose it (it is not a DPanel).
  -- The Paint/PaintOver overrides below are what keep it from drawing.
  p.Paint = function() end
  p.PaintOver = function() end
  if cvCefVisible:GetBool() then
    -- Escape hatch for debugging a page that will not load: bring it up in a
    -- small corner panel instead of full screen.
    p:SetAlpha(255)
    p:SetSize(480, 360)
    p:SetPos(ScrW() - 500, ScrH() - 400)
    p:SetMouseInputEnabled(true)
  end
  return p
end

local function ensurePanel()
  if IsValid(panel) then return panel end
  -- Same hidden hosting as the mixer pages: never visible, never input.
  panel = NTx.MakeHiddenCef()
  panel.ConsoleMessage = function(_, msg)
    local c = GetConVar("ntx_webaudio_debug")
    if c and c:GetBool() then print("[NTx:JS probe] " .. tostring(msg)) end
  end
  panel.OnFinishLoadingDocument = function()
    if not IsValid(panel) then return end
    local ok = pcall(panel.AddFunction, panel, "ntx", "probeResult",
      function(json) onResult(json) end)
    if ok then
      probeReady = true
      if pendingRun then
        pendingRun = false
        local arg = pendingUrl and string.format("%q", tostring(pendingUrl)) or "null"
        pendingUrl = nil
        panel:Call("runProbe(" .. arg .. ")")
      end
    else
      print("[NTx] probe: bridge registration failed")
    end
  end
  panel:OpenURL(NTx.PageURL("probe.html"))
  timer.Simple(12, function()
    if IsValid(panel) and not probeReady then
      print("[NTx] probe: page never signalled ready (page host unreachable or ntx_page_base truncated?). WebAudio treated as unavailable.")
      -- Destroy it: a dead remote document can render an error page, and
      -- there is nothing left to gain from keeping it around.
      panel:Remove()
      panel = nil
      probeReady = false
    end
  end)
  return panel
end

onResult = function(json)
  local r = nil
  pcall(function() r = util.JSONToTable(tostring(json or "")) end)
  if not istable(r) then
    print("[NTx] probe: unreadable result")
    return
  end
  NTx.WebAudioOK = (r.api == "full")
  -- A "clean" verdict on a near-zero-variance signal blesses dead air:
  -- flag it so nobody trusts it.
  if r.taint == "clean" and tonumber(r.svar) ~= nil and tonumber(r.svar) < 2 then
    r.note = (r.note and r.note ~= "" and (r.note .. "; ") or "")
      .. "signal variance " .. tostring(r.svar) .. " (DC-only/silent source?)"
  end
  -- A clean stream probe un-latches tainted inputs on the same URL: the
  -- latch exists for broken CORS, not to shun a fixed server forever.
  if r.taint == "clean" and NTx.LastProbeUrl then
    for ent, u in pairs(NTx.TaintedUrl or {}) do
      if u == NTx.LastProbeUrl and (NTx.Tainted or {})[ent] then
        NTx.Tainted[ent] = nil
        NTx.TaintedNoticed[ent] = nil
        print("[NTx] probe clean: input ent "
          .. tostring(IsValid(ent) and ent:EntIndex() or "gone")
          .. " un-latched, WebAudio page will reopen it.")
      end
    end
  end
  NTx.WebAudioDetail = "api=" .. tostring(r.api or "?")
    .. " vorbis=" .. tostring(r.cpt or "?")
    .. " plain=" .. tostring(r.plain or "?")
    .. " taint=" .. tostring(r.taint or "?")
    .. " fetch=" .. tostring(r.fstatus or "?") .. "/" .. tostring(r.ftype or "?")
    .. "/acao:" .. tostring(r.facao or "?") .. "/magic:" .. tostring(r.fmagic or "?")
    .. " nocors=" .. tostring(r.nocors or "?") .. " csp=" .. tostring(r.csp or "?")
    .. (r.note and r.note ~= "" and (" (" .. tostring(r.note) .. ")") or "")
  print("[NTx] WebAudio probe: " .. NTx.WebAudioDetail
    .. " -> effective backend " .. (NTx.EffectiveBackend and NTx.EffectiveBackend() or "bass"))
end

function NTx.RunProbe(url)
  local p = ensurePanel()
  NTx.LastProbeUrl = url
  if probeReady and IsValid(p) then
    local arg = url and string.format("%q", tostring(url)) or "null"
    p:Call("runProbe(" .. arg .. ")")
  else
    -- Flushed by OnFinishLoadingDocument (flag, not nil-check: API-only
    -- probes carry no URL).
    pendingRun = true
    pendingUrl = url
  end
end

concommand.Add("ntx_audio_probe", function(_, _, args)
  local url = args[1]
  if not url or url == "" then
    local ins = NTx.Graph and NTx.Graph.inputs or {}
    if ins[1] and ins[1].url ~= "" then url = ins[1].url end
  end
  NTx.RunProbe(url)
end)

-- One silent API-only probe per session so "auto" has data to work with.
hook.Add("InitPostEntity", "NTx.AutoProbe", function()
  timer.Simple(8, function() NTx.RunProbe(nil) end)
end)

-- Panels are documents, not views: a base change orphans them. Tear down
-- every NTx page so the next Think/probe opens fresh ones at the new base.
-- (Without this, editing ntx_page_base silently keeps testing the OLD host.)
cvars.AddChangeCallback("ntx_page_base", function()
  if IsValid(panel) then panel:Remove() end
  panel = nil
  probeReady = false
  pendingRun = false
  pendingUrl = nil
  NTx.WebAudioOK = false
  NTx.WebAudioDetail = "not run"
  NTx.WebAudioRunning = false
  if NTx.WebAudio and NTx.WebAudio.Pages then
    for k, P in pairs(NTx.WebAudio.Pages) do
      if P and IsValid(P.panel) then P.panel:Remove() end
      NTx.WebAudio.Pages[k] = nil
    end
  end
  print("[NTx] page base changed; all mixer/probe pages closed and will reopen fresh.")
  -- Re-probe capability (API-only) so "auto" can re-engage without a
  -- reconnect; stream taint is still evaluated per input at runtime.
  timer.Simple(2, function() NTx.RunProbe(nil) end)
end)
