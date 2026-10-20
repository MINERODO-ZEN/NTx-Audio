-- Client: forward the page's measured levels to the server.
--
-- The WebAudio page already measures real source RMS through an analyser and
-- hands it to NTx.WebAudioOnStatus, which stores it in NTx.PageRms keyed by
-- input entity. The meters read that locally. This file is the other half: it
-- pushes the same numbers to the server so the authoritative simulation - mains
-- draw, output watts, thermal load and speaker drive - follows the music
-- instead of sitting on the fader positions.
--
-- The client sends whenever it has something to send and the server takes it
-- at the server's rate. There is no negotiated rate: a handshake that can be
-- missed leaves a client reporting at a fraction of the rate for ever, and the
-- source was seen publishing at five hertz for exactly that reason.
-- AddCSLuaFile is a server function. Calling it bare from a client file
-- risks aborting the whole file if it is absent here, and everything
-- after this line - the reporter, its Think hook, its command - would
-- silently never register.
if SERVER then AddCSLuaFile() end
if not CLIENT then return end

NTx = NTx or {}

-- Wire format marker. The server drops any message it does not recognise
-- rather than trying to read it: a client running older addon Lua than the
-- server would otherwise have its floats read as the wrong fields, and every
-- input in the rig would quietly report a garbage level.
local RMS_PROTO = 3

-- The client sends whenever it has something to send, and the server takes it
-- at the server's rate. There is no negotiated rate and no fallback: a
-- handshake that can be missed leaves a client reporting at a fraction of the
-- rate for ever, and the source was seen publishing at five hertz because of
-- exactly that.
--
-- The rate the PAGE samples at is the same one, so what the page measures and
-- what arrives are the same thing.
NTx.RmsInterval = 1 / 66

-- Opt out of sending entirely. For a client that would rather the server
-- used its fader-only estimate than spend the bandwidth.
local nextSend = 0
local cvSend = CreateClientConVar("ntx_amp_rms_send", "1", true, false,
  "Send measured programme levels to the server (0 = off, the server falls back to fader positions)")
local announced = false

-- The server tells us how often to report.
-- net.Receive, not a hypothetical AddReceiver: that is the name GMod actually
-- has, and it is the same call every other receiver in this addon uses.
-- The page samples the analyser on its own timer, so it has to be given the
-- same interval the server will read at. Without it the page reports at its
-- own fixed rate and a tick-rate consumer only ever sees aliased level steps.
local function applyPageInterval()
  local secs = NTx.RmsInterval or (1 / 66)
  NTx.RmsCadence = secs
  for _, p in pairs(NTx.WebAudio.Pages or {}) do
    if p and p.panel and IsValid(p.panel) then
      pcall(p.panel.Call, p.panel, "ntxSetMeterInterval(" .. string.format("%.4f", secs) .. ")")
    end
  end
end
NTx.ApplyRmsPageInterval = applyPageInterval

-- A page that is already open when this file loads must be told as well, not
-- only one that appears later.
hook.Add("InitPostEntity", "NTx.RmsPageInterval", function()
  timer.Simple(1, applyPageInterval)
end)

-- Claim (or withdraw) the right to report.
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
      items[#items + 1] = { idx = idx, v = r.v, b = r.b }
      -- Cap as we go rather than trimming afterwards: table.move does not exist
      -- in GLua's 5.1 base library.
      if #items >= 64 then break end
    end
  end
  if #items == 0 then return end
  -- How often the client actually sends, measured.
  local now = CurTime()
  NTx.RmsSendCount = (NTx.RmsSendCount or 0) + 1
  if not NTx.RmsSendAt or (now - NTx.RmsSendAt) >= 1 then
    NTx.RmsSendRate = (NTx.RmsSendCount - (NTx.RmsSendBase or 0)) / math.max(now - (NTx.RmsSendAt or (now - 1)), 0.001)
    NTx.RmsSendAt = now
    NTx.RmsSendBase = NTx.RmsSendCount
  end
  net.Start("NTx.AmpRms")
  net.WriteUInt(RMS_PROTO, 8)
  net.WriteUInt(#items, 6)
  for _, it in ipairs(items) do
    net.WriteUInt(it.idx, 16)
    -- Every bus, band-limited. A fixed count so the server can always read the
    -- message to its end: a variable-length array that a short report leaves
    -- truncated would desynchronise the next item.
    for i = 1, 5 do
      net.WriteFloat(tonumber(it.b and it.b[i]) or it.v or 0)
    end
  end
  net.SendToServer()
end

local lastRunning = nil

hook.Add("Think", "NTx.AmpRmsReport", function()
  local running = NTx.WebAudioRunning == true
  -- Claim (or withdraw) the right to report whenever the page comes up or
  -- dies. Polled from Think because NTx.WebAudioRunning is a plain variable,
  -- not a hook.
  if running ~= lastRunning then
    lastRunning = running
    sendReady(running)
    if running then applyPageInterval() end
    announced = true
    return
  end
  if not running then return end
  -- Off means off: the server keeps its fader-only estimate and the client
  -- stops spending the bandwidth.
  if not cvSend:GetBool() then return end
  -- At the tick rate, not once per frame. A client at a hundred and fifty
  -- frames a second was sending three times what the server admits, and the
  -- server threw most of it away - which is what the "dropped by rate" count
  -- was showing.
  if CurTime() < nextSend then return end
  nextSend = CurTime() + (NTx.RmsInterval or (1 / 66))
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
    "[NTx] rms reporter: announced=%s send=%s interval=%.4fs (%.1f Hz) tracked=%d fresh=%d running=%s",
    tostring(announced), tostring(cvSend:GetBool()),
    NTx.RmsInterval or (1 / 66), 1 / math.max(NTx.RmsInterval or (1 / 66), 0.001), n, fresh,
    tostring(NTx.WebAudioRunning == true)))
end)