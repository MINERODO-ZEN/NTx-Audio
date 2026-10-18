-- Tool: NTx Connections.
--
-- Wiring plus the input/bus source settings. Amplifier settings live on the
-- Amplifier tool, cabinet settings on the Speaker tool.
--
--   left-click    first the source, then the destination: input / cabinet /
--                 bus -> mixer, cabinet -> amplifier, mixer -> amplifier (opens
--                 the per-channel patch panel). The same gesture works on the
--                 other two tools. Shift-click opens any NTx entity's panel
--   right-click   an input or fallback bus: apply its settings from this panel
--   reload        unlink the aimed entity from whatever it feeds; also clears
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

-- Left: the shared link/select gesture (ntx_net.lua). This tool is where linking
-- normally happens, but the same gesture is live on the other two, so a player
-- who picked up the wrong tool can still wire the rig. Shift-click opens any NTx
-- entity's panel.
function TOOL:LeftClick(tr)
  if CLIENT then return true end
  local ply = self:GetOwner()
  local ent = tr.Entity
  local _shift = NTx.ToolShift(ply)
  print("[NTX DBG] LeftClick " .. (IsValid(ent) and ent:GetClass() .. ":" .. ent:EntIndex() or "nil") .. " shift=" .. tostring(_shift))
  if _shift and NTx.OpenEntityGui(ply, ent) then return true end
  return NTx.ToolLinkClick(ply, ent)
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
    Text = "Left-click: source, then destination (input/cabinet/bus -> mixer, cabinet -> amplifier, mixer -> amplifier opens the patch panel). Shift-click opens any NTx entity panel. Right-click an input or bus: apply its settings. Reload: unlink.",
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
  local cvar = GetConVar(cv("busflat"))
  local flat = cvar and cvar:GetString() or ""
  -- Preselect by index: ChooseOptionID fires OnSelect, which is still the
-- no-op the base class provides, so nothing is written during panel build.
  right:ChooseOptionID(flat == "1" and 2 or 1)
  right.OnSelect = function(_, _, data)
    if cvar and cvar:GetString() ~= tostring(data or "") then cvar:SetString(tostring(data or "")) end
  end

  panel:AddControl("Label", { Text = "GIZMOS (owner-only: other players never see them)" })
  panel:AddControl("CheckBox", {
    Label = "Link lines (input / mixer / speaker / amplifier wiring)",
    Command = "ntx_gizmo_links",
  })
end

if CLIENT then
  language.Add("tool.ntx_connection_tool.name", "NTx Connections")
  language.Add("tool.ntx_connection_tool.desc", "Link sources, cabinets and amplifiers; configure inputs and buses")
  language.Add("tool.ntx_connection_tool.left", "Select source / link to mixer or amplifier (shift: open panel)")
  language.Add("tool.ntx_connection_tool.right", "Apply settings to the aimed input or bus")
  language.Add("tool.ntx_connection_tool.reload", "Unlink the aimed entity")
end

TOOL.Information = { { name = "left" }, { name = "right" }, { name = "reload" } }
