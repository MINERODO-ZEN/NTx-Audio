-- Client mixer UI: Derma port of AudioMixerScreen channel strips.
-- Lives in autorun/client so it executes with plain sibling includes.
if not CLIENT then return end
if NTx_MixerUILoaded then return end
NTx_MixerUILoaded = true

local openMixer = nil

-- Derma's label ink is inherited from the active skin, which on this dark
-- mixer frame left every caption sitting almost on top of the background.
-- Text is coloured explicitly here so contrast never depends on the skin.
local COL_TEXT = Color(240, 240, 240)
local COL_DIM = Color(200, 200, 200)

local function label(parent, txt, col)
  local lbl = vgui.Create("DLabel", parent)
  lbl:SetText(txt)
  lbl:SetTextColor(col or COL_TEXT)
  return lbl
end

local function checkLabel(parent, txt)
  local chk = vgui.Create("DCheckBoxLabel", parent)
  chk:SetText(txt)
  chk:SetTextColor(COL_TEXT)
  return chk
end

local function sendBus(mixer, which, fader, muted)
  net.Start("NTx.MixerEdit")
  net.WriteEntity(mixer)
  net.WriteString("bus")
  net.WriteString(which)
  net.WriteFloat(NTx.ClampFader(fader))
  net.WriteBool(muted)
  net.SendToServer()
end

-- The bus a channel feeds goes last so an older client that stops after the
-- label leaves the existing assignment alone.
local function sendChannel(mixer, input, fader, muted, text)
  net.Start("NTx.MixerEdit")
  net.WriteEntity(mixer)
  net.WriteString("channel")
  net.WriteEntity(input)
  net.WriteFloat(NTx.ClampFader(fader))
  net.WriteBool(muted)
  net.WriteString(string.sub(text or "", 1, 24))
  net.SendToServer()
end

local function mixerRec(ent)
  for _, m in ipairs(NTx.Graph.mixers) do
    if m.ent == ent then return m end
  end
  return nil
end

-- Faders are logarithmic: slider position 0..2 maps to -60..+6 dB with
-- unity at 1, so the label always shows real dB instead of raw position.
local function dbLabel(v)
  local db = NTx.GainToDb(NTx.FaderToGain(v))
  if db <= -59.5 then return "-inf dB" end
  return string.format("%+.1f dB", db)
end

local function busRow(parent, name, which, mixer)
  local rec = mixerRec(mixer)
  local fader = rec and rec[which] or 1
  local muted = rec and rec[which .. "m"] or false
  if which == "master" then fader, muted = rec and rec.master or 1, rec and rec.mm or false end

  local row = vgui.Create("DPanel", parent)
  row:Dock(TOP)
  row:SetTall(36)
  row:DockMargin(4, 4, 4, 0)
  row.Paint = function(_, w, h)
    draw.RoundedBox(4, 0, 0, w, h, Color(24, 24, 28))
  end
  local lbl = label(row, name)
  lbl:SetFont("DermaDefaultBold")
  lbl:SetWide(70)
  lbl:Dock(LEFT)
  local slider = vgui.Create("DNumSlider", row)
  slider:Dock(FILL)
  slider:SetMinMax(0, 2)
  slider:SetDecimals(2)
  slider:SetValue(fader)
  if slider.TextEntry then slider.TextEntry:SetTextColor(COL_TEXT) end
  local mute = checkLabel(row, "Mute")
  mute:SetValue(muted)
  mute:Dock(RIGHT)
  local db = label(row, dbLabel(fader), COL_DIM)
  db:SetWide(62)
  db:Dock(RIGHT)
  slider.OnValueChanged = function(_, v)
    db:SetText(dbLabel(v))
    sendBus(mixer, which, v, mute:GetChecked())
  end
  mute.OnChange = function(_, v) sendBus(mixer, which, slider:GetValue(), v) end
end

function NTx.OpenMixerUI(mixer)
  if not IsValid(mixer) then return end
  if IsValid(openMixer) then openMixer:Close() end
  local rec = mixerRec(mixer)

  local frame = vgui.Create("DFrame")
  frame:SetTitle("NTx Mixer - " .. mixer:EntIndex())
  frame:SetSize(math.min(520, ScrW() * 0.6), math.min(560, ScrH() * 0.75))
  frame:Center()
  frame:MakePopup()
  openMixer = frame

  local scroll = vgui.Create("DScrollPanel", frame)
  scroll:Dock(FILL)
  scroll.Paint = function(_, w, h) draw.RoundedBox(0, 0, 0, w, h, Color(20, 20, 24)) end

  busRow(scroll, "Master", "master", mixer)
  busRow(scroll, "MID bus", "mid", mixer)
  busRow(scroll, "SUB bus", "sub", mixer)

  local help = label(scroll,
    "Channels follow linked inputs. Each input opens one stream at its mixer's fallback bus.", COL_DIM)
  help:Dock(TOP)
  help:SetWrap(true)
  help:SetTall(30)

  local st = vgui.Create("DLabel", scroll)
  st:Dock(TOP)
  st:SetTextColor(COL_DIM)
  local backend = NTx.EffectiveBackend and NTx.EffectiveBackend() or "bass"
  if backend == "webaudio" then
    st:SetText("Backend: WebAudio - speakers live, fallback buses silent.")
  elseif NTx.FallbackAllowed and NTx.FallbackAllowed() then
    st:SetText("Backend: BASS fallback - fallback buses live, speakers silent.")
  else
    -- WebAudio selected but the capability probe has not answered yet: the
    -- buses are muted so a capable client never hears both backends.
    st:SetText("Backend: waiting on the WebAudio capability probe - fallback buses muted until it answers.")
  end
  st:SetWrap(true)
  st:SetTall(30)

  if rec then
    for _, ch in ipairs(rec.channels) do
      local row = vgui.Create("DPanel", scroll)
      row:Dock(TOP)
      row:SetTall(64)
      row:DockMargin(4, 4, 4, 0)
      local top = vgui.Create("DPanel", row)
      top:Dock(TOP)
      top:SetTall(28)
      top:SetPaintBackground(false)
      local name = label(top,
        (ch.label ~= "" and ch.label or tostring(ch.input and ch.input:EntIndex() or "?")) .. " [" .. (ch.input and ch.input:GetClass() or "?") .. "]")
      name:SetFont("DermaDefaultBold")
      name:Dock(LEFT)
      name:SetWide(260)
      local mute = checkLabel(top, "Mute")
      mute:SetValue(ch.muted)
      mute:Dock(RIGHT)
      local bot = vgui.Create("DPanel", row)
      bot:Dock(FILL)
      bot:SetPaintBackground(false)
      local slider = vgui.Create("DNumSlider", bot)
      slider:Dock(FILL)
      slider:SetMinMax(0, 2)
      slider:SetDecimals(2)
      slider:SetValue(ch.fader)
      local entry = vgui.Create("DTextEntry", bot)
      entry:Dock(BOTTOM)
      entry:SetTextColor(COL_TEXT)
      entry:SetValue(ch.label or "")
      entry:SetPlaceholderText("Label")
      local db = label(bot, dbLabel(ch.fader), COL_DIM)
      db:SetWide(62)
      db:Dock(RIGHT)
      local apply = function()
        db:SetText(dbLabel(slider:GetValue()))
        sendChannel(mixer, ch.input, slider:GetValue(), mute:GetChecked(),
          entry:GetValue())
      end
      slider.OnValueChanged = function() apply() end
      mute.OnChange = function() apply() end
      entry.OnEnter = function() apply() end
    end
  end
end

concommand.Add("ntx_open_mixer", function(_, _, args)
  local ent = Entity(tonumber(args[1] or 0) or 0)
  if IsValid(ent) and ent:GetClass() == "ntx_mixer" then NTx.OpenMixerUI(ent) end
end)
