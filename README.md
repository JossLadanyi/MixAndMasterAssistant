# 🎛️ REAPER AI Mix & Master Assistant

[![REAPER](https://img.shields.io/badge/REAPER-v6.0%2B-blue.svg)](https://www.cockos.com/reaper/)
[![ReaImGui](https://img.shields.io/badge/GUI-ReaImGui-orange.svg)](https://github.com/cfillion/reaimgui)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

An audio analysis and AI mixing assistant embedded directly inside **Cockos REAPER**.

One click renders your project once and measures every track and the master while it plays. The script turns the measurements and your routing and plugin settings into a compact prompt, then sends it to the **DeepSeek API** or copies it so you can paste it into a web chat. Keeping the prompt small (few tokens) is the main design goal.

## 🌟 Features

### 1. One-Render Measurement (JSFX analyzers)

Collect Project Info renders the project **once** into a temporary folder. During the render, small analyzer plugins (JSFX, written by the script itself) measure:

- **Per track and second:** level, peak, crest factor, 15 frequency bands, stereo correlation and width, sub-mono check (below 120 Hz), clipped samples, and when the track plays.
- **Master, every 100 ms:** loudness (integrated, momentary, short-term, LRA), 15 mid and 15 side bands, correlation, sub-mono check, balance, peak and clips, plus the level going into the master chain.
- **15 frequency bands** from 20 Hz to 20 kHz (rumble, deep sub, sub, bass/punch, body/warmth, mud, boxy, hollow/honk, nasal, bite, presence, harsh, sibilance, sizzle, air). Bands touch at -3 dB, so they add up to the broadband level.

The analyzers sit on hidden copies of your tracks ("phantom" tracks, measured after the fader), so your own tracks are not changed. Everything is removed again afterwards (one undo step), your render settings are restored and the temporary folder is emptied. A cancelled render or an error cleans up the same way.

### 2. Compact Project Serializer (YAML)

- Routing, sends (only sidechains are labelled) and plugin settings as short YAML.
- Plugin settings only where they matter: full settings for the tracks the question is about, names only for the rest. Default values, bypassed modules, screen-only controls and repeated settings ("same as plugin 2 on Vocal") are left out.
- Optional `MixAssistant_plugin_notes.txt` next to the script: a short note per plugin (or maker) for the AI, and settings to drop from the YAML.

### 3. Focus Prompts

One prompt per focus, built from the same measurements without a new render: **Whole Song**, **Vocals**, **Drums & Bass**, **Guitars**, **Keys & Synths**, **Strings & Brass**, **Instruments**, **Effects & Returns**, **Selected Tracks**, and the topics **Low End**, **Mids**, **High End**, **Stereo Image**, **Master & Loudness**.

- The prompt describes the song per region: master numbers (flagged only when notable), the loudest tracks, bands that stand out, and masking between tracks that really play together.
- The AI answers in a fixed format: overview, areas, and a priority table of at most 12 fixes.
- The prompt shows the project as it was when you collected; a warning appears when the project changed since.

### 4. Send, Copy, Track Detail

- **Send Project Info to Agent:** DeepSeek Flash (default, low cost) or Pro, with optional "Think". The estimated cost is shown before sending, the real cost after the answer.
- **Copy Project Info:** the whole prompt on the clipboard for a web chat (no API key needed). The prompt is also saved as `AI_Mix_Prompt_JSFX_<focus>.txt` next to the project, numbered so nothing is overwritten.
- **Send Track Detail...:** after a first answer, sends the full settings of the tracks you selected into the same chat (asks before sending).
- Follow-up questions in the chat box, **Copy Chat**, **Clear Chat**, a live account balance and a colour-coded, cached Markdown conversation view.

## 📋 Requirements

1. **REAPER** v6.0 or higher (v7.x supported).
2. **ReaImGui** extension (installed via ReaPack).
3. **SWS extension** (recommended: lets the script close the render window by itself).
4. **cURL** (standard on Windows 10/11 and macOS/Linux).
5. **DeepSeek API key** _(optional: only for Send; Copy works without it)._

## 🚀 Installation

### 1. Install ReaImGui

1. In REAPER, open **Extensions > ReaPack > Browse packages...**
2. Search for `ReaImGui`.
3. Right-click `ReaImGui: Dear ImGui implementation for REAPER` and select **Install**.
4. Click **Apply**, then restart REAPER.

### 2. Install the Script

1. Download `Mix and Master Assistant.lua` from this repository.
2. In REAPER, click **Actions > Show action list...** (or press `?`).
3. Click **New action... > Load ReaScript...**
4. Select the downloaded `.lua` file.
5. (Optional) Assign a keyboard shortcut or toolbar icon to the action.

The analyzer plugin needs no installation: the script writes it to REAPER's `Effects/MixAssistant` folder when you collect and removes it afterwards.

### 3. API key (only for Send)

Create a text file `apikey.txt` next to the script with your DeepSeek key on the first line. Keep it out of any public repository.

## ⚙️ One-Time Render Setup

1. Open **File > Render...** (`Ctrl+Alt+R` on Windows / `Cmd+Opt+R` on macOS).
2. Set **Source:** `Master mix` and **Bounds:** `Entire project`.
3. Click **Save settings** (do not click Render).

The script sets the folder, the file name, "add to project" and "auto-close" itself for its render and restores your settings afterwards. Tip: set the audio device to the project sample rate; the analyzers run at the device rate, and a different rate renders slower.

## 📖 Usage

1. **Set regions:** add standard REAPER regions across the timeline (`Intro`, `Verse`, `Chorus`, ...). Regions are what the prompt describes; markers only appear in the project YAML.
2. **Bypass** any plugin that only colours your monitoring (e.g. a headphone correction) on the master, so the measurements describe the mix.
3. **Collect Project Info.** The render takes about as long as the project (offline speed). A free step: nothing is sent anywhere.
4. Pick a **Focus** (the combo shows the track count of each group; hovering lists the tracks) and an **AI Model**.
5. **Send Project Info to Agent**, or **Copy Project Info** and paste it into a web chat.
6. Ask follow-up questions, or select tracks and use **Send Track Detail...**.

**Limit:** tracks × song length must fit in the analyzer memory (for example 128 tracks for about 30 minutes, or 49 tracks for about 68 minutes, at most 4096 tracks). Collect says so before it changes anything.

## 🔧 Tuning

| Setting | Default | Purpose |
| --- | --- | --- |
| `MAX_PLUGIN_PARAMS` (script) | `128` | Maximum parameters read per plugin (precision vs. tokens). |
| `MixAssistant_plugin_notes.txt` | optional | Notes for the AI and settings to drop, per plugin or maker. |
| `apikey.txt` | none | DeepSeek key (first line). |

## 📝 Changelog

### v6.0

- **New measurement:** JSFX analyzers replace the Lua analysis of a rendered file. 15 bands instead of 9, per second per track and per 100 ms on the master, from one render that leaves no trace in the project.
- **New prompt:** focus prompts, compact YAML, per-region lines with flagged values only, masking only between tracks that play together, cost shown before sending.
- **New buttons:** Collect, Send, Copy, Send Track Detail; DeepSeek Flash is the default model.
- **Removed:** the old "Run Fresh Scan" (solo / mute isolation, the 9-band Lua DSP, HTML tables). Earlier versions are in the git history.

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
