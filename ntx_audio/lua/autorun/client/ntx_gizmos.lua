-- Client: owner-only rig gizmos and link lines.
-- Two independent toggles (both off by default):
--   ntx_gizmo_speakers  arrows + label on speaker nodes
--   ntx_gizmo_links     input <-> mixer <-> speaker wiring lines
-- Nothing here is drawn unless the local player owns the entity, so other
-- players never see your build scaffolding. Entities with no CPPI owner
-- (spawned before ownership existed, or from a map) stay visible to
-- everyone so existing builds do not silently lose their helpers.
if not CLIENT then return end
if NTx_GizmosLoaded then return end
NTx_GizmosLoaded = true

local cvSpeakers = CreateClientConVar("ntx_gizmo_speakers", "0", true, false,
  "Show owner-only speaker gizmos: up arrow, front arrow and label")
local cvLinks = CreateClientConVar("ntx_gizmo_links", "0", true, false,
  "Show owner-only link lines between inputs, mixers and speakers")
local cvCones = CreateClientConVar("ntx_gizmo_cones", "0", true, false,
  "Show owner-only coverage cone wedges (horizontal + vertical FOV)")
local cvConeLen = CreateClientConVar("ntx_cone_len", "72", true, false,
  "Coverage wedge length in units")

local C_SPEAKER = Color(90, 170, 255)
local C_SUB = Color(255, 150, 90)
local C_MID = Color(120, 220, 140)
local C_INPUT = Color(200, 200, 120)
local C_MIXER = Color(220, 220, 220)
local C_AMP = Color(245, 210, 120)

function NTx.IsMine(ent)
  local ply = LocalPlayer()
  if not IsValid(ply) or not IsValid(ent) then return false end
  local owner = ent.CPPIGetOwner and ent:CPPIGetOwner()
  if not IsValid(owner) then return true end -- legacy/unowned: visible
  return owner == ply
end

local function arrow(from, to, col)
  render.SetColorMaterial()
  render.DrawLine(from, to, col, true)
  local dir = to - from
  local len = dir:Length()
  if len < 0.01 then return end
  dir:Div(len)
  local side = dir:Cross(Vector(0, 0, 1))
  if side:Length() < 0.01 then side = dir:Cross(Vector(1, 0, 0)) end
  side:Normalize()
  local up = dir:Cross(side)
  local size = math.min(len * 0.35, 8)
  local tip = to - dir * size
  render.DrawLine(tip, tip + side * size * 0.45, col, true)
  render.DrawLine(tip, tip + up * size * 0.45, col, true)
  render.DrawLine(tip, tip - side * size * 0.45, col, true)
  render.DrawLine(tip, tip - up * size * 0.45, col, true)
end

local function speakerColor(s)
  return s.stype == "SUB" and C_SUB or C_MID
end

-- Gizmo transforms come from the LIVE entity, not the cached graph snapshot.
-- The engine already moves and interpolates the entity every frame, so
-- reading GetPos/GetAngles here parents the overlay to the rig for free:
-- no timer, no 0.5 s staircase when a stack is physgunned. The snapshot
-- pos/ang stays only as a fallback for the brief window where the graph
-- knows a node whose entity is not yet valid locally.
local function livePos(s)
  if IsValid(s.ent) then return s.ent:GetPos() end
  return s.pos
end

local function liveAng(s)
  if IsValid(s.ent) then return s.ent:GetAngles() end
  return s.ang or Angle(0, 0, 0)
end

local function drawSpeakerGizmo(s)
  local pos = livePos(s)
  if not pos then return end
  local ang = liveAng(s)
  local fwd = ang:Forward()
  local col = speakerColor(s)
  -- up: which way the box is aimed vertically
  arrow(pos, pos + Vector(0, 0, 40), Color(col.r, col.g, col.b, 90))
  -- front: facing / throw direction
  arrow(pos, pos + fwd * 36, col)
  local tag = s.stype .. " [" .. s.array .. "]"
  if s.reversed then tag = tag .. " REV" end
  if s.selfcard then tag = tag .. " SC" end
  local tpos = pos + Vector(0, 0, 44)
  local tang = (IsValid(LocalPlayer()) and LocalPlayer():EyeAngles() or Angle(0, 0, 0))
  tang:RotateAroundAxis(tang:Forward(), 90)
  tang:RotateAroundAxis(tang:Right(), 90)
  cam.Start3D2D(tpos, Angle(0, tang.y, 90), 0.22)
    draw.SimpleText(tag, "DermaDefault", 0, 0, Color(255, 255, 255, 220),
      TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
  cam.End3D2D()
end

local function entPos(ent)
  return IsValid(ent) and ent:GetPos() or nil
end

-- Coverage cone outline: an arc of `halfAngle` about `fwd` in the plane
-- spanned by (fwd, side), with spokes back to the apex. Drawn twice per
-- speaker - horizontal plane (fwd, right) and vertical plane (fwd, up) - so
-- an elliptical FOV reads as a 3D wedge instead of a flat circle.
-- Coverage wedge: a solid translucent triangle fan from the grille along one
-- axis, plus a brighter rim at the outer angle so the coverage edge reads.
-- Solid beats wireframe here because a wireframe of overlapping stacks at
-- ignoreZ was unreadable noise.
--
-- Depth testing is ON (no ignoreZ on the rim): walls and floors correctly cut
-- the wedge instead of the cone drawing straight through the map.
local CONE_SEG = 14

-- Fill material: plain "vgui/null", resolved lazily (never at file load,
-- when the material system may hand back an error material - that is what
-- produced the purple/black missing-texture wedges). No shared stock
-- material is mutated. If the path ever resolves to an error material we
-- fall back to the untextured color material plus a global alpha blend,
-- so the wedges still render instead of checkering.
local coneMat -- nil = untried, false = failed, IMaterial = usable
local function getConeMat()
  if coneMat == nil then
    local m = Material("vgui/null")
    coneMat = (m and not m:IsError()) and m or false
  end
  return coneMat or nil
end

local function coneBasis(ang)
  -- Re-orthogonalise from forward so a tilted/rolled cabinet still gets a
  -- clean basis (and a usable one when the cabinet looks straight up).
  local f = ang:Forward():GetNormalized()
  local r = f:Cross(Vector(0, 0, 1))
  if r:Length() < 0.001 then r = f:Cross(Vector(1, 0, 0)) end
  r:Normalize()
  local u = r:Cross(f):GetNormalized()
  return f, r, u
end

local function drawWedge(apex, fwd, side, halfAngle, length, fill, rim)
  -- Clamp below 90 degrees: at exactly 90 the fan's rim points cross the
  -- apex plane and the triangle strip degenerates.
  halfAngle = math.Clamp(halfAngle, math.rad(1), math.rad(89))
  local SEG = CONE_SEG
  local pts = {}
  for i = 0, SEG do
    local a = -halfAngle + (2 * halfAngle) * (i / SEG)
    local d = fwd * math.cos(a) + side * math.sin(a)
    if d:Length() < 0.001 then d = fwd end
    d:Normalize()
    pts[i + 1] = apex + d * length
  end

  local m = getConeMat()
  local useBlend = (m == nil)
  if m then
    render.SetMaterial(m)
  else
    -- Fallback path: the untextured color material is opaque, so drive
    -- translucency through the global blend factor instead.
    render.SetColorMaterial()
    render.SetBlend((fill.a or 255) / 255)
  end
  for i = 2, SEG + 1 do
    -- GMod has no render.DrawTriangle: a quad whose last two corners
    -- coincide degenerates to a triangle (apex, p[i-1], p[i]).
    render.DrawQuad(apex, pts[i - 1], pts[i], pts[i],
      fill.r, fill.g, fill.b, fill.a)
  end
  if useBlend then render.SetBlend(1) end

  render.SetColorMaterial()
  render.DrawLine(apex, pts[1], rim, false)
  for i = 2, SEG + 1 do
    render.DrawLine(pts[i - 1], pts[i], rim, false)
  end
  render.DrawLine(apex, pts[SEG + 1], rim, false)
end

local function drawCoverage(s)
  if s.stype ~= "MID" then return end
  local pos = livePos(s)
  if not pos then return end
  local ang = liveAng(s)
  local f, r, u = coneBasis(ang)
  local apex = pos + f * 6
  local len = math.Clamp(cvConeLen:GetFloat() or 72, 8, 400)
  if s.selfcard then
    -- Self-cardioid is a horizontal cardioid: one wedge, pink.
    drawWedge(apex, f, u, math.rad(90), len, Color(255, 130, 200, 34), Color(255, 150, 210, 200))
    return
  end
  local a = NTx.MidConeAngles((s.hFov ~= 0) and s.hFov or 152, (s.vFov ~= 0) and s.vFov or 57)
  -- Horizontal coverage (green) and vertical coverage (blue) as separate,
  -- differently coloured wedges so an elliptical FOV is readable at a glance.
  drawWedge(apex, f, r, math.rad(a.HOutFull), len, Color(120, 255, 170, 30), Color(140, 255, 180, 210))
  drawWedge(apex, f, u, math.rad(a.VOutFull), len, Color(130, 190, 255, 26), Color(150, 200, 255, 210))
end

hook.Add("PostDrawTranslucentRenderables", "NTx.Gizmos", function(depth, sky)
  if depth or sky then return end
  local ply = LocalPlayer()
  if not IsValid(ply) then return end
  local wantSpeakers = cvSpeakers:GetBool()
  local wantLinks = cvLinks:GetBool()
  local wantCones = cvCones:GetBool()
  if not wantSpeakers and not wantLinks and not wantCones then return end
  local g = NTx.Graph
  if not g then return end

  render.SetColorMaterial()

  if wantSpeakers then
    for _, s in ipairs(g.speakers or {}) do
      if IsValid(s.ent) and NTx.IsMine(s.ent) then drawSpeakerGizmo(s) end
    end
  end

  -- Cones are their own switch: they are the busiest overlay, so they stay
  -- off even when arrows/labels are on.
  if wantCones then
    for _, s in ipairs(g.speakers or {}) do
      if IsValid(s.ent) and NTx.IsMine(s.ent) then drawCoverage(s) end
    end
  end

  if wantLinks then
    -- input -> mixer
    for _, inp in ipairs(g.inputs or {}) do
      if IsValid(inp.ent) and IsValid(inp.mixer) and NTx.IsMine(inp.ent) then
        local a, b = entPos(inp.ent), entPos(inp.mixer)
        if a and b then arrow(a, b, C_INPUT) end
      end
    end
    -- mixer -> speaker
    for _, s in ipairs(g.speakers or {}) do
      if IsValid(s.ent) and IsValid(s.mixer) and NTx.IsMine(s.ent) then
        local a, b = entPos(s.ent), entPos(s.mixer)
        if a and b then arrow(a, b, speakerColor(s)) end
      end
    end
    -- mixer -> fallback bus (fallback wiring)
    for _, fb in ipairs(g.fallbacks or {}) do
      if IsValid(fb.ent) and IsValid(fb.mixer) and NTx.IsMine(fb.ent) then
        local a, b = entPos(fb.ent), entPos(fb.mixer)
        if a and b then arrow(a, b, C_MIXER) end
      end
    end
    -- mixer -> amplifier -> cabinet: the signal path, so a rig that is patched
    -- wrong reads as a chain instead of a scatter of speakers.
    for _, amp in ipairs(ents.FindByClass("ntx_amplifier")) do
      if IsValid(amp) and NTx.IsMine(amp) then
        local a = entPos(amp)
        if a then
          if IsValid(amp:GetMixer()) then
            local b = entPos(amp:GetMixer())
            if b then arrow(b, a, C_AMP) end
          end
          for _, spk in ipairs(g.speakers or {}) do
            if IsValid(spk.ent) and spk.ent:GetAmp() == amp and a then
              local b = entPos(spk.ent)
              if b then arrow(a, b, C_AMP) end
            end
          end
        end
      end
    end
  end
end)