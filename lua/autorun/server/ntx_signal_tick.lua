-- The signal chain runs from here, not from the entities' own Think.
--
-- GMod scales an entity's think frequency by its distance from the nearest
-- player: an entity out in the venue was being thought five times a second
-- while this hook runs at the tick rate. The measurement was arriving at
-- seventy-five hertz and the level still stepped, because the source only
-- republished when it was thought.
--
-- A hook is not distance-scaled, which is why the simulation has always run
-- at the rate it was asked for.
AddCSLuaFile()
if not SERVER then return end

local CLASSES = { "ntx_input_url", "ntx_mixer", "ntx_fallback_bus", "ntx_speaker" }

hook.Add("Think", "NTx.SignalTick", function()
  for i = 1, #CLASSES do
    for _, e in ipairs(ents.FindByClass(CLASSES[i])) do
      if IsValid(e) and e.UpdateSignal then
        local ok, err = pcall(e.UpdateSignal, e)
        if not ok then
          print("[NTx] signal tick: " .. CLASSES[i] .. " errored: " .. tostring(err))
        end
      end
    end
  end
end)
