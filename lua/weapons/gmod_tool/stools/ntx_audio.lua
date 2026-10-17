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

local function isNtx(ent)
  return IsValid(ent) and (ent:GetClass() == "ntx_mixer" or ent:GetClass() == "ntx_speaker"
    or ent:GetClass() == "ntx_fallback_bus" or ent:GetClass() == "ntx_input_url")
end

-- Left: link input/speaker -> mixer. First click selects source, second selects mixer.
function TOOL:LeftClick(tr)
  if CLIENT then return true end
  local ply = self:GetOwner()
  local ent = tr.Entity
  if not isNtx(ent) then return false end

  if ent:GetClass() == "ntx_mixer" and IsValid(ply:GetNWEntity("NtxSrc")) then
    local src = ply:GetNWEntity("NtxSrc")
    if isNtx(src) and src ~= ent then
      if NTx.LinkToMixer(ply, src, ent) then
        ply:ChatPrint("[NTx] Linked " .. src:GetClass() .. " -> mixer.")
        ply:SetNWEntity("NtxSrc", NULL)
        return true
      end
      return false
    end
  end

  if ent:GetClass() ~= "ntx_mixer" then
    ply:SetNWEntity("NtxSrc", ent)
    ply:ChatPrint("[NTx] Source selected. Click a mixer to link.")
    return true
  end

  -- Clicked mixer with no source: open its UI.
  ply:ConCommand("ntx_open_mixer " .. ent:EntIndex())
  return true
end

-- Right: apply the panel's settings to the aimed entity. Every build option
-- lives in the control panel, so right-click is the single "apply" verb for
-- all four entity types.
function TOOL:RightClick(tr)
  if CLIENT then return true end
  local ply = self:GetOwner()
  local ent = tr.Entity
  if not isNtx(ent) then return false end
  local cls = ent:GetClass()
  local applied = {}

  if cls == "ntx_speaker" then
    local st = string.upper(self:GetClientInfo("stype"))
    if NTx.IsSpeakerType(st) then ent:SetSpeakerType(st) end
    ent:SetArrayId(string.sub(self:GetClientInfo("arrayid"), 1, 32))
    ent:SetSelfCardioid(self:GetClientNumber("selfcard", 0) ~= 0)
    ent:SetReversed(self:GetClientNumber("reversed", 0) ~= 0)
    ent:SetMidHFov(math.Clamp(self:GetClientNumber("hifov", 152), 5, 360))
    ent:SetMidVFov(math.Clamp(self:GetClientNumber("vifov", 57), 5, 360))
    applied[#applied + 1] = ent:GetSpeakerType() .. " [" .. ent:GetArrayId() .. "]"
      .. (ent:GetReversed() and " REV" or "")
      .. (ent:GetSelfCardioid() and " SC" or "")
      .. string.format(" FOV %dx%d", math.Round(ent:GetMidHFov()), math.Round(ent:GetMidVFov()))
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

-- Reload: unlink, or toggle speaker polarity (for cardioid rear box).
function TOOL:Reload(tr)
  if CLIENT then return true end
  local ent = tr.Entity
  if not isNtx(ent) then return false end
  if ent:GetClass() == "ntx_speaker" then
    ent:SetReversed(not ent:GetReversed())
    self:GetOwner():ChatPrint("[NTx] Speaker polarity reversed = " .. tostring(ent:GetReversed()))
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
    Text = "Left-click: source, then mixer (or click mixer to open its live UI).\nReload: unlink / flip cardioid polarity.",
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

  panel:AddControl("Label", { Text = "SPEAKER  (right-click a ntx_speaker)" })
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
    Label = "Link lines (input / mixer / speaker wiring)",
    Command = "ntx_gizmo_links",
  })
end

if CLIENT then
  language.Add("tool.ntx_audio.name", "NTx Audio")
  language.Add("tool.ntx_audio.desc", "Link live inputs and speakers to mixers.")
  language.Add("tool.ntx_audio.left", "Select source / link to mixer / open mixer UI")
  language.Add("tool.ntx_audio.right", "Apply panel settings to the aimed input / speaker / bus")
  language.Add("tool.ntx_audio.reload", "Unlink or flip cardioid polarity")
end

TOOL.Information = { { name = "left" }, { name = "right" }, { name = "reload" } }
