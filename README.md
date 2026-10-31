# 🎛️ REAPER AI Mix & Master Assistant

[![REAPER](https://img.shields.io/badge/REAPER-v6.0%2B-blue.svg)](https://www.cockos.com/reaper/)
[![ReaImGui](https://img.shields.io/badge/GUI-ReaImGui-orange.svg)](https://github.com/cfillion/reaimgui)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

An audio analysis and AI mixing assistant embedded directly inside **Cockos REAPER**.

The script performs a non-destructive render of your mix or isolated stems, extracts mastering-grade DSP metrics across project regions, serializes routing and FX parameter states into compact YAML, and provides feedback either directly via the **DeepSeek API** or through exportable prompts for web-based LLMs.

## 🌟 Features

### 1. 9-Band Mastering DSP Engine

Extracts dynamic and tonal metrics per region using a Chamberlin State-Variable Filter (SVF) engine:

- **Dynamics:** True Peak (dBFS), RMS (dBFS), and Crest Factor (dB).
- **Stereo Field:** Stereo width percentage (`width_pct`).
- **Gated Sub-Mono Phase Check:** Evaluates stereo energy below 120 Hz using a `-60 dBFS` threshold gate to prevent quiet tails and plugin noise floors from triggering false phase alerts.
- **9 Frequency Bands (dBFS):** Sub (60 Hz), Punch (120 Hz), Mud (250 Hz), Boxy (500 Hz), Mid/Core (1 kHz), Presence (3 kHz), Harshness (6 kHz), Sibilance (8 kHz), and Air (12 kHz).

### 2. Mix State Manager & Isolated Target Auditioning

- **Targets:** Full Mix, Vocals, Drums & Bass, Instruments, or Soloed Tracks Only.
- **Routing Awareness:** Understands folder hierarchies and can optionally mute parallel busses or bypass Master FX during stem auditioning.
- **State Restoration:** Restores track mutes, solos, and Master FX to their exact pre-scan states when finished or if a render is cancelled.
- **Cancellation Handling:** Detects cancelled renders via REAPER project settings and logs the status directly to the chat interface without modal error dialogs.

### 3. Active Track Detection

Cross-references track audio items against project markers/regions. If an instrument does not play during a specific section, the assistant will not critique or recommend changes for that instrument during that region.

### 4. Token-Optimized Project Serializer

- Suppresses default bypass states, inactive EQ bands, and irrelevant UI controls.
- Abbreviates common audio parameter names (`freq`, `thr`, `rel`, `att`, `gn`) to minimize token usage when communicating with language models.

### 5. ReaImGui Interface

- Fixed-fit tables for regional dynamics and tonal balance metrics.
- Color-coded role badges for conversation history.
- Asynchronous balance query that does not block the UI during startup or manual refreshes.

### 6. File Exporter with Auto-Numbering

Every scan exports:

- **Prompt File (`.txt`):** Full project configuration and DSP metrics ready to copy into web LLMs (ChatGPT, Claude, Gemini).
- **Visual Summary (`.html`):** Standalone, styled HTML tables for viewing regional metrics in any browser.
- **Auto-Numbering:** Automatically appends sequential counters (`_01`, `_02`) to prevent overwriting previous reports.

## 📋 Requirements

1. **REAPER** v6.0 or higher (v7.x supported).
2. **ReaImGui** extension (installed via ReaPack).
3. **cURL** (standard on Windows 10/11 and macOS/Linux).
4. **DeepSeek API Key** _(Optional — only required for direct in-app API queries)._

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

## ⚙️ Mandatory One-Time Render Setup

The assistant relies on REAPER's native render engine. Set these options once to ensure background analysis functions correctly:

1. Open **File > Render...** (`Ctrl+Alt+R` on Windows / `Cmd+Opt+R` on macOS).
2. Configure the following:
    - **Source:** `Master mix`
    - **Bounds:** `Entire project`
    - **Directory:** Set your project folder or a temp directory (e.g., `C:\temp`).
    - **File name:** `temp_mix_render`
    - **Format:** `WAV`, `24-bit PCM`, `44100 Hz`, `Stereo`
    - **Render Speed:** `Full-speed Offline`
3. Under **Options**, ensure these three boxes are checked:
    - [x] **Add rendered items to new tracks in project**
    - [x] **Silently increment filenames to avoid overwriting**
    - [x] **Auto-close all render windows when finished**
4. Click **Save settings** (do not click Render).

## 📖 Usage

1. **Set Regions:** Add standard REAPER regions across your project timeline (`Verse`, `Chorus`, etc.).
2. **Run the Script:** Open the assistant from your Actions list or toolbar.
3. **Configure Your Scan:**
    - **Target:** Choose what to analyze (_Full Mix_, _Vocals_, _Drums & Bass_, _Instruments_, or _Soloed Tracks Only_).
    - **Duration:** Set analysis window per section (_10s_, _20s_, or _Full Region_).
    - **AI Model:** Select `DeepSeek V4 Pro` (reasoning/critique) or `DeepSeek Flash` (fast/budget).
    - **Mute Parallels / Bypass Master FX:** Recommended checked to evaluate clean stem tone.
4. **Run Analysis:** Click **Run Fresh Scan & Reset Chat**.
5. **Review Results:**
    - Review the regional **Macro-Dynamics** and **Tonal Balance** tables directly in the conversation log.
    - Send follow-up questions in the chat box (e.g., _"How can I fix the harshness in Chorus 1?"_).
    - Click **Copy Chat** at any time to copy the entire conversation to your clipboard.

If you plan to use direct in-DAW chat with DeepSeek:

1. Open `Mix and Master Assistant.lua` in any text editor or inside the REAPER IDE.
2. Near the top of the file, enter your API key:
    ```lua
    local API_KEY = "sk-your-actual-deepseek-api-key-here"
    ```

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
