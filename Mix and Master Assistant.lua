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
local MAX_PLUGIN_PARAMS = 64

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

local function TrimString(str)
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
    param_name = TrimString(param_name):lower()

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
    str = TrimString(str)
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
    name = TrimString(name):lower()
    if name:match("^control %d+$") then return false end
    for _, word in ipairs(IGNORED_PARAMETER_KEYWORDS) do
        if name:find(word) then return false end
    end
    return true
end

local function is_boilerplate(param_name, param_value)
    if not param_name or not param_value then return true end

    local name_lower = TrimString(param_name):lower()
    local val_clean = TrimString(param_value):lower():gsub("%s+", "")

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
    track_name = TrimString(track_name)
    return (not track_name or track_name == "") and ("Track " .. track_idx) or track_name
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
            name = TrimString(name) or ""
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

    for i = 0, num_tracks - 1 do
        local src_track = reaper.GetTrack(0, i)
        local num_sends = reaper.GetTrackNumSends(src_track, 0)

        for s = 0, num_sends - 1 do
            local dest_track = reaper.GetTrackSendInfo_Value(src_track, 0, s, "P_DESTTRACK")
            if dest_track and dest_track ~= 0 then
                local src_name = get_track_identity(src_track)
                local dest_name = "Unknown Track"

                if type(dest_track) == "userdata" then
                    dest_name = get_track_identity(dest_track)
                else
                    for t = 0, num_tracks - 1 do
                        local tr = reaper.GetTrack(0, t)
                        if tr == dest_track then dest_name = get_track_identity(tr); break end
                    end
                end

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
        fx_name = TrimString(fx_name) or "Unknown FX"
        fx_name = fx_name:match(":%s*(.+)") or fx_name
        fx_name = TrimString(fx_name)

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
        raw_name = TrimString(raw_name) or ""
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
                param_name = TrimString(param_name)

                if is_valid_parameter_name(param_name) then
                    local _, param_value = reaper.TrackFX_GetFormattedParamValue(track, i, k)
                    param_value = TrimString(param_value)

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

    local flags = {}
    if reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1 then table.insert(flags, "folder") end
    if reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1 then table.insert(flags, "muted") end
    if reaper.GetMediaTrackInfo_Value(track, "I_SOLO") > 0 then table.insert(flags, "soloed") end
    if reaper.GetMediaTrackInfo_Value(track, "B_PHASE") == 1 then table.insert(flags, "phase_flipped") end
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
                env_name = TrimString(env_name)
                if env_name and env_name ~= "" then table.insert(active_envelopes, env_name) end
            end
        end
        if #active_envelopes > 0 then track_data.auto = table.concat(active_envelopes, ", ") end
    end

    local is_muted = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1
    if not is_muted then track_data.fx = get_track_fx_chain(track) end
    return track_data
end

local function ExtractFullProjectYAML()
    local num, den = reaper.TimeMap_GetTimeSigAtTime(0, 0)
    local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
    local proj_notes = TrimString(reaper.GetSetProjectNotes(0, false, ""))

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

local function GetTrackCategory(name)
    name = name:lower()
    if name:match("nyc") or name:match("rear") or name:match("parallel") or name:match("crush") then return 99 end
    if name:match("drum") or name:match("kick") or name:match("snare") or name:match("bass") or name:match("808") then return 1 end
    if name:match("vox") or name:match("vocal") or name:match("choir") or name:match("lead") then return 3 end
    return 2 -- Instruments default
end

local function SaveAndApplyMixState(target_mode, mute_parallels, bypass_master_fx)
    local master_track = reaper.GetMasterTrack(0)
    saved_mix_state.master_fx = {}

    -- Backup and bypass master FX
    for fx_idx = 0, reaper.TrackFX_GetCount(master_track) - 1 do
        saved_mix_state.master_fx[fx_idx] = reaper.TrackFX_GetEnabled(master_track, fx_idx)
        if bypass_master_fx then reaper.TrackFX_SetEnabled(master_track, fx_idx, false) end
    end

    -- Backup and set track solos/mutes
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        local track_guid = reaper.GetTrackGUID(track)
        local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        local category = GetTrackCategory(track_name)

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

local function RestoreMixState()
    local master_track = reaper.GetMasterTrack(0)
    for fx_idx, state in pairs(saved_mix_state.master_fx) do
        reaper.TrackFX_SetEnabled(master_track, fx_idx, state)
    end
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        local state = saved_mix_state.tracks[reaper.GetTrackGUID(track)]
        if state then
            reaper.SetMediaTrackInfo_Value(track, "I_SOLO", state.solo)
            reaper.SetMediaTrackInfo_Value(track, "B_MUTE", state.mute)
        end
    end
end

-- ==============================================================================
-- 6. ACTIVE TRACK DETECTION (WITH PARENT HIERARCHY MUTE CHECK)
-- ==============================================================================

--- Traverses up the folder hierarchy to verify if any parent track is muted.
local function IsTrackAudible(track)
    local current = track
    while current do
        if reaper.GetMediaTrackInfo_Value(current, "B_MUTE") == 1 then
            return false -- A parent or the track itself is muted
        end
        current = reaper.GetParentTrack(current)
    end
    return true
end

local function GetActiveTracks(start_time, end_time, max_tracks)
    local active_tracks = {}
    -- Only loop through tracks that existed BEFORE the render occurred
    local limit = (max_tracks or reaper.CountTracks(0)) - 1

    for i = 0, limit do
        local track = reaper.GetTrack(0, i)

        if IsTrackAudible(track) then
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

local function ProcessAudioChunk(take, item_pos, analyze_start, analyze_dur)
    local num_samples = math.floor(analyze_dur * SAMPLE_RATE)
    if num_samples < 1 then return nil end

    local buffer = reaper.new_array(num_samples * 2)
    local accessor = reaper.CreateTakeAudioAccessor(take)
    reaper.GetAudioAccessorSamples(accessor, SAMPLE_RATE, 2, analyze_start - item_pos, num_samples, buffer)
    reaper.DestroyAudioAccessor(accessor)

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

    for i = 1, num_samples * 2, 2 do
        local samp_L, samp_R = buffer[i], buffer[i+1]
        if math.abs(samp_L) > peak_left then peak_left = math.abs(samp_L) end
        if math.abs(samp_R) > peak_right then peak_right = math.abs(samp_R) end

        local mid, side = (samp_L + samp_R) * 0.5, (samp_L - samp_R) * 0.5
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

    -- Token optimized output keys for the AI
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

local function AnalyzeGhostRender(regions, duration_pref, tracks_before)
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

                            local metrics = ProcessAudioChunk(take, item_start, safe_start, analysis_duration)
                            if metrics then
                                metrics.active_trks = GetActiveTracks(overlap_start, overlap_end, tracks_before)
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

    -- Fallback if no regions exist: analyze first item across full timeline
    if not next(regional_metrics) then
        local first_item = reaper.GetTrackMediaItem(new_tracks[1], 0)
        local take = first_item and reaper.GetActiveTake(first_item)
        if take then
            local pos = reaper.GetMediaItemInfo_Value(first_item, "D_POSITION")
            local dur = reaper.GetMediaItemInfo_Value(first_item, "D_LENGTH")
            if duration_pref > 0 then dur = math.min(duration_pref, dur) end
            local m = ProcessAudioChunk(take, pos, pos, dur)
            if m then
                m.active_trks = GetActiveTracks(pos, pos + dur, tracks_before)
                regional_metrics["01_Entire_Song"] = m
            end
        end
    end

    return regional_metrics, new_tracks, nil
end


-- ==============================================================================
-- 9. UNIFIED PROMPT BUILDER & MANDATORY FILE EXPORTER
-- ==============================================================================

local function BuildFullPrompt(project_yaml, audio_metrics, target_str, user_notes)
    local prompt = "=== MIXING & MASTERING DIRECTIVES ===\nYou are an elite, multi-platinum audio mixing and mastering engineer.\n"
    prompt = prompt .. "Focus Target: " .. target_str .. "\n\n"

    -- UNIFIED INSTRUCTIONS BLOCK (Combined Core Directives + User Notes)
    prompt = prompt .. "=== INSTRUCTIONS FOR ANALYSIS ===\n"

    if user_notes and user_notes ~= "" then
        prompt = prompt .. "[USER CUSTOM INSTRUCTIONS FOR THIS PASS]:\n"
        prompt = prompt .. trim(user_notes) .. "\n\n"
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

local function SavePromptToTxt(full_prompt, target_str)
    local _, project_filepath = reaper.EnumProjects(-1, "")
    local project_dir = reaper.GetProjectPath("")

    if project_filepath and project_filepath ~= "" then
        local matched_dir = project_filepath:match("^(.*)[\\/]")
        if matched_dir then project_dir = matched_dir end
    end

    local path_separator = package.config:sub(1,1) or "/"
    if not project_dir:match("[\\/]$") then project_dir = project_dir .. path_separator end

    local sanitized_target = target_str:gsub("[%s%p]+", "_")
    local output_filename = project_dir .. "AI_Mix_Prompt_" .. sanitized_target .. ".txt"

    local file = io.open(output_filename, "w")
    if file then
        file:write(full_prompt)
        file:close()
        return output_filename
    end
    return nil
end

local function EscapeJsonString(str)
    local escape_map = {
        ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"
    }
    return (str:gsub('[\\"\n\r\t]', escape_map))
end

local function AskDeepSeek(full_prompt, model_name)
    local temp_json_path = reaper.GetResourcePath() .. "/temp_ds_request.json"
    local temp_response_path = reaper.GetResourcePath() .. "/temp_ds_response.txt"

    local sanitized_prompt = EscapeJsonString(full_prompt)
    local selected_model = model_name or "deepseek-v4-pro"
    local json_payload = '{"model":"' .. selected_model .. '","messages":[{"role":"system","content":"You are a surgical mix engineer."},{"role":"user","content":"' .. sanitized_prompt .. '"}],"thinking":{"type":"disabled"},"temperature":0.1}'

    local json_file = io.open(temp_json_path, "w")
    if not json_file then return "I/O Error: Unable to write request file." end
    json_file:write(json_payload)
    json_file:close()

    local curl_command = 'curl -s -X POST https://api.deepseek.com/chat/completions ' ..
                         '-H "Authorization: Bearer ' .. API_KEY .. '" ' ..
                         '-H "Content-Type: application/json" ' ..
                         '-d @"' .. temp_json_path .. '" -o "' .. temp_response_path .. '"'
    os.execute(curl_command)

    local response_file = io.open(temp_response_path, "r")
    if not response_file then return "Network Error: DeepSeek API request failed/timed out." end
    local raw_response = response_file:read("*a")
    response_file:close()

    os.remove(temp_json_path)
    os.remove(temp_response_path)

    local content_match = raw_response:match('"content"%s*:%s*"(.-)"%s*},?%s*')
    if not content_match then
        content_match = raw_response:match('"content" *: *"(.*)"')
    end

    if content_match then
        content_match = content_match:gsub('"%s*}%s*]%s*}%s*$', '')
        return content_match:gsub('\\n', '\n'):gsub('\\"', '"'):gsub('\\\\', '\\')
    end

    return "Failed to parse API response. Raw response:\n" .. raw_response
end


-- ==============================================================================
-- 10. REAIM-GUI RICH TEXT CONTROLLER & WORKFLOW RUNNER (COMPLETE)
-- ==============================================================================

--- Renders markdown text into styled ReaImGui elements
local function RenderMarkdownText(ctx, text)
    if not text or text == "" then return end

    for line in text:gmatch("([^\r\n]*)[\r\n]?") do
        if line ~= "" then
            -- Headers (### Title) -> Gold text with separator
            if line:match("^#+%s*(.+)") then
                local header_text = line:match("^#+%s*(.+)")
                reaper.ImGui_Dummy(ctx, 0, 6)
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

-- UI State Variables
local current_view = "SETTINGS" -- "SETTINGS" or "REPORT"
local report_ai_text = ""
local report_metrics_yaml = ""
local report_saved_path = nil

local function RunWorkflow(target_mode, model_choice, mute_parallels, bypass_master_fx, duration_pref, output_api, user_notes)
    local target_descriptions = { [1] = "Drums & Bass", [2] = "Instruments", [3] = "Vocals", [4] = "Full Mix" }
    local target_name = target_descriptions[target_mode] or "Full Mix"

    local model_ids = { [1] = "deepseek-v4-pro", [2] = "deepseek-flash" }
    local selected_model = model_ids[model_choice] or "deepseek-v4-pro"

    -- 1. Scan full project hierarchy & routing
    local project_yaml, song_regions = ExtractFullProjectYAML()

    -- 2. Solo target and mute requested busses
    SaveAndApplyMixState(target_mode, mute_parallels, bypass_master_fx)

    -- 3. Run ghost render and 9-band DSP analysis
    local tracks_before = reaper.CountTracks(0)
    reaper.Main_OnCommand(42230, 0)
    local audio_metrics, rendered_tracks, dsp_error = AnalyzeGhostRender(song_regions, duration_pref, tracks_before)

    if rendered_tracks then
        for _, trk in ipairs(rendered_tracks) do reaper.DeleteTrack(trk) end
    end
    RestoreMixState()

    if not audio_metrics then
        reaper.ShowMessageBox(dsp_error or "DSP Processing failed.", "Analysis Error", 0)
        return false
    end

    -- 4. Build prompt package (incorporating user notes at the top)
    local full_prompt = BuildFullPrompt(project_yaml, audio_metrics, target_name, user_notes)
    report_metrics_yaml = to_yaml(audio_metrics)

    -- MANDATORY: Always save to text file
    report_saved_path = SavePromptToTxt(full_prompt, target_name)

    -- Handle API Call depending on checkbox choice
    report_ai_text = ""
    if output_api then
        reaper.ShowConsoleMsg("Transmitting payload to DeepSeek API... (Wait 3-10 seconds)\n")
        report_ai_text = AskDeepSeek(full_prompt, selected_model)
    else
        report_ai_text = "Prompt exported to text file successfully.\n\nFile location:\n" .. (report_saved_path or "")
    end

    return true
end

local function main()
    local ctx = reaper.ImGui_CreateContext("AI_Mix_Assistant")
    local target_idx = 3           -- 0: Drums, 1: Inst, 2: Vox, 3: Full Mix
    local model_idx = 0            -- 0: DeepSeek V4 Pro, 1: DeepSeek Flash
    local mute_parallels = true
    local bypass_master_fx = true
    local duration_idx = 0         -- 0: 10s, 1: 20s, 2: Full
    local output_api = true        -- Checkbox: Call API or just save file
    local user_notes = ""          -- Text buffer for additional instructions

    local target_items = "Drums & Bass\0Instruments\0Vocals\0Full Mix\0\0"
    local model_items  = "DeepSeek V4 Pro (Flagship Reasoning)\0DeepSeek Flash (Fast / Low-Cost)\0\0"
    local duration_items = "10 Seconds\0" .. "20 Seconds\0" .. "Full Region\0\0"

    local function loop()
        local win_w = (current_view == "SETTINGS") and 420 or 700
        local win_h = (current_view == "SETTINGS") and 370 or 580
        reaper.ImGui_SetNextWindowSize(ctx, win_w, win_h, reaper.ImGui_Cond_FirstUseEver())

        local title = (current_view == "SETTINGS") and "AI Mix Assistant v4.6" or "AI Mix Directive Report"
        local visible, open = reaper.ImGui_Begin(ctx, title, true, reaper.ImGui_WindowFlags_NoCollapse())

        if visible then
            if current_view == "SETTINGS" then
                _, target_idx = reaper.ImGui_Combo(ctx, "Target Bus", target_idx, target_items)
                _, model_idx  = reaper.ImGui_Combo(ctx, "AI Model", model_idx, model_items)

                reaper.ImGui_Separator(ctx)

                _, mute_parallels = reaper.ImGui_Checkbox(ctx, "Mute Parallel Busses (NYC/Rear/etc)", mute_parallels)
                _, bypass_master_fx = reaper.ImGui_Checkbox(ctx, "Bypass Master Bus FX Chain", bypass_master_fx)
                _, duration_idx = reaper.ImGui_Combo(ctx, "Duration", duration_idx, duration_items)
                _, output_api = reaper.ImGui_Checkbox(ctx, "Also Call DeepSeek API (Uncheck for TXT Only)", output_api)

                reaper.ImGui_Dummy(ctx, 0, 4)
                reaper.ImGui_Text(ctx, "Additional Instructions / Notes for AI:")
                -- Multiline text input box for custom user notes
                _, user_notes = reaper.ImGui_InputTextMultiline(ctx, "##user_notes", user_notes, -1, 50)

                reaper.ImGui_Dummy(ctx, 0, 6)
                reaper.ImGui_Separator(ctx)
                reaper.ImGui_Dummy(ctx, 0, 4)

                if reaper.ImGui_Button(ctx, "Run Mix Analysis", -1, 32) then
                    local dur_values = { [0] = 10, [1] = 20, [2] = 0 }
                    local success = RunWorkflow(
                        target_idx + 1,
                        model_idx + 1,
                        mute_parallels,
                        bypass_master_fx,
                        dur_values[duration_idx],
                        output_api,
                        user_notes
                    )
                    if success then
                        current_view = "REPORT"
                    end
                end

            elseif current_view == "REPORT" then
                if reaper.ImGui_Button(ctx, "◀ Back to Scan", 120, 26) then
                    current_view = "SETTINGS"
                end

                reaper.ImGui_SameLine(ctx)
                if reaper.ImGui_Button(ctx, "Copy Directives to Clipboard", 200, 26) then
                    reaper.ImGui_SetClipboardText(ctx, report_ai_text)
                end

                if report_saved_path then
                    reaper.ImGui_SameLine(ctx)
                    reaper.ImGui_TextDisabled(ctx, "(Saved to .txt)")
                end

                reaper.ImGui_Dummy(ctx, 0, 4)

                if reaper.ImGui_BeginTabBar(ctx, "ReportTabs") then
                    if reaper.ImGui_BeginTabItem(ctx, "AI Mixing Directives") then
                        if reaper.ImGui_BeginChild(ctx, "DirectivesScroll", 0, 0) then
                            RenderMarkdownText(ctx, report_ai_text)
                            reaper.ImGui_EndChild(ctx)
                        end
                        reaper.ImGui_EndTabItem(ctx)
                    end

                    if reaper.ImGui_BeginTabItem(ctx, "Detected Audio Metrics") then
                        if reaper.ImGui_BeginChild(ctx, "MetricsScroll", 0, 0) then
                            reaper.ImGui_TextColored(ctx, 0x81C784FF, "=== REGIONAL METRICS DETECTED ===")
                            reaper.ImGui_Separator(ctx)
                            reaper.ImGui_Text(ctx, report_metrics_yaml)
                            reaper.ImGui_EndChild(ctx)
                        end
                        reaper.ImGui_EndTabItem(ctx)
                    end

                    reaper.ImGui_EndTabBar(ctx)
                end
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