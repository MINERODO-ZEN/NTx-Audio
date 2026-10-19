AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
  self:SetModel("models/props_lab/reciever01a.mdl")
  self:PhysicsInit(SOLID_VPHYSICS)
  self:SetMoveType(MOVETYPE_VPHYSICS)
  self:SetSolid(SOLID_VPHYSICS)
  local phys = self:GetPhysicsObject()
  if IsValid(phys) then phys:Wake() end
  if self:GetInputVolume() == 0 then self:SetInputVolume(1) end
  if self:GetMaxDist() == 0 then self:SetMaxDist(1200) end
  self.WireOut = -1
  self:CreateWirePorts()
  if NTx.InstallWireHooks then NTx.InstallWireHooks(self) end
end

-- Emits the input volume scaled by the measured programme level, once for each
-- bus the source could feed. This is not the audio: the client decodes StreamUrl
-- itself. The wire carries the level the source is producing so a mixer wired
-- downstream can route it into the right bus and the amplifier's load, heat and
-- speaker drive follow the music.
--
-- One level per bus, chosen by what that bus actually plays: MidL and SubL
-- carry the left programme, MidR and SubR the right, SubMono their sum. The
-- mixer decides which of them a given source feeds, per channel, which is what
-- the per-channel bus picker is for. With no measurement every slot stays at
-- the fader value alone.
function ENT:Think()
  self:NextThink(CurTime() + 0.1)
  local vol = math.Clamp(tonumber(self:GetInputVolume()) or 0, 0, 2)
  -- One level per BUS, not one level copied everywhere. The buses are
  -- side-specific, so publishing the same figure in all five slots is what made
  -- MidL and MidR indistinguishable and left every meter unable to reflect the
  -- side its channel was assigned.
  local rl = NTx.MeasuredRms and NTx.MeasuredRms(self, 0)
  local rr = NTx.MeasuredRms and NTx.MeasuredRms(self, 1)
  if rl then self.LastL = rl end
  if rr then self.LastR = rr end
  -- No measurement: hold the last real level. Falling back to 1 claims the
  -- source is at full scale, which is how a silent rig ends up looking like a
  -- loud one. First run has nothing to hold, so it starts at the fader default.
  -- shortcut: holds forever, so a source that stops reporting freezes at its
  -- last level instead of decaying to silence. Upgrade path if that ever
  -- matters: age self.LastL/self.LastR and fade, rather than a new mechanism.
  rl = rl or self.LastL or 1
  rr = rr or self.LastR or 1
  -- Energy-preserving sum, matching what a mono bus actually plays.
  local rmono = math.sqrt((rl * rl + rr * rr) * 0.5)
  local n = (NTx and NTx.BUS_COUNT) or 5
  local changed = false
  if not istable(self.WireBuses) then self.WireBuses = {} end
  for i = 1, n do
    local sd = (NTx and NTx.BusSideOf) and NTx.BusSideOf(i - 1) or 0
    local lvl = vol * ((sd == 0) and rl or (sd == 1) and rr or rmono)
    if self.WireBuses[i] ~= lvl then
      self.WireBuses[i] = lvl
      changed = true
    end
  end
  -- changed alone covers the first pass: WireBuses starts empty, so every slot
  -- differs from nil and the flag is set. There is deliberately no
  -- `self.WireOut = lvl` here - lvl is scoped to the loop body, so reading it
  -- out here would assign a global nil and defeat the sentinel entirely.
  if changed then
    -- A fresh table each time: Wiremod holds ARRAY values by reference, and
    -- mutating the one it already stores would not re-trigger the fan-out.
    local buses = {}
    for i = 1, n do buses[i] = self.WireBuses[i] end
    NTx.WireOut(self, "Buses", buses)
  end
end

function ENT:SpawnFunction(ply, tr)
  if not tr.Hit then return end
  local ent = ents.Create("ntx_input_url")
  ent:SetPos(tr.HitPos + tr.HitNormal * 8)
  ent:Spawn()
  ent:Activate()
  if CPPI then ent:CPPISetOwner(ply) end
  undo.Create("NTx Input")
  undo.AddEntity(ent)
  undo.SetPlayer(ply)
  undo.Finish()
  return ent
end

function ENT:PreEntityCopy()
  duplicator.StoreEntityModifier(self, "NtxInput", {
    url = self:GetStreamUrl(),
    vol = self:GetInputVolume(), maxd = self:GetMaxDist(),
  })
end

function ENT:PostEntityPaste(ply, ent, created)
  local d = ent.EntityMods and ent.EntityMods.NtxInput
  if d then
    self:SetStreamUrl(tostring(d.url or ""))
    self:SetInputVolume(NTx.ClampFader(d.vol))
    self:SetMaxDist(math.Clamp(tonumber(d.maxd) or 1200, 100, 10000))
  end
end
