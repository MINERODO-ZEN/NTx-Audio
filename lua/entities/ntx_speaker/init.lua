AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
  -- Never sleep. GMod puts an entity that is out of sight to sleep and stops
  -- calling its Think entirely, so a source that slept stopped publishing its
  -- level - and the mixer, the amplifier's input and the cabinets all
  -- inherited that rate. It looked like a slow measurement; it was a sleeping
  -- prop. These entities are the signal path, so they have to keep running.
  if self.SetNeverSleep then
    self:SetNeverSleep(true)
  else
    -- Said out loud rather than skipped: a missing method means the entity can
    -- still be put to sleep, and the level stops with it.
    print("[NTx] " .. self:GetClass() .. ": SetNeverSleep is not available")
  end
  self:CreateWirePorts()
  self.WireIn = 0
  self.WireOut = -1
  if NTx.InstallWireHooks then NTx.InstallWireHooks(self) end
  self:SetModel("models/hunter/blocks/cube025x025x025.mdl")
  self:SetMaterial("models/debug/debugwhite")
  self:SetColor(Color(30, 30, 30, 120))
  self:SetRenderMode(RENDERMODE_TRANSALPHA)
  self:PhysicsInit(SOLID_VPHYSICS)
  self:SetMoveType(MOVETYPE_VPHYSICS)
  self:SetSolid(SOLID_VPHYSICS)
  local phys = self:GetPhysicsObject()
  if IsValid(phys) then phys:Wake() end
  if self:GetSpeakerType() == "" then self:SetSpeakerType("MID") end
  if self:GetArrayId() == "" then self:SetArrayId("A") end
  -- MID coverage defaults: wide/shallow main PA (NTx-derived throw).
  if self:GetMidHFov() <= 0 then self:SetMidHFov(152) end
  if self:GetMidVFov() <= 0 then self:SetMidVFov(57) end
  -- Electrical defaults. An existing rig that predates the amplifier work
  -- still needs a sane impedance and power budget, so an empty profile picks up
  -- the archetype for its type instead of staying at zero (which the sim would
  -- read as a dead short).
  if self:GetProfile() == "" then
    self:ApplySpeakerProfile(self:GetSpeakerType() == "SUB" and "sub18" or "pa15")
  end
  if self:GetImpedance() <= 0 then self:SetImpedance(self:GetTapVolt() > 0 and 100 or 8) end
  if self:GetRmsW() <= 0 then self:SetRmsW(100) end
  if self:GetPeakW() <= 0 then self:SetPeakW(self:GetRmsW() * 2) end
end

-- ------------------------------------------------------------ wire signal

-- Level arrives from whatever drives this box. A blown or disabled cabinet
-- stops passing it on, so a series stack downstream goes quiet instead of
-- carrying a level the driver can no longer produce.
function ENT:TriggerInput(name, value)
  if name ~= "In" then return end
  self.WireIn = math.Clamp(tonumber(value) or 0, 0, 2)
end

-- Every OTHER cabinet in this speaker's chain, walked both ways.
--
-- "Chain" means the run of cabinets joined by the In/Out signal ports, so
-- A -> B -> C gives all three the same two-element list. Walking stops at
-- anything that is not a cabinet (an amplifier, a mixer), which is what keeps
-- two separate stacks from being reported as one chain. The `seen` set guards
-- against a loop someone wires by accident.
local function chainOf(self)
  local out, seen = {}, {}
  seen[self] = true

  local function step(ent, port)
    while IsValid(ent) and not seen[ent] do
      if ent:GetClass() ~= "ntx_speaker" then return end
      seen[ent] = true
      out[#out + 1] = ent
      ent = NTx.WireUpstream(ent, port)
    end
  end

  step(NTx.WireUpstream(self, "In"), "In")
  for _, d in ipairs(NTx.WireDownstream(self, "Out")) do
    step(d.ent, "In")
  end
  return out
end

-- Published from a server hook as well: GMod scales an entity's think
-- frequency by its distance from the nearest player.
function ENT:UpdateSignal()
  local out = 0
  if self:GetActive() then
    -- Self-powered cabinets are their own source; series wiring does not apply.
    out = 1
  elseif not self:GetBlown() then
    out = self.WireIn or 0
  end
  if out ~= self.WireOut then
    self.WireOut = out
    NTx.WireOut(self, "Out", out)
  end

  -- Republished whenever the chain changes, which link/unlink hooks cover.
  -- The signature is built from ent-indices, not the entities themselves:
  -- table.concat cannot stringify entity userdata and would error outright.
  local chain = chainOf(self)
  local ids = {}
  for i, e in ipairs(chain) do ids[i] = e:EntIndex() end
  local sig = table.concat(ids, ",")
  if sig ~= self.WireLinkSig then
    self.WireLinkSig = sig
    NTx.WireOut(self, "Link", chain)
  end
end

function ENT:SpawnFunction(ply, tr)
  if not tr.Hit then return end
  local ent = ents.Create("ntx_speaker")
  ent:SetPos(tr.HitPos + tr.HitNormal * 8)
  ent:Spawn()
  ent:Activate()
  if CPPI then ent:CPPISetOwner(ply) end
  undo.Create("NTx Speaker")
  undo.AddEntity(ent)
  undo.SetPlayer(ply)
  undo.Finish()
  return ent
end

function ENT:PreEntityCopy()
  local d = {}
  d.stype, d.arrayid, d.reversed = self:GetSpeakerType(), self:GetArrayId(), self:GetReversed()
  d.selfcard = self:GetSelfCardioid()
  d.hfov, d.vfov = self:GetMidHFov(), self:GetMidVFov()
  d.profile = self:GetProfile()
  d.imp, d.rmsw, d.peakw, d.minampw = self:GetImpedance(), self:GetRmsW(), self:GetPeakW(), self:GetMinAmpW()
  d.tapv, d.seriesgrp, d.active = self:GetTapVolt(), self:GetSeriesGroup(), self:GetActive()
  d.ampch = self:GetAmpChannel()
  duplicator.StoreEntityModifier(self, "NtxSpeaker", d)
end

function ENT:PostEntityPaste(ply, ent, created)
  local d = ent.EntityMods and ent.EntityMods.NtxSpeaker
  if d then
    self:SetSpeakerType(NTx.IsSpeakerType(d.stype) and d.stype or "MID")
    self:SetArrayId(tostring(d.arrayid or "A"))
    self:SetReversed(d.reversed == true)
    self:SetSelfCardioid(d.selfcard == true)
    self:SetMidHFov(math.Clamp(tonumber(d.hfov) or 152, 5, 360))
    self:SetMidVFov(math.Clamp(tonumber(d.vfov) or 57, 5, 360))
    self:SetProfile(tostring(d.profile or ""))
    self:SetImpedance(math.Clamp(tonumber(d.imp) or 8, 0.1, 100000))
    self:SetRmsW(math.Clamp(tonumber(d.rmsw) or 100, 0, 100000))
    self:SetPeakW(math.Clamp(tonumber(d.peakw) or 200, 0, 200000))
    self:SetMinAmpW(math.Clamp(tonumber(d.minampw) or 50, 0, 100000))
    self:SetTapVolt(math.Clamp(math.floor(tonumber(d.tapv) or 0), 0, 240))
    self:SetSeriesGroup(math.Clamp(math.floor(tonumber(d.seriesgrp) or 0), 0, 8))
    self:SetActive(d.active == true)
    self:SetAmpChannel(math.Clamp(math.floor(tonumber(d.ampch) or 0), 0, 8))
  end
  -- Duplication hands the rig to the player doing the work, so gizmos and
  -- link lines stay private to whoever is building.
  if ply and CPPI then self:CPPISetOwner(ply) end
end

function ENT:Think()
  self:NextThink(CurTime() + (NTx.SignalInterval and NTx.SignalInterval() or (1 / 60)))
  self:UpdateSignal()
end
