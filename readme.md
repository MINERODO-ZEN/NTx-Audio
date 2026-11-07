# NTx Audio

NTx Audio turns a Garry's Mod sandbox into a small live-sound rig: stream sources, a five-bus
mixer, profile-driven power amplifiers and DSP-rendered cabinets, patched together with Wiremod.

Sources are real HTTP streams. The mixer routes MID and SUB programme material independently.
The amplifiers are simulated — mains, rails, current limits, heatsinks, fans, protection and
permanent damage — rather than being boxes that only look the part. Every cabinet is then
rendered client-side by a Web Audio page with its own crossover, delay, polarity, directivity
and occlusion. A legacy BASS fallback path exists for clients that cannot run the page, but a new
wire-only rig should be built around WebAudio.

> **Status:** playable and under active development. The core signal chain, amplifier
> simulation and WebAudio renderer are in place. The BASS fallback is legacy: it can only use a
> mixer link carried over from an older save or a duplicate, because the current wire graph
> cannot create one. Some hardware profiles still use placeholder models, and the speaker nodes
> are deliberately transparent placement markers.

## Features

- **Stream sources** — `ntx_input_url` plays an HTTP/Icecast stream (the tool's default is
  `https://radio.plaza.one/mp3`) with per-input volume and range. `ntx_fallback_bus` is the
  legacy full-range tap for clients on the BASS backend; see [BASS fallback](#bass-fallback).
- **Five-bus mixer** — a Soundcraft UI24R-styled mixer with up to 16 wired inputs and separate
  MID and SUB programme buses, master/MID/SUB faders and mutes, and per-channel fader, mute and
  label.
- **Amplifier simulation** — Crown MA2400 and CDi 1000, plus Powersoft K2, K3, K6, K10 and K20
  profiles. Each profile carries its own published power, sensitivity, supply behaviour,
  thermal data and protection limits. Dual, bridge and parallel modes where the profile supports
  them; 70/100 V taps on constant-voltage models; editable mains override, ambient temperature and
  per-unit behaviour.
- **Cabinet model** — MID/SUB nodes with impedance, RMS/peak ratings, minimum amplifier power,
  series wiring, constant-voltage taps, self-powered mode, directivity and coil temperature.
  Drivers accumulate damage and eventually blow.
- **Per-cabinet DSP** — the WebAudio backend decodes each source once and gives every cabinet a
  filtered tap: 80 Hz high/low-pass crossover, gain, delay and polarity for cardioid/endfire
  sub arrays, elliptical MID coverage, wall occlusion with a high-frequency roll-off, and a
  final safety limiter.
- **Wiremod is the patch bay** — signal and telemetry ports expose levels, bus identity,
  amplifier electrical state, speaker temperatures, blown state and more. The wire graph is the
  topology: rewire the rig and the audio path follows.
- **Both realms in sync** — the server owns the simulation and publishes state; clients render
  the same numbers they see on the panels and meters.
- **Derma panels and diagnostics** — mixer, amplifier and cabinet windows, owner-only gizmos and
  coverage cones, an engine settings page in the spawn menu, and console commands for the
  things that are hard to see.
- **Third-party amplifier packs** — add a model, a profile and lamp layout as a JSON pack, with
  optional Workshop mounting. Built-in profiles always win over a pack.
- **Duplicator support** — copies keep their wires and their mixer/amplifier links.

## Requirements

| Requirement | Notes |
| --- | --- |
| Garry's Mod (Sandbox) | The addon is built around Sandbox tools, CPPI ownership and the spawn menu. |
| [Wiremod](https://steamcommunity.com/sharedfiles/filedetails/?id=160250458) | **Required.** The wire graph is the rig; without it, nothing is routed. |
| A CEF/WebAudio-capable client | Needed for normal cabinet audio. The capability probe selects the backend. |
| A page host (optional) | For a `.gma`/Workshop release the two HTML pages must be served from `ntx_page_base`. |
| [PAC3](https://steamcommunity.com/sharedfiles/filedetails/?id=104691717) (optional) | Only needed by maintainers authoring new lamp layouts, not to play. |

The WebAudio pages are not packed into a `.gma` (gmad only packs known asset types). A folder
install can copy them from `data_static/ntx_audio/` into `garrysmod/data/ntx/`; a packed release
must host them remotely. See [WebAudio pages](#webaudio-pages).

## Installation

1. Clone or copy this repository into your addons folder:

   ```text
   garrysmod/addons/NTx-Audio/
   ```

   Any folder name works — the addon is identified by `addon.json`. The maintainer scripts
   assume a folder named `NTx`, so use that name if you plan to run them.

2. Start Garry's Mod and check the console for `[NTx]` build lines. A clone deployed with
   `tools/sync.js` or packed with `build_gma.js` prints its commit; a plain source clone reports
   `unknown`. If Wiremod is missing, the addon prints a loud warning at `InitPostEntity`;
   install it from the Workshop before building a rig.

3. For a dedicated server, decide where the WebAudio pages will be served from and set:

   ```text
   ntx_page_base "https://your.host/path/"
   ```

   Quote the URL and keep the trailing slash. The default is
   `https://xta.xenonetwork.moe/dsp/`.

## Quick start: build a rig

The whole rig is ordinary Wiremod wiring. The NTx Connections tool is only for opening panels
and applying source settings; the stock wire tool does the connections.

```text
 NTx Live Input (URL)
   └─ Buses (ARRAY: MidL, MidR, SubL, SubR, SubMono)
        └─▶ Mixer In1..In16

 NTx Mixer
   ├─ MidL / MidR  ── ARRAY [level, bus id] ──▶ Amplifier Ch<N>In
   └─ SubL / SubR / SubMono ──────────────────▶ Amplifier Ch<N>In

 NTx Power Amplifier
   └─ Ch<N>Out (0..1 level) ──▶ Speaker In
                                  └─ Out ──▶ next Speaker In   (series chain)
```

1. Spawn an **NTx Mixer** and an **NTx Live Input (URL)** from the `NTx Audio` spawn category.
2. Select the **NTx Connections** tool. In its panel, set the stream URL, input volume and max
   distance, then right-click the input entity to apply them.
3. With the stock wire tool, wire the input's `Buses` output to a mixer `In` port.
4. Spawn an **NTx Power Amplifier** and a **NTx Speaker Node**. Wire a mixer `MidL`/`MidR`
   output to an amplifier channel input, and that channel's `Ch<N>Out` to the cabinet's `In`.
   Use `SubL`, `SubR` or `SubMono` for sub cabinets.
5. Left-click the mixer, amplifier or cabinet with the NTx Connections tool to open its panel.
   Set the cabinet type and profile, the amplifier mode and tap, and the faders.
6. For a series pair, wire the first cabinet's `Out` to the second cabinet's `In`. The
   simulation treats the chain as series-connected, so their impedances add.
7. Open **Utilities → NTx Audio → NTx Audio Engine** for backend, limiter, occlusion and
   diagnostic controls. **NTx Amplifiers** holds simulation-wide settings.

If a client cannot run WebAudio, its normal speakers are silent by design. The **NTx Fallback
Bus** is a legacy path: it renders only if it already carries a mixer link from an older save or
a duplicate. The current wire graph cannot create that link, so use a WebAudio-capable client for
a new build. See [BASS fallback](#bass-fallback).

## Entities

| Class | Spawn name | Role |
| --- | --- | --- |
| `ntx_input_url` | NTx Live Input (URL) | Stream source; gets a WebAudio page (up to `ntx_max_pages`). |
| `ntx_mixer` | NTx Mixer | 16-input, five-bus summing mixer with master/MID/SUB control. |
| `ntx_amplifier` | NTx Power Amplifier | Profile-driven 1–8 channel amplifier with a full electrical/thermal simulation. |
| `ntx_speaker` | NTx Speaker Node | MID or SUB cabinet; pass-through for series chains. |
| `ntx_fallback_bus` | NTx Fallback Bus | Legacy full-range BASS tap; needs a mixer link that current wiring cannot create. |

Each built-in amplifier profile also registers a spawn-menu entry (for example
`ntx_ampvar_ma2400`). Those entries are thin classes that spawn a normal `ntx_amplifier` with
the chosen profile and model; they are not separate entity types.

## The buses

| Bus | Mixer port | What it carries |
| --- | --- | --- |
| MidL | `MidL` | Left programme above the 80 Hz crossover |
| MidR | `MidR` | Right programme above the 80 Hz crossover |
| SubL | `SubL` | Left programme below the 80 Hz crossover |
| SubR | `SubR` | Right programme below the 80 Hz crossover |
| SubMono | `SubMono` | Mono sum below the crossover |

The source publishes measured levels for all five buses. The mixer sums the wired inputs
through its faders and mutes, then publishes each bus as an **ARRAY pair**: `[level, bus id]`.
The amplifier learns the bus from the mixer output port it is wired to; the pair carries the same
id, so a channel cannot be patched to one bus and told it is another. That is what lets the
simulation charge a SUB channel for SUB drive and a MID channel for MID drive.

None of these wires carry audio. They carry topology, levels and identifiers. The actual audio
is decoded by each client from the input's URL.

## How the audio path works

### WebAudio (preferred)

1. The client runs a capability probe (`probe.html`) that checks `AudioContext`, biquad,
   panner and delay support and whether a stream survives `createMediaElementSource`.
2. Each active input gets one hidden page (`webaudio.html`), up to `ntx_max_pages`. The page opens
   the URL once and builds a per-cabinet tap from the state Lua pushes at ~15 Hz.
3. Each tap applies the cabinet's crossover, gain, cardioid/endfire delay and polarity, MID
   coverage cone, wall occlusion, amplifier attenuation and range fade, then feeds a panner.
4. A second page instance renders amplifier fan noise in its own audio context, so it cannot
   colour the programme mix.
5. The page reports per-bus RMS back to Lua; the client uses it for meters and forwards it to
   the server so the simulation follows the programme rather than only the fader positions.

### BASS fallback

The BASS fallback is a legacy path. When WebAudio is unavailable (or `ntx_backend bass` is set),
only `ntx_fallback_bus` entities render. Each input opens one full-range BASS tap at the nearest
fallback bus of its mixer; only that one bus per mixer is used. There is no crossover, no cardioid
delay, no array shading and no per-cabinet directivity on this path — BASS has no DSP stage here.
Normal speaker nodes become placement markers.

A fallback bus renders only when it carries a mixer link. That link survives in older saves and
in duplicated rigs, but the current wire graph cannot create it: the mixer's bus outputs are
`ARRAY` pairs, while the fallback bus input is a scalar `NTXSIG`, so Wiremod refuses the
connection. On a rig built from scratch, a BASS client therefore hears nothing. Use WebAudio for
new rigs.

The two backends are mutually exclusive on a given client. If WebAudio is live, fallback buses
are muted; if WebAudio is not, speakers are silent. This is intentional: hearing both would
double every source and destroy the phase relationships the WebAudio taps are built to keep.

### Amplifier simulation

The server runs the authoritative model at `ntx_amp_sim_hz` (67 Hz by default, capped at 130). For
each channel the chain is:

```text
mixer bus level → amplifier gain/trim → supply rail and current ceiling → clipping
→ cabinet load → watts → dissipation → sink/device temperature → protection → damage
```

The model covers class AB and class D supplies, PFC and non-PFC mains behaviour, sensitivity
and gain, bridge/parallel pairing, minimum load, 70/100 V taps, fan airflow, ambient
temperature, crest factor, thermal gain reduction and permanent damage. Mains voltage can be
driven from a wire (`MainsV`), and `PowerIn` can switch an amplifier independently of its panel
switch. When a channel protects or the amplifier dies, the audio path attenuates or mutes with
it.

### Cabinets and arrays

- **Series wiring** is derived from the speaker `In`/`Out` chain; there is no hand-set group
  number to disagree with the wires.
- **Cardioid** mode uses reversed cabinets with a configurable rear delay.
- **Endfire** mode (three or more subs with at least one reversed) steps delay progressively
  along the array.
- **MID coverage** is an ellipse with independent horizontal and vertical full angles; a
  self-cardioid cabinet uses a fixed cardioid cone instead.
- **Occlusion** star-traces from the cabinet to the listener and applies both a volume floor
  and, for MID cabinets, a low-pass filter as the path becomes blocked.
- **Damage** is per-driver: sustained over-power heats the coil, peak overload adds damage, and
  a blown driver goes open circuit and stops loading the amplifier.

## Controls

### NTx Connections tool

| Input | Action |
| --- | --- |
| Left-click an NTx entity | Open its panel (mixer, amplifier or cabinet). |
| Right-click an input | Apply the stream URL, volume and max distance from the tool panel. |
| Right-click a fallback bus | Apply trim, label and 2D/3D playback mode. |
| Reload | Explains that disconnecting is done by deleting the wire; it does not unlink anything. |

### Panels and gizmos

- Mixer panel: master, MID and SUB faders and mutes, plus one row per wired input.
- Amplifier panel: virtual front panel, profile, channel count, mode, taps, protection state,
  temperatures, fan, meters and the full per-unit behaviour list.
- Cabinet panel: profile (built-in or saved), type, impedance, power ratings, tap, array ID,
  directivity, self-powered mode and damage state.
- `ntx_gizmo_speakers`, `ntx_gizmo_links` and `ntx_gizmo_cones` draw owner-only rig helpers.
  They are off by default; other players never see them.

## Configuration

### Server settings

| ConVar | Default | Purpose |
| --- | --- | --- |
| `ntx_page_base` | `https://xta.xenonetwork.moe/dsp/` | Where clients load `webaudio.html` and `probe.html`. Quote it and keep the trailing slash. |
| `ntx_mixer_admin_only` | `0` | Restrict edits to unowned rig entities to admins. Owners and admins can always edit. |
| `ntx_amp_sim` | `1` | Run the amplifier/speaker simulation. Off means inert boxes and no heat or damage. |
| `ntx_amp_damage` | `1` | Let amplifiers accumulate permanent damage and burn out. |
| `ntx_spk_damage` | `1` | Let drivers accumulate damage and blow. |
| `ntx_amp_sim_hz` | `67` | Simulation rate cap (1–130 Hz). |
| `ntx_signal_hz` | `67` | Signal-chain publish rate (1–130 Hz). |
| `ntx_meter_hz` | `67` | Meter/level broadcast rate cap (1–130 Hz). |
| `ntx_amp_sync_hz` | `10` | Slow amplifier state broadcast rate cap (1–130 Hz). |
| `ntx_amp_sync_dist` | `6000` | Radius around which amplifier state is still sent (0 = everywhere). |
| `ntx_max_channels` | `16` | Maximum simultaneous BASS taps per client (WebAudio inputs use `ntx_max_pages`). |
| `ntx_update_hz` | `67` | Graph rebroadcast rate cap. |
| `ntx_mains_nominal` | `230` | Nominal mains voltage for amplifiers with no wire input. |
| `ntx_ambient_c` | `22` | Ambient temperature for amplifiers and drivers, °C. |
| `ntx_crest_db` | `6` | Crest factor used to turn RMS output into peak power. |

### Client settings

| ConVar | Default | Purpose |
| --- | --- | --- |
| `ntx_backend` | `auto` | `auto`, `webaudio` or `bass`. Auto uses WebAudio when the probe passes. |
| `ntx_client_volume` | `1` | Client-side master volume for the WebAudio mix. |
| `ntx_headroom_db` | `-6` | Mix headroom below the limiter; keeps cone ratios audible. |
| `ntx_limiter` | `1` | Safety limiter on the WebAudio master bus. |
| `ntx_limiter_db` | `-0.5` | Limiter threshold in dBFS. |
| `ntx_limiter_ratio` | `20` | Limiter ratio (1 = off). |
| `ntx_max_pages` | `4` | Maximum simultaneous WebAudio input pages. |
| `ntx_push_hz` | `15` | State push rate to the pages; motion is interpolated in-page. |
| `ntx_motion_smooth` | `60` | Motion smoothing time constant in ms. |
| `ntx_mute_distance` | `5000` | Upper bound for fallback tap mute; the actual limit is `min(input range + 1000, this)`. |
| `ntx_occlusion_rays` | `48` | Star-trace sample count (0 = off). |
| `ntx_occlusion_min` | `0.33` | Volume floor for a fully occluded fallback bus. |
| `ntx_occ_mid_min` | `0.12` | Volume floor for a fully occluded MID cabinet. |
| `ntx_occ_mid_lp` | `1400` | Low-pass cutoff for a fully occluded MID cabinet (0 = gain only). |
| `ntx_amp_leds` | `1` | Draw amplifier lamps in the world and in panels. |
| `ntx_amp_rms_send` | `1` | Send measured programme levels to the server. |
| `ntx_gizmo_speakers` | `0` | Owner-only speaker arrows and labels. |
| `ntx_gizmo_links` | `0` | Owner-only input/mixer/amplifier/speaker link lines. |
| `ntx_gizmo_cones` | `0` | Owner-only coverage wedges. |
| `ntx_webaudio_debug` | `0` | Mirror page console output to the game console. |
| `ntx_cef_visible` | `0` | Debug: park pages on screen instead of hiding them. |

Array and diagnostic tuning: `ntx_cardioid_ms` (rear-box delay, `2.9` ms), `ntx_endfire_m`
(endfire spacing, `1.0` m), `ntx_motion_max_rate` (motion speed cap, `0` = uncapped),
`ntx_bass_smooth` (BASS 3D tap smoothing, `60` ms), `ntx_cone_debug` (per-tap directivity and
coverage printout), `ntx_amp_debug` (full amplifier simulation printout), `ntx_amp_rms_db`
(assumed level when a page reports no RMS, `-70` dBFS) and `ntx_cone_len` (coverage wedge length,
`72` units).

Most of these are also exposed in **Utilities → NTx Audio → NTx Audio Engine**.

## Console commands

Run these in the client console unless noted.

| Command | What it does |
| --- | --- |
| `ntx_audio_status` | Backend, probe verdict, commit, Wiremod presence, graph counts, tap bus resolution and page/BASS state. Start here. |
| `ntx_audio_probe [url]` | Run the WebAudio capability/CORS probe, optionally against a stream URL. |
| `ntx_audio_resume` | Resume a suspended browser audio context. |
| `ntx_mixer_test_levels` | Print the current level of every active BASS tap. |
| `ntx_rms_status` | Show the client's page-RMS reporter state and tracked page count. |
| `ntx_open_mixer <ent>`, `ntx_open_amp <ent>`, `ntx_open_cabinet <ent>` | Open a panel directly. |
| `ntx_amp_patch <amp> [mixer]` | Open the amplifier/mixer patch panel. |
| `ntx_amp_list` | List the loaded amplifier profiles and their models. |
| `ntx_amp_bus <ent>` | Print an amplifier's profile, mixer and the bus each wired channel is fed from. |
| `ntx_amp_status` | Print electrical/thermal state for every amplifier. |
| `ntx_amp_fault <ent> <fault>` | Inject `brownout`, `overvoltage`, `overload`, `dc`, `short`, `thermal` or `kill`. |
| `ntx_amp_rate` | Ask the server for its measured simulation, meter, sync and graph rates. |
| `ntx_chain` | Print the cabinet chains the simulation sees. |
| `ntx_packs` | Rescan and list third-party packs, their roots and profiles. |
| `ntx_leds_status`, `ntx_leds_debug [ent]`, `ntx_leds_reload` | Lamp layout diagnostics. |
| `ntx_spk_list`, `ntx_spk_save <name>`, `ntx_spk_apply <id>`, `ntx_spk_del <id>` | Manage saved cabinet profiles; aim at a cabinet first. |
| `ntx_engine_reset` | Restore the client-owned engine settings on the page to their defaults. |

## Third-party amplifier packs

A pack is a folder with a manifest, an optional lamp file and any assets it needs:

```text
garrysmod/addons/my-pack/
├── ntx_pack.json
├── ntx_pack_lamps.json        (optional)
├── models/...
└── materials/...
```

Packs are searched in three places:

- any mounted addon (including Workshop items),
- `garrysmod/ntx_packs/<name>/`,
- `packs/<name>/` inside another addon.

`ntx_pack.json` carries a category, an optional Workshop ID and a `profiles` table. The easiest
starting point is [`packs/example/ntx_pack.json`](packs/example/ntx_pack.json); copy it and edit
the model, specs and lamps. The loader checks every field in `NTx.AMP_PROFILE_FIELDS` and prints
any missing field rather than letting an amplifier half-load.

Useful details:

- A profile with `"variant": false` is available to the simulation and panels but does not get
  its own spawn-menu button.
- A pack can never override a built-in profile ID. The built-in names win, and a broken pack
  cannot break the built-in rig.
- `"workshop": "1234567890"` makes the server mount that Workshop item when the pack loads.
- Lamp rows can live in `ntx_pack_lamps.json` or under a `lamps` key in `ntx_pack.json`.
- Bake a PAC3 layout into a pack file with:

  ```text
  node tools/build_pac3_leds.js --pack <pac3-file> <out-file>
  ```

PAC3 is not needed at runtime: the layouts are baked Lua/JSON tables and only interpreted in
game.

## WebAudio pages

The two pages live in `data_static/ntx_audio/`:

- `probe.html` — capability and CORS probe.
- `webaudio.html` — the mixer/renderer (also used with `?sfx=1` for amplifier fan noise).

For a folder install, the client copies them into `garrysmod/data/ntx/` on load and prints the
matching `file://` base. For a `.gma`/Workshop release, gmad does not pack HTML, so host both
files yourself and set `ntx_page_base` to that URL. The server owns `ntx_page_base`; clients
cannot redirect their pages to another host.

## Repository layout

```text
addon.json                     addon manifest (title, tags, packaging ignore list)
lua/
  autorun/
    ntx_audio_shared.lua       constants, bus ids, fader taper, distance/cone math
    ntx_amp_shared.lua         amplifier/speaker profiles, physics, wire helpers
    ntx_packs.lua              third-party pack loader
    client/                    probe, backend, DSP, panels, meters, gizmos
    server/                    simulation, topology, signal tick, networking
  entities/                    ntx_input_url, ntx_mixer, ntx_amplifier,
                              ntx_speaker, ntx_fallback_bus
  weapons/gmod_tool/stools/    ntx_connection_tool.lua
data_static/ntx_audio/         webaudio.html, probe.html
models/, materials/            included models and textures
packs/example/                 reference pack manifest and lamp rows
tools/                         Node build, check and packaging tools
```

Key server files:

- `ntx_amp_sim.lua` — authoritative electrical/thermal simulation; the place to look when
  watts, temperatures or protection behaviour are wrong.
- `ntx_signal_tick.lua` — runs the source → mixer → cabinet signal chain from a hook at tick
  rate, instead of relying on distance-scaled entity `Think`.
- `ntx_wire_topology.lua` — walks `Inputs[].Src`, mirrors the result into the `Amp`,
  `AmpChannel` and `Mixer` network vars, and restores wires/links through the duplicator.
- `ntx_net.lua` — graph and amplifier state sync, plus server-side validation of every edit.
- `ntx_amp_rms.lua` — turns client-reported measured levels into the server's programme level.

Key client files:

- `ntx_probe.lua` — WebAudio capability/CORS probe and local page installation.
- `ntx_dsp.lua` — backend selection and the BASS fallback renderer.
- `ntx_webaudio.lua` — per-cabinet tap construction and state pushing.
- `ntx_occlusion.lua` — wall occlusion sampling for buses and MID cabinets.
- `ntx_amp_meters.lua`, `ntx_amp_ui.lua`, `ntx_mixer_ui.lua` — meters and panels.

## Development

The addon is plain GLua; there is no compile step. Node.js is only needed for the checks and
packaging scripts. `tools/vendor/luaparse.js` is vendored, so `npm install` is not required for
the normal checks.

### Checks

```text
node tools/check_lua.js lua
node tools/check_blocks.js <file> <file> ...
node tools/release_check.js
```

`release_check.js` is the useful one: it checks the source tree is committed, validates that
materials name textures that exist with the right case, checks the model/texture pairing, runs
the Lua syntax and block-depth checks, inspects the packaging ignore lists, and reports whether
a deployed clone or a `.gma` is present.

`check_lua.js` is a GLua-aware parser check, not a full linter. It catches mismatched blocks,
unterminated strings and the common GLua traps such as `math.Sqrt`, `<<` and C-style comments.

### Packaging

```text
node tools/build_gma.js [output.gma]
node tools/verify_gma.js . ntx_audio.gma
```

`build_gma.js` writes the generated `lua/autorun/ntx_version.lua` from the current commit and
calls `gmad.exe` on the source tree. Set `GMAD` if gmad is not at the default Steam path. The
resulting `.gma` is ignored by git; the version stamp is generated for the same reason.

`verify_gma.js` reads the archive back and checks every entry byte-for-byte and every CRC
against the tree it was packed from.

`tools/sync.js [pageCopyPath]` is a maintainer convenience that deploys to the default Windows
Garry's Mod `addons/NTx` folder, stamps the deployed clone and optionally copies
`webaudio.html` to a page host. Its paths are hard-coded; edit them for your install.

### Baking lamp layouts

```text
node tools/build_pac3_leds.js [pac3Dir] [outFile]
```

The default input is `garrysmod/data/pac3/ntx/*.txt` and the default output is
`lua/autorun/client/ntx_pac3_data.lua`. The baked file is committed so clients do not need
PAC3 or the server's data folder.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| No audio at all | `ntx_audio_status` — is the backend `webaudio` or `bass`? Is the probe `pending` or `fail`? Is the URL set and reachable? |
| Speakers say “inactive: needs WebAudio” | The client is on the BASS backend. Normal cabinets only render through WebAudio; use a WebAudio-capable client (the fallback bus is legacy-only) or fix the page/probe. |
| BASS client hears nothing even with a fallback bus | The bus has no mixer link. Current wiring cannot create one, because the mixer output is an `ARRAY` pair and the bus input is scalar; only a legacy save or duplicate carries the link. Use WebAudio. |
| Mixer channels missing | Each mixer input is created from a wire into `In1..In16`. Check the stock wire tool and `ntx_audio_status` graph counts. |
| Amplifier has no bus on a channel | `ntx_amp_bus <ent>` says “NOT WIRED” when no mixer bus output feeds `Ch<N>In`. Wire it; the bus is read from the port, not a panel. |
| Stream plays but is silent in WebAudio | CORS. The page must be able to read the stream through `createMediaElementSource`; a tainted stream is silent, and the BASS fallback is deliberately not mixed underneath a capable client. Run `ntx_audio_probe <url>`. |
| Page never loads | Check `ntx_page_base` is quoted and reachable. Try `ntx_webaudio_debug 1` and `ntx_cef_visible 1`. |
| Packs do not appear | `ntx_packs` lists every root and whether a manifest was found; the loader prints missing profile fields on load. |
| Lamps are missing | `ntx_leds_status`; a profile/model without a baked layout falls back to the virtual panel. Use `ntx_leds_debug` on an amplifier. |
| Changes do nothing after an update | `ntx_audio_status` prints the commit the running Lua was built from. Re-deploy or rebuild the `.gma` if it is stale. |
| `[NTx] Wiremod is REQUIRED` | Install Wiremod (Workshop item 160250458). The addon deliberately refuses to pretend a rig is wired when it cannot read the graph. |

## Things to know

- **WebAudio bypasses the GMod master volume.** The page has its own audio context; use
  `ntx_client_volume` (or the Windows mixer) rather than the GMod volume slider to control it.
- **A stream needs CORS headers for WebAudio.** The page can fetch and play a stream without
  them, but cannot route it through `createMediaElementSource`; the result is silence. The
  probe distinguishes “plain playback works” from “CORS-clean”.
- **The two backends never mix.** A WebAudio-capable client will not hear fallback buses, and
  a BASS client will not hear normal cabinets. This avoids doubled sources and broken phase.
- **The BASS path is deliberately simple and legacy-only.** It has no crossover, cardioid delay,
  array shading or cabinet directivity because BASS exposes no DSP stage. A fallback bus also
  needs a mixer link that the current wire graph cannot create, so only a carried-over save or
  duplicate will make sound there.
- **Some models are placeholders.** The Crown profiles reuse the stock GMod receiver model and
  draw a virtual front panel; the Powersoft K series has a dedicated model. Speaker nodes are
  translucent debug cubes on purpose.
- **The wire graph is topology, not audio.** The wires carry levels, bus identifiers and
  telemetry. Every client decodes the source itself.
- **`ntx_page_base` is server-owned.** Clients cannot point their pages at another host, which
  keeps a malicious value from loading remote script into a privileged page.

## License

MIT — see [LICENSE](LICENSE).

NTx Audio is not affiliated with Crown, Powersoft, Soundcraft or Pioneer. Product names and
datasheet figures are used descriptively; the models and textures are fan/port assets, and the
respective trademarks remain the property of their owners.

Wiremod is a separate project and is required at runtime. PAC3 is optional and only used by
maintainers when authoring lamp layouts.
