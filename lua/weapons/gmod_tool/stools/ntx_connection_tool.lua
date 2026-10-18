-- Tool: NTx Connections.
--
-- Wiring only: sources into mixers, cabinets into amplifiers, amplifiers into
-- mixers, plus the input/bus source settings. Amplifiers' internals live on
-- the Amplifier tool; cabinets' on the Speaker tool.
--
--   left-click    first the source, then the destination: input / cabinet /
--                 bus -> mixer, cabinet -> amplifier, mixer -> amplifier (opens
--                 the per-channel patch panel), amplifier on its own (same).
--                 Clicking a mixer with nothing pending opens its UI.
--   right-click   an input or fallback bus: apply its settings from this panel
--   reload       unlink the aimed entity from whatever it feeds; also clears
--                 the pending source selection
TOOL.Category = "NTx"
TOOL.Name = "#tool.ntx_connection_tool.name"
TOOL.Command = nil
TOOL.ConfigName = ""

TOOL.ClientConVar["url"] = "https://radio.plaza.one/mp3"
TOOL.ClientConVar["inivol"] = "1"
TOOL.ClientConVar["inimaxd"] = "1200"
TOOL.ClientConVar["bustrim"] = "1"
TOOL.ClientConVar["buslabel"] = ""
TOOL.ClientConVar["busflat"] = "0"

-- The tool system creates one client convar per ClientConVar entry, named
-- "<tool class>_<key>" (sandbox/entities/weapons/gmod_tool/stool.lua). The
-- panel controls have to bind to that exact name: DForm rows run
-- RunConsoleCommand on whatever they were given, so a bare key is just an
-- "Unknown command" every time a slider moves. The server side still asks for
-- the bare key, because GetClientInfo("busflat") resolves it from the table.
local function cv(key)
  return "ntx_connection_tool_" .. key
end

local function isLinkable(ent)
  return IsValid(ent) and (ent:GetClass() == "ntx_mixer" or ent:GetClass() == "ntx_speaker"
    or ent:GetClass() == "ntx_fallback_bus" or ent:GetClass() == "ntx_input_url"
    or ent:GetClass() == "ntx_amplifier")
end

-- Left: the two-click link. First click selects the source, second selects the
-- destination; the amplifier decides what "destination" means (a cabinet links
-- straight onto a channel, a mixer opens the bus picker instead of guessing).
function TOOL:LeftClick(tr)
  if CLIENT then return true end
  local ply = self:GetOwner()
  local ent = tr.Entity
  if not isLinkable(ent) then return false end
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
      ply:ChatPrint("[NTx] Linked " .. src:GetClass() .. " -> amplifier " .. ent:EntIndex() .. ".")
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
    -- No source pending: the amplifier's only outward link is to a mixer, so
    -- open its patch panel directly.
    ply:ConCommand("ntx_amp_patch " .. ent:EntIndex())
    return true
  end

  ply:SetNWEntity("NtxSrc", ent)
  ply:ChatPrint("[NTx] Source selected. Click a mixer or an amplifier to link.")
  return true
end

-- Right: apply the input / bus settings to the aimed source entity.
function TOOL:RightClick(tr)
  if CLIENT then return true end
  local ply = self:GetOwner()
  local ent = tr.Entity
  if not IsValid(ent) then return false end
  local cls = ent:GetClass()
  if cls == "ntx_input_url" then
    local url = string.sub(self:GetClientInfo("url"), 1, 512)
    if url ~= "" then ent:SetStreamUrl(url) end
    ent:SetInputVolume(NTx.ClampFader(self:GetClientNumber("inivol", 1)))
    ent:SetMaxDist(math.Clamp(self:GetClientNumber("inimaxd", 1200), 100, 10000))
    ply:ChatPrint(string.format("[NTx] Input: vol %.2f, maxd %d",
      ent:GetInputVolume(), math.Round(ent:GetMaxDist())))
  elseif cls == "ntx_fallback_bus" then
    ent:SetTrim(NTx.ClampFader(self:GetClientNumber("bustrim", 1)))
    ent:SetBusLabel(string.sub(self:GetClientInfo("buslabel"), 1, 32))
    local flat = self:GetClientNumber("busflat", 0) ~= 0
    local was = ent:GetFlat2D()
    ent:SetFlat2D(flat)
    ply:ChatPrint(string.format("[NTx] Bus: trim %.2f, %s%s", ent:GetTrim(),
      ent:GetFlat2D() and "2D stereo" or "3D positional",
      flat ~= was and " (changed)" or ""))
  else
    return false
  end
  NTx.BroadcastGraph()
  return true
end

-- Reload: detach, and forget any half-finished link.
function TOOL:Reload(tr)
  if CLIENT then return true end
  local ply = self:GetOwner()
  local ent = tr.Entity
  ply:SetNWEntity("NtxSrc", NULL)
  if not IsValid(ent) then return false end
  if ent:GetClass() == "ntx_speaker" and IsValid(ent:GetAmp()) then
    ent:SetAmp(NULL)
    ent:SetAmpChannel(0)
    ply:ChatPrint("[NTx] Cabinet unlinked from its amplifier.")
  elseif IsValid(ent:GetMixer()) then
    local mixer = ent:GetMixer()
    ent:SetMixer(NULL)
    if mixer.RemoveChannel then mixer:RemoveChannel(ent) end
    ply:ChatPrint("[NTx] " .. ent:GetClass() .. " unlinked from its mixer.")
  else
    return false
  end
  NTx.BroadcastGraph()
  return true
end

-- Note: dot syntax (static). The spawnmenu calls this as TOOL.BuildCPanel(panel).
function TOOL.BuildCPanel(panel)
  panel:AddControl("Header", { Description = "#tool.ntx_connection_tool.desc" })
  panel:AddControl("Label", {
    Text = "Left-click: source, then destination (input/cabinet/bus -> mixer, cabinet -> amplifier, mixer -> amplifier opens the patch panel).\nRight-click an input or bus: apply its settings. Reload: unlink.",
  })

  panel:AddControl("Label", { Text = "INPUT  (right-click a ntx_input_url)" })
  panel:AddControl("TextBox", { Label = "Stream URL", Command = cv("url") })
  panel:AddControl("Slider", {
    Label = "Input volume (0-2)", Command = cv("inivol"),
    Min = 0, Max = 2, Default = 1, Decimals = 2,
  })
  panel:AddControl("Slider", {
    Label = "Max distance (units)", Command = cv("inimaxd"),
    Min = 100, Max = 10000, Default = 1200, Decimals = 0,
  })

  panel:AddControl("Label", { Text = "FALLBACK BUS  (right-click a ntx_fallback_bus)" })
  panel:AddControl("Slider", {
    Label = "Bus trim (0-2)", Command = cv("bustrim"), Min = 0, Max = 2,
    Default = 1, Decimals = 2,
  })
  panel:AddControl("TextBox", { Label = "Bus label", Command = cv("buslabel") })
  -- Same DForm row as the amp and speaker tools: the label it binds is
  -- "ntsl_<tool>_<key>", and the pick has to be written into that convar here
  -- because RightClick reads it on the server.
  local right = panel:ComboBox("Bus playback", cv("busflat"))
  right:SetTall(26)
  right:AddChoice("3D positional", "0")
  right:AddChoice("2D stereo", "1")
  right.OnSelect = function(_, _, _, data)
    local cvar = GetConVar(cv("busflat"))
    if cvar and cvar:GetString() ~= tostring(data or "") then cvar:SetString(tostring(data or "")) end
  end
  local flat = GetConVarString(cv("busflat"))
  right:ChooseOptionID(flat)
  right:SetValue(flat)

  panel:AddControl("Label", { Text = "GIZMOS (owner-only: other players never see them)" })
  panel:AddControl("CheckBox", {
    Label = "Link lines (input / mixer / speaker / amplifier wiring)",
    Command = "ntx_gizmo_links",
  })
end

if CLIENT then
  language.Add("tool.ntx_connection_tool.name", "NTx Connections")
  language.Add("tool.ntx_connection_tool.desc", "Link sources, cabinets and amplifiers; configure inputs and buses")
  language.Add("tool.ntx_connection_tool.left", "Select source / link to mixer or amplifier / open its UI")
  language.Add("tool.ntx_connection_tool.right", "Apply settings to the aimed input or bus")
  language.Add("tool.ntx_connection_tool.reload", "Unlink the aimed entity")
end

TOOL.Information = { { name = "left" }, { name = "right" }, { name = "reload" } }
