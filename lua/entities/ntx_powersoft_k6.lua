-- Powersoft KK6, as its own entity class.
--
-- A profile is not a spawn button. GMod's spawn menu lists ENTITY CLASSES, so
-- five profiles sharing one class would all collapse into one entry that
-- spawns whichever profile the class defaults to. One class per model is what
-- makes them pickable.
--
-- The file name matters: lua/entities is loaded in alphabetical order, and a
-- derived class has to come AFTER its base or the base is not there to inherit
-- from. "ntx_powersoft_*" sorts after "ntx_amplifier" because 'a' < 'p'.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "ntx_amplifier"
ENT.PrintName = "Powersoft KK6"
ENT.Author = "NTx port"
ENT.Category = "Powersoft K Series"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.Editable = true

-- Applied by the base's Initialize, which falls back to the default profile
-- when this is absent. The body group comes with it: one chassis, five model
-- numbers, and the body is what tells them apart.
ENT.AmpProfileId = "k6"

DEFINE_BASECLASS( "ntx_amplifier" )
