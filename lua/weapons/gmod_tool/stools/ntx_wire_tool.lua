TOOL.Category = "Wire"
TOOL.Name = "#tool.ntx_wire.name"
TOOL.Command = nil
TOOL.ConfigName = ""

-- Dedicated NTx wiring tool. It exists for one reason: the stock wire tool
-- lists every port on an entity, which on these boxes means 30+ telemetry
-- outputs next to the handful that actually carry signal. This tool only offers
-- NTXSIG ports and only offers destinations that are legal for the source, so
-- Ch3Out cannot be dropped onto Ch1In by accident.
--
-- Wiring itself is done by Wiremod through WireLib, so links are real wires:
-- dupe-safe, visible with the stock tool, and readable by anything else.

if CLIENT then
  language.Add("tool.ntx_wire.name", "NTx Signal Wire")
  language.Add("tool.ntx_wire.left", "Start a signal at the entity you click")
  language.Add("tool.ntx_wire.right", "Click the destination entity to complete the link")
  language.Add("tool.ntx_wire.reload", "Cancel the pending link")
  language.Add("tool.ntx_wire.0", "Left-click a source entity (mixer, input, amplifier, cabinet)")
  language.Add("tool.ntx_wire.1", "Right-click a destination entity to link them")
  language.Add("tool.ntx_wire.desc", "Links only NTx signal ports. Telemetry ports are hidden.")
end

TOOL.Information = {
  { name = "left" },
  { name = "right" },
  { name = "reload" },
}

-- Which entity classes take part, and what each one offers as a source.
local SOURCES = {
  ntx_input_url = { { port = "Out", label = "Out" } },
  ntx_mixer = { { port = "Out", label = "Out" } },
  ntx_amplifier = { port = "Ch%dOut", per = "channels", label = "Ch%dOut" },
  ntx_speaker = { { port = "Out", label = "Out" } },
  ntx_fallback_bus = { { port = "Out", label = "Out" } },
}

local DESTS = {
  ntx_mixer = { { port = "In%d", upto = 16, label = "In%d" } },
  ntx_amplifier = { { port = "Ch%dIn", per = "channels", label = "Ch%dIn" } },
  ntx_speaker = { { port = "In", label = "In" } },
  ntx_fallback_bus = { { port = "In", label = "In" } },
}

-- A source may only reach these classes. This is the actual guard that stops
-- nonsense rigs: an amplifier output does not go back into a mixer channel, and
-- an input only ever feeds a mixer or a fallback bus.
local ALLOWED = {
  ntx_input_url = { ntx_mixer = true, ntx_fallback_bus = true },
  ntx_mixer = { ntx_amplifier = true },
  ntx_amplifier = { ntx_speaker = true },
  ntx_speaker = { ntx_speaker = true },
  ntx_fallback_bus = { ntx_amplifier = true },
}

-- Shared: the routing tables and the link predicate. Both realms need this, so
-- the client's holo outlines and the server's validation cannot disagree.
local function portsFor(ent, spec)
  local out = {}
  if not IsValid(ent) then return out end
  for _, s in ipairs(spec) do
    if s.port:find("%%d") then
      local n = s.per == "channels" and math.Clamp(math.floor(ent:GetChannels() or 2), 1, 8)
        or math.Clamp(s.upto or 1, 1, s.upto or 1)
      for i = 1, n do
        local p = s.port:format(i)
        if ent.Outputs and ent.Outputs[p] then out[#out + 1] = { port = p, label = s.label:format(i) } end
      end
    else
      if ent.Outputs and ent.Outputs[s.port] then
        out[#out + 1] = { port = s.port, label = s.label }
      end
    end
  end
  return out
end

-- The whole tool decision, from the two classes involved. Runs identically in
-- both realms so the HUD and the click agree.
function NTx.WireCanLink(srcEnt, dstEnt)
  if not IsValid(srcEnt) or not IsValid(dstEnt) then return false end
  if srcEnt == dstEnt then return false end
  local sc, dc = srcEnt:GetClass(), dstEnt:GetClass()
  local allow = ALLOWED[sc]
  if not allow or not allow[dc] then return false end
  if #portsFor(srcEnt, SOURCES[sc] or {}) == 0 then return false end
  if #portsFor(dstEnt, DESTS[dc] or {}) == 0 then return false end
  return true
end

if SERVER then
  util.AddNetworkString("NTx.WireLink")

  -- Pick concrete port names for a legal pair. Amplifier channels are paired by
  -- matching SUB/MID so a cabinet lands on a channel its bus agrees with;
  -- otherwise the lowest free channel wins.
  local function pickPorts(srcEnt, dstEnt)
    local sc, dc = srcEnt:GetClass(), dstEnt:GetClass()
    local outs = portsFor(srcEnt, SOURCES[sc] or {})
    local ins = portsFor(dstEnt, DESTS[dc] or {})
    if #outs == 0 or #ins == 0 then return nil end
    if dc ~= "ntx_amplifier" then
      return outs[1].port, ins[1].port
    end
    -- Amplifier: prefer a channel already wired to the same kind of source, so
    -- a mixer feeding a 4-channel amp spreads across channels instead of
    -- stacking everything on channel 1.
    local used = {}
    for i = 1, math.Clamp(math.floor(dstEnt:GetChannels() or 2), 1, 8) do
      local cur = dstEnt.Inputs and dstEnt.Inputs["Ch" .. i .. "In"]
      used[i] = IsValid(cur) and IsValid(cur.Src) or false
    end
    local first = nil
    for i = 1, #ins do
      local ch = tonumber(ins[i].port:match("^Ch(%d+)In$"))
      if ch and not used[ch] then
        first = ins[i]
        break
      end
    end
    return (first or ins[1]).port, outs[1].port
  end

  net.Receive("NTx.WireLink", function(_, ply)
    local src = net.ReadEntity()
    local dst = net.ReadEntity()
    if not IsValid(ply) or not IsValid(src) or not IsValid(dst) then return end
    if not NTx.WireCanLink(src, dst) then
      ply:ChatPrint("[NTx] Those two cannot be wired together.")
      return
    end
    -- Only the owning player (or an admin) may re-route a rig.
    local owner = dst.CPPIGetOwner and dst:CPPIGetOwner() or src.CPPIGetOwner and src:CPPIGetOwner()
    if not ply:IsAdmin() and IsValid(owner) and owner ~= ply then
      ply:ChatPrint("[NTx] You do not own that rig.")
      return
    end
    local inPort, outPort = pickPorts(src, dst)
    if not inPort then return end
    -- Replace an existing link on that input rather than stacking a second wire.
    if dst.Inputs and dst.Inputs[inPort] and IsValid(dst.Inputs[inPort].Src) then
      pcall(Wire_Link_Clear, dst, inPort)
    end
    pcall(Wire_Link_Start, ply, dst, dst:GetPos(), inPort)
    pcall(Wire_Link_End, ply, src, src:GetPos(), outPort)
    ply:ChatPrint("[NTx] Wired " .. src:GetClass() .. " [" .. outPort .. "] -> "
      .. dst:GetClass() .. " [" .. inPort .. "].")
    if NTx.WireTopologyTouch then NTx.WireTopologyTouch() end
  end)
end

function TOOL:LeftClick(trace)
  local ent = trace and trace.Entity
  if not IsValid(ent) or not SOURCES[ent:GetClass()] then return false end
  self:GetOwner():SetNWEntity("NtxWireSrc", ent)
  self:GetOwner():ChatPrint("[NTx] Signal source: " .. ent:GetClass()
    .. " [" .. ent:EntIndex() .. "]. Right-click the destination.")
  return true
end

function TOOL:RightClick(trace)
  local ent = trace and trace.Entity
  local ply = self:GetOwner()
  local src = ply:GetNWEntity("NtxWireSrc")
  if not IsValid(src) or not IsValid(ent) then return false end
  if not DESTS[ent:GetClass()] then return false end
  if not NTx.WireCanLink(src, ent) then
    ply:ChatPrint("[NTx] " .. src:GetClass() .. " cannot feed " .. ent:GetClass()
      .. ". Left-click to pick a different source.")
    return true
  end
  net.Start("NTx.WireLink")
  net.WriteEntity(src)
  net.WriteEntity(ent)
  net.SendToServer()
  ply:SetNWEntity("NtxWireSrc", NULL)
  return true
end

function TOOL:Reload(trace)
  self:GetOwner():SetNWEntity("NtxWireSrc", NULL)
  self:GetOwner():ChatPrint("[NTx] Link cancelled.")
  return true
end

function TOOL:DrawHUD()
  local ply = LocalPlayer()
  if not IsValid(ply) then return end
  local src = ply:GetNWEntity("NtxWireSrc")
  if not IsValid(src) then return end
  draw.SimpleText("NTx signal source: " .. src:GetClass() .. " [" .. src:EntIndex() .. "]",
    "DermaDefaultBold", ScrW() / 2, ScrH() - 140, Color(120, 255, 140, 230),
    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
  draw.SimpleText("Right-click a destination entity to wire it",
    "DermaDefault", ScrW() / 2, ScrH() - 120, Color(220, 220, 220, 200),
    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

function TOOL:Holos()
  local ply = LocalPlayer()
  if not IsValid(ply) then return end
  local src = ply:GetNWEntity("NtxWireSrc")
  if not IsValid(src) then return end
  -- Show which entities are legal destinations, so the player does not have to
  -- remember the routing table.
  local tr = ply:GetEyeTrace()
  local looking = tr and tr.Entity
  for _, cls in ipairs({ "ntx_mixer", "ntx_amplifier", "ntx_speaker", "ntx_fallback_bus" }) do
    for _, ent in ipairs(ents.FindByClass(cls)) do
      if IsValid(ent) and NTx.WireCanLink(src, ent) then
        local ok = looking == ent
        local col = ok and Color(120, 255, 120, 60) or Color(120, 255, 120, 25)
        render.SetColorMaterial()
        render.DrawWireframeSphere(ent:GetPos(), ent:OBBMaxs():Length() * 1.05, 12, 12, col)
      end
    end
  end
end