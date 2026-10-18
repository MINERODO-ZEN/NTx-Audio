-- GENERATED FILE - DO NOT EDIT BY HAND.
-- Produced by tools/build_pac3_leds.js from garrysmod/data/pac3/ntx/*.txt.
-- Re-run "node tools/build_pac3_leds.js" after editing a layout in PAC3.
--
-- Row layout, positional on purpose so a rig with many lamps stays cheap to
-- load:
--   1 kind      lamp name with any channel digits stripped ("signal", "odep")
--   2 channel   trailing digit from the lamp name, 0 when it has none
--   3,4,5 position   model space, x y z
--   6,7,8 rotation   degrees, pitch yaw roll
--   9,10,11 lens tint 0-255, used only while the lamp is dark
NTx = NTx or {}

-- Two lookup keys. The game tries byProfile[profile id] first and falls back
-- to byModel[model path], so one file can cover several profiles that share a
-- chassis and a per-profile file still wins once profiles get their own models.
NTx.PAC3_LEDS = {
  byModel = {
    ["models/props_lab/reciever01b.mdl"] = {
      { "signal", 1, 6.3514, 0.003, 2.073, 90, 0, 0, 0, 255, 63 },
      { "signal", 2, 6.3514, 3.8412, 2.073, 90, 0, 0, 0, 255, 63 },
      { "protect", 1, 6.3514, 1.2541, 2.073, 90, 0, 0, 255, 0, 0 },
      { "protect", 2, 6.3514, 2.591, 2.073, 90, 0, 0, 255, 0, 0 },
    },
  },
  byProfile = {
    ["testing"] = {
      { "signal", 1, 6.3514, 0.003, 2.073, 90, 0, 0, 0, 255, 63 },
      { "signal", 2, 6.3514, 3.8412, 2.073, 90, 0, 0, 0, 255, 63 },
      { "protect", 1, 6.3514, 1.2541, 2.073, 90, 0, 0, 255, 0, 0 },
      { "protect", 2, 6.3514, 2.591, 2.073, 90, 0, 0, 255, 0, 0 },
    },
  },
}
