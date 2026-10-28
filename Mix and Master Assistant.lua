-- ==============================================================================
-- REAPER AI MIX ASSISTANT & SCANNER (v5.0 - FULL READABILITY EDITION)
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

-- DeepSeek API Key (Only needed if sending analysis to DeepSeek)
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

local function get_track_fx_chain(track)
    local num_fx = reaper.TrackFX_GetCount(track)
    if num_fx == 0 then return nil end
    local fx_chain = {}

    for i = 0, num_fx - 1 do
		local _, fx_name = reaper.TrackFX_GetFXName(track, i)
        fx_name = trim_string(fx_name) or "Unknown FX"
        fx_name = fx_name:match(":%s*(.+)") or fx_name
        fx_name = fx_name:gsub("%s*%(.*%)$", "")	-- Uses a greedy match %s*%(.*%)$ to safely catch nested parens like "(Universal Audio (UADx))"
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
            local disabled_prefixes = {}
            local count = 0
            local max_inspect = 1000

            -- -------------------------------------------------------------
            -- PASS 1: Detect disabled modules using standardized keys
            -- -------------------------------------------------------------
            for k = 0, math.min(num_params - 1, max_inspect) do
                local _, param_name = reaper.TrackFX_GetParamName(track, i, k)
                if param_name and param_name ~= "" then
                    -- Sanitize first so spaces/colons become underscores (e.g. "band_3_active")
                    local clean_k = clean_param_key(param_name)

                    if clean_k:find("active") or clean_k:find("enable") or clean_k:find("bypass") then
                        local _, param_val = reaper.TrackFX_GetFormattedParamValue(track, i, k)
                        local v_clean = trim_string(param_val):lower():gsub("%s+", "")

                        local is_off = (v_clean == "off" or v_clean == "0" or v_clean == "false" or v_clean == "disabled")
                        local is_bypassed = (clean_k:find("bypass") and (v_clean == "on" or v_clean == "1" or v_clean == "true"))

                        if is_off or is_bypassed then
                            -- Extract hierarchical prefixes reliably:
                            local prefix = clean_k:match("^(band_%d+_)")
                                        or clean_k:match("^(eq_b%d+_)")
                                        or clean_k:match("^(c%d+_b%d+_)")
                                        or clean_k:match("^(h%d+_)")
                                        or clean_k:match("^(b%d+_)")

                            if prefix then
                                disabled_prefixes[prefix] = true
                            end
                        end
                    end
                end
            end

            -- -------------------------------------------------------------
            -- PASS 2: Extract active parameters, dropping disabled prefixes
            -- -------------------------------------------------------------
            for k = 0, num_params - 1 do
                if k >= max_inspect then break end
                local _, param_name = reaper.TrackFX_GetParamName(track, i, k)
                param_name = trim_string(param_name)

                if is_valid_parameter_name(param_name) then
                    local clean_key = clean_param_key(param_name)
                    local is_in_disabled_band = false

                    -- Check if clean parameter key starts with any disabled prefix
                    for prefix, _ in pairs(disabled_prefixes) do
                        if clean_key:sub(1, #prefix) == prefix then
                            is_in_disabled_band = true
                            break
                        end
                    end

                    -- Only keep parameters from active bands/modules
                    if not is_in_disabled_band then
                        local _, param_value = reaper.TrackFX_GetFormattedParamValue(track, i, k)
                        param_value = trim_string(param_value)

                        if not is_boilerplate(param_name, param_value) then
                            if count < MAX_PLUGIN_PARAMS then
                                params_table[clean_key] = tonumber(param_value) or param_value
                                count = count + 1
                            else
                                break
                            end
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

    project_data.notes = "- any routing send volume omitted is at 0.0 dB unity gain."
    if proj_notes and proj_notes ~= "" then project_data.notes = project_data.notes .. '\n' .. proj_notes end

    local any_soloed = reaper.AnyTrackSolo(0)
    local num_tracks = reaper.CountTracks(0)

    -- Pre-calculate parent folders that actually have children
    local has_children = {}
    for i = 0, num_tracks - 1 do
        local tr = reaper.GetTrack(0, i)
        local p = reaper.GetParentTrack(tr)
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

local function get_track_category(name)
    if type(name) ~= "string" then
        name = ""
    else
        name = trim_string(name):lower()
    end

    -- 99 = Parallel / Rear / NYC Busses
    if name:match("nyc") or name:match("rear") or name:match("parallel") then
        return 99

    -- 1 = Drums & Bass (Drums, Percussion, Kicks, Snares, 808s, Basses)
    elseif name:match("drum") or name:match("kick") or name:match("snare") or
           name:match("hat") or name:match("perc") or name:match("cymbal") or
           name:match("bass") or name:match("808") or name:match("sub") then
        return 1

    -- 3 = Vocals (Lead Vox, Harmonies, BGV, Choirs, Acapellas)
    elseif name:match("vox") or name:match("vocal") or name:match("choir") or
           name:match("lead") or name:match("bgv") or name:match("acap") or
           name:match("harmony") or name:match("chorus") or name:match("backing") then
        return 3

    -- 2 = Instruments (Everything else: Guitars, Keys, Synths, Strings, Horns, FX, Pads)
    else
        return 2
    end
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

local function save_and_apply_mix_state(target_mode, mute_parallels, bypass_master_fx)
    saved_mix_state = { tracks = {}, master_fx = {} }
    local master_track = reaper.GetMasterTrack(0)
    local target_track_names = {}

    -- Backup and bypass master FX
    for fx_idx = 0, reaper.TrackFX_GetCount(master_track) - 1 do
        saved_mix_state.master_fx[fx_idx] = reaper.TrackFX_GetEnabled(master_track, fx_idx)
        if bypass_master_fx then reaper.TrackFX_SetEnabled(master_track, fx_idx, false) end
    end

    -- Backup and set track solos/mutes based STRICTLY on I_SOLO
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        if track then
            local track_guid = reaper.GetTrackGUID(track)
            local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)

            local category = get_effective_track_category(track)
            local display_name = (trim_string(track_name) ~= "") and trim_string(track_name) or ("Track " .. (i + 1))

            local orig_solo = reaper.GetMediaTrackInfo_Value(track, "I_SOLO")
            local orig_mute = reaper.GetMediaTrackInfo_Value(track, "B_MUTE")

            saved_mix_state.tracks[track_guid] = {
                solo = orig_solo,
                mute = orig_mute
            }

            local is_target = false

            -- TARGET MODE 5: "Soloed Tracks Only" -> strictly looks at your REAPER Solo buttons!
            if target_mode == 5 then
                is_target = (orig_solo > 0)
            elseif target_mode ~= 4 then
                -- TARGET MODES 1, 2, 3: Automatic stem category soloing
                is_target = (category == target_mode)
            end

            if target_mode ~= 4 then
                if is_target then
                    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 2) -- Solo-in-place
                    if not is_track_hierarchy_muted(track) then
                        table.insert(target_track_names, display_name)
                    end
                else
                    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
                end
            else
                -- MODE 4: Full Mix -> clear all solos
                reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
            end

            if mute_parallels and category == 99 then
                reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 1)
            end
        end
    end

    return target_track_names
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

--- Traverses up folder hierarchy to verify track is audible (checks both Mutes and Solos).
local function is_track_audible(track)
    local current = track
    while current do
        if reaper.GetMediaTrackInfo_Value(current, "B_MUTE") == 1 then
            return false -- A parent or the track itself is muted
        end
        current = reaper.GetParentTrack(current)
    end

    -- If any track is soloed in REAPER, this track must be soloed (or under a soloed folder) to be audible
    if reaper.AnyTrackSolo(0) then
        local is_soloed = false
        current = track
        while current do
            if reaper.GetMediaTrackInfo_Value(current, "I_SOLO") > 0 then
                is_soloed = true
                break
            end
            current = reaper.GetParentTrack(current)
        end
        if not is_soloed then
            return false
        end
    end

    return true
end

local function get_active_tracks(start_time, end_time, max_tracks)
    local active_tracks = {}
    -- Only loop through tracks that existed BEFORE the render occurred
    local limit = (max_tracks or reaper.CountTracks(0)) - 1

    -- Threshold: Must overlap by at least 100 ms to be considered active
    local MIN_OVERLAP_SECONDS = 0.1

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
                    local item_end = pos + len

                    -- Calculate actual overlap duration between item and section
                    local overlap = math.min(item_end, end_time) - math.max(pos, start_time)

                    if overlap > MIN_OVERLAP_SECONDS then
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
    if not buffer then return nil end

    local accessor = reaper.CreateTakeAudioAccessor(take)
    if not accessor then return nil end

    local ok = reaper.GetAudioAccessorSamples(accessor, SAMPLE_RATE, 2, analyze_start - item_pos, num_samples, buffer)
    reaper.DestroyAudioAccessor(accessor)

    if not ok then return nil end

	-- Convert C++ buffer to a native 1-based Lua table
    local audio_samples = buffer
    if type(buffer) == "userdata" and buffer.table then
        audio_samples = buffer.table()
    end

    if type(audio_samples) ~= "table" then return nil end
    local total_sample_count = #audio_samples
    if total_sample_count < 2 then return nil end

    local peak_left, peak_right = 0, 0
    local sum_squared_mid, sum_squared_side = 0, 0

    -- Human-readable energy accumulators for the 9 frequency bands
    local energy_sub_60hz = 0
    local energy_punch_120hz = 0
    local energy_mud_250hz = 0
    local energy_boxy_500hz = 0
    local energy_core_1khz = 0
    local energy_presence_3khz = 0
    local energy_harsh_6khz = 0
    local energy_sibilance_8khz = 0
    local energy_air_12khz = 0
    local energy_sub_side_channel = 0

    -- Filter Coefficients for the 9 critical bands
    local filter_coeff_sub   = 2 * math.sin(math.pi * 60 / SAMPLE_RATE)
    local filter_coeff_punch = 2 * math.sin(math.pi * 120 / SAMPLE_RATE)
    local filter_coeff_mud   = 2 * math.sin(math.pi * 250 / SAMPLE_RATE)
    local filter_coeff_boxy  = 2 * math.sin(math.pi * 500 / SAMPLE_RATE)
    local filter_coeff_core  = 2 * math.sin(math.pi * 1000 / SAMPLE_RATE)
    local filter_coeff_pres  = 2 * math.sin(math.pi * 3000 / SAMPLE_RATE)
    local filter_coeff_harsh = 2 * math.sin(math.pi * 6000 / SAMPLE_RATE)
    local filter_coeff_sib   = 2 * math.sin(math.pi * 8000 / SAMPLE_RATE)
    local filter_coeff_air   = 2 * math.sin(math.pi * 12000 / SAMPLE_RATE)

    -- Filter state registers (Low-pass and Band-pass nodes for Chamberlin SVF)
    local low_sub, band_sub       = 0, 0
    local low_punch, band_punch   = 0, 0
    local low_mud, band_mud       = 0, 0
    local low_boxy, band_boxy     = 0, 0
    local low_core, band_core     = 0, 0
    local low_pres, band_pres     = 0, 0
    local low_harsh, band_harsh   = 0, 0
    local low_sib, band_sib       = 0, 0
    local low_air, band_air       = 0, 0
    local low_sub_side, band_sub_side = 0, 0

    -- Fast native table loop (audio_samples[1] = L0, audio_samples[2] = R0, ...)
    for i = 1, total_sample_count, 2 do
        local sample_left = audio_samples[i]
        local sample_right = audio_samples[i+1]

        if math.abs(sample_left) > peak_left then peak_left = math.abs(sample_left) end
        if math.abs(sample_right) > peak_right then peak_right = math.abs(sample_right) end

        local mid = (sample_left + sample_right) * 0.5
        local side = (sample_left - sample_right) * 0.5

        sum_squared_mid = sum_squared_mid + (mid * mid)
        sum_squared_side = sum_squared_side + (side * side)

        -- State-Variable Filter executions on Mid channel
        low_sub = low_sub + filter_coeff_sub * band_sub
        band_sub = band_sub + filter_coeff_sub * (mid - low_sub - FILTER_Q * band_sub)
        energy_sub_60hz = energy_sub_60hz + (band_sub * band_sub)

        low_punch = low_punch + filter_coeff_punch * band_punch
        band_punch = band_punch + filter_coeff_punch * (mid - low_punch - FILTER_Q * band_punch)
        energy_punch_120hz = energy_punch_120hz + (band_punch * band_punch)

        low_mud = low_mud + filter_coeff_mud * band_mud
        band_mud = band_mud + filter_coeff_mud * (mid - low_mud - FILTER_Q * band_mud)
        energy_mud_250hz = energy_mud_250hz + (band_mud * band_mud)

        low_boxy = low_boxy + filter_coeff_boxy * band_boxy
        band_boxy = band_boxy + filter_coeff_boxy * (mid - low_boxy - FILTER_Q * band_boxy)
        energy_boxy_500hz = energy_boxy_500hz + (band_boxy * band_boxy)

        low_core = low_core + filter_coeff_core * band_core
        band_core = band_core + filter_coeff_core * (mid - low_core - FILTER_Q * band_core)
        energy_core_1khz = energy_core_1khz + (band_core * band_core)

        low_pres = low_pres + filter_coeff_pres * band_pres
        band_pres = band_pres + filter_coeff_pres * (mid - low_pres - FILTER_Q * band_pres)
        energy_presence_3khz = energy_presence_3khz + (band_pres * band_pres)

        low_harsh = low_harsh + filter_coeff_harsh * band_harsh
        band_harsh = band_harsh + filter_coeff_harsh * (mid - low_harsh - FILTER_Q * band_harsh)
        energy_harsh_6khz = energy_harsh_6khz + (band_harsh * band_harsh)

        low_sib = low_sib + filter_coeff_sib * band_sib
        band_sib = band_sib + filter_coeff_sib * (mid - low_sib - FILTER_Q * band_sib)
        energy_sibilance_8khz = energy_sibilance_8khz + (band_sib * band_sib)

        low_air = low_air + filter_coeff_air * band_air
        band_air = band_air + filter_coeff_air * (mid - low_air - FILTER_Q * band_air)
        energy_air_12khz = energy_air_12khz + (band_air * band_air)

        -- Sub-bass side channel tracking for mono compatibility
        low_sub_side = low_sub_side + filter_coeff_sub * band_sub_side
        band_sub_side = band_sub_side + filter_coeff_sub * (side - low_sub_side - FILTER_Q * band_sub_side)
        energy_sub_side_channel = energy_sub_side_channel + (band_sub_side * band_sub_side)
    end

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

    local sub_energy_total = energy_sub_60hz + energy_sub_side_channel + 0.000001
    local sub_side_percentage = (energy_sub_side_channel / sub_energy_total) * 100

    -- Helper to convert any raw band energy accumulation into absolute dBFS
    local function convert_energy_to_db(energy_sum)
        local band_rms = math.sqrt(energy_sum / num_samples)
        if band_rms <= 1e-7 then return -144.0 end
        return round(20 * math.log(band_rms, 10), 1)
    end

    local sub_energy_total = energy_sub_60hz + energy_sub_side_channel + 0.000001
    local sub_side_percentage = (energy_sub_side_channel / sub_energy_total) * 100

    -- Only flag phase risk if there is actual bass playing (louder than -60 dBFS).
    -- This prevents plugin noise floors or dither in empty regions from triggering a false positive.
    local sub_mono_status = "Safe"
    if convert_energy_to_db(energy_sub_60hz) > -60.0 and sub_side_percentage > 15.0 then
        sub_mono_status = "Phase_Risk"
    end

    return {
        dyn = { peak_db = round(peak_db, 1), rms_db = round(rms_db, 1), crest_db = round(crest_factor, 1) },
        stereo = { width_pct = round(width_pct, 1), sub_mono = sub_mono_status },
        tonal_db = {
            sub60 = convert_energy_to_db(energy_sub_60hz),
            punch120 = convert_energy_to_db(energy_punch_120hz),
            mud250 = convert_energy_to_db(energy_mud_250hz),
            boxy500 = convert_energy_to_db(energy_boxy_500hz),
            mid1k = convert_energy_to_db(energy_core_1khz),
            pres3k = convert_energy_to_db(energy_presence_3khz),
            harsh6k = convert_energy_to_db(energy_harsh_6khz),
            sib8k = convert_energy_to_db(energy_sibilance_8khz),
            air12k = convert_energy_to_db(energy_air_12khz)
        }
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

local function analyze_ghost_render(regions, duration_pref, tracks_before, pre_render_guids)
    local tracks_after = reaper.CountTracks(0)
    local num_new_tracks = tracks_after - tracks_before

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
                local item_count = reaper.CountTrackMediaItems(trk)
                local found_audio = false
                for item_idx = 0, item_count - 1 do
                    local media_item = reaper.GetTrackMediaItem(trk, item_idx)
                    if has_rendered_media_item(media_item) then
                        found_audio = true
                        break
                    end
                end
                if found_audio then
                    table.insert(render_tracks, trk)
                end
            end
        end
    end

    if #render_tracks == 0 then
        if num_new_tracks <= 0 then
            return nil, nil, "Render did not create any new tracks. In REAPER, enable 'Render > Add rendered items to new tracks' before running the analysis."
        end
        return nil, nil, "Render created temporary tracks, but no valid audio items were generated. Check your time selection, mix bounds, and whether 'Render > Add rendered items to new tracks' is enabled."
    end

    local regional_metrics = {}
    local region_counter = 1

    if regions and #regions > 0 then
        for _, region in ipairs(regions) do
            local analyzed = false

            -- Search across all newly rendered tracks and items for this region.
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
                    m.active_trks = get_active_tracks(pos, pos + dur, tracks_before)
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
    local prompt = "=== MIXING & MASTERING DIRECTIVES ===\nYou are an elite, multi-platinum audio mixing and mastering engineer.\n"
    prompt = prompt .. "Focus Target: " .. target_str .. "\n\n"

    prompt = prompt .. "=== TARGET TRACKS ===\n"
    if target_tracks and #target_tracks > 0 then
        prompt = prompt .. "The following tracks are currently active for this specific analysis:\n"
        prompt = prompt .. table.concat(target_tracks, ", ") .. "\n\n"
        prompt = prompt .. "CRITICAL RESTRICTION: Focus YOUR ENTIRE ANALYSIS and plugin recommendations SOLELY on these specific tracks, plus the Master Bus if relevant. Do not critique or suggest parameter changes for any tracks outside this list.\n\n"
    else
        prompt = prompt .. "All active tracks are included in this full mix analysis.\n\n"
    end

    -- UNIFIED INSTRUCTIONS BLOCK
    prompt = prompt .. "=== INSTRUCTIONS FOR ANALYSIS ===\n"
    prompt = prompt .. "1. MACRO-DYNAMICS: Compare Crest Factor and RMS across regions. If dynamic contrast is lacking, pinpoint over-compression in the YAML and specify threshold/ratio adjustments.\n"
    prompt = prompt .. "2. LOW/MID FREQUENCY BALANCE: Scrutinize Sub (60Hz), Punch (120Hz), Mud (250Hz), and Boxy (500Hz). Locate masking in the project tracks and suggest surgical EQ cuts.\n"
    prompt = prompt .. "3. HIGH FREQUENCY INTEGRITY: Differentiate Harshness (6kHz) from Sibilance (8kHz). Look for abrasive saturation or identify tracks requiring a De-Esser.\n"
    prompt = prompt .. "4. STEREO & SUB-MONO INTEGRITY: Check 'width_pct' and 'sub_mono'. If 'Phase_Risk' is flagged on sub-bass, immediately identify which low-end tracks have wide side-channel information and advise how to high-pass or mono their sides.\n"
    prompt = prompt .. "6. PRECISION: Quote exact track names, plugin names, and parameter settings as formatted in the project YAML.\n\n"
    prompt = prompt .. "5. CONTEXT AWARENESS: Look closely at 'active_trks' for each region. ONLY critique or suggest changes to tracks that are actively playing in that specific region. You should not create a new CONTEXT AWARE section if you already made all suggestions you would list here.\n"

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

local function shell_quote_for_curl(value)
    local text = tostring(value or "")
    local os_name = reaper.GetOS()

    if os_name:match("Win") then
        text = text:gsub('"', '""')
        return '"' .. text .. '"'
    end

    text = text:gsub("\\", "\\\\")
    text = text:gsub("'", "'\\''")
    return "'" .. text .. "'"
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

    local curl_command = curl_bin .. ' -sS -D "' .. temp_response_path .. '.headers" -o "' .. temp_response_path .. '" -X POST https://api.deepseek.com/chat/completions ' ..
                         '-H ' .. shell_quote_for_curl('Authorization: Bearer ' .. API_KEY) .. ' ' ..
                         '-H ' .. shell_quote_for_curl('Content-Type: application/json') .. ' ' ..
                         '-H ' .. shell_quote_for_curl('Expect:') .. ' ' ..
                         '-d ' .. shell_quote_for_curl('@' .. temp_json_path)

    -- Windows cmd.exe quote-stripping protection
    local os_name = reaper.GetOS()
    if os_name:match("Win") then
        curl_command = '"' .. curl_command .. '"'
    end

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

    local header_file = io.open(temp_response_path .. ".headers", "r")
    local headers = ""
    if header_file then
        headers = header_file:read("*a")
        header_file:close()
    end

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

    local os_name = reaper.GetOS()
    local curl_cmd = curl_bin .. ' -sS -H ' .. shell_quote_for_curl('Authorization: Bearer ' .. API_KEY) ..
                     ' https://api.deepseek.com/user/balance'

    -- On Windows, wrap the command in an extra pair of quotes so cmd.exe doesn't strip inner quotes.
    -- Append 2>&1 so stderr errors (like network/certificate issues) are captured instead of lost.
    local popen_cmd = os_name:match("Win") and ('"' .. curl_cmd .. ' 2>&1"') or (curl_cmd .. ' 2>&1')
    local handle = io.popen(popen_cmd)
    local raw = handle and handle:read("*a") or ""
    if handle then handle:close() end

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
        -- DeepSeek balance is nested inside balance_infos[1]
        local info = (data.balance_infos and data.balance_infos[1]) or data
        total_balance = info.total_balance or info.total or info.balance
        currency = info.currency or currency
    end

    -- 2. Direct regex fallback (guarantees extraction even if JSON structure varies)
    if not total_balance then
        total_balance = raw:match('"total_balance"%s*:%s*"(.-)"')
        currency = raw:match('"currency"%s*:%s*"(.-)"') or currency
    end

    if total_balance then
        local symbol = (currency == "USD") and "$" or "¥"
        user_balance_str = symbol .. tostring(total_balance)
    else
        user_balance_str = "Check Failed"
        -- Print exact server output to the console for instant diagnostics
        reaper.ShowConsoleMsg("\n[DeepSeek Balance Error]\nRaw Server Output:\n" .. tostring(raw) .. "\n")
    end
end

-- ==============================================================================
-- 10. UNIFIED CHATBOX & WORKFLOW CONTROLLER
-- ==============================================================================

local function render_markdown_text(ctx, text)
    if not text or text == "" then return end

    local in_table = false
    local table_counter = 0

    for line in text:gmatch("([^\r\n]*)[\r\n]?") do
        if line ~= "" then
            -- Detect Markdown Table Rows
            if line:match("^%s*|.*|%s*$") then
                -- FIX: Strictly match ONLY markdown separator rows (e.g., |---|---|)
                -- Prevents negative dB values (e.g., -12.0) from being deleted
                if line:match("^%s*[|%-%s:]+$") then
                    -- Skip the markdown table separator row
                else
                    if not in_table then
                        table_counter = table_counter + 1
                        local cols = 0
                        for _ in line:gmatch("|") do cols = cols + 1 end
                        cols = cols - 1

						-- Start Native ReaImGui Table with a UNIQUE ID. Columns auto-size intelligently
                        local flags = reaper.ImGui_TableFlags_Borders() | reaper.ImGui_TableFlags_RowBg() | reaper.ImGui_TableFlags_SizingStretchProp()
                        if reaper.ImGui_BeginTable(ctx, "MarkdownTable_" .. table_counter, cols, flags) then
                            in_table = true
                            for c = 0, cols - 1 do
                                reaper.ImGui_TableSetupColumn(ctx, "Col" .. c)
                            end
                        end
                    end

                    if in_table then
                        reaper.ImGui_TableNextRow(ctx)
                        local col_idx = 0
                        for cell_text in line:gmatch("|([^|]+)") do
                            reaper.ImGui_TableSetColumnIndex(ctx, col_idx)
                            local clean_cell = trim_string(cell_text:gsub("%*%*(.-)%*%*", "%1"))
                            -- Use TextWrapped instead of Text so long region names or values never clip
                            reaper.ImGui_TextWrapped(ctx, clean_cell)
                            col_idx = col_idx + 1
                        end
                    end
                end
            else
                -- If we were drawing a table and hit a normal line, close the table cleanly
                if in_table then
                    reaper.ImGui_EndTable(ctx)
                    in_table = false
                    reaper.ImGui_Dummy(ctx, 0, 8)
                end

                -- Headers (### Title)
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

                -- Numbered lists (1. Directive)
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

    if in_table then
        reaper.ImGui_EndTable(ctx)
    end
end

local chat_history = {}
local chat_input_text = ""
local report_saved_path = nil
local scroll_to_bottom = false

local function run_fresh_scan(target_mode, model_choice, mute_parallels, bypass_master_fx, duration_pref, output_api)
	local target_descriptions = {
        [1] = "Drums & Bass",
        [2] = "Instruments",
        [3] = "Vocals",
        [4] = "Full Mix",
        [5] = "Soloed Tracks Only"
    }
	local target_name = target_descriptions[target_mode] or "Full Mix"
    local selected_model = get_model_name(model_choice)

    -- 1. Scan and isolate
    local target_tracks = save_and_apply_mix_state(target_mode, mute_parallels, bypass_master_fx)
    local project_yaml, song_regions = extract_full_project_yaml()

    -- 2. Render and analyze
    local tracks_before = reaper.CountTracks(0)
    local pre_render_guids = {}
    for i = 0, tracks_before - 1 do
        local trk = reaper.GetTrack(0, i)
        if trk then pre_render_guids[reaper.GetTrackGUID(trk)] = true end
    end

    reaper.Main_OnCommand(42230, 0)
    local audio_metrics, rendered_tracks, dsp_error = analyze_ghost_render(song_regions, duration_pref, tracks_before, pre_render_guids)

    if rendered_tracks then
        for _, trk in ipairs(rendered_tracks) do reaper.DeleteTrack(trk) end
    end
    restore_mix_state()

    if not audio_metrics then
        reaper.ShowMessageBox(dsp_error or "DSP Processing failed.", "Analysis Error", 0)
        return false
    end

    -- 3. Save raw file
    local full_prompt = build_full_prompt(project_yaml, audio_metrics, target_name, target_tracks)
    report_saved_path = save_prompt_to_txt(full_prompt, target_name)

    -- 4. Initialize chat history for DeepSeek Prompt Caching
    local initial_ui_msg = "Please analyze the mix for: **" .. target_name .. "**.\n"
    if target_mode ~= 4 and target_tracks and #target_tracks > 0 then
        initial_ui_msg = initial_ui_msg .. "\n**Active Tracks:**\n" .. table.concat(target_tracks, ", ") .. "\n"
    elseif target_mode == 4 then
        initial_ui_msg = initial_ui_msg .. " *(All tracks included).* \n"
    end

    -- =====================================================================
    -- DYNAMIC METRICS TABLES FOR GUI (Splitting into 2 tables for neatness)
    -- =====================================================================
    initial_ui_msg = initial_ui_msg .. "\n### 1. Macro-Dynamics & Stereo Summary\n"
    initial_ui_msg = initial_ui_msg .. "| Region | Peak | RMS | Crest | Width | Sub-Mono |\n"
    initial_ui_msg = initial_ui_msg .. "|---|---|---|---|---|---|\n"

    local tonal_msg = "\n### 2. Tonal Balance Summary (dBFS)\n"
    tonal_msg = tonal_msg .. "| Region | Sub | Punch | Mud | Boxy | Core | Pres | Harsh | Sib | Air |\n"
    tonal_msg = tonal_msg .. "|---|---|---|---|---|---|---|---|---|---|\n"

    local sorted_regions = {}
    for r_key in pairs(audio_metrics) do table.insert(sorted_regions, r_key) end
    table.sort(sorted_regions)

    for _, r_key in ipairs(sorted_regions) do
        local m = audio_metrics[r_key]
        local clean_name = r_key:gsub("^%d+_", ""):gsub("_", " ")
        local phase_status = m.stereo.sub_mono == "Phase_Risk" and "Risk" or "Safe"

        -- Populate Dynamics Table
        initial_ui_msg = initial_ui_msg .. string.format("| %s | %.1f | %.1f | %.1f | %.0f%% | %s |\n",
            clean_name, m.dyn.peak_db, m.dyn.rms_db, m.dyn.crest_db, m.stereo.width_pct, phase_status)

        -- Populate Tonal Balance Table
        tonal_msg = tonal_msg .. string.format("| %s | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f |\n",
            clean_name, m.tonal_db.sub60, m.tonal_db.punch120, m.tonal_db.mud250, m.tonal_db.boxy500, m.tonal_db.mid1k, m.tonal_db.pres3k, m.tonal_db.harsh6k, m.tonal_db.sib8k, m.tonal_db.air12k)
    end
    initial_ui_msg = initial_ui_msg .. tonal_msg

    chat_history = {
        { role = "system", content = full_prompt },
        { role = "user", content = "Perform full mix analysis as instructed.", display_content = initial_ui_msg }
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

    -- Load fixed-width font for chat
    local os_name = reaper.GetOS()
    local font_name = os_name:match("Win") and "Consolas" or "Menlo"
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
    local mute_parallels = true
    local bypass_master_fx = true
    local duration_idx = 0
    local output_api = true

    local target_items = "Drums & Bass\0Instruments (No Drums/Bass/Vox)\0Vocals\0Full Mix\0Soloed Tracks Only\0\0"
    local model_items = "DeepSeek V4 Pro (Flagship Reasoning)\0DeepSeek Flash (Fast / Low-Cost)\0\0"
    local duration_items = "10 Seconds\0" .. "20 Seconds\0" .. "Full Region\0\0"

    local function loop()
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

            -- SCAN SETTINGS PANEL
            if reaper.ImGui_CollapsingHeader(ctx, "Scan Configuration & Controls") then
                _, target_idx = reaper.ImGui_Combo(ctx, "Target", target_idx, target_items)
                _, mute_parallels = reaper.ImGui_Checkbox(ctx, "Mute Parallels", mute_parallels)
                _, bypass_master_fx = reaper.ImGui_Checkbox(ctx, "Bypass Master FX", bypass_master_fx)
                _, duration_idx = reaper.ImGui_Combo(ctx, "Duration", duration_idx, duration_items)
                _, output_api = reaper.ImGui_Checkbox(ctx, "Query DeepSeek API (Uncheck for TXT only)", output_api)
                _, model_idx = reaper.ImGui_Combo(ctx, "AI Model", model_idx, model_items)

                reaper.ImGui_Dummy(ctx, 0, 4)

                if reaper.ImGui_Button(ctx, "Run Fresh Scan & Reset Chat", -1, 30) then
                    local dur_map = { [0] = 10, [1] = 20, [2] = 0 }
                    run_fresh_scan(target_idx + 1, model_idx + 1, mute_parallels, bypass_master_fx, dur_map[duration_idx], output_api)
                end
                reaper.ImGui_Separator(ctx)
            end

            -- CHAT HISTORY LOG
            reaper.ImGui_TextColored(ctx, 0xFFD54FFF, "Conversation Log:")
            local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
            local scroll_h = math.max(150, avail_h - 70)

            if reaper.ImGui_BeginChild(ctx, "ChatScroll", 0, scroll_h) then
                push_chat_font(15)

                for _, msg in ipairs(chat_history) do
                    if msg.role == "user" then
                        reaper.ImGui_TextColored(ctx, 0x4FC3F7FF, "YOU: ")
                        local text_to_show = msg.display_content or msg.content
                        render_markdown_text(ctx, text_to_show)
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

                pop_chat_font()
                reaper.ImGui_EndChild(ctx)
            end

            -- FOLLOW-UP INPUT AREA (MULTILINE + BUTTON ONLY)
            reaper.ImGui_Separator(ctx)

            -- Multiline text box with fixed-width font
            push_chat_font(15)
            _, chat_input_text = reaper.ImGui_InputTextMultiline(ctx, "##chat_in", chat_input_text, -95, 52)
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
							local user_text = msg.display_content or msg.content
							table.insert(conversation_lines, "### YOU:\n" .. user_text)
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