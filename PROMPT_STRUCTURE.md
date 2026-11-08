# What the prompt contains

The script sends the AI one plain-text prompt built from one render of the whole song. Each part starts with a heading such as `=== ROLE ===`, always in this order:

| # | Heading | Contents |
|---|---|---|
| 1 | `ROLE` | One sentence: who the AI is and what it must do |
| 2 | `LEGEND OF THE MEASURED DATA` | What the short keys in part 5 mean |
| 3 | `PROJECT YAML` | How to read part 6, and how to ask for more detail |
| 4 | `INSTRUCTIONS` | The answer format and the advice rules |
| 5 | `MEASURED DATA` | The numbers from the analyzers |
| 6 | `REAPER PROJECT (YAML)` | Notes, routing, faders and plugin settings |

If a focus is chosen, the prompt ends with a `FOCUS:` line.

The names and values in the examples below are made up.

## Instructions

The AI must answer in three parts:

1. **Overview:** 3 to 5 short lines on what works and 3 to 5 on the main problems, each with the number that shows it.
2. **Eight areas, in this order:** dynamics and loudness, low end, low mids, mids, highs, stereo and mono, arrangement, master. Each covers what the data shows, the cause and the fixes.
3. **To-do table:** at most 12 fixes, biggest effect first, with priority, track, plugin and parameter, the change (current -> new) and why.

The main rules for the advice:

- Quote exact track, plugin and parameter names from the YAML.
- A setting in a module that is switched off has no effect.
- Never give a threshold, because the levels going into a plugin are not measured. Give the gain reduction or cut to aim for instead.
- Never compute values the data does not give. When the data does not support a claim, say so.
- Write in plain studio words. The short data keys are for the AI only and must not appear in the answer.

## Measured data

Each track is measured after its own fader, pan and automation, and before its folder and the master FX.

Compact number format, used throughout:

- A key and its value have no space between them: `L-26.0`.
- A number below 1 has no leading zero: `c.93`, `c-.01`.
- A `_` in a track name stands for a space, so `Lead_Vox` is `Lead Vox` in the YAML.

### Frequency bands

| Band | Hz | Band | Hz | Band | Hz |
|---|---|---|---|---|---|
| `rumble` | 20-31.5 | `mud` | 200-315 | `presence` | 2000-3150 |
| `deepsub` | 31.5-50 | `boxy` | 315-500 | `harsh` | 3150-5000 |
| `sub` | 50-80 | `honk` | 500-800 | `sibilance` | 5000-8000 |
| `bass` | 80-125 | `nasal` | 800-1250 | `sizzle` | 8000-12500 |
| `body` | 125-200 | `bite` | 1250-2000 | `air` | 12500-20000 |

### Song line

```
SONG I-12.8 M-8.0 S-9.8 LRA7.5 pk-1.0 clip0 | mid rumble-40.0 deepsub-30.0 ... air-46.0 | side rumble-74.0 ... air-55.0
```

| Field | Meaning |
|---|---|
| `I` | Integrated loudness (LUFS) |
| `M` | Maximum momentary loudness (LUFS) |
| `S` | Maximum short-term loudness (LUFS) |
| `LRA` | Loudness range (LU) |
| `pk` | Sample peak (dBFS) |
| `clip` | Clipped samples |
| `mid` / `side` | Song-average level of all 15 bands in the mid and side signal (dB) |

### Master chain line

```
chain in I-17.5 M-13.0 LRA7.5 > out I-12.8 M-8.0 LRA7.5 gain+4.7
```

Shows the master's loudness before and after the master FX. `gain` is the loudness the chain adds (dB).

### Track lines

A `TRACKS (whole song)` block follows, with one line per playing track:

```
Bass s20 L-26.0 pk-8.0 cr14 a80 W15 c.93 pL1 | sub+3 bass+4
```

| Field | Meaning | When it appears |
|---|---|---|
| Name | Track name | Always |
| `s` | Share of the mix (%, loudness-weighted energy; all counted tracks add up to 100) | Not on folder buses, whose children carry it |
| `L` | Average loudness including pauses (LUFS, ungated) | Always |
| `pk` | Sample peak (dBFS) | Always |
| `cr` | Crest factor (dB; low = dense or heavily compressed) | Always |
| `a` | Time the track plays (%) | Always |
| `W` | Width (0 mono, about 50 wide and uncorrelated, above 50 more side than mid) | Always |
| `c` | Left/right correlation (1 mono, 0 unrelated, below 0 out of phase) | Always |
| `pC`, `pL n`, `pR n` | Measured balance: centre, or 0-100 towards that side | Always |
| `sub!` | Out of phase below 120 Hz, so it cancels in mono | Only when true |
| `clip n` | Clipped samples | Only when clipping |
| After `\|` | Bands that stand out from their neighbours in the same track (dB; `+` bump, `-` dip) | Only when a band stands out |

Tracks with no path to the master are left out.

### Region blocks

A `REGIONS` block follows, with one block per region:

```
R2 Verse_1 10.7-53.3 | I-14.5 M-9.7 S-11.8 LRA5.5 W27 | presence-3 sibilance-4
 chain in I-19.5 M-14.7 LRA5.7 > out I-14.5 M-9.7 LRA5.5 gain+5.0
 Bass s22 L-27.6 pk-9.8 cr13 a75 W16 c.93 pL1 | sub+3 bass+4
 Lead_Vox s21 L-22.8 pk-8.8 cr13 a91 W0 c1.00 pC | mud+4
 R2 also Pad a100, Hi_Hat a31, Reverb a88
 mask 50-80Hz: Kick 46, Bass 36; 200-500Hz: Lead_Vox 37, Pad 30
```

| Line | Contents |
|---|---|
| Region line | Number, name, start-end (seconds), then the master numbers (`I`, `M`, `S`, `LRA`, `W`). After `\|`: master bands against the song average with the loudness difference removed (dB) |
| Chain line | The master chain line for this region |
| Track lines | The region's top tracks by share, with the same fields as above, measured over this region |
| `R n also` | Every other track playing in the region; `a` = % of the region it plays |
| `mask` | Hz ranges where 2 or more of the top tracks each hold at least 25% of the energy. The number is each track's % of all energy in that range |

The master numbers on a region line also include `c`, `pL n` / `pR n`, `sub!` and `clip n`, but only when notable: `c` below 0, balance 12 or more, any clipped samples. No value shown means normal.

A note marked `approx` means those tracks' shares are approximate, because their folder also receives sends.

## Project YAML

Compact YAML. Short lists and settings stay on one line (`{key: value, ...}`), and a value at its default is usually left out.

### Notes, meta and arrangement

```yaml
additional_information:
  - the project notes, then one line per plugin note
meta: {bpm: 120.0, sample_rate: 44100, time_sig: 4/4}
arr:
  - {end_s: 53.33, name: Verse 1, start_s: 10.67, type: region}
```

### Connections

```yaml
connections:
  - {dst: Reverb, src: Lead Vox, vol_db: -9.0}
  - {dst: Bass, dst_ch: 3/4, purpose: sidechain, src: Kick, type: pre}
```

| Field | Meaning | When it appears |
|---|---|---|
| `src`, `dst` | Sending and receiving track | Always |
| `vol_db` | Send volume (dB) | Left out at 0 dB |
| `type` | `pre` = pre-fader, `prefx` = before the track's FX | Left out for a post-fader send |
| `dst_ch` | Receiving channels | Only for a non-default channel pair |
| `purpose` | `sidechain` = feeds a side-chain input | Only for side-chains |

### Tracks

```yaml
tracks:
  - track: Lead Vox
    flags: [muted]
    vol_db: -1.5
    pan: 30% Left
    depth: 1
    parent: Vocals
    auto: "Volume (Pre-FX), Send Volume"
    fx:
      - name: Ducking Comp (ReaComp)
        wet: 80%
        params: {att: 5.0 ms, band_1: {freq: 181, gn: 2.0}, out: 0.0 dB}
      - name: Old EQ
        bypassed: true
      - name: Second Comp
        params: same as plugin 1 on Harmony
  - track: Pad
    fx: Synth (instrument) > EQ > Chorus
```

| Field | Meaning | When it appears |
|---|---|---|
| `track` | Track name; the first entry is the master | Always |
| `flags` | Any of `folder`, `muted`, `soloed`, `phase_flipped` | Only when one applies |
| `vol_db` | Fader (dB) | Left out at 0 dB |
| `pan` | Pan position | Left out when centred |
| `depth`, `parent` | Folder level and parent folder | Only inside a folder |
| `auto` | Names of the envelopes on the track | Only when it has some |
| `fx` | The plugin chain, in order | Only when it has plugins |

Inside `fx`:

| Form | Meaning |
|---|---|
| `fx: A > B` | Plugin names only, used for most tracks; `(instrument)` marks an instrument |
| `fx:` with a list | Full settings, used for the master and the tracks named under Regions, with their folders |
| `name` | Plugin name; a renamed plugin shows the original in brackets |
| `type: instrument` | The plugin is an instrument |
| `bypassed: true` | The plugin is switched off |
| `wet` | REAPER's mix knob for the plugin |
| `params: {...}` | The settings, as the plugin reports them |
| `band_1: {freq: 181}` | Grouped shorthand: settings with a common name start, here `band_1_freq` |
| `low_shelf_3: off` | A module that is switched off |
| `params: same as plugin N on TRACK` | Exactly the settings of the Nth plugin in that track's chain |

The AI can ask for "DETAIL <track name>" to get a track's full plugin settings, sends, automation and measurements per region.

## When a focus is chosen

The prompt adds a `FOCUS DATA` part to the legend, and `FOCUS: <name>. Give advice only about these tracks: ...` at the end. The measured data changes like this:

| Part | Change |
|---|---|
| `TRACKS` | Focus tracks and returns also show `clip n`, `prepk` (sample peak before their own fader) and `levels` (all 15 band levels). Tracks that never play together with a focus track are left out |
| `auto` line | Under a track line: each moving envelope with its points, as `ENVELOPE unit: value@seconds ...` |
| Region line | `no focus track plays` replaces the band list when none of the focus tracks play, and the region shows only its master numbers |
| Track lines | The track's role follows its name, for example `Bass (backdrop, competitor)`. Roles: `focus`, `return` (receives audio from a focus track), `backdrop` (one of the 3 loudest other tracks), `competitor` |
| `R n others` | Replaces `R n also`: the remaining playing tracks with their share, for example `R2 others Pluck s8, Sub-Bass s7` |
| `compete` | Replaces the `mask` lines |
| YAML | Tracks left out of the data show only name, parent and flags |

A `compete` line lists up to 3 ranges, strongest first, for one focus track:

```
compete Lead_Vox 1250-2000Hz: Bass +0 o76; 200-315Hz: Pad -1, Bass -2 o76
```

| Field | Meaning |
|---|---|
| Hz range | One of the focus track's main bands, within 10 dB of its loudest band |
| Track name and `+n` | A competitor's level against the focus track in that range (dB; `+` = louder). It is at most 3 dB quieter and not panned to the opposite side |
| `oN` | % of the focus track's playing seconds when the competitor plays too. No `o` = all of them |
