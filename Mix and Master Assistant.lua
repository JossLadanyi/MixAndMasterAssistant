-- ==============================================================================
-- REAPER AI MIX ASSISTANT & SCANNER (v4.5 - FULL READABILITY EDITION)
-- ==============================================================================
-- Features:
-- 1. Token-Optimized YAML Architecture Scanner (Reduces LLM cost, retains data)
-- 2. Mix State Manager (Target Soloing & Parallel / Master FX Muting)
-- 3. Ghost Render Engine with Auto-Cleanup & Non-Destructive State Restore
-- 4. 9-Band Mastering DSP Engine + Sub-Mono (<120Hz) Phase Check
-- 5. Active Track Detection (Tells AI exactly what is playing in each region)
-- 6. DeepSeek API Integration & Free Web-LLM Prompt Exporter (.txt)
-- ==============================================================================
-- 1. What Needs to Be Installed
-- - REAPER (v6 or above),
-- - ReaImGui,
-- - DeepSeek API Key (only if you want AI responses; not needed for .txt export mode).
-- 2. Render Window Setup (One-Time Setup)
--   Open File > Render... (Ctrl+Alt+R / Cmd+Opt+R) and configure these settings:
--   Source: Master mix
--   Bounds: Entire project
--   Directory: Choose your project folder (or any valid folder like C:\temp).
--   File name: temp_mix_render
--   Format: WAV, 24-bit PCM, 44100 Hz, Stereo.
--   Options (MANDATORY):
--     [x] Add rendered items to new tracks in project
--     [x] Silently increment filenames to avoid overwriting
--     [x] Auto-close all render windows when finished
--   Crucial Final Step: Click "Save settings"
-- ==============================================================================

local reaper = reaper

-- ==============================================================================
-- 1. GLOBAL CONFIGURATION & TUNING
-- ==============================================================================

-- DeepSeek API Key (Only needed if using Output Mode: API or Both)
local API_KEY = "YOUR_DEEPSEEK_API_KEY"

-- Maximum plugin parameters to capture per effect (Balances precision vs tokens)
local MAX_PLUGIN_PARAMS = 128

-- DSP Sample Rate & Filter Q Factor (Chamberlin State-Variable Filter)
local SAMPLE_RATE = 44100
local FILTER_Q = 0.5

-- Default plugin property expectations for boilerplate suppression
local DEFAULT_SETTINGS = {
    plugin = {
        bypassed = false,
        type = "effect",
        delta = "normal",
        wet = "100%"
    }
}

-- Parameters that carry zero mix relevance (GUI controls, meters, themes)
local IGNORED_PARAMETER_KEYWORDS = {
    "unused", "reserved", "midi", "ui ", "gui", "program",
    "preset", "monitoring", "meter", "theme", "tooltip",
    "display", "analyzer"
}

-- ==============================================================================
-- 2. STRING SANITIZATION & TOKEN OPTIMIZATION
-- ==============================================================================

local function trim_string(str)
    if type(str) ~= "string" then return str end
    return str:match("^%s*(.-)%s*$")
end

local function round(num, decimal_places)
    local multiplier = 10^(decimal_places or 0)
    return math.floor(num * multiplier + 0.5) / multiplier
end

-- This function abbreviates parameter names for the AI payload to save tokens,
-- but the Lua function name and variables remain human-readable.
local function clean_param_key(param_name)
    if not param_name then return "param" end
    param_name = trim_string(param_name):lower()

    -- Audio Parameter Abbreviations for the YAML output
    local abbreviations = {
        frequency = "freq", threshold = "thr", release = "rel", attack = "att", ratio = "rat",
        volume = "vol", gain = "gn", level = "lvl", output = "out", input = "inp", feedback = "fb",
        time = "tm", mix = "mx", width = "wdth", drive = "drv", resonance = "res", bandwidth = "bw",
        cutoff = "cut", highpass = "hp", lowpass = "lp", slope = "slp", sidechain = "sc",
        lookahead = "la", saturation = "sat"
    }

    for full_word, abbreviation in pairs(abbreviations) do
        param_name = param_name:gsub(full_word, abbreviation)
    end

    -- Preserve unit context cleanly
    param_name = param_name:gsub("%%", "_pct")
    param_name = param_name:gsub("%s*%(%s*hz%s*%)", "_hz"):gsub("%s*%[%s*hz%s*%]", "_hz")
    param_name = param_name:gsub("%s*%(%s*db%s*%)", "_db"):gsub("%s*%[%s*db%s*%]", "_db")
    param_name = param_name:gsub("%s*%(%s*ms%s*%)", "_ms"):gsub("%s*%[%s*ms%s*%]", "_ms")

    -- Strip special characters
    param_name = param_name:gsub("[%[%]%(%)]", "")
    param_name = param_name:gsub("[%s%-%/]+", "_")
    param_name = param_name:gsub("^_+", ""):gsub("_+$", "")

    return param_name ~= "" and param_name or "param"
end

local function escape_yaml_string(str)
    if type(str) ~= "string" then return tostring(str) end
    str = trim_string(str)
    -- Don't quote booleans or numbers
    if tonumber(str) and not str:lower():find("inf") then return str end
    if str:lower() == "true" or str:lower() == "false" then return str:lower() end
    -- Quote strings with YAML special characters
    if str:match('[:#",%[%]{}]') or str:match('^%s') or str:match('%s$') then
        return '"' .. str:gsub('"', '\\"') .. '"'
    end
    return str
end

local function is_valid_parameter_name(name)
    if not name or name == "" then return false end
    name = trim_string(name):lower()
    if name:match("^control %d+$") then return false end
    for _, word in ipairs(IGNORED_PARAMETER_KEYWORDS) do
        if name:find(word) then return false end
    end
    return true
end

local function is_boilerplate(param_name, param_value)
    if not param_name or not param_value then return true end

    local name_lower = trim_string(param_name):lower()
    local val_clean = trim_string(param_value):lower():gsub("%s+", "")

    if val_clean == "" or name_lower:find("ui") or name_lower:find("graph") then return true end

    -- Filter out default bypass/power states
    if name_lower == "bypass" and (val_clean == "normal" or val_clean == "off" or val_clean == "0") then return true end
    if name_lower == "power" and (val_clean == "on" or val_clean == "1") then return true end

    -- Filter out default 100% wet / 0% dry states
    local num_val = val_clean:gsub("db$", ""):gsub("%%$", "")
    if name_lower:find("wet") and (num_val == "100" or num_val == "100.0" or num_val == "1.0") then return true end
    if name_lower:find("dry") and (num_val == "0" or num_val == "0.0" or val_clean == "off") then return true end

    return false
end

local function linear_to_db(vol)
    if vol <= 1e-7 then return -144.0 end
    return math.floor((20 * math.log(vol, 10)) * 10 + 0.5) / 10
end

local function format_pan_value(pan_val)
    local pct = math.floor(math.abs(pan_val) * 100 + 0.5)
    if pct == 0 then return "Center" end
    return string.format("%d%% %s", pct, pan_val < 0 and "Left" or "Right")
end

local function get_track_identity(track)
    if not track or track == 0 then return "Unknown Track" end
    if track == reaper.GetMasterTrack(0) then return "MASTER BUS" end
    local track_idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
    local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    track_name = trim_string(track_name)
    return (not track_name or track_name == "") and ("Track " .. track_idx) or track_name
end

local function get_model_name(model_choice)
    local model_ids = { [1] = "deepseek-v4-pro", [2] = "deepseek-flash" }
    return model_ids[model_choice] or "deepseek-v4-pro"
end

local function get_duration_seconds(duration_idx)
    local duration_map = { [0] = 10, [1] = 20, [2] = 0 }
    return duration_map[duration_idx] or 0
end

-- ==============================================================================
-- 3. ORIGINAL SERIALIZER ENGINE (COMPACT & RANKED YAML)
-- ==============================================================================

local function to_inline_yaml(tbl)
    if type(tbl) ~= "table" then
        return type(tbl) == "string" and escape_yaml_string(tbl) or tostring(tbl)
    end
    local is_array, max_key = true, 0
    for k, _ in pairs(tbl) do
        if type(k) ~= "number" then is_array = false; break end
        max_key = math.max(max_key, k)
    end
    local parts = {}
    if is_array then
        if max_key == 0 then return "[]" end
        for i = 1, max_key do table.insert(parts, to_inline_yaml(tbl[i])) end
        return "[" .. table.concat(parts, ", ") .. "]"
    else
        local keys = {}
        for k in pairs(tbl) do table.insert(keys, k) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        if #keys == 0 then return "{}" end
        for _, k in ipairs(keys) do
            local v = tbl[k]
            local v_str = (type(v) == "table") and to_inline_yaml(v) or (type(v) == "string" and escape_yaml_string(v) or tostring(v))
            table.insert(parts, tostring(k) .. ": " .. v_str)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
end

local INLINE_KEYS = { meta = true, params = true, media = true, flags = true, active_trks = true }
local INLINE_ARRAY_PARENTS = { arr = true, connections = true }
local KEY_ORDER = {
    "notes", "meta", "arr", "connections", "tracks",
    "track", "flags", "vol_db", "pan", "depth", "parent",
    "auto", "media", "fx",
    "name", "type", "bypassed", "wet", "params",
    "src", "dst", "purpose", "dst_ch"
}
local KEY_RANK = {}
for idx, key_name in ipairs(KEY_ORDER) do KEY_RANK[key_name] = idx end

local function to_yaml(tbl, indent, parent_key)
    indent = indent or 0
    local pad = string.rep("  ", indent)
    local yaml_output = ""

    if type(tbl) ~= "table" then return "" end

    local is_array, max_key = true, 0
    for k, _ in pairs(tbl) do
        if type(k) ~= "number" then is_array = false; break end
        max_key = math.max(max_key, k)
    end

    if is_array then
        if max_key == 0 then return "" end
        for i = 1, max_key do
            local v = tbl[i]
            if INLINE_ARRAY_PARENTS[parent_key] and type(v) == "table" then
                yaml_output = yaml_output .. pad .. "- " .. to_inline_yaml(v) .. "\n"
            elseif type(v) == "table" then
                local child = to_yaml(v, indent + 1, parent_key)
                yaml_output = yaml_output .. pad .. "- " .. child:gsub("^%s+", "")
            else
                yaml_output = yaml_output .. pad .. "- " .. (type(v) == "string" and escape_yaml_string(v) or tostring(v)) .. "\n"
            end
        end
    else
        local keys = {}
        for k in pairs(tbl) do table.insert(keys, k) end
        table.sort(keys, function(a, b)
            local rank_a = KEY_RANK[a] or 999
            local rank_b = KEY_RANK[b] or 999
            if rank_a ~= rank_b then return rank_a < rank_b end
            return tostring(a) < tostring(b)
        end)

        for _, k in ipairs(keys) do
            local v = tbl[k]
            if v ~= nil then
                if INLINE_KEYS[k] and type(v) == "table" then
                    yaml_output = yaml_output .. pad .. tostring(k) .. ": " .. to_inline_yaml(v) .. "\n"
                elseif type(v) == "table" then
                    if next(v) ~= nil then
                        yaml_output = yaml_output .. pad .. tostring(k) .. ":\n" .. to_yaml(v, indent + 1, k)
                    end
                elseif k == "notes" then
                    local block = v:gsub("\r", ""):gsub("\n", "\n" .. pad .. "  ")
                    yaml_output = yaml_output .. pad .. "additional_information:\n" .. pad .. "  " .. block .. "\n"
                else
                    local val_str = type(v) == "string" and escape_yaml_string(v) or tostring(v)
                    yaml_output = yaml_output .. pad .. tostring(k) .. ": " .. val_str .. "\n"
                end
            end
        end
    end
    return yaml_output
end

-- ==============================================================================
-- 4. COMPLETE ROUTING MATRIX & PROJECT HIERARCHY SCANNER
-- ==============================================================================

local function get_arrangement_markers()
    local arrangement = {}
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, (num_markers + num_regions) - 1 do
        local retval, is_region, pos, region_end, name, marker_idx = reaper.EnumProjectMarkers3(0, i)
        if retval > 0 then
            name = trim_string(name) or ""
            local element = {
                type = is_region and "region" or "marker",
                name = name ~= "" and name or ((is_region and "Region " or "Marker ") .. marker_idx),
                start_s = math.floor(pos * 100 + 0.5) / 100
            }
            if is_region then
                element.end_s = math.floor(region_end * 100 + 0.5) / 100
            end
            table.insert(arrangement, element)
        end
    end
    return #arrangement > 0 and arrangement or nil
end

local function get_all_connections()
    local connections = {}
    local num_tracks = reaper.CountTracks(0)
    local track_lookup = {}

    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        track_lookup[track] = get_track_identity(track)
    end

    for i = 0, num_tracks - 1 do
        local src_track = reaper.GetTrack(0, i)
        local num_sends = reaper.GetTrackNumSends(src_track, 0)

        for s = 0, num_sends - 1 do
            local dest_track = reaper.GetTrackSendInfo_Value(src_track, 0, s, "P_DESTTRACK")
            if dest_track and dest_track ~= 0 then
                local src_name = track_lookup[src_track] or get_track_identity(src_track)
                local dest_name = track_lookup[dest_track] or "Unknown Track"
                local conn = { src = src_name, dst = dest_name }

                local main_send = reaper.GetMediaTrackInfo_Value(src_track, "B_MAINSEND")
                local dst_chan = math.floor(reaper.GetTrackSendInfo_Value(src_track, 0, s, "I_DSTCHAN"))
                local base_chan = (dst_chan & 1023) + 1
                local dst_ch_str = string.format("%d/%d", base_chan, base_chan + 1)
                local item_count = type(dest_track) == "userdata" and reaper.CountTrackMediaItems(dest_track) or 0

                if (dst_chan & 1023) >= 2 then
                    conn.purpose = "sidechain"
                elseif main_send == 0 and (dst_chan & 1023) < 2 then
                    conn.purpose = "bus_summing"
                elseif main_send == 1 and (dst_chan & 1023) < 2 and item_count == 0 then
                    conn.purpose = "parallel_split"
                end

                local mode_val = math.floor(reaper.GetTrackSendInfo_Value(src_track, 0, s, "I_SENDMODE"))
                if mode_val == 1 then conn.type = "prefx" elseif mode_val == 3 or mode_val == 2 then conn.type = "pre" end
                if dst_ch_str ~= "1/2" then conn.dst_ch = dst_ch_str end

                conn.vol_db = linear_to_db(reaper.GetTrackSendInfo_Value(src_track, 0, s, "D_VOL"))
                table.insert(connections, conn)
            end
        end
    end
    return #connections > 0 and connections or nil
end

local function get_track_fx_chain(track)
    local num_fx = reaper.TrackFX_GetCount(track)
    if num_fx == 0 then return nil end
    local fx_chain = {}

    for i = 0, num_fx - 1 do
        local _, fx_name = reaper.TrackFX_GetFXName(track, i)
        fx_name = trim_string(fx_name) or "Unknown FX"
        fx_name = fx_name:match(":%s*(.+)") or fx_name
        fx_name = trim_string(fx_name)

        local plugin = { name = fx_name }
        if not reaper.TrackFX_GetEnabled(track, i) then plugin.bypassed = true end

        local ok_wet, wet_val = reaper.TrackFX_GetNamedConfigParm(track, i, "wet")
        local current_wet = "100%"
        if ok_wet and wet_val then
            local wet_num = tonumber(wet_val)
            if wet_num then current_wet = math.floor(wet_num * 100 + 0.5) .. "%" end
        end
        if current_wet ~= DEFAULT_SETTINGS.plugin.wet then plugin.wet = current_wet end

        local _, raw_name = reaper.TrackFX_GetFXName(track, i)
        raw_name = trim_string(raw_name) or ""
        local inst_idx = reaper.TrackFX_GetInstrument(track)
        local plugin_type = ((inst_idx == i) or raw_name:match("^%w+i:")) and "instrument" or "effect"
        if plugin_type ~= DEFAULT_SETTINGS.plugin.type then plugin.type = plugin_type end

        if plugin_type == "effect" and not plugin.bypassed then
            local num_params = reaper.TrackFX_GetNumParams(track, i)
            local params_table = {}
            local count = 0
            local max_inspect = 1000

            for k = 0, num_params - 1 do
                if k >= max_inspect then break end
                local _, param_name = reaper.TrackFX_GetParamName(track, i, k)
                param_name = trim_string(param_name)

                if is_valid_parameter_name(param_name) then
                    local _, param_value = reaper.TrackFX_GetFormattedParamValue(track, i, k)
                    param_value = trim_string(param_value)

                    if not is_boilerplate(param_name, param_value) then
                        if count < MAX_PLUGIN_PARAMS then
                            local clean_key = clean_param_key(param_name)
                            params_table[clean_key] = tonumber(param_value) or param_value
                            count = count + 1
                        else
                            break
                        end
                    end
                end
            end
            if next(params_table) ~= nil then plugin.params = params_table end
        end
        table.insert(fx_chain, plugin)
    end
    return #fx_chain > 0 and fx_chain or nil
end

local function process_track_data(track, is_master, current_depth)
    local track_name = get_track_identity(track)
    local track_data = { track = track_name }

    if not is_master and current_depth and current_depth > 0 then
        track_data.depth = current_depth
    end

    local parent = reaper.GetParentTrack(track)
    if parent then track_data.parent = get_track_identity(parent) end

    local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    local mute_state = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1
    local solo_state = reaper.GetMediaTrackInfo_Value(track, "I_SOLO") > 0
    local phase_state = reaper.GetMediaTrackInfo_Value(track, "B_PHASE") == 1

    local flags = {}
    if folder_depth == 1 then table.insert(flags, "folder") end
    if mute_state then table.insert(flags, "muted") end
    if solo_state then table.insert(flags, "soloed") end
    if phase_state then table.insert(flags, "phase_flipped") end
    if #flags > 0 then track_data.flags = flags end

    local volume = linear_to_db(reaper.GetMediaTrackInfo_Value(track, "D_VOL"))
    if volume ~= 0.0 then track_data.vol_db = volume end

    local pan = format_pan_value(reaper.GetMediaTrackInfo_Value(track, "D_PAN"))
    if pan ~= "Center" then track_data.pan = pan end

    local item_count = reaper.CountTrackMediaItems(track)
    if item_count > 0 then
        local total_duration = 0
        for idx = 0, item_count - 1 do
            local item = reaper.GetTrackMediaItem(track, idx)
            if item then
                total_duration = total_duration + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            end
        end
        track_data.media = {
            items = item_count,
            dur_s = math.floor(total_duration * 10 + 0.5) / 10
        }
    end

    local num_envelopes = reaper.CountTrackEnvelopes(track)
    if num_envelopes > 0 then
        local active_envelopes = {}
        for env_idx = 0, num_envelopes - 1 do
            local env = reaper.GetTrackEnvelope(track, env_idx)
            if env then
                local _, env_name = reaper.GetEnvelopeName(env, "")
                env_name = trim_string(env_name)
                if env_name and env_name ~= "" then table.insert(active_envelopes, env_name) end
            end
        end
        if #active_envelopes > 0 then track_data.auto = table.concat(active_envelopes, ", ") end
    end

    if not mute_state then track_data.fx = get_track_fx_chain(track) end
    return track_data
end

local function extract_full_project_yaml()
    local num, den = reaper.TimeMap_GetTimeSigAtTime(0, 0)
    local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
    local proj_notes = trim_string(reaper.GetSetProjectNotes(0, false, ""))

    local project_data = {
        meta = {
            bpm = reaper.Master_GetTempo(),
            time_sig = string.format("%d/%d", num, den),
            sample_rate = sr > 0 and math.floor(sr) or "Default"
        },
        arr = get_arrangement_markers(),
        connections = get_all_connections(),
        tracks = {}
    }

    if proj_notes and proj_notes ~= "" then project_data.notes = proj_notes end

    -- 1. Master Track
    table.insert(project_data.tracks, process_track_data(reaper.GetMasterTrack(0), true, 0))

    -- 2. Child Tracks & Folders
    local current_depth = 0
    local num_tracks = reaper.CountTracks(0)
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        table.insert(project_data.tracks, process_track_data(track, false, current_depth))
        local folder_delta = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
        if folder_delta == 1 then
            current_depth = current_depth + 1
        elseif folder_delta < 0 then
            current_depth = math.max(0, current_depth + folder_delta)
        end
    end

    return to_yaml(project_data), project_data.arr
end

-- ==============================================================================
-- 5. MIX STATE MANAGER (TARGET SOLOING & MUTING)
-- ==============================================================================

local saved_mix_state = { tracks = {}, master_fx = {} }

local function get_track_category(name)
    if type(name) ~= "string" then
        name = ""
    else
        name = trim_string(name):lower()
    end

    -- 99 = Parallel / Crush / NYC Busses
    if name:match("nyc") or name:match("rear") or name:match("parallel") then
        return 99

    -- 1 = Drums & Bass (Drums, Percussion, Kicks, Snares, 808s, Basses)
    elseif name:match("drum") or name:match("kick") or name:match("snare") or
           name:match("hat") or name:match("perc") or name:match("cymbal") or
           name:match("bass") or name:match("808") or name:match("sub") then
        return 1

    -- 3 = Vocals (Lead Vox, Harmonies, BGV, Choirs, Acapellas)
    elseif name:match("vox") or name:match("vocal") or name:match("choir") or
           name:match("lead") or name:match("bgv") or name:match("acap") or name:match("harmony") then
        return 3

    -- 2 = Instruments (Everything else: Guitars, Keys, Synths, Strings, Horns, FX, Pads)
    else
        return 2
    end
end

local function save_and_apply_mix_state(target_mode, mute_parallels, bypass_master_fx)
    saved_mix_state = { tracks = {}, master_fx = {} }
    local master_track = reaper.GetMasterTrack(0)

    -- Backup and bypass master FX
    for fx_idx = 0, reaper.TrackFX_GetCount(master_track) - 1 do
        saved_mix_state.master_fx[fx_idx] = reaper.TrackFX_GetEnabled(master_track, fx_idx)
        if bypass_master_fx then reaper.TrackFX_SetEnabled(master_track, fx_idx, false) end
    end

    -- Backup and set track solos/mutes
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        if track then
            local track_guid = reaper.GetTrackGUID(track)
            local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
            local category = get_track_category(track_name)

            saved_mix_state.tracks[track_guid] = {
                solo = reaper.GetMediaTrackInfo_Value(track, "I_SOLO"),
                mute = reaper.GetMediaTrackInfo_Value(track, "B_MUTE")
            }

            if target_mode ~= 4 then
                reaper.SetMediaTrackInfo_Value(track, "I_SOLO", (category == target_mode) and 2 or 0)
            end
            if mute_parallels and category == 99 then
                reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 1)
            end
        end
    end
end

local function restore_mix_state()
    local master_track = reaper.GetMasterTrack(0)

    if saved_mix_state then
        for fx_idx, state in pairs(saved_mix_state.master_fx or {}) do
            if master_track and reaper.TrackFX_GetCount(master_track) > fx_idx then
                reaper.TrackFX_SetEnabled(master_track, fx_idx, state)
            end
        end

        for i = 0, reaper.CountTracks(0) - 1 do
            local track = reaper.GetTrack(0, i)
            if track then
                local track_guid = reaper.GetTrackGUID(track)
                local state = saved_mix_state.tracks and saved_mix_state.tracks[track_guid]
                if state then
                    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", state.solo)
                    reaper.SetMediaTrackInfo_Value(track, "B_MUTE", state.mute)
                end
            end
        end
    end
end

-- ==============================================================================
-- 6. ACTIVE TRACK DETECTION (WITH PARENT HIERARCHY MUTE CHECK)
-- ==============================================================================

--- Traverses up the folder hierarchy to verify if any parent track is muted.
local function is_track_audible(track)
    local current = track
    while current do
        if reaper.GetMediaTrackInfo_Value(current, "B_MUTE") == 1 then
            return false -- A parent or the track itself is muted
        end
        current = reaper.GetParentTrack(current)
    end
    return true
end

local function get_active_tracks(start_time, end_time, max_tracks)
    local active_tracks = {}
    -- Only loop through tracks that existed BEFORE the render occurred
    local limit = (max_tracks or reaper.CountTracks(0)) - 1

    for i = 0, limit do
        local track = reaper.GetTrack(0, i)

        if is_track_audible(track) then
            local is_active = false
            local item_count = reaper.CountTrackMediaItems(track)

            for j = 0, item_count - 1 do
                local item = reaper.GetTrackMediaItem(track, j)
                local item_muted = (reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1)

                if not item_muted then
                    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

                    if (pos < end_time) and (pos + len > start_time) then
                        is_active = true
                        break
                    end
                end
            end

            if is_active then
                local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
                table.insert(active_tracks, name ~= "" and name or ("Track_" .. (i + 1)))
            end
        end
    end

    return active_tracks
end

-- ==============================================================================
-- 7. 9-BAND MASTERING DSP ENGINE
-- ==============================================================================

local function process_audio_chunk(take, item_pos, analyze_start, analyze_dur)
    local num_samples = math.floor(analyze_dur * SAMPLE_RATE)
    if num_samples < 1 then return nil end

    local buffer = reaper.new_array(num_samples * 2)
    local accessor = reaper.CreateTakeAudioAccessor(take)
    local ok = reaper.GetAudioAccessorSamples(accessor, SAMPLE_RATE, 2, analyze_start - item_pos, num_samples, buffer)
    reaper.DestroyAudioAccessor(accessor)

    if not ok then return nil end

    -- Defensive conversion: some REAPER builds expose the data differently, so we avoid
    -- assuming every array supports .table() without checking first.
    local samples = buffer
    if type(samples) == "table" and samples.table then
        samples = samples:table()
    elseif type(samples) == "userdata" and type(samples.table) == "function" then
        samples = samples:table()
    end

    local total_sample_count = type(samples) == "table" and #samples or 0
    if total_sample_count < 2 then return nil end

    local peak_left, peak_right = 0, 0
    local sum_sq_mid, sum_sq_side = 0, 0

    -- Energy accumulators
    local eng_sub, eng_punch, eng_mud, eng_boxy = 0, 0, 0, 0
    local eng_core, eng_pres, eng_harsh = 0, 0, 0
    local eng_sib, eng_air, eng_sub_side = 0, 0, 0

    -- Filter Coefficients
    local f_sub   = 2 * math.sin(math.pi * 60 / SAMPLE_RATE)
    local f_punch = 2 * math.sin(math.pi * 120 / SAMPLE_RATE)
    local f_mud   = 2 * math.sin(math.pi * 250 / SAMPLE_RATE)
    local f_boxy  = 2 * math.sin(math.pi * 500 / SAMPLE_RATE)
    local f_core  = 2 * math.sin(math.pi * 1000 / SAMPLE_RATE)
    local f_pres  = 2 * math.sin(math.pi * 3000 / SAMPLE_RATE)
    local f_harsh = 2 * math.sin(math.pi * 6000 / SAMPLE_RATE)
    local f_sib   = 2 * math.sin(math.pi * 8000 / SAMPLE_RATE)
    local f_air   = 2 * math.sin(math.pi * 12000 / SAMPLE_RATE)

    local l1,b1, l2,b2, l3,b3, l4,b4, l5,b5, l6,b6, l7,b7, l8,b8, l9,b9, ls,bs = 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

    -- Fast native table loop (samples[1] = L0, samples[2] = R0, ...)
    for i = 1, total_sample_count, 2 do
        local samp_L = samples[i]
        local samp_R = samples[i+1]

        if math.abs(samp_L) > peak_left then peak_left = math.abs(samp_L) end
        if math.abs(samp_R) > peak_right then peak_right = math.abs(samp_R) end

        local mid = (samp_L + samp_R) * 0.5
        local side = (samp_L - samp_R) * 0.5

        sum_sq_mid = sum_sq_mid + (mid * mid)
        sum_sq_side = sum_sq_side + (side * side)

        l1=l1+f_sub*b1; b1=b1+f_sub*(mid-l1-FILTER_Q*b1); eng_sub=eng_sub+(b1*b1)
        l2=l2+f_punch*b2; b2=b2+f_punch*(mid-l2-FILTER_Q*b2); eng_punch=eng_punch+(b2*b2)
        l3=l3+f_mud*b3; b3=b3+f_mud*(mid-l3-FILTER_Q*b3); eng_mud=eng_mud+(b3*b3)
        l4=l4+f_boxy*b4; b4=b4+f_boxy*(mid-l4-FILTER_Q*b4); eng_boxy=eng_boxy+(b4*b4)
        l5=l5+f_core*b5; b5=b5+f_core*(mid-l5-FILTER_Q*b5); eng_core=eng_core+(b5*b5)
        l6=l6+f_pres*b6; b6=b6+f_pres*(mid-l6-FILTER_Q*b6); eng_pres=eng_pres+(b6*b6)
        l7=l7+f_harsh*b7; b7=b7+f_harsh*(mid-l7-FILTER_Q*b7); eng_harsh=eng_harsh+(b7*b7)
        l8=l8+f_sib*b8; b8=b8+f_sib*(mid-l8-FILTER_Q*b8); eng_sib=eng_sib+(b8*b8)
        l9=l9+f_air*b9; b9=b9+f_air*(mid-l9-FILTER_Q*b9); eng_air=eng_air+(b9*b9)
        ls=ls+f_sub*bs; bs=bs+f_sub*(side-ls-FILTER_Q*bs); eng_sub_side=eng_sub_side+(bs*bs)
    end

    local true_peak = math.max(peak_left, peak_right)
    local peak_db = (true_peak > 0) and (20 * math.log(true_peak, 10)) or -144
    local rms_db = (sum_sq_mid+sum_sq_side) > 0 and (20 * math.log(math.sqrt((sum_sq_mid+sum_sq_side)/num_samples), 10)) or -144
    local width_pct = (sum_sq_mid+sum_sq_side) > 0 and (math.sqrt(sum_sq_side)/(math.sqrt(sum_sq_mid)+math.sqrt(sum_sq_side)))*100 or 0

    local sub_mono_status = ((eng_sub_side / (eng_sub + eng_sub_side + 0.0001)) * 100 > 12) and "Phase_Risk" or "Safe"
    local total_eng = eng_sub + eng_punch + eng_mud + eng_boxy + eng_core + eng_pres + eng_harsh + eng_sib + eng_air + 0.0001

    return {
        dyn = { peak_db = round(peak_db, 1), rms_db = round(rms_db, 1), crest_db = round(peak_db - rms_db, 1) },
        stereo = { width_pct = round(width_pct, 1), sub_mono = sub_mono_status },
        tonal = {
            sub60 = round((eng_sub / total_eng) * 100, 1),
            punch120 = round((eng_punch / total_eng) * 100, 1),
            mud250 = round((eng_mud / total_eng) * 100, 1),
            boxy500 = round((eng_boxy / total_eng) * 100, 1),
            mid1k = round((eng_core / total_eng) * 100, 1),
            pres3k = round((eng_pres / total_eng) * 100, 1),
            harsh6k = round((eng_harsh / total_eng) * 100, 1),
            sib8k = round((eng_sib / total_eng) * 100, 1),
            air12k = round((eng_air / total_eng) * 100, 1)
        }
    }
end

-- ==============================================================================
-- 8. MULTI-REGION & MULTI-TRACK GHOST RENDER ANALYZER (FIXED)
-- ==============================================================================

local function analyze_ghost_render(regions, duration_pref, tracks_before)
    local tracks_after = reaper.CountTracks(0)
    local num_new_tracks = tracks_after - tracks_before

    if num_new_tracks <= 0 then
        return nil, nil, "Render failed or 'Add rendered items to new tracks' was not checked."
    end

    -- Collect ALL newly created render tracks
    local new_tracks = {}
    for i = tracks_before, tracks_after - 1 do
        table.insert(new_tracks, reaper.GetTrack(0, i))
    end

    local regional_metrics = {}
    local region_counter = 1

    if regions and #regions > 0 then
        for _, region in ipairs(regions) do
            local analyzed = false

            -- Search across all newly rendered tracks and items for this region
            for _, trk in ipairs(new_tracks) do
                for item_idx = 0, reaper.CountTrackMediaItems(trk) - 1 do
                    local media_item = reaper.GetTrackMediaItem(trk, item_idx)
                    local take = media_item and reaper.GetActiveTake(media_item)

                    if take then
                        local item_start = reaper.GetMediaItemInfo_Value(media_item, "D_POSITION")
                        local item_end = item_start + reaper.GetMediaItemInfo_Value(media_item, "D_LENGTH")

                        local overlap_start = math.max(item_start, region.start_s)
                        local overlap_end = math.min(item_end, region.end_s)
                        local overlap_duration = overlap_end - overlap_start

                        if overlap_duration > 0 and not analyzed then
                            local safe_start = overlap_start + math.min(1.0, overlap_duration * 0.1)
                            local analysis_duration = overlap_end - safe_start
                            if duration_pref > 0 then
                                analysis_duration = math.min(duration_pref, analysis_duration)
                            end

                            local clean_name = region.name:gsub("[%s%p]+", "_")
                            local seq_key = string.format("%02d_%s", region_counter, clean_name)

                            local metrics = process_audio_chunk(take, item_start, safe_start, analysis_duration)
                            if metrics then
                                metrics.active_trks = get_active_tracks(overlap_start, overlap_end, tracks_before)
                                regional_metrics[seq_key] = metrics
                                analyzed = true
                                region_counter = region_counter + 1
                            end
                        end
                    end
                end
            end
        end
    end

-- Fallback if no regions exist: analyze first valid item across full timeline
    if not next(regional_metrics) then
        for _, trk in ipairs(new_tracks) do
            if trk then -- Safe dereference check
                local first_item = reaper.GetTrackMediaItem(trk, 0)
                local take = first_item and reaper.GetActiveTake(first_item)

                if take then
                    local pos = reaper.GetMediaItemInfo_Value(first_item, "D_POSITION")
                    local dur = reaper.GetMediaItemInfo_Value(first_item, "D_LENGTH")
                    if duration_pref > 0 then dur = math.min(duration_pref, dur) end

                    local m = process_audio_chunk(take, pos, pos, dur)
                    if m then
                        m.active_trks = get_active_tracks(pos, pos + dur, tracks_before)
                        regional_metrics["01_Entire_Song"] = m
                    end
                    break -- Stop searching once we successfully analyze the first valid take
                end
            end
        end
    end

    -- ULTIMATE SAFETY NET: If metrics are still empty, abort gracefully
    if not next(regional_metrics) then
        return nil, new_tracks, "Analysis failed: No valid audio items were generated by the render. Check your time selection and mix bounds."
    end

    return regional_metrics, new_tracks, nil
end


-- ==============================================================================
-- 9. UNIFIED PROMPT BUILDER & MANDATORY FILE EXPORTER
-- ==============================================================================

local function build_full_prompt(project_yaml, audio_metrics, target_str, user_notes)
    local prompt = "=== MIXING & MASTERING DIRECTIVES ===\nYou are an elite, multi-platinum audio mixing and mastering engineer.\n"
    prompt = prompt .. "Focus Target: " .. target_str .. "\n\n"

    -- UNIFIED INSTRUCTIONS BLOCK (Combined Core Directives + User Notes)
    prompt = prompt .. "=== INSTRUCTIONS FOR ANALYSIS ===\n"

    if user_notes and user_notes ~= "" then
        prompt = prompt .. "[USER CUSTOM INSTRUCTIONS FOR THIS PASS]:\n"
        prompt = prompt .. trim_string(user_notes) .. "\n\n"
    end

    prompt = prompt .. "1. MACRO-DYNAMICS: Compare Crest Factor and RMS across regions. If dynamic contrast is lacking, pinpoint over-compression in the YAML and specify threshold/ratio adjustments.\n"
    prompt = prompt .. "2. LOW/MID FREQUENCY BALANCE: Scrutinize Sub (60Hz), Punch (120Hz), Mud (250Hz), and Boxy (500Hz). Locate masking in the project tracks and suggest surgical EQ cuts.\n"
    prompt = prompt .. "3. HIGH FREQUENCY INTEGRITY: Differentiate Harshness (6kHz) from Sibilance (8kHz). Look for abrasive saturation or identify tracks requiring a De-Esser.\n"
    prompt = prompt .. "4. STEREO & SUB-MONO INTEGRITY: Check 'width_pct' and 'sub_mono'. If 'Phase_Risk' is flagged on sub-bass, immediately identify which low-end tracks have wide side-channel information and advise how to high-pass or mono their sides.\n"
    prompt = prompt .. "5. CONTEXT AWARENESS: Look closely at 'active_trks' for each region. ONLY critique or suggest changes to tracks that are actively playing in that specific region.\n"
    prompt = prompt .. "6. PRECISION: Quote exact track names, plugin names, and parameter settings as formatted in the project YAML.\n\n"

    prompt = prompt .. "=== REGIONAL AUDIO ANALYSIS METRICS ===\n" .. to_yaml(audio_metrics) .. "\n\n"
    prompt = prompt .. "=== REAPER PROJECT CONFIGURATION & FX CHAINS ===\n" .. project_yaml .. "\n"

    return prompt
end

local function save_prompt_to_txt(full_prompt, target_str)
    local path_separator = package.config:sub(1,1) or "/"
    local sanitized_target = target_str:gsub("[%s%p]+", "_")
    local filename_only = "AI_Mix_Prompt_" .. sanitized_target .. ".txt"

    local target_dir = nil
    local _, project_filepath = reaper.EnumProjects(-1, "")

    -- 1. Check if project is saved to disk (.rpp)
    if project_filepath and project_filepath ~= "" then
        target_dir = project_filepath:match("^(.*)[\\/]")
    end

    -- 2. Fallback to default project recording path if valid
    if not target_dir or target_dir == "" then
        local project_path = reaper.GetProjectPath("")
        if project_path and project_path ~= "" then
            target_dir = project_path
        end
    end

    -- 3. Fail-safe for unsaved projects: REAPER Resource Directory
    -- (Always exists and is guaranteed to have user-write permissions)
    if not target_dir or target_dir == "" then
        target_dir = reaper.GetResourcePath()
    end

    -- Ensure proper trailing slash
    if not target_dir:match("[\\/]$") then
        target_dir = target_dir .. path_separator
    end

    local output_filename = target_dir .. filename_only
    local file, err = io.open(output_filename, "w")

    -- Emergency Fallback: If project folder is write-protected (e.g. read-only drive),
    -- redirect file creation to REAPER's user directory
    if not file then
        local fallback_dir = reaper.GetResourcePath() .. path_separator
        output_filename = fallback_dir .. filename_only
        file, err = io.open(output_filename, "w")
    end

    if file then
        file:write(full_prompt)
        file:close()
        return output_filename
    else
        -- Never fail silently: explicitly inform the user of the OS error
        reaper.ShowMessageBox(
            "Failed to save AI prompt text file.\n\nTried path:\n" .. output_filename ..
            "\n\nSystem Error: " .. tostring(err),
            "File Write Error", 0
        )
        return nil
    end
end

local function escape_json_string(str)
    local escape_map = {
        ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"
    }
    return (str:gsub('[\\"\n\r\t]', escape_map))
end

-- Helper to convert Lua chat history table to a JSON array string
local function build_json_messages(messages)
    local json_msgs = {}
    for _, msg in ipairs(messages) do
        local safe_content = escape_json_string(msg.content)
        table.insert(json_msgs, '{"role":"'..msg.role..'","content":"'..safe_content..'"}')
    end
    return "[" .. table.concat(json_msgs, ",") .. "]"
end

-- ==============================================================================
-- LIGHTWEIGHT PURE-LUA JSON DECODER
-- ==============================================================================

local function parse_json(str)
    local pos = 1
    local len = #str

    local function skip_whitespace()
        while pos <= len and str:byte(pos) <= 32 do
            pos = pos + 1
        end
    end

    local parse_value

    local function parse_string()
        pos = pos + 1 -- Skip opening quote
        local chars = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(chars)
            elseif c == '\\' then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if esc == '"' or esc == '\\' or esc == '/' then
                    table.insert(chars, esc)
                elseif esc == 'b' then table.insert(chars, '\b')
                elseif esc == 'f' then table.insert(chars, '\f')
                elseif esc == 'n' then table.insert(chars, '\n')
                elseif esc == 'r' then table.insert(chars, '\r')
                elseif esc == 't' then table.insert(chars, '\t')
                elseif esc == 'u' then
                    local hex = str:sub(pos + 1, pos + 4)
                    local cp = tonumber(hex, 16)
                    if cp then
                        pos = pos + 4
                        -- Convert Unicode code point to UTF-8
                        if cp < 0x80 then
                            table.insert(chars, string.char(cp))
                        elseif cp < 0x800 then
                            table.insert(chars, string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64)))
                        else
                            table.insert(chars, string.char(0xE0 + math.floor(cp / 4096), 0x80 + (math.floor(cp / 64) % 64), 0x80 + (cp % 64)))
                        end
                    end
                else
                    table.insert(chars, esc)
                end
                pos = pos + 1
            else
                table.insert(chars, c)
                pos = pos + 1
            end
        end
        error("Unterminated string in JSON")
    end

    local function parse_number()
        local start_pos = pos

        -- Optional leading sign
        if str:sub(pos, pos) == '-' or str:sub(pos, pos) == '+' then
            pos = pos + 1
        end

        -- Integer part
        while pos <= len and str:sub(pos, pos):match('%d') do
            pos = pos + 1
        end

        -- Fractional part
        if str:sub(pos, pos) == '.' then
            pos = pos + 1
            while pos <= len and str:sub(pos, pos):match('%d') do
                pos = pos + 1
            end
        end

        -- Exponent part
        if str:sub(pos, pos) == 'e' or str:sub(pos, pos) == 'E' then
            local exp_pos = pos
            pos = pos + 1
            if str:sub(pos, pos) == '-' or str:sub(pos, pos) == '+' then
                pos = pos + 1
            end
            while pos <= len and str:sub(pos, pos):match('%d') do
                pos = pos + 1
            end
            if pos == exp_pos + 1 then
                error("Invalid exponent in JSON number at pos " .. exp_pos)
            end
        end

        return tonumber(str:sub(start_pos, pos - 1))
    end

    local function parse_array()
        pos = pos + 1 -- Skip '['
        local arr = {}
        skip_whitespace()
        if str:sub(pos, pos) == ']' then
            pos = pos + 1
            return arr
        end
        while pos <= len do
            table.insert(arr, parse_value())
            skip_whitespace()
            local c = str:sub(pos, pos)
            if c == ']' then
                pos = pos + 1
                return arr
            elseif c == ',' then
                pos = pos + 1
            else
                error("Expected ',' or ']' in array at pos " .. pos)
            end
        end
    end

    local function parse_object()
        pos = pos + 1 -- Skip '{'
        local obj = {}
        skip_whitespace()
        if str:sub(pos, pos) == '}' then
            pos = pos + 1
            return obj
        end
        while pos <= len do
            skip_whitespace()
            if str:sub(pos, pos) ~= '"' then error("Expected string key at pos " .. pos) end
            local key = parse_string()
            skip_whitespace()
            if str:sub(pos, pos) ~= ':' then error("Expected ':' at pos " .. pos) end
            pos = pos + 1
            obj[key] = parse_value()
            skip_whitespace()
            local c = str:sub(pos, pos)
            if c == '}' then
                pos = pos + 1
                return obj
            elseif c == ',' then
                pos = pos + 1
            else
                error("Expected ',' or '}' in object at pos " .. pos)
            end
        end
    end

    function parse_value()
        skip_whitespace()
        local c = str:sub(pos, pos)
        if c == '"' then return parse_string()
        elseif c == '{' then return parse_object()
        elseif c == '[' then return parse_array()
        elseif c:match('[%d%-]') then return parse_number()
        elseif str:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
        elseif str:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
        elseif str:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil
        else error("Unexpected character in JSON: " .. tostring(c)) end
    end

    local ok, res = pcall(function()
        skip_whitespace()
        return parse_value()
    end)
    return ok, res
end

-- ==============================================================================
-- ROBUST CURL RESOLVER & PRE-FLIGHT CHECK
-- ==============================================================================

local cached_curl_cmd = nil

local function command_succeeded(cmd)
    local status = os.execute(cmd)
    if status == true then return true end
    if type(status) == "number" then return status == 0 end
    return status == 0 or status == true
end

local function resolve_curl_binary()
    if cached_curl_cmd then return cached_curl_cmd end

    local os_name = reaper.GetOS()

    -- 1. Windows Path Resolution
    if os_name:match("Win") then
        local windir = os.getenv("WINDIR") or "C:\\Windows"
        local candidates = {
            windir .. "\\System32\\curl.exe",
            windir .. "\\Sysnative\\curl.exe",
            "C:\\Program Files\\Git\\mingw64\\bin\\curl.exe",
            "C:\\Program Files\\Git\\usr\\bin\\curl.exe",
        }

        for _, filepath in ipairs(candidates) do
            if reaper.file_exists(filepath) then
                cached_curl_cmd = '"' .. filepath .. '"'
                return cached_curl_cmd
            end
        end

    -- 2. macOS / Linux Path Resolution
    else
        local unix_candidates = {
            "/usr/bin/curl",
            "/usr/local/bin/curl",
            "/opt/homebrew/bin/curl",
        }

        for _, filepath in ipairs(unix_candidates) do
            if reaper.file_exists(filepath) then
                cached_curl_cmd = filepath
                return cached_curl_cmd
            end
        end
    end

    -- 3. Final safe probe: if curl is not in the known locations, check PATH.
    local probe_cmd = os_name:match("Win") and 'curl.exe --version >nul 2>&1' or 'curl --version >/dev/null 2>&1'
    if command_succeeded(probe_cmd) then
        cached_curl_cmd = "curl"
        return cached_curl_cmd
    end

    cached_curl_cmd = nil
    return nil
end

-- ==============================================================================
-- HARDENED API DISPATCHER
-- ==============================================================================

local function ask_deep_seek(chat_history, model_name)
    local temp_json_path = reaper.GetResourcePath() .. "/temp_ds_request.json"
    local temp_response_path = reaper.GetResourcePath() .. "/temp_ds_response.txt"

    local curl_bin = resolve_curl_binary()
    if not curl_bin then
        return "Network Error: cURL is not installed or not available on this system.\n\nInstall curl.exe or add it to PATH before using the DeepSeek API."
    end

    local selected_model = model_name or "deepseek-v4-pro"
    local msgs_json = build_json_messages(chat_history)

    -- NOTE: "thinking":{"type":"disabled"} is included to prevent expensive output token burning
    local json_payload = '{"model":"' .. selected_model .. '","messages":' .. msgs_json .. ',"thinking":{"type":"disabled"},"temperature":0.1}'

    local json_file = io.open(temp_json_path, "w")
    if not json_file then return "I/O Error: Unable to write request file." end
    json_file:write(json_payload)
    json_file:close()

    local curl_command = curl_bin .. ' -s -X POST https://api.deepseek.com/chat/completions ' ..
                         '-H "Authorization: Bearer ' .. API_KEY .. '" ' ..
                         '-H "Content-Type: application/json" ' ..
                         '-d @"' .. temp_json_path .. '" -o "' .. temp_response_path .. '"'
    os.execute(curl_command)

    local response_file = io.open(temp_response_path, "r")
    if not response_file then
        return "Network Error: API request failed or timed out.\n\n" ..
               "Troubleshooting:\n" ..
               "1. Verify internet connection.\n" ..
               "2. Ensure cURL is installed. If on an older Windows version, install cURL or place curl.exe in C:\\Windows\\System32."
    end
    local raw_response = response_file:read("*a")
    response_file:close()

    os.remove(temp_json_path)
    os.remove(temp_response_path)

    -- Parse response using the full JSON decoder
    local ok, data = parse_json(raw_response)
    if not ok or type(data) ~= "table" then
        return "JSON Parse Error: Invalid API response.\n\nRaw output:\n" .. tostring(raw_response)
    end

    -- Explicitly handle API error structures
    if data.error then
        local err_msg = data.error.message or "Unknown API error"
        local err_type = data.error.type or "API_Error"
        return "DeepSeek API Error (" .. err_type .. "):\n" .. err_msg
    end

    -- Extract message content safely
    if data.choices and data.choices[1] and data.choices[1].message then
        local content = data.choices[1].message.content or "No content returned."

        -- Warn if token budget truncated the answer
        if data.choices[1].finish_reason == "length" then
            content = content .. "\n\n⚠️ [WARNING: Response was truncated by DeepSeek token output limit.]"
        end
        return content
    end

    return "Unexpected API response structure:\n" .. raw_response
end

local user_balance_str = "N/A"

local function fetch_deep_seek_balance()
    if API_KEY == "YOUR_DEEPSEEK_API_KEY" or API_KEY == "" then
        user_balance_str = "No API Key"
        return
    end

    local curl_bin = resolve_curl_binary()
    if not curl_bin then
        user_balance_str = "cURL Missing"
        return
    end

    local temp_resp = reaper.GetResourcePath() .. "/temp_ds_bal.txt"
    local curl_cmd = curl_bin .. ' -s -X GET https://api.deepseek.com/user/balance ' ..
                     '-H "Authorization: Bearer ' .. API_KEY .. '" ' ..
                     '-o "' .. temp_resp .. '"'
    os.execute(curl_cmd)

    local file = io.open(temp_resp, "r")
    if file then
        local raw = file:read("*a")
        file:close()
        os.remove(temp_resp)

        -- Extract total_balance and currency
        local total = raw:match('"total_balance"%s*:%s*"(.-)"')
        local curr  = raw:match('"currency"%s*:%s*"(.-)"') or "USD"

        if total then
            local symbol = (curr == "USD") and "$" or "¥"
            user_balance_str = symbol .. total
        else
            user_balance_str = "Check Failed"
        end
    end
end

-- ==============================================================================
-- 10. UNIFIED CHATBOX & WORKFLOW CONTROLLER
-- ==============================================================================

local function render_markdown_text(ctx, text)
    if not text or text == "" then return end

    for line in text:gmatch("([^\r\n]*)[\r\n]?") do
        if line ~= "" then
            -- Headers (### Title) -> Gold text with separator
            if line:match("^#+%s*(.+)") then
                local header_text = line:match("^#+%s*(.+)")
                reaper.ImGui_Dummy(ctx, 0, 4)
                reaper.ImGui_TextColored(ctx, 0xFFD54FFF, "▶  " .. header_text)
                reaper.ImGui_Separator(ctx)
                reaper.ImGui_Dummy(ctx, 0, 2)

            -- Bullet points (- item or * item)
            elseif line:match("^[%*%-]%s+(.+)") then
                local bullet_text = line:match("^[%*%-]%s+(.+)")
                bullet_text = bullet_text:gsub("%*%*(.-)%*%*", "%1")
                reaper.ImGui_Bullet(ctx)
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_TextWrapped(ctx, bullet_text)

            -- Numbered lists (1. Directive) -> Cyan number
            elseif line:match("^%d+%.%s+(.+)") then
                local num, item_text = line:match("^(%d+%.)%s+(.+)")
                item_text = item_text:gsub("%*%*(.-)%*%*", "%1")
                reaper.ImGui_TextColored(ctx, 0x4FC3F7FF, num)
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_TextWrapped(ctx, item_text)

            -- Regular paragraph text
            else
                local clean_line = line:gsub("%*%*(.-)%*%*", "%1")
                reaper.ImGui_TextWrapped(ctx, clean_line)
            end
        end
    end
end

local chat_history = {}
local chat_input_text = ""
local report_saved_path = nil
local scroll_to_bottom = false

local function run_fresh_scan(target_mode, model_choice, mute_parallels, bypass_master_fx, duration_pref, output_api, custom_notes)
    local target_descriptions = { [1] = "Drums & Bass", [2] = "Instruments", [3] = "Vocals", [4] = "Full Mix" }
    local target_name = target_descriptions[target_mode] or "Full Mix"
    local selected_model = get_model_name(model_choice)

    -- 1. Scan and isolate
    save_and_apply_mix_state(target_mode, mute_parallels, bypass_master_fx)
    local project_yaml, song_regions = extract_full_project_yaml()

    -- 2. Render and analyze
    local tracks_before = reaper.CountTracks(0)
    reaper.Main_OnCommand(42230, 0)
    local audio_metrics, rendered_tracks, dsp_error = analyze_ghost_render(song_regions, duration_pref, tracks_before)

    if rendered_tracks then
        for _, trk in ipairs(rendered_tracks) do reaper.DeleteTrack(trk) end
    end
    restore_mix_state()

    if not audio_metrics then
        reaper.ShowMessageBox(dsp_error or "DSP Processing failed.", "Analysis Error", 0)
        return false
    end

    -- 3. Save raw file
    local full_prompt = build_full_prompt(project_yaml, audio_metrics, target_name, custom_notes)
    report_saved_path = save_prompt_to_txt(full_prompt, target_name)

    -- 4. Initialize chat history for DeepSeek Prompt Caching
    chat_history = {
        { role = "system", content = full_prompt },
        { role = "user", content = "Perform full mix analysis as instructed." }
    }

    if output_api then
        local reply = ask_deep_seek(chat_history, selected_model)
        table.insert(chat_history, { role = "assistant", content = reply })
        scroll_to_bottom = true
        fetch_deep_seek_balance()
    else
        table.insert(chat_history, { role = "assistant", content = "Analysis saved to file:\n" .. (report_saved_path or "") })
        scroll_to_bottom = true
    end

    return true
end

local function send_followup_message(user_text, model_choice)
    if trim_string(user_text) == "" then return end
    local selected_model = get_model_name(model_choice)

    table.insert(chat_history, { role = "user", content = user_text })
    scroll_to_bottom = true

    local reply = ask_deep_seek(chat_history, selected_model)
    table.insert(chat_history, { role = "assistant", content = reply })
    fetch_deep_seek_balance()
    scroll_to_bottom = true
end

local function main()
	-- Query live balance immediately upon launching the script
    fetch_deep_seek_balance()

	local ctx = reaper.ImGui_CreateContext("AI_Mix_Assistant")
    local target_idx = 3
    local model_idx = 0
    local mute_parallels = true
    local bypass_master_fx = true
    local duration_idx = 0
    local output_api = true
    local custom_notes = ""

    local target_items = "Drums & Bass\0Instruments (No Drums/Bass/Vox)\0Vocals\0Full Mix\0\0"
    local model_items = "DeepSeek V4 Pro (Flagship Reasoning)\0DeepSeek Flash (Fast / Low-Cost)\0\0"
    local duration_items = "10 Seconds\0" .. "20 Seconds\0" .. "Full Region\0\0"

    local function loop()
        reaper.ImGui_SetNextWindowSize(ctx, 720, 680, reaper.ImGui_Cond_FirstUseEver())
        local visible, open = reaper.ImGui_Begin(ctx, "Mix and Master Assistant", true, reaper.ImGui_WindowFlags_NoCollapse())

		if visible then
            -- Live Account Balance Bar
            reaper.ImGui_Text(ctx, "Account Balance: ")
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_TextColored(ctx, 0x81C784FF, user_balance_str)
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_SmallButton(ctx, "↻ Refresh") then
                fetch_deep_seek_balance()
            end
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Dummy(ctx, 0, 2)

            -- SCAN SETTINGS PANEL
            if reaper.ImGui_CollapsingHeader(ctx, "Scan Configuration & Controls") then
                _, target_idx = reaper.ImGui_Combo(ctx, "Target", target_idx, target_items)
                _, mute_parallels = reaper.ImGui_Checkbox(ctx, "Mute Parallels", mute_parallels)
                _, bypass_master_fx = reaper.ImGui_Checkbox(ctx, "Bypass Master FX", bypass_master_fx)
                _, duration_idx = reaper.ImGui_Combo(ctx, "Duration", duration_idx, duration_items)
                _, output_api = reaper.ImGui_Checkbox(ctx, "Query DeepSeek API (Uncheck for TXT only)", output_api)
                _, model_idx = reaper.ImGui_Combo(ctx, "AI Model", model_idx, model_items)

                reaper.ImGui_Text(ctx, "Custom Instructions / Notes for Scan:")
                _, custom_notes = reaper.ImGui_InputText(ctx, "##notes", custom_notes)

                if reaper.ImGui_Button(ctx, "Run Fresh Scan & Reset Chat", -1, 30) then
                    run_fresh_scan(target_idx + 1, model_idx + 1, mute_parallels, bypass_master_fx, get_duration_seconds(duration_idx), output_api, custom_notes)
                end
                reaper.ImGui_Separator(ctx)
            end

            -- CHAT HISTORY LOG
            reaper.ImGui_TextColored(ctx, 0xFFD54FFF, "Conversation Log:")
            local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
            local scroll_h = math.max(150, avail_h - 70)

            if reaper.ImGui_BeginChild(ctx, "ChatScroll", 0, scroll_h) then
                for _, msg in ipairs(chat_history) do
                    if msg.role == "user" and msg.content ~= "Perform full mix analysis as instructed." then
                        reaper.ImGui_TextColored(ctx, 0x4FC3F7FF, "YOU: ")
                        reaper.ImGui_SameLine(ctx)
                        reaper.ImGui_TextWrapped(ctx, msg.content)
                        reaper.ImGui_Separator(ctx)
                    elseif msg.role == "assistant" then
                        reaper.ImGui_TextColored(ctx, 0x81C784FF, "DEEPSEEK: ")
                        render_markdown_text(ctx, msg.content)
                        reaper.ImGui_Separator(ctx)
                    end
                end

                -- Auto-scroll down to the latest message
                if scroll_to_bottom then
                    reaper.ImGui_SetScrollHereY(ctx, 1.0)
                    scroll_to_bottom = false
                end

                reaper.ImGui_EndChild(ctx)
            end

			-- FOLLOW-UP INPUT AREA (MULTILINE + BUTTON ONLY)
            reaper.ImGui_Separator(ctx)

            -- Multiline text box: Enter inserts a new line, does not submit
            -- Width: -95px leaves room for the stacked buttons on the right. Height: 52px (approx 2.5 lines)
            _, chat_input_text = reaper.ImGui_InputTextMultiline(ctx, "##chat_in", chat_input_text, -95, 52)

            reaper.ImGui_SameLine(ctx)

            -- Stack the 'Send' and 'Copy Chat' buttons neatly beside the multiline box
            if reaper.ImGui_BeginGroup(ctx) then
                if reaper.ImGui_Button(ctx, "Send", 85, 24) then
                    if trim_string(chat_input_text) ~= "" then
                        local user_msg = chat_input_text
                        chat_input_text = ""
                        send_followup_message(user_msg, model_idx + 1)
                    end
                end

                if reaper.ImGui_Button(ctx, "Copy Chat", 85, 24) then
                    if #chat_history > 0 then
                        reaper.ImGui_SetClipboardText(ctx, chat_history[#chat_history].content)
                    end
                end
                reaper.ImGui_EndGroup(ctx)
            end
        end

        reaper.ImGui_End(ctx)

        if open then
            reaper.defer(loop)
        end
    end

    reaper.defer(loop)
end

-- Start script execution
main()