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

If a track was soloed during the measurement, a `NOTE:` line follows, saying the numbers describe the soloed tracks and not the whole mix. If a focus is chosen, the prompt ends with a `FOCUS:` line.

The names and values in the examples below are made up.

## Instructions

The AI must answer in three parts:

1. **Overview.** 3 to 5 short lines on what works and 3 to 5 on the main problems, each with the number that shows it.
2. **Eight areas.** In this order: dynamics and loudness, low end, low mids, mids, highs, stereo and mono, arrangement, master. Each covers what the data shows, the cause and the fixes.
3. **To-do table.** At most 12 fixes, biggest effect first, with priority, track, plugin and parameter, the change (current -> new) and why.

The main rules for the advice:

- Quote exact track, plugin and parameter names from the YAML.
- A setting in a module that is switched off has no effect.
- Never give a threshold, because the script does not measure the levels going into a plugin. Give the gain reduction or cut to aim for instead. The Track Detail message repeats this rule.
- Band levels fall towards the highs in nearly every mix, so that alone does not make a mix dark.
- Never compute values the data does not give. When the data does not support a claim, say so.
- Write in plain studio words. The short data keys are for the AI only and must not appear in the answer.

## Measured data

The analyzers measure each track after its own fader, pan and automation, and before its folder and the master FX.

All numbers use a compact format:

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
chain in I-17.5 M-13.0 LRA7.5 cr12.4 >> gain+4.7 cr-2.1 tone sub+1.3 air-1.1
```

The part before `>>` gives the loudness and crest (peak minus rms over the whole span) of the master before the master FX. The song line above gives the master after them. The part after `>>` gives what the chain changes, in dB:

| Key | Meaning | Shown |
| --- | --- | --- |
| `gain` | The loudness the chain adds | Always |
| `cr` | The change in crest factor | When it can be measured |
| `tone` | Mid bands the chain changes more or less than the other bands, by at least 1 dB | Only when a band qualifies; region lines list only bands that also differ by 1 dB from the song line |

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
| `cr` | Crest factor (dB; low = dense or heavily compressed) | When it can be measured |
| `a` | Time the track plays (%) | Always |
| `W` | Width (0 mono, about 50 wide and uncorrelated, above 50 more side than mid) | Always |
| `c` | Left/right correlation (1 mono, 0 unrelated, below 0 out of phase) | Always |
| `pC`, `pL n`, `pR n` | Measured balance: centre, or 0-100 towards that side | Always |
| `sub!` | Out of phase below 120 Hz, so it cancels in mono | Only when true |
| `clip n` | Clipped samples | Only when clipping |
| After `\|` | Bands that stand out from their neighbours in the same track (dB; `+` bump, `-` dip) | Only when a band stands out |

The data leaves out tracks with no path to the master.

### Sidechain block

Whole Song and track-group focuses add this block after the track lines, when a plugin has something to show:

```
SIDECHAIN (gain reduction in dB of plugins with a side-chain input; avg, max = while the key track plays, off = avg while it is silent; then the bands whose cut jumps when the key starts; closed n% = a gate cutting 20 dB or more that share of the time)
Verse_Vocal, Chorus_Vocal > Instruments / Curves_Resolve_Stereo: avg 1.2 max 3.1 off 0.1; presence-2.8 bite-2.1
S:_Kick > Basses / Curves_Resolve_Stereo: avg 2.4 max 5.0 off 0.3; sub-3.9 bass-3.1
S:_Claps_&_Snares > S:_Gated_Snare / ReaGate: closed 62%
key only Ghost_Kick L-20.1 pk-6.0
```

The **key** is the track that tells the plugin when to act. Each line reads: key tracks > track / plugin: numbers. The script decides every 100 ms whether the key plays.

A plugin gets a line only when the key really drives it. The script looks at the moments when the key starts while the plugin's input stays about equally loud (within 1 dB of the 100 ms before). A real ducker cuts more right then; a plugin that only reacts to its own track does not, even if the key mostly plays in the louder parts of the song. A line needs a gate, or at least 10 such key starts with a cut that jumps by 0.5 dB on average, or a band that jumps by 1 dB.

| Part | Meaning | Shown |
| --- | --- | --- |
| `avg`, `max` | Gain reduction while the key plays, measured from the plugin's least-reduced moments, so make-up gain does not count | Always |
| `off` | Average reduction while the key is silent | Always |
| Band names | How much more (`-`) or less (`+`) that band is cut right after the key starts than just before, at least 1 dB, at most two | Only when the bands change differently from each other, so a reduction that is the same everywhere shows none |
| `closed n%` | A gate: the share of the time it cuts 20 dB or more. Replaces avg, max and off | When the plugin cuts fully at least once |
| `key only` | A track that feeds only a side-chain input: its level and peak. It is in no mix total | When its plugin has a line |

A plugin gets a line only if its key is silent for at least 5 s in total. With less silence, the script cannot tell the key's effect apart from what the plugin always does. The plugin must also be a gate, reduce at least 0.5 dB more or less with the key, or change a band. The Track Detail message gives the same numbers for the chosen tracks, whole song and per region.

### Region blocks

A `REGIONS` block follows, with one block per region:

```
R2 Verse_1 10.67-53.33 | I-14.5 M-9.7 S-11.8 LRA5.5 W27 | presence-3 sibilance-4
 chain in I-19.5 M-14.7 LRA5.7 cr12.9 >> gain+5.0 cr-2.3
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
| `mask` | Hz ranges where 2 or more of the top tracks each hold at least 25% of the energy, measured over the seconds they play together. The number is each track's % of all energy in that range. A pair counts only if it plays together for at least 25% of the shorter track's playing time |

A region line also shows the master's `c`, `pL n` / `pR n`, `sub!` and `clip n`, but only when they are notable: `c` below 0, balance 12 or more, or any clipped samples. A missing value means normal.

A note marked `approx` means those tracks' shares are approximate, because their folder also receives sends.

## Project YAML

The YAML is compact. Short lists and settings stay on one line (`{key: value, ...}`), and a value at its default is usually left out.

### Notes, meta and markers

```yaml
additional_information:
  - the project notes, then one line per plugin note
meta: {bpm: 120.0, sample_rate: 44100, time_sig: 4/4}
arr:
  - {name: Drop, start_s: 53.33, type: marker}
```

`arr` holds only markers and is left out when there are none. Regions are on the region lines of the measured data.

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
      - Ducking Comp (ReaComp, wet 80%): {att: 5.0 ms, band_1: {freq: 181, gn: 2.0}, out: 0.0 dB}
      - Old EQ (bypassed)
      - Second Comp: same as plugin 1 on Harmony
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

The YAML leaves out a muted track that made no sound in the measurement, and its sends. The same goes for a silent track inside a muted folder. A track with mute automation stays, and so does a folder that still holds a kept track.

Inside `fx`:

| Form | Meaning |
|---|---|
| `fx: A > B` | Plugin names only, used for most tracks |
| `fx:` with a list | Full settings, one line per plugin, used for the master and the tracks named under Regions, with their folders |
| `Name: {...}` | The plugin and its settings, as the plugin reports them |
| `Name: same as plugin N on TRACK` | Exactly the settings of the Nth plugin in that track's chain |
| `Name` alone | A plugin with no settings to show, such as one that is bypassed |
| `(...)` after a name | Any of: the original name of a renamed plugin, `instrument`, `bypassed`, `wet NN%` (REAPER's mix knob for the plugin) |
| `band_1: {freq: 181}` | Grouped shorthand: settings with a common name start, here `band_1_freq` |
| `low_shelf_3: off` | A module that is switched off |
| `sat: 0.5-1.2` | An automated setting shows its range over the song (not the value at the edit cursor); its envelope is listed under `auto` |

To save space, the YAML leaves out some settings:

- Any setting whose name contains `solo`, `delta` or `master bypass`, when it is off.
- A switched-off module's settings and its switch (`active` or `enabled`), when they share a name. If a plugin's settings don't share the switch's name, the switch stays.

The AI can ask for "DETAIL <track name>" to get a track's full plugin settings, sends, automation and measurements per region. In the detail, each region line says when the track plays inside the region, in song seconds, for example `on 12-98,120-150`. Pauses under 3 s do not count. A line without `on` means the track plays the whole region.

## When a focus is chosen

Whole Song has no focus and is the prompt described above. The other choices are of two kinds:

- **Track groups:** Vocals, Drums & Bass, Guitars, Keys & Synths, Strings & Brass, Instruments, Effects & Returns, Selected Tracks.
- **Topics:** Low End (20-315 Hz), Mids (315-5000 Hz), High End (5000-20000 Hz), Stereo Image, Master & Loudness.

### Track groups

The prompt adds a `FOCUS DATA` part to the legend, and `FOCUS: <name>. Give advice only about these tracks: ...` at the end. The measured data changes like this:

| Part | Change |
|---|---|
| `TRACKS` | Focus tracks and returns also show `clip n`, `prepk` (sample peak before their own fader) and `levels` (all 15 band levels). The data leaves out tracks that never play together with a focus track |
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

### Topics

The prompt adds a `TOPIC DATA` part to the legend, and `FOCUS: <name>. Give advice only about <the topic>.` at the end. What changes depends on the topic.

**Low End, Mids and High End** keep only the data of their frequency range:

```
Bass s20 rs48 L-26.0 pk-8.0 cr14 a80 W15 c.93 pL1 | sub+3 bass+4 | levels rumble-60 deepsub-40 sub-27 bass-26 body-35 mud-44
```

| Part | Change |
|---|---|
| `TRACKS` | Only tracks with at least 2% of the range's energy in some region. New field `rs`: the track's % of the range's energy (all counted tracks add up to 100; `s` stays the share of the whole mix). `levels`: the track's band levels in the range (dB) |
| Band data | The song's mid and side levels, the bumps and the region deviations stay only inside the range |
| Track lines | Every track with `rs` 2 or more in that region, highest `rs` first. No `R n also` line |
| `mask` | The usual rule, over these tracks and inside the range only |
| `sub!` | Only in Low End |
| YAML | Tracks left out of the data show only name, parent and flags |

**Stereo Image** leaves out the band data: bumps, region band deviations and `mask` lines. The song line keeps the master's mid and side levels.

**Master & Loudness** shortens the regions:

| Part | Change |
|---|---|
| Track lines | The loudest tracks until they cover 85% of the region: 3 to 10 lines, none under 1%. No `R n also` and `mask` lines |
| YAML | Only the master lists full plugin settings. Every track lists plugin names only |
