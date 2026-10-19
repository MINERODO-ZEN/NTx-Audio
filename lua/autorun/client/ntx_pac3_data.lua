-- GENERATED FILE - DO NOT EDIT BY HAND.
-- Produced by tools/build_pac3_leds.js from garrysmod/data/pac3/ntx/*.txt.
-- Re-run "node tools/build_pac3_leds.js" after editing a layout in PAC3.
--
-- Row layout, positional on purpose so a rig with many lamps stays cheap to
-- load:
--   1 kind      lamp name with any channel digits stripped ("signal", "odep")
--   2 channel   trailing digit from the lamp name, 0 when it has none
--   3 step      ladder step, 0 when it has none
--   4,5,6 position   model space, x y z
--   7,8,9 rotation   degrees, pitch yaw roll
--   10,11,12 lens tint 0-255, used only while the lamp is dark
--   13 size     diameter in model units, 0 when the layout records none
--
-- Everything is written exactly as PAC3 stored it. The size IS baked, because
-- a layout that records one means it: drawn at native scale instead, the lamps
-- of a model with small lenses came out eight times too big and merged into
-- blobs. PAC3's Scale is still not applied - it is a multiplier on the model
-- rather than a size, and no layout here uses it.
NTx = NTx or {}

-- Two lookup keys. The game tries byProfile[profile id] first and falls back
-- to byModel[model path], so one file can cover several profiles that share a
-- chassis and a per-profile file still wins once profiles get their own models.
NTx.PAC3_LEDS = {
  byModel = {
    ["models/minerodo/powersoft/powersoft_k.mdl"] = {
      { "meter", 2, 4, 8.238, 1.374, 0.18, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 1, 2, 8.238, 1.404, 0.24, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 1, 0, 8.238, 1.404, 0.63, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 1, 3, 8.238, 1.404, 0.03, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 2, 2, 8.238, 1.374, 0.24, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 2, 0, 8.238, 1.374, 0.63, 90, 0, 0, 33, 255, 0, 0.175 },
      { "fault", 1, 0, 8.238, 1.404, 0.622, 90, 0, 0, 255, 0, 0, 0.175 },
      { "fault", 2, 0, 8.238, 1.374, 0.622, 90, 0, 0, 255, 0, 0, 0.175 },
      { "meter", 1, 1, 8.238, 1.404, 0.44, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 2, 3, 8.238, 1.374, 0.03, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 1, 4, 8.238, 1.404, 0.18, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 2, 1, 8.238, 1.374, 0.44, 90, 0, 0, 33, 255, 0, 0.175 },
      { "protect", 2, 0, 8.238, 1.374, 0.402, 90, 0, 0, 255, 191, 0, 0.175 },
      { "protect", 1, 0, 8.238, 1.404, 0.402, 90, 0, 0, 255, 191, 0, 0.175 },
    },
    ["models/props_lab/reciever01b.mdl"] = {
      { "protect", 2, 0, 6.3514, 2.591, 2.073, 90, 0, 0, 255, 0, 0, 0 },
      { "fault", 0, 0, 6.2381, 6.2496, 2.8217, 90, 0, 0, 255, 0, 0, 0 },
      { "signal", 2, 0, 6.3514, 3.8412, 2.073, 90, 0, 0, 0, 255, 63, 0 },
      { "signal", 1, 0, 6.3514, 0.003, 2.073, 90, 0, 0, 0, 255, 63, 0 },
      { "protect", 1, 0, 6.3514, 1.2541, 2.073, 90, 0, 0, 255, 0, 0, 0 },
      { "power", 0, 0, 6.238, 7.4471, 2.8217, 90, 0, 0, 255, 191, 0, 0 },
    },
  },
  byProfile = {
    ["powersoft_k_line"] = {
      { "meter", 2, 4, 8.238, 1.374, 0.18, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 1, 2, 8.238, 1.404, 0.24, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 1, 0, 8.238, 1.404, 0.63, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 1, 3, 8.238, 1.404, 0.03, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 2, 2, 8.238, 1.374, 0.24, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 2, 0, 8.238, 1.374, 0.63, 90, 0, 0, 33, 255, 0, 0.175 },
      { "fault", 1, 0, 8.238, 1.404, 0.622, 90, 0, 0, 255, 0, 0, 0.175 },
      { "fault", 2, 0, 8.238, 1.374, 0.622, 90, 0, 0, 255, 0, 0, 0.175 },
      { "meter", 1, 1, 8.238, 1.404, 0.44, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 2, 3, 8.238, 1.374, 0.03, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 1, 4, 8.238, 1.404, 0.18, 90, 0, 0, 33, 255, 0, 0.175 },
      { "meter", 2, 1, 8.238, 1.374, 0.44, 90, 0, 0, 33, 255, 0, 0.175 },
      { "protect", 2, 0, 8.238, 1.374, 0.402, 90, 0, 0, 255, 191, 0, 0.175 },
      { "protect", 1, 0, 8.238, 1.404, 0.402, 90, 0, 0, 255, 191, 0, 0.175 },
    },
    ["testing"] = {
      { "protect", 2, 0, 6.3514, 2.591, 2.073, 90, 0, 0, 255, 0, 0, 0 },
      { "fault", 0, 0, 6.2381, 6.2496, 2.8217, 90, 0, 0, 255, 0, 0, 0 },
      { "signal", 2, 0, 6.3514, 3.8412, 2.073, 90, 0, 0, 0, 255, 63, 0 },
      { "signal", 1, 0, 6.3514, 0.003, 2.073, 90, 0, 0, 0, 255, 63, 0 },
      { "protect", 1, 0, 6.3514, 1.2541, 2.073, 90, 0, 0, 255, 0, 0, 0 },
      { "power", 0, 0, 6.238, 7.4471, 2.8217, 90, 0, 0, 255, 191, 0, 0 },
    },
  },
}
