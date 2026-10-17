-- Client: amplifier and cabinet Derma panels.
--
-- Everything an amplifier does differently from another amplifier is a field in
-- NTx.AmpFields, and the settings page is generated straight from that table -
-- so the panel cannot drift out of sync with what the server accepts, and a new
-- profile switch shows up here for free.
--
-- All edits go through NTx.AmpEdit, whose receiver looks the field name up in
-- the same table and applies a clamped setter server side.
if not CLIENT then return end
if NTx_AmpUILoaded then return end
NTx_AmpUILoaded = true

local COL_TEXT = Color(235, 235, 235)
local COL_DIM = Color(185, 185, 185)
local COL_WARN = Color(235, 160, 90)
local COL_OK = Color(120, 220, 150)

local openPanel = nil

local function label(parent, txt, col, tall)
  local lbl = vgui.Create("DLabel", parent)
  lbl:SetText(txt)
  lbl:SetTextColor(col or COL_TEXT)
  if tall then lbl:SetWrap(true) lbl:SetTall(tall) end
  return lbl
end

-- One slider or checkbox per entry in a field table, wired to whichever sender
-- the caller passes. Generating the page from the table is the point: the
-- panel and the server's validation read the same list.
local function buildFields(parent, ent, fields, getter, sender)
  for _, entry in ipairs(fields) do
    if entry.label ~= "" and entry.set then
      local r = row(parent)
      local lbl = label(r, entry.label)
      lbl:SetWide(150)
      lbl:Dock(LEFT)
      local value = getter(entry.name)
      local isBool = entry.min == 0 and entry.max == 1
      local ctl
      if isBool then
        ctl = vgui.Create("DCheckBoxLabel", r)
        ctl:SetText("")
        ctl:SetValue((tonumber(value) or 0) > 0.5)
        ctl:Dock(FILL)
        ctl.OnChange = function(_, v) sender(entry.name, v and 1 or 0) end
      else
        ctl = vgui.Create("DNumSlider", r)
        ctl:Dock(FILL)
        ctl:SetMinMax(entry.min, entry.max)
        local decimals = entry.step < 0.1 and 2 or (entry.step < 1 and 1 or 0)
        ctl:SetDecimals(decimals)
        ctl:SetValue(value or entry.min)
        ctl.OnValueChanged = function(_, v) sender(entry.name, v) end
      end
    end
  end
end

local function ampSender(amp)
  return function(name, value)
    net.Start("NTx.AmpEdit")
    net.WriteEntity(amp)
    net.WriteString("set")
    net.WriteUInt(1, 5)
    net.WriteString(name)
    net.WriteFloat(value)
    net.SendToServer()
  end
end

local function spkSender(spk)
  return function(name, value)
    net.Start("NTx.AmpEdit")
    net.WriteEntity(spk)
    net.WriteString("spkset")
    net.WriteUInt(1, 5)
    net.WriteString(name)
    net.WriteFloat(value)
    net.SendToServer()
  end
end

local function sendAmpKind(amp, kind, extra)
  net.Start("NTx.AmpEdit")
  net.WriteEntity(amp)
  net.WriteString(kind)
  if extra then extra() end
  net.SendToServer()
end

local function row(parent, h)
  local r = vgui.Create("DPanel", parent)
  r:Dock(TOP)
  r:SetTall(h or 26)
  r:DockMargin(4, 2, 4, 0)
  r:SetPaintBackground(false)
  return r
end

-- ------------------------------------------------------------ amp settings

-- ------------------------------------------------------------ amplifier UI

function NTx.OpenAmpUI(amp)
  if not IsValid(amp) then return end
  if IsValid(openPanel) then openPanel:Close() end
  local rec = NTx.AmpRecord(amp)

  local frame = vgui.Create("DFrame")
  frame:SetTitle("NTx Amplifier - " .. (amp:GetProfile() or "?"))
  frame:SetSize(600, math.min(760, ScrH() * 0.85))
  frame:Center()
  frame:MakePopup()
  openPanel = frame

  local scroll = vgui.Create("DScrollPanel", frame)
  scroll:Dock(FILL)

  -- The front panel itself, drawn by the same code that draws it in 3D.
  local face = vgui.Create("DPanel", scroll)
  face:Dock(TOP)
  face:SetTall(126)
  face:DockMargin(4, 4, 4, 0)
  face.Paint = function(_, w, h)
    draw.RoundedBox(4, 0, 0, w, h, Color(22, 22, 24))
    surface.SetDrawColor(70, 70, 76, 255)
    surface.DrawOutlinedRect(0, 0, w, h)
    -- The panel is drawn at its own virtual size, so the Derma copy is pixel for
    -- pixel the LEDs the amplifier is showing in the world.
    local ok, err = pcall(NTx.DrawAmpPanel, amp, { text = true, x = 6, y = 6, textCol = COL_TEXT, dimCol = COL_DIM })
    if not ok then draw.SimpleText("panel draw failed: " .. tostring(err), "DermaDefault", 6, 6, COL_WARN) end
  end

  local header = row(scroll, 20)
  local faultLbl = label(header, "fault: -")
  faultLbl:Dock(LEFT)
  local modelLbl = label(header, (amp:GetProfile() or "?"), COL_DIM)
  modelLbl:Dock(LEFT)

  -- Profile.
  local prow = row(scroll, 30)
  local plbl = label(prow, "Model")
  plbl:SetWide(150)
  plbl:Dock(LEFT)
  local combo = vgui.Create("DComboBox", prow)
  combo:Dock(FILL)
  for _, id in ipairs(NTx.AmpProfileIds()) do combo:AddChoice(NTx.AmpProfile(id).name, id) end
  combo:Select(amp:GetProfile())
  combo.OnSelect = function(_, _, data)
    sendAmpKind(amp, "profile", function() net.WriteString(tostring(data or "")) end)
  end

  -- Buttons.
  local brow = row(scroll, 30)
  local function mkBtn(text, w)
    local b = vgui.Create("DButton", brow)
    b:SetText(text)
    b:SetWide(w or 78)
    b:Dock(LEFT)
    b:DockMargin(0, 0, 4, 0)
    return b
  end
  local setAmp = ampSender(amp)
  mkBtn("Reset all", 78).DoClick = function() sendAmpKind(amp, "reset") end
  mkBtn("Clear LED", 78).DoClick = function() sendAmpKind(amp, "cliplatch") end
  mkBtn("Cool down", 88).DoClick = function()
    setAmp("fanon", 1)
    setAmp("mainsov", 0)
    setAmp("ambient", 0)
  end

  local faultWrap = vgui.Create("DPanel", scroll)
  faultWrap:Dock(TOP)
  faultWrap:SetTall(28)
  faultWrap:DockMargin(4, 2, 4, 0)
  faultWrap:SetPaintBackground(false)
  for _, f in ipairs({ "brownout", "overvoltage", "dc", "short", "thermal", "kill", "none" }) do
    local b = vgui.Create("DButton", faultWrap)
    b:SetText(f)
    b:SetWide(72)
    b:Dock(LEFT)
    b:DockMargin(0, 0, 3, 0)
    b.DoClick = function()
      sendAmpKind(amp, "fault", function() net.WriteString(f) end)
    end
  end
  label(scroll, "FAULT INJECTION - testing only. Each button latches until 'none'.", COL_DIM, 16):Dock(TOP)

  -- Behaviour toggles (everything that differs between one amplifier and the
  -- next: PFC, hum, fan, standby, thermal limiter, meters, taps).
  label(scroll, "BEHAVIOUR", COL_WARN, 18):Dock(TOP)
  buildFields(scroll, amp, NTx.AmpFields, function(name)
    if name == "channels" then return amp:GetChannels() end
    if name == "ratedw" then return amp:GetRatedW() end
    if name == "ratedz" then return amp:GetRatedLoad() end
    if name == "minz" then return amp:GetMinLoad() end
    if name == "sens" then return amp:GetSens() end
    if name == "trim" then return amp:GetTrim() end
    if name == "ilime" then return amp:GetIlime() end
    if name == "mode" then return amp:GetMode() end
    if name == "hizv" then return amp:GetHizVolt() end
    if name == "busmask" then return amp:GetBusMask() end
    if name == "meters" then return amp:GetMeters() end
    if name == "pfc" then return amp:GetPFC() and 1 or 0 end
    if name == "hum" then return amp:GetMainsHum() and 1 or 0 end
    if name == "humdb" then return amp:GetHumDb() end
    if name == "fan" then return amp:GetFanNoise() and 1 or 0 end
    if name == "fandb" then return amp:GetFanNoiseDb() end
    if name == "standby" then return amp:GetAutoStandby() and 1 or 0 end
    if name == "sbdelay" then return amp:GetStandbyDelay() end
    if name == "cliphold" then return amp:GetClipHold() end
    if name == "crest" then return amp:GetCrestDb() end
    if name == "thbias" then return amp:GetThermalBias() end
    if name == "mainsov" then return amp:GetMainsOverride() end
    if name == "ambient" then return amp:GetAmbient() end
    if name == "power" then return amp:GetPower() and 1 or 0 end
    if name == "fanon" then return amp:GetFanOn() and 1 or 0 end
    return nil
  end, setAmp)

  -- Per channel rows. The numbers are refreshed from the live record rather
  -- than baked in at build time: this panel is how you watch a channel fold back.
  label(scroll, "CHANNELS", COL_WARN, 18):Dock(TOP)
  local chanLabels = {}
  for _, ch in ipairs(amp:ActiveChannels()) do
    local cr = row(scroll, 24)
    local lbl = label(cr, string.format("CH%d", ch))
    lbl:SetWide(40)
    lbl:Dock(LEFT)
    local bus = vgui.Create("DComboBox", cr)
    bus:SetWide(70)
    bus:Dock(LEFT)
    bus:AddChoice("MID", 0)
    bus:AddChoice("SUB", 1)
    bus:Select(amp:ChannelIsSub(ch) and 1 or 0)
    bus.OnSelect = function(_, _, data)
      local mask = amp:GetBusMask()
      local bit = 1 << (ch - 1)
      if tonumber(data) == 1 then mask = bit.bor(mask, bit) else mask = bit.band(mask, bit.bnot(bit)) end
      setAmp("busmask", mask)
    end
    local info = label(cr, "-", COL_DIM)
    info:Dock(FILL)
    chanLabels[ch] = info
  end

  -- Cabinet patch on this amplifier.
  label(scroll, "CABINETS", COL_WARN, 18):Dock(TOP)
  local spkLabels = {}
  local any = false
  for _, spk in ipairs(ents.FindByClass("ntx_speaker")) do
    if IsValid(spk) and spk:GetAmp() == amp then
      any = true
      local sr = row(scroll, 22)
      local info = label(sr, "[" .. spk:EntIndex() .. "]", COL_DIM)
      info:Dock(FILL)
      spkLabels[spk] = info
      local b = vgui.Create("DButton", sr)
      b:SetText("Cabinet")
      b:SetWide(74)
      b:Dock(RIGHT)
      b.DoClick = function() NTx.OpenCabinetUI(spk) end
    end
  end
  if not any then label(scroll, "No cabinets linked. Tool: left-click a cabinet, then this amplifier.", COL_DIM, 16):Dock(TOP) end

  frame.Think = function()
    local rec = NTx.AmpRecord(amp)
    if not IsValid(amp) then return end
    faultLbl:SetText("fault: " .. (rec and NTx.AmpFaultName(rec.fault) or "unknown"))
    faultLbl:SetTextColor(rec and rec.fault ~= 0 and rec.fault ~= 9 and COL_WARN or COL_OK)
    modelLbl:SetText((amp:GetProfile() or "?") .. (amp:GetBlown() and "  BURNT" or ""))
    for ch, info in pairs(chanLabels) do
      local idx, c = 0, nil
      for i, active in ipairs(amp:ActiveChannels()) do
        if active == ch then idx = i end
      end
      c = rec and rec.ch[idx]
      info:SetText(string.format("%s  %.1f A  %.0f W  %s",
        (c and (c.z < 1000)) and string.format("%.1f ohm", c.z) or "open",
        c and c.i or 0, c and c.w or 0,
        c and c.protect and "PROTECT" or (c and c.clip and "CLIP" or "")))
      info:SetTextColor(c and (c.protect or c.clip) and COL_WARN or COL_DIM)
    end
    for spk, info in pairs(spkLabels) do
      local ss = rec and rec.spk[spk:EntIndex()]
      if ss then
        info:SetText(string.format("[%d] %s %s  %.0f/%.0f W rms  coil %.0f C  %s",
          spk:EntIndex(), spk:GetSpeakerType(), NTx.SpkOhmText(spk), ss.rms, spk:GetRmsW(),
          ss.temp, spk:GetBlown() and "BLOWN" or string.format("damage %.0f%%", spk:GetDamage() * 100)))
        info:SetTextColor(spk:GetBlown() and Color(255, 90, 90) or COL_DIM)
      end
    end
  end
end

-- ------------------------------------------------------- mixer link panel

-- Choosing the bus per channel is not cosmetic: the amplifier reads that bus
-- for its input level, so the meters and the heat only make sense once the
-- player has said what each output is going to drive.
function NTx.OpenAmpLinkPanel(amp, mixer)
  if not IsValid(amp) then return end
  local frame = vgui.Create("DFrame")
  frame:SetTitle("Patch amplifier " .. amp:EntIndex() .. " -> mixer " .. (IsValid(mixer) and mixer:EntIndex() or "?"))
  frame:SetSize(430, 420)
  frame:Center()
  frame:MakePopup()

  local scroll = vgui.Create("DScrollPanel", frame)
  scroll:Dock(FILL)

  label(scroll, "What will each output drive? The amplifier takes its level from that bus.", COL_DIM, 32):Dock(TOP)

  local usable = amp:UsableChannels()
  local combos = {}
  for _, ch in ipairs(amp:ActiveChannels()) do
    local cr = row(scroll, 28)
    local lbl = label(cr, "Output " .. ch)
    lbl:SetWide(70)
    lbl:Dock(LEFT)
    local bus = vgui.Create("DComboBox", cr)
    bus:Dock(FILL)
    bus:AddChoice("MID cabinets", 0)
    bus:AddChoice("SUB cabinets", 1)
    -- Pre-select from whatever is already patched, which is right most of the
    -- time and is a starting point rather than a decision.
    local guess = amp:ChannelIsSub(ch) and 1 or 0
    for _, spk in ipairs(ents.FindByClass("ntx_speaker")) do
      if IsValid(spk) and spk:GetAmp() == amp
        and (NTx.AmpSpeakerChannel(amp, spk) == ch) then
        guess = (spk:BusType() == "sub") and 1 or 0
        break
      end
    end
    bus:Select(guess)
    combos[ch] = bus
  end

  local mrow = row(scroll, 28)
  local modeLbl = label(mrow, "Mode")
  modeLbl:SetWide(70)
  modeLbl:Dock(LEFT)
  local mode = vgui.Create("DComboBox", mrow)
  mode:Dock(LEFT)
  mode:SetWide(150)
  -- Only the modes the amplifier itself has. The MA2400 has three (the manual
  -- documents dual, bridge and parallel-mono); the CDi has two.
  local prof = amp:Prof()
  local modeNames = { [0] = "Dual (stereo)", [1] = "Bridge-mono", [2] = "Parallel-mono" }
  local offered = prof and prof.modes or { "dual" }
  for i, name in ipairs({ "dual", "bridge", "parallel" }) do
    if offered[name] then mode:AddChoice(modeNames[i], i - 1) end
  end
  mode:Select(math.Clamp(amp:GetMode(), 0, 2))

  local hrow = row(scroll, 28)
  local hizLbl = label(hrow, "Output tap")
  hizLbl:SetWide(70)
  hizLbl:Dock(LEFT)
  local hiz = vgui.Create("DComboBox", hrow)
  hiz:Dock(LEFT)
  hiz:SetWide(150)
  hiz:AddChoice("low-Z (4/8 ohm)", 0)
  if prof and prof.hiz then
    hiz:AddChoice("70 V constant voltage", 70)
    hiz:AddChoice("100 V constant voltage", 100)
  end
  hiz:Select(amp:GetHizVolt())

  label(scroll, "Cabs on the wrong bus after patching are unlinked, not silently moved.", COL_DIM, 18):Dock(TOP)

  local go = vgui.Create("DButton", frame)
  go:Dock(BOTTOM)
  go:SetText("Link amplifier to mixer")
  go.DoClick = function()
    local mask = 0
    for ch, bus in pairs(combos) do
      if bus:GetSelectedID() == 1 then mask = bit.bor(mask, 1 << (ch - 1)) end
    end
    net.Start("NTx.AmpEdit")
    net.WriteEntity(amp)
    net.WriteString("link")
    net.WriteEntity(IsValid(mixer) and mixer or NULL)
    net.WriteUInt(mask, 8)
    net.WriteUInt(mode:GetSelectedID() or 0, 2)
    net.WriteUInt(hiz:GetSelectedID() or 0, 8)
    net.SendToServer()
    frame:Close()
  end
end

-- ------------------------------------------------------------- cabinet UI

function NTx.OpenCabinetUI(spk)
  if not IsValid(spk) then return end
  local frame = vgui.Create("DFrame")
  frame:SetTitle("NTx Cabinet - " .. spk:EntIndex())
  frame:SetSize(440, 470)
  frame:Center()
  frame:MakePopup()
  local scroll = vgui.Create("DScrollPanel", frame)
  scroll:Dock(FILL)

  local prow = row(scroll, 30)
  label(prow, "Profile").SetWide(110)
  local combo = vgui.Create("DComboBox", prow)
  combo:Dock(FILL)
  for _, p in ipairs(NTx.AllSpeakerProfiles()) do
    combo:AddChoice(p.name .. (p.saved and " *" or ""), p.id)
  end
  combo:Select(spk:GetProfile())
  combo.OnSelect = function(_, _, data)
    net.Start("NTx.SpkProfile")
    net.WriteString("apply")
    net.WriteEntity(spk)
    net.WriteString(tostring(data or ""))
    net.SendToServer()
  end
  label(scroll, "* = saved profile (shared with the server)", COL_DIM, 16):Dock(TOP)

  local function spkGetter(name)
    if name == "imp" then return spk:GetImpedance() end
    if name == "rmsw" then return spk:GetRmsW() end
    if name == "peakw" then return spk:GetPeakW() end
    if name == "minampw" then return spk:GetMinAmpW() end
    if name == "tapv" then return spk:GetTapVolt() end
    if name == "seriesgrp" then return spk:GetSeriesGroup() end
    if name == "active" then return spk:GetActive() and 1 or 0 end
    if name == "ampch" then return spk:GetAmpChannel() end
    return nil
  end

  local numeric = {}
  for _, entry in ipairs(NTx.SpkFields) do
    if entry.name ~= "profile" and entry.label ~= "" then numeric[#numeric + 1] = entry end
  end
  buildFields(scroll, spk, numeric, spkGetter, spkSender(spk))

  -- Link row.
  local lrow = row(scroll, 28)
  local ampLbl = label(lrow, "Amplifier")
  ampLbl:SetWide(110)
  ampLbl:Dock(LEFT)
  local ac = vgui.Create("DComboBox", lrow)
  ac:Dock(FILL)
  ac:AddChoice("(none - driven off the mixer)", NULL)
  for _, amp in ipairs(ents.FindByClass("ntx_amplifier")) do
    if IsValid(amp) then ac:AddChoice("amp " .. amp:EntIndex() .. " (" .. amp:GetProfile() .. ")", amp) end
  end
  local cur = spk:GetAmp()
  ac:Select(IsValid(cur) and cur or NULL)
  ac.OnSelect = function(_, _, data)
    local amp = data
    if not IsValid(amp) then
      net.Start("NTx.AmpUnlink")
      net.WriteEntity(spk)
      net.SendToServer()
      return
    end
    net.Start("NTx.AmpLink")
    net.WriteEntity(spk)
    net.WriteEntity(amp)
    net.WriteUInt(math.Clamp(math.floor(tonumber(spkGetter("ampch")) or 0), 0, 8), 4)
    net.SendToServer()
  end

  local info = row(scroll, 22)
  local st = label(info, "coil -", COL_DIM)
  st:Dock(FILL)

  local saveRow = vgui.Create("DPanel", frame)
  saveRow:Dock(BOTTOM)
  saveRow:SetTall(30)
  saveRow:DockMargin(4, 4, 4, 4)
  local entry = vgui.Create("DTextEntry", saveRow)
  entry:Dock(FILL)
  entry:DockMargin(0, 0, 4, 0)
  entry:SetPlaceholderText("save this cabinet as a profile...")
  local save = vgui.Create("DButton", saveRow)
  save:SetText("Save")
  save:SetWide(80)
  save:Dock(RIGHT)
  save.DoClick = function()
    net.Start("NTx.SpkProfile")
    net.WriteString("save")
    net.WriteEntity(spk)
    net.WriteString(NTx.SpkSanitiseName(entry:GetValue()))
    net.SendToServer()
  end

  frame.Think = function()
    if not IsValid(spk) then return end
    st:SetText(string.format("coil %.0f C   damage %.0f%%   %s",
      spk:GetCoilTemp(), spk:GetDamage() * 100, spk:GetBlown() and "BLOWN" or "ok"))
    st:SetTextColor(spk:GetBlown() and Color(255, 90, 90) or COL_DIM)
  end
end

concommand.Add("ntx_open_amp", function(_, _, args)
  local ent = Entity(tonumber(args[1] or 0) or 0)
  if IsValid(ent) and ent:GetClass() == "ntx_amplifier" then NTx.OpenAmpUI(ent) end
end)

concommand.Add("ntx_open_cabinet", function(_, _, args)
  local ent = Entity(tonumber(args[1] or 0) or 0)
  if IsValid(ent) and ent:GetClass() == "ntx_speaker" then NTx.OpenCabinetUI(ent) end
end)

-- Tool verb: patch an amplifier to a mixer, which always opens the bus picker.
concommand.Add("ntx_amp_patch", function(_, _, args)
  local amp = Entity(tonumber(args[1] or 0) or 0)
  local mixer = Entity(tonumber(args[2] or 0) or 0)
  if IsValid(amp) and amp:GetClass() == "ntx_amplifier" then
    NTx.OpenAmpLinkPanel(amp, IsValid(mixer) and mixer or nil)
  end
end)

-- Fault verbs for scripted testing: ntx_amp_fault <ent> <fault>
concommand.Add("ntx_amp_fault", function(_, _, args)
  local ent = Entity(tonumber(args[1] or 0) or 0)
  local fault = tostring(args[2] or "none")
  if not IsValid(ent) or ent:GetClass() ~= "ntx_amplifier" then return end
  net.Start("NTx.AmpEdit")
  net.WriteEntity(ent)
  net.WriteString("fault")
  net.WriteString(fault)
  net.SendToServer()
end)

-- --------------------------------------------------- saved speaker profiles

-- The list lives on the server (garrysmod/data) so a profile is shared; this
-- receiver keeps the local copy the dropdowns and the Utilities page read from.
net.Receive("NTx.SpkList", function()
  NTx.SavedSpeakerProfiles = {}
  local n = net.ReadUInt(6)
  for _ = 1, n do
    local name, stype = net.ReadString(), net.ReadString()
    local ohm, rmsW, peakW, minAmpW, tapV = net.ReadFloat(), net.ReadFloat(),
      net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
    local id = NTx.SpkMakeId(name)
    if id ~= "" then
      NTx.SavedSpeakerProfiles[id] = {
        id = id, name = name, stype = stype, ohm = ohm, rmsW = rmsW,
        peakW = peakW, minAmpW = minAmpW, tapVolt = tapV, saved = true,
      }
    end
  end
end)

-- Everything the Utilities page does with a profile, and the console verbs for
-- the same job. The entity defaults to whatever the player is looking at, which
-- is what makes "aim at a cab, type a name" the fast path.
local function aimedSpeaker()
  local ply = LocalPlayer()
  if not IsValid(ply) then return nil end
  local tr = ply:GetEyeTrace()
  local ent = tr.Entity
  if IsValid(ent) and ent:GetClass() == "ntx_speaker" then return ent end
  return nil
end

concommand.Add("ntx_spk_save", function(_, _, args)
  local spk = aimedSpeaker()
  if not spk then print("[NTx] aim at a ntx_speaker first") return end
  local name = NTx.SpkSanitiseName(table.concat(args, " "))
  if name == "" then print("[NTx] usage: ntx_spk_save <name>") return end
  net.Start("NTx.SpkProfile")
  net.WriteString("save")
  net.WriteEntity(spk)
  net.WriteString(name)
  net.SendToServer()
end)

concommand.Add("ntx_spk_apply", function(_, _, args)
  local spk = aimedSpeaker()
  local id = table.concat(args, " ")
  if not spk or id == "" then print("[NTx] usage: aim at a ntx_speaker, then ntx_spk_apply <profile id>") return end
  net.Start("NTx.SpkProfile")
  net.WriteString("apply")
  net.WriteEntity(spk)
  net.WriteString(id)
  net.SendToServer()
end)

concommand.Add("ntx_spk_del", function(_, _, args)
  local id = table.concat(args, " ")
  if id == "" then print("[NTx] usage: ntx_spk_del <profile id>") return end
  net.Start("NTx.SpkProfile")
  net.WriteString("delete")
  net.WriteEntity(NULL)
  net.WriteString(id)
  net.SendToServer()
end)

concommand.Add("ntx_spk_list", function()
  net.Start("NTx.SpkProfile")
  net.WriteString("list")
  net.SendToServer()
  print("[NTx] built-in profiles: " .. table.concat(NTx.SpeakerProfileIds(), ", "))
  local saved = {}
  for id in pairs(NTx.SavedSpeakerProfiles) do saved[#saved + 1] = id end
  table.sort(saved)
  print("[NTx] saved profiles: " .. (#saved > 0 and table.concat(saved, ", ") or "(none)"))
end)