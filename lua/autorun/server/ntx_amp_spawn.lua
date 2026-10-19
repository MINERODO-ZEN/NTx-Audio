-- Spawn-menu entries, one per amplifier profile.
--
-- A profile is more than a name here: it carries the body group that decides
-- which model number is printed on the front, so an entry cannot be "spawn the
-- entity and let the player pick later". Each entry names its profile and the
-- entity is created with it applied before it is handed over.
if not SERVER then return end

AddCSLuaFile("ntx_amp_spawnmenu.lua")

local SPAWN_OFFSET = 8

local function spawn(ply, id)
  local p = NTx.AmpProfile(id)
  if not p then return end
  local tr = ply:GetEyeTrace()
  if not tr.Hit then return end
  local ent = ents.Create("ntx_amplifier")
  if not IsValid(ent) then return end
  ent:SetPos(tr.HitPos + tr.HitNormal * SPAWN_OFFSET)
  ent:Spawn()
  ent:Activate()
  -- Before the owner is set, so CPPI catches it like any other spawned entity.
  if CPPI then ent:CPPISetOwner(ply) end
  ent:ApplyAmpProfile(p.id)
  undo.Create("NTx " .. p.name)
  undo.AddEntity(ent)
  undo.SetPlayer(ply)
  undo.Finish()
  return ent
end

for _, id in ipairs(NTx.AmpProfileIds()) do
  concommand.Add("ntx_spawn_amp_" .. id, function(ply) spawn(ply, id) end)
end
