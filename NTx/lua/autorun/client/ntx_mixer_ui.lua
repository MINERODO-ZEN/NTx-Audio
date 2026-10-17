-- Client mixer UI: Derma port of AudioMixerScreen channel strips.
-- Lives in autorun/client so it executes with plain sibling includes.
if not CLIENT then return end
if NTx_MixerUILoaded then return end
NTx_MixerUILoaded = true

local openMixer = nil

local function sendBus(mixer, which, fader, muted)
  net.Start("NTx.MixerEdit")
  net.WriteEntity(mixer)
  net.WriteString("bus")
  net.WriteString(which)
  net.WriteFloat(NTx.ClampFader(fader))
  net.WriteBool(muted)
  net.SendToServer()
end

local function sendChannel(mixer, input, fader, muted, label)
  net.Start("NTx.MixerEdit")
  net.WriteEntity(mixer)
  net.WriteString("channel")
  net.WriteEntity(input)
  net.WriteFloat(NTx.ClampFader(fader))
  net.WriteBool(muted)
  net.WriteString(string.sub(label or "", 1, 24))
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
  local lbl = vgui.Create("DLabel", row)
  lbl:SetText(name)
  lbl:SetWide(70)
  lbl:Dock(LEFT)
  local slider = vgui.Create("DNumSlider", row)
  slider:Dock(FILL)
  slider:SetMinMax(0, 2)
  slider:SetDecimals(2)
  slider:SetValue(fader)
  local mute = vgui.Create("DCheckBoxLabel", row)
  mute:SetText("Mute")
  mute:SetValue(muted)
  mute:Dock(RIGHT)
  local db = vgui.Create("DLabel", row)
  db:SetWide(62)
  db:Dock(RIGHT)
  db:SetText(dbLabel(fader))
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

  busRow(scroll, "Master", "master", mixer)
  busRow(scroll, "MID bus", "mid", mixer)
  busRow(scroll, "SUB bus", "sub", mixer)

  local help = vgui.Create("DLabel", scroll)
  help:Dock(TOP)
  help:SetText("Channels follow linked inputs. Each input opens one stream at its mixer's fallback bus.")
  help:SetWrap(true)
  help:SetTall(30)

  local st = vgui.Create("DLabel", scroll)
  st:Dock(TOP)
  local backend = NTx.EffectiveBackend and NTx.EffectiveBackend() or "bass"
  if backend == "webaudio" then
    st:SetText("Backend: WebAudio - speakers live, fallback buses silent.")
  else
    st:SetText("Backend: BASS fallback - fallback buses live, speakers silent.")
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
      local name = vgui.Create("DLabel", top)
      name:SetText((ch.label ~= "" and ch.label or tostring(ch.input and ch.input:EntIndex() or "?")) .. " [" .. (ch.input and ch.input:GetClass() or "?") .. "]")
      name:Dock(LEFT)
      name:SetWide(260)
      local mute = vgui.Create("DCheckBoxLabel", top)
      mute:SetText("Mute")
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
      entry:SetValue(ch.label or "")
      entry:SetPlaceholderText("Label")
      local db = vgui.Create("DLabel", bot)
      db:SetWide(62)
      db:Dock(RIGHT)
      db:SetText(dbLabel(ch.fader))
      local apply = function()
        db:SetText(dbLabel(slider:GetValue()))
        sendChannel(mixer, ch.input, slider:GetValue(), mute:GetChecked(), entry:GetValue())
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
