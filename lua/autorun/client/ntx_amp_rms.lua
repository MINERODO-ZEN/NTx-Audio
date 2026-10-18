-- Client: forward the page's measured levels to the server.
--
-- The WebAudio page already measures real source RMS through an analyser and
-- hands it to NTx.WebAudioOnStatus, which stores it in NTx.PageRms keyed by
-- input entity. The meters read that locally. This file is the other half: it
-- pushes the same numbers to the server so the authoritative simulation - mains
-- draw, output watts, thermal load and speaker drive - follows the music
-- instead of sitting on the fader positions.
--
-- The cadence is not chosen here. The server decides, because it is the only
-- party that knows who owns an amplifier, and a client-chosen rate is a client
-- that can flood the server.
AddCSLuaFile()
if not CLIENT then return end

NTx = NTx or {}

local cadence = 0.25          -- seconds between reports; the server overwrites this
local nextSend = 0
local announced = false

-- The server tells us how often to report.
-- net.Receive, not a hypothetical AddReceiver: that is the name GMod actually
-- has, and it is the same call every other receiver in this addon uses.
net.Receive("NTx.AmpRmsCadence", function()
  local secs = net.ReadFloat()
  if secs <= 0 then return end
  cadence = math.Clamp(secs, 0.005, 1)
  -- Published so a page created later picks the same interval up.
  NTx.RmsCadence = cadence
  -- The page samples the analyser on its own timer, so it has to be told the
  -- same interval; otherwise it reports at its old fixed 20 Hz and a tick-rate
  -- consumer would only ever see aliased level steps.
  for _, p in pairs(NTx.WebAudio.Pages or {}) do
    if p and p.panel and IsValid(p.panel) then
      pcall(p.panel.Call, p.panel, "ntxSetMeterInterval(" .. string.format("%.4f", cadence) .. ")")
    end
  end
end)

-- Claim (or withdraw) a cadence from the server.
local function sendReady(ready)
  announced = true
  net.Start("NTx.AmpRmsReady")
  net.WriteBool(ready == true)
  net.SendToServer()
end

-- Push every input we currently hold a level for, in one message.
local function report()
  local now = CurTime()
  local items = {}
  for pkey, r in pairs(NTx.PageRms or {}) do
    local idx = tonumber(pkey:match("^wai|(%d+)$"))
    -- The client ages its own copy at one second; anything older would arrive
    -- at the server already stale.
    if idx and (now - r.at) < 1 then
      items[#items + 1] = { idx = idx, v = r.v }
      -- Cap as we go rather than trimming afterwards: table.move does not exist
      -- in GLua's 5.1 base library.
      if #items >= 64 then break end
    end
  end
  if #items == 0 then return end
  net.Start("NTx.AmpRms")
  net.WriteUInt(#items, 6)
  for _, it in ipairs(items) do
    net.WriteUInt(it.idx, 16)
    net.WriteFloat(it.v)
  end
  net.SendToServer()
end

local lastRunning = nil

hook.Add("Think", "NTx.AmpRmsReport", function()
  local running = NTx.WebAudioRunning == true
  -- Claim (or withdraw) a cadence whenever the page comes up or dies. Polled
  -- from Think because NTx.WebAudioRunning is a plain variable, not a hook.
  if running ~= lastRunning then
    lastRunning = running
    sendReady(running)
    if running then
      net.Start("NTx.AmpRmsCadenceReq")
      net.SendToServer()
    end
    announced = true
    return
  end
  if not running then return end
  if CurTime() < nextSend then return end
  nextSend = CurTime() + cadence
  report()
end)

-- Debug aid: shows what the reporter is holding and how often it is sending.
concommand.Add("ntx_rms_status", function()
  local now = CurTime()
  local n, fresh = 0, 0
  for _, r in pairs(NTx.PageRms or {}) do
    n = n + 1
    if (now - r.at) < 1 then fresh = fresh + 1 end
  end
  print(string.format(
    "[NTx] rms reporter: announced=%s cadence=%.4fs (%.1f Hz) tracked=%d fresh=%d running=%s",
    tostring(announced), cadence, 1 / math.max(cadence, 0.001), n, fresh,
    tostring(NTx.WebAudioRunning == true)))
end)