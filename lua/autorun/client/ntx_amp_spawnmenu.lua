-- Spawn-menu entries, one per amplifier profile.
--
-- A profile is not a button. GMod's stock spawn menu lists ENTITY CLASSES, and
-- every Powersoft model is the same ntx_amplifier class, so all five would
-- collapse into one entry and whichever profile it applied would be a guess.
-- Each model therefore registers its own command and its own button.
if not CLIENT then return end

-- ULib replaces the global spawnmenu table with its own, and that table has no
-- AddCommand. There is nothing to shadow - the function simply is not there -
-- so defining it restores the one entry point this file needs. Running the
-- command is all a spawn button does anyway.
local function ensureSpawnApi()
  if not spawnmenu then return false, "spawnmenu table missing" end
  if not spawnmenu.AddCommand then
    spawnmenu.AddCommand = function(_, _, _, cmd)
      RunConsoleCommand(tostring(cmd))
    end
  end
  if not spawnmenu.AddCreationTab then return false, "AddCreationTab missing" end
  return true
end

-- A tab of its own, deliberately. GMod's stock creation tabs list ENTITY
-- CLASSES, and every Powersoft model is the same ntx_amplifier class, so in
-- the shared "NTx Audio" tab they would all collapse into one entry beside
-- the mixer and the speaker. Their own tab keeps each model a button you can
-- actually pick out of the list.
local TAB = "Powersoft K Series"
local added = false

local function addEntries()
  if added then return end
  local ok, why = ensureSpawnApi()
  if not ok then
    ErrorNoHalt("[NTx] spawn menu: " .. tostring(why) .. "; no amplifier entries added.\n")
    return
  end
  spawnmenu.AddCreationTab("ntx_amp", TAB)
  local n = 0
  for _, id in ipairs(NTx.AmpProfileIds()) do
    local p = NTx.AmpProfile(id)
    local cmd = "ntx_spawn_amp_" .. id
    -- The command is the fourth argument. Passing the class name here is what
    -- would have produced a button that opens nothing.
    spawnmenu.AddCommand(cmd, p.name, p.model or "", cmd)
    n = n + 1
  end
  added = true
  print(string.format("[NTx] spawn menu: %d amplifier entries in '%s'.", n, TAB))
end

hook.Add("InitPostEntity", "NTx.AmpSpawnMenu", addEntries)
hook.Add("PlayerSpawn", "NTx.AmpSpawnMenuRespawn", addEntries)

concommand.Add("ntx_amp_list", function()
  print("[NTx] amplifier profiles:")
  for _, id in ipairs(NTx.AmpProfileIds()) do
    local p = NTx.AmpProfile(id)
    print(string.format("  %-8s %-28s %s%s", id, p.name, p.model or "?",
      p.body ~= nil and ("  body=" .. tostring(p.body)) or ""))
  end
  addEntries()
end)
