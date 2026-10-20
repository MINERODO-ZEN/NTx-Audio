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
  -- The signal chain's rate, not a tenth of a second: this is one of three
  -- stages the measured level passes through on its way to the amplifier, and
  -- at ten hertz the level arriving there only changed ten times a second.
  self:NextThink(CurTime() + (NTx.SignalInterval and NTx.SignalInterval() or 1 / 60))
  local vol = math.Clamp(tonumber(self:GetInputVolume()) or 0, 0, 2)
  -- A source with no URL cannot play, so it contributes NOTHING. The fallback
  -- below is the fader position, which for a source that is not playing at all
  -- is a phantom at full scale: the amplifier saw a clipping signal from a
  -- player with nothing assigned, and the clip hold blinked the meters from
  -- full to zero.
  local silent = (tostring(self:GetStreamUrl() or "") == "")
  -- One level per BUS, straight from the page's band-limited measurement. The
  -- side split, the band split and the mono sum all happen there, because they
  -- are properties of the audio; redoing them here would only approximate what
  -- the page already measured properly.
  local n = (NTx and NTx.BUS_COUNT) or 5
  local changed = false
  if not istable(self.WireBuses) then self.WireBuses = {} end
  if not istable(self.LastBus) then self.LastBus = {} end
  for i = 1, n do
    local m = NTx.MeasuredRms and NTx.MeasuredRms(self, i - 1)
    if m then self.LastBus[i] = m end
    -- No measurement: hold the last real level. Falling back to 1 claims the
    -- source is at full scale, which is how a silent rig ends up looking like
    -- a loud one. First run has nothing to hold, so it starts at the fader.
    -- shortcut: holds forever, so a source that stops reporting freezes at its
    -- last level instead of decaying. Upgrade path: age LastBus and fade.
    local lvl = silent and 0 or (vol * (m or self.LastBus[i] or 1))
    if self.WireBuses[i] ~= lvl then
      self.WireBuses[i] = lvl
      changed = true
    end
  end
  -- changed alone covers the first pass: WireBuses starts empty, so every slot
  -- differs from nil and the flag is set. There is deliberately no
  -- `self.WireOut = lvl` here - lvl is scoped to the loop body, so reading it
  -- out here would assign a global nil and defeat the sentinel entirely.
  -- Measured on every tick, NOT inside the publish. Counting only the
  -- publishes meant the rate was recomputed only when a publish happened, so
  -- a source whose value stopped changing reported the last rate it ever
  -- achieved - a number for something that was no longer happening.
  --
  -- NOT named n: n is the number of BUSES, and shadowing it made the publish
  -- loop walk the publish count instead of the five buses - an ever growing
  -- number of indices into a five entry table. The loop got slower and
  -- slower, which is what the rate had fallen to.
  -- Three rates, counted separately, because they answer three different
  -- questions: how often the entity is TICKED, how often the value actually
  -- CHANGED, and how often it was PUBLISHED. When the last one is the odd one
  -- out, the value is what is not moving - and when the first one is, the
  -- entity is being throttled by something else entirely.
  local published = (self.PublishCount or 0)
  local changedCount = (self.ChangeCount or 0)
  local thinkCount = (self.ThinkCount or 0)
  local now = CurTime()
  if not self.PublishAt or (now - self.PublishAt) >= 1 then
    local elapsed = now - (self.PublishAt or (now - 1))
    if elapsed > 0 then
      self.PublishRate = (published - (self.PublishBase or 0)) / elapsed
      self.ChangeRate = (changedCount - (self.ChangeBase or 0)) / elapsed
      self.ThinkRate = (thinkCount - (self.ThinkBase or 0)) / elapsed
    end
    self.PublishAt = now
    self.PublishBase = published
    self.ChangeBase = changedCount
    self.ThinkBase = thinkCount
  end
  self.ThinkCount = thinkCount + 1
  -- Publish on a SCHEDULE, not only when the value changes.
  --
  -- A source that only republished on a change let the whole chain inherit
  -- the rate its number happened to change at: the mixer republished when the
  -- source did, and the amplifier's simulation only saw a new value when the
  -- mixer did. The measurement was arriving every tick and the level was
  -- still stepping. A level that is refreshed on a schedule cannot go stale,
  -- whatever the reason it stopped changing.
  local interval = NTx.SignalInterval and NTx.SignalInterval() or (1 / 66)
  if changed then self.ChangeCount = changedCount + 1 end
  if changed or (now - (self.LastPublishAt or 0)) >= interval then
    self.LastPublishAt = now
    self.PublishCount = published + 1
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
