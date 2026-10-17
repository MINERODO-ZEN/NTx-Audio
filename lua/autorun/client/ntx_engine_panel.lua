-- Client: NTx engine options panel, registered into the spawnmenu Utilities
-- menu the same way core's utilities_menu.lua and 3D-Stream-Radio do it.
--
-- The panel we are handed is a ControlPanel (a DForm), which lays out and
-- scrolls its OWN children. Nesting a DScrollPanel inside it collapses that
-- child to zero height - the panel then looks empty with no error at all -
-- so everything below is added directly through DForm's own helpers:
-- Help / ControlHelp / NumSlider / CheckBox / AddItem / Button.
if not CLIENT then return end
if NTx_EnginePanelLoaded then return end
NTx_EnginePanelLoaded = true

-- name, kind, help, min, max, decimals, choices
--   kind: "check" | "combo" | "slider"
local ENGINE = {
  { "ntx_backend", "combo", "Backend", nil, nil, nil,
    { "auto", "webaudio", "bass" } },
  { "ntx_max_pages", "slider", "Max WebAudio pages (one per input)", 1, 8, 0 },
  { "ntx_limiter", "check", "Safety limiter on the WebAudio master" },
  { "ntx_limiter_db", "slider", "Limiter threshold (dBFS)", -12, 0, 1 },
  { "ntx_headroom_db", "slider", "Mix headroom (dB)", -12, 0, 1 },
  { "ntx_push_hz", "slider", "State push rate (Hz)", 5, 60, 0 },
  { "ntx_motion_smooth", "slider", "Motion smoothing (ms)", 0, 300, 0 },
  { "ntx_motion_max_rate", "slider", "Max motion speed (units/s)", 0, 8000, 0 },
  { "ntx_cardioid_ms", "slider", "Cardioid rear-box delay (ms)", 0, 20, 1 },
  { "ntx_endfire_m", "slider", "Endfire cabinet spacing (m)", 0, 5, 2 },
  { "ntx_bass_smooth", "slider", "BASS 3D tap smoothing (ms)", 0, 300, 0 },
  { "ntx_occlusion_rays", "slider", "Wall-occlusion star traces (0 = off)", 0, 128, 0 },
  { "ntx_occlusion_min", "slider", "Occluded bus volume floor", 0, 1, 2 },
  { "ntx_occ_mid_min", "slider", "Occluded MID volume floor", 0, 1, 2 },
  { "ntx_occ_mid_lp", "slider", "Occluded MID lowpass (Hz, 0 = gain only)", 0, 20000, 0 },
  { "ntx_webaudio_debug", "check", "Mirror page console to game console" },
}

-- ConVars the SERVER owns (FCVAR_REPLICATED). A client cannot write these, so
-- they are reported rather than controlled.
local SERVER_OWNED = {
  ntx_page_base = "Page host",
  ntx_max_channels = "Max BASS taps per client",
  ntx_mute_distance = "BASS hard-mute range (units)",
  ntx_update_hz = "Graph rebroadcast cap (Hz)",
  ntx_mixer_admin_only = "Mixer edits limited to admins",
}

local function cvOf(name)
  return GetConVar(name)
end

local function addConvarCombo(panel, name, help, choices)
  local cv = cvOf(name)
  if not cv then
    panel:ControlHelp(help .. " (" .. name .. " unavailable)")
    return nil
  end
  local left = vgui.Create("DLabel", panel)
  left:SetText(help)
  left:SetDark(true)
  local right = vgui.Create("DComboBox", panel)
  if right.SetConVar then right:SetConVar(name) end
  for _, v in ipairs(choices or {}) do right:AddChoice(v, v) end
  -- Show the live value: SetConVar alone leaves the box blank until the
  -- first selection, which is the "dropdown is nil" report.
  right:SetValue(cv:GetString())
  function right:OnSelect(_, value, data)
    -- AddChoice stores the value in data; fall back to the visible text
    -- so the convar can never receive a literal "nil" string (the old
    -- tostring(data) did exactly that, pinning the backend to BASS and
    -- making every other setting look dead).
    RunConsoleCommand(name, tostring(data or value))
  end
  panel:AddItem(left, right)
  return cv
end

local function buildContents(panel)
  panel:Clear()

  local backend = NTx.EffectiveBackend and NTx.EffectiveBackend() or "?"
  panel:Help("NTx audio engine")
  local warn = panel:Help(
    "WARNING: engine internals. Only change these if you know what you are doing - " ..
    "wrong values can silence or break all NTx audio. Use \"Restore engine defaults\" below to undo.")
  if IsValid(warn) then
    if warn.SetTextColor then warn:SetTextColor(Color(200, 60, 60)) end
    -- Breathing room under the warning: Help's stock 8 px bottom margin puts
    -- the backend/probe line right against it. The label sits inside a
    -- DSizeToContents wrapper, so that wrapper has to re-measure too.
    warn:DockMargin(8, 0, 8, 20)
    local wParent = warn:GetParent()
    if IsValid(wParent) then wParent:InvalidateLayout(true) end
  end
  panel:ControlHelp("Active backend: " .. backend
    .. "   |   probe: " .. tostring(NTx.WebAudioDetail or "not run"))

  for _, opt in ipairs(ENGINE) do
    local name, kind, help = opt[1], opt[2], opt[3]
    local cv = cvOf(name)
    if not cv then
      panel:ControlHelp(name .. " (unavailable)")
    elseif kind == "check" then
      panel:CheckBox(help, name)
    elseif kind == "combo" then
      addConvarCombo(panel, name, help, opt[7])
    else
      panel:NumSlider(help, name, opt[4] or 0, opt[5] or 100, opt[6] == nil and 2 or opt[6])
    end
  end

  panel:Help("Server-controlled")
  for name, label in pairs(SERVER_OWNED) do
    local cv = cvOf(name)
    panel:ControlHelp(label .. ": " .. (cv and cv:GetString() or "(not ready)"))
  end

  panel:Help("Diagnostics")
  panel:Button("Run WebAudio probe", "ntx_audio_probe")
  panel:Button("Print audio status", "ntx_audio_status")
  panel:Button("Resume suspended browser audio", "ntx_audio_resume")
  panel:Button("Restore engine defaults", "ntx_engine_reset")
end

local function build(panel)
  -- A throw here would leave the Utilities panel blank (it was just cleared).
  local ok, err = pcall(buildContents, panel)
  if not ok then
    print("[NTx] engine panel build failed: " .. tostring(err))
    local lbl = vgui.Create("DLabel", panel)
    lbl:Dock(TOP)
    lbl:SetWrap(true)
    lbl:SetTall(60)
    lbl:SetText("NTx engine panel failed to build:\n" .. tostring(err))
  end
end

-- The engine options live in the spawnmenu Utilities tab only: no standalone
-- window, no console command. The option name is just a spawnmenu identity.
hook.Add("PopulateToolMenu", "NTx.EngineUtilities", function()
  spawnmenu.AddToolMenuOption("Utilities", "NTx Audio", "ntx_engine",
    "NTx audio engine",
    "", "", build, {})
end)

-- Restore every client-owned engine ConVar on this page to its default.
-- Server-owned values are reported, not written, so they are skipped.
-- Also repairs a ntx_backend poisoned with a non-choice value (the old
-- dropdown wrote a literal "nil", which archived client-side and pinned
-- the rig to BASS even after the dropdown was fixed).
concommand.Add("ntx_engine_reset", function()
  local n = 0
  for _, opt in ipairs(ENGINE) do
    local cv = cvOf(opt[1])
    if cv then
      local ok = pcall(function() cv:Revert() end)
      if not ok then pcall(function() cv:SetString(cv:GetDefault()) end) end
      n = n + 1
    end
  end
  local be = cvOf("ntx_backend")
  if be and be:GetString() ~= "auto" and be:GetString() ~= "webaudio" and be:GetString() ~= "bass" then
    print("[NTx] ntx_backend was poisoned (" .. be:GetString() .. "); reverting to auto")
    local ok = pcall(function() be:Revert() end)
    if not ok then pcall(function() be:SetString("auto") end) end
  end
  print("[NTx] engine options restored to defaults (" .. n .. " convars)")
end)
