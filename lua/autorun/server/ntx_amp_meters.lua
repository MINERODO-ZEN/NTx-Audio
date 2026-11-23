-- Server: a small, fast message carrying only what the meters actually move on.
--
-- The full NTx.AmpSync is rate capped at ntx_amp_sync_hz (10 Hz by default)
-- because it carries mains, rail, fan, temperatures, damage and every
-- speaker's state - all of which move slowly. That cap also capped the meters,
-- because they were reading linDb out of the same payload, so the lamps could
-- not animate faster than 10 Hz no matter how fast the levels arrived.
--
-- This is the separate path the meters use instead: per amplifier, its entity
-- reference and one quantised input level per active channel, and nothing else.
-- The level is the simulation's own c.linDb, not a client-side blend of page
-- RMS and fader positions, so a lamp and the heat it causes come from the same
-- number and cannot disagree.
AddCSLuaFile()
if not SERVER then return end

NTx = NTx or {}

util.AddNetworkString("NTx.AmpMeters")

local lastSend = 0

local function meterInterval()
  local cv = GetConVar("ntx_meter_hz")
  return 1 / math.Clamp(cv and cv:GetFloat() or 66, 1, 130)
end

-- One dB value, offset so silence (-120) is still a positive number.
--
-- This WRITES. It used to compute the number and return it, and the call site
-- was a bare statement, so the level never went on the wire at all: the server
-- sent two bools per channel where the client expected a level and two bools.
-- Sixteen bits of drift per channel then desynchronised the whole message, and
-- amplifiers read each other's bytes - which is why one of them showed a
-- nonsense level that never changed while the others, whose data went to the
-- wrong entity, kept the correct value from the slow sync.
local function wdB(v)
  net.WriteUInt(math.Clamp(math.floor(((tonumber(v) or -120) + 130) * 20 + 0.5), 0, 65535), 16)
end

function NTx.BroadcastAmpMeters()
  if not NTx.AmpState then return end
  local now = CurTime()
  if now - lastSend < meterInterval() then return end
  lastSend = now

  NTx.AmpMeterSends = (NTx.AmpMeterSends or 0) + 1
  NTx.AmpMeterRate = NTx.AmpMeterSends
  local list = {}
  for amp, st in pairs(NTx.AmpState) do
    if IsValid(amp) then
      list[#list + 1] = { amp = amp, st = st, pos = amp:GetPos() }
    end
  end
  if #list == 0 then return end

  net.Start("NTx.AmpMeters")
  net.WriteUInt(#list, 6)
  for _, e in ipairs(list) do
    local amp, st = e.amp, e.st
    net.WriteEntity(amp)
    net.WriteUInt(amp:UsableChannels(), 4)
    for _, ch in ipairs(amp:ActiveChannels()) do
      local c = st[ch]
      wdB(c and c.linDb)
      net.WriteBool((c and c.clip or 0) > 1)
      net.WriteBool(c and c.protect == true)
    end
  end

  local cv = GetConVar("ntx_amp_sync_dist")
  local dist = math.Clamp(cv and cv:GetFloat() or 0, 0, 20000)
  if NTx.SendToAmpRange then
    NTx.SendToAmpRange(list, dist)
  else
    net.Broadcast()
  end
end