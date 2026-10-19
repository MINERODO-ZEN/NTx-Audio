-- Spawn-menu side. The icon follows the model's own path, so
-- materials/spawnicons/<model>.png has to exist for it to resolve; profiles
-- without one fall back to the addon's own icon.
if not CLIENT then return end

local function addEntries()
  local tab = "NTx Audio"
  spawnmenu.AddCreationTab(tab, tab)
  for _, id in ipairs(NTx.AmpProfileIds()) do
    local p = NTx.AmpProfile(id)
    spawnmenu.AddCommand("ntx_spawn_amp_" .. id, p.name, p.model or "", "ntx_amplifier")
  end
end

hook.Add("InitPostEntity", "NTx.AmpSpawnMenu", function()
  hook.Add("PlayerSpawn", "NTx.AmpSpawnMenuApply", addEntries)
  addEntries()
end)

concommand.Add("ntx_amp_list", function()
  print("[NTx] amplifier profiles:")
  for _, id in ipairs(NTx.AmpProfileIds()) do
    local p = NTx.AmpProfile(id)
    print(string.format("  %-8s %-28s %s%s", id, p.name, p.model or "?",
      p.body ~= nil and ("  body=" .. tostring(p.body)) or ""))
  end
end)
