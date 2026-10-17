TOOL.Category = "Construction"
TOOL.Name = "#tool.ntx_audio.name"
TOOL.Command = nil
TOOL.ConfigName = ""

TOOL.ClientConVar["arrayid"] = "A"
TOOL.ClientConVar["stype"] = "MID"
TOOL.ClientConVar["selfcard"] = "0"
TOOL.ClientConVar["reversed"] = "0"
TOOL.ClientConVar["hifov"] = "152"
TOOL.ClientConVar["vifov"] = "57"
TOOL.ClientConVar["inivol"] = "1"
TOOL.ClientConVar["inimaxd"] = "1200"
TOOL.ClientConVar["bustrim"] = "1"
TOOL.ClientConVar["buslabel"] = ""
TOOL.ClientConVar["busflat"] = "0"
TOOL.ClientConVar["url"] = "https://radio.plaza.one/mp3"
-- Amplifier
TOOL.ClientConVar["ampprofile"] = "cdi1000"
TOOL.ClientConVar["ampmode"] = "0"
TOOL.ClientConVar["amphiz"] = "0"
TOOL.ClientConVar["ampchans"] = "2"
TOOL.ClientConVar["amptrim"] = "0"
TOOL.ClientConVar["ampratedw"] = "500"
TOOL.ClientConVar["ampminz"] = "2"
TOOL.ClientConVar["ampsens"] = "1.4"
TOOL.ClientConVar["ampilime"] = "19"
TOOL.ClientConVar["ampmeters"] = "2"
TOOL.ClientConVar["ampcrest"] = "12"
TOOL.ClientConVar["ampthbias"] = "1"
TOOL.ClientConVar["ampfault"] = "none"
-- Cabinet
TOOL.ClientConVar["spkprofile"] = "pa15"
TOOL.ClientConVar["spkimp"] = "8"
TOOL.ClientConVar["spkrmsw"] = "500"
TOOL.ClientConVar["spkpeakw"] = "1000"
TOOL.ClientConVar["spkminampw"] = "350"
TOOL.ClientConVar["spktapv"] = "0"
TOOL.ClientConVar["spkseries"] = "0"
TOOL.ClientConVar["spkactive"] = "0"
TOOL.ClientConVar["spkampch"] = "0"

local function isNtx(ent)
  return IsValid(ent) and (ent:GetClass() == "ntx_mixer" or ent:GetClass() == "ntx_speaker"
    or ent:GetClass() == "ntx_fallback_bus" or ent:GetClass() == "ntx_input_url"
    or ent:GetClass() == "ntx_amplifier")
end

-- Right-click on an amplifier with alt held injects a fault instead of applying
-- the panel. Testing a thermal or DC path otherwise means waiting for the rig to
-- cook itself, which takes real minutes.
local function altHeld(ply)
  return ply:KeyDown(KEY_LALT) or ply:KeyDown(KEY_RALT)
end

-- Left: link input/cabinet -> mixer, or cabinet -> amplifier. First click selects
-- the source, second selects the destination.
function TOOL:LeftClick(tr)
  if CLIENT then return true end
  local ply = self:GetOwner()
  local ent = tr.Entity
  if not isNtx(ent) then return false end
  local src = ply:GetNWEntity("NtxSrc")

  -- Amplifier as the destination: either a cabinet -> amplifier link, or a
  -- mixer, which opens the per-channel bus picker instead of silently linking.
  -- What each output drives decides which bus the amplifier reads for its level,
  -- so that choice has to be made by the player.
  if ent:GetClass() == "ntx_amplifier" and IsValid(src) and src ~= ent then
    if src:GetClass() == "ntx_mixer" then
      if not NTx.CanEditRig(ply, ent) then
        ply:ChatPrint("[NTx] You do not own that amplifier.")
        return false
      end
      ply:ConCommand("ntx_amp_patch " .. ent:EntIndex() .. " " .. src:EntIndex())
      ply:SetNWEntity("NtxSrc", NULL)
      return true
    end
    if src:GetClass() == "ntx_speaker" then
      if src:GetActive() then
        ply:ChatPrint("[NTx] That cabinet is self-powered (ACTIVE): no amplifier in its chain.")
        ply:SetNWEntity("NtxSrc", NULL)
        return true
      end
      local ch = self:GetClientNumber("spkampch", 0)
      local ok, why = NTx.LinkSpeakerToAmp(ply, src, ent, ch)
      if ok then
        ply:ChatPrint("[NTx] Cabinet " .. src:EntIndex() .. " -> amplifier "
          .. ent:EntIndex() .. " ch" .. ch .. " (" .. NTx.SpkOhmText(src) .. ").")
      elseif why == "bus" then
        ply:ChatPrint("[NTx] That channel is patched for "
          .. (ent:ChannelIsSub(ch) and "SUB" or "MID") .. " and the cabinet is "
          .. src:GetSpeakerType() .. ". Patch the amplifier to a mixer first.")
      end
      ply:SetNWEntity("NtxSrc", NULL)
      return true
    end
    if NTx.LinkToMixer(ply, src, ent) then
      ply:ChatPrint("[NTx] Linked " .. src:GetClass() .. " -> mixer.")
      ply:SetNWEntity("NtxSrc", NULL)
      return true
    end
    return false
  end

  if ent:GetClass() == "ntx_mixer" and IsValid(src) and src ~= ent then
    if NTx.LinkToMixer(ply, src, ent) then
      ply:ChatPrint("[NTx] Linked " .. src:GetClass() .. " -> mixer.")
      ply:SetNWEntity("NtxSrc", NULL)
      return true
    end
    return false
  end

  if ent:GetClass() == "ntx_mixer" then
    -- Clicked mixer with no source: open its UI.
    ply:ConCommand("ntx_open_mixer " .. ent:EntIndex())
    return true
  end

  if ent:GetClass() == "ntx_amplifier" then
    -- Clicked an amplifier with no pending source: open its own panel.
    ply:ConCommand("ntx_open_amp " .. ent:EntIndex())
    return true
  end

  if ent:GetClass() == "ntx_speaker" and IsValid(ent:GetAmp()) then
    ply:ConCommand("ntx_open_cabinet " .. ent:EntIndex())
    return true
  end

  ply:SetNWEntity("NtxSrc", ent)
  ply:ChatPrint("[NTx] Source selected. Click a mixer or an amplifier to link.")
  return true
end

-- Right: apply the panel's settings to the aimed entity. Every build option
-- lives in the control panel, so right-click is the single "apply" verb for
-- every entity type. Alt+right on an amplifier injects a fault instead.
function TOOL:RightClick(tr)
  if CLIENT then return true end
  local ply = self:GetOwner()
  local ent = tr.Entity
  if not isNtx(ent) then return false end
  local cls = ent:GetClass()
  local applied = {}

  if cls == "ntx_amplifier" and altHeld(ply) then
    local fault = string.lower(self:GetClientInfo("ampfault") or "none")
    NTx.AmpInjectFault(ent, fault)
    ply:ChatPrint("[NTx] Amplifier fault injected: " .. fault .. " (set back to 'none' to clear).")
    return true
  end

  if cls == "ntx_speaker" then
    local st = string.upper(self:GetClientInfo("stype"))
    if NTx.IsSpeakerType(st) then ent:SetSpeakerType(st) end
    ent:SetArrayId(string.sub(self:GetClientInfo("arrayid"), 1, 32))
    ent:SetSelfCardioid(self:GetClientNumber("selfcard", 0) ~= 0)
    ent:SetReversed(self:GetClientNumber("reversed", 0) ~= 0)
    ent:SetMidHFov(math.Clamp(self:GetClientNumber("hifov", 152), 5, 360))
    ent:SetMidVFov(math.Clamp(self:GetClientNumber("vifov", 57), 5, 360))
    -- Electrical patch. The profile stamps the whole set at once; the numeric
    -- fields below then override it, so "pick a cabinet then fine-tune it"
    -- works without needing a saved profile first.
    local prof = NTx.SpeakerProfileById(self:GetClientInfo("spkprofile"))
    if prof then ent:ApplySpeakerProfile(prof.id) end
    if NTx.IsSpeakerType(st) then ent:SetSpeakerType(st) end
    ent:SetImpedance(math.Clamp(self:GetClientNumber("spkimp", 8), 0.1, 100000))
    ent:SetRmsW(math.Clamp(self:GetClientNumber("spkrmsw", 500), 0, 100000))
    ent:SetPeakW(math.Clamp(self:GetClientNumber("spkpeakw", 1000), 0, 200000))
    ent:SetMinAmpW(math.Clamp(self:GetClientNumber("spkminampw", 350), 0, 100000))
    ent:SetTapVolt(math.Clamp(math.floor(self:GetClientNumber("spktapv", 0)), 0, 240))
    ent:SetSeriesGroup(math.Clamp(math.floor(self:GetClientNumber("spkseries", 0)), 0, 8))
    ent:SetActive(self:GetClientNumber("spkactive", 0) ~= 0)
    ent:SetAmpChannel(math.Clamp(math.floor(self:GetClientNumber("spkampch", 0)), 0, 8))
    applied[#applied + 1] = ent:GetSpeakerType() .. " [" .. ent:GetArrayId() .. "]"
      .. (ent:GetReversed() and " REV" or "")
      .. (ent:GetSelfCardioid() and " SC" or "")
      .. string.format(" FOV %dx%d", math.Round(ent:GetMidHFov()), math.Round(ent:GetMidVFov()))
      .. string.format(" / %s%s", NTx.SpkOhmText(ent), ent:GetActive() and " ACTIVE" or "")
      .. string.format(" %d/%d W", math.Round(ent:GetRmsW()), math.Round(ent:GetPeakW()))
  elseif cls == "ntx_amplifier" then
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
    applied[#applied + 1] = ent:GetProfile() .. string.format(" %dch %dW %s",
      ent:GetChannels(), math.Round(ent:GetRatedW()),
      (ent:GetMode() == 0 and "dual" or (ent:GetMode() == 1 and "bridge" or "parallel")))
  elseif cls == "ntx_input_url" then
    local url = string.sub(self:GetClientInfo("url"), 1, 512)
    if url ~= "" then ent:SetStreamUrl(url) end
    ent:SetInputVolume(NTx.ClampFader(self:GetClientNumber("inivol", 1)))
    ent:SetMaxDist(math.Clamp(self:GetClientNumber("inimaxd", 1200), 100, 10000))
    applied[#applied + 1] = string.format("vol %.2f, maxd %d",
      ent:GetInputVolume(), math.Round(ent:GetMaxDist()))
  elseif cls == "ntx_fallback_bus" then
    ent:SetTrim(NTx.ClampFader(self:GetClientNumber("bustrim", 1)))
    ent:SetBusLabel(string.sub(self:GetClientInfo("buslabel"), 1, 32))
    local flat = self:GetClientNumber("busflat", 0) ~= 0
    local was = ent:GetFlat2D()
    ent:SetFlat2D(flat)
    applied[#applied + 1] = string.format("trim %.2f, %s%s", ent:GetTrim(),
      ent:GetFlat2D() and "2D stereo" or "3D positional",
      (flat ~= was) and " (changed)" or "")
  end

  NTx.BroadcastGraph()
  if #applied > 0 then ply:ChatPrint("[NTx] " .. cls .. ": " .. table.concat(applied, " / ")) end
  return true
end

-- Reload: unlink, flip speaker polarity, or (alt) clear an amplifier's faults.
function TOOL:Reload(tr)
  if CLIENT then return true end
  local ent = tr.Entity
  if not isNtx(ent) then return false end
  local ply = self:GetOwner()
  if ent:GetClass() == "ntx_amplifier" then
    if altHeld(ply) then
      NTx.AmpInjectFault(ent, "none")
      ent:SetClipLatch(false)
      ent:SetPower(true)
      ent:SetFanOn(true)
      ply:ChatPrint("[NTx] Amplifier faults cleared (repair in progress).")
    else
      ply:ConCommand("ntx_open_amp " .. ent:EntIndex())
    end
    return true
  end
  if ent:GetClass() == "ntx_speaker" then
    if altHeld(ply) and IsValid(ent:GetAmp()) then
      ent:SetAmp(NULL)
      ent:SetAmpChannel(0)
      ply:ChatPrint("[NTx] Cabinet unlinked from its amplifier.")
    else
      ent:SetReversed(not ent:GetReversed())
      ply:ChatPrint("[NTx] Speaker polarity reversed = " .. tostring(ent:GetReversed()))
    end
  elseif IsValid(ent:GetMixer()) then
    local mixer = ent:GetMixer()
    ent:SetMixer(NULL)
    if mixer.RemoveChannel then mixer:RemoveChannel(ent) end
  end
  NTx.BroadcastGraph()
  return true
end

-- Convar-bound dropdown.
--
-- AddControl("ComboBox", {MenuButton = 1}) does NOT build a value dropdown:
-- ControlPanel:AddControl hands that case to a ControlPresets widget - a
-- preset picker labelled "Presets" that never shows the current value (so a
-- saved choice looks lost) and whose + button writes a preset FILE rather than
-- the convar.
--
-- DForm:ComboBox is the real control: it builds the label/combo row through the
-- same DForm layout as every other row here (same padding, same 100 px label
-- column), binds the combo to the convar and writes the choice back on select.
--
-- `data` is passed per choice because DComboBox:GetOptionTextByData maps a
-- convar string back to a label through that table; a choice added without data
-- always resolves to the first option.
--
-- Labels stay within DForm's 100 px column ("Self-cardioid" is the longest
-- word that fits) or the text runs under the combo box.
local function dropdown(panel, label, convar, choices)
  local right = panel:ComboBox(label, convar)
  -- DForm leaves the combo at its stock 22 px, which reads cramped between
  -- the taller rows above and below it.
  right:SetTall(26)
  local current = GetConVarString(convar)
  local shown = current
  for _, ch in ipairs(choices) do
    right:AddChoice(ch[1], ch[2])
    if tostring(ch[2]) == current then shown = ch[1] end
  end
  -- DComboBox:Think resyncs the text from the convar, but only on the next
  -- frame; set it here so the row never opens on the wrong label.
  right:SetValue(shown)
  return right
end

-- Note: dot syntax (static). The spawnmenu calls this as TOOL.BuildCPanel(panel);
-- a colon definition would bind the panel to self and leave panel nil.
-- All build options live here; right-click applies the matching set to the
-- entity you aim at. The STOOL panel has no ControlLabel method, so section
-- headings use AddControl("Label", { Text = ... }).
function TOOL.BuildCPanel(panel)
  panel:AddControl("Header", { Description = "#tool.ntx_audio.desc" })
  panel:AddControl("Label", { Text = "LINKING" })
  panel:AddControl("Label", {
    Text = "Left-click: source, then mixer / amplifier (click a mixer or amplifier on its own to open its UI).\nReload: unlink / flip cardioid polarity.\nAlt+right-click an amplifier: inject a fault. Alt+reload: clear faults.",
  })

  panel:AddControl("Label", { Text = "INPUT  (right-click a ntx_input_url)" })
  panel:AddControl("TextBox", { Label = "Stream URL", Command = "ntx_audio_url" })
  panel:AddControl("Slider", {
    Label = "Input volume (0-2)", Command = "ntx_audio_inivol",
    Min = 0, Max = 2, Default = 1, Decimals = 2,
  })
  panel:AddControl("Slider", {
    Label = "Max distance (units)", Command = "ntx_audio_inimaxd",
    Min = 100, Max = 10000, Default = 1200, Decimals = 0,
  })

  panel:AddControl("Label", { Text = "CABINET  (right-click a ntx_speaker)" })
  -- Profile dropdown: built from the live profile list, saved ones included, so
  -- a box saved by someone else shows up here without a client restart.
  local spkCombo = panel:ComboBox("Cabinet profile", "ntx_audio_spkprofile")
  spkCombo:SetTall(26)
  for _, p in ipairs(NTx.AllSpeakerProfiles()) do
    spkCombo:AddChoice(p.name .. (p.saved and " *" or ""), p.id)
  end
  spkCombo:SetValue(GetConVarString("ntx_audio_spkprofile"))
  panel:AddControl("Label", {
    Text = "Power/ohms follow the profile; the sliders below then override them. Save a box you like with ntx_spk_save <name>.",
  })
  panel:AddControl("Slider", {
    Label = "Impedance (ohm)", Command = "ntx_audio_spkimp", Min = 0.5, Max = 1000,
    Default = 8, Decimals = 1,
  })
  panel:AddControl("Slider", {
    Label = "RMS power (W)", Command = "ntx_audio_spkrmsw", Min = 5, Max = 5000,
    Default = 500, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "Peak power (W)", Command = "ntx_audio_spkpeakw", Min = 10, Max = 10000,
    Default = 1000, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "Min amp watts", Command = "ntx_audio_spkminampw", Min = 0, Max = 3000,
    Default = 350, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "Series group (0-8)", Command = "ntx_audio_spkseries", Min = 0, Max = 8,
    Default = 0, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "Amp channel (0 = auto)", Command = "ntx_audio_spkampch", Min = 0, Max = 8,
    Default = 0, Decimals = 0,
  })
  dropdown(panel, "Hi-Z tap", "ntx_audio_spktapv", {
    { "low-Z", "0" }, { "70 V", "70" }, { "100 V", "100" },
  })
  dropdown(panel, "Self-powered", "ntx_audio_spkactive", {
    { "Passive (amp driven)", "0" }, { "ACTIVE (no simulation)", "1" },
  })
  panel:AddControl("Label", { Text = "CABINET PLACEMENT" })
  dropdown(panel, "Speaker type", "ntx_audio_stype", {
    { "MID", "MID" }, { "SUB", "SUB" },
  })
  panel:AddControl("TextBox", { Label = "Array ID", Command = "ntx_audio_arrayid" })
  dropdown(panel, "Self-cardioid", "ntx_audio_selfcard", {
    { "Off", "0" }, { "On", "1" },
  })
  dropdown(panel, "Rear polarity", "ntx_audio_reversed", {
    { "Normal", "0" }, { "Reversed", "1" },
  })
  panel:AddControl("Slider", {
    Label = "MID H-FOV (deg)", Command = "ntx_audio_hifov", Min = 5, Max = 360,
    Default = 152, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "MID V-FOV (deg)", Command = "ntx_audio_vifov", Min = 5, Max = 360,
    Default = 57, Decimals = 0,
  })

  panel:AddControl("Label", { Text = "AMPLIFIER  (right-click a ntx_amplifier)" })
  local ampCombo = panel:ComboBox("Amplifier model", "ntx_audio_ampprofile")
  ampCombo:SetTall(26)
  for _, id in ipairs(NTx.AmpProfileIds()) do
    ampCombo:AddChoice(NTx.AmpProfile(id).name, id)
  end
  ampCombo:SetValue(GetConVarString("ntx_audio_ampprofile"))
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
    Text = "FAULT INJECTION (alt+right-click applies)",
  })
  dropdown(panel, "Injected fault", "ntx_audio_ampfault", {
    { "none", "none" }, { "brownout", "brownout" }, { "overvoltage", "overvoltage" },
    { "DC offset", "dc" }, { "short circuit", "short" },
    { "thermal (fan off)", "thermal" }, { "kill", "kill" },
  })

  panel:AddControl("Label", { Text = "FALLBACK BUS  (right-click a ntx_fallback_bus)" })
  panel:AddControl("Slider", {
    Label = "Bus trim (0-2)", Command = "ntx_audio_bustrim", Min = 0, Max = 2,
    Default = 1, Decimals = 2,
  })
  panel:AddControl("TextBox", { Label = "Bus label", Command = "ntx_audio_buslabel" })
  dropdown(panel, "Bus playback", "ntx_audio_busflat", {
    { "3D positional", "0" }, { "2D stereo", "1" },
  })

  panel:AddControl("Label", { Text = "GIZMOS (owner-only: other players never see them)" })
  panel:AddControl("CheckBox", {
    Label = "Speaker gizmos (up + front arrows, labels)",
    Command = "ntx_gizmo_speakers",
  })
  panel:AddControl("CheckBox", {
    Label = "Coverage cones (H/V FOV outlines)",
    Command = "ntx_gizmo_cones",
  })
  panel:AddControl("CheckBox", {
    Label = "Link lines (input / mixer / speaker / amplifier wiring)",
    Command = "ntx_gizmo_links",
  })
  panel:AddControl("CheckBox", {
    Label = "Amplifier front panels (signal / clip / protect LEDs)",
    Command = "ntx_gizmo_amp",
  })
end

if CLIENT then
  language.Add("tool.ntx_audio.name", "NTx Audio")
  language.Add("tool.ntx_audio.desc", "Link live inputs, cabinets and amplifiers to mixers.")
  language.Add("tool.ntx_audio.left", "Select source / link to mixer or amplifier / open its UI")
  language.Add("tool.ntx_audio.right", "Apply panel settings to the aimed entity (alt: inject a fault)")
  language.Add("tool.ntx_audio.reload", "Unlink, flip polarity, or (alt) clear faults")
end

TOOL.Information = { { name = "left" }, { name = "right" }, { name = "reload" } }
