-- Whole-rig diagnostic: `ntx_chain`.
--
-- Every part of the level path is driven by an independent subsystem - the
-- page, the wires, the RMS reporter, the topology walk - and none of them
-- reports the failure of another. The symptom of a break anywhere along it is
-- identical: a silent rig with wires that look healthy. So this dumps all of
-- it in one place, from the SERVER, because the values that matter (published
-- bus levels, WireSignal, the topology's own view) do not exist client-side.
--
-- The server builds the text and sends it back, so it prints in the console of
-- whoever asked - a server-only concommand would print somewhere they cannot
-- see.
AddCSLuaFile()

util.AddNetworkString("NTx.ChainReq")
util.AddNetworkString("NTx.ChainRep")

local BUS_ORDER = { "MidL", "MidR", "SubL", "SubR", "SubMono" }

if SERVER then
  local function buildDump()
    local L, add = {}, nil
    add = function(s) L[#L + 1] = s end

    add("===== NTx signal chain =====")
    add(string.format("convars: sim_hz=%s meter_hz=%s",
      tostring(GetConVar("ntx_amp_sim_hz") and GetConVar("ntx_amp_sim_hz"):GetFloat()),
      tostring(GetConVar("ntx_meter_hz") and GetConVar("ntx_meter_hz"):GetFloat())))
    add("bus ids: MidL=0 MidR=1 SubL=2 SubR=3 SubMono=4")
    add("")

    -- Sources: what they publish, and what they are measuring.
    local anySrc = false
    for _, e in ipairs(ents.FindByClass("ntx_input_url")) do
      anySrc = true
      local vals = {}
      for i = 1, 5 do
        vals[#vals + 1] = string.format("%.3f", tonumber(e.WireBuses and e.WireBuses[i]) or -1)
      end
      add(string.format("source %d  vol=%.2f  publishes=[%s]", e:EntIndex(),
        tonumber(e:GetInputVolume()) or 0, table.concat(vals, " ")))
      local r = NTx.LiveRms and NTx.LiveRms[e]
      if r then
        add(string.format("    measured l=%.3f r=%.3f mono=%.3f  (%.2fs old, by %s)",
          tonumber(r.l) or 0, tonumber(r.r) or 0, tonumber(r.v) or 0,
          CurTime() - (r.at or 0),
          IsValid(r.by) and r.by:Nick() or "?"))
      else
        add("    measured NONE (fader estimate only)")
      end
    end
    if not anySrc then add("source: NONE in the map") end
    add("")

    -- Mixers: their channels, and what each bus actually comes out at.
    local anyMx = false
    for _, mx in ipairs(ents.FindByClass("ntx_mixer")) do
      anyMx = true
      local outs = {}
      for b = 0, 4 do
        local ok, v = pcall(mx.ComputeBusOut, mx, b)
        outs[#outs + 1] = string.format("%s=%s", BUS_ORDER[b + 1],
          ok and string.format("%.3f", tonumber(v) or -1) or "ERR")
      end
      add(string.format("mixer %d  %s", mx:EntIndex(), table.concat(outs, " ")))
      local nCh = #(mx.Channels or {})
      add(string.format("    channels=%d master=%.2f%smid=%.2f%ssub=%.2f", nCh,
        tonumber(mx:GetMasterFader()) or -1, (mx:GetMasterMuted() and " MUTED" or " "),
        tonumber(mx:GetMidFader()) or -1, (mx:GetMidMuted() and " MUTED" or " "),
        tonumber(mx:GetSubFader()) or -1, (mx:GetSubMuted() and " MUTED" or "")))
      for i, ch in ipairs(mx.Channels or {}) do
        local port = "UNWIRED"
        for k = 1, 16 do
          if NTx.WireUpstream(mx, "In" .. k) == ch.Input then port = "In" .. k break end
        end
        local lvl = "?"
        for k = 1, 16 do
          if port == "In" .. k then
            local src = (mx.WireLevels or {})[k]
            lvl = istable(src) and string.format("%.3f", tonumber(src[ch.Bus + 1]) or -1) or "none"
          end
        end
        add(string.format("    ch%d  %-9s %-14s bus=%-7s fader=%.2f%s  sees=%s",
          i, IsValid(ch.Input) and ch.Input:GetClass() or "?", port,
          NTx.BusName(ch.Bus), tonumber(ch.Fader) or -1,
          (ch.Muted and " MUTED" or ""), lvl))
      end
    end
    if not anyMx then add("mixer: NONE in the map") end
    add("")

    -- Amplifiers: what each channel is fed, and whether a wire feeds it at all.
    local anyAmp = false
    for _, amp in ipairs(ents.FindByClass("ntx_amplifier")) do
      anyAmp = true
      add(string.format("amp %d  mixer=%s  simHz=%s", amp:EntIndex(),
        IsValid(amp:GetMixer()) and amp:GetMixer():EntIndex() or "NONE",
        tostring(NTx.AmpSimEnabled and NTx.AmpSimEnabled() or "?")))
      for _, ch in ipairs(amp:ActiveChannels()) do
        local name = "Ch" .. ch .. "In"
        local src, srcPort = NTx.WireUpstream(amp, name)
        local id = amp:ChannelBusId(ch)
        add(string.format("    CH%d fed=%-5s bus=%-7s side=%d  src=%s/%s  wireSignal=%s",
          ch, tostring(amp:ChannelIsFed(ch)), NTx.BusName(id), NTx.BusSideOf(id),
          IsValid(src) and src:GetClass() or "NONE", tostring(srcPort),
          tostring(amp.WireSignal and amp.WireSignal[ch])))
      end
    end
    if not anyAmp then add("amp: NONE in the map") end
    return table.concat(L, "\n")
  end

  net.Receive("NTx.ChainReq", function(_, ply)
    if not IsValid(ply) then return end
    local ok, text = pcall(buildDump)
    net.Start("NTx.ChainRep")
    net.WriteString(ok and text or ("dump failed: " .. tostring(text)))
    net.Send(ply)
  end)
end

if CLIENT then
  net.Receive("NTx.ChainRep", function()
    print(net.ReadString())
    -- Client-only state, appended here because the server cannot see it.
    print(string.format("page running=%s  graph: %d inputs %d speakers %d mixers",
      tostring(NTx.WebAudioRunning),
      #(NTx.Graph and NTx.Graph.inputs or {}),
      #(NTx.Graph and NTx.Graph.speakers or {}),
      #(NTx.Graph and NTx.Graph.mixers or {})))
  end)

  concommand.Add("ntx_chain", function()
    net.Start("NTx.ChainReq")
    net.SendToServer()
  end)
end