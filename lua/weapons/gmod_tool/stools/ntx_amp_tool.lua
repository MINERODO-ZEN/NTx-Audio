-- Tool: NTx Amplifier.
--
-- Amplifier settings only. One verb per job:
--   left-click    select / link (shared with the other two tools, so the rig can
--                 be wired whatever is in your hands). Shift-click opens the
--                 panel of ANY NTx entity aimed at, including mixers and cabinets
--   right-click   apply the settings from this panel onto the amplifier
--   reload        clear faults and revive it (power, fan, no fault)
TOOL.Category = "NTx"
TOOL.Name = "#tool.ntx_amp_tool.name"
TOOL.Command = nil
TOOL.ConfigName = ""

TOOL.ClientConVar["ampprofile"] = "cdi1000"
TOOL.ClientConVar["ampchans"] = "2"
TOOL.ClientConVar["ampratedw"] = "500"
TOOL.ClientConVar["ampminz"] = "2"
TOOL.ClientConVar["ampsens"] = "1.4"
TOOL.ClientConVar["amptrim"] = "0"
TOOL.ClientConVar["ampilime"] = "19"
TOOL.ClientConVar["ampmode"] = "0"
TOOL.ClientConVar["amphiz"] = "0"
TOOL.ClientConVar["ampmeters"] = "2"
TOOL.ClientConVar["ampcrest"] = "12"
TOOL.ClientConVar["ampthbias"] = "1"

-- The tool system creates one client convar per ClientConVar entry, named
-- "<tool class>_<key>" (sandbox/entities/weapons/gmod_tool/stool.lua). The
-- panel controls have to bind to that exact name: DForm rows run
-- RunConsoleCommand on whatever they were given, so a bare key is just an
-- "Unknown command" every time a slider moves. The server side still asks for
-- the bare key, because GetClientInfo("ampchans") resolves it from the table.
local function cv(key)
  return "ntx_amp_tool_" .. key
end

-- Left-click: link/select only, via the shared gesture in ntx_net.lua. Shift-
-- click opens the panel of whatever NTx entity is aimed at, whichever tool is
-- held.
function TOOL:LeftClick(tr)
  if CLIENT then return true end
  local ply = self:GetOwner()
  local ent = tr.Entity
  -- Left click opens the panel. It used to be shift-click to open and plain
  -- click to link; wiring moved to the stock wire tool, so the gesture is gone
  -- and there is nothing left for a plain click to do but open the panel.
  print("[NTX DBG] LeftClick " .. (IsValid(ent) and ent:GetClass() .. ":" .. ent:EntIndex() or "nil"))
  return NTx.OpenEntityGui(ply, ent)
end

-- Right-click: stamp this panel's settings onto the aimed amplifier. Choosing a
-- model first stamps its published power, sensitivity, PFC, thermal limits and
-- meter layout; the numeric fields then override it, so "pick a model, then
-- fine-tune" works in one click.
function TOOL:RightClick(tr)
  if CLIENT then return true end
  local ent = tr.Entity
  if not (IsValid(ent) and ent:GetClass() == "ntx_amplifier") then return false end
  local ply = self:GetOwner()

  local prof = NTx.AmpProfile(self:GetClientInfo("ampprofile"))
  if prof then
    ent:ApplyAmpProfile(prof.id)
    NTx.AmpSimDrop(ent)
  end
  ent:SetChannels(math.Clamp(math.floor(self:GetClientNumber("ampchans", 2)), 1, 8))
  ent:SetRatedW(math.Clamp(self:GetClientNumber("ampratedw", 500), 1, 20000))
  ent:SetMinLoad(math.Clamp(self:GetClientNumber("ampminz", 2), 0.1, 100))
  ent:SetSens(math.Clamp(self:GetClientNumber("ampsens", 1.4), 0.05, 10))
  ent:SetIlime(math.Clamp(self:GetClientNumber("ampilime", 19), 1, 60))
  ent:SetTrim(math.Clamp(self:GetClientNumber("amptrim", 0), -40, 24))
  ent:SetMode(math.Clamp(math.floor(self:GetClientNumber("ampmode", 0)), 0, 2))
  ent:SetHizVolt(math.Clamp(math.floor(self:GetClientNumber("amphiz", 0)), 0, 240))
  ent:SetMeters(math.Clamp(math.floor(self:GetClientNumber("ampmeters", 2)), 0, 2))
  ent:SetCrestDb(math.Clamp(self:GetClientNumber("ampcrest", 12), 0, 30))
  ent:SetThermalBias(math.Clamp(self:GetClientNumber("ampthbias", 1), 0.4, 3))

  ply:ChatPrint("[NTx] Amplifier: " .. ent:GetProfile() .. string.format(" %dch %dW %s",
    ent:GetChannels(), math.Round(ent:GetRatedW()),
    (ent:GetMode() == 0 and "dual" or (ent:GetMode() == 1 and "bridge" or "parallel"))))
  return true
end

-- Reload: the repair click. A burnt or locked-out amplifier is not a rubbish
-- bin - this brings it back to a healthy, powered state.
function TOOL:Reload(tr)
  if CLIENT then return true end
  local ent = tr.Entity
  if not (IsValid(ent) and ent:GetClass() == "ntx_amplifier") then return false end
  NTx.AmpInjectFault(ent, "none")
  ent:SetClipLatch(false)
  ent:SetPower(true)
  ent:SetFanOn(true)
  self:GetOwner():ChatPrint("[NTx] Amplifier " .. ent:EntIndex()
    .. " repaired: faults cleared, power and fan on.")
  return true
end

-- Convar-bound dropdown.
--
-- AddControl("ComboBox", {MenuButton = 1}) does NOT build a value dropdown: it
-- hands that case to a preset picker, which never shows the current value and
-- writes a preset file from its + button. The DForm row is the real control -
-- but its ComboBox does not write the bound convar when an option is picked,
-- and RightClick reads that convar on the server, so the pick is written here.
local function dropdown(panel, label, convar, choices)
  local right = panel:ComboBox(label, convar)
  right:SetTall(26)
  local index = {}
  for i, ch in ipairs(choices) do
    right:AddChoice(ch[1], ch[2])
    index[tostring(ch[2])] = i
  end
  local cvar = GetConVar(convar)
  local current = cvar and cvar:GetString() or ""
  -- DComboBox picks by INDEX (ChooseOptionID), and ChooseOption - which it calls
  -- internally - takes the option text as its first argument, so preselecting
  -- with a raw value is what errors out. Hence the map; the
  -- preselect fires OnSelect, which is harmless because DComboBox has a no-op
  -- one until the real handler is installed below.
  right:ChooseOptionID(index[current] or 1)
  right.OnSelect = function(_, _, data)
    if cvar and cvar:GetString() ~= tostring(data or "") then cvar:SetString(tostring(data or "")) end
  end
  return right
end

-- The model list is dynamic (it grows with every profile NTx knows), so it is
-- built by hand rather than through the DForm row. Same value -> index rule as
-- the dropdown above.
local function modelPicker(panel, convar)
  local combo = vgui.Create("DComboBox", panel)
  combo:Dock(TOP)
  combo:DockMargin(4, 0, 4, 0)
  combo:SetTall(26)
  local index = {}
  for i, id in ipairs(NTx.AmpProfileIds()) do
    combo:AddChoice(NTx.AmpProfile(id).name, id)
    index[id] = i
  end
  local cvar = GetConVar(convar)
  combo:ChooseOptionID(index[cvar and cvar:GetString() or ""] or 1)
  combo.OnSelect = function(_, _, data)
    if cvar and cvar:GetString() ~= tostring(data or "") then cvar:SetString(tostring(data or "")) end
  end
  return combo
end

-- Note: dot syntax (static). The spawnmenu calls this as TOOL.BuildCPanel(panel).
function TOOL.BuildCPanel(panel)
  panel:AddControl("Header", { Description = "#tool.ntx_amp_tool.desc" })
  panel:AddControl("Label", {
    Text = "Left-click selects and links. Shift-click opens any NTx entity panel. Right-click applies the settings below. Reload clears faults and revives it.",
  })

  panel:AddControl("Label", { Text = "AMPLIFIER MODEL" })
  modelPicker(panel, cv("ampprofile"))
  panel:AddControl("Label", {
    Text = "Choosing a model stamps its published power, sensitivity, PFC, thermal limits and meter layout onto the amplifier.",
  })

  panel:AddControl("Slider", {
    Label = "Channels", Command = cv("ampchans"), Min = 1, Max = 8,
    Default = 2, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "Rated watts / channel", Command = cv("ampratedw"), Min = 10, Max = 2000,
    Default = 500, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "Min load (ohm)", Command = cv("ampminz"), Min = 0.5, Max = 32,
    Default = 2, Decimals = 1,
  })
  panel:AddControl("Slider", {
    Label = "Sensitivity (V)", Command = cv("ampsens"), Min = 0.1, Max = 5,
    Default = 1.4, Decimals = 2,
  })
  panel:AddControl("Slider", {
    Label = "Level trim (dB)", Command = cv("amptrim"), Min = -20, Max = 12,
    Default = 0, Decimals = 1,
  })
  panel:AddControl("Slider", {
    Label = "Current limit (A)", Command = cv("ampilime"), Min = 2, Max = 40,
    Default = 19, Decimals = 1,
  })
  dropdown(panel, "Output mode", cv("ampmode"), {
    { "Dual (stereo)", "0" }, { "Bridge-mono", "1" }, { "Parallel-mono", "2" },
  })
  dropdown(panel, "Output tap", cv("amphiz"), {
    { "low-Z", "0" }, { "70 V", "70" }, { "100 V", "100" },
  })
  dropdown(panel, "Front panel", cv("ampmeters"), {
    { "No meters", "0" }, { "Crown MA (IOC / ODEP)", "1" }, { "Crown CDi (3 LED)", "2" },
  })
  panel:AddControl("Slider", {
    Label = "Crest RMS to peak (dB)", Command = cv("ampcrest"), Min = 0, Max = 24,
    Default = 12, Decimals = 1,
  })
  panel:AddControl("Slider", {
    Label = "Thermal bias (x)", Command = cv("ampthbias"), Min = 0.5, Max = 2.5,
    Default = 1, Decimals = 2,
  })
  panel:AddControl("Label", {
    Text = "FAULT INJECTION lives in the amplifier panel (left-click one).",
  })
end

if CLIENT then
  language.Add("tool.ntx_amp_tool.name", "NTx Amplifier")
  language.Add("tool.ntx_amp_tool.desc", "Amplifier model, channel and protection settings")
  language.Add("tool.ntx_amp_tool.left", "Select / link the aimed entity (shift: open its panel)")
  language.Add("tool.ntx_amp_tool.right", "Apply these settings to the amplifier")
  language.Add("tool.ntx_amp_tool.reload", "Clear faults and revive the amplifier")
end

TOOL.Information = { { name = "left" }, { name = "right" }, { name = "reload" } }
