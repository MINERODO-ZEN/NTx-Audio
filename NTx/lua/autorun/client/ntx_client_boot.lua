-- Client bootstrap: load the shared constants + the client modules in
-- dependency order.
--
-- ntx_audio_shared.lua lives in lua/autorun/ root, which GMod auto-executes in
-- BOTH realms, so it needs no include here (and include() cannot resolve
-- parent-relative "../..." paths anyway - that only produced a console error
-- while the file loaded correctly all along).
if not CLIENT then return end
include("ntx_dsp.lua")
include("ntx_occlusion.lua")
include("ntx_probe.lua")
include("ntx_webaudio.lua")
include("ntx_gizmos.lua")
include("ntx_engine_panel.lua")
include("ntx_mixer_ui.lua")

concommand.Add("ntx_mixer_test_levels", function()
  for key, chan in pairs(NTx.Stations or {}) do
    if IsValid(chan) then
      local l, r = chan:GetLevel()
      print("[NTx] " .. key .. " L=" .. math.Round(l or 0, 3) .. " R=" .. math.Round(r or 0, 3))
    end
  end
  if not next(NTx.Stations or {}) then print("[NTx] no active stations") end
end)

concommand.Add("ntx_audio_status", function()
  local wantCv = GetConVar("ntx_backend")
  print("[NTx] backend want=" .. (wantCv and wantCv:GetString() or "?")
    .. " effective=" .. (NTx.EffectiveBackend and NTx.EffectiveBackend() or "?")
    .. " probe=" .. tostring(NTx.WebAudioDetail or "not run")
    .. " pageRunning=" .. tostring(NTx.WebAudioRunning))
  local g = NTx.Graph or {}
  print(string.format("[NTx] graph: %d inputs %d speakers %d buses %d mixers",
    #(g.inputs or {}), #(g.speakers or {}), #(g.fallbacks or {}), #(g.mixers or {})))
  if NTx.WebAudio and NTx.WebAudio.Pages then
    local n = 0
    for k, P in pairs(NTx.WebAudio.Pages) do
      n = n + 1
      print("[NTx] page " .. k .. " url=" .. tostring(P.url)
        .. " ready=" .. tostring(P.registered) .. " panel=" .. tostring(IsValid(P.panel))
        .. " api=v" .. tostring((NTx.PageHello or {})[k] or "?")
        .. " pong=" .. (function()
            local t = (NTx.PagePong or {})[k]
            return t and math.Round(CurTime() - t, 1) or "none"
          end)() .. "s ago")
    end
    if n == 0 then print("[NTx] no mixer pages open") end
  end
  if not next(NTx.Stations or {}) then
    print("[NTx] no BASS taps open")
  end
  for k, chan in pairs(NTx.Stations or {}) do
    if IsValid(chan) then
      print("[NTx] BASS tap " .. k .. " vol=" .. math.Round(chan:GetVolume() or 0, 3)
        .. " 3d=" .. tostring(chan:Is3D()))
    end
  end
  for ent in pairs(NTx.Tainted or {}) do
    print("[NTx] CORS-tainted input ent " .. tostring(IsValid(ent) and ent:EntIndex() or "gone"))
  end
  if istable(NTx.LastTaint) then
    print("[NTx] last taint report at " .. tostring(NTx.LastTaint.when)
      .. ": source audible=" .. tostring(NTx.LastTaint.srcAudible)
      .. " mean=" .. tostring(NTx.LastTaint.srcMean)
      .. " var=" .. tostring(NTx.LastTaint.srcVar)
      .. " chains=" .. tostring(NTx.LastTaint.chains)
      .. " fq=" .. tostring(NTx.LastTaint.fq)
      .. " pan=" .. tostring(NTx.LastTaint.pan)
      .. " g=" .. tostring(NTx.LastTaint.cgain))
  end
  for ent, n in pairs(NTx.PageErrors or {}) do
    if not (NTx.PageBroken or {})[ent] then
      print("[NTx] page load errors on ent "
        .. tostring(IsValid(ent) and ent:EntIndex() or "gone") .. " x" .. tostring(n))
    end
  end
  for ent in pairs(NTx.PageBroken or {}) do
    print("[NTx] page-broken input ent " .. tostring(IsValid(ent) and ent:EntIndex() or "gone")
      .. " (BASS bus cover, page retries every 30 s)")
  end
  for dgkey in pairs(NTx.Downgraded or {}) do
    print("[NTx] downgraded to 2D: " .. tostring(dgkey))
  end
end)
