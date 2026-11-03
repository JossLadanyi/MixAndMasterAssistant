-- ==============================================================================
-- REAPER AI MIX ASSISTANT & SCANNER (v5.6)
-- ==============================================================================
-- Features:
-- 1. Token-Optimized YAML Architecture Scanner (Reduces LLM cost, retains data)
-- 2. Mix State Manager (Target Soloing & Parallel / Master FX Muting)
-- 3. Ghost Render Engine with Auto-Cleanup & Non-Destructive State Restore
-- 4. 9-Band Mastering DSP Engine (accurate biquad band-pass filters) + Sub-Mono (<120Hz) Phase Check
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

-- Environment lookups that never change while the script runs (resolved once)
local IS_WINDOWS = reaper.GetOS():match("Win") ~= nil
local PATH_SEPARATOR = package.config:sub(1, 1) or "/"

-- ==============================================================================
-- 1. GLOBAL CONFIGURATION & TUNING
-- ==============================================================================

-- DeepSeek API Key (Only needed if sending analysis to DeepSeek)
local API_KEY = "YOUR_DEEPSEEK_API_KEY"

-- Maximum plugin parameters to capture per effect (Balances precision vs tokens)
local MAX_PLUGIN_PARAMS = 128

-- DSP Sample Rate
local SAMPLE_RATE = 44100

-- Sub-Mono check: everything below this frequency (24 dB/oct low-pass) must be mono-compatible
local SUB_MONO_CUTOFF_HZ = 120

-- Tonal bands have different widths (see section 7). When true, each band level is reported as the level of a
-- 1-octave-wide band (dBFS), so the narrow 6k/8k/12k bands stay directly comparable with the wider bands below them.
-- Set to false for the raw band-limited RMS level of each band.
local NORMALIZE_BANDS_TO_OCTAVE = true

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

-- Audio Parameter Abbreviations for the YAML output. They are applied in THIS order
-- (a plain Lua dictionary has no stable order, so overlapping words such as
-- "bandwidth"/"width" and "saturation"/"ratio" could be abbreviated differently on every run).
local PARAM_ABBREVIATIONS = {
    { "saturation", "sat" }, { "bandwidth", "bw" }, { "frequency", "freq" }, { "threshold", "thr" },
    { "resonance", "res" }, { "lookahead", "la" }, { "sidechain", "sc" }, { "feedback", "fb" },
    { "highpass", "hp" }, { "lowpass", "lp" }, { "cutoff", "cut" }, { "release", "rel" },
    { "attack", "att" }, { "ratio", "rat" }, { "volume", "vol" }, { "output", "out" },
    { "input", "inp" }, { "level", "lvl" }, { "gain", "gn" }, { "time", "tm" },
    { "mix", "mx" }, { "width", "wdth" }, { "drive", "drv" }, { "slope", "slp" }
}

-- Plugins repeat the same parameter names over and over, so each cleaned key is computed only once
local clean_key_cache = {}

-- This function abbreviates parameter names for the AI payload to save tokens,
-- but the Lua function name and variables remain human-readable.
local function clean_param_key(param_name)
    if not param_name then return "param" end
    local cached = clean_key_cache[param_name]
    if cached then return cached end

    local key = trim_string(param_name):lower()

    for _, pair in ipairs(PARAM_ABBREVIATIONS) do
        key = key:gsub(pair[1], pair[2])
    end

    -- Preserve unit context cleanly
    key = key:gsub("%%", "_pct")
    key = key:gsub("%s*%(%s*hz%s*%)", "_hz"):gsub("%s*%[%s*hz%s*%]", "_hz")
    key = key:gsub("%s*%(%s*db%s*%)", "_db"):gsub("%s*%[%s*db%s*%]", "_db")
    key = key:gsub("%s*%(%s*ms%s*%)", "_ms"):gsub("%s*%[%s*ms%s*%]", "_ms")

    -- Strip special characters
    key = key:gsub("[%[%]%(%)]", "")
    key = key:gsub("[%s%-%/]+", "_")
    key = key:gsub("^_+", ""):gsub("_+$", "")

    if key == "" then key = "param" end
    clean_key_cache[param_name] = key
    return key
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
    return round(20 * math.log(vol, 10), 1)
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

-- ==============================================================================
-- 3. ORIGINAL SERIALIZER ENGINE (COMPACT & RANKED YAML)
-- ==============================================================================

--- Returns (is_array, max_key): a table is an "array" when every key is a number.
local function analyze_table_keys(tbl)
    local max_key = 0
    for k in pairs(tbl) do
        if type(k) ~= "number" then return false, 0 end
        max_key = math.max(max_key, k)
    end
    return true, max_key
end

local function to_inline_yaml(tbl)
    if type(tbl) ~= "table" then
        return type(tbl) == "string" and escape_yaml_string(tbl) or tostring(tbl)
    end

    local parts = {}
    local is_array, max_key = analyze_table_keys(tbl)
    if is_array then
        if max_key == 0 then return "[]" end
        for i = 1, max_key do parts[i] = to_inline_yaml(tbl[i]) end
        return "[" .. table.concat(parts, ", ") .. "]"
    end

    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = tostring(k) .. ": " .. to_inline_yaml(tbl[k])
    end
    return "{" .. table.concat(parts, ", ") .. "}"
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
    if type(tbl) ~= "table" then return "" end
    indent = indent or 0
    local pad = string.rep("  ", indent)
    local out = {} -- collected pieces are joined once at the end (no repeated string re-allocation)

    local is_array, max_key = analyze_table_keys(tbl)
    if is_array then
        for i = 1, max_key do
            local v = tbl[i]
            if INLINE_ARRAY_PARENTS[parent_key] and type(v) == "table" then
                out[#out + 1] = pad .. "- " .. to_inline_yaml(v) .. "\n"
            elseif type(v) == "table" then
                local child = to_yaml(v, indent + 1, parent_key)
                out[#out + 1] = pad .. "- " .. (child:gsub("^%s+", ""))
            else
                out[#out + 1] = pad .. "- " .. (type(v) == "string" and escape_yaml_string(v) or tostring(v)) .. "\n"
            end
        end
    else
        local keys = {}
        for k in pairs(tbl) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            local rank_a = KEY_RANK[a] or 999
            local rank_b = KEY_RANK[b] or 999
            if rank_a ~= rank_b then return rank_a < rank_b end
            return tostring(a) < tostring(b)
        end)

        for _, k in ipairs(keys) do
            local v = tbl[k]
            if INLINE_KEYS[k] and type(v) == "table" then
                out[#out + 1] = pad .. tostring(k) .. ": " .. to_inline_yaml(v) .. "\n"
            elseif type(v) == "table" then
                if next(v) ~= nil then
                    out[#out + 1] = pad .. tostring(k) .. ":\n" .. to_yaml(v, indent + 1, k)
                end
            elseif k == "notes" then
                local block = v:gsub("\r", ""):gsub("\n", "\n" .. pad .. "  ")
                out[#out + 1] = pad .. "additional_information:\n" .. pad .. "  " .. block .. "\n"
            else
                local val_str = type(v) == "string" and escape_yaml_string(v) or tostring(v)
                out[#out + 1] = pad .. tostring(k) .. ": " .. val_str .. "\n"
            end
        end
    end
    return table.concat(out)
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
                start_s = round(pos, 2)
            }
            if is_region then element.end_s = round(region_end, 2) end
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
        local main_send = reaper.GetMediaTrackInfo_Value(src_track, "B_MAINSEND")

        for s = 0, reaper.GetTrackNumSends(src_track, 0) - 1 do
            local dest_track = reaper.GetTrackSendInfo_Value(src_track, 0, s, "P_DESTTRACK")
            if dest_track and dest_track ~= 0 then
                local conn = { src = track_lookup[src_track], dst = track_lookup[dest_track] or "Unknown Track" }

                local dst_chan = math.floor(reaper.GetTrackSendInfo_Value(src_track, 0, s, "I_DSTCHAN"))
                local chan_index = dst_chan & 1023
                local dst_ch_str = string.format("%d/%d", chan_index + 1, chan_index + 2)

                if chan_index >= 2 then
                    conn.purpose = "sidechain"
                elseif main_send == 0 then
                    conn.purpose = "bus_summing"
                elseif main_send == 1 and (type(dest_track) ~= "userdata" or reaper.CountTrackMediaItems(dest_track) == 0) then
                    -- Main send still active and the destination holds no media: a parallel split
                    conn.purpose = "parallel_split"
                end

                local mode_val = math.floor(reaper.GetTrackSendInfo_Value(src_track, 0, s, "I_SENDMODE"))
                if mode_val == 1 then conn.type = "prefx" elseif mode_val == 3 or mode_val == 2 then conn.type = "pre" end
                if dst_ch_str ~= "1/2" then conn.dst_ch = dst_ch_str end

                -- Only record send volume if it is NOT exactly 0.0 dB
                local send_vol = linear_to_db(reaper.GetTrackSendInfo_Value(src_track, 0, s, "D_VOL"))
                if send_vol ~= 0.0 then
                    conn.vol_db = send_vol
                end

                table.insert(connections, conn)
            end
        end
    end
    return #connections > 0 and connections or nil
end

-- Hierarchical module prefixes used to drop the parameters of switched-off EQ bands / modules
local MODULE_PREFIX_PATTERNS = { "^(band_%d+_)", "^(eq_b%d+_)", "^(c%d+_b%d+_)", "^(h%d+_)", "^(b%d+_)" }

--- Extracts the meaningful, non-default parameters of one effect (nil when there are none).
local function extract_fx_params(track, fx_idx)
    local num_params = reaper.TrackFX_GetNumParams(track, fx_idx)
    local max_inspect = 256

    -- Every parameter name is fetched from REAPER ONCE and reused by both passes
    -- (the API round-trip is the expensive part of scanning a big plugin).
    local param_names = {}
    for k = 0, math.min(num_params - 1, max_inspect) do
        local _, param_name = reaper.TrackFX_GetParamName(track, fx_idx, k)
        param_names[k] = param_name
    end

    -- -------------------------------------------------------------
    -- PASS 1: Detect disabled modules using standardized keys
    -- -------------------------------------------------------------
    local disabled_prefixes = {}
    for k = 0, math.min(num_params - 1, max_inspect) do
        local param_name = param_names[k]
        if param_name and param_name ~= "" then
            -- Sanitize first so spaces/colons become underscores (e.g. "band_3_active")
            local clean_k = clean_param_key(param_name)

            if clean_k:find("active") or clean_k:find("enable") or clean_k:find("bypass") then
                local _, param_val = reaper.TrackFX_GetFormattedParamValue(track, fx_idx, k)
                local v_clean = trim_string(param_val):lower():gsub("%s+", "")

                local is_off = (v_clean == "off" or v_clean == "0" or v_clean == "false" or v_clean == "disabled")
                local is_bypassed = (clean_k:find("bypass") and (v_clean == "on" or v_clean == "1" or v_clean == "true"))

                if is_off or is_bypassed then
                    -- Extract hierarchical prefixes reliably:
                    for _, pattern in ipairs(MODULE_PREFIX_PATTERNS) do
                        local prefix = clean_k:match(pattern)
                        if prefix then
                            disabled_prefixes[prefix] = true
                            break
                        end
                    end
                end
            end
        end
    end

    -- -------------------------------------------------------------
    -- PASS 2: Extract active parameters, dropping disabled prefixes
    -- -------------------------------------------------------------
    local params_table = {}
    local count = 0
    for k = 0, math.min(num_params - 1, max_inspect - 1) do
        local param_name = trim_string(param_names[k])

        if is_valid_parameter_name(param_name) then
            local clean_key = clean_param_key(param_name)
            local is_in_disabled_band = false

            -- Check if clean parameter key starts with any disabled prefix
            for prefix in pairs(disabled_prefixes) do
                if clean_key:sub(1, #prefix) == prefix then
                    is_in_disabled_band = true
                    break
                end
            end

            -- Only keep parameters from active bands/modules
            if not is_in_disabled_band then
                local _, param_value = reaper.TrackFX_GetFormattedParamValue(track, fx_idx, k)
                param_value = trim_string(param_value)

                if not is_boilerplate(param_name, param_value) then
                    if count >= MAX_PLUGIN_PARAMS then break end
                    params_table[clean_key] = tonumber(param_value) or param_value
                    count = count + 1
                end
            end
        end
    end
    return next(params_table) ~= nil and params_table or nil
end

local function get_track_fx_chain(track)
    local num_fx = reaper.TrackFX_GetCount(track)
    if num_fx == 0 then return nil end
    local fx_chain = {}
    local inst_idx = reaper.TrackFX_GetInstrument(track) -- the same for every FX slot on this track

    for i = 0, num_fx - 1 do
        local _, raw_name = reaper.TrackFX_GetFXName(track, i)
        local fx_name = trim_string(raw_name) or "Unknown FX"
        fx_name = fx_name:match(":%s*(.+)") or fx_name
        fx_name = fx_name:gsub("%s*%(.*%)$", "")    -- Uses a greedy match %s*%(.*%)$ to safely catch nested parens like "(Universal Audio (UADx))"
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

        raw_name = trim_string(raw_name) or ""
        local plugin_type = ((inst_idx == i) or raw_name:match("^%w+i:")) and "instrument" or "effect"
        if plugin_type ~= DEFAULT_SETTINGS.plugin.type then plugin.type = plugin_type end

        if plugin_type == "effect" and not plugin.bypassed then
            plugin.params = extract_fx_params(track, i)
        end
        table.insert(fx_chain, plugin)
    end
    return #fx_chain > 0 and fx_chain or nil
end

local function process_track_data(track, is_master, current_depth, any_soloed, has_children)
    local track_name = get_track_identity(track)
    local parent = reaper.GetParentTrack(track)
    local parent_name = parent and get_track_identity(parent) or nil

    -- -------------------------------------------------------------------------
    -- SMART OMISSION RULE: If tracks are soloed, strip tracks that do not
    -- contribute audio (not soloed, no children, receives no audio)
    -- -------------------------------------------------------------------------
    if any_soloed and not is_master then
        local is_soloed = reaper.GetMediaTrackInfo_Value(track, "I_SOLO") > 0
        local is_folder = (has_children and has_children[track] == true)
        -- In REAPER, category -1 queries RECEIVES from other tracks
        local receives_audio = reaper.GetTrackNumSends(track, -1) > 0

        local keep_full = is_soloed or is_folder or receives_audio
        if not keep_full then
            local minimal_data = {
                track = track_name,
                flags = { "muted" }
            }
            if parent_name then minimal_data.parent = parent_name end
            return minimal_data
        end
    end
    -- -------------------------------------------------------------------------

    local track_data = { track = track_name }

    if not is_master and current_depth and current_depth > 0 then
        track_data.depth = current_depth
    end

    if parent_name then track_data.parent = parent_name end

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

    local active_envelopes = {}
    for env_idx = 0, reaper.CountTrackEnvelopes(track) - 1 do
        local env = reaper.GetTrackEnvelope(track, env_idx)
        if env then
            local _, env_name = reaper.GetEnvelopeName(env, "")
            env_name = trim_string(env_name)
            if env_name and env_name ~= "" then table.insert(active_envelopes, env_name) end
        end
    end
    if #active_envelopes > 0 then track_data.auto = table.concat(active_envelopes, ", ") end

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

    project_data.notes = "- any routing send volume omitted is at 0.0 dB unity gain."
    if proj_notes and proj_notes ~= "" then project_data.notes = project_data.notes .. '\n' .. proj_notes end

    local any_soloed = reaper.AnyTrackSolo(0)
    local num_tracks = reaper.CountTracks(0)

    -- Pre-calculate parent folders that actually have children
    local has_children = {}
    for i = 0, num_tracks - 1 do
        local p = reaper.GetParentTrack(reaper.GetTrack(0, i))
        if p then has_children[p] = true end
    end

    -- 1. Master Track
    table.insert(project_data.tracks, process_track_data(reaper.GetMasterTrack(0), true, 0, any_soloed, has_children))

    -- 2. Child Tracks & Folders
    local current_depth = 0
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        table.insert(project_data.tracks, process_track_data(track, false, current_depth, any_soloed, has_children))
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

-- Track names repeat constantly (every child of a folder is classified through its parents),
-- so each name is pattern-matched only once.
local track_category_cache = {}

-- Keyword lists for the track-name classifier (plain substring match, checked in this order)
-- 99 = Parallel / Rear / NYC Busses
local PARALLEL_WORDS = { "nyc", "rear", "parallel" }
-- 1 = Drums & Bass (Drums, Percussion, Kicks, Snares, 808s, Basses - excluding Brass, see below)
local DRUM_BASS_WORDS = { "drum", "kick", "snare", "hat", "perc", "cymbal", "808", "sub" }
-- 3 = Vocals (Lead Vox, Harmonies, BGV, Choirs, Acapellas - plurals and "lead/backing vocal" are covered by the short forms)
local VOCAL_WORDS = { "vox", "vocal", "choir", "bgv", "bv", "acap", "harmony", "harmonies" }

local function name_has_any(name, words)
    for _, word in ipairs(words) do
        if name:find(word, 1, true) then return true end
    end
    return false
end

local function get_track_category(name)
    if type(name) ~= "string" then
        name = ""
    else
        name = trim_string(name):lower()
    end

    local category = track_category_cache[name]
    if category then return category end

    if name_has_any(name, PARALLEL_WORDS) then
        category = 99
    elseif name_has_any(name, DRUM_BASS_WORDS) or (name:find("bass", 1, true) and not name:find("brass", 1, true)) then
        category = 1
    elseif name_has_any(name, VOCAL_WORDS) then
        category = 3
    else
        -- 2 = Instruments (Everything else: Guitars, Keys, Synths, Strings, Horns, FX, Pads)
        category = 2
    end

    track_category_cache[name] = category
    return category
end

--- Determines track category by inspecting parent folder hierarchy first.
-- Children inside Drums, Vocals, or Parallel folders inherit their parent's category.
local function get_effective_track_category(track)
    if not track then return 2 end

    -- 1. Check parent folder hierarchy (Parents strictly override children)
    local current_parent = reaper.GetParentTrack(track)
    while current_parent do
        local _, parent_name = reaper.GetSetMediaTrackInfo_String(current_parent, "P_NAME", "", false)
        local parent_cat = get_track_category(parent_name)

        -- If parent folder is explicitly Drums, Vocals, or Parallel, children inherit it
        if parent_cat == 1 or parent_cat == 3 or parent_cat == 99 then
            return parent_cat
        end

        current_parent = reaper.GetParentTrack(current_parent)
    end

    -- 2. Fall back to track's own name if not inside an explicit category folder
    local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    return get_track_category(track_name)
end

local function is_track_hierarchy_muted(track)
    local current = track
    while current do
        if reaper.GetMediaTrackInfo_Value(current, "B_MUTE") == 1 then
            return true
        end
        current = reaper.GetParentTrack(current)
    end
    return false
end

local function set_track_info_delta(track, param, target_val)
    if reaper.GetMediaTrackInfo_Value(track, param) ~= target_val then
        reaper.SetMediaTrackInfo_Value(track, param, target_val)
    end
end

local function save_and_apply_mix_state(target_mode, mute_parallels, bypass_master_fx)
    -- Freeze UI and routing graph updates during mass solo/mute operations
    reaper.PreventUIRefresh(1)

    saved_mix_state = { tracks = {}, master_fx_enabled = 1 }
    local master_track = reaper.GetMasterTrack(0)
    local target_track_names = {}

    -- 1. Atomic Master FX Bypass (Single PDC recalculation)
    if master_track then
        saved_mix_state.master_fx_enabled = reaper.GetMediaTrackInfo_Value(master_track, "I_FXEN")
        if bypass_master_fx and saved_mix_state.master_fx_enabled == 1 then
            reaper.SetMediaTrackInfo_Value(master_track, "I_FXEN", 0)
        end
    end

    -- 2. Delta-checked track isolation
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        if track then
            local track_guid = reaper.GetTrackGUID(track)
            local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)

            local category = get_effective_track_category(track)
            local display_name = (trim_string(track_name) ~= "") and trim_string(track_name) or ("Track " .. (i + 1))

            local orig_solo = reaper.GetMediaTrackInfo_Value(track, "I_SOLO")
            local orig_mute = reaper.GetMediaTrackInfo_Value(track, "B_MUTE")

            saved_mix_state.tracks[track_guid] = { solo = orig_solo, mute = orig_mute }

            -- FIX: Check that the track is NOT muted (or inside a muted folder hierarchy) before targeting/soloing it
            local is_muted = is_track_hierarchy_muted(track)

            -- Mode 4 (Full Mix) targets nothing: every solo is cleared and the whole project renders
            local is_target = false
            if target_mode == 5 then
                is_target = (orig_solo > 0) and not is_muted
            elseif target_mode ~= 4 then
                is_target = (category == target_mode) and not is_muted
            end

            set_track_info_delta(track, "I_SOLO", is_target and 1 or 0)
            if is_target then table.insert(target_track_names, display_name) end

            if mute_parallels and category == 99 then
                set_track_info_delta(track, "B_MUTE", 1)
            end
        end
    end

    -- Unfreeze and commit audio routing changes all at once
    reaper.PreventUIRefresh(-1)
    reaper.TrackList_AdjustWindows(false)
    return target_track_names
end

local function restore_mix_state()
    -- Freeze UI and routing graph updates during mass restoration
    reaper.PreventUIRefresh(1)

    -- 1. Restore Master FX in one atomic call
    local master_track = reaper.GetMasterTrack(0)
    if master_track and saved_mix_state and saved_mix_state.master_fx_enabled ~= nil then
        set_track_info_delta(master_track, "I_FXEN", saved_mix_state.master_fx_enabled)
    end

    -- 2. Restore only modified tracks
    if saved_mix_state and saved_mix_state.tracks then
        for i = 0, reaper.CountTracks(0) - 1 do
            local track = reaper.GetTrack(0, i)
            if track then
                local state = saved_mix_state.tracks[reaper.GetTrackGUID(track)]
                if state then
                    set_track_info_delta(track, "I_SOLO", state.solo)
                    set_track_info_delta(track, "B_MUTE", state.mute)
                end
            end
        end
    end

    -- Unfreeze and commit audio routing changes all at once
    reaper.PreventUIRefresh(-1)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
end

-- ==============================================================================
-- 6. ACTIVE TRACK DETECTION (WITH PARENT HIERARCHY MUTE CHECK)
-- ==============================================================================

--- Traverses up folder hierarchy to verify track is audible (checks both Mutes and Solos).
-- `any_solo` may be passed in so the project is only queried once per scan.
local function is_track_audible(track, any_solo)
    local current = track
    while current do
        if reaper.GetMediaTrackInfo_Value(current, "B_MUTE") == 1 then
            return false -- A parent or the track itself is muted
        end
        current = reaper.GetParentTrack(current)
    end

    -- If any track is soloed in REAPER, this track must be soloed (or under a soloed folder) to be audible
    if any_solo == nil then any_solo = reaper.AnyTrackSolo(0) end
    if any_solo then
        current = track
        while current do
            if reaper.GetMediaTrackInfo_Value(current, "I_SOLO") > 0 then return true end
            current = reaper.GetParentTrack(current)
        end
        return false
    end

    return true
end

--- Reads every audible track and its un-muted item time ranges from REAPER ONCE per scan.
-- Each region query afterwards is a cheap in-memory overlap test instead of walking
-- every track, folder and item through the REAPER API again for every region.
-- Only tracks that existed BEFORE the render are indexed (max_tracks).
local function build_active_track_index(max_tracks)
    local index = {}
    local any_solo = reaper.AnyTrackSolo(0)

    for i = 0, (max_tracks or reaper.CountTracks(0)) - 1 do
        local track = reaper.GetTrack(0, i)

        if is_track_audible(track, any_solo) then
            local items = {}
            for j = 0, reaper.CountTrackMediaItems(track) - 1 do
                local item = reaper.GetTrackMediaItem(track, j)
                if reaper.GetMediaItemInfo_Value(item, "B_MUTE") ~= 1 then
                    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                    table.insert(items, { pos, pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH") })
                end
            end

            if #items > 0 then
                local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
                table.insert(index, { name = name ~= "" and name or ("Track_" .. (i + 1)), items = items })
            end
        end
    end

    return index
end

local function get_active_tracks(track_index, start_time, end_time)
    local active_tracks = {}

    -- Threshold: Must play for at least 10% of the section (minimum 2.0 seconds)
    local MIN_OVERLAP_SECONDS = math.max(2.0, (end_time - start_time) * 0.10)

    for _, entry in ipairs(track_index) do
        for _, item_range in ipairs(entry.items) do
            -- Calculate actual overlap duration between item and section
            local overlap = math.min(item_range[2], end_time) - math.max(item_range[1], start_time)
            if overlap > MIN_OVERLAP_SECONDS then
                table.insert(active_tracks, entry.name)
                break
            end
        end
    end

    return active_tracks
end

-- ==============================================================================
-- 7. 9-BAND MASTERING DSP ENGINE
-- ==============================================================================

-- Centre frequencies (Hz) and result keys of the 9 critical bands:
-- sub (60), punch (120), mud (250), boxy (500), core (1k), presence (3k), harsh (6k), sibilance (8k), air (12k)
local BAND_FREQS = { 60, 120, 250, 500, 1000, 3000, 6000, 8000, 12000 }
local BAND_KEYS  = { "sub60", "punch120", "mud250", "boxy500", "mid1k", "pres3k", "harsh6k", "sib8k", "air12k" }

local function sinh(x) return (math.exp(x) - math.exp(-x)) / 2 end

-- Band widths are derived once from the centre frequencies: each band is exactly as wide (in octaves) as its
-- CLOSEST neighbour allows, so neighbouring bands touch at their edges but never overlap.
-- (60..1k come out 1 octave wide, 6k and 8k ~0.4 octave, 12k ~0.6 octave.)
local BAND_Q, BAND_OFFSET_DB = {}, {}
for b, freq in ipairs(BAND_FREQS) do
    local lower_gap = BAND_FREQS[b - 1] and math.log(freq / BAND_FREQS[b - 1], 2)
    local upper_gap = BAND_FREQS[b + 1] and math.log(BAND_FREQS[b + 1] / freq, 2)
    local width_octaves = math.min(lower_gap or upper_gap, upper_gap or lower_gap)

    BAND_Q[b] = 1 / (2 * sinh(math.log(2) / 2 * width_octaves)) -- bandwidth in octaves -> filter Q
    BAND_OFFSET_DB[b] = NORMALIZE_BANDS_TO_OCTAVE and (-10 * math.log(width_octaves, 10)) or 0
end

-- Audio is streamed through the analyzer in 1-second blocks instead of one giant buffer,
-- so memory stays flat even for "Full Region" scans (a 3-minute song used to need ~16 million Lua numbers at once).
local DSP_BLOCK_FRAMES = SAMPLE_RATE

-- ------------------------------------------------------------------------------
-- Biquad filters (RBJ cookbook, bilinear transform). Unlike the old Chamberlin state-variable filter
-- these keep their exact centre frequency and gain right up to the top bands at 44.1 kHz.
-- ------------------------------------------------------------------------------

--- Band-pass with 0 dB gain at the centre frequency (so band energy is the true energy inside the band).
local function design_bandpass(freq, q)
    local w0 = 2 * math.pi * freq / SAMPLE_RATE
    local alpha = math.sin(w0) / (2 * q)
    local a0 = 1 + alpha
    return { b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * math.cos(w0) / a0, a2 = (1 - alpha) / a0, z1 = 0, z2 = 0, energy = 0 }
end

--- 4th-order Linkwitz-Riley low-pass (24 dB/oct, -6 dB at the cutoff): two identical 2nd-order Butterworth
--- stages in series. One set of coefficients, two sets of filter memory (z1/z2 = stage 1, z3/z4 = stage 2).
local function design_lowpass4(freq)
    local w0 = 2 * math.pi * freq / SAMPLE_RATE
    local cos_w0 = math.cos(w0)
    local alpha = math.sin(w0) / (2 * 0.70710678)
    local a0 = 1 + alpha
    local b = (1 - cos_w0) / a0
    return { b0 = b / 2, b1 = b, b2 = b / 2, a1 = -2 * cos_w0 / a0, a2 = (1 - alpha) / a0, z1 = 0, z2 = 0, z3 = 0, z4 = 0 }
end

--- Runs a band-pass biquad over input[1..n]; the filter state carries from block to block and the output energy keeps accumulating.
local function run_bandpass(input, n, filter)
    local b0, b2, a1, a2 = filter.b0, filter.b2, filter.a1, filter.a2
    local z1, z2, energy = filter.z1, filter.z2, filter.energy
    for i = 1, n do
        local x = input[i]
        local y = b0 * x + z1       -- transposed direct form II (b1 is 0 for a band-pass)
        z1 = z2 - a1 * y
        z2 = b2 * x - a2 * y
        energy = energy + y * y
    end
    filter.z1, filter.z2, filter.energy = z1, z2, energy
end

--- Runs the 4th-order low-pass over input[1..n] and stores the result in output (input and output may be the same table).
local function run_lowpass4(input, output, n, filter)
    local b0, b1, b2, a1, a2 = filter.b0, filter.b1, filter.b2, filter.a1, filter.a2
    local z1, z2, z3, z4 = filter.z1, filter.z2, filter.z3, filter.z4
    for i = 1, n do
        local x = input[i]
        local y = b0 * x + z1       -- stage 1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        local out = b0 * y + z3     -- stage 2 (same coefficients)
        z3 = b1 * y - a1 * out + z4
        z4 = b2 * y - a2 * out
        output[i] = out
    end
    filter.z1, filter.z2, filter.z3, filter.z4 = z1, z2, z3, z4
end

-- Helper to convert any raw band energy accumulation into absolute dBFS (offset_db = optional octave normalization)
local function convert_energy_to_db(energy_sum, num_samples, offset_db)
    local band_rms = math.sqrt(energy_sum / num_samples)
    if band_rms <= 1e-7 then return -144.0 end
    return round(20 * math.log(band_rms, 10) + (offset_db or 0), 1)
end

local dsp_debug = {} -- test-only: values the YAML metrics do not carry

local function process_audio_chunk(take, item_pos, analyze_start, analyze_dur)
    local num_samples = math.floor(analyze_dur * SAMPLE_RATE)
    if num_samples < 1 then return nil end

    local block_frames = math.min(num_samples, DSP_BLOCK_FRAMES)
    local buffer = reaper.new_array(block_frames * 2)
    if not buffer then return nil end

    local accessor = reaper.CreateTakeAudioAccessor(take)
    if not accessor then return nil end

    local peak_left, peak_right = 0, 0
    local sum_squared_mid, sum_squared_side = 0, 0

    -- Full-Spectrum Phase Correlation Accumulators: sum(L*R), sum(L^2), sum(R^2)
    local sum_full_LR, sum_full_LL, sum_full_RR = 0, 0, 0
    -- Same accumulators for the sub-bass region (below SUB_MONO_CUTOFF_HZ)
    local sum_sub_LR, sum_sub_LL, sum_sub_RR = 0, 0, 0

    -- One band-pass filter per band (applied to the Mid channel)
    local bands = {}
    for b, freq in ipairs(BAND_FREQS) do bands[b] = design_bandpass(freq, BAND_Q[b]) end

    -- Sub-Mono low-pass (24 dB/oct), one for the Mid and one for the Side channel
    local sub_mid_lp = design_lowpass4(SUB_MONO_CUTOFF_HZ)
    local sub_side_lp = design_lowpass4(SUB_MONO_CUTOFF_HZ)

    -- Per-block work arrays (allocated once, reused for every block)
    local mid, side, sub_mid, sub_side = {}, {}, {}, {}

    local frames_done = 0
    while frames_done < num_samples do
        local n = math.min(block_frames, num_samples - frames_done)

        buffer.clear() -- a block without audio must read as silence, never as the previous block's samples
        local ok = reaper.GetAudioAccessorSamples(accessor, SAMPLE_RATE, 2, analyze_start - item_pos + frames_done / SAMPLE_RATE, n, buffer)
        if not ok then break end

        -- Convert C++ buffer to a native 1-based Lua table
        local audio_samples = buffer
        if type(buffer) == "userdata" and buffer.table then
            audio_samples = buffer.table()
        end
        if type(audio_samples) ~= "table" then break end

        -- Fast native table loop (audio_samples[1] = L0, audio_samples[2] = R0, ...)
        for i = 1, n do
            local sample_left = audio_samples[2 * i - 1]
            local sample_right = audio_samples[2 * i]

            if sample_left > peak_left then peak_left = sample_left elseif -sample_left > peak_left then peak_left = -sample_left end
            if sample_right > peak_right then peak_right = sample_right elseif -sample_right > peak_right then peak_right = -sample_right end

            -- Accumulate full-spectrum stereo cross-correlation metrics
            sum_full_LR = sum_full_LR + (sample_left * sample_right)
            sum_full_LL = sum_full_LL + (sample_left * sample_left)
            sum_full_RR = sum_full_RR + (sample_right * sample_right)

            local m = (sample_left + sample_right) * 0.5
            local s = (sample_left - sample_right) * 0.5
            mid[i], side[i] = m, s

            sum_squared_mid = sum_squared_mid + (m * m)
            sum_squared_side = sum_squared_side + (s * s)
        end

        -- Band-pass filters on the Mid channel (one tight loop per band keeps the filter state in registers)
        for b = 1, #bands do
            run_bandpass(mid, n, bands[b])
        end

        -- Sub-bass low-pass on Mid and Side (linear, so L/R can be rebuilt afterwards) for the mono compatibility check
        run_lowpass4(mid, sub_mid, n, sub_mid_lp)
        run_lowpass4(side, sub_side, n, sub_side_lp)

        -- Accumulate cross-channel correlation of the sub-bass region
        for i = 1, n do
            local sub_L = sub_mid[i] + sub_side[i]
            local sub_R = sub_mid[i] - sub_side[i]
            sum_sub_LR = sum_sub_LR + (sub_L * sub_R)
            sum_sub_LL = sum_sub_LL + (sub_L * sub_L)
            sum_sub_RR = sum_sub_RR + (sub_R * sub_R)
        end

        frames_done = frames_done + n
    end
    reaper.DestroyAudioAccessor(accessor)

    if frames_done < num_samples then return nil end -- the accessor failed part-way through

    local true_peak = math.max(peak_left, peak_right)
    local peak_db = (true_peak > 0) and (20 * math.log(true_peak, 10)) or -144
    local rms_db = (sum_squared_mid + sum_squared_side) > 0 and (20 * math.log(math.sqrt((sum_squared_mid + sum_squared_side) / num_samples), 10)) or -144
    local crest_factor = peak_db - rms_db

    local rms_mid = math.sqrt(sum_squared_mid / num_samples)
    local rms_side = math.sqrt(sum_squared_side / num_samples)
    local width_pct = 0
    if (rms_mid + rms_side) > 0 then
        width_pct = (rms_side / (rms_mid + rms_side)) * 100
    end

    -- Feature #1: Full-Spectrum Phase Correlation calculation (-1.0 to +1.0)
    local full_denom = math.sqrt(sum_full_LL * sum_full_RR)
    local phase_corr = full_denom > 0 and (sum_full_LR / full_denom) or 1.0

    local denom = math.sqrt(sum_sub_LL * sum_sub_RR)
    local correlation = denom > 0 and (sum_sub_LR / denom) or 1.0
    dsp_debug.sub_corr = correlation

    -- Only flag if there is actual bass AND phase correlation drops below 0 (canceling out)
    local sub_mono_status = "Safe"
    if convert_energy_to_db((sum_sub_LL + sum_sub_RR) / 2, num_samples) > -50.0 and correlation < 0.0 then
        sub_mono_status = "Phase_Risk"
    end

    local tonal_db = {}
    for b, key in ipairs(BAND_KEYS) do
        tonal_db[key] = convert_energy_to_db(bands[b].energy, num_samples, BAND_OFFSET_DB[b])
    end

    return {
        dyn = { peak_db = round(peak_db, 1), rms_db = round(rms_db, 1), crest_db = round(crest_factor, 1) },
        stereo = { width_pct = round(width_pct, 1), sub_mono = sub_mono_status, phase_corr = round(phase_corr, 2) },
        tonal_db = tonal_db
    }
end

-- ==============================================================================
-- 8. MULTI-REGION & MULTI-TRACK GHOST RENDER ANALYZER (FIXED)
-- ==============================================================================

local function has_rendered_media_item(media_item)
    if not media_item then return false end
    local item_len = reaper.GetMediaItemInfo_Value(media_item, "D_LENGTH")
    return item_len ~= nil and item_len > 0
end

--- Analyzes the first rendered item that overlaps the region.
-- Returns the metrics plus the overlap window, or nil when nothing could be analyzed.
local function analyze_region(render_tracks, region, duration_pref)
    for _, trk in ipairs(render_tracks) do
        for item_idx = 0, reaper.CountTrackMediaItems(trk) - 1 do
            local media_item = reaper.GetTrackMediaItem(trk, item_idx)
            local take = media_item and reaper.GetActiveTake(media_item)

            if take then
                local item_start = reaper.GetMediaItemInfo_Value(media_item, "D_POSITION")
                local item_end = item_start + reaper.GetMediaItemInfo_Value(media_item, "D_LENGTH")

                local overlap_start = math.max(item_start, region.start_s)
                local overlap_end = math.min(item_end, region.end_s)
                local overlap_duration = overlap_end - overlap_start

                if overlap_duration > 0 then
                    local safe_start = overlap_start + math.min(1.0, overlap_duration * 0.1)
                    local analysis_duration = overlap_end - safe_start
                    if duration_pref > 0 then
                        analysis_duration = math.min(duration_pref, analysis_duration)
                    end

                    local metrics = process_audio_chunk(take, item_start, safe_start, analysis_duration)
                    if metrics then return metrics, overlap_start, overlap_end end
                end
            end
        end
    end
    return nil
end

local function analyze_ghost_render(regions, duration_pref, tracks_before, pre_render_guids)
    local tracks_after = reaper.CountTracks(0)

    -- Build a real identity set of tracks created by the render by comparing GUIDs before
    -- and after. This is more reliable than assuming track count/index range alone.
    local existing_guids = pre_render_guids or {}
    if not pre_render_guids then
        for i = 0, tracks_before - 1 do
            local trk = reaper.GetTrack(0, i)
            if trk then existing_guids[reaper.GetTrackGUID(trk)] = true end
        end
    end

    local render_tracks = {}
    local seen_render_guids = {}
    for i = 0, tracks_after - 1 do
        local trk = reaper.GetTrack(0, i)
        if trk then
            local guid = reaper.GetTrackGUID(trk)
            if not existing_guids[guid] and not seen_render_guids[guid] then
                seen_render_guids[guid] = true
                for item_idx = 0, reaper.CountTrackMediaItems(trk) - 1 do
                    if has_rendered_media_item(reaper.GetTrackMediaItem(trk, item_idx)) then
                        table.insert(render_tracks, trk)
                        break
                    end
                end
            end
        end
    end

    if #render_tracks == 0 then
        return nil, nil, "CANCELLED"
    end

    -- One pass over the original tracks answers "who is playing?" for every region below
    local track_index = build_active_track_index(tracks_before)

    local regional_metrics = {}
    local region_counter = 1

    for _, region in ipairs(regions or {}) do
        -- Markers have no end time, only regions can be analyzed as a section
        if region.end_s then
            local metrics, overlap_start, overlap_end = analyze_region(render_tracks, region, duration_pref)
            if metrics then
                local clean_name = region.name:gsub("[%s%p]+", "_")
                local seq_key = string.format("%02d_%s", region_counter, clean_name)
                metrics.active_trks = get_active_tracks(track_index, overlap_start, overlap_end)
                regional_metrics[seq_key] = metrics
                region_counter = region_counter + 1
            end
        end
    end

    -- Fallback if no regions exist: analyze the first valid audio item across the whole timeline.
    if not next(regional_metrics) then
        for _, trk in ipairs(render_tracks) do
            local first_item = reaper.GetTrackMediaItem(trk, 0)
            local take = first_item and reaper.GetActiveTake(first_item)

            if take then
                local pos = reaper.GetMediaItemInfo_Value(first_item, "D_POSITION")
                local dur = reaper.GetMediaItemInfo_Value(first_item, "D_LENGTH")
                if duration_pref > 0 then dur = math.min(duration_pref, dur) end

                local m = process_audio_chunk(take, pos, pos, dur)
                if m then
                    m.active_trks = get_active_tracks(track_index, pos, pos + dur)
                    regional_metrics["01_Entire_Song"] = m
                    break
                end
            end
        end
    end

    if not next(regional_metrics) then
        return nil, render_tracks, "Render created temporary tracks, but no valid audio items were generated. Check your time selection, mix bounds, and whether 'Render > Add rendered items to new tracks' is enabled."
    end

    return regional_metrics, render_tracks, nil
end

-- ==============================================================================
-- 9. UNIFIED PROMPT BUILDER & MANDATORY FILE EXPORTER
-- ==============================================================================

local function build_full_prompt(project_yaml, audio_metrics, target_str, target_tracks)
    local prompt = { "=== MIXING & MASTERING DIRECTIVES ===\nYou are an elite, multi-platinum audio mixing and mastering engineer.\n" }
    prompt[#prompt + 1] = "Focus Target: " .. target_str .. "\n\n"

    prompt[#prompt + 1] = "=== TARGET TRACKS ===\n"
    if target_tracks and #target_tracks > 0 then
        prompt[#prompt + 1] = "The following tracks are currently active for this specific analysis:\n"
        prompt[#prompt + 1] = table.concat(target_tracks, ", ") .. "\n\n"
        prompt[#prompt + 1] = "CRITICAL RESTRICTION: Focus YOUR ENTIRE ANALYSIS and plugin recommendations SOLELY on these specific tracks, plus the Master Bus if relevant. Do not critique or suggest parameter changes for any tracks outside this list.\n\n"
    else
        prompt[#prompt + 1] = "All active tracks are included in this full mix analysis.\n\n"
    end

    -- UNIFIED INSTRUCTIONS BLOCK
    prompt[#prompt + 1] = "=== INSTRUCTIONS FOR ANALYSIS ===\n"
    prompt[#prompt + 1] = "1. MACRO-DYNAMICS: Compare Crest Factor and RMS across regions. If dynamic contrast is lacking, pinpoint over-compression in the YAML and specify threshold/ratio adjustments.\n"
    prompt[#prompt + 1] = "2. LOW/MID FREQUENCY BALANCE: Scrutinize Sub (60Hz), Punch (120Hz), Mud (250Hz), and Boxy (500Hz). Locate masking in the project tracks and suggest surgical EQ cuts.\n"
    prompt[#prompt + 1] = "3. HIGH FREQUENCY INTEGRITY: Differentiate Harshness (6kHz) from Sibilance (8kHz). Look for abrasive saturation or identify tracks requiring a De-Esser.\n"
    prompt[#prompt + 1] = "4. STEREO & SUB-MONO INTEGRITY: Check 'width_pct', 'phase_corr', and 'sub_mono'. 'phase_corr' is full-spectrum phase correlation (-1.0 to +1.0). If 'phase_corr' is low (< 0.5) or 'Phase_Risk' is flagged on sub-bass, identify phase issues across wide stereo elements or plugins and advise how to fix them.\n"
    prompt[#prompt + 1] = "Be precise: Quote exact track names, plugin names, and parameter settings as formatted in the project YAML.\n"
    prompt[#prompt + 1] = "Look closely at 'active_trks' for each region. ONLY critique or suggest changes to tracks that are actively playing in that specific region.\n"
    prompt[#prompt + 1] = "When suggesting dynamic EQ or compressor settings do not suggest threshold, always suggest gain reduction that we should achieve.\n"
    prompt[#prompt + 1] = "Be totally honest and give as much information as possible to educate me but also be short.\n\n"

    prompt[#prompt + 1] = "=== REGIONAL AUDIO ANALYSIS METRICS ===\n" .. to_yaml(audio_metrics) .. "\n\n"
    prompt[#prompt + 1] = "=== REAPER PROJECT CONFIGURATION & FX CHAINS ===\n" .. project_yaml .. "\n"

    return table.concat(prompt)
end

--- Returns the first "<dir><base>.txt" / "<dir><base>_01.txt" ... that does not exist yet (never overwrites).
local function find_free_filename(dir, base_filename)
    local path = dir .. base_filename .. ".txt"
    local counter = 1
    while reaper.file_exists(path) do
        path = dir .. base_filename .. string.format("_%02d", counter) .. ".txt"
        counter = counter + 1
    end
    return path
end

local function save_prompt_to_txt(full_prompt, target_str)
    local sanitized_target = target_str:gsub("[%s%p]+", "_")
    local base_filename = "AI_Mix_Prompt_" .. sanitized_target

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
    if not target_dir or target_dir == "" then
        target_dir = reaper.GetResourcePath()
    end

    -- Ensure proper trailing slash
    if not target_dir:match("[\\/]$") then
        target_dir = target_dir .. PATH_SEPARATOR
    end

    -- 4. Auto-Numbering Logic (Prevents overwriting existing files)
    local output_filename = find_free_filename(target_dir, base_filename)
    local file, err = io.open(output_filename, "w")

    -- Emergency Fallback: If project folder is write-protected, redirect to REAPER's resource folder
    if not file then
        output_filename = find_free_filename(reaper.GetResourcePath() .. PATH_SEPARATOR, base_filename)
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

-- ------------------------------------------------------------------------------
-- RESULT TABLES: one column definition drives BOTH the chat (Markdown) table and the HTML report
-- ------------------------------------------------------------------------------

local TABLE_TITLES = { "1. Macro-Dynamics & Stereo Summary", NORMALIZE_BANDS_TO_OCTAVE and "2. Tonal Balance Summary (dBFS, octave-normalized)" or "2. Tonal Balance Summary (dBFS)" }

-- label = chat header, html = report header, fmt = number format, get(m, html) = cell value
local DYNAMICS_COLUMNS = {
    { label = "Peak",       html = "Peak (dB)",   fmt = "%.1f",  get = function(m) return m.dyn.peak_db end },
    { label = "RMS",        html = "RMS (dB)",    fmt = "%.1f",  get = function(m) return m.dyn.rms_db end },
    { label = "Crest",      html = "Crest (dB)",  fmt = "%.1f",  get = function(m) return m.dyn.crest_db end },
    { label = "Width",      html = "Width (%)",   fmt = "%.0f%%", get = function(m) return m.stereo.width_pct end },
    { label = "Phase Corr", html = "Phase Corr",  fmt = "%.2f",  get = function(m) return m.stereo.phase_corr or 1.0 end },
    { label = "Sub-Mono",   html = "Sub-Mono",    fmt = "%s",    get = function(m, html)
        if m.stereo.sub_mono == "Phase_Risk" then
            return html and "<span class='risk'>Risk</span>" or "Risk"
        end
        return html and "<span class='safe'>Safe</span>" or "Safe"
    end },
}

local TONAL_COLUMNS = {}
do
    local tonal_labels = { "Sub", "Punch", "Mud", "Boxy", "Core", "Pres", "Harsh", "Sib", "Air" }
    local tonal_html   = { "Sub (60Hz)", "Punch (120Hz)", "Mud (250Hz)", "Boxy (500Hz)", "Core (1kHz)", "Pres (3kHz)", "Harsh (6kHz)", "Sib (8kHz)", "Air (12kHz)" }
    for b, key in ipairs(BAND_KEYS) do
        TONAL_COLUMNS[b] = { label = tonal_labels[b], html = tonal_html[b], fmt = "%.1f", get = function(m) return m.tonal_db[key] end }
    end
end

--- Region keys ("01_Verse_1", "02_Chorus", ...) in playing order.
local function get_sorted_regions(audio_metrics)
    local sorted_regions = {}
    for r_key in pairs(audio_metrics) do table.insert(sorted_regions, r_key) end
    table.sort(sorted_regions)
    return sorted_regions
end

--- "01_Verse_1" -> "Verse 1"
local function get_region_display_name(r_key)
    return (r_key:gsub("^%d+_", ""):gsub("_", " "))
end

--- Builds one Markdown table (header + one row per region) for the chat window.
local function build_markdown_table(columns, audio_metrics)
    local labels = {}
    for i, col in ipairs(columns) do labels[i] = col.label end
    local lines = {
        "| Region | " .. table.concat(labels, " | ") .. " |\n",
        "|---|" .. string.rep("---|", #columns) .. "\n"
    }

    for _, r_key in ipairs(get_sorted_regions(audio_metrics)) do
        local m = audio_metrics[r_key]
        local cells = {}
        for i, col in ipairs(columns) do cells[i] = string.format(col.fmt, col.get(m, false)) end
        lines[#lines + 1] = "| " .. get_region_display_name(r_key) .. " | " .. table.concat(cells, " | ") .. " |\n"
    end
    return table.concat(lines)
end

--- Builds one HTML <table> (header + one row per region) for the report file.
local function build_html_table(columns, audio_metrics)
    local headers = {}
    for i, col in ipairs(columns) do headers[i] = "<th>" .. col.html .. "</th>" end
    local lines = {
        "    <table>\n",
        "        <tr><th>Region</th>" .. table.concat(headers) .. "</tr>\n"
    }

    for _, r_key in ipairs(get_sorted_regions(audio_metrics)) do
        local m = audio_metrics[r_key]
        local cells = {}
        for i, col in ipairs(columns) do cells[i] = "<td>" .. string.format(col.fmt, col.get(m, true)) .. "</td>" end
        lines[#lines + 1] = "<tr><td>" .. get_region_display_name(r_key) .. "</td>" .. table.concat(cells) .. "</tr>\n"
    end
    lines[#lines + 1] = "    </table>\n"
    return table.concat(lines)
end

local function save_tables_to_html(audio_metrics, txt_file_path, target_str)
    if not txt_file_path then return end

    -- Swap .txt extension for .html
    local html_path = txt_file_path:gsub("%.txt$", ".html")
    local file = io.open(html_path, "w")
    if not file then return end

    local html = [[
<!DOCTYPE html>
<html>
<head>
<style>
    body { background-color: #1e1e1e; color: #d4d4d4; font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; padding: 25px; }
    h2 { color: #FFD54F; font-weight: normal; margin-bottom: 25px; }
    h3 { color: #e0e0e0; margin-top: 30px; border-bottom: 1px solid #444; padding-bottom: 5px; }
    table { border-collapse: collapse; width: 100%; max-width: 1200px; margin-top: 15px; background-color: #252526; box-shadow: 0px 4px 10px rgba(0,0,0,0.5); }
    th, td { border: 1px solid #333; padding: 12px; text-align: center; }
    th:first-child, td:first-child { text-align: left; font-weight: bold; }
    th { background-color: #333; color: #4FC3F7; }
    .risk { color: #EF5350; font-weight: bold; }
    .safe { color: #81C784; }
</style>
</head>
<body>
    <h2>Mix & Master Analysis: <b>]] .. target_str .. [[</b></h2>

    <h3>]] .. TABLE_TITLES[1] .. [[</h3>
]] .. build_html_table(DYNAMICS_COLUMNS, audio_metrics) .. [[

    <h3>]] .. TABLE_TITLES[2] .. [[</h3>
]] .. build_html_table(TONAL_COLUMNS, audio_metrics) .. [[
</body>
</html>
]]

    file:write(html)
    file:close()
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

--- Reads a whole file; nil when it cannot be opened.
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

--- Writes the lines to a file (one per line); false when it cannot be created.
local function write_lines(path, lines)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
    return true
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

    local JSON_ESCAPES = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

    local function parse_string()
        pos = pos + 1 -- Skip opening quote
        local chars = {}
        while pos <= len do
            -- Copy the whole run of ordinary characters at once; only quotes and backslashes need attention
            local special = str:find('["\\]', pos) or (len + 1)
            table.insert(chars, str:sub(pos, special - 1))
            pos = special

            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(chars)
            elseif c == '\\' then
                local esc = str:sub(pos + 1, pos + 1)
                pos = pos + 2
                if esc == 'u' then
                    local cp = tonumber(str:sub(pos, pos + 3), 16)
                    if cp then
                        pos = pos + 4
                        -- Combine UTF-16 surrogate pairs (emoji etc.) into one code point
                        local low = (cp >= 0xD800 and cp <= 0xDBFF) and tonumber(str:match("^\\u(%x%x%x%x)", pos) or "", 16)
                        if low and low >= 0xDC00 and low <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
                            pos = pos + 6
                        end
                        table.insert(chars, utf8.char(cp)) -- code point -> UTF-8 bytes
                    end
                else
                    -- \" \\ \/ map to themselves; \b \f \n \r \t map to control characters
                    table.insert(chars, JSON_ESCAPES[esc] or esc)
                end
            end
        end
        error("Unterminated string in JSON")
    end

    local function parse_number()
        local start_pos = pos

        -- Optional sign + integer part
        local _, int_end = str:find("^[%+%-]?%d*", pos)
        pos = int_end + 1

        -- Fractional part
        if str:sub(pos, pos) == '.' then
            local _, frac_end = str:find("^%d*", pos + 1)
            pos = frac_end + 1
        end

        -- Exponent part
        if str:sub(pos, pos):match("[eE]") then
            local exponent = str:match("^[eE][%+%-]?%d+", pos)
            if not exponent then error("Invalid exponent in JSON number at pos " .. pos) end
            pos = pos + #exponent
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

local function shell_quote_for_curl(value)
    local text = tostring(value or "")

    if IS_WINDOWS then
        text = text:gsub('"', '""')
        return '"' .. text .. '"'
    end

    text = text:gsub("\\", "\\\\")
    text = text:gsub("'", "'\\''")
    return "'" .. text .. "'"
end

local function resolve_curl_binary()
    if cached_curl_cmd then return cached_curl_cmd end

    local candidates
    if IS_WINDOWS then
        -- 1. Windows Path Resolution
        local windir = os.getenv("WINDIR") or "C:\\Windows"
        candidates = {
            windir .. "\\System32\\curl.exe",
            windir .. "\\Sysnative\\curl.exe",
            "C:\\Program Files\\Git\\mingw64\\bin\\curl.exe",
            "C:\\Program Files\\Git\\usr\\bin\\curl.exe",
        }
    else
        -- 2. macOS / Linux Path Resolution
        candidates = { "/usr/bin/curl", "/usr/local/bin/curl", "/opt/homebrew/bin/curl" }
    end

    for _, filepath in ipairs(candidates) do
        if reaper.file_exists(filepath) then
            cached_curl_cmd = IS_WINDOWS and ('"' .. filepath .. '"') or filepath
            return cached_curl_cmd
        end
    end

    -- 3. Final safe probe: if curl is not in the known locations, check PATH.
    local probe_cmd = IS_WINDOWS and 'curl.exe --version >nul 2>&1' or 'curl --version >/dev/null 2>&1'
    if command_succeeded(probe_cmd) then
        cached_curl_cmd = "curl"
        return cached_curl_cmd
    end

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

    local curl_command = curl_bin .. ' -sS -D "' .. temp_response_path .. '.headers" -o "' .. temp_response_path .. '" -X POST https://api.deepseek.com/chat/completions ' ..
                         '-H ' .. shell_quote_for_curl('Authorization: Bearer ' .. API_KEY) .. ' ' ..
                         '-H ' .. shell_quote_for_curl('Content-Type: application/json') .. ' ' ..
                         '-H ' .. shell_quote_for_curl('Expect:') .. ' ' ..
                         '-d ' .. shell_quote_for_curl('@' .. temp_json_path)

    -- Windows cmd.exe quote-stripping protection
    if IS_WINDOWS then
        -- REAPER's ExecProcess runs completely hidden. Timeout 0 means "wait until finished".
        reaper.ExecProcess('cmd.exe /c "' .. curl_command .. '"', 0)
    else
        os.execute(curl_command)
    end

    local raw_response = read_file(temp_response_path)
    if not raw_response then
        return "Network Error: API request failed or timed out.\n\n" ..
               "Troubleshooting:\n" ..
               "1. Verify internet connection.\n" ..
               "2. Ensure cURL is installed. If on an older Windows version, install cURL or place curl.exe in C:\\Windows\\System32."
    end
    local headers = read_file(temp_response_path .. ".headers") or ""

    os.remove(temp_json_path)
    os.remove(temp_response_path)
    os.remove(temp_response_path .. ".headers")

    local http_status = headers:match("HTTP/[%d%.]+%s+(%d%d%d)")
    if http_status and http_status ~= "200" then
        local msg = "DeepSeek API HTTP Error (" .. http_status .. ")"
        if headers ~= "" then msg = msg .. "\nHeaders:\n" .. headers end
        return msg .. "\n\nBody:\n" .. tostring(raw_response)
    end

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
local balance_is_fetching = false
local balance_temp_file = reaper.GetResourcePath() .. "/temp_balance.txt"
local balance_done_file = reaper.GetResourcePath() .. "/temp_balance.done"
local balance_script_file = reaper.GetResourcePath() .. "/temp_balance_script"
local next_balance_poll_time = 0 -- the "done" flag file is only checked a few times per second, not every frame

--- Deletes the balance result, the completion flag and every helper script.
local function cleanup_balance_files()
    for _, path in ipairs({ balance_temp_file, balance_done_file,
                            balance_script_file .. ".bat", balance_script_file .. ".vbs", balance_script_file .. ".sh" }) do
        os.remove(path)
    end
end

local function fetch_deep_seek_balance()
    if balance_is_fetching then return end

    if API_KEY == "YOUR_DEEPSEEK_API_KEY" or API_KEY == "" then
        user_balance_str = "No API Key"
        return
    end

    local curl_bin = resolve_curl_binary()
    if not curl_bin then
        user_balance_str = "cURL Missing"
        return
    end

    user_balance_str = "Fetching..."
    balance_is_fetching = true

    -- Clean up previous async files
    cleanup_balance_files()

    local curl_cmd = curl_bin .. ' -sS -H ' .. shell_quote_for_curl('Authorization: Bearer ' .. API_KEY) ..
                     ' https://api.deepseek.com/user/balance'

    -- Both helper scripts run curl, store its answer, then raise the "done" flag file that the UI polls for
    local run_curl_lines = { curl_cmd .. ' > "' .. balance_temp_file .. '" 2>&1', 'echo DONE > "' .. balance_done_file .. '"' }
    local launched

    if IS_WINDOWS then
        local bat_path = balance_script_file .. ".bat"
        local vbs_path = balance_script_file .. ".vbs"

        -- 1. Batch script  2. VBScript wrapper (safe quotes prevent any syntax hanging)
        launched = write_lines(bat_path, { "@echo off", run_curl_lines[1], run_curl_lines[2] })
            and write_lines(vbs_path, {
                'Set objShell = CreateObject("WScript.Shell")',
                'objShell.Run "cmd.exe /c " & Chr(34) & "' .. bat_path .. '" & Chr(34), 0, False' })

        -- 3. Launch via native REAPER ExecProcess using -1 (Launch detached and immediately return)
        -- This guarantees the UI thread will not block waiting for curl to finish.
        if launched then reaper.ExecProcess('wscript.exe "' .. vbs_path .. '"', -1) end
    else
        -- Mac/Linux invisible background execution (stream redirect to fully detach handles)
        local sh_path = balance_script_file .. ".sh"
        launched = write_lines(sh_path, { "#!/bin/sh", run_curl_lines[1], run_curl_lines[2] })
        if launched then os.execute('sh "' .. sh_path .. '" >/dev/null 2>&1 &') end
    end

    if not launched then
        balance_is_fetching = false
        user_balance_str = "I/O Error"
    end
end

-- Non-blocking UI checker for the background job
local function poll_deep_seek_balance()
    if not balance_is_fetching then return end

    local now = reaper.time_precise()
    if now < next_balance_poll_time then return end
    next_balance_poll_time = now + 0.25

    -- Check if background script created the completion flag
    if not read_file(balance_done_file) then return end
    balance_is_fetching = false

    -- Safely read the result
    local raw = read_file(balance_temp_file) or ""

    -- Complete cleanup of all temporary scripts and files
    cleanup_balance_files()

    if raw == "" then
        user_balance_str = "Check Failed"
        return
    end

    local total_balance = nil
    local currency = "USD"

    -- 1. Parse via JSON decoder
    local ok_json, data = parse_json(raw)
    if ok_json and type(data) == "table" then
        if data.error then
            user_balance_str = data.error.message or "API Error"
            return
        end
        local info = (data.balance_infos and data.balance_infos[1]) or data
        total_balance = info.total_balance or info.total or info.balance
        currency = info.currency or currency
    end

    -- 2. Direct regex fallback
    if not total_balance then
        total_balance = raw:match('"total_balance"%s*:%s*"(.-)"')
        currency = raw:match('"currency"%s*:%s*"(.-)"') or currency
    end

    if total_balance then
        local symbol = (currency == "USD") and "$" or "¥"
        user_balance_str = symbol .. tostring(total_balance)
    else
        user_balance_str = "Check Failed"
        reaper.ShowConsoleMsg("\n[DeepSeek Balance Error]\nRaw Server Output:\n" .. tostring(raw) .. "\n")
    end
end

-- ==============================================================================
-- 10. JSFX DATA COLLECTION (STAGE 1: peaks, stereo sums, K-weighted energy, master 100 ms blocks)
-- ==============================================================================

local GMEM_NAME = "MixAssistant"
local ANALYZER_FX_PATH = "JS:MixAssistant/mix_assistant_analyzer"
-- gmem layout (must match the JSFX): header | per track-second records | master 100 ms blocks
local MA_HDR, MA_MAXTR, MA_MAXSEC, MA_STRIDE, MA_MSTRIDE = 256, 128, 1800, 32, 36
local MA_MBASE = MA_HDR + MA_MAXTR * MA_MAXSEC * MA_STRIDE
-- Stage 3 short-window dynamics: thresholds are passed to the JSFX through header slots, so changing them needs no JSFX edit
local MA_ACTIVE_DB, MA_CLIP_THRESHOLD = -60, 1.0 -- 100 ms sub-block is "active" above this stereo RMS (dBFS); clipped frame: |L| or |R| >= this
local MA_S_LOUDF, MA_S_CLIPS, MA_S_ACTIVE, MA_S_LOUDK, MA_S_ELIG = 26, 27, 28, 29, 30 -- record slots (see CLAUDE.md)
local MA_H_ACTIVE, MA_H_CLIP_TRK, MA_H_CLIP_MST = 16, 17, 18 -- header slots, Lua -> JSFX
local MA_H_MCLIPS, MA_H_MSTAMP, MA_H_MPEAK = 19, 20, 21 -- header slots, JSFX -> Lua (master clip frames, run id stamp, max |sample|)

-- Final 15 bands: each 2/3 octave wide, edges = every second ISO 1/3-octave value (the JSFX has the same edges).
local B15_EDGES = { 20, 31.5, 50, 80, 125, 200, 315, 500, 800, 1250, 2000, 3150, 5000, 8000, 12500, 20000 }
local B15_NAMES = { "rumble", "deep sub", "sub", "bass/punch", "body/warmth", "mud", "boxy", "hollow/honk",
    "nasal", "bite", "presence", "harsh", "sibilance", "sizzle", "air" }
-- Per stage the band edges sit at -1.5 dB (analog Q * bandwidth / centre = sqrt(10^0.15 - 1)); two cascaded stages give -3 dB.
-- The filter is designed from the pre-warped edges, so this holds at any sample rate (sent to the JSFX in gmem[185]).
local B15_C = 0.6423

--- Biquad of one band stage (b1 = 0, b2 = -b0); the JSFX uses the same maths.
local function band15_coefs(b, sr)
    local o1 = math.tan(math.pi * B15_EDGES[b] / sr)
    local o2 = math.tan(math.pi * B15_EDGES[b + 1] / sr)
    local o0 = math.sqrt(o1 * o2)
    local bw = (o2 - o1) / B15_C -- centre / Q of the analog prototype
    local d0 = 1 + bw + o0 * o0
    return bw / d0, (2 * o0 * o0 - 2) / d0, (1 - bw + o0 * o0) / d0
end

--- Response of the two-stage band filter (same RBJ design as the JSFX) at the JSFX sample rate:
-- per band the calibration offset (dB, so the band level is the energy between its edges) and the pair's response at both edges.
local function band15_calibration(sr)
    local function pair_power(b0, a1, a2, f)
        local w = 2 * math.pi * f / sr
        local re = 1 + a1 * math.cos(w) + a2 * math.cos(2 * w)
        local im = a1 * math.sin(w) + a2 * math.sin(2 * w)
        local p = b0 * b0 * (2 - 2 * math.cos(2 * w)) / (re * re + im * im) -- |H|^2 of one stage
        return p * p
    end
    local offsets, edge_lo, edge_hi = {}, {}, {}
    local steps, f_min = 4000, 1.0
    local ratio = math.log((sr / 2 * 0.9999) / f_min)
    for b = 1, 15 do
        local lo, hi = B15_EDGES[b], B15_EDGES[b + 1]
        local b0, a1, a2 = band15_coefs(b, sr)
        local enbw = 0 -- equivalent noise bandwidth (Hz), integrated on a log frequency axis
        for i = 0, steps - 1 do
            local f = f_min * math.exp(ratio * (i + 0.5) / steps)
            enbw = enbw + pair_power(b0, a1, a2, f) * f * ratio / steps
        end
        offsets[b] = 10 * math.log((hi - lo) / enbw, 10)
        edge_lo[b] = 10 * math.log(pair_power(b0, a1, a2, lo), 10)
        edge_hi[b] = 10 * math.log(pair_power(b0, a1, a2, hi), 10)
    end
    return offsets, edge_lo, edge_hi
end
local MA_MAGIC = 20261103

local ANALYZER_JSFX = [==[
desc:Mix Assistant Analyzer (temp)
//MA_JSFX_VERSION=3
options:gmem=MixAssistant

slider1:0<0,127,1>Track index
slider2:0<0,1,1{Track,Master}>Role
slider3:0<0,1,1{Off,On}>Debug: Lua DSP check (master only)

in_pin:left input
in_pin:right input
out_pin:left output
out_pin:right output

@init
MAGIC = 20261103; VERSION = 3;
HDR = 256; MAXTR = 128; MAXSEC = 1800; STRIDE = 32;
MBASE = HDR + MAXTR * MAXSEC * STRIDE; MSTRIDE = 36;
gmem[0] = MAGIC; gmem[1] = VERSION;
invsr = 1 / srate;

// K-weighting (ITU-R BS.1770), coefficients designed for the real sample rate
K = tan($pi * 1681.974450955533 / srate);
Q = 0.7071752369554196;
Vh = pow(10, 3.999843853973347 / 20);
Vb = pow(Vh, 0.4996667741545416);
a0 = 1 + K / Q + K * K;
sb0 = (Vh + Vb * K / Q + K * K) / a0;
sb1 = 2 * (K * K - Vh) / a0;
sb2 = (Vh - Vb * K / Q + K * K) / a0;
sa1 = 2 * (K * K - 1) / a0;
sa2 = (1 - K / Q + K * K) / a0;
K = tan($pi * 38.13547087602444 / srate);
Q = 0.5003270373238773;
a0 = 1 + K / Q + K * K;
hb0 = 1; hb1 = -2; hb2 = 1;
ha1 = 2 * (K * K - 1) / a0;
ha2 = (1 - K / Q + K * K) / a0;

cur_sec = -1; cur_mb = -1; last_run = -1;
FBASE = 256; dbg = 0; dw0 = 0; dw1 = 0;
// local memory: 0 band coefs (15x4), 64 mid states, 128 side states (15x4 each), 192 accumulators (15 mid + 15 side), 224 band edges, 256 debug filters
CBASE = 0; STM = 64; STS = 128; ACC = 192; EDG = 224;
EDG[0] = 20; EDG[1] = 31.5; EDG[2] = 50; EDG[3] = 80; EDG[4] = 125; EDG[5] = 200; EDG[6] = 315; EDG[7] = 500;
EDG[8] = 800; EDG[9] = 1250; EDG[10] = 2000; EDG[11] = 3150; EDG[12] = 5000; EDG[13] = 8000; EDG[14] = 12500; EDG[15] = 20000;
SILN = floor(0.1 * srate); silcnt = 0; skip = 0;
sub_ll = 0; sub_rr = 0; sub_lr = 0;
// Stage 3: 100 ms sub-blocks aligned to the project second (thresholds come from Lua through gmem[16..18])
SBMIN = srate * 0.05;
act_thr = 0; clip_thr = 1; mclip_thr = 1;
cur_sb = -1; sbcnt = 0; sb_fe = 0; sb_ke = 0;
sb_maxf = 0; sb_maxk = 0; sb_act = 0; sb_elig = 0; clipc = 0;
mclipc = 0; mpeak = 0;

function sb_close() global(sbcnt,sb_fe,sb_ke,SBMIN,act_thr,sb_maxf,sb_maxk,sb_act,sb_elig) local(mf,mk) (
  sbcnt >= SBMIN ? (
    mf = sb_fe / sbcnt; mk = sb_ke / sbcnt;
    sb_elig += 1;
    mf > act_thr ? sb_act += 1;
    mf > sb_maxf ? sb_maxf = mf;
    mk > sb_maxk ? sb_maxk = mk;
  );
  sbcnt = 0; sb_fe = 0; sb_ke = 0;
);

function shelf(x) instance(x1,x2,y1,y2) global(sb0,sb1,sb2,sa1,sa2) local(y) (
  y = sb0*x + sb1*x1 + sb2*x2 - sa1*y1 - sa2*y2;
  x2 = x1; x1 = x; y2 = y1; y1 = y;
  y;
);
function hpf(x) instance(x1,x2,y1,y2) global(hb0,hb1,hb2,ha1,ha2) local(y) (
  y = hb0*x + hb1*x1 + hb2*x2 - ha1*y1 - ha2*y2;
  x2 = x1; x1 = x; y2 = y1; y1 = y;
  y;
);
function lp4(x) instance(z1,z2,z3,z4) global(lb0,lb1,lb2,la1,la2) local(y,o) (
  y = lb0*x + z1; z1 = lb1*x - la1*y + z2; z2 = lb2*x - la2*y;
  o = lb0*y + z3; z3 = lb1*y - la1*o + z4; z4 = lb2*y - la2*o;
  o;
);
// two cascaded band-pass biquads (RBJ, 0 dB peak: b1 = 0, b2 = -b0) per band; adds the output energy to abase[band]
function bandrun(x, sbase, abase) global(CBASE) local(bi,cp,sp,y,o) (
  bi = 0;
  loop(15,
    cp = CBASE + bi * 4; sp = sbase + bi * 4;
    y = cp[0] * x + sp[0];
    sp[0] = sp[1] - cp[1] * y;
    sp[1] = -cp[0] * x - cp[2] * y;
    o = cp[0] * y + sp[2];
    sp[2] = sp[3] - cp[1] * o;
    sp[3] = -cp[0] * y - cp[2] * o;
    abase[bi] += o * o;
    bi += 1;
  );
);
function put_track() global(idx,cur_sec,pkl,pkr,sll,srr,slr,ske,scnt,run,HDR,MAXSEC,STRIDE,ACC,sub_ll,sub_rr,sub_lr,gmem,sb_maxf,sb_maxk,sb_act,sb_elig,sbcnt,sb_fe,sb_ke,SBMIN,act_thr,clipc) local(b,bi,pf,pk,pa,pe,mf,mk) (
  b = HDR + (idx * MAXSEC + cur_sec) * STRIDE;
  gmem[b] = pkl; gmem[b+1] = pkr; gmem[b+2] = sll; gmem[b+3] = srr;
  gmem[b+4] = slr; gmem[b+5] = ske; gmem[b+6] = scnt; gmem[b+7] = run;
  bi = 0;
  loop(15, gmem[b+8+bi] = ACC[bi]; bi += 1;);
  gmem[b+23] = sub_ll; gmem[b+24] = sub_rr; gmem[b+25] = sub_lr;
  // provisional: the in-progress sub-block counts in THIS write only (never added to the persistent state)
  pf = sb_maxf; pk = sb_maxk; pa = sb_act; pe = sb_elig;
  sbcnt >= SBMIN ? (
    mf = sb_fe / sbcnt; mk = sb_ke / sbcnt;
    pe += 1; mf > act_thr ? pa += 1;
    mf > pf ? pf = mf; mk > pk ? pk = mk;
  );
  gmem[b+26] = pf; gmem[b+27] = clipc; gmem[b+28] = pa; gmem[b+29] = pk; gmem[b+30] = pe;
);
function put_master() global(cur_mb,mke,mcnt,run,MBASE,MSTRIDE,ACC,gmem) local(b,bi) (
  b = MBASE + cur_mb * MSTRIDE;
  gmem[b] = mke; gmem[b+1] = mcnt; gmem[b+2] = run;
  bi = 0;
  loop(30, gmem[b+3+bi] = ACC[bi]; bi += 1;);
);
@slider
idx = slider1 | 0;
role = slider2 | 0;
dbg = slider3 | 0;

@block
run = gmem[9];
ok = role ? 1 : (idx >= 0 && idx < MAXTR);
t0 = play_position;
run != last_run ? (
  last_run = run; cur_sec = -1; cur_mb = -1; exp_t = -1;
  cur_sb = -1; sbcnt = 0; sb_fe = 0; sb_ke = 0;
  sb_maxf = 0; sb_maxk = 0; sb_act = 0; sb_elig = 0; clipc = 0; mclipc = 0; mpeak = 0;
  act_thr = gmem[16]; clip_thr = gmem[17] > 0 ? gmem[17] : 1; mclip_thr = gmem[18] > 0 ? gmem[18] : 1;
  bq =gmem[185] > 0 ? gmem[185] : 0.6423;
  bi = 0;
  loop(15,
    bo1 = tan($pi * EDG[bi] / srate);
    bo2 = tan($pi * EDG[bi + 1] / srate);
    bo0 = sqrt(bo1 * bo2);
    bbw = (bo2 - bo1) / bq;
    bd0 = 1 + bbw + bo0 * bo0;
    cp = CBASE + bi * 4;
    cp[0] = bbw / bd0; cp[1] = (2 * bo0 * bo0 - 2) / bd0; cp[2] = (1 - bbw + bo0 * bo0) / bd0;
    bi += 1;
  );
  memset(STM, 0, 124);
  subhz = gmem[162] > 0 ? gmem[162] : 120;
  lw = 2 * $pi * subhz / srate;
  lal = sin(lw) / 1.41421356;
  la0 = 1 + lal;
  lbg = (1 - cos(lw)) / la0;
  lb0 = lbg / 2; lb1 = lbg; lb2 = lbg / 2;
  la1 = -2 * cos(lw) / la0; la2 = (1 - lal) / la0;
  lpl.z1 = lpl.z2 = lpl.z3 = lpl.z4 = 0;
  lpr.z1 = lpr.z2 = lpr.z3 = lpr.z4 = 0;
  silcnt = 0;
  role && dbg ? (
    dw0 = gmem[160]; dw1 = gmem[161];
    acN = acPL = acPR = acLL = acRR = acLR = acMM = acSS = bsLL = bsRR = bsLR = 0;
    memset(FBASE, 0, 72);
    kb = 0;
    loop(9,
      dq = gmem[176 + kb];
      dwr = 2 * $pi * gmem[164 + kb] / srate;
      dal = sin(dwr) / (2 * dq);
      da0 = 1 + dal;
      dp = FBASE + kb * 8;
      dp[0] = dal / da0; dp[1] = -dal / da0;
      dp[2] = -2 * cos(dwr) / da0; dp[3] = (1 - dal) / da0;
      kb += 1;
    );
    dwr = 2 * $pi * gmem[162] / srate;
    dal = sin(dwr) / 1.41421356;
    da0 = 1 + dal;
    lbg = (1 - cos(dwr)) / da0;
    lb0 = lbg / 2; lb1 = lbg; lb2 = lbg / 2;
    la1 = -2 * cos(dwr) / da0; la2 = (1 - dal) / da0;
    dlm.z1 = dlm.z2 = dlm.z3 = dlm.z4 = 0;
    dls.z1 = dls.z2 = dls.z3 = dls.z4 = 0;
  );
);
synced = (exp_t >= 0 && abs(t0 - exp_t) < 0.004) || abs(t0 - gmem[7]) < 0.05;
exp_t = t0 + samplesblock * invsr;
active = (gmem[6] == 1) && (run > 0) && ok && synced;
n = 0;
active ? (
  role ? ( gmem[10] = run; ) : ( gmem[32 + idx] = run; );
  gmem[2] = srate;
  role && dbg ? (
    gmem[192] = acN; gmem[193] = acPL; gmem[194] = acPR;
    gmem[195] = acLL; gmem[196] = acRR; gmem[197] = acLR;
    gmem[198] = acMM; gmem[199] = acSS;
    gmem[200] = bsLL; gmem[201] = bsRR; gmem[202] = bsLR;
    gmem[203] = run;
    kb = 0;
    loop(9, dp = FBASE + kb * 8; gmem[204 + kb] = dp[6]; kb += 1;);
  );
);

@sample
active ? (
  t = t0 + n * invsr;
  (t >= 0 && t < MAXSEC) ? (
    kl = hpl.hpf(shl.shelf(spl0));
    kr = hpr.hpf(shr.shelf(spl1));
    ke = kl * kl + kr * kr;
    // after 100 ms of exact digital silence: reset the band/sub filters once and skip them until audio returns
    (spl0 == 0 && spl1 == 0) ? ( silcnt += 1; ) : ( silcnt = 0; );
    silcnt == SILN ? (
      memset(STM, 0, 124);
      lpl.z1 = lpl.z2 = lpl.z3 = lpl.z4 = 0;
      lpr.z1 = lpr.z2 = lpr.z3 = lpr.z4 = 0;
    );
    skip = silcnt >= SILN;
    role ? (
      mb = (t * 10) | 0;
      mb != cur_mb ? (
        cur_mb >= 0 ? put_master();
        cur_mb = mb; mke = 0; mcnt = 0;
        memset(ACC, 0, 30);
      );
      mke += ke; mcnt += 1;
      sb_pk = max(abs(spl0), abs(spl1)); sb_pk > mpeak ? mpeak = sb_pk; sb_pk >= mclip_thr ? mclipc += 1;
      !skip ? (
        mdx = (spl0 + spl1) * 0.5; sdx = (spl0 - spl1) * 0.5;
        bandrun(mdx, STM, ACC);
        bandrun(sdx, STS, ACC + 15);
      );
      dbg && t >= dw0 && t < dw1 ? (
        xl = spl0; xr = spl1;
        xy = abs(xl); xy > acPL ? acPL = xy;
        xy = abs(xr); xy > acPR ? acPR = xy;
        acLL += xl * xl; acRR += xr * xr; acLR += xl * xr;
        xm = (xl + xr) * 0.5; xs = (xl - xr) * 0.5;
        acMM += xm * xm; acSS += xs * xs;
        kb = 0;
        loop(9,
          dp = FBASE + kb * 8;
          xy = dp[0] * xm + dp[4];
          dp[4] = dp[5] - dp[2] * xy;
          dp[5] = dp[1] * xm - dp[3] * xy;
          dp[6] += xy * xy;
          kb += 1;
        );
        xsm = dlm.lp4(xm); xsd = dls.lp4(xs);
        xsl = xsm + xsd; xsr = xsm - xsd;
        bsLL += xsl * xsl; bsRR += xsr * xsr; bsLR += xsl * xsr;
        acN += 1;
      );
      n >= samplesblock - 1 ? ( put_master(); gmem[19] = mclipc; gmem[20] = run; gmem[21] = mpeak; );
    ) : (
      sec = t | 0;
      sec != cur_sec ? (
        sb_close();
        cur_sec >= 0 ? put_track();
        cur_sec = sec;
        pkl = 0; pkr = 0; sll = 0; srr = 0; slr = 0; ske = 0; scnt = 0;
        memset(ACC, 0, 15); sub_ll = 0; sub_rr = 0; sub_lr = 0;
        sb_maxf = 0; sb_maxk = 0; sb_act = 0; sb_elig = 0; clipc = 0;
      );
      nb = (t * 10) | 0;
      nb != cur_sb ? ( sb_close(); cur_sb = nb; );
      a = abs(spl0); a > pkl ? pkl = a;
      a = abs(spl1); a > pkr ? pkr = a;
      sll += spl0 * spl0; srr += spl1 * spl1; slr += spl0 * spl1;
      ske += ke; scnt += 1;
      sb_e = spl0 * spl0 + spl1 * spl1;
      sb_fe += sb_e; sb_ke += ke; sbcnt += 1;
      sb_pk = max(abs(spl0), abs(spl1));
      sb_pk >= clip_thr ? clipc += 1;
      !skip ? (
        mdx = (spl0 + spl1) * 0.5;
        bandrun(mdx, STM, ACC);
        ylp = lpl.lp4(spl0); yrp = lpr.lp4(spl1);
        sub_ll += ylp * ylp; sub_rr += yrp * yrp; sub_lr += ylp * yrp;
      );
      n >= samplesblock - 1 ? put_track();
    );
  );
);
n += 1;
]==]

local function analyzer_dir()
    return reaper.GetResourcePath() .. PATH_SEPARATOR .. "Effects" .. PATH_SEPARATOR .. "MixAssistant"
end

local function write_analyzer_file()
    local dir = analyzer_dir()
    reaper.RecursiveCreateDirectory(dir, 0)
    local path = dir .. PATH_SEPARATOR .. "mix_assistant_analyzer"
    local f, err = io.open(path, "w")
    if not f then return nil, "Cannot write analyzer file:\n" .. path .. "\n" .. tostring(err) end
    f:write(ANALYZER_JSFX)
    f:close()
    return path
end

local function remove_analyzer_file()
    os.remove(analyzer_dir() .. PATH_SEPARATOR .. "mix_assistant_analyzer")
    os.remove(analyzer_dir()) -- only succeeds when empty
end

local function is_analyzer_name(name)
    local n = (name or ""):lower()
    return n:find("mix assistant analyzer", 1, true) ~= nil or n:find("mix_assistant_analyzer", 1, true) ~= nil
end

--- Deletes every analyzer instance (also leftovers from a crash). Returns how many were removed.
local function remove_all_analyzers()
    local removed = 0
    local function sweep(track)
        for i = reaper.TrackFX_GetCount(track) - 1, 0, -1 do
            local _, name = reaper.TrackFX_GetFXName(track, i)
            if is_analyzer_name(name) then
                reaper.TrackFX_Delete(track, i)
                removed = removed + 1
            end
        end
    end
    reaper.PreventUIRefresh(1)
    sweep(reaper.GetMasterTrack(0))
    for i = 0, reaper.CountTracks(0) - 1 do sweep(reaper.GetTrack(0, i)) end
    reaper.PreventUIRefresh(-1)
    return removed
end

--- True when the track's audio can reach the master (main/parent send, or a non-muted send on channels 1/2).
local function reaches_master(track, memo)
    if memo[track] ~= nil then return memo[track] end
    memo[track] = false -- cycle guard
    local result = false
    if reaper.GetMediaTrackInfo_Value(track, "B_MAINSEND") == 1 then
        local parent = reaper.GetParentTrack(track)
        result = (parent == nil) or reaches_master(parent, memo)
    end
    if not result then
        for s = 0, reaper.GetTrackNumSends(track, 0) - 1 do
            local dest = reaper.GetTrackSendInfo_Value(track, 0, s, "P_DESTTRACK")
            local send_muted = reaper.GetTrackSendInfo_Value(track, 0, s, "B_MUTE") == 1
            local dst_chan = math.floor(reaper.GetTrackSendInfo_Value(track, 0, s, "I_DSTCHAN")) & 1023
            if dest and dest ~= 0 and not send_muted and dst_chan < 2 and reaches_master(dest, memo) then
                result = true
                break
            end
        end
    end
    memo[track] = result
    return result
end

local function should_analyze(track, has_children, memo)
    if is_track_hierarchy_muted(track) then return false end
    local can_sound = reaper.CountTrackMediaItems(track) > 0
        or reaper.TrackFX_GetInstrument(track) >= 0
        or reaper.GetTrackNumSends(track, -1) > 0
        or has_children[track] == true
    return can_sound and reaches_master(track, memo)
end

--- Adds one analyzer to every qualifying track (+ master). Returns list, skipped count | nil, error.
local function inject_analyzers(debug_on)
    local num_tracks = reaper.CountTracks(0)
    local has_children = {}
    for i = 0, num_tracks - 1 do
        local p = reaper.GetParentTrack(reaper.GetTrack(0, i))
        if p then has_children[p] = true end
    end

    local list, skipped, memo, err = {}, 0, {}, nil
    reaper.PreventUIRefresh(1)
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        if i >= MA_MAXTR or not should_analyze(track, has_children, memo) then
            skipped = skipped + 1
        else
            local fx = reaper.TrackFX_AddByName(track, ANALYZER_FX_PATH, false, -1)
            if fx < 0 then
                err = "TrackFX_AddByName could not find the analyzer JSFX (returned -1)."
                break
            end
            reaper.TrackFX_SetParam(track, fx, 0, i)
            reaper.TrackFX_SetParam(track, fx, 1, 0)
            list[#list + 1] = { idx = i, name = get_track_identity(track) }
        end
    end
    if not err then
        local master = reaper.GetMasterTrack(0)
        local fx = reaper.TrackFX_AddByName(master, ANALYZER_FX_PATH, false, -1)
        if fx < 0 then
            err = "Could not add the analyzer to the master track."
        else
            reaper.TrackFX_SetParam(master, fx, 0, 0)
            reaper.TrackFX_SetParam(master, fx, 1, 1)
            reaper.TrackFX_SetParam(master, fx, 2, debug_on and 1 or 0)
        end
    end
    reaper.PreventUIRefresh(-1)

    if err then return nil, nil, err end
    return list, skipped
end

local function level_db(x) return x > 1e-9 and 20 * math.log(x, 10) or -144.0 end
local function lufs(mean_square) return mean_square > 1e-12 and (-0.691 + 10 * math.log(mean_square, 10)) or -144.0 end

--- Nearest-rank percentile (p = 0..100) of a list of numbers (sorts a copy); nil for an empty list.
local function percentile(list, p)
    local n = #list
    if n == 0 then return nil end
    local c = {}
    for i = 1, n do c[i] = list[i] end
    table.sort(c)
    return c[math.max(1, math.ceil(p / 100 * n))]
end
local function median(list) return percentile(list, 50) end

--- Reads every valid per-second record of one track and sums them up (seconds first_sec .. max_sec - 1, first_sec default 0).
local function summarize_track(idx, max_sec, run_id, first_sec)
    local s = { secs = 0, first = -1, last = -1, samples = 0, ll = 0, rr = 0, lr = 0, ke = 0, peak = 0,
        bands = {}, sub_ll = 0, sub_rr = 0, sub_lr = 0, clips = 0, viol_loud = 0, viol_act = 0 } -- bands[1..15]: summed mid band energies
    for k = 1, 15 do s.bands[k] = 0 end
    local srate = reaper.gmem_read(2)
    local crest, max_loudf, max_loudk, sum_act, sum_elig = {}, 0, 0, 0, 0
    for sec = first_sec or 0, max_sec - 1 do
        local b = MA_HDR + (idx * MA_MAXSEC + sec) * MA_STRIDE
        if reaper.gmem_read(b + 7) == run_id then
            s.secs = s.secs + 1
            if s.first < 0 then s.first = sec end
            s.last = sec
            s.peak = math.max(s.peak, reaper.gmem_read(b), reaper.gmem_read(b + 1))
            s.ll = s.ll + reaper.gmem_read(b + 2)
            s.rr = s.rr + reaper.gmem_read(b + 3)
            s.lr = s.lr + reaper.gmem_read(b + 4)
            s.ke = s.ke + reaper.gmem_read(b + 5)
            s.samples = s.samples + reaper.gmem_read(b + 6)
            for k = 1, 15 do s.bands[k] = s.bands[k] + reaper.gmem_read(b + 7 + k) end
            s.sub_ll = s.sub_ll + reaper.gmem_read(b + 23)
            s.sub_rr = s.sub_rr + reaper.gmem_read(b + 24)
            s.sub_lr = s.sub_lr + reaper.gmem_read(b + 25)

            -- Stage 3: short-window dynamics of this second
            local scnt, e_ll, e_rr = reaper.gmem_read(b + 6), reaper.gmem_read(b + 2), reaper.gmem_read(b + 3)
            local loudf = reaper.gmem_read(b + MA_S_LOUDF)
            local act, elig = reaper.gmem_read(b + MA_S_ACTIVE), reaper.gmem_read(b + MA_S_ELIG)
            max_loudf = math.max(max_loudf, loudf)
            max_loudk = math.max(max_loudk, reaper.gmem_read(b + MA_S_LOUDK))
            sum_act, sum_elig = sum_act + act, sum_elig + elig
            s.clips = s.clips + reaper.gmem_read(b + MA_S_CLIPS)
            if act > elig then s.viol_act = s.viol_act + 1 end
            if scnt > 0 then
                local mean_fe = (e_ll + e_rr) / scnt -- mean(L^2 + R^2), same convention as the loudest-100 ms slot
                local rms_db = level_db(math.sqrt(mean_fe / 2))
                if scnt >= 0.999 * srate and mean_fe > 1e-12 and loudf < mean_fe * 10 ^ -0.01 then
                    s.viol_loud = s.viol_loud + 1 -- loudest 100 ms more than 0.1 dB below the full second's own rms
                end
                if scnt >= 0.9 * srate and rms_db > MA_ACTIVE_DB then
                    crest[#crest + 1] = level_db(math.max(reaper.gmem_read(b), reaper.gmem_read(b + 1))) - rms_db
                end
            end
        end
    end
    s.crest_n, s.crest_med, s.crest_p90 = #crest, median(crest), percentile(crest, 90)
    s.loud100_db = sum_elig > 0 and (max_loudf > 1e-12 and 10 * math.log(max_loudf / 2, 10) or -144.0) or nil
    s.loudk100 = lufs(max_loudk)
    s.act_pct = sum_elig > 0 and 100 * sum_act / sum_elig or nil
    return s
end

--- Master loudness from the 100 ms K-weighted blocks (BS.1770: 400 ms momentary, 3 s short-term, two-stage gating).
local function summarize_master(max_sec, run_id)
    local nblk = math.min(18000, max_sec * 10)
    local pe, pc, pv = { [0] = 0 }, { [0] = 0 }, { [0] = 0 }
    local mid_e, side_e = {}, {} -- summed band energies of the valid blocks
    for i = 1, 15 do mid_e[i], side_e[i] = 0, 0 end
    for k = 0, nblk - 1 do
        local b = MA_MBASE + k * MA_MSTRIDE
        local ok = reaper.gmem_read(b + 2) == run_id
        if ok then
            for i = 1, 15 do
                mid_e[i] = mid_e[i] + reaper.gmem_read(b + 2 + i)
                side_e[i] = side_e[i] + reaper.gmem_read(b + 17 + i)
            end
        end
        pe[k + 1] = pe[k] + (ok and reaper.gmem_read(b) or 0)
        pc[k + 1] = pc[k] + (ok and reaper.gmem_read(b + 1) or 0)
        pv[k + 1] = pv[k] + (ok and 1 or 0)
    end

    local function window_ms(k, len)
        if k + len > nblk or pv[k + len] - pv[k] ~= len then return nil end
        local c = pc[k + len] - pc[k]
        return c > 0 and (pe[k + len] - pe[k]) / c or nil
    end

    local gated, max_m, max_s = {}, -144.0, -144.0
    for k = 0, nblk - 4 do
        local ms = window_ms(k, 4)
        if ms then
            max_m = math.max(max_m, lufs(ms))
            if lufs(ms) > -70 then gated[#gated + 1] = ms end
        end
    end
    for k = 0, nblk - 30 do
        local ms = window_ms(k, 30)
        if ms then max_s = math.max(max_s, lufs(ms)) end
    end

    local integrated = -144.0
    if #gated > 0 then
        local sum = 0
        for _, ms in ipairs(gated) do sum = sum + ms end
        local rel_gate = lufs(sum / #gated) - 10
        local sum2, n2 = 0, 0
        for _, ms in ipairs(gated) do
            if lufs(ms) > rel_gate then sum2 = sum2 + ms; n2 = n2 + 1 end
        end
        if n2 > 0 then integrated = lufs(sum2 / n2) end
    end
    return { valid_blocks = pv[nblk], integrated = integrated, max_m = max_m, max_s = max_s,
        samples = pc[nblk], mid = mid_e, side = side_e }
end

local DEBUG_DURATION = 20 -- seconds of the region compared against the Lua DSP

--- Region under the edit cursor (else first region, else the whole project) plus the analysis window the Lua DSP will use.
local function pick_debug_region()
    local region, first
    local cursor = reaper.GetCursorPosition()
    for _, r in ipairs(get_arrangement_markers() or {}) do
        if r.end_s then
            first = first or r
            if cursor >= r.start_s and cursor < r.end_s then
                region = r
                break
            end
        end
    end
    region = region or first
    if not region then region = { name = "Entire project", start_s = 0, end_s = reaper.GetProjectLength(0) } end
    local win0 = region.start_s + math.min(1.0, (region.end_s - region.start_s) * 0.1)
    local win1 = math.min(region.end_s, win0 + DEBUG_DURATION)
    return region, win0, win1
end

local function find_new_tracks(old_guids)
    local list = {}
    for i = 0, reaper.CountTracks(0) - 1 do
        local trk = reaper.GetTrack(0, i)
        if not old_guids[reaper.GetTrackGUID(trk)] and reaper.CountTrackMediaItems(trk) > 0 then
            list[#list + 1] = trk
        end
    end
    return list
end

local function print_dsp_comparison(out, region, run_id, lua_m, win0, win1, fader_db)
    local function g(i) return reaper.gmem_read(i) end
    local n = g(192)
    if g(203) ~= run_id or n < 1 then
        out[#out + 1] = "\nJSFX debug data missing (master analyzer accumulated nothing)."
        return
    end
    local ll, rr, lr, mm, ss = g(195), g(196), g(197), g(198), g(199)
    local sll, srr, slr = g(200), g(201), g(202)
    local rms_m, rms_s = math.sqrt(mm / n), math.sqrt(ss / n)
    local peak_db = level_db(math.max(g(193), g(194))) + fader_db
    local rms_db = level_db(math.sqrt((mm + ss) / n)) + fader_db
    local sub_corr = (sll * srr > 0) and slr / math.sqrt(sll * srr) or 1

    local rows = {
        { "peak dB",    lua_m.dyn.peak_db,       peak_db },
        { "rms dB",     lua_m.dyn.rms_db,        rms_db },
        { "crest dB",   lua_m.dyn.crest_db,      peak_db - rms_db },
        { "width %",    lua_m.stereo.width_pct,  (rms_m + rms_s) > 0 and rms_s / (rms_m + rms_s) * 100 or 0 },
        { "phase corr", lua_m.stereo.phase_corr, (ll * rr > 0) and lr / math.sqrt(ll * rr) or 1 },
        { "sub corr",   dsp_debug.sub_corr,      sub_corr },
    }
    for b, key in ipairs(BAND_KEYS) do
        rows[#rows + 1] = { key, lua_m.tonal_db[key], convert_energy_to_db(g(203 + b), n, BAND_OFFSET_DB[b]) + fader_db }
    end

    out[#out + 1] = string.format("\nLua DSP vs JSFX | '%s' window %.2f-%.2f s | JSFX samples %d | master fader %.1f dB",
        region.name, win0, win1, n, fader_db)
    out[#out + 1] = "metric            Lua      JSFX     delta"
    for _, r in ipairs(rows) do
        out[#out + 1] = string.format("%-12s %9.2f %9.2f %9.2f", r[1], r[2] or 0, r[3], r[3] - (r[2] or 0))
    end
    local jsfx_status = (convert_energy_to_db((sll + srr) / 2, n) > -50.0 and sub_corr < 0.0) and "Phase_Risk" or "Safe"
    out[#out + 1] = "sub-mono status: Lua " .. tostring(lua_m.stereo.sub_mono) .. " | JSFX " .. jsfx_status
end

--- Stage 1 test: inject -> render (nothing added to the project) -> read gmem -> print numbers -> clean up.
-- compare = true: also render into the project and compare the Lua DSP with the JSFX master values.
local function run_collection_test(compare)
    reaper.ClearConsole()
    remove_all_analyzers() -- leftovers from an earlier crash

    local path, write_err = write_analyzer_file()
    if not path then reaper.ShowMessageBox(write_err, "Analyzer file", 0) return end

	reaper.Undo_BeginBlock2(0)
    local render_opts = math.floor(reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, false))
    local out = {}
    local old_guids = {}
    for i = 0, reaper.CountTracks(0) - 1 do old_guids[reaper.GetTrackGUID(reaper.GetTrack(0, i))] = true end

    local ok, err = pcall(function()
        reaper.gmem_attach(GMEM_NAME)

        local top = 8388607
        reaper.gmem_write(top, 12345.5)
        out[#out + 1] = "gmem top index write/read: " .. (reaper.gmem_read(top) == 12345.5 and "OK" or "FAILED")
        reaper.gmem_write(top, 0)

        reaper.gmem_write(0, 0)
        reaper.gmem_write(6, 0)
        local run_id = math.floor(reaper.time_precise() * 1000) % 2000000000 + 1

        reaper.gmem_write(162, SUB_MONO_CUTOFF_HZ)
        reaper.gmem_write(185, B15_C)
        local tracks, skipped, inject_err = inject_analyzers(compare)
        if not tracks then error(inject_err, 0) end
        out[#out + 1] = string.format("Analyzers: %d tracks + master (%d tracks skipped)", #tracks, skipped)
        out[#out + 1] = "JSFX handshake after injection: " .. (reaper.gmem_read(0) == MA_MAGIC and "yes" or "no (advisory only)")

        local region, win0, win1
        if compare then
            region, win0, win1 = pick_debug_region()
            reaper.gmem_write(160, win0)
            reaper.gmem_write(161, win1)
            reaper.gmem_write(162, SUB_MONO_CUTOFF_HZ)
            for b = 1, #BAND_FREQS do
                reaper.gmem_write(163 + b, BAND_FREQS[b])
                reaper.gmem_write(175 + b, BAND_Q[b])
            end
        end

        -- Comparison needs the rendered file in the project; the normal test renders without adding it
        reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", compare and (render_opts | 1) or (render_opts & ~1), true)
        -- Stage 3 thresholds (the JSFX reads them when the run id changes, so they go in before slot 9)
        local master_vol = reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "D_VOL")
        if master_vol < 1e-9 then master_vol = 1e9 end
        reaper.gmem_write(MA_H_ACTIVE, 2 * 10 ^ (MA_ACTIVE_DB / 10))
        reaper.gmem_write(MA_H_CLIP_TRK, MA_CLIP_THRESHOLD)
        reaper.gmem_write(MA_H_CLIP_MST, MA_CLIP_THRESHOLD / master_vol)
        reaper.gmem_write(MA_H_MCLIPS, 0)
        reaper.gmem_write(MA_H_MSTAMP, 0)
        reaper.gmem_write(MA_H_MPEAK, 0)
		reaper.gmem_write(9, run_id)
        reaper.gmem_write(7, 0)
        reaper.gmem_write(6, 1)
        local render_t0 = reaper.time_precise()
        -- 43349 = dry run render (no file written); the Lua DSP comparison needs the rendered file, so it keeps 42230
        reaper.Main_OnCommand(compare and 42230 or 43349, 0)
        local render_s = reaper.time_precise() - render_t0
        reaper.gmem_write(6, 0)

        local proj_len = reaper.GetProjectLength(0)
        local max_sec = math.min(MA_MAXSEC, math.ceil(proj_len) + 2)
        local project_sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
        out[#out + 1] = string.format("Project length %.1f s | project SR %d | JSFX reported SR %d | master seen: %s",
            proj_len, project_sr, reaper.gmem_read(2), reaper.gmem_read(10) == run_id and "yes" or "NO")
        out[#out + 1] = string.format("Render time %.1f s (%.1fx realtime, %s)", render_s, proj_len / math.max(render_s, 0.001),
            compare and "normal render" or "dry run")

        local jsfx_sr = reaper.gmem_read(2)
        if jsfx_sr < 8000 then jsfx_sr = project_sr end
        local offsets, edge_lo, edge_hi = band15_calibration(jsfx_sr)
        local edge_min, edge_max = 0, -99
        for b = 1, 15 do
            edge_min = math.min(edge_min, edge_lo[b], edge_hi[b])
            edge_max = math.max(edge_max, edge_lo[b], edge_hi[b])
        end
        out[#out + 1] = string.format("Band filter pair response at the band edges (target -3.0 dB): %.2f .. %.2f dB | edge const %.4f | SR %d",
            edge_min, edge_max, B15_C, jsfx_sr)
        for b = 1, 15 do
            if math.abs(edge_lo[b] + 3) > 0.3 or math.abs(edge_hi[b] + 3) > 0.3 then
                out[#out + 1] = string.format("  band %d (%s): lower edge %.2f dB, upper edge %.2f dB, calibration %+.2f dB",
                    b, B15_NAMES[b], edge_lo[b], edge_hi[b], offsets[b])
            end
        end

        out[#out + 1] = "\n idx name                      secs  first-last   samples   peak   Kdb   corr"
        local sums = {}
		for _, t in ipairs(tracks) do
            local s = summarize_track(t.idx, max_sec, run_id)
            if s.secs > 0 then sums[#sums + 1] = { t = t, s = s } end
            if s.secs == 0 then
                out[#out + 1] = string.format("%4d %-24s  NO DATA", t.idx, t.name:sub(1, 24))
            else
                local corr = (s.ll * s.rr > 0) and (s.lr / math.sqrt(s.ll * s.rr)) or 1
                out[#out + 1] = string.format("%4d %-24s %5d  %4d-%-5d %9d  %6.1f %6.1f  %5.2f",
                    t.idx, t.name:sub(1, 24), s.secs, s.first, s.last, s.samples,
                    level_db(s.peak), lufs(s.ke / s.samples), corr)
            end
        end

        -- 15 band levels (mid signal, dB, calibrated to the energy between the band edges) + sum-of-bands vs broadband check
        local names, hdr = {}, " idx "
        for b = 1, 15 do
            local fc = math.sqrt(B15_EDGES[b] * B15_EDGES[b + 1])
            local label = fc >= 1000 and (string.format("%.3g", fc / 1000) .. "k") or string.format("%.3g", fc)
            hdr = hdr .. string.format("%6s", label)
            names[#names + 1] = string.format("%s %g-%g Hz", B15_NAMES[b], B15_EDGES[b], B15_EDGES[b + 1])
        end
        out[#out + 1] = "\nBands: " .. table.concat(names, " | ")
        out[#out + 1] = hdr .. "  sum-bb  subC"
        for _, e in ipairs(sums) do
            local s, line = e.s, string.format("%4d ", e.t.idx)
            local lin = 0
            for b = 1, 15 do
                line = line .. string.format("%6.1f", convert_energy_to_db(s.bands[b], s.samples, offsets[b]))
                lin = lin + s.bands[b] * 10 ^ (offsets[b] / 10)
            end
            local bb = (s.ll + s.rr + 2 * s.lr) / 4 -- broadband mid energy
            local delta = (lin > 0 and bb > 0) and 10 * math.log(lin / bb, 10) or 0
            local subc = (s.sub_ll * s.sub_rr > 0) and s.sub_lr / math.sqrt(s.sub_ll * s.sub_rr) or 1
            out[#out + 1] = line .. string.format("  %6.2f %5.2f", delta, subc)
        end

        -- Stage 3: short-window dynamics (crest over active seconds, loudest 100 ms, active share, clipped frames)
        local function num(v, w) return v and string.format("%" .. w .. ".1f", v) or string.format("%" .. w .. "s", "n/a") end
        out[#out + 1] = "\nDYNAMICS (crest dB: all = overall peak - overall rms, med/p90 = per-second over active seconds)"
        out[#out + 1] = " idx name                  crest(all) crest(med) crest(p90) loud100(dB) loudK100(LUFS) active%  clips"
        local viol_loud, viol_act = 0, 0
        for _, e in ipairs(sums) do
            local s = e.s
            local rms_all = level_db(math.sqrt((s.ll + s.rr) / (2 * math.max(s.samples, 1))))
            out[#out + 1] = string.format("%4d %-24s %s %s %s %s %s %s %6d", e.t.idx, e.t.name:sub(1, 24),
                num(level_db(s.peak) - rms_all, 10), num(s.crest_med, 10), num(s.crest_p90, 10),
                num(s.loud100_db, 11), num(s.loudk100, 14), num(s.act_pct, 7), s.clips)
            viol_loud, viol_act = viol_loud + s.viol_loud, viol_act + s.viol_act
        end
        out[#out + 1] = string.format("self-check: loudest100<rms violations %d, active>eligible violations %d", viol_loud, viol_act)

        local m = summarize_master(max_sec, run_id)
        local master_fader = level_db(reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "D_VOL"))
        out[#out + 1] = string.format("\nMASTER (pre-fader, fader = %.1f dB): valid 100 ms blocks %d | integrated %.1f LUFS | max momentary %.1f | max short-term %.1f",
            master_fader, m.valid_blocks, m.integrated, m.max_m, m.max_s)
        -- Stage 3: max 100 ms K level (blocks with at least half of 100 ms), master peak/clips from the header slots
        local max_100 = -144.0
        for k = 0, math.min(18000, max_sec * 10) - 1 do
            local b = MA_MBASE + k * MA_MSTRIDE
            local cnt = reaper.gmem_read(b + 1)
            if reaper.gmem_read(b + 2) == run_id and cnt >= 0.05 * jsfx_sr then
                max_100 = math.max(max_100, lufs(reaper.gmem_read(b) / cnt))
            end
        end
        local stamped = reaper.gmem_read(MA_H_MSTAMP) == run_id
        out[#out + 1] = string.format("  max 100 ms K %.1f LUFS | peak %.1f dBFS post-fader | clip frames %s (|sample| >= %.2f post-fader) | master fader automation ignored",
            max_100, stamped and (level_db(reaper.gmem_read(MA_H_MPEAK)) + master_fader) or -144.0,
            stamped and string.format("%d", reaper.gmem_read(MA_H_MCLIPS)) or "n/a", MA_CLIP_THRESHOLD)
        if m.samples > 0 then
            local mline, sline = "  mid ", " side "
            for b = 1, 15 do
                mline = mline .. string.format("%6.1f", convert_energy_to_db(m.mid[b], m.samples, offsets[b]))
                sline = sline .. string.format("%6.1f", convert_energy_to_db(m.side[b], m.samples, offsets[b]))
            end
            out[#out + 1] = hdr .. "\n" .. mline .. "\n" .. sline
        end

        if compare then
            local lua_m = analyze_region(find_new_tracks(old_guids), region, DEBUG_DURATION)
            if not lua_m then error("Lua DSP found no rendered item for the region", 0) end
            local fader_db = level_db(reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "D_VOL"))
            print_dsp_comparison(out, region, run_id, lua_m, win0, win1, fader_db)
        end
    end)

    -- Cleanup ALWAYS runs (success, error or cancelled render)
    reaper.gmem_write(6, 0)
    remove_all_analyzers()
    remove_analyzer_file()
    reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", render_opts, true)
    if compare then
        for _, trk in ipairs(find_new_tracks(old_guids)) do reaper.DeleteTrack(trk) end
    end
    reaper.UpdateArrange()

	local block_name = "Mix Assistant temp collection"
    reaper.Undo_EndBlock2(0, block_name, -1)
    if reaper.Undo_CanUndo2(0) == block_name then reaper.Undo_DoUndo2(0) end

    if not ok then out[#out + 1] = "ERROR: " .. tostring(err) end
    reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
end

-- ==============================================================================
-- 11. UNIFIED CHATBOX & WORKFLOW CONTROLLER
-- ==============================================================================

local function render_role_badge(ctx, label, bg_color, text_color, id)
    reaper.ImGui_Dummy(ctx, 0, 4) -- Healthy spacing above badge

    -- Invert colors: Apply colored background and dark text
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        bg_color)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), bg_color)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  bg_color)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          text_color)

    -- Rounded corners and healthy internal top/bottom padding (3px vertical, 8px horizontal)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 8, 3)

    -- Render as a static pill badge (using unique ID so ImGui doesn't conflict)
    reaper.ImGui_Button(ctx, label .. "##badge_" .. tostring(id))

    reaper.ImGui_PopStyleVar(ctx, 2)
    reaper.ImGui_PopStyleColor(ctx, 4)

    reaper.ImGui_Dummy(ctx, 0, 3) -- Healthy spacing below badge
end

--- Dark, full-width section banner (e.g. "SCAN CONFIGURATION & CONTROLS")
local function render_section_header(ctx, label)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x333333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFF33FF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 8, 8)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ButtonTextAlign(), 0.0, 0.5)

    reaper.ImGui_BeginDisabled(ctx, true)
    reaper.ImGui_Button(ctx, label, -1, 0)
    reaper.ImGui_EndDisabled(ctx)

    reaper.ImGui_PopStyleVar(ctx, 2)
    reaper.ImGui_PopStyleColor(ctx, 2)
    reaper.ImGui_Dummy(ctx, 0, 4)
end

--- Strips Markdown bold markers (**text**)
local function strip_bold(text)
    return (text:gsub("%*%*(.-)%*%*", "%1"))
end

--- Converts Markdown text into a list of drawing blocks (header / bullet / number / para / table).
-- ImGui redraws the whole chat every frame, so the text is parsed ONCE per message and the
-- cached blocks are reused, instead of re-running every pattern match on every message 60 times a second.
local function parse_markdown(text)
    local blocks = {}
    if not text or text == "" then return blocks end

    local current_table = nil

    for line in text:gmatch("([^\r\n]*)[\r\n]?") do
        if line ~= "" then
            -- Detect Markdown Table Rows
            if line:match("^%s*|.*|%s*$") then
                -- Skip markdown separator row (e.g., |---|---|)
                if not line:match("^%s*[|%-%s:]+$") then
                    if not current_table then
                        local cols = 0
                        for _ in line:gmatch("|") do cols = cols + 1 end
                        current_table = { kind = "table", cols = math.max(1, cols - 1), rows = {} }
                        table.insert(blocks, current_table)
                    end

                    local cells = {}
                    for cell_text in line:gmatch("|([^|]+)") do
                        if #cells < current_table.cols then
                            table.insert(cells, trim_string(cell_text:gsub("%*%*(.-)%*%*", "%1")))
                        end
                    end
                    table.insert(current_table.rows, cells)
                end
            else
                -- If we were collecting a table and hit a normal line, close the table cleanly
                if current_table then
                    current_table.gap_after = true
                    current_table = nil
                end

                local header_text = line:match("^#+%s*(.+)")
                local bullet_text = line:match("^[%*%-]%s+(.+)")
                local num, item_text = line:match("^(%d+%.)%s+(.+)")

                -- Headers (### Title)
                if header_text then
                    table.insert(blocks, { kind = "header", text = header_text })
                -- Bullet points (- item or * item)
                elseif bullet_text then
                    table.insert(blocks, { kind = "bullet", text = strip_bold(bullet_text) })
                -- Numbered lists (1. Directive)
                elseif num then
                    table.insert(blocks, { kind = "number", num = num, text = strip_bold(item_text) })
                -- Regular paragraph text
                else
                    table.insert(blocks, { kind = "para", text = strip_bold(line) })
                end
            end
        end
    end

    return blocks
end

local function draw_markdown_blocks(ctx, blocks, msg_id)
    local table_counter = 0

    for _, block in ipairs(blocks) do
        local kind = block.kind

        if kind == "table" then
            table_counter = table_counter + 1
            local flags = reaper.ImGui_TableFlags_Borders()
                        | reaper.ImGui_TableFlags_RowBg()
                        | reaper.ImGui_TableFlags_SizingFixedFit()
                        | reaper.ImGui_TableFlags_NoSavedSettings()

            local table_id = "MDTable_" .. tostring(msg_id or 0) .. "_" .. table_counter
            if reaper.ImGui_BeginTable(ctx, table_id, block.cols, flags) then
                for c = 0, block.cols - 1 do
                    reaper.ImGui_TableSetupColumn(ctx, "Col" .. c)
                end
                for _, cells in ipairs(block.rows) do
                    reaper.ImGui_TableNextRow(ctx)
                    for col_idx, cell in ipairs(cells) do
                        reaper.ImGui_TableSetColumnIndex(ctx, col_idx - 1)
                        reaper.ImGui_Text(ctx, cell)
                    end
                end
                reaper.ImGui_EndTable(ctx)
                if block.gap_after then reaper.ImGui_Dummy(ctx, 0, 8) end
            end

        elseif kind == "header" then
            reaper.ImGui_Dummy(ctx, 0, 4)
            reaper.ImGui_TextColored(ctx, 0xFFD54FFF, "▶  " .. block.text)
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Dummy(ctx, 0, 2)

        elseif kind == "bullet" then
            reaper.ImGui_Bullet(ctx)
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_TextWrapped(ctx, block.text)

        elseif kind == "number" then
            reaper.ImGui_TextColored(ctx, 0x4FC3F7FF, block.num)
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_TextWrapped(ctx, block.text)

        else
            reaper.ImGui_TextWrapped(ctx, block.text)
        end
    end
end

--- Draws a chat message's Markdown (parsed lazily, then cached on the message itself).
local function render_markdown_text(ctx, msg, text, msg_id)
    msg.md_blocks = msg.md_blocks or parse_markdown(text)
    draw_markdown_blocks(ctx, msg.md_blocks, msg_id)
end

local chat_history = {}
local chat_input_text = ""
local report_saved_path = nil
local scroll_to_bottom = false

local TARGET_DESCRIPTIONS = {
    [1] = "Drums & Bass",
    [2] = "Instruments",
    [3] = "Vocals",
    [4] = "Full Mix",
    [5] = "Soloed Tracks Only"
}

local function run_fresh_scan(target_mode, model_choice, mute_parallels, bypass_master_fx, duration_pref, output_api)
    local target_name = TARGET_DESCRIPTIONS[target_mode] or "Full Mix"
    local selected_model = get_model_name(model_choice)

    chat_history = {}
    local target_tracks = save_and_apply_mix_state(target_mode, mute_parallels, bypass_master_fx)

    -- OPTIMIZATION: Only grab arrangement markers before render (instantaneous)
    local song_regions = get_arrangement_markers()

    local tracks_before = reaper.CountTracks(0)
    local pre_render_guids = {}
    for i = 0, tracks_before - 1 do
        local trk = reaper.GetTrack(0, i)
        if trk then pre_render_guids[reaper.GetTrackGUID(trk)] = true end
    end

    -- Automatically turn ON "Add rendered items to new tracks" in REAPER
    local current_opts = math.floor(reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, false))
    reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", current_opts | 1, true)

    reaper.Main_OnCommand(42230, 0)

    -- 1. Receive dsp_error as the 3rd return value
    local audio_metrics, rendered_tracks, dsp_error = analyze_ghost_render(song_regions, duration_pref, tracks_before, pre_render_guids)

    -- 2. If analysis failed, evaluate dsp_error to decide what to show the user
    if not audio_metrics then
        if rendered_tracks then
            for _, trk in ipairs(rendered_tracks) do reaper.DeleteTrack(trk) end
        end

        -- Restore tracks, but keep Master FX intact if already active
        restore_mix_state()

        -- CASE A: User aborted the render
        if dsp_error == "CANCELLED" or (dsp_error and dsp_error:lower():find("cancel")) then
            table.insert(chat_history, {
                role = "alert",
                content = "⚠️ Scan aborted: Render was cancelled by user. Mix state restored."
            })

        -- CASE B: Real error (e.g. checkbox missing, empty bounds, silent audio)
        else
            table.insert(chat_history, {
                role = "alert",
                content = "❌ " .. tostring(dsp_error or "DSP Processing failed.")
            })
        end

        scroll_to_bottom = true
        return false
    end

    -- Render succeeded! Extract YAML now while target tracks are still isolated
    local project_yaml = extract_full_project_yaml()

    -- Automatically undo the render to purge the track AND clear the undo stack
    local last_undo = reaper.Undo_CanUndo2(0)
    if last_undo and (last_undo:lower():find("render") or last_undo:lower():find("media")) then
        reaper.Undo_DoUndo2(0)
    else
        if rendered_tracks then
            for _, trk in ipairs(rendered_tracks) do reaper.DeleteTrack(trk) end
        end
    end

    restore_mix_state()

    -- Stage 6: Build prompt & export
    local full_prompt = build_full_prompt(project_yaml, audio_metrics, target_name, target_tracks)
    report_saved_path = save_prompt_to_txt(full_prompt, target_name)
    save_tables_to_html(audio_metrics, report_saved_path, target_name)

    -- Populate UI Tables
    local initial_ui_msg = "Please analyze the mix for: **" .. target_name .. "**.\n"
    if target_mode ~= 4 and target_tracks and #target_tracks > 0 then
        initial_ui_msg = initial_ui_msg .. "\n**Active Tracks:**\n" .. table.concat(target_tracks, ", ") .. "\n"
    elseif target_mode == 4 then
        initial_ui_msg = initial_ui_msg .. " *(All tracks included).* \n"
    end

    -- =====================================================================
    -- DYNAMIC METRICS TABLES FOR GUI (Splitting into 2 tables for neatness)
    -- =====================================================================
    initial_ui_msg = initial_ui_msg .. "\n### " .. TABLE_TITLES[1] .. "\n" .. build_markdown_table(DYNAMICS_COLUMNS, audio_metrics)
    initial_ui_msg = initial_ui_msg .. "\n### " .. TABLE_TITLES[2] .. "\n" .. build_markdown_table(TONAL_COLUMNS, audio_metrics)

    table.insert(chat_history, { role = "user", content = full_prompt, display_content = initial_ui_msg })

    if output_api then
        local reply = ask_deep_seek(chat_history, selected_model)
        table.insert(chat_history, { role = "assistant", content = reply })
        fetch_deep_seek_balance()
    else
        table.insert(chat_history, { role = "assistant", content = "Analysis saved to file:\n" .. (report_saved_path or "") })
    end

    scroll_to_bottom = true
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

-- Combo-box item lists and the "Duration" -> seconds map (0 = analyze the full region)
local TARGET_ITEMS = "Drums & Bass\0Instruments (No Drums/Bass/Vox)\0Vocals\0Full Mix\0Soloed Tracks Only\0\0"
local MODEL_ITEMS = "DeepSeek V4 Pro (Flagship Reasoning)\0DeepSeek Flash (Fast / Low-Cost)\0\0"
local DURATION_ITEMS = "10 Seconds\0" .. "20 Seconds\0" .. "Full Region\0\0"
local DURATION_SECONDS = { [0] = 10, [1] = 20, [2] = 0 }

local function main()
    -- Query live balance immediately upon launching the script
    fetch_deep_seek_balance()

    local ctx = reaper.ImGui_CreateContext("AI_Mix_Assistant")

    -- Load fixed-width font for chat
    local font_name = IS_WINDOWS and "Consolas" or "Menlo"
    local chat_font = nil

    if reaper.ImGui_CreateFont then
        chat_font = reaper.ImGui_CreateFont(font_name)
        reaper.ImGui_Attach(ctx, chat_font)
    end

    -- Universal helper: handles ReaImGui 0.10+ (3 args) and older versions (2 args)
    local function push_chat_font(size)
        if chat_font then
            local s = size or 15
            local ok = pcall(reaper.ImGui_PushFont, ctx, chat_font, s)
            if not ok then
                pcall(reaper.ImGui_PushFont, ctx, chat_font)
            end
        end
    end

    local function pop_chat_font()
        if chat_font then
            pcall(reaper.ImGui_PopFont, ctx)
        end
    end
    -- =========================================================

    local target_idx = 3
    local model_idx = 0
    local mute_parallels = false
    local bypass_master_fx = false
    local duration_idx = 0
    local output_api = true

    local scan_state = 0

    local function loop()
        poll_deep_seek_balance()

        reaper.ImGui_SetNextWindowSize(ctx, 720, 680, reaper.ImGui_Cond_FirstUseEver())
        local window_flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_TopMost()
        local visible, open = reaper.ImGui_Begin(ctx, "Mix and Master Assistant", true, window_flags)

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

            local _ -- throw-away for ImGui's 'changed' return values (keeps them out of the global scope)

            -- SCAN SETTINGS PANEL
            render_section_header(ctx, "  SCAN CONFIGURATION & CONTROLS")

            _, target_idx = reaper.ImGui_Combo(ctx, "Target", target_idx, TARGET_ITEMS)
            _, mute_parallels = reaper.ImGui_Checkbox(ctx, "Mute Parallels", mute_parallels)
            _, bypass_master_fx = reaper.ImGui_Checkbox(ctx, "Bypass Master FX", bypass_master_fx)
            _, duration_idx = reaper.ImGui_Combo(ctx, "Duration", duration_idx, DURATION_ITEMS)
            _, output_api = reaper.ImGui_Checkbox(ctx, "Query DeepSeek API (Uncheck for TXT only)", output_api)
            _, model_idx = reaper.ImGui_Combo(ctx, "AI Model", model_idx, MODEL_ITEMS)

            reaper.ImGui_Dummy(ctx, 0, 4)

            -- 1. Draw button state based on scan_state
            local is_busy = (scan_state and scan_state > 0)
            if is_busy then reaper.ImGui_BeginDisabled(ctx, true) end

            local btn_label = is_busy and "Scanning in progress..." or "Run Fresh Scan & Reset Chat"
            local btn_clicked = reaper.ImGui_Button(ctx, btn_label, -1, 30)

            if is_busy then reaper.ImGui_EndDisabled(ctx) end
            reaper.ImGui_Separator(ctx)

			if reaper.ImGui_SmallButton(ctx, "JSFX Collection Test (Stage 1)") and not is_busy then
                run_collection_test()
            end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_SmallButton(ctx, "JSFX vs Lua DSP check") and not is_busy then
                run_collection_test(true)
            end

			-- 2. Strict Frame Delay & Click-Absorption Cooldown
            if btn_clicked and not is_busy then
                table.insert(chat_history, {
                    role = "assistant",
                    content = "⏳ *Rendering mix and analyzing peaks & frequencies... please wait.*"
                })
                scroll_to_bottom = true
                scan_state = 1
            elseif scan_state == 1 then scan_state = 2
            elseif scan_state == 2 then scan_state = 3
            elseif scan_state == 3 then
                run_fresh_scan(target_idx + 1, model_idx + 1, mute_parallels, bypass_master_fx, DURATION_SECONDS[duration_idx], output_api)
                scan_state = 4 -- Enter click-absorption cooldown
            elseif scan_state >= 4 and scan_state < 10 then
                scan_state = scan_state + 1 -- Absorb queued OS clicks for 6 frames
            elseif scan_state == 10 then
                scan_state = 0 -- Reset to idle and re-enable button
            end

            -- CHAT HISTORY LOG
            reaper.ImGui_Dummy(ctx, 0, 8)
            render_section_header(ctx, "  CONVERSATION LOG")
            local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
            local scroll_h = math.max(150, avail_h - 70)

            if reaper.ImGui_BeginChild(ctx, "ChatScroll", 0, scroll_h) then
                push_chat_font(15)

                for idx, msg in ipairs(chat_history) do
                    if msg.role == "user" then
                        -- Light Blue background with dark text
                        render_role_badge(ctx, " YOU ", 0x4FC3F7FF, 0x111111FF, idx)
                        render_markdown_text(ctx, msg, msg.display_content or msg.content, idx)

                    elseif msg.role == "assistant" then
                        -- Light Green background with dark text
                        render_role_badge(ctx, " ASSISTANT ", 0x81C784FF, 0x111111FF, idx)
                        render_markdown_text(ctx, msg, msg.content, idx)

                    elseif msg.role == "alert" then
                        -- Red badge (0xEF5350FF) with dark text
                        render_role_badge(ctx, " CANCELLED ", 0xEF5350FF, 0x111111FF, idx)
                        -- Bright red warning text
                        reaper.ImGui_TextColored(ctx, 0xEF5350FF, msg.content)
                    end

                    -- Divider shared by every message type
                    reaper.ImGui_Dummy(ctx, 0, 4)
                    reaper.ImGui_Separator(ctx)
                    reaper.ImGui_Dummy(ctx, 0, 4)
                end

                -- Auto-scroll down to the latest message
                if scroll_to_bottom then
                    reaper.ImGui_SetScrollHereY(ctx, 1.0)
                    scroll_to_bottom = false
                end

                pop_chat_font()
                reaper.ImGui_EndChild(ctx)
            end

            -- FOLLOW-UP INPUT AREA (MULTILINE + BUTTON ONLY)
            reaper.ImGui_Separator(ctx)

            -- Multiline text box with fixed-width font
            -- (Note: ReaImGui does not natively support word-wrap inside input boxes)
            push_chat_font(15)
            local changed, new_text = reaper.ImGui_InputTextMultiline(ctx, "##chat_in", chat_input_text, -95, 52)
            if changed then
                chat_input_text = new_text
            end
            pop_chat_font()

            reaper.ImGui_SameLine(ctx)

            -- Stacked action buttons
            reaper.ImGui_BeginGroup(ctx)
            if reaper.ImGui_Button(ctx, "Send", 85, 24) then
                if trim_string(chat_input_text) ~= "" then
                    local user_msg = chat_input_text
                    chat_input_text = ""
                    send_followup_message(user_msg, model_idx + 1)
                end
            end

            if reaper.ImGui_Button(ctx, "Copy Chat", 85, 24) then
                if #chat_history > 0 then
                    local conversation_lines = {}

                    for _, msg in ipairs(chat_history) do
                        if msg.role == "user" then
                            -- Uses display_content if available (so the track list summary is included)
                            table.insert(conversation_lines, "### YOU:\n" .. (msg.display_content or msg.content))
                        elseif msg.role == "assistant" then
                            table.insert(conversation_lines, "### DEEPSEEK:\n" .. msg.content)
                        end
                    end

                    -- Join the entire conversation separated by clean dividers
                    local full_chat_export = table.concat(conversation_lines, "\n\n" .. string.rep("-", 40) .. "\n\n")
                    reaper.ImGui_SetClipboardText(ctx, full_chat_export)
                end
            end
            reaper.ImGui_EndGroup(ctx)
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
