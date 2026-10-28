# 🎛️ REAPER AI Mix & Master Assistant

[![REAPER](https://img.shields.io/badge/REAPER-v6.0%2B-blue.svg)](https://www.cockos.com/reaper/)
[![ReaImGui](https://img.shields.io/badge/GUI-ReaImGui-orange.svg)](https://github.com/cfillion/reaimgui)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

An intelligent, token-optimized mixing and mastering engineer embedded directly inside **Cockos REAPER**.

This tool performs a non-destructive **"Ghost Render"** of your mix or isolated stems, calculates mastering-grade DSP metrics across every region of your song, serializes your routing matrix and active FX chains into compact YAML, and feeds the entire context to an AI mixing engineer (either natively via the **DeepSeek API** or exported as a standalone prompt for web LLMs).

---

## 🌟 Key Features

### 1. 9-Band Mastering DSP Engine

Extracts critical dynamic and tonal metrics per region using an internal Chamberlin State-Variable Filter (SVF) engine:

- **Dynamics:** True Peak (dBFS), RMS (dBFS), and Crest Factor (dB).
- **Stereo Field:** Total stereo width percentage (`width_pct`).
- **Sub-Mono Phase Check:** Monitors stereo information below 120 Hz. Gated to ignore noise floors and dither so empty regions do not trigger false `Phase_Risk` alerts.
- **9 Frequency Bands:** Sub (60 Hz), Punch (120 Hz), Mud (250 Hz), Boxy (500 Hz), Mid/Core (1 kHz), Presence (3 kHz), Harshness (6 kHz), Sibilance (8 kHz), and Air (12 kHz).

### 2. Mix State Manager & Isolated Target Auditioning

Isolate stems for targeted acoustic and processing critique:

- **Targets:** Drums & Bass, Instruments, Vocals, Full Mix, or Soloed Tracks Only.
- **Smart Stem Routing:** Understands folder hierarchies and automatically mutes parallel busses or master-bus processing to prevent skewed readings.
- **Non-Destructive Restoration:** Automatically saves and restores track mutes, solos, and master FX states after every render.

### 3. Active Track Detection

Cross-references track audio items against project markers/regions. If an instrument does not play during a specific section, the assistant will not critique or recommend changes for that instrument during that region.

### 4. Token-Optimized Project Serializer

Converts complex project configurations into compact YAML for LLMs:

- Automatically strips bypass/default states, UI metering parameters, and boilerplate noise.
- Excludes parameters belonging to disabled EQ bands and dynamic modules.
- Abbreviates common parameter names (`freq`, `thr`, `rel`, `att`, `gn`, `rat`) to minimize API token consumption.

### 5. Interactive ReaImGui Chat Interface

- In-DAW chat window with live follow-up capability.
- Auto-sizing Markdown tables displaying regional dynamics and frequency balances.
- Inverted role badges (**YOU** in cyan, **DEEPSEEK** in green) for quick readability.
- Real-time, non-blocking asynchronous balance display.

### 6. Dual Export Mode (Free / API-Free Support)

- **Direct API Chat:** Connect directly to DeepSeek (`deepseek-v4-pro` or `deepseek-flash`).
- **Offline / Free Web-LLM Exporter:** Uncheck the API option to export a complete prompt file (`.txt`) and a styled, dark-mode visual summary report (`.html`) to copy into ChatGPT, Claude, Gemini, or DeepSeek Web.

---

## 📋 Requirements

1. **REAPER** (v6.0 or higher, fully compatible with v7.x).
2. **ReaImGui** extension (installed via ReaPack).
3. **cURL** (standard on Windows 10/11 and macOS/Linux).
4. **DeepSeek API Key** _(Optional — only required if querying the API directly inside REAPER)._

---

## 🚀 Installation

### 1. Install ReaImGui (via ReaPack)

1. Open REAPER.
2. Go to **Extensions > ReaPack > Browse packages...**
3. Search for `ReaImGui`.
4. Right-click `ReaImGui: Dear ImGui implementation for REAPER` and choose **Install**.
5. Click **Apply**, then restart REAPER.

### 2. Add the Script to REAPER

1. Download `Mix and Master Assistant.lua` from this repository.
2. In REAPER, click **Actions > Show action list...** (or press `?`).
3. Click **New action... > Load ReaScript...**
4. Select the downloaded `.lua` file.
5. (Optional) Assign a keyboard shortcut or toolbar icon to the action.

---

## ⚙️ Mandatory One-Time Render Setup

The assistant uses REAPER's native render engine for its "Ghost Render" analysis. Configure these settings once so the script can capture the audio buffer silently:

1. Open REAPER's render window: **File > Render...** (`Ctrl+Alt+R` on Windows / `Cmd+Opt+R` on macOS).
2. Set the following options:
    - **Source:** `Master mix`
    - **Bounds:** `Entire project`
    - **Directory:** Choose your default project folder or any temporary directory (e.g., `C:\temp`).
    - **File name:** `temp_mix_render`
    - **Format:** `WAV`, `24-bit PCM`, `44100 Hz`, `Stereo`
3. Under **Options**, ensure these three boxes are checked:
    - [x] **Add rendered items to new tracks in project** _(Mandatory)_
    - [x] **Silently increment filenames to avoid overwriting**
    - [x] **Auto-close all render windows when finished**
4. Click **Save settings** (do not click Render).

---

## 🔑 API Configuration (Optional)

If you plan to use direct in-DAW chat with DeepSeek:

1. Open `Mix and Master Assistant.lua` in any text editor or inside the REAPER IDE.
2. Near the top of the file, enter your API key:
    ```lua
    local API_KEY = "sk-your-actual-deepseek-api-key-here"
    ```
