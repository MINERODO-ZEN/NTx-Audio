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

-- GLua's DComboBox has no Select(): the wiki's ChooseOptionID takes the option
-- index, and every combo here identifies its current value by choice data (a
-- profile id, a bus flag, an entity), so the data -> index map is kept by hand.
-- Combo handling lives in ntx_amp_shared so the tool panels and the entity
-- panels cannot drift apart; see NTx.ComboAdd for why the text is the key.
local comboAdd, comboGet, comboPick = NTx.ComboAdd, NTx.ComboGet, NTx.ComboPick

local function row(parent, h)
  local r = vgui.Create("DPanel", parent)
  r:Dock(TOP)
  r:SetTall(h or 26)
  r:DockMargin(4, 2, 4, 0)
  r:SetPaintBackground(false)
  return r
end

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
  -- A profile can lock rows it owns. The row stays in NTx.AmpFields, so the
  -- server-side validation and the patch window still know about it - this only
  -- stops the panel offering to change a number the datasheet already fixed.
  local locked = (ent.Prof and ent:Prof() and ent:Prof().locked) or nil
  local function isLocked(name)
    if not locked then return false end
    for _, n in ipairs(locked) do
      if n == name then return true end
    end
    return false
  end
  -- The controls are built once and never looked at again, so a profile
  -- loaded from here changed the cabinet and left the panel showing the old
  -- numbers. Each control registers how to re-read itself, and the panel
  -- refreshes them after anything that changes the entity from outside.
  local refreshers = {}
  -- While refreshing, a control is set to the value it already holds, and
  -- firing its change handler would send every one of them back to the server.
  local refreshing = false
  for _, entry in ipairs(fields) do
    if entry.label ~= "" and entry.set and not entry.hidden and not isLocked(entry.name) then
      local value = getter(entry.name)
      local isBool = entry.min == 0 and entry.max == 1
      -- A DNumSlider needs ~46 px to show its track and its text entry;
      -- anything less clips the slider and leaves what looks like a text box.
      local isSlider = not entry.choices and not entry.isString and not isBool
      local r = row(parent, isSlider and 46 or 26)
      local lbl = label(r, entry.label)
      lbl:SetWide(150)
      lbl:Dock(LEFT)
      local ctl
      if entry.choices then
        -- A field with a fixed set of values is a dropdown, not a slider: a
        -- speaker type is MID or SUB, and a slider that says 0 to 1 makes the
        -- reader do the mapping.
        ctl = vgui.Create("DComboBox", r)
        ctl:Dock(FILL)
        for _, ch in ipairs(entry.choices) do comboAdd(ctl, ch[1], ch[2]) end
        comboPick(ctl, value)
        ctl.OnSelect = function()
          local v = comboGet(ctl)
          if v ~= nil then sender(entry.name, v) end
        end
        refreshers[#refreshers + 1] = function()
          comboPick(ctl, getter(entry.name))
        end
      elseif entry.isString then
        ctl = vgui.Create("DTextEntry", r)
        ctl:Dock(FILL)
        ctl:SetTextColor(COL_TEXT)
        ctl:SetText(tostring(value or ""))
        -- On enter, not on every keystroke: a half-typed array id is not a
        -- value the server should be handed.
        ctl.OnEnter = function() sender(entry.name, ctl:GetValue()) end
        refreshers[#refreshers + 1] = function()
          ctl:SetText(tostring(getter(entry.name) or ""))
        end
      elseif isBool then
        ctl = vgui.Create("DCheckBoxLabel", r)
        ctl:SetText("")
        ctl:SetValue((tonumber(value) or 0) > 0.5)
        ctl:Dock(FILL)
        ctl.OnChange = function(_, v)
          if refreshing then return end
          sender(entry.name, v and 1 or 0)
        end
        refreshers[#refreshers + 1] = function()
          ctl:SetValue((tonumber(getter(entry.name)) or 0) > 0.5)
        end
      else
        ctl = vgui.Create("DNumSlider", r)
        ctl:Dock(FILL)
        if ctl.Label then ctl.Label:SetTextColor(COL_TEXT) end
        if ctl.TextEntry then ctl.TextEntry:SetTextColor(COL_TEXT) end
        -- ApplySchemeSettings copies the label colour onto the slider notches
        -- and the text entry. It has to run AFTER the colour is set, or the
        -- notches keep the skin's dark colour and vanish on a dark row.
        ctl:ApplySchemeSettings()
        ctl:SetMinMax(entry.min, entry.max)
        local decimals = entry.step < 0.1 and 2 or (entry.step < 1 and 1 or 0)
        ctl:SetDecimals(decimals)
        ctl:SetValue(value or entry.min)
        ctl.OnValueChanged = function(_, v)
          if refreshing then return end
          sender(entry.name, v)
        end
        refreshers[#refreshers + 1] = function()
          ctl:SetValue(getter(entry.name) or entry.min)
        end
      end
    end
  end
  -- Re-reads every control from the entity. The panel calls this after
  -- anything that changed the cabinet from outside the panel: a profile
  -- loaded here, or a profile applied from somewhere else.
  return function()
    refreshing = true
    for _, r in ipairs(refreshers) do r() end
    refreshing = false
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
    -- The field says what its value is, and the server reads the same table,
    -- so a string field is written as a string and everything else as a
    -- float. The cabinet is the first entity: the receiver looks at the kind
    -- before it judges what it was sent.
    local entry = NTx.SpkField(name)
    net.Start("NTx.AmpEdit")
    net.WriteEntity(spk)
    net.WriteString("spkset")
    net.WriteUInt(1, 5)
    net.WriteString(name)
    if entry and entry.isString then
      net.WriteString(tostring(value))
    else
      net.WriteFloat(tonumber(value) or 0)
    end
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

-- ------------------------------------------------------------ amp settings

-- ------------------------------------------------------------ amplifier UI

-- Forward declaration: the public entry point below wraps this in a pcall, and a
-- `local function` further down would not be in scope at the call site yet.
local buildAmpUI

function NTx.OpenAmpUI(amp)
  if not IsValid(amp) then return end
  if IsValid(openPanel) then openPanel:Close() end
  openPanel = nil
  -- The panel is assembled top to bottom, so an error halfway through used to
  -- leave a half-built window with no explanation and no way to tell which
  -- control was missing. Same treatment as the Utilities page.
  local ok, err = pcall(buildAmpUI, amp)
  if not ok then
    print("[NTx] amplifier panel build failed: " .. tostring(err))
    local frame = vgui.Create("DFrame")
    frame:SetTitle("NTx Amplifier - build failed")
    frame:SetSize(600, 120)
    frame:Center()
    frame:MakePopup()
    local lbl = vgui.Create("DLabel", frame)
    lbl:Dock(FILL)
    lbl:SetWrap(true)
    lbl:SetDark(true)
    lbl:SetText("The amplifier panel failed to build:\n" .. tostring(err))
    openPanel = frame
  end
end

buildAmpUI = function(amp)
  local rec = NTx.AmpRecord(amp)

  local frame = vgui.Create("DFrame")
  frame:SetTitle("NTx Amplifier - " .. (amp:GetProfile() or "?"))
  frame:SetSize(600, math.min(760, ScrH() * 0.85))
  frame:Center()
  frame:MakePopup()
  openPanel = frame

  local scroll = vgui.Create("DScrollPanel", frame)
  scroll:Dock(FILL)
  -- The panel's own refresh, filled in when the fields are built. The profile
  -- row is above them and needs it, so it is declared here first.
  local refreshFields

  -- The front panel itself, drawn by the same code that draws it in 3D.
  local face = vgui.Create("DPanel", scroll)
  face:Dock(TOP)
  -- A PAC3 layout fills the panel with its lamps and puts the readout under
  -- it, so that panel is taller.
  face:SetTall((NTx.AmpPanelHeight and NTx.AmpPanelHeight(amp) or 112) + 14)
  face:DockMargin(4, 4, 4, 0)
  face.Paint = function(_, w, h)
    -- The model can be swapped while this window is open, and a PAC3 layout
    -- makes the panel taller, so the height follows it.
    local want = (NTx.AmpPanelHeight and NTx.AmpPanelHeight(amp) or 112) + 14
    if face:GetTall() ~= want then face:SetTall(want) end
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
  for _, id in ipairs(NTx.AmpProfileIds()) do comboAdd(combo, NTx.AmpProfile(id).name, id) end
  comboPick(combo, amp:GetProfile())
  -- One place sends the model, so the dropdown and the button can never drift.
  local function loadModel(id)
    sendAmpKind(amp, "profile", function() net.WriteString(tostring(id or "")) end)
    -- The values are the server's to give, so they arrive a moment later. The
    -- panel is refreshed when they do, or it keeps showing the old numbers and
    -- a loaded model looks like nothing happened.
    timer.Simple(0.15, function()
      if not IsValid(frame) then return end
      if refreshFields then refreshFields() end
    end)
  end
  combo.OnSelect = function()
    loadModel(comboGet(combo))
  end
  -- Selecting loads it, but a dropdown that was already on the wanted model has
  -- nothing left to fire, so "load" is also a button.
  local loadBtn = vgui.Create("DButton", prow)
  loadBtn:SetText("Load")
  loadBtn:SetWide(64)
  loadBtn:Dock(RIGHT)
  loadBtn.DoClick = function()
    loadModel(comboGet(combo) or amp:GetProfile())
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
  for _, fault in ipairs({ "brownout", "overvoltage", "dc", "short", "thermal", "kill", "none" }) do
    -- Local copy: Lua 5.1 shares one loop variable across iterations, so a
    -- closure over the loop variable itself would send the LAST value from
    -- every button.
    local f = fault
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
  -- next: PFC, fan, standby, thermal limiter, meters, taps).
  label(scroll, "BEHAVIOUR", COL_WARN, 18):Dock(TOP)
  refreshFields = buildFields(scroll, amp, NTx.AmpFields, function(name)
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

  -- Per channel rows. Read-only: the bus is whatever the mixer published on
  -- Ch<N>Bus, so there is nothing here to set. A writable control here is what
  -- fought the wiring and reverted.
  label(scroll, "CHANNELS", COL_WARN, 18):Dock(TOP)
  local chanLabels = {}
  for _, ch in ipairs(amp:ActiveChannels()) do
    local chan = ch
    local cr = row(scroll, 24)
    local lbl = label(cr, string.format("CH%d", chan))
    lbl:SetWide(40)
    lbl:Dock(LEFT)
    local info = label(cr, "-", COL_DIM)
    info:Dock(FILL)
    chanLabels[chan] = info
  end

  -- Cabinet patch on this amplifier.
  label(scroll, "CABINETS", COL_WARN, 18):Dock(TOP)
  local spkLabels = {}
  local any = false
  for _, cabinet in ipairs(ents.FindByClass("ntx_speaker")) do
    -- Local copy, for the same reason as the fault buttons: one shared loop
    -- variable would make every row open the last cabinet in the list.
    local spk = cabinet
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
      -- The bus comes from the wiring, so it is shown, not set. An unwired
      -- channel has no identifier at all and says so rather than claiming MID.
      local busName = amp.ChannelBusId and amp:ChannelBusId(ch)
      local wired = busName ~= nil
      info:SetText(string.format("%s  %.1f A  %.0f W  %s%s",
        (c and (c.z < 1000)) and string.format("%.1f ohm", c.z) or "open",
        c and c.i or 0, c and c.w or 0,
        wired and (NTx.BusName(busName) .. " ") or "",
        c and c.protect and "PROTECT" or (c and c.clip and "CLIP" or "")))
      info:SetTextColor(not wired and COL_WARN
        or (c and (c.protect or c.clip) and COL_WARN or COL_DIM))
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
  local busInfo = {}
  for _, ch in ipairs(amp:ActiveChannels()) do
    local chan = ch
    local cr = row(scroll, 26)
    local lbl = label(cr, "Output " .. chan)
    lbl:SetWide(70)
    lbl:Dock(LEFT)
    local info = label(cr, "-", COL_DIM)
    info:Dock(FILL)
    busInfo[chan] = info
  end
  -- Refreshed with the rest of the panel; see the update loop below.
  local function refreshBusInfo()
    for ch, info in pairs(busInfo) do
      local id = amp.ChannelBusId and amp:ChannelBusId(ch)
      if id ~= nil then
        info:SetText(NTx.BusName(id))
        info:SetTextColor(COL_OK)
      else
        info:SetText("no bus wired to this channel")
        info:SetTextColor(COL_WARN)
      end
    end
  end
  refreshBusInfo()

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
    if offered[name] then comboAdd(mode, modeNames[i], i - 1) end
  end
  comboPick(mode, math.Clamp(amp:GetMode(), 0, 2))

  local hrow = row(scroll, 28)
  local hizLbl = label(hrow, "Output tap")
  hizLbl:SetWide(70)
  hizLbl:Dock(LEFT)
  local hiz = vgui.Create("DComboBox", hrow)
  hiz:Dock(LEFT)
  hiz:SetWide(150)
  comboAdd(hiz, "low-Z (4/8 ohm)", 0)
  if prof and prof.hiz then
    comboAdd(hiz, "70 V constant voltage", 70)
    comboAdd(hiz, "100 V constant voltage", 100)
  end
  comboPick(hiz, amp:GetHizVolt())

  label(scroll, "Cabs on the wrong bus after patching are unlinked, not silently moved.", COL_DIM, 18):Dock(TOP)

  local go = vgui.Create("DButton", frame)
  go:Dock(BOTTOM)
  go:SetText("Link amplifier to mixer")
  go.DoClick = function()
    -- No bus mask: each channel's bus comes from the mixer's identifier on
    -- Ch<N>Bus. This sends the mixer patch, mode and tap only.
    net.Start("NTx.AmpEdit")
    net.WriteEntity(amp)
    net.WriteString("link")
    net.WriteEntity(IsValid(mixer) and mixer or NULL)
    net.WriteUInt(0, 8)
    net.WriteUInt(math.Clamp(tonumber(comboGet(mode)) or 0, 0, 3), 2)
    net.WriteUInt(math.Clamp(tonumber(comboGet(hiz)) or 0, 0, 240), 8)
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
  -- Declared here and filled in lower down: the profile row needs to say what
  -- happened, and the label it says it in is docked to the frame's bottom.
  local hint
  -- The same for the panel's refresh: the Load button is above the fields and
  -- needs it, and a local declared after its use is a different variable - a
  -- global, and nil.
  local refreshFields

  local prow = row(scroll, 30)
  local plbl = label(prow, "Profile")
  plbl:SetWide(110)
  plbl:Dock(LEFT)
  -- The Load button is docked before the dropdown, so it sits at the right of
  -- the row and the dropdown takes what is left.
  local load = vgui.Create("DButton", prow)
  load:SetText("Load")
  load:SetWide(64)
  load:Dock(RIGHT)
  local combo = vgui.Create("DComboBox", prow)
  combo:Dock(FILL)
  -- The dropdown is rebuilt when the server pushes the list, so a profile
  -- saved from this window shows up in it instead of only in the next one.
  local listVersion = -1
  local function refreshProfiles()
    combo:Clear()
    -- The label map is keyed by the option's data, so it has to go with the
    -- options: a deleted profile must not stay pickable.
    combo._ntxLabel = nil
    for _, p in ipairs(NTx.AllSpeakerProfiles()) do
      comboAdd(combo, p.name .. (p.saved and " *" or ""), p.id)
    end
    comboPick(combo, spk:GetProfile())
    listVersion = NTx.SpkListVersion or 0
  end
  refreshProfiles()
  -- Choosing a profile does not apply it. The Load button does, so a click
  -- that lands on the wrong option cannot change the cabinet.
  load.DoClick = function()
    local p = NTx.SpeakerProfileById(tostring(comboGet(combo) or ""))
    if not p then
      if hint then hint:SetText("no such profile") end
      return
    end
    NTx.ApplySpeakerProfile(spk, p)
    -- The values are the server's to give, so they arrive a moment later. The
    -- panel is refreshed when they do, otherwise it keeps showing the old
    -- numbers and a loaded profile looks like nothing happened.
    timer.Simple(0.15, function()
      if not IsValid(frame) then return end
      if refreshFields then refreshFields() end
      if hint then hint:SetText("loaded " .. p.name) end
    end)
  end
  label(scroll, "* = saved profile (shared with the server)", COL_DIM, 16):Dock(TOP)

  local function spkGetter(name)
    if name == "stype" then return spk:GetSpeakerType() == "SUB" and 1 or 0 end
    if name == "arrayid" then return spk:GetArrayId() end
    if name == "hifov" then return spk:GetMidHFov() end
    if name == "vifov" then return spk:GetMidVFov() end
    if name == "reversed" then return spk:GetReversed() and 1 or 0 end
    if name == "selfcard" then return spk:GetSelfCardioid() and 1 or 0 end
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

  local fields = {}
  for _, entry in ipairs(NTx.SpkFields) do
    if entry.name ~= "profile" and entry.label ~= "" then fields[#fields + 1] = entry end
  end
  refreshFields = buildFields(scroll, spk, fields, spkGetter, spkSender(spk))

  -- Link row.
  local lrow = row(scroll, 28)
  local ampLbl = label(lrow, "Amplifier")
  ampLbl:SetWide(110)
  ampLbl:Dock(LEFT)
  local ac = vgui.Create("DComboBox", lrow)
  ac:Dock(FILL)
  comboAdd(ac, "(none - driven off the mixer)", NULL)
  for _, amp in ipairs(ents.FindByClass("ntx_amplifier")) do
    if IsValid(amp) then comboAdd(ac, "amp " .. amp:EntIndex() .. " (" .. amp:GetProfile() .. ")", amp) end
  end
  local cur = spk:GetAmp()
  comboPick(ac, IsValid(cur) and cur or NULL)
  ac.OnSelect = function()
    local amp = comboGet(ac)
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

  hint = vgui.Create("DLabel", frame)
  hint:Dock(BOTTOM)
  hint:SetTall(16)
  hint:DockMargin(4, 0, 4, 0)
  hint:SetText("")
  hint:SetTextColor(COL_WARN)
  hint:SetFont("DermaDefaultBold")

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
  local del = vgui.Create("DButton", saveRow)
  del:SetText("Delete")
  del:SetWide(80)
  del:Dock(RIGHT)
  -- Only a saved profile can go: the built-in ones are part of the addon.
  del.DoClick = function()
    local id = tostring(comboGet(combo) or "")
    if not NTx.SavedSpeakerProfiles[id] then
      hint:SetText("that one is built in")
      return
    end
    NTx.DeleteSpeakerProfile(id)
    hint:SetText("")
  end
  save.DoClick = function()
    -- The server drops an empty name without a word, which looks like the
    -- button did nothing at all.
    local ok, err = NTx.SaveSpeakerProfile(spk, entry:GetValue())
    if not ok then
      hint:SetText(tostring(err))
      return
    end
    entry:SetText("")
    hint:SetText("saved")
    -- The cabinet keeps the values it had, and the profile holds them, but
    -- the panel's own numbers are read once, so they are refreshed too.
    timer.Simple(0.15, function()
      if not IsValid(frame) then return end
      if refreshFields then refreshFields() end
    end)
  end

  frame.Think = function()
    if not IsValid(spk) then return end
    if (NTx.SpkListVersion or 0) ~= listVersion then refreshProfiles() end
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
--
-- The saved profiles live in the CLIENT's own data folder. A profile is a
-- cabinet the player built, so it belongs to the player who built it, and the
-- server is never asked to hold it. The server is told the VALUES when one is
-- applied to a cabinet; it keeps no copy and writes no file.
local PROFILE_FILE = "ntx_spk_speakers.json"
local MAX_SAVED = 64

-- The shared file declares this table, but the load order of the autorun files
-- is not fixed, so it is claimed here too: whichever runs first makes it.
NTx.SavedSpeakerProfiles = NTx.SavedSpeakerProfiles or {}

-- Bumped whenever the list changes, so an open cabinet window knows its
-- dropdown is out of date.
NTx.SpkListVersion = 0

local function bumpProfiles()
  NTx.SpkListVersion = NTx.SpkListVersion + 1
end

local function loadProfiles()
  local raw = file.Read(PROFILE_FILE, "DATA")
  if not raw or raw == "" then return end
  local decoded = nil
  pcall(function() decoded = util.JSONToTable(raw) end)
  if not istable(decoded) then return end
  for id, p in pairs(decoded) do
    if istable(p) and NTx.SpkSanitiseName(p.name or "") ~= "" then
      NTx.SavedSpeakerProfiles[tostring(id)] = {
        id = tostring(id), name = NTx.SpkSanitiseName(p.name),
        stype = (p.stype == "SUB") and "SUB" or "MID",
        ohm = math.Clamp(tonumber(p.ohm) or 8, 0.1, 100000),
        rmsW = math.Clamp(tonumber(p.rmsW) or 100, 0, 100000),
        peakW = math.Clamp(tonumber(p.peakW) or 200, 0, 200000),
        minAmpW = math.Clamp(tonumber(p.minAmpW) or 50, 0, 100000),
        tapVolt = math.Clamp(math.floor(tonumber(p.tapVolt) or 0), 0, 240),
        hifov = math.Clamp(tonumber(p.hifov) or 120, 5, 360),
        vifov = math.Clamp(tonumber(p.vifov) or 120, 5, 360),
        saved = true,
      }
    end
  end
end

local function saveProfileFile()
  local out = {}
  for id, p in pairs(NTx.SavedSpeakerProfiles) do out[id] = p end
  file.Write(PROFILE_FILE, util.TableToJSON(out), "DATA")
end

loadProfiles()

-- Asks the server to put a profile on a cabinet. The values go with it: the
-- saved profiles are the client's, and the server has none to look up.
function NTx.ApplySpeakerProfile(spk, p)
  if not IsValid(spk) or not istable(p) then return false end
  net.Start("NTx.SpkProfile")
  net.WriteString("apply")
  net.WriteEntity(spk)
  net.WriteString(tostring(p.id or ""))
  net.WriteString(p.stype or "MID")
  net.WriteFloat(p.ohm or 8)
  net.WriteFloat(p.rmsW or 100)
  net.WriteFloat(p.peakW or 200)
  net.WriteFloat(p.minAmpW or 50)
  net.WriteFloat(p.tapVolt or 0)
  net.WriteFloat(p.hifov or 120)
  net.WriteFloat(p.vifov or 120)
  net.SendToServer()
  return true
end

-- Saves the cabinet as a profile in the client's own folder, and puts it on
-- the cabinet so what was saved is what the cabinet now is.
function NTx.SaveSpeakerProfile(spk, name)
  if not IsValid(spk) then return false, "no cabinet" end
  local clean = NTx.SpkSanitiseName(name)
  if clean == "" then return false, "give the profile a name first" end
  local count = 0
  for _ in pairs(NTx.SavedSpeakerProfiles) do count = count + 1 end
  if count >= MAX_SAVED then return false, "profile limit reached (" .. MAX_SAVED .. ")" end
  local id = NTx.SpkMakeId(clean)
  if id == "" then return false, "that name cannot be used" end
  local p = {
    id = id, name = clean, stype = spk:GetSpeakerType(),
    ohm = spk:GetImpedance(), rmsW = spk:GetRmsW(), peakW = spk:GetPeakW(),
    minAmpW = spk:GetMinAmpW(), tapVolt = spk:GetTapVolt(),
    hifov = spk:GetMidHFov(), vifov = spk:GetMidVFov(), saved = true,
  }
  NTx.SavedSpeakerProfiles[id] = p
  saveProfileFile()
  bumpProfiles()
  NTx.ApplySpeakerProfile(spk, p)
  return true
end

-- Removes a profile from the client's folder. Nothing goes to the server: the
-- server never had a copy.
function NTx.DeleteSpeakerProfile(id)
  id = tostring(id or "")
  if not NTx.SavedSpeakerProfiles[id] then return false end
  NTx.SavedSpeakerProfiles[id] = nil
  saveProfileFile()
  bumpProfiles()
  return true
end

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
  local name = table.concat(args, " ")
  local ok, err = NTx.SaveSpeakerProfile(spk, name)
  if ok then print("[NTx] saved speaker profile \"" .. name .. "\"")
  else print("[NTx] " .. tostring(err)) end
end)

concommand.Add("ntx_spk_apply", function(_, _, args)
  local spk = aimedSpeaker()
  local id = table.concat(args, " ")
  if not spk or id == "" then print("[NTx] usage: aim at a ntx_speaker, then ntx_spk_apply <profile id>") return end
  local p = NTx.SpeakerProfileById(id)
  if not p then print("[NTx] no such profile: " .. id) return end
  NTx.ApplySpeakerProfile(spk, p)
end)

concommand.Add("ntx_spk_del", function(_, _, args)
  local id = table.concat(args, " ")
  if id == "" then print("[NTx] usage: ntx_spk_del <profile id>") return end
  if NTx.DeleteSpeakerProfile(id) then print("[NTx] deleted profile " .. id)
  else print("[NTx] no such profile: " .. id) end
end)

concommand.Add("ntx_spk_list", function()
  print("[NTx] built-in profiles: " .. table.concat(NTx.SpeakerProfileIds(), ", "))
  local saved = {}
  for id in pairs(NTx.SavedSpeakerProfiles) do saved[#saved + 1] = id end
  table.sort(saved)
  print("[NTx] saved profiles: " .. (#saved > 0 and table.concat(saved, ", ") or "(none)"))
end)
-- Reports the raw bus bits and what the server-side field lookup resolves to.
-- Three attempts at fixing the MID/SUB dropdown have failed, and "it looks
-- wrong in the panel" cannot distinguish a UI problem from a message that never
-- arrived or a write that was rejected. This prints the truth.
concommand.Add("ntx_amp_list", function()
  print("[NTx] amplifier profiles:")
  for _, id in ipairs(NTx.AmpProfileIds()) do
    local p = NTx.AmpProfile(id)
    print(string.format("  %-8s %-28s %s%s", id, p.name, p.model or "?",
      p.body ~= nil and ("  body=" .. tostring(p.body)) or ""))
  end
end)

concommand.Add("ntx_amp_bus", function(_, _, args)
  local ent = Entity(tonumber(args[1] or 0) or 0)
  if not IsValid(ent) or ent:GetClass() ~= "ntx_amplifier" then
    print("[NTx] usage: ntx_amp_bus <amplifier entity index>")
    return
  end
  print(string.format("[NTx] amp %d profile=%q channels=%d mixer=%s",
    ent:EntIndex(), tostring(ent:GetProfile()),
    math.floor(tonumber(ent:GetChannels()) or 0),
    IsValid(ent:GetMixer()) and ent:GetMixer():EntIndex() or "none"))
  for _, ch in ipairs(ent:ActiveChannels()) do
    -- What the channel is actually fed, as decided by its wiring.
    local id = ent:ChannelBusId(ch)
    if id ~= nil then
      print(string.format("    CH%d bus=%s (id %d)", ch, NTx.BusName(id), id))
    else
      print(string.format("    CH%d bus=NOT WIRED - wire a mixer bus to Ch%dIn", ch, ch))
    end
  end
end)

-- No util.AddNetworkString here: it is server-only, and calling it from a client
-- file raises "attempt to call field 'AddNetworkString' (a nil value)", which
-- aborts the rest of THIS file - silently taking ntx_chain with it. The server
-- half in ntx_amp_rms.lua declares both strings, which is the only place they
-- need declaring.

-- Prints the server's view of the whole level path, plus the two things only
-- this client knows: whether the page is running, and what arrived in the graph.
net.Receive("NTx.ChainRep", function()
  print(net.ReadString())
  print(string.format("client build: %s", tostring(NTx.COMMIT or "unknown")))
  print(string.format("page running=%s  graph: %d inputs %d speakers %d mixers",
    tostring(NTx.WebAudioRunning),
    #(NTx.Graph and NTx.Graph.inputs or {}),
    #(NTx.Graph and NTx.Graph.speakers or {}),
    #(NTx.Graph and NTx.Graph.mixers or {})))
end)

concommand.Add("ntx_chain", function()
  net.Start("NTx.ChainReq")
  net.SendToServer()
end)
