-- Tool: NTx Speaker.
--
-- Cabinet settings only. One verb per job:
--   left-click    select / link (shared with the other two tools). Shift-click
--                 opens the panel of ANY NTx entity aimed at
--   right-click   apply the settings from this panel to the cabinet, the profile
--                 included
--   reload        flip rear polarity (alt: unlink from its amplifier)
TOOL.Category = "NTx"
TOOL.Name = "#tool.ntx_speaker_tool.name"
TOOL.Command = nil
TOOL.ConfigName = ""

TOOL.ClientConVar["stype"] = "MID"
TOOL.ClientConVar["arrayid"] = "A"
TOOL.ClientConVar["selfcard"] = "0"
TOOL.ClientConVar["reversed"] = "0"
TOOL.ClientConVar["hifov"] = "152"
TOOL.ClientConVar["vifov"] = "57"
TOOL.ClientConVar["spkprofile"] = "pa15"
TOOL.ClientConVar["spkimp"] = "8"
TOOL.ClientConVar["spkrmsw"] = "500"
TOOL.ClientConVar["spkpeakw"] = "1000"
TOOL.ClientConVar["spkminampw"] = "350"
TOOL.ClientConVar["spktapv"] = "0"
TOOL.ClientConVar["spkactive"] = "0"
-- The panel's save row writes the name here; it is a workspace, not a setting.
TOOL.ClientConVar["spksavename"] = ""

-- The tool system creates one client convar per ClientConVar entry, named
-- "<tool class>_<key>" (sandbox/entities/weapons/gmod_tool/stool.lua). The
-- panel controls have to bind to that exact name: DForm rows run
-- RunConsoleCommand on whatever they were given, so a bare key is just an
-- "Unknown command" every time a slider moves. The server side still asks for
-- the bare key, because GetClientInfo("spkprofile") resolves it from the table.
local function cv(key)
  return "ntx_speaker_tool_" .. key
end

local function altHeld(ply)
  return ply:KeyDown(KEY_LALT) or ply:KeyDown(KEY_RALT)
end

-- The cabinet under the crosshair: what the panel's Load / Save buttons act on.
local function aimedSpeaker()
  local ply = LocalPlayer()
  if not IsValid(ply) then return nil end
  local ent = ply:GetEyeTrace().Entity
  if IsValid(ent) and ent:GetClass() == "ntx_speaker" then return ent end
  return nil
end

-- Left-click: link/select only, via the shared gesture in ntx_net.lua. Shift-
-- click opens the panel of whatever NTx entity is aimed at, whichever tool is
-- held.
function TOOL:LeftClick(tr)
  if CLIENT then return true end
  local ply = self:GetOwner()
  local ent = tr.Entity
  local _shift = NTx.ToolShift(ply)
  print("[NTX DBG] LeftClick " .. (IsValid(ent) and ent:GetClass() .. ":" .. ent:EntIndex() or "nil") .. " shift=" .. tostring(_shift))
  if _shift and NTx.OpenEntityGui(ply, ent) then return true end
  return NTx.ToolLinkClick(ply, ent)
end

-- Right-click: stamp this panel's settings onto the aimed cabinet. The profile
-- applies first (it stamps the whole electrical set at once) and the numeric
-- fields then override it, so "pick a profile then fine-tune" still works.
function TOOL:RightClick(tr)
  if CLIENT then return true end
  local ent = tr.Entity
  if not (IsValid(ent) and ent:GetClass() == "ntx_speaker") then return false end
  local ply = self:GetOwner()

  local st = string.upper(self:GetClientInfo("stype"))
  if NTx.IsSpeakerType(st) then ent:SetSpeakerType(st) end
  ent:SetArrayId(string.sub(self:GetClientInfo("arrayid"), 1, 32))
  ent:SetSelfCardioid(self:GetClientNumber("selfcard", 0) ~= 0)
  ent:SetReversed(self:GetClientNumber("reversed", 0) ~= 0)
  ent:SetMidHFov(math.Clamp(self:GetClientNumber("hifov", 152), 5, 360))
  ent:SetMidVFov(math.Clamp(self:GetClientNumber("vifov", 57), 5, 360))
  local prof = NTx.SpeakerProfileById(self:GetClientInfo("spkprofile"))
  if prof then ent:ApplySpeakerProfile(prof.id) end
  if NTx.IsSpeakerType(st) then ent:SetSpeakerType(st) end
  ent:SetImpedance(math.Clamp(self:GetClientNumber("spkimp", 8), 0.1, 100000))
  ent:SetRmsW(math.Clamp(self:GetClientNumber("spkrmsw", 500), 0, 100000))
  ent:SetPeakW(math.Clamp(self:GetClientNumber("spkpeakw", 1000), 0, 200000))
  ent:SetMinAmpW(math.Clamp(self:GetClientNumber("spkminampw", 350), 0, 100000))
  ent:SetTapVolt(math.Clamp(math.floor(self:GetClientNumber("spktapv", 0)), 0, 240))
  ent:SetActive(self:GetClientNumber("spkactive", 0) ~= 0)
  ply:ChatPrint("[NTx] Cabinet: " .. ent:GetSpeakerType() .. " [" .. ent:GetArrayId() .. "]"
    .. (ent:GetReversed() and " REV" or "")
    .. (ent:GetSelfCardioid() and " SC" or "")
    .. string.format(" FOV %dx%d", math.Round(ent:GetMidHFov()), math.Round(ent:GetMidVFov()))
    .. string.format(" / %s%s", NTx.SpkOhmText(ent), ent:GetActive() and " ACTIVE" or "")
    .. string.format(" %d/%d W", math.Round(ent:GetRmsW()), math.Round(ent:GetPeakW())))
  return true
end

function TOOL:Reload(tr)
  if CLIENT then return true end
  local ent = tr.Entity
  if not (IsValid(ent) and ent:GetClass() == "ntx_speaker") then return false end
  local ply = self:GetOwner()
  if altHeld(ply) and IsValid(ent:GetAmp()) then
    ent:SetAmp(NULL)
    ent:SetAmpChannel(0)
    ply:ChatPrint("[NTx] Cabinet unlinked from its amplifier.")
  else
    ent:SetReversed(not ent:GetReversed())
    ply:ChatPrint("[NTx] Speaker polarity reversed = " .. tostring(ent:GetReversed()))
  end
  return true
end

-- Convar-bound dropdown. The DForm row is the real control (AddControl's
-- ComboBox hands the case to a preset picker instead), but its ComboBox does not
-- write the bound convar when an option is picked, and RightClick reads that
-- convar on the server, so the pick is written here.
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

-- The profile picker is built by hand because the list is dynamic: saved
-- profiles arrive over the network at any time, so a preset picker has nothing
-- to show. Same value -> index rule as the dropdown above.
local function profilePicker(panel, list, convar, mark)
  local combo = vgui.Create("DComboBox", panel)
  combo:Dock(TOP)
  combo:DockMargin(4, 0, 4, 0)
  combo:SetTall(26)
  local index = {}
  for i, p in ipairs(list) do
    combo:AddChoice(p.name .. (p.saved and mark or ""), p.id)
    index[p.id] = i
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
  panel:AddControl("Header", { Description = "#tool.ntx_speaker_tool.desc" })
  panel:AddControl("Label", {
    Text = "Left-click selects and links (source, then destination). Shift-click opens any NTx entity panel. Right-click applies the settings below, profile included. Reload flips polarity; alt+reload unlinks from its amplifier.",
  })

  -- Profile: the dropdown is the picker, but right-click is not the only way to
  -- use it - Load applies just the profile to whatever you aim at, and Save
  -- stores the aimed cabinet under the typed name. Both act on the crosshair,
  -- so no panel has to be open for a profile to move.
  panel:AddControl("Label", { Text = "CABINET PROFILE" })
  local spkCombo = profilePicker(panel, NTx.AllSpeakerProfiles(), cv("spkprofile"), " *")

  local loadRow = vgui.Create("DPanel", panel)
  loadRow:Dock(TOP)
  loadRow:SetTall(26)
  loadRow:DockMargin(4, 2, 4, 0)
  loadRow:SetPaintBackground(false)
  local loadBtn = vgui.Create("DButton", loadRow)
  loadBtn:SetText("Load onto aimed cabinet")
  loadBtn:SetWide(170)
  loadBtn:Dock(LEFT)
  loadBtn.DoClick = function()
    local spk = aimedSpeaker()
    if not IsValid(spk) then
      LocalPlayer():ChatPrint("[NTx] Aim at a cabinet first.")
      return
    end
    net.Start("NTx.SpkProfile")
    net.WriteString("apply")
    net.WriteEntity(spk)
    -- Whatever the combo currently points at, with the convar as the fallback:
    -- the button has to work even if the combo never got a selection.
    net.WriteString(tostring(spkCombo:GetOptionData(spkCombo:GetSelectedID())
      or GetConVarString(cv("spkprofile"))))
    net.SendToServer()
  end
  local saveBtn = vgui.Create("DButton", loadRow)
  saveBtn:SetText("Save aimed as...")
  saveBtn:SetWide(120)
  saveBtn:Dock(RIGHT)
  saveBtn.DoClick = function()
    local spk = aimedSpeaker()
    local name = NTx.SpkSanitiseName(GetConVarString(cv("spksavename")))
    if not IsValid(spk) then
      LocalPlayer():ChatPrint("[NTx] Aim at a cabinet first.")
      return
    end
    if name == "" then
      LocalPlayer():ChatPrint("[NTx] Type a profile name first.")
      return
    end
    net.Start("NTx.SpkProfile")
    net.WriteString("save")
    net.WriteEntity(spk)
    net.WriteString(name)
    net.SendToServer()
  end
  panel:AddControl("TextBox", { Label = "Save as", Command = cv("spksavename") })
  panel:AddControl("Label", {
    Text = "* = saved profile, shared with the server. Loading a profile stamps its impedance, power ratings and tap onto the cabinet; the sliders below then override it.",
  })

  panel:AddControl("Label", { Text = "POWER / OHMS" })
  panel:AddControl("Slider", {
    Label = "Impedance (ohm)", Command = cv("spkimp"), Min = 0.5, Max = 1000,
    Default = 8, Decimals = 1,
  })
  panel:AddControl("Slider", {
    Label = "RMS power (W)", Command = cv("spkrmsw"), Min = 5, Max = 5000,
    Default = 500, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "Peak power (W)", Command = cv("spkpeakw"), Min = 10, Max = 10000,
    Default = 1000, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "Min amp watts", Command = cv("spkminampw"), Min = 0, Max = 3000,
    Default = 350, Decimals = 0,
  })
  dropdown(panel, "Hi-Z tap", cv("spktapv"), {
    { "low-Z", "0" }, { "70 V", "70" }, { "100 V", "100" },
  })
  dropdown(panel, "Self-powered", cv("spkactive"), {
    { "Passive (amp driven)", "0" }, { "ACTIVE (no simulation)", "1" },
  })

  panel:AddControl("Label", { Text = "CABINET PLACEMENT" })
  dropdown(panel, "Speaker type", cv("stype"), {
    { "MID", "MID" }, { "SUB", "SUB" },
  })
  panel:AddControl("TextBox", { Label = "Array ID", Command = cv("arrayid") })
  dropdown(panel, "Self-cardioid", cv("selfcard"), {
    { "Off", "0" }, { "On", "1" },
  })
  dropdown(panel, "Rear polarity", cv("reversed"), {
    { "Normal", "0" }, { "Reversed", "1" },
  })
  panel:AddControl("Slider", {
    Label = "MID H-FOV (deg)", Command = cv("hifov"), Min = 5, Max = 360,
    Default = 152, Decimals = 0,
  })
  panel:AddControl("Slider", {
    Label = "MID V-FOV (deg)", Command = cv("vifov"), Min = 5, Max = 360,
    Default = 57, Decimals = 0,
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
end

if CLIENT then
  language.Add("tool.ntx_speaker_tool.name", "NTx Speaker")
  language.Add("tool.ntx_speaker_tool.desc", "Cabinet profile, power and placement settings")
  language.Add("tool.ntx_speaker_tool.left", "Select / link the aimed entity (shift: open its panel)")
  language.Add("tool.ntx_speaker_tool.right", "Apply these settings to the cabinet")
  language.Add("tool.ntx_speaker_tool.reload", "Flip polarity (alt: unlink from amplifier)")
end

TOOL.Information = { { name = "left" }, { name = "right" }, { name = "reload" } }
