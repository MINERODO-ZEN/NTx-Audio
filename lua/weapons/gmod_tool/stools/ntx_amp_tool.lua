-- Tool: NTx Amplifier.
--
-- Amplifier-only. One verb per job:
--   left-click an amplifier    open its full panel (model picker, fault
--                              injection, live channel readout)
--   right-click an amplifier   apply the settings from this panel
--   reload on an amplifier     clear faults and revive it (power, fan, no fault)
--
-- Linking an amplifier to a mixer is the Connections tool's job; cabinet
-- settings live on the Speaker tool.
TOOL.Category = "NTx"
TOOL.Name = "#tool.ntx_amp.name"
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

-- Left-click: open the aimed amplifier's panel.
function TOOL:LeftClick(tr)
  if CLIENT then return true end
  local ent = tr.Entity
  if not (IsValid(ent) and ent:GetClass() == "ntx_amplifier") then return false end
  self:GetOwner():ConCommand("ntx_open_amp " .. ent:EntIndex())
  return true
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

-- Convar-bound dropdown. DForm's ComboBox would route this to a preset picker
-- that never shows the current value, so the row is built by hand and the
-- choice is written back to the convar on select.
local function dropdown(panel, label, convar, choices)
  local right = panel:ComboBox(label, convar)
  right:SetTall(26)
  for _, ch in ipairs(choices) do
    right:AddChoice(ch[1], ch[2])
  end
  right:SetValue(GetConVarString(convar))
  return right
end

-- Note: dot syntax (static). The spawnmenu calls this as TOOL.BuildCPanel(panel).
function TOOL.BuildCPanel(panel)
  panel:AddControl("Header", { Description = "#tool.ntx_amp.desc" })
  panel:AddControl("Label", {
    Text = "Left-click an amplifier to open its full panel. Right-click applies the settings below. Reload clears faults and revives it.",
  })

  panel:AddControl("Label", { Text = "AMPLIFIER MODEL" })
  local combo = panel:ComboBox("Model", "ntx_audio_ampprofile")
  combo:SetTall(26)
  for _, id in ipairs(NTx.AmpProfileIds()) do
    combo:AddChoice(NTx.AmpProfile(id).name, id)
  end
  combo:SetValue(GetConVarString("ntx_audio_ampprofile"))
  panel:AddControl("Label", {
    Text = "Choosing a model stamps its published power, sensitivity, PFC, thermal limits and meter layout onto the amplifier.",
  })

  panel:AddControl("Slider", {
    Label = "Channels", Command = "ntx_audio_ampchans", Min = 1, Max = 8,
    Default = 2, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "Rated watts / channel", Command = "ntx_audio_ampratedw", Min = 10, Max = 2000,
    Default = 500, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "Min load (ohm)", Command = "ntx_audio_ampminz", Min = 0.5, Max = 32,
    Default = 2, Decimals = 1,
  })
  panel:AddControl("Slider", {
    Label = "Sensitivity (V)", Command = "ntx_audio_ampsens", Min = 0.1, Max = 5,
    Default = 1.4, Decimals = 2,
  })
  panel:AddControl("Slider", {
    Label = "Level trim (dB)", Command = "ntx_audio_amptrim", Min = -20, Max = 12,
    Default = 0, Decimals = 1,
  })
  panel:AddControl("Slider", {
    Label = "Current limit (A)", Command = "ntx_audio_ampilime", Min = 2, Max = 40,
    Default = 19, Decimals = 1,
  })
  dropdown(panel, "Output mode", "ntx_audio_ampmode", {
    { "Dual (stereo)", "0" }, { "Bridge-mono", "1" }, { "Parallel-mono", "2" },
  })
  dropdown(panel, "Output tap", "ntx_audio_amphiz", {
    { "low-Z", "0" }, { "70 V", "70" }, { "100 V", "100" },
  })
  dropdown(panel, "Front panel", "ntx_audio_ampmeters", {
    { "No meters", "0" }, { "Crown MA (IOC / ODEP)", "1" }, { "Crown CDi (3 LED)", "2" },
  })
  panel:AddControl("Slider", {
    Label = "Crest RMS to peak (dB)", Command = "ntx_audio_ampcrest", Min = 0, Max = 24,
    Default = 12, Decimals = 1,
  })
  panel:AddControl("Slider", {
    Label = "Thermal bias (x)", Command = "ntx_audio_ampthbias", Min = 0.5, Max = 2.5,
    Default = 1, Decimals = 2,
  })
  panel:AddControl("Label", {
    Text = "FAULT INJECTION lives in the amplifier panel (left-click one).",
  })
end

if CLIENT then
  language.Add("tool.ntx_amp.name", "NTx Amplifier")
  language.Add("tool.ntx_amp.desc", "Amplifier model, channel and protection settings")
  language.Add("tool.ntx_amp.left", "Open the amplifier panel")
  language.Add("tool.ntx_amp.right", "Apply these settings to the amplifier")
  language.Add("tool.ntx_amp.reload", "Clear faults and revive the amplifier")
end

TOOL.Information = { { name = "left" }, { name = "right" }, { name = "reload" } }
