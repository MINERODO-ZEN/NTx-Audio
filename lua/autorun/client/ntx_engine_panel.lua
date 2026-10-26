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
  { "ntx_mute_distance", "slider", "BASS hard-mute range (units)", 100, 100000, 0 },
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
  ntx_update_hz = "Graph rebroadcast cap (Hz)",
  ntx_amp_sim_hz = "Amplifier simulation rate (Hz)",
  ntx_meter_hz = "Meter rate (Hz)",
  ntx_signal_hz = "Signal chain rate (Hz)",
  ntx_amp_rms_send = "Send measured levels to the server (0 = off)",
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

-- ------------------------------------------------------- amplifier options
--
-- Its own Utilities page, deliberately separate from the engine page: the engine
-- toggles stay exactly where they were, and everything about amplifiers lives
-- together here - the simulation switches, the server-owned rig parameters, the
-- cabinet profile store and the diagnostics.
--
-- What differs between one amplifier and the next is NOT here: PFC,
-- fan noise, standby and the thermal limiter are per-amplifier fields (see
-- NTx.AmpFields), editable from the amplifier's own panel, the properties window
-- or the tool. A car amplifier and a vintage class AB rack share this page and
-- nothing else.
local function sendCvar(name, value, isBool)
  net.Start("NTx.CvarSet")
  net.WriteString(name)
  if isBool then net.WriteBool(value and true or false) else net.WriteFloat(value) end
  net.SendToServer()
end

local function sendAll(what)
  net.Start("NTx.AmplifierEditAll")
  net.WriteString(what)
  net.SendToServer()
end

-- The simulation switches live on the server (they decide what every player
-- hears), so these rows do NOT use DForm's convar-bound controls: a client
-- writing a replicated ConVar only changes its own copy, and the checkbox would
-- then show a setting the server is ignoring.
local function serverCheck(panel, text, name)
  local left = vgui.Create("DLabel", panel)
  left:SetText(text)
  left:SetDark(true)
  local right = vgui.Create("DCheckBox", panel)
  local cv = cvOf(name)
  right:SetValue(cv and cv:GetBool() or false)
  right.OnChange = function(_, v) sendCvar(name, v, true) end
  panel:AddItem(left, right)
end

local function serverSlider(panel, text, name, min, max, dec)
  local left = vgui.Create("DLabel", panel)
  left:SetText(text)
  left:SetDark(true)
  local right = vgui.Create("DNumSlider", panel)
  local cv = cvOf(name)
  right:SetMinMax(min, max)
  right:SetDecimals(dec)
  right:SetValue(cv and cv:GetFloat() or min)
  right.OnValueChanged = function(_, v) sendCvar(name, v) end
  panel:AddItem(left, right)
end

local function buildAmpContents(panel)
  panel:Clear()

  panel:Help("NTx amplifier simulation")
  local sim = cvOf("ntx_amp_sim")
  panel:ControlHelp("Simulation is " .. (sim and sim:GetBool() and "RUNNING" or "OFF")
    .. ". Amplifiers keep passing audio either way; with it off they are just"
    .. " boxes and nothing heats up, clips, protects or dies.")
  serverCheck(panel, "Run the amplifier simulation", "ntx_amp_sim")
  serverCheck(panel, "Amplifiers take permanent damage and can burn out", "ntx_amp_damage")
  serverCheck(panel, "Cabinets take damage and can blow", "ntx_spk_damage")
  panel:CheckBox("Panel LEDs on (off leaves the simulation running)", "ntx_amp_leds")
  panel:CheckBox("Print the amplifier table every 2 s", "ntx_amp_debug")

  panel:Help("Rig parameters (server)")
  panel:ControlHelp("Read by the simulation on the server, so these are shared by everyone.")
  serverSlider(panel, "Crest factor, RMS to peak (dB)", "ntx_crest_db", 0, 30, 1)
  serverSlider(panel, "Nominal mains voltage (V)", "ntx_mains_nominal", 90, 260, 0)
  serverSlider(panel, "Room temperature (C)", "ntx_ambient_c", -10, 45, 0)
  serverSlider(panel, "Amplifier sync rate (Hz)", "ntx_amp_sync_hz", 1, 20, 0)
  serverSlider(panel, "Amplifier sync radius (units)", "ntx_amp_sync_dist", 0, 20000, 0)
  panel:ControlHelp("With nothing wired to an amplifier's MainsV it reads the nominal"
    .. " voltage above. Wire a number pad or an E2 to MainsV for a venue-wide brownout.")
  panel:NumSlider("Fallback meter level without page RMS (dBFS)", "ntx_amp_rms_db", -90, -20, 0)

  panel:Help("Cabinet profiles")
  panel:ControlHelp("Built in: " .. table.concat(NTx.SpeakerProfileIds(), ", "))
  local savedIds = {}
  for id in pairs(NTx.SavedSpeakerProfiles or {}) do savedIds[#savedIds + 1] = id end
  table.sort(savedIds)
  if #savedIds == 0 then
    panel:ControlHelp("No saved profiles yet: aim at a cabinet and run ntx_spk_save <name>.")
  end
  for _, id in ipairs(savedIds) do
    local p = NTx.SavedSpeakerProfiles[id]
    local left = vgui.Create("DLabel", panel)
    left:SetText(string.format("%s (%s)", p.name, id))
    left:SetDark(true)
    local del = vgui.Create("DButton", panel)
    del:SetText("Delete")
    del.DoClick = function()
      -- The profiles are the client's own; the server never had a copy.
      NTx.DeleteSpeakerProfile(id)
    end
    panel:AddItem(left, del)
  end
  panel:ControlHelp("Aim at a ntx_speaker, then: ntx_spk_save <name> / ntx_spk_apply <id>.")

  panel:Help("Diagnostics")
  panel:Button("Print amplifier status", "ntx_amp_status")
  panel:Button("List cabinet profiles", "ntx_spk_list")
  panel:Button("Clear every clip LED and fault", function() sendAll("reset") end)
  panel:Button("Restore fans and mains on every amp", function() sendAll("cool") end)
end

local function buildAmp(panel)
  local ok, err = pcall(buildAmpContents, panel)
  if not ok then
    print("[NTx] amplifier panel build failed: " .. tostring(err))
    local lbl = vgui.Create("DLabel", panel)
    lbl:Dock(TOP)
    lbl:SetWrap(true)
    lbl:SetTall(60)
    lbl:SetText("NTx amplifier panel failed to build:\n" .. tostring(err))
  end
end

hook.Add("PopulateToolMenu", "NTx.AmplifierUtilities", function()
  spawnmenu.AddToolMenuOption("Utilities", "NTx Amplifiers", "ntx_amplifiers",
    "Amplifier simulation, rig parameters and cabinet profiles",
    "", "", buildAmp, {})
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
