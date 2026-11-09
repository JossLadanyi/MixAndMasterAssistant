-- ==============================================================================
-- REAPER AI MIX & MASTER ASSISTANT (v6.0)
-- ==============================================================================
-- What it does:
-- 1. Collect Project Info: ONE render of the project into a temporary folder. During it,
--    analyzer JSFX on hidden copies of the tracks ("phantom" tracks, post-fader) and on the
--    master measure the mix: per track and second (level, peak, crest, 15 frequency bands,
--    stereo, sub-mono, clips, when the track plays), per 100 ms on the master (loudness,
--    15 mid + 15 side bands, correlation, sub-mono, balance, peak, clips) and the master input.
--    Everything is removed again afterwards (one undo block), the render settings restored,
--    the temporary folder emptied.
-- 2. Compact YAML of the routing and FX settings, plus the measured data per region.
-- 3. Focus prompts (Whole Song, Vocals, Drums & Bass, ..., Low End, Mids, ...), sent to
--    DeepSeek (Flash default, or Pro; optional Think) or copied for a web chat; the prompt is
--    also saved as AI_Mix_Prompt_JSFX_<focus>.txt next to the project. Send Track Detail asks
--    about selected tracks in the same chat.
-- 4. Optional MixAssistant_plugin_notes.txt next to the script: short notes per plugin and
--    settings to drop from the YAML (fewer tokens).
-- Limit: tracks x song length must fit in the analyzer memory (e.g. 128 tracks for about
-- 30 min, 49 tracks for about 68 min); Collect says so before changing anything.
-- ==============================================================================
-- 1. What Needs to Be Installed
-- - REAPER (v6 or above),
-- - ReaImGui,
-- - SWS (recommended: lets the script close the render window by itself),
-- - DeepSeek API key (only for Send): first line of "apikey.txt" next to this script.
--   Copy Project Info works without it.
-- 2. Render Settings (nothing to set up)
--   Collect sets Source (Master mix), Bounds (Entire project), the folder, the file name,
--   "add to project" and auto-close itself for its render and restores your settings afterwards.
--   Tip: set the audio device to the project sample rate (the analyzers run at the device rate);
--   Collect warns when the two differ.
-- ==============================================================================

local reaper = reaper

-- Environment lookups that never change while the script runs (resolved once)
local IS_WINDOWS = reaper.GetOS():match("Win") ~= nil
local PATH_SEPARATOR = package.config:sub(1, 1) or "/"

-- ==============================================================================
-- 1. GLOBAL CONFIGURATION & TUNING
-- ==============================================================================

-- DeepSeek API Key (Only needed if sending analysis to DeepSeek): first line of "apikey.txt" next to this script
local API_KEY = (function()
    local dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
    local f = io.open(dir .. "apikey.txt", "r")
    if not f then return "" end
    local key = (f:read("l") or ""):match("^%s*(.-)%s*$")
    f:close()
    return key
end)()

-- Maximum plugin parameters to capture per effect (Balances precision vs tokens)
local MAX_PLUGIN_PARAMS = 128

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
    if name_lower == "delta" and val_clean == DEFAULT_SETTINGS.plugin.delta then return true end -- REAPER's own delta solo switch, off
    -- task 5e2: solo, delta and master bypass switches that are off say nothing; one that is on stays visible
    if val_clean == "off" then
        local squeezed = name_lower:gsub("[%s_]+", "")
        if squeezed:find("solo", 1, true) or squeezed:find("delta", 1, true) or squeezed:find("masterbypass", 1, true) then return true end
    end

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
            if type(v) == "table" and v.__line then -- task 5e2: an already formatted one-line plugin entry
                out[#out + 1] = pad .. "- " .. v.__line .. "\n"
            elseif INLINE_ARRAY_PARENTS[parent_key] and type(v) == "table" then
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

local function get_all_connections(keep, ptrs) -- only the "sidechain" label is kept (task 4e: the other purposes were guesses); keep (task 4f.7b): only sends from or to these tracks; ptrs (task 4g.3): ptrs[conn] = { source, destination track }
    local connections = {}
    local num_tracks = reaper.CountTracks(0)
    local track_lookup = {}

    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        track_lookup[track] = get_track_identity(track)
    end

    for i = 0, num_tracks - 1 do
        local src_track = reaper.GetTrack(0, i)

        for s = 0, reaper.GetTrackNumSends(src_track, 0) - 1 do
            local dest_track = reaper.GetTrackSendInfo_Value(src_track, 0, s, "P_DESTTRACK")
            if dest_track and dest_track ~= 0 and (not keep or keep[src_track] or keep[dest_track]) then
                local conn = { src = track_lookup[src_track], dst = track_lookup[dest_track] or "Unknown Track" }

                local dst_chan = math.floor(reaper.GetTrackSendInfo_Value(src_track, 0, s, "I_DSTCHAN"))
                local chan_index = dst_chan & 1023
                -- a mono send (mono source, or "mix to mono" flag 1024) lands on ONE channel: "3", not "3/4"
                local mono = (dst_chan & 1024) ~= 0 or (math.floor(reaper.GetTrackSendInfo_Value(src_track, 0, s, "I_SRCCHAN")) >> 10) == 1
                local dst_ch_str = mono and tostring(chan_index + 1) or string.format("%d/%d", chan_index + 1, chan_index + 2)

                if chan_index >= 2 then conn.purpose = "sidechain" end

                local mode_val = math.floor(reaper.GetTrackSendInfo_Value(src_track, 0, s, "I_SENDMODE"))
                if mode_val == 1 then conn.type = "prefx" elseif mode_val == 3 or mode_val == 2 then conn.type = "pre" end
                if dst_ch_str ~= "1/2" then conn.dst_ch = dst_ch_str end

                -- Only record send volume if it is NOT exactly 0.0 dB
                local send_vol = linear_to_db(reaper.GetTrackSendInfo_Value(src_track, 0, s, "D_VOL"))
                if send_vol ~= 0.0 then
                    conn.vol_db = send_vol
                end

                table.insert(connections, conn)
                if ptrs then ptrs[conn] = { src_track, dest_track } end
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
                            is_off = false -- handled by the numbered rule
                            break
                        end
                    end
                    -- task 5e2: any module name ("lp_active: Off"), but only when another setting shares the name; otherwise the
                    -- switch stays ("compressor_enabled: Off" with settings named comp_...), so nothing looks active that is not
                    local pre = is_off and (clean_k:match("^(.+_)active$") or clean_k:match("^(.+_)enabled$"))
                    if pre then
                        for j = 0, math.min(num_params - 1, max_inspect) do
                            local other = param_names[j] and param_names[j] ~= "" and clean_param_key(param_names[j])
                            if other and other ~= clean_k and other:sub(1, #pre) == pre then
                                disabled_prefixes[pre] = true
                                break
                            end
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
    -- Open item: an automated setting (active envelope that moves more than 1% of the setting's range) shows its range over the song,
    -- "0.5-1.2" (" to " with a negative end), not the value at the edit cursor. Sampled every 100 ms (at most 20000 samples).
    local proj_len = reaper.GetProjectLength(0)
    local function auto_range(k)
        local env = reaper.GetFXEnvelope(track, fx_idx, k, false)
        if not env then return nil end
        local ok, act = reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", "", false)
        if ok and act == "0" then return nil end
        local _, pmin, pmax = reaper.TrackFX_GetParam(track, fx_idx, k)
        local step = math.max(0.1, proj_len / 20000)
        local lo, hi = math.huge, -math.huge
        for t = 0, proj_len + step, step do
            local _, v = reaper.Envelope_Evaluate(env, math.min(t, proj_len), 0, 0)
            lo, hi = math.min(lo, v), math.max(hi, v)
        end
        if hi - lo <= 0.01 * ((pmax > pmin) and (pmax - pmin) or 1) then return nil end
        local a = (reaper.Envelope_FormatValue(env, lo, "") or ""):gsub("%s+", "")
        local b = (reaper.Envelope_FormatValue(env, hi, "") or ""):gsub("%s+", "")
        if a == "" or b == "" or a == b then return nil end
        local unit = b:match("%d(%D+)$")
        if unit and a:sub(-#unit) == unit then a = a:sub(1, #a - #unit) end
        return a .. ((a:sub(1, 1) == "-" or b:sub(1, 1) == "-") and " to " or "-") .. b
    end
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
                local rng = auto_range(k)
                local _, param_value = reaper.TrackFX_GetFormattedParamValue(track, fx_idx, k)
                param_value = trim_string(param_value)

                if rng or not is_boilerplate(param_name, param_value) then
                    if count >= MAX_PLUGIN_PARAMS then break end
                    params_table[clean_key] = rng or tonumber(param_value) or param_value
                    count = count + 1
                end
            end
        end
    end
    return next(params_table) ~= nil and params_table or nil
end

-- mode (task 4e compact YAML; nil = old full output): "names" = one string "Name (tags) > Name ...", no settings;
-- "full" = settings with lossless regrouped names, and a renamed plugin shows its original name ("Ducking Comp (ReaComp)").
local function get_track_fx_chain(track, mode)
    local num_fx = reaper.TrackFX_GetCount(track)
    if num_fx == 0 then return nil end
    local fx_chain = {}
    local inst_idx = reaper.TrackFX_GetInstrument(track) -- the same for every FX slot on this track
    local names_only = (mode == "names")
    local function clean(n)
        n = trim_string(n) or "Unknown FX"
        n = n:match(":%s*(.+)") or n
        n = n:gsub("%s*%(.*%)$", "")    -- Uses a greedy match %s*%(.*%)$ to safely catch nested parens like "(Universal Audio (UADx))"
        return trim_string(n)
    end
    -- Lossless regrouping (compact "full" mode). ReaEQ: freq/gn/bw of one band become one entry ("high_pass_1: {bw, freq, gn}").
    -- Other plugins: 3+ names sharing the part before their last "_" become one entry ("band_1: {att, freq, ...}").
    -- Never when the group name is itself a setting, or when all short names are numbers. Short names stay text keys.
    local function regroup(params, reaeq)
        local groups = {}
        for k in pairs(params) do
            local pre, short
            if reaeq then
                short, pre = k:match("^(%a+)_(.+)$")
                if not (short == "freq" or short == "gn" or short == "bw") then pre = nil end
            else
                pre, short = k:match("^(.+)_([^_]+)$")
            end
            if pre then
                local g = groups[pre] or { n = 0, num = true, keys = {} }
                groups[pre] = g
                g.n = g.n + 1
                g.keys[short] = k
                if not short:match("^%d+$") then g.num = false end
            end
        end
        for pre, g in pairs(groups) do
            if params[pre] == nil and not g.num and g.n >= (reaeq and 2 or 3) then
                local sub = {}
                for short, k in pairs(g.keys) do sub[short] = params[k]; params[k] = nil end
                params[pre] = sub
            end
        end
        return params
    end

    for i = 0, num_fx - 1 do
        local _, raw_name = reaper.TrackFX_GetFXName(track, i)
        local fx_name = clean(raw_name)
        local orig, vend
        if mode then
            local ok_o, o = reaper.TrackFX_GetNamedConfigParm(track, i, "original_name")
            orig = ok_o and o and o ~= "" and clean(o) or nil
            if orig == fx_name then orig = nil end
            vend = ((ok_o and o and o ~= "") and o or raw_name):match("(%b())%s*$") -- task 4f.11: the maker, "(Waves)", for [vendor: ...] blocks
            vend = vend and trim_string(vend:sub(2, -2))
        end

        local plugin = { name = fx_name .. (orig and (" (" .. orig .. ")") or "") }
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

        if plugin_type == "effect" and not plugin.bypassed and not names_only then
            plugin.params = extract_fx_params(track, i)
            if mode == "full" and plugin.params then
                local reaeq = (orig or fx_name) == "ReaEQ"
                plugin.params, plugin.vendor = regroup(plugin.params, reaeq), vend -- vendor: removed again in extract_full_project_yaml
                if reaeq then -- task 4h: a band switched off in ReaEQ (no parameter shows it) becomes "off"
                    local types, seen, b = { high_pass = 0, low_shelf = 1, band = 2, notch = 3, high_shelf = 4, low_pass = 5, band_pass = 6 }, {}, 0
                    while true do
                        local ok_n, pn = reaper.TrackFX_GetParamName(track, i, b * 3) -- each band: freq, gain, bw
                        local key = ok_n and clean_param_key(pn):match("^freq_(.+)$")
                        if not key then break end
                        local tp = (key:gsub("_%d+$", ""))
                        local idx = seen[tp] or 0
                        seen[tp] = idx + 1
                        local ok_e, en = reaper.TrackFX_GetNamedConfigParm(track, i, "BANDENABLED" .. b)
                        local off
                        if ok_e and en and en ~= "" then off = (en == "0")
                        elseif types[tp] then off = not reaper.TrackFX_GetEQBandEnabled(track, i, types[tp], idx) end
                        if off and plugin.params[key] ~= nil then plugin.params[key] = "off" end
                        b = b + 1
                    end
                end
            end
        end
        if names_only then
            local tags = {}
            if orig then tags[#tags + 1] = orig end
            if plugin.type then tags[#tags + 1] = plugin.type end
            if plugin.bypassed then tags[#tags + 1] = "bypassed" end
            if plugin.wet then tags[#tags + 1] = "wet " .. plugin.wet end
            plugin = fx_name .. (#tags > 0 and (" (" .. table.concat(tags, ", ") .. ")") or "")
        end
        table.insert(fx_chain, plugin)
    end
    if names_only and #fx_chain > 0 then return table.concat(fx_chain, " > ") end
    return #fx_chain > 0 and fx_chain or nil
end

local function process_track_data(track, is_master, current_depth, any_soloed, has_children, fx_mode) -- fx_mode: see get_track_fx_chain
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
    if fx_mode == "bare" then return { track = track_name, parent = parent_name, flags = track_data.flags } end -- task 4f.7b: outside the focus data

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

    if not mute_state then track_data.fx = get_track_fx_chain(track, fx_mode) end
    return track_data
end

-- opts (task 4e compact YAML): full = { [track GUID] = true }: these tracks, their folders and the master keep
-- their full plugin settings, every other track lists plugin names only; connections keep only the "sidechain" label.
local function extract_full_project_yaml(opts)
    -- task 4g.3 snapshot: opts.take = read every setting the compact YAML can use (every track in every fx mode) and return that table;
    -- opts.snap = such a table: every read below then comes from it, so a prompt describes the project as it was measured, not as it is now
    local S = opts and opts.snap
    local function cp(x) -- the YAML is built from copies (the plugin-settings pass below changes them); to_yaml sorts keys, so copies print the same
        if type(x) ~= "table" then return x end
        local y = {}
        for k, v in pairs(x) do y[k] = cp(v) end
        return y
    end
    local function par(tr) if S then return S.parent[tr] end return reaper.GetParentTrack(tr) end
    local function gid(tr) if S then return S.guid[tr] end return reaper.GetTrackGUID(tr) end
    -- task 5g.4: the project's rate only while its setting is switched on (otherwise the stored number is stale); else the rate the analyzers ran at
    local function proj_rate()
        local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE_USE", 0, false) > 0 and reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false) or reaper.gmem_read(2)
        return sr >= 8000 and math.floor(sr) or "Default"
    end
    if opts and opts.take then
        local num, den = reaper.TimeMap_GetTimeSigAtTime(0, 0)
        S = { meta = { bpm = reaper.Master_GetTempo(), time_sig = string.format("%d/%d", num, den), sample_rate = proj_rate() },
            notes = trim_string(reaper.GetSetProjectNotes(0, false, "")), arr = get_arrangement_markers(), any_soloed = reaper.AnyTrackSolo(0),
            list = {}, parent = {}, guid = {}, has_children = {}, td = {}, cptr = {}, master = reaper.GetMasterTrack(0) }
        S.conns = get_all_connections(nil, S.cptr)
        for i = 0, reaper.CountTracks(0) - 1 do
            local tr = reaper.GetTrack(0, i)
            S.list[i + 1], S.guid[tr], S.parent[tr] = tr, reaper.GetTrackGUID(tr), reaper.GetParentTrack(tr)
            if S.parent[tr] then S.has_children[S.parent[tr]] = true end
        end
        S.td[S.master] = { full = process_track_data(S.master, true, 0, S.any_soloed, S.has_children, "full") }
        local depth = 0
        for _, tr in ipairs(S.list) do
            local d = {}
            for _, m in ipairs({ "full", "names", "bare" }) do d[m] = process_track_data(tr, false, depth, S.any_soloed, S.has_children, m) end
            S.td[tr] = d
            local fd = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
            if fd == 1 then depth = depth + 1 elseif fd < 0 then depth = math.max(0, depth + fd) end
        end
        return S
    end
    local gone = {} -- task 5e2: tracks left out of the YAML (muted and silent, see below), with their sends
    local function conns(keep) -- the snapshot's connections, filtered like get_all_connections(true, keep)
        local l = {}
        for _, c in ipairs(S.conns or {}) do
            local p = S.cptr[c]
            if (not keep or keep[p[1]] or keep[p[2]]) and not gone[p[1]] and not gone[p[2]] then l[#l + 1] = cp(c) end
        end
        return #l > 0 and l or nil
    end
    local meta, proj_notes, arr
    if S then
        meta, proj_notes, arr = cp(S.meta), S.notes, cp(S.arr)
    else
        local num, den = reaper.TimeMap_GetTimeSigAtTime(0, 0)
        proj_notes = trim_string(reaper.GetSetProjectNotes(0, false, ""))
        meta = {
            bpm = reaper.Master_GetTempo(),
            time_sig = string.format("%d/%d", num, den),
            sample_rate = proj_rate()
        }
        arr = get_arrangement_markers()
    end

    local project_data = {
        meta = meta,
        arr = arr,
        connections = S and conns(nil) or (not S and get_all_connections()) or nil,
        tracks = {}
    }

    if proj_notes and proj_notes ~= "" then project_data.notes = (project_data.notes and (project_data.notes .. '\n') or "") .. proj_notes end
    if arr then -- task 5e2: the region lines of the data have the regions; only markers stay
        local marks = {}
        for _, e in ipairs(arr) do
            if e.type ~= "region" then marks[#marks + 1] = e end
        end
        project_data.arr = #marks > 0 and marks or nil
    end

    local any_soloed, list, has_children
    if S then
        any_soloed, list, has_children = S.any_soloed, S.list, S.has_children
    else
        any_soloed, list, has_children = reaper.AnyTrackSolo(0), {}, {}
        for i = 0, reaper.CountTracks(0) - 1 do list[i + 1] = reaper.GetTrack(0, i) end
        -- Pre-calculate parent folders that actually have children
        for _, tr in ipairs(list) do
            local p = reaper.GetParentTrack(tr)
            if p then has_children[p] = true end
        end
    end
    local keep = {} -- compact mode: tracks with full plugin settings (the named tracks and their folder chain)
    if opts then
        for _, tr in ipairs(list) do
            if opts.full[gid(tr)] then
                while tr do keep[tr] = true; tr = par(tr) end
            end
        end
    end
    if opts and opts.only then -- task 4g.3 Track Detail (snapshot only): just these tracks with full settings and their sends, no project part
        keep = opts.only
        project_data.meta, project_data.arr, project_data.notes, project_data.connections = nil, nil, nil, conns(keep)
    end
    -- task 4f.7b (group focus, opts.listed = GUIDs the data mentions): the other tracks get a bare line unless a mentioned or kept
    -- track is inside them; connections only where one end is kept
    local shown
    if opts and opts.listed then
        shown = {}
        for _, tr in ipairs(list) do
            if opts.listed[gid(tr)] or keep[tr] then
                while tr do shown[tr] = true; tr = par(tr) end
            end
        end
        project_data.connections = S and conns(keep) or (not S and get_all_connections(keep)) or nil
    end
    -- task 5e2: tracks muted (also by a folder) that made no sound in the measurement (S.silent, AI.collect) are left out with their sends,
    -- except a track the data names and a folder that still holds a kept track
    if S and S.silent and not opts.only then
        for _, tr in ipairs(list) do
            if S.silent[tr] and not opts.full[gid(tr)] and not (opts.listed and opts.listed[gid(tr)]) then gone[tr] = true end
        end
        for _, tr in ipairs(list) do
            if not gone[tr] then
                local p = par(tr)
                while p do gone[p] = nil; p = par(p) end
            end
        end
        if next(gone) ~= nil then project_data.connections = conns(opts.listed and keep or nil) end
    end

    -- 1. Master Track
    if not (opts and opts.only) then
        table.insert(project_data.tracks, S and cp(S.td[S.master].full) or process_track_data(reaper.GetMasterTrack(0), true, 0, any_soloed, has_children, "full"))
    end

    -- 2. Child Tracks & Folders
    local current_depth = 0
    for _, track in ipairs(list) do
        local mode = keep[track] and "full" or ((shown and not shown[track]) and "bare" or "names")
        if S then
            if (not opts.only or opts.only[track]) and not gone[track] then table.insert(project_data.tracks, cp(S.td[track][mode])) end
        else
            table.insert(project_data.tracks, process_track_data(track, false, current_depth, any_soloed, has_children, mode))
            local folder_delta = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
            if folder_delta == 1 then
                current_depth = current_depth + 1
            elseif folder_delta < 0 then
                current_depth = math.max(0, current_depth + folder_delta)
            end
        end
    end

    -- task 4f.11 (compact YAML only): screen-only settings and the user's drop rules removed; settings equal to an earlier plugin of the
    -- same kind become "same as plugin n on TRACK"; the notes of the plugins whose settings are shown go into additional_information.
    -- MixAssistant_plugin_notes.txt (next to the script): "[original plugin name]", then "note: text" and "drop: name, name_*" lines
    -- (a drop name is the setting as the prompt shows it, groups joined by "_", e.g. band_1_selected; * = any text).
    if opts then
        local pn, cur = {}, nil
        local dir = (debug.getinfo(1, "S").source or ""):match("^@(.*[\\/])")
        local f = dir and io.open(dir .. "MixAssistant_plugin_notes.txt", "r")
        if f then
            for line in f:lines() do
                line = trim_string(line) or ""
                local h = line:match("^%[(.+)%]$")
                if h then
                    cur = { notes = {}, drop = {} }
                    local key = trim_string(h):lower():gsub("^vendor:%s*", "vendor: ")
                    if key:find("^vendor: ") then pn[key] = cur else -- [ReaComp, ReaGate]: one block for several plugins
                        for p in key:gmatch("[^,]+") do
                            p = trim_string(p)
                            if p and p ~= "" then pn[p] = cur end
                        end
                    end
                elseif cur then
                    local k, v = line:match("^(%a+):%s*(.+)$")
                    if k == "note" then
                        cur.notes[#cur.notes + 1] = v
                    elseif k == "drop" then
                        for p in v:gmatch("[^,%s]+") do
                            cur.drop[#cur.drop + 1] = "^" .. p:lower():gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
                        end
                    end
                end
            end
            f:close()
        end
        local SCREEN = { "^selected$", "_selected$", "^visible$", "_visible$" } -- which band is highlighted / which panel is open
        local function strip(t, path, drop)
            for k, v in pairs(t) do
                local full = (path and (path .. "_") or "") .. tostring(k):lower()
                if type(v) == "table" then
                    strip(v, full, drop)
                    if next(v) == nil then t[k] = nil end
                else
                    for _, list in ipairs({ SCREEN, drop }) do
                        for _, p in ipairs(list) do if full:find(p) then t[k] = nil end end
                    end
                end
            end
        end
        local seen, used, nl = {}, {}, {}
        for _, td in ipairs(project_data.tracks) do
            if type(td.fx) == "table" then
                for n, pl in ipairs(td.fx) do
                    local orig = pl.name:match("%((.+)%)$") or pl.name
                    local e = pn[orig:lower()]
                    local vn = pl.vendor
                    local ev = vn and pn["vendor: " .. vn:lower()] -- [vendor: Waves]: drop and note lines for every plugin of that maker
                    pl.vendor = nil
                    if type(pl.params) == "table" then
                        local drop = { table.unpack(e and e.drop or {}) }
                        for _, p in ipairs(ev and ev.drop or {}) do drop[#drop + 1] = p end
                        strip(pl.params, nil, drop)
                        if next(pl.params) == nil then pl.params = nil end
                    end
                    if pl.params then
                        -- one line per block, listing the block's plugins this prompt shows (the prompt has no maker names)
                        for _, b in ipairs({ e or false, ev or false }) do
                            if b and #b.notes > 0 then
                                b.shown = b.shown or {}
                                b.shown[orig] = true
                                used[b] = true
                            end
                        end
                        local key = orig .. " " .. to_inline_yaml(pl.params)
                        if seen[key] then pl.params = seen[key] else seen[key] = "same as plugin " .. n .. " on " .. td.track end
                    end
                end
            end
        end
        for e in pairs(used) do -- "plugin CLA Epic Mono/Stereo: ..." or "plugins ReaComp, ReaGate: ..."
            local l = {}
            for k in pairs(e.shown) do l[#l + 1] = k end
            table.sort(l)
            nl[#nl + 1] = "- plugin" .. (#l > 1 and "s " or " ") .. table.concat(l, ", ") .. ": " .. table.concat(e.notes, " ")
        end
        table.sort(nl)
        if #nl > 0 then project_data.notes = (project_data.notes and (project_data.notes .. "\n") or "") .. table.concat(nl, "\n") end
        -- task 5e2: one line per plugin: "- Name (tags): {settings}", "- Name (tags): same as plugin n on TRACK" or "- Name (tags)"
        for _, td in ipairs(project_data.tracks) do
            if type(td.fx) == "table" then
                for n, pl in ipairs(td.fx) do
                    local tags = {}
                    if pl.type then tags[#tags + 1] = pl.type end
                    if pl.bypassed then tags[#tags + 1] = "bypassed" end
                    if pl.wet then tags[#tags + 1] = "wet " .. pl.wet end
                    local label = pl.name
                    if #tags > 0 then
                        local t = table.concat(tags, ", ")
                        label = label:sub(-1) == ")" and (label:sub(1, -2) .. ", " .. t .. ")") or (label .. " (" .. t .. ")")
                    end
                    label = escape_yaml_string(label)
                    local v = pl.params
                    td.fx[n] = { __line = type(v) == "table" and (label .. ": " .. to_inline_yaml(v)) or (v and (label .. ": " .. escape_yaml_string(v)) or label) }
                end
            end
        end
    end

    return to_yaml(project_data), project_data.arr
end

-- ==============================================================================
-- 5. TRACK NAME AND MUTE HELPERS
-- ==============================================================================

-- Keyword list for parallel / rear / NYC busses (plain substring match)
local PARALLEL_WORDS = { "nyc", "rear", "parallel" }

local function name_has_any(name, words)
    for _, word in ipairs(words) do
        if name:find(word, 1, true) then return true end
    end
    return false
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

-- ==============================================================================
-- 7. LEVEL MATH
-- ==============================================================================

-- Helper to convert any raw band energy accumulation into absolute dBFS (offset_db = optional octave normalization)
local function convert_energy_to_db(energy_sum, num_samples, offset_db)
    local band_rms = math.sqrt(energy_sum / num_samples)
    if band_rms <= 1e-7 then return -144.0 end
    return round(20 * math.log(band_rms, 10) + (offset_db or 0), 1)
end

-- ==============================================================================
-- 9. PROMPT FILE EXPORTER, JSON, CURL / API, BALANCE
-- ==============================================================================

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
        if msg.role == "user" or msg.role == "assistant" then -- alert and info lines stay local
            local safe_content = escape_json_string(msg.content)
            table.insert(json_msgs, '{"role":"'..msg.role..'","content":"'..safe_content..'"}')
        end
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

-- Returns the answer text, plus the reply's `usage` table on success (nil with an error text).
-- think = true: thinking mode with low effort; the thinking (`reasoning_content`) is never read, so it is not shown or sent back.
local function ask_deep_seek(chat_history, model_name, think)
    local temp_json_path = reaper.GetResourcePath() .. "/temp_ds_request.json"
    local temp_response_path = reaper.GetResourcePath() .. "/temp_ds_response.txt"

    local curl_bin = resolve_curl_binary()
    if not curl_bin then
        return "Network Error: cURL is not installed or not available on this system.\n\nInstall curl.exe or add it to PATH before using the DeepSeek API."
    end

    local selected_model = model_name or "deepseek-v4-pro"
    local msgs_json = build_json_messages(chat_history)

    -- NOTE: "thinking":{"type":"disabled"} is included to prevent expensive output token burning (thinking is the API default)
    local mode_json = think and ',"thinking":{"type":"enabled"},"reasoning_effort":"low"}' or ',"thinking":{"type":"disabled"},"temperature":0.1}'
    local json_payload = '{"model":"' .. selected_model .. '","messages":' .. msgs_json .. mode_json

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
        return content, type(data.usage) == "table" and data.usage or nil
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
local MA_HDR, MA_MAXTR, MA_MAXSEC, MA_STRIDE, MA_MSTRIDE = 256, 128, 1800, 32, 45
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

-- Stage 4 (feeding the JSFX data to the AI): all constants in ONE table to spare top-level locals.
local MA_A = {
    DEV = true, -- task 5g.1: developer switch. On: Collect writes MixAssistant_report.txt next to the script and saves the Whole Song prompt at once. Off: nothing in the script folder; a failed Collect leaves its report next to the project
    MIBASE = MA_MBASE + 18000 * MA_MSTRIDE, MISTRIDE = 4, -- master input records (JSFX role 2): K energy, count, run id, max |sample|
    GMEM_SIZE = 8388608, -- task 5b: REAPER's gmem slots; the layout (MA_MAXSEC, MA_MAXTR, MA_MBASE, MIBASE) is set per run in collect_jsfx_data
    TOP_N = 6, NOTABLE_DB = 3, BAND_RANGE_DB = 30, REGION_DEV_DB = 3, MASK_SHARE = 0.25, MASK_PAN = 100, MASK_OVERLAP = 25,
    BACKDROP_N = 3, -- task 4f.7b: group focus, the loudest other tracks per focus region that get full lines (backdrop)
    COMP_MAIN_DB = 10, COMP_DB = 3, COMP_N = 3, -- task 4f.8: main bands within 10 dB of the loudest; competitor >= focus - 3 dB; 3 per range, 3 ranges
    -- task 4f.10: band topics keep tracks with >= TOPIC_PCT of the range energy in a region; Master & Loudness region lines: loudest first
    -- until MASTER_PCT of the region's mix, MASTER_MIN to MASTER_MAX lines, none under MIN_SHARE
    TOPIC_PCT = 2, MASTER_PCT = 85, MASTER_MIN = 3, MASTER_MAX = 10,
    -- task 4f.9: automation points: at most AUTO_MAX per envelope; tolerances 0.5 dB volume, 2% pan/width, 1% of a plugin parameter's range
    AUTO_MAX = 200, AUTO_TOL_DB = 0.5, AUTO_TOL_PCT = 2, AUTO_TOL_FX_PCT = 1, AUTO_FLOOR_DB = -90,
    ACTIVE_MIN_PCT = 5, TOKEN_CEILING = 8000, MIN_SHARE = 1, -- MIN_SHARE: region track lines below this share (%) are left out of the data block
    M_CORR_MAX = -0.005, M_BAL_MIN = 12, -- task 5d: a region's master c shows below this (rounds to under 0), its balance from this (about 1 dB between the sides)
    KEYS = { "rumble", "deepsub", "sub", "bass", "body", "mud", "boxy", "honk", "nasal", "bite", "presence", "harsh", "sibilance", "sizzle", "air" },
    -- Task 4f: DeepSeek peak prices, USD per 1M tokens { cache hit, cache miss, output } (api-docs.deepseek.com, 2026-11-04);
    -- off-peak = half. Peak hours (UTC, Mon-Fri, not Chinese holidays): 01:00-04:00 and 06:00-10:00.
    PRICE = { ["deepseek-v4-pro"] = { 0.044, 1.32, 3.96 }, ["deepseek-flash"] = { 0.006, 0.30, 1.20 } },
    PEAK_UTC = { { 1, 4 }, { 6, 10 } },
    CPT = 2.37, -- characters per token: 4f01 prompt 44,071 chars = 18,617 tokens (DeepSeek's count); every "Send Project Info" re-measures it
}

--- Token estimate for n characters (the last measured characters-per-token ratio, kept in REAPER's ExtState; MA_A.CPT before the first send)
function MA_A.tokens(n)
    local r = tonumber(reaper.GetExtState("MixAssistant", "chars_per_token")) or MA_A.CPT
    return math.floor(n / r + 0.5)
end

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
//MA_JSFX_VERSION=5
options:gmem=MixAssistant

slider1:0<0,4095,1>Track index
slider2:0<0,2,1{Track,Master,Master input}>Role

in_pin:left input
in_pin:right input
out_pin:left output
out_pin:right output

@init
ext_noinit = 1; // keep the state when REAPER restarts the FX after a render (else the idle blocks look like a fresh run)
MAGIC = 20261103; VERSION = 5;
HDR = 256; MAXTR = 128; MAXSEC = 1800; STRIDE = 32;
// master block: 0-2 K energy/count/run, 3-32 mid+side bands, 33-35 LL/RR/LR, 36-38 sub-mono LL/RR/LR, 39-40 peak |L|/|R|, 41 clip frames
MBASE = HDR + MAXTR * MAXSEC * STRIDE; MSTRIDE = 45;
// master input records (role 2): MAXSEC x 10 blocks x 4 slots after the master blocks: K energy, count, run id, max |sample|
// (task 5b: MAXSEC / MAXTR come from Lua per run, gmem[11] / gmem[12]; see @block)
MIBASE = MBASE + 18000 * MSTRIDE; mipk = 0;
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
// local memory: 0 band coefs (15x4), 64 mid states, 128 side states (15x4 each), 192 accumulators (15 mid + 15 side), 224 band edges
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
function put_master() global(cur_mb,mke,mcnt,run,MBASE,MSTRIDE,ACC,gmem,m_ll,m_rr,m_lr,m_sll,m_srr,m_slr,m_pl,m_pr,m_cl) local(b,bi) (
  b = MBASE + cur_mb * MSTRIDE;
  gmem[b] = mke; gmem[b+1] = mcnt; gmem[b+2] = run;
  bi = 0;
  loop(30, gmem[b+3+bi] = ACC[bi]; bi += 1;);
  gmem[b+33] = m_ll; gmem[b+34] = m_rr; gmem[b+35] = m_lr;
  gmem[b+36] = m_sll; gmem[b+37] = m_srr; gmem[b+38] = m_slr;
  gmem[b+39] = m_pl; gmem[b+40] = m_pr; gmem[b+41] = m_cl;
);
function put_master_in() global(cur_mb,mke,mcnt,run,mipk,MIBASE,gmem) local(b) (
  b = MIBASE + cur_mb * 4;
  gmem[b] = mke; gmem[b+1] = mcnt; gmem[b+2] = run; gmem[b+3] = mipk;
);
@slider
idx = slider1 | 0;
role = (slider2 | 0) == 1; // master (end of the chain)
ismin = (slider2 | 0) == 2; // master input (start of the chain)

@block
run = gmem[9];
t0 = play_position;
run != last_run ? (
  last_run = run; cur_sec = -1; cur_mb = -1; exp_t = -1; reach = -1;
  cur_sb = -1; sbcnt = 0; sb_fe = 0; sb_ke = 0;
  sb_maxf = 0; sb_maxk = 0; sb_act = 0; sb_elig = 0; clipc = 0; mclipc = 0; mpeak = 0;
  act_thr = gmem[16]; clip_thr = gmem[17] > 0 ? gmem[17] : 1; mclip_thr = gmem[18] > 0 ? gmem[18] : 1;
  // task 5b: the run's layout from Lua (seconds and track slots that fit in gmem); the @init values are only the fallback
  MAXSEC = gmem[11] > 0 ? gmem[11] : 1800; MAXTR = gmem[12] > 0 ? gmem[12] : 128;
  MBASE = HDR + MAXTR * MAXSEC * STRIDE; MIBASE = MBASE + MAXSEC * 10 * MSTRIDE;
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
);
// a block starting at the render start (gmem[7]) is accepted only before this run got 1 s past it: after the render, a stopped
// project with the edit cursor at the start must not count as a new start (it overwrote the master peak with idle noise)
ok = (role || ismin) ? 1 : (idx >= 0 && idx < MAXTR); // after the run-id change (task 5b: MAXTR comes with the run)
synced = (exp_t >= 0 && abs(t0 - exp_t) < 0.004) || (abs(t0 - gmem[7]) < 0.05 && reach < gmem[7] + 1);
exp_t = t0 + samplesblock * invsr;
active = (gmem[6] == 1) && (run > 0) && ok && synced;
active && t0 > reach ? reach = t0;
n = 0;
active ? (
  role ? gmem[10] = run;
  gmem[2] = srate;
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
        m_ll = m_rr = m_lr = m_sll = m_srr = m_slr = m_pl = m_pr = m_cl = 0;
      );
      mke += ke; mcnt += 1;
      sb_pk = max(abs(spl0), abs(spl1)); sb_pk > mpeak ? mpeak = sb_pk; sb_pk >= mclip_thr ? ( mclipc += 1; m_cl += 1; );
      a = abs(spl0); a > m_pl ? m_pl = a;
      a = abs(spl1); a > m_pr ? m_pr = a;
      m_ll += spl0 * spl0; m_rr += spl1 * spl1; m_lr += spl0 * spl1;
      !skip ? (
        mdx = (spl0 + spl1) * 0.5; sdx = (spl0 - spl1) * 0.5;
        bandrun(mdx, STM, ACC);
        bandrun(sdx, STS, ACC + 15);
        ylp = lpl.lp4(spl0); yrp = lpr.lp4(spl1);
        m_sll += ylp * ylp; m_srr += yrp * yrp; m_slr += ylp * yrp;
      );
      n >= samplesblock - 1 ? ( put_master(); gmem[19] = mclipc; gmem[20] = run; gmem[21] = mpeak; );
    ) : ismin ? (
      mb = (t * 10) | 0;
      mb != cur_mb ? (
        cur_mb >= 0 ? put_master_in();
        cur_mb = mb; mke = 0; mcnt = 0; mipk = 0;
      );
      mke += ke; mcnt += 1;
      sb_pk = max(abs(spl0), abs(spl1)); sb_pk > mipk ? mipk = sb_pk;
      n >= samplesblock - 1 ? put_master_in();
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

--- Deletes every analyzer instance and every phantom track "__MA_PHANTOM n" (also leftovers from a crash). Returns how many were removed.
-- Deleting a phantom also removes the send that fed it.
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
    for i = reaper.CountTracks(0) - 1, 0, -1 do
        local tr = reaper.GetTrack(0, i)
        local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
        if nm:find("^__MA_PHANTOM") then
            reaper.DeleteTrack(tr)
            removed = removed + 1
        end
    end
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

--- Picks the qualifying tracks, then adds one phantom track per chosen track (post-fader send from the original, main send off, the
-- analyzer on the phantom) and the analyzers on the master. List entries: idx and name of the original, slot = gmem record index.
-- Returns list, skipped count | nil, error.
-- Task 5b: max_tr = how many track slots fit in gmem at this project length; more chosen tracks: nil, nil, message (nothing changed yet).
local function inject_analyzers(max_tr)
    local num_tracks = reaper.CountTracks(0)
    local has_children = {}
    for i = 0, num_tracks - 1 do
        local p = reaper.GetParentTrack(reaper.GetTrack(0, i))
        if p then has_children[p] = true end
    end

    local list, skipped, memo, err = {}, 0, {}, nil
    reaper.PreventUIRefresh(1)
    -- 1. choose the tracks first, while no send of ours exists yet
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        if not should_analyze(track, has_children, memo) then
            skipped = skipped + 1
        else
            list[#list + 1] = { idx = i, name = get_track_identity(track), slot = #list, track = track }
        end
    end
    if #list > max_tr then
        reaper.PreventUIRefresh(-1)
        local len = reaper.GetProjectLength(0)
        local fit_s = math.floor((MA_A.GMEM_SIZE - MA_HDR) / (#list * MA_STRIDE + 10 * (MA_MSTRIDE + MA_A.MISTRIDE))) - 2
        return nil, nil, string.format("This project is too big for the analyzer memory: %d tracks to measure x %.0f s. At this length up to %d tracks fit; with %d tracks up to %.1f min. Shorten the project or mute / remove tracks, then try again. Nothing was changed.",
            #list, len, math.max(max_tr, 0), #list, math.max(fit_s, 0) / 60)
    end
    -- 2. one phantom per chosen track, appended at the end of the project (the original track numbers do not change)
    local clock = reaper.time_precise
    local tm = { ins = 0, set = 0, hide = 0, send = 0, check = 0, fixed = 0, fx = 0, master = 0, total = clock() } -- seconds spent per phase (printed in the report)
    -- Post-fader send from src to dst on channels 1/2, 0 dB, centre, MIDI off. REAPER creates sends with the user's own defaults, so every
    -- value is checked and only values that differ are written. Returns false when the send could not be created.
    -- Writes every send value (only the differing ones); returns how many it had to change.
    local function fix_send(src, s)
        local w = 0
        local function set(k, v)
            if reaper.GetTrackSendInfo_Value(src, 0, s, k) ~= v then reaper.SetTrackSendInfo_Value(src, 0, s, k, v); w = w + 1 end
        end
        set("I_SENDMODE", 0) -- post-fader (and post-pan)
        set("D_VOL", 1); set("D_PAN", 0); set("D_PANLAW", 1)
        set("B_MUTE", 0); set("B_PHASE", 0); set("B_MONO", 0)
        set("I_SRCCHAN", 0); set("I_DSTCHAN", 0) -- channels 1/2 to channels 1/2
        set("I_MIDIFLAGS", 1023) -- MIDI off (source and destination channel 31 = disabled)
        return w
    end
    local function make_send(src, dst)
        local s = reaper.CreateTrackSend(src, dst)
        if s < 0 then return false end
        fix_send(src, s)
        return true
    end
    -- The first phantom is built call by call; its chunk text (REAPER's own format) becomes the template, and every other phantom is a copy
    -- of it (2 calls instead of about 14, because each routing change makes REAPER rebuild its processing graph). The check after the loop
    -- repairs whatever differs, so a copy that came out wrong cannot give wrong data.
    local template
    for _, t in ipairs(list) do
        local c0 = clock()
        local n = reaper.CountTracks(0)
        reaper.InsertTrackAtIndex(n, false) -- false: no default FX or envelopes
        local ph = reaper.GetTrack(0, n)
        t.phantom = ph
        tm.ins = tm.ins + (clock() - c0)
        c0 = clock()
        local copied = false
        if template then
            local map = {}
            local chunk = template:gsub("{%x+%-%x+%-%x+%-%x+%-%x+}", function(g) -- new GUIDs (track and FX)
                map[g] = map[g] or reaper.genGuid("")
                return map[g]
            end)
            chunk = chunk:gsub("\n(%s*)NAME [^\n]*", "\n%1NAME \"__MA_PHANTOM " .. t.slot .. "\"", 1)
            chunk = chunk:gsub("\n(%s*)AUXRECV %d+ ", "\n%1AUXRECV " .. t.idx .. " ", 1) -- receive from this track
            copied = reaper.SetTrackStateChunk(ph, chunk, false)
            tm.set = tm.set + (clock() - c0)
        end
        if copied then
            c0 = clock()
            if reaper.TrackFX_GetCount(ph) > 0 and math.abs(reaper.TrackFX_GetParam(ph, 0, 0) - t.slot) > 0.5 then
                reaper.TrackFX_SetParam(ph, 0, 0, t.slot)
            end
            tm.fx = tm.fx + (clock() - c0)
        else
            reaper.GetSetMediaTrackInfo_String(ph, "P_NAME", "__MA_PHANTOM " .. t.slot, true)
            reaper.SetMediaTrackInfo_Value(ph, "B_MAINSEND", 0) -- a phantom never reaches the master
            tm.set = tm.set + (clock() - c0)
            c0 = clock()
            reaper.SetMediaTrackInfo_Value(ph, "B_SHOWINTCP", 0) -- hidden from the track list and mixer (no flicker)
            reaper.SetMediaTrackInfo_Value(ph, "B_SHOWINMIXER", 0)
            tm.hide = tm.hide + (clock() - c0)
            c0 = clock()
            if not make_send(t.track, ph) then
                err = "Could not create the send to the phantom track of '" .. t.name .. "'."
                break
            end
            tm.send = tm.send + (clock() - c0)
            c0 = clock()
            local fx = reaper.TrackFX_AddByName(ph, ANALYZER_FX_PATH, false, -1)
            if fx < 0 then
                err = "TrackFX_AddByName could not find the analyzer JSFX (returned -1)."
                break
            end
            reaper.TrackFX_SetParam(ph, fx, 0, t.slot)
            reaper.TrackFX_SetParam(ph, fx, 1, 0)
            tm.fx = tm.fx + (clock() - c0)
            if not template then
                local okc, ch = reaper.GetTrackStateChunk(ph, "", false)
                if okc and ch:find("AUXRECV", 1, true) and ch:find("<JS", 1, true) then template = ch end
            end
        end
    end
    -- Check every phantom (all of them, copied or not): name, main send off, exactly the one send with the right values, the analyzer with its slot
    if not err then
        local c0 = clock()
        for _, t in ipairs(list) do
            local ph, want, s = t.phantom, "__MA_PHANTOM " .. t.slot, nil
            local fixed = false
            for i = 0, reaper.GetTrackNumSends(t.track, 0) - 1 do
                local dest = reaper.GetTrackSendInfo_Value(t.track, 0, i, "P_DESTTRACK")
                if dest and dest ~= 0 and select(2, reaper.GetSetMediaTrackInfo_String(dest, "P_NAME", "", false)) == want then s = i; break end
            end
            if s then
                if fix_send(t.track, s) > 0 then fixed = true end
            elseif make_send(t.track, ph) then
                fixed = true
            else
                err = "Could not create the send to the phantom track of '" .. t.name .. "'."
                break
            end
            if select(2, reaper.GetSetMediaTrackInfo_String(ph, "P_NAME", "", false)) ~= want then
                reaper.GetSetMediaTrackInfo_String(ph, "P_NAME", want, true); fixed = true
            end
            if reaper.GetMediaTrackInfo_Value(ph, "B_MAINSEND") ~= 0 then reaper.SetMediaTrackInfo_Value(ph, "B_MAINSEND", 0); fixed = true end
            if reaper.TrackFX_GetCount(ph) == 0 then
                local fx = reaper.TrackFX_AddByName(ph, ANALYZER_FX_PATH, false, -1)
                if fx < 0 then err = "TrackFX_AddByName could not find the analyzer JSFX (returned -1)." break end
                reaper.TrackFX_SetParam(ph, fx, 0, t.slot)
                reaper.TrackFX_SetParam(ph, fx, 1, 0)
                fixed = true
            elseif math.abs(reaper.TrackFX_GetParam(ph, 0, 0) - t.slot) > 0.5 or math.abs(reaper.TrackFX_GetParam(ph, 0, 1)) > 0.5 then
                reaper.TrackFX_SetParam(ph, 0, 0, t.slot); reaper.TrackFX_SetParam(ph, 0, 1, 0); fixed = true
            end
            if fixed then tm.fixed = tm.fixed + 1 end
        end
        tm.check = clock() - c0
    end
    local c_master = clock()
    if not err then
        local master = reaper.GetMasterTrack(0)
        local fx = reaper.TrackFX_AddByName(master, ANALYZER_FX_PATH, false, -1)
        if fx < 0 then
            err = "Could not add the analyzer to the master track."
        else
            reaper.TrackFX_SetParam(master, fx, 0, 0)
            reaper.TrackFX_SetParam(master, fx, 1, 1)
            -- Second analyzer at the START of the master chain (role 2 = master input); -1000 = first position
            local fx_in = reaper.TrackFX_AddByName(master, ANALYZER_FX_PATH, false, -1000)
            if fx_in < 0 then
                err = "Could not add the master input analyzer."
            else
                reaper.TrackFX_SetParam(master, fx_in, 0, 0)
                reaper.TrackFX_SetParam(master, fx_in, 1, 2)
            end
        end
    end
    reaper.PreventUIRefresh(-1)
    tm.master = clock() - c_master
    tm.total = clock() - tm.total

    if err then return nil, nil, err end
    list.timing = tm
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
-- idx = the phantom slot of the track. opts (optional, stage 4 region use): weight[sec] = share of that second inside the region (0..1),
-- tie_sec = the second where a weight of exactly 0.5 counts as the larger part. Without opts the result is the plain sum.
local function summarize_track(idx, max_sec, run_id, first_sec, opts)
    local s = { secs = 0, first = -1, last = -1, samples = 0, ll = 0, rr = 0, lr = 0, ke = 0, peak = 0,
        bands = {}, sub_ll = 0, sub_rr = 0, sub_lr = 0, clips = 0, viol_loud = 0, viol_act = 0 } -- bands[1..15]: summed mid band energies
    for k = 1, 15 do s.bands[k] = 0 end
    if opts then s.wsecs = 0 end -- total weight of the seconds used
    local weight = opts and opts.weight
    local srate = reaper.gmem_read(2)
    local crest, max_loudf, max_loudk, sum_act, sum_elig = {}, 0, 0, 0, 0
    for sec = first_sec or 0, max_sec - 1 do
        local b = MA_HDR + (idx * MA_MAXSEC + sec) * MA_STRIDE
        if reaper.gmem_read(b + 7) == run_id and (not weight or (weight[sec] or 0) > 0) then
            local w = weight and weight[sec] or 1
            local wg = w
            local major = w > 0.5 or (w == 0.5 and sec == (opts and opts.tie_sec)) -- maxima, crest and clips belong to the larger part
            s.secs = s.secs + 1
            if opts then s.wsecs = s.wsecs + w end
            if s.first < 0 then s.first = sec end
            s.last = sec
            if major then s.peak = math.max(s.peak, reaper.gmem_read(b), reaper.gmem_read(b + 1)) end
            s.ll = s.ll + reaper.gmem_read(b + 2) * wg
            s.rr = s.rr + reaper.gmem_read(b + 3) * wg
            s.lr = s.lr + reaper.gmem_read(b + 4) * wg
            s.ke = s.ke + reaper.gmem_read(b + 5) * wg
            s.samples = s.samples + reaper.gmem_read(b + 6) * w
            for k = 1, 15 do s.bands[k] = s.bands[k] + reaper.gmem_read(b + 7 + k) * wg end
            s.sub_ll = s.sub_ll + reaper.gmem_read(b + 23) * wg
            s.sub_rr = s.sub_rr + reaper.gmem_read(b + 24) * wg
            s.sub_lr = s.sub_lr + reaper.gmem_read(b + 25) * wg

            -- Stage 3: short-window dynamics of this second
            local scnt, e_ll, e_rr = reaper.gmem_read(b + 6), reaper.gmem_read(b + 2), reaper.gmem_read(b + 3)
            local loudf = reaper.gmem_read(b + MA_S_LOUDF)
            local act, elig = reaper.gmem_read(b + MA_S_ACTIVE), reaper.gmem_read(b + MA_S_ELIG)
            if major then
                max_loudf = math.max(max_loudf, loudf)
                max_loudk = math.max(max_loudk, reaper.gmem_read(b + MA_S_LOUDK))
                s.clips = s.clips + reaper.gmem_read(b + MA_S_CLIPS)
            end
            sum_act, sum_elig = sum_act + act * w, sum_elig + elig * w
            if act > elig then s.viol_act = s.viol_act + 1 end
            if scnt > 0 then
                local mean_fe = (e_ll + e_rr) / scnt -- mean(L^2 + R^2), same convention as the loudest-100 ms slot
                local rms_db = level_db(math.sqrt(mean_fe / 2))
                if scnt >= 0.999 * srate and mean_fe > 1e-12 and loudf < mean_fe * 10 ^ -0.01 then
                    s.viol_loud = s.viol_loud + 1 -- loudest 100 ms more than 0.1 dB below the full second's own rms
                end
                if major and scnt >= 0.9 * srate and rms_db > MA_ACTIVE_DB then
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
-- blk0, blk1 (optional, inclusive): only this block range counts (a region); windows must lie fully inside it. Default: whole song.
-- input (optional): read the master input records (start of the master chain) instead of the end records; no bands, peak instead.
local function summarize_master(max_sec, run_id, blk0, blk1, input)
    local base, stride = MA_MBASE, MA_MSTRIDE
    if input then base, stride = MA_A.MIBASE, MA_A.MISTRIDE end
    local in_peak = 0
    local nblk = math.min(MA_MAXSEC * 10, max_sec * 10)
    blk0 = blk0 or 0
    blk1 = blk1 and math.min(blk1, nblk - 1) or nblk - 1
    local pe, pc, pv = { [0] = 0 }, { [0] = 0 }, { [0] = 0 }
    local mid_e, side_e = {}, {} -- summed band energies of the valid blocks
    for i = 1, 15 do mid_e[i], side_e[i] = 0, 0 end
    -- task 5a: stereo sums (slots 33-38: LL, RR, LR, sub-mono LL, RR, LR), peaks |L| / |R| (39-40, max), clip frames (41)
    local st = { 0, 0, 0, 0, 0, 0 }
    local pkl, pkr, clips = 0, 0, 0
    for k = 0, nblk - 1 do
        local b = base + k * stride
        local ok = reaper.gmem_read(b + 2) == run_id
        if ok and k >= blk0 and k <= blk1 then
            if input then
                in_peak = math.max(in_peak, reaper.gmem_read(b + 3))
            else
                for i = 1, 15 do
                    mid_e[i] = mid_e[i] + reaper.gmem_read(b + 2 + i)
                    side_e[i] = side_e[i] + reaper.gmem_read(b + 17 + i)
                end
                for i = 1, 6 do st[i] = st[i] + reaper.gmem_read(b + 32 + i) end
                pkl, pkr = math.max(pkl, reaper.gmem_read(b + 39)), math.max(pkr, reaper.gmem_read(b + 40))
                clips = clips + reaper.gmem_read(b + 41)
            end
        end
        pe[k + 1] = pe[k] + (ok and reaper.gmem_read(b) or 0)
        pc[k + 1] = pc[k] + (ok and reaper.gmem_read(b + 1) or 0)
        pv[k + 1] = pv[k] + (ok and 1 or 0)
    end

    local function window_ms(k, len)
        if k < blk0 or k + len - 1 > blk1 or pv[k + len] - pv[k] ~= len then return nil end
        local c = pc[k + len] - pc[k]
        return c > 0 and (pe[k + len] - pe[k]) / c or nil
    end

    local gated, short, max_m, max_s = {}, {}, -144.0, -144.0
    for k = blk0, blk1 - 3 do
        local ms = window_ms(k, 4)
        if ms then
            max_m = math.max(max_m, lufs(ms))
            if lufs(ms) > -70 then gated[#gated + 1] = ms end
        end
    end
    for k = blk0, blk1 - 29 do
        local ms = window_ms(k, 30)
        if ms then
            max_s = math.max(max_s, lufs(ms))
            if lufs(ms) > -70 then short[#short + 1] = ms end -- absolute gate for the loudness range
        end
    end

    -- Loudness range (EBU Tech 3342): short-term values every 100 ms, relative gate 20 LU below their power mean, LRA = p95 - p10
    local lra
    if #short > 0 then
        local sum = 0
        for _, ms in ipairs(short) do sum = sum + ms end
        local rel_gate = lufs(sum / #short) - 20
        local lv = {}
        for _, ms in ipairs(short) do
            if lufs(ms) > rel_gate then lv[#lv + 1] = lufs(ms) end
        end
        if #lv >= 2 then lra = percentile(lv, 95) - percentile(lv, 10) end
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
    return { valid_blocks = pv[blk1 + 1] - pv[blk0], integrated = integrated, max_m = max_m, max_s = max_s,
        samples = pc[blk1 + 1] - pc[blk0], mid = mid_e, side = side_e, ke = pe[blk1 + 1] - pe[blk0], lra = lra, peak = in_peak,
        ll = st[1], rr = st[2], lr = st[3], sub_ll = st[4], sub_rr = st[5], sub_lr = st[6], pkl = pkl, pkr = pkr, clips = clips }
end

--- Task 5a: stereo and level values of a summarize_master result m (same formulas as the tracks in collect_region_data).
-- fader_db: the master fader (the analyzer sits before it). Returns { corr, sub_corr, sub_risk, pan100, width, pk, rms, crest }.
function MA_A.mstereo(m, fader_db)
    local n = math.max(m.samples, 1)
    local r = {}
    r.corr = (m.ll * m.rr > 0) and m.lr / math.sqrt(m.ll * m.rr) or 1
    r.sub_corr = (m.sub_ll * m.sub_rr > 0) and m.sub_lr / math.sqrt(m.sub_ll * m.sub_rr) or 1
    r.sub_risk = convert_energy_to_db((m.sub_ll + m.sub_rr) / 2, n) > -50.0 and r.sub_corr < 0
    local pw = m.ll + m.rr
    local p = pw > 0 and 100 * (m.rr - m.ll) / pw or 0
    r.pan100 = p >= 0 and math.floor(p + 0.5) or -math.floor(-p + 0.5)
    local rm = math.sqrt(math.max((m.ll + m.rr + 2 * m.lr) / 4, 0))
    local rs = math.sqrt(math.max((m.ll + m.rr - 2 * m.lr) / 4, 0))
    r.width = (rm + rs) > 0 and 100 * rs / (rm + rs) or 0
    r.pk = level_db(math.max(m.pkl, m.pkr)) + fader_db
    r.rms = level_db(math.sqrt(pw / (2 * n))) + fader_db
    r.crest = r.pk - r.rms
    return r
end

-- ------------------------------------------------------------------------------
-- Stage 4, task 4a: routing, region aggregation, contribution model (console output only, no AI yet)
-- ------------------------------------------------------------------------------

--- Folder parent, folder-bus flag and "not counted" rule of every analyzed track. Fader, pan and automation are no longer modelled:
-- the phantom tracks measure them (task 4c). tracks = the list from inject_analyzers. Returns routing[track idx].
local function track_routing(tracks)
    local function gmi(tr, key) return reaper.GetMediaTrackInfo_Value(tr, key) end
    local has_children = {}
    for i = 0, reaper.CountTracks(0) - 1 do
        local p = reaper.GetParentTrack(reaper.GetTrack(0, i))
        if p then has_children[p] = true end
    end

    local routing = {}
    for _, t in ipairs(tracks) do
        local tr = reaper.GetTrack(0, t.idx)
        local r = { reasons = {} }
        routing[t.idx] = r
        r.role = has_children[tr] and "bus" or "trk" -- "bus" = folder bus (never ranked: it would double-count its children)
        local par = reaper.GetParentTrack(tr)
        r.parent = par and (math.floor(gmi(par, "IP_TRACKNUMBER")) - 1) or nil -- track idx of the folder parent
        r.fader_db = level_db(gmi(tr, "D_VOL")) -- the track's own static fader (for the pre-fader peak estimate)

        -- No direct path to the master (main send off somewhere on the folder chain, or a fader at -inf): the track is not counted at all.
        -- Whatever it feeds through sends is measured on the receiving tracks.
        local lin, cur, send_only = 1, tr, false
        while cur do
            lin = lin * gmi(cur, "D_VOL")
            if gmi(cur, "B_MAINSEND") ~= 1 then send_only = true break end
            cur = reaper.GetParentTrack(cur)
        end
        r.no_direct = send_only and "send-only" or (level_db(lin) <= -100 and "fader off" or nil)

        -- A folder bus that also receives audio sends on channels 1/2: that audio inflates the share factor of its children
        if r.role == "bus" then
            for k = 0, reaper.GetTrackNumSends(tr, -1) - 1 do
                local dst = math.floor(reaper.GetTrackSendInfo_Value(tr, -1, k, "I_DSTCHAN")) & 1023
                if reaper.GetTrackSendInfo_Value(tr, -1, k, "B_MUTE") ~= 1 and reaper.GetTrackSendInfo_Value(tr, -1, k, "I_SRCCHAN") >= 0 and dst < 2 then
                    r.bus_sends = true
                    break
                end
            end
        end
    end
    for _, t in ipairs(tracks) do
        local r = routing[t.idx]
        local pr = r.parent and routing[r.parent]
        if pr and pr.bus_sends then r.reasons[#r.reasons + 1] = "bus+sends" end
    end
    return routing
end

--- Notable bands of a track (15 dB values): a band stands out against the mean of its two neighbours (the end bands: against their
-- single neighbour, bumps only). Bands more than BAND_RANGE_DB below the loudest band are ignored. Returns { {key=, dev=, band=}, ... } low to high.
local function notable_bands(levels)
    local top = -1e9
    for b = 1, 15 do top = math.max(top, levels[b]) end
    local floor_db = top - MA_A.BAND_RANGE_DB
    local function lv(b) return math.max(levels[b], floor_db) end
    local list = {}
    for b = 1, 15 do
        if levels[b] >= floor_db then
            local edge = (b == 1 or b == 15)
            local dev
            if b == 1 then dev = lv(1) - lv(2)
            elseif b == 15 then dev = lv(15) - lv(14)
            else dev = lv(b) - (lv(b - 1) + lv(b + 1)) / 2 end
            if (edge and dev or math.abs(dev)) >= MA_A.NOTABLE_DB - 1e-9 then
                list[#list + 1] = { key = MA_A.KEYS[b], dev = dev, band = b }
            end
        end
    end
    return list
end

--- Region and song aggregation (A1.3-A1.5): master numbers per region, per-track stats, K-energy share, top-N selection,
-- masking hints and the approx list. Returns D = { song, over = {stats per track, whole song}, regions = {...}, ... } | nil, error.
local function collect_region_data(tracks, max_sec, run_id, offsets)
    -- Stage 6: everything the prompts read is in D when this returns: song, over, regions, ps, offsets, tracks (each with t.guid), route, m_peak, m_clips, check, pre_fx
    local route = track_routing(tracks)
    local proj_len = reaper.GetProjectLength(0)
    local song = summarize_master(max_sec, run_id)
    if song.samples <= 0 then return nil, "the master has no valid data" end
    song.mi = summarize_master(max_sec, run_id, nil, nil, true) -- master input (before the master FX)
    song.mid_db, song.side_db = {}, {}
    for b = 1, 15 do
        song.mid_db[b] = convert_energy_to_db(song.mid[b], song.samples, offsets[b])
        song.side_db[b] = convert_energy_to_db(song.side[b], song.samples, offsets[b])
    end
    local D = { song = song, over = {}, regions = {}, proj_len = proj_len, tracks_with_data = 0, dropped = 0, tracks = tracks, route = route }

    -- Stats of one track (read from its phantom, so after its own fader, pan and automation) over seconds s0 .. s1 - 1
    -- (w = region weights or nil); nil when the track has no data there
    local function window(r, t, s0, s1, w)
        local opts = w and { weight = w, tie_sec = s0 } or nil
        local s = summarize_track(t.slot, s1, run_id, s0, opts)
        if s.secs == 0 or s.samples <= 0 then return nil end
        local d = { s = s, t = t, r = r }
        local mean_ke = s.ke / s.samples
        d.L = lufs(mean_ke)
        d.pk = level_db(s.peak)
        d.crest, d.act = s.crest_med, s.act_pct
        local mm, ss = (s.ll + s.rr + 2 * s.lr) / 4, (s.ll + s.rr - 2 * s.lr) / 4
        local rm, rs = math.sqrt(math.max(mm, 0)), math.sqrt(math.max(ss, 0))
        d.width = (rm + rs) > 0 and 100 * rs / (rm + rs) or 0
        d.corr = (s.ll * s.rr > 0) and s.lr / math.sqrt(s.ll * s.rr) or 1
        local sub_corr = (s.sub_ll * s.sub_rr > 0) and s.sub_lr / math.sqrt(s.sub_ll * s.sub_rr) or 1
        d.sub_risk = convert_energy_to_db((s.sub_ll + s.sub_rr) / 2, s.samples) > -50.0 and sub_corr < 0
        d.bands = {}
        for b = 1, 15 do d.bands[b] = convert_energy_to_db(s.bands[b], s.samples, offsets[b]) end
        d.notable = notable_bands(d.bands)
        -- measured pan balance p = 100 * (RR - LL) / (RR + LL): includes pan automation, width and every pan mode (not the parent's pan)
        local pw = s.ll + s.rr
        local p = pw > 0 and 100 * (s.rr - s.ll) / pw or 0
        d.pan100 = p >= 0 and math.floor(p + 0.5) or -math.floor(-p + 0.5)
        d.num = mean_ke -- E: the K energy per sample this track puts out (after its own fader and pan, not its parent's)
        d.reasons = {}
        for _, x in ipairs(r.reasons) do d.reasons[#d.reasons + 1] = x end
        return d
    end

    -- Contribution C of every track: a top-level track or bus counts with its own measured energy E; a child of a folder bus gets
    -- E x (C of the bus / sum of E over the bus's counted children), so the children always add up to the bus's measured output.
    -- Share = 100 x C / sum of C over all non-bus tracks (adds up to 100); folder buses get no share. d.gain_lin = C / E (energy factor).
    -- Returns the sum of E over the top-level tracks (self-check against the master input).
    local function normalise(list)
        local by, sum_e = {}, {}
        for _, d in ipairs(list) do by[d.t.idx] = d end
        for _, d in ipairs(list) do
            local p = d.r.parent
            if p and by[p] then sum_e[p] = (sum_e[p] or 0) + d.num end
        end
        local function contrib(d)
            if not d.C then
                local p = d.r.parent
                if p and by[p] then
                    d.gain_lin = (sum_e[p] or 0) > 0 and contrib(by[p]) / sum_e[p] or 0
                else
                    d.gain_lin = 1
                end
                d.C = d.num * d.gain_lin
            end
            return d.C
        end
        local tot, top = 0, 0
        for _, d in ipairs(list) do
            contrib(d)
            if d.r.role ~= "bus" then tot = tot + d.C end
            if not (d.r.parent and by[d.r.parent]) then top = top + d.num end
        end
        for _, d in ipairs(list) do
            d.share = d.r.role ~= "bus" and (tot > 0 and 100 * d.C / tot or 0) or nil
        end
        return top
    end

    -- Tracks with a direct path to the master; the others are not counted (see track_routing)
    local live = {}
    for _, t in ipairs(tracks) do
        if route[t.idx].no_direct then D.dropped = D.dropped + 1 else live[#live + 1] = t end
    end

    -- Whole song (also the seconds between regions)
    for _, t in ipairs(live) do
        local d = window(route[t.idx], t, 0, max_sec, nil)
        if d then
            D.over[#D.over + 1] = d
            D.tracks_with_data = D.tracks_with_data + 1
        end
    end
    -- Task 4f.8: per-second copy for the time-gated backdrop and competitors (send time reads no gmem). D.ps[idx][sec * 18 + k]:
    -- k = 1 K energy, 2-16 mid bands 1-15, 17 active sub-blocks, 18 eligible sub-blocks (all 0 when the second has no valid record)
    D.ps, D.offsets = {}, offsets
    for _, t in ipairs(live) do
        local p = {}
        for sec = 0, max_sec - 1 do
            local b, o = MA_HDR + (t.slot * MA_MAXSEC + sec) * MA_STRIDE, sec * 18
            local ok = reaper.gmem_read(b + 7) == run_id
            p[o + 1] = ok and reaper.gmem_read(b + 5) or 0
            for k = 1, 15 do p[o + 1 + k] = ok and reaper.gmem_read(b + 7 + k) or 0 end
            p[o + 17] = ok and reaper.gmem_read(b + MA_S_ACTIVE) or 0
            p[o + 18] = ok and reaper.gmem_read(b + MA_S_ELIG) or 0
        end
        D.ps[t.idx] = p
    end
    -- Master "Volume (Pre-FX)" envelope: it scales everything before the master FX, so the master input analyzer hears the top-level
    -- tracks times this gain (task 4c: a -3.35 dB curve explained a steady +3.3 dB check). pre_g2(t0, t1) returns the mean energy
    -- factor (gain squared) over [t0, t1), sampled every 100 ms, plus the lowest and highest gain; 1, 1, 1 without an active envelope.
    local menv = reaper.GetTrackEnvelopeByName(reaper.GetMasterTrack(0), "Volume (Pre-FX)")
    if menv then
        local ok, act = reaper.GetSetEnvelopeInfo_String(menv, "ACTIVE", "", false)
        if ok and act == "0" then menv = nil end
    end
    local function pre_g2(t0, t1)
        if not menv then return 1, 1, 1 end
        local mode, sum, n, gmin, gmax = reaper.GetEnvelopeScalingMode(menv), 0, 0, math.huge, 0
        for t = t0 + 0.05, t1, 0.1 do
            local _, v = reaper.Envelope_Evaluate(menv, t, 0, 0)
            local g = reaper.ScaleFromEnvelopeMode(mode, v)
            sum, n, gmin, gmax = sum + g * g, n + 1, math.min(gmin, g), math.max(gmax, g)
        end
        if n == 0 then return 1, 1, 1 end
        return sum / n, gmin, gmax
    end
    -- self-check: the top-level tracks (phantoms) x the master pre-FX gain against the master input, in dB. Expect about -3 to 0: tracks
    -- that partly add up in phase make the real mix louder than the plain sum of their energies.
    local function top_check(top, mi, g2)
        return (mi and mi.samples > 0 and top > 0 and mi.ke > 0) and 10 * math.log(top * g2 / (mi.ke / mi.samples), 10) or nil
    end
    local g2, gmin, gmax = pre_g2(0, proj_len)
    if menv then D.pre_fx = { lo = level_db(gmin), hi = level_db(gmax) } end
    D.song_chk = top_check(normalise(D.over), song.mi, g2)

    -- Regions (without regions: the whole song as one region); region ends are clipped to the project length
    local regs = {}
    for _, e in ipairs(get_arrangement_markers() or {}) do
        local e_end = e.end_s and math.min(e.end_s, proj_len)
        if e_end and e_end > e.start_s then regs[#regs + 1] = { name = e.name, start_s = e.start_s, end_s = e_end } end
    end
    table.sort(regs, function(a, b) return a.start_s < b.start_s end)
    if #regs == 0 then regs[1] = { name = "Song", start_s = 0, end_s = proj_len } end

    local total_w, covered, cover_end, n_na = 0, 0, 0, 0
    for _, rg in ipairs(regs) do
        local s0, s1, w = MA_A.reg_win(rg.start_s, rg.end_s)
        local wsum = 0
        for sec = s0, s1 - 1 do wsum = wsum + w[sec] end
        total_w = total_w + wsum
        if rg.end_s > math.max(rg.start_s, cover_end) then
            covered = covered + rg.end_s - math.max(rg.start_s, cover_end)
            cover_end = rg.end_s
        end

        local reg = { name = rg.name, start_s = rg.start_s, end_s = rg.end_s, wsum = wsum, all = {}, sel = {}, mask = {}, approx = {} }
        D.regions[#D.regions + 1] = reg
        if wsum < 1 then
            reg.na = true
            n_na = n_na + 1
        else
            local blk0, blk1 = math.ceil(rg.start_s * 10 - 1e-6), math.floor(rg.end_s * 10 + 1e-6) - 1
            local mr = blk1 >= blk0 and summarize_master(max_sec, run_id, blk0, blk1) or nil
            if mr and mr.samples > 0 then
                reg.mr = mr
                reg.mi = summarize_master(max_sec, run_id, blk0, blk1, true)
                -- width from the calibrated mid and side band energies
                local em, es = 0, 0
                for b = 1, 15 do
                    local c = 10 ^ (offsets[b] / 10)
                    em, es = em + mr.mid[b] * c, es + mr.side[b] * c
                end
                local rm, rs = math.sqrt(em), math.sqrt(es)
                reg.width = (rm + rs) > 0 and 100 * rs / (rm + rs) or 0
                -- band deviations from the song average (mid bands), normalised by the loudness difference
                reg.dev = {}
                if mr.integrated > -70 and song.integrated > -70 then
                    for b = 1, 15 do
                        local rb = convert_energy_to_db(mr.mid[b], mr.samples, offsets[b])
                        if rb > -143 and song.mid_db[b] > -143 then
                            local dev = (rb - song.mid_db[b]) - (mr.integrated - song.integrated)
                            if math.abs(dev) >= MA_A.REGION_DEV_DB - 1e-9 then
                                reg.dev[#reg.dev + 1] = { key = MA_A.KEYS[b], dev = dev, band = b }
                            end
                        end
                    end
                end

                local cand = {}
                for _, t in ipairs(live) do
                    local r = route[t.idx]
                    local d = window(r, t, s0, s1, w)
                    if d then
                        reg.all[#reg.all + 1] = d
                        if r.role ~= "bus" and MA_A.plays(d) then cand[#cand + 1] = d end
                    end
                end
                reg.chk = top_check(normalise(reg.all), reg.mi, (pre_g2(rg.start_s, rg.end_s)))
                table.sort(cand, function(a, b) return a.share > b.share end)
                for i = 1, math.min(MA_A.TOP_N, #cand) do reg.sel[i] = cand[i] end

                -- Masking: see MA_A.mask_band (task 5e: only over the seconds the tracks play together)
                for b = 1, 15 do
                    local list, cen = MA_A.mask_band(D, reg, b, reg.sel)
                    if list then reg.mask[#reg.mask + 1] = { band = b, list = list, cen = cen } end
                end
                for _, d in ipairs(reg.sel) do
                    if #d.reasons > 0 then reg.approx[#reg.approx + 1] = d end
                end
            end
        end
    end
    D.check = { weights = total_w, gaps = proj_len - covered, n_na = n_na }
    for _, t in ipairs(tracks) do t.guid = reaper.GetTrackGUID(t.track) end -- task 4f.6: tracks are found by GUID at send time
    local stamped = reaper.gmem_read(MA_H_MSTAMP) == run_id
    D.m_peak = stamped and (level_db(reaper.gmem_read(MA_H_MPEAK)) + level_db(reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "D_VOL"))) or nil
    D.m_clips = stamped and math.floor(reaper.gmem_read(MA_H_MCLIPS) + 0.5) or nil
    return D
end

--- Stage 6: the whole seconds a region touches (s0 .. s1 - 1) and each second's weight (the part of that second inside the region).
function MA_A.reg_win(start_s, end_s)
    local s0, s1, w = math.floor(start_s + 1e-9), math.ceil(end_s - 1e-9), {}
    for sec = s0, s1 - 1 do w[sec] = math.max(0, math.min(1, math.min(sec + 1, end_s) - math.max(sec, start_s))) end
    return s0, s1, w
end

--- Stage 6: the track plays in this second (the act rule per second); p = the track's per-second copy D.ps[idx], see collect_region_data.
function MA_A.on_sec(p, sec)
    local k = sec * 18
    return p ~= nil and (p[k + 18] or 0) > 0 and 100 * p[k + 17] / p[k + 18] >= MA_A.ACTIVE_MIN_PCT
end

--- Stage 6: the track counts as playing in a song or region entry (the act rule over the whole span).
function MA_A.plays(d) return d and d.act and d.act >= MA_A.ACTIVE_MIN_PCT end

--- Task 5e: masking in band b of a region among the tracks of pool. A pair counts when it is not on opposite sides, plays together for at
--- least MASK_OVERLAP % of the shorter track's playing seconds, and over those seconds each holds >= MASK_SHARE of the band energy of all
--- non-bus tracks. Returns the tracks of the counting pairs { d, sh } (loudest first; sh = the track's largest share in such a pair, so never
--- under MASK_SHARE) and cen (the calibrated band energy over the seconds of those pairs: the weight when a merged range's shares are combined), or nil.
function MA_A.mask_band(D, reg, b, pool)
    local A, P = MA_A, D.ps
    local s0, s1, w = MA_A.reg_win(reg.start_s, reg.end_s)
    local tot = {}
    for sec = s0, s1 - 1 do tot[sec] = 0 end
    for _, d in ipairs(reg.all) do
        local p = P[d.t.idx]
        if p and d.r.role ~= "bus" then
            for sec = s0, s1 - 1 do tot[sec] = tot[sec] + (p[sec * 18 + 1 + b] or 0) * d.gain_lin end
        end
    end
    local function total(g)
        local s = 0
        for sec = s0, s1 - 1 do
            if g[sec] then s = s + tot[sec] * g[sec] end
        end
        return s
    end
    local function energy(d, g)
        local p, s = P[d.t.idx], 0
        if not p then return 0 end
        for sec = s0, s1 - 1 do
            if g[sec] then s = s + (p[sec * 18 + 1 + b] or 0) * g[sec] end
        end
        return s * d.gain_lin
    end
    -- the seconds each track plays (the act rule per second, as in the compete lines)
    local on, time = {}, {}
    for _, d in ipairs(pool) do
        local p, o, t = P[d.t.idx], {}, 0
        for sec = s0, s1 - 1 do
            if A.on_sec(p, sec) then
                o[sec] = true
                t = t + w[sec]
            end
        end
        on[d], time[d] = o, t
    end
    local inc, union = {}, {}
    for x = 1, #pool do
        for y = x + 1, #pool do
            local a, c = pool[x], pool[y]
            if math.abs(a.pan100 - c.pan100) <= A.MASK_PAN then
                local g, both = {}, 0
                for sec = s0, s1 - 1 do
                    if on[a][sec] and on[c][sec] then g[sec] = w[sec]; both = both + w[sec] end
                end
                local short = math.min(time[a], time[c])
                if short > 0 and 100 * both / short >= A.MASK_OVERLAP then
                    local den = total(g)
                    local sa, sc = den > 0 and energy(a, g) / den or 0, den > 0 and energy(c, g) / den or 0
                    if sa >= A.MASK_SHARE and sc >= A.MASK_SHARE then
                        inc[a], inc[c] = math.max(inc[a] or 0, sa), math.max(inc[c] or 0, sc)
                        for sec, wt in pairs(g) do union[sec] = wt end
                    end
                end
            end
        end
    end
    local den = total(union)
    if not next(inc) or den <= 0 then return nil end
    local list = {}
    for _, d in ipairs(pool) do
        if inc[d] then list[#list + 1] = { d = d, sh = inc[d] } end
    end
    table.sort(list, function(x, y) return x.sh > y.sh end)
    return list, den * 10 ^ (D.offsets[b] / 10)
end

--- Task 4f.6: number and text helpers shared by the report (print_region_summary) and the data block (build_data_block)
function MA_A.fmt()
    local function f1(v) return (v and math.abs(v) < 1e6) and string.format("%.1f", v) or "n/a" end
    local function n1(v) return (v and v > -143) and string.format("%.1f", v) or "n/a" end
    local function i0(v) return (v and math.abs(v) < 1e9) and string.format("%d", math.floor(v + 0.5)) or "n/a" end
    local function c2(v) return (string.format("%.2f", v):gsub("^(%-?)0%.", "%1.")) end
    local function nm(s) return (s:gsub("%s+", "_")) end
    -- Master chain effect: input (before the master FX) against output (after them), per song or region. Whole spans only, never per block.
    local function chain(mi, mo)
        if not (mi and mi.samples > 0 and mi.integrated > -70 and mo.integrated > -70) then return nil end
        return string.format("chain in I%s M%s LRA%s gain%+.1f", f1(mi.integrated), f1(mi.max_m), f1(mi.lra), mo.integrated - mi.integrated) -- task 5e2: "out" = the line above
    end
    local function pan_label(p) return p == 0 and "pC" or (p < 0 and ("pL" .. -p) or ("pR" .. p)) end
    local function devs(list, int)
        local l = {}
        for _, e in ipairs(list) do
            l[#l + 1] = e.key .. (int and string.format("%+d", math.floor(e.dev + 0.5)) or string.format("%+.1f", e.dev))
        end
        return table.concat(l, " ")
    end
    -- Masking entries of a region: neighbouring bands with the same set of tracks become one Hz range ("20-200Hz: Pad 56, Intro_Pad 40");
    -- the numbers are each track's share of the total energy of the whole range (band shares weighted by the band energy `cen`).
    local function mask_ranges(reg, name)
        local res, g = {}, nil
        local function flush()
            if not g then return end
            local sum, tot, order, who = {}, 0, {}, {}
            for _, m in ipairs(g.ms) do
                tot = tot + m.cen
                for _, e in ipairs(m.list) do
                    if not sum[e.d] then sum[e.d] = 0; order[#order + 1] = e.d end
                    sum[e.d] = sum[e.d] + e.sh * m.cen
                end
            end
            table.sort(order, function(x, y) return sum[x] > sum[y] end)
            for _, d in ipairs(order) do who[#who + 1] = name(d.t.name) .. " " .. i0(100 * sum[d] / tot) end
            res[#res + 1] = string.format("%g-%gHz: %s", B15_EDGES[g.lo], B15_EDGES[g.hi + 1], table.concat(who, ", "))
        end
        for _, m in ipairs(reg.mask) do
            local ids = {}
            for _, e in ipairs(m.list) do ids[#ids + 1] = e.d.t.idx end
            table.sort(ids)
            local key = table.concat(ids, ",")
            if g and g.key == key and m.band == g.hi + 1 then
                g.hi = m.band
                g.ms[#g.ms + 1] = m
            else
                flush()
                g = { lo = m.band, hi = m.band, key = key, ms = { m } }
            end
        end
        flush()
        return res
    end
    -- Stage 6: the data keys of one track line, the same in the data block and Track Detail (the legend explains them)
    local function track_keys(d, show_sub)
        return string.format("L%s pk%s%s a%s W%s c%s %s%s", f1(d.L), f1(d.pk), d.crest and (" cr" .. i0(d.crest)) or "", i0(d.act),
            i0(d.width), c2(d.corr), pan_label(d.pan100), (d.sub_risk and show_sub) and " sub!" or "")
    end
    return f1, n1, i0, c2, nm, chain, pan_label, devs, mask_ranges, track_keys
end

--- Stage 6: what differs per focus mode (AI.FOCUS[i].mode; no focus = song). build_data_block runs the common flow (SONG, TRACKS, REGIONS, mask,
-- approx) and asks the mode's part. All fields are optional. B = what the parts share (see build_data_block).
--   start(B): prepare; may set B.bl, B.bh (band range), B.rs (share of the range), B.rlev (range levels text), B.listed (see the return values below)
--   keep(B, d): TRACKS, does this playing track get a line; devs(B, list): the band deviations to show
--   track_extra(B, d, clip): TRACKS, returns the clip text, the levels text and the automation text
--   quiet_region(B, i): header-only region; region(B, i, reg): returns the full lines, the approx tracks, the mask holder, role[d], extra text lines
--   all_lines: no minimum share for a region line; also: add the "R n also" line
--   finish(B, named): at the end; may return a new named list; legend(focus): the legend lines of this mode
MA_A.PARTS = { song = { also = true }, group = { all_lines = true }, band = { all_lines = true }, stereo = { also = true }, master = {} }

function MA_A.PARTS.group.start(B)
    local D, plays = B.D, MA_A.plays
    local inF, inR, freg, played, listed = B.fs.F, B.fs.R, {}, {}, {}
    -- focus regions (an F track plays there) and the tracks that play in at least one of them
    for i, reg in ipairs(D.regions) do
        if not reg.na and reg.mr then
            for _, d in ipairs(reg.all) do
                if inF[d.t.idx] and plays(d) then freg[i] = true break end
            end
            if freg[i] then
                for _, d in ipairs(reg.all) do if plays(d) then played[d.t.idx] = true end end
            end
        end
    end
    for _, t in ipairs(D.tracks) do
        if played[t.idx] or inF[t.idx] or inR[t.idx] then listed[t.guid] = true end
    end
    B.inF, B.inR, B.freg, B.played, B.listed = inF, inR, freg, played, listed
end

function MA_A.PARTS.group.keep(B, d)
    local x = d.t.idx
    return B.played[x] or B.inF[x] or B.inR[x]
end

function MA_A.PARTS.group.quiet_region(B, i) return not B.freg[i] end

-- task 4f.7b: a focus track (4f.8: and a return) also gets its clips, the peak before its fader and all 15 band levels; 4f.9: its automation points
function MA_A.PARTS.group.track_extra(B, d, clip)
    if not (B.inF[d.t.idx] or B.inR[d.t.idx]) then return clip, "" end
    local l, KEYS, i0 = {}, MA_A.KEYS, B.i0
    for b = 1, 15 do l[b] = KEYS[b] .. i0(d.bands[b]) end
    return string.format(" clip%.0f prepk%s", d.s.clips, B.f1(d.pk - d.r.fader_db)), " | levels " .. table.concat(l, " "), B.fs.auto and B.fs.auto[d.t.idx]
end

-- task 4f.8: time-gated roles and the compete lines. w = region weight per second; on(d, sec) = d plays in that second
function MA_A.PARTS.group.region(B, i, reg)
    local D, inF, inR, nm, i0, plays = B.D, B.inF, B.inR, B.nm, B.i0, MA_A.plays
    local P, OFF, A = D.ps, D.offsets, MA_A
    local s0, s1, w = A.reg_win(reg.start_s, reg.end_s)
    local function on(d, sec) return A.on_sec(P[d.t.idx], sec) end
    local role, comp_lines = {}, {} -- role[d] = { "focus", "competitor", ... }
    -- weighted sum over the seconds of g (g[sec] = weight): k = record slot (1 K energy, 1 + b band b); nil k = play time
    local function sum(d, g, k)
        local p, s = P[d.t.idx], 0
        if not p then return 0 end
        for sec = s0, s1 - 1 do
            local wt = g[sec]
            if wt then
                if k then s = s + (p[sec * 18 + k] or 0) * wt elseif on(d, sec) then s = s + wt end
            end
        end
        return s
    end
    local function addrole(d, r)
        local l = role[d]
        if not l then l = {}; role[d] = l end
        for _, x in ipairs(l) do if x == r then return end end
        l[#l + 1] = r
    end
    -- focus tracks and returns that play here; gate = the seconds where at least one focus track plays
    local cand, fl, gate, gw = {}, {}, {}, 0
    for _, d in ipairs(reg.all) do
        if (inF[d.t.idx] or inR[d.t.idx]) and plays(d) then addrole(d, inF[d.t.idx] and "focus" or "return") end
        if d.r.role ~= "bus" then
            cand[#cand + 1] = d
            if inF[d.t.idx] and plays(d) then fl[#fl + 1] = d end
        end
    end
    for sec = s0, s1 - 1 do
        if w[sec] > 0 then
            for _, d in ipairs(reg.all) do
                if inF[d.t.idx] and plays(d) and on(d, sec) then gate[sec] = w[sec]; gw = gw + w[sec] break end
            end
        end
    end
    -- backdrop: the BACKDROP_N other tracks with the most energy (scaled like the shares) while a focus track plays
    local bd, ge = {}, {}
    for _, d in ipairs(cand) do
        if not inF[d.t.idx] and not inR[d.t.idx] and gw > 0 and 100 * sum(d, gate) / gw >= A.ACTIVE_MIN_PCT then
            ge[d] = sum(d, gate, 1) * d.gain_lin
            bd[#bd + 1] = d
        end
    end
    table.sort(bd, function(a, b) return ge[a] > ge[b] end)
    for k = 1, math.min(A.BACKDROP_N, #bd) do addrole(bd[k], "backdrop") end
    -- competitors of each focus track f, over the seconds where f plays (gf): its main bands are within COMP_MAIN_DB of its
    -- loudest band; a competitor is another track, not on the opposite side, at least f - COMP_DB in such a band
    for _, f in ipairs(fl) do
        local gf, nf = {}, 0
        for sec = s0, s1 - 1 do
            if w[sec] > 0 and on(f, sec) then gf[sec] = w[sec]; nf = nf + w[sec] end
        end
        if nf > 0 then
            local ef, top, cs = {}, 0, {}
            for b = 1, 15 do
                ef[b] = sum(f, gf, 1 + b) * f.gain_lin * 10 ^ (OFF[b] / 10)
                top = math.max(top, ef[b])
            end
            for _, o in ipairs(cand) do
                if o ~= f and math.abs(o.pan100 - f.pan100) <= A.MASK_PAN then
                    local ov = 100 * sum(o, gf) / nf -- o = % of f's playing seconds where the competitor plays too
                    if ov >= A.ACTIVE_MIN_PCT then
                        local e = {}
                        for b = 1, 15 do e[b] = sum(o, gf, 1 + b) * o.gain_lin * 10 ^ (OFF[b] / 10) end
                        cs[#cs + 1] = { d = o, e = e, ov = ov }
                    end
                end
            end
            -- neighbouring main bands with the same competitor set merge into one range (b = 16 closes the last one)
            local ranges, g = {}, nil
            for b = 1, 16 do
                local key, set = nil, {}
                if b <= 15 and top > 0 and ef[b] > 0 and ef[b] >= top * 10 ^ (-A.COMP_MAIN_DB / 10) then
                    local ids = {}
                    for _, c in ipairs(cs) do
                        if c.e[b] >= ef[b] * 10 ^ (-A.COMP_DB / 10) then set[#set + 1] = c; ids[#ids + 1] = c.d.t.idx end
                    end
                    if #set > 0 then key = table.concat(ids, ",") end
                end
                if g and key == g.key then
                    g.hi = b
                else
                    if g then ranges[#ranges + 1] = g end
                    g = key and { lo = b, hi = b, key = key, set = set } or nil
                end
            end
            for _, r in ipairs(ranges) do
                local sf = 0
                for b = r.lo, r.hi do sf = sf + ef[b] end
                r.items = {}
                for _, c in ipairs(r.set) do
                    local so = 0
                    for b = r.lo, r.hi do so = so + c.e[b] end
                    r.items[#r.items + 1] = { c = c, db = 10 * math.log(so / sf, 10) }
                end
                table.sort(r.items, function(x, y) return x.db > y.db end)
                r.top = r.items[1].db
            end
            table.sort(ranges, function(x, y) return x.top > y.top end)
            local parts = {}
            for k = 1, math.min(A.COMP_N, #ranges) do
                local r, it = ranges[k], {}
                for j = 1, math.min(A.COMP_N, #r.items) do
                    local x = r.items[j]
                    addrole(x.c.d, "competitor")
                    it[#it + 1] = string.format("%s %+d%s", nm(x.c.d.t.name), math.floor(x.db + 0.5),
                        x.c.ov >= 99.5 and "" or (" o" .. i0(x.c.ov))) -- no o = plays the whole time
                end
                parts[#parts + 1] = string.format("%g-%gHz: %s", B15_EDGES[r.lo], B15_EDGES[r.hi + 1], table.concat(it, ", "))
            end
            if #parts > 0 then comp_lines[#comp_lines + 1] = string.format(" compete %s %s", nm(f.t.name), table.concat(parts, "; ")) end
        end
    end
    -- full lines: focus tracks and returns in track order, then backdrop and competitors by share; the rest on the "others" line
    local lines, rest, apx = {}, {}, {}
    local extra = {}
    for _, d in ipairs(reg.all) do
        if role[d] then
            if inF[d.t.idx] or inR[d.t.idx] then lines[#lines + 1] = d else extra[#extra + 1] = d end
        elseif d.r.role ~= "bus" and plays(d) then rest[#rest + 1] = d end
    end
    table.sort(extra, function(a, b) return (a.share or 0) > (b.share or 0) end)
    for _, d in ipairs(extra) do lines[#lines + 1] = d end
    table.sort(rest, function(a, b) return a.share > b.share end)
    for _, d in ipairs(lines) do if #d.reasons > 0 then apx[#apx + 1] = d end end
    local tail, o = {}, {}
    for _, d in ipairs(rest) do
        if d.share >= A.MIN_SHARE then o[#o + 1] = nm(d.t.name) .. " s" .. i0(d.share) end
    end
    if #o > 0 then tail[#tail + 1] = string.format(" R%d others %s", i, table.concat(o, ", ")) end
    for _, s in ipairs(comp_lines) do tail[#tail + 1] = s end
    return lines, apx, { mask = {} }, role, tail -- the compete lines replace the mask line
end

function MA_A.PARTS.group.finish(B, named) -- task 4f.7b: focus tracks and returns keep full plugin settings even where they do not play
    for _, t in ipairs(B.D.tracks) do
        if B.inF[t.idx] or B.inR[t.idx] then named[t.guid] = true end
    end
    for g in pairs(named) do B.listed[g] = true end -- task 4f.8: a competitor never gets a bare YAML line
end

function MA_A.PARTS.group.legend()
    local A = MA_A
    return { "",
            "FOCUS DATA (see FOCUS at the end):",
            "- TRACKS: focus tracks and returns also show clip n, prepk = sample peak before their own fader (dB) and \"levels\" = all 15 band levels (dB). Tracks that never play while a focus track plays are left out.",
            "- auto (under a TRACKS line): the track's envelopes over the whole song, ENVELOPE unit: value@seconds ...; the curve follows straight lines between the points within " .. string.format("%g", A.AUTO_TOL_DB) .. " dB (volume), " .. string.format("%g", A.AUTO_TOL_PCT) .. "% (pan, width) or " .. string.format("%g", A.AUTO_TOL_FX_PCT) .. "% of a plugin parameter's range; ~ = over " .. MA_A.AUTO_MAX .. " points, drawn coarser; envelopes that never move are left out; Mute lists the switching points. Send_Volume>NAME = the send to NAME, PLUGIN/PARAM = a plugin parameter. The measured numbers already include the automation.",
            "- REGIONS: \"no focus track plays\" = master numbers only. Otherwise full lines with the track's role in brackets: focus; return = receives audio from a focus track (reverb, delay, parallel bus); backdrop = one of the " .. A.BACKDROP_N .. " loudest other tracks while focus tracks play; competitor = see compete. Focus tracks and returns first (track order), then the rest by share; line numbers cover the whole region. \"R n others\" = the remaining playing tracks with their share (under " .. string.format("%g", A.MIN_SHARE) .. "% left out); replaces \"R n also\".",
            "- compete NAME range: TRACK +n oN: main bands of NAME = within " .. string.format("%g", A.COMP_MAIN_DB) .. " dB of its loudest band; a competitor is at most " .. string.format("%g", A.COMP_DB) .. " dB quieter than NAME in such a band and not panned to the opposite side. +n = competitor level against NAME in that range (dB, + = louder); o = % of NAME's playing seconds when the competitor plays too (no o = all of them). Over the seconds NAME plays in the region, not moment by moment; at most " .. A.COMP_N .. " ranges, strongest first. Replaces the mask lines.",
            "- YAML: tracks left out of the data show only name, parent and flags." }
end

-- task 4f.10: only the bands focus.lo..focus.hi. rs[d] = % of the range energy among the counted tracks of d's list; inB[idx] = >= TOPIC_PCT in a region
function MA_A.PARTS.band.start(B)
    local D, focus, rs, plays = B.D, B.focus, B.rs, MA_A.plays
    local bl, bh, inB, KEYS, i0 = focus.lo, focus.hi, {}, MA_A.KEYS, B.i0
    B.bl, B.bh, B.inB, B.listed = bl, bh, inB, {}
    local function range_share(list)
        local e, tot = {}, 0
        for _, d in ipairs(list) do
            if d.r.role ~= "bus" then
                local x = 0
                for b = bl, bh do x = x + d.s.bands[b] * d.gain_lin * 10 ^ (D.offsets[b] / 10) end
                e[d], tot = x, tot + x
            end
        end
        for d, x in pairs(e) do rs[d] = tot > 0 and 100 * x / tot or 0 end
    end
    range_share(D.over)
    for _, reg in ipairs(D.regions) do
        if not reg.na and reg.mr then
            range_share(reg.all)
            for _, d in ipairs(reg.all) do
                if plays(d) and (rs[d] or 0) >= MA_A.TOPIC_PCT then inB[d.t.idx] = true end
            end
        end
    end
    for _, t in ipairs(D.tracks) do if inB[t.idx] then B.listed[t.guid] = true end end
    function B.rlev(d) -- the track's band levels inside the range (whole dB)
        local l = {}
        for b = bl, bh do l[#l + 1] = KEYS[b] .. i0(d.bands[b]) end
        return " | levels " .. table.concat(l, " ")
    end
end

function MA_A.PARTS.band.keep(B, d) return B.inB[d.t.idx] end

function MA_A.PARTS.band.devs(B, list) -- the deviations inside the range
    local l = {}
    for _, e in ipairs(list) do if e.band >= B.bl and e.band <= B.bh then l[#l + 1] = e end end
    return l
end

function MA_A.PARTS.band.track_extra(B, d, clip) return clip, B.rlev(d) end

-- every playing track with >= TOPIC_PCT of the range here, highest rs first, and the masking rule over these tracks inside the range
function MA_A.PARTS.band.region(B, i, reg)
    local rs, c, lines, apx, mreg = B.rs, {}, {}, {}, { mask = {} }
    for _, d in ipairs(reg.all) do
        if d.r.role ~= "bus" and MA_A.plays(d) then c[#c + 1] = d end
    end
    table.sort(c, function(a, b) return rs[a] > rs[b] end)
    for _, d in ipairs(c) do if rs[d] >= MA_A.TOPIC_PCT then lines[#lines + 1] = d end end
    for b = B.bl, B.bh do
        local list, cen = MA_A.mask_band(B.D, reg, b, lines) -- task 5e: only the listed tracks; a brief track off the list can top a quiet band in its few seconds
        if list then mreg.mask[#mreg.mask + 1] = { band = b, list = list, cen = cen } end
    end
    for _, d in ipairs(lines) do if #d.reasons > 0 then apx[#apx + 1] = d end end
    return lines, apx, mreg
end

function MA_A.PARTS.band.finish(B, named) -- task 4f.10: a named track never gets a bare YAML line
    for g in pairs(named) do B.listed[g] = true end
end

function MA_A.PARTS.band.legend(topic)
    local A = MA_A
        local r = string.format("%g-%g Hz", B15_EDGES[topic.lo], B15_EDGES[topic.hi + 1])
    return { "", "TOPIC DATA (see FOCUS at the end):",
        "- Only tracks with at least " .. A.TOPIC_PCT .. "% of the " .. r .. " energy in some region. Band data (SONG mid / side, bumps, region deviations) only inside " .. r .. ".",
                "- rs = % of the " .. r .. " energy (all counted tracks add up to 100; s stays the share of the whole mix); levels = the track's band levels in that range (dB).",
                "- REGIONS: every track with rs " .. A.TOPIC_PCT .. " or more there, highest rs first; no \"also\" line; mask = the same rule over these tracks, inside the range only.",
                "- YAML: tracks left out of the data show only name, parent and flags." }
end

function MA_A.PARTS.stereo.devs() return {} end -- no band deviations

function MA_A.PARTS.stereo.region(B, i, reg) return reg.sel, reg.approx, { mask = {} } end

function MA_A.PARTS.stereo.legend()
    return { "", "TOPIC DATA (see FOCUS at the end):",
        "- Band data left out (bumps, region band deviations, mask lines); the SONG line keeps the master mid and side bands." }
end

-- the loudest tracks until they cover MASTER_PCT (MASTER_MIN to MASTER_MAX lines, none under MIN_SHARE), no mask line
function MA_A.PARTS.master.region(B, i, reg)
    local c, lines, apx, sum = {}, {}, {}, 0
    for _, d in ipairs(reg.all) do
        if d.r.role ~= "bus" and MA_A.plays(d) then c[#c + 1] = d end
    end
    table.sort(c, function(a, b) return a.share > b.share end)
    for _, d in ipairs(c) do
        if #lines >= MA_A.MASTER_MAX or d.share < MA_A.MIN_SHARE or (sum >= MA_A.MASTER_PCT and #lines >= MA_A.MASTER_MIN) then break end
        lines[#lines + 1] = d
        sum = sum + d.share
    end
    for _, d in ipairs(lines) do if #d.reasons > 0 then apx[#apx + 1] = d end end
    return lines, apx, { mask = {} }
end

function MA_A.PARTS.master.finish() return {} end -- task 4f.10: only the master keeps full plugin settings (an empty list, not nil = the old YAML)

function MA_A.PARTS.master.legend()
    local A = MA_A
    return { "", "TOPIC DATA (see FOCUS at the end):",
        string.format("- REGIONS: the loudest tracks until they cover %d%% of the region (%d to %d lines, none under %d%%); no \"also\" and mask lines.",
                A.MASTER_PCT, A.MASTER_MIN, A.MASTER_MAX, A.MIN_SHARE),
                "- YAML: only the master lists full plugin settings; every track lists plugin names only." }
end

--- Task 4f.6: the data block of the prompt from the stored measurements (D = the collect_region_data result), so it can be rebuilt at
-- send time without reading gmem. focus = an AI.FOCUS entry; nil gives the Whole Song text. fs = { F = {[idx] = true}, R = {[idx] = true}, auto }
-- for a group focus (F = focus tracks, R = their returns), nil otherwise. Returns the text, the GUIDs of the tracks it names (they keep full
-- plugin settings in the YAML), the number of tracks left out of TRACKS and, for group and band, the GUIDs of every track the data mentions
-- (the others get a bare YAML line).
local function build_data_block(D, focus, fs)
    local f1, _, i0, c2, nm, chain, pan_label, devs, mask_ranges, track_keys = MA_A.fmt()
    local song, KEYS, m_peak, m_clips = D.song, MA_A.KEYS, D.m_peak, D.m_clips
    local song_chain = chain(song.mi, song)
    local plays, part = MA_A.plays, MA_A.PARTS[focus and focus.mode or "song"]
    local B = { D = D, focus = focus, fs = fs, bl = 1, bh = 15, rs = {}, f1 = f1, i0 = i0, nm = nm }
    if part.start then part.start(B) end
    local bl, bh, rs = B.bl, B.bh, B.rs
    local function devs_in(list) return part.devs and part.devs(B, list) or list end
    local function bandlist(db)
        local l = {}
        for b = bl, bh do l[#l + 1] = KEYS[b] .. f1(db[b]) end
        return table.concat(l, " ")
    end
    local function tok(d) return track_keys(d, bl == 1) end -- task 4f.10: sub! only when the bands include the low end
    local draft, omitted = {}, 0
    local named = {} -- task 4e: GUIDs of the tracks the region lines and masking hints name (they keep full plugin settings in the YAML)
    draft[1] = string.format("SONG I%s M%s S%s LRA%s pk%s clip%s | mid %s | side %s", f1(song.integrated), f1(song.max_m), f1(song.max_s),
        f1(song.lra), f1(m_peak), m_clips and tostring(m_clips) or "n/a", bandlist(song.mid_db), bandlist(song.side_db))
    if song_chain then draft[#draft + 1] = song_chain end
    draft[#draft + 1] = "TRACKS (whole song)"
    for _, d in ipairs(D.over) do
        if plays(d) and (not part.keep or part.keep(B, d)) then
            local dn = devs_in(d.notable)
            local nb = #dn > 0 and (" | " .. devs(dn, true)) or ""
            local clip, lv, au = d.s.clips > 0 and (" clip" .. string.format("%.0f", d.s.clips)) or "", "", nil
            if part.track_extra then clip, lv, au = part.track_extra(B, d, clip) end
            draft[#draft + 1] = string.format("%s%s%s %s%s%s%s", nm(d.t.name), d.share and (" s" .. i0(d.share)) or "",
                rs[d] and (" rs" .. i0(rs[d])) or "", tok(d), clip, nb, lv)
            if au then draft[#draft + 1] = " auto " .. au end
        else
            omitted = omitted + 1
        end
    end
    draft[#draft + 1] = "REGIONS"
    local function mnotable(mr) -- task 5d: a region's master stereo values and clips, only when they say something
        local x, s = MA_A.mstereo(mr, 0), ""
        if x.corr < MA_A.M_CORR_MAX then s = s .. " c" .. c2(x.corr) end
        if math.abs(x.pan100) >= MA_A.M_BAL_MIN then s = s .. " " .. pan_label(x.pan100) end
        if x.sub_risk and bl == 1 then s = s .. " sub!" end
        if mr.clips > 0 then s = s .. string.format(" clip%.0f", mr.clips) end
        return s
    end
    for i, reg in ipairs(D.regions) do
        if reg.na or not reg.mr then
            draft[#draft + 1] = string.format("R%d %s %s-%s | n/a", i, nm(reg.name), string.format("%.2f", reg.start_s), string.format("%.2f", reg.end_s))
        elseif part.quiet_region and part.quiet_region(B, i) then -- task 4f.7b: the header only
            local mr = reg.mr
            draft[#draft + 1] = string.format("R%d %s %s-%s | I%s M%s S%s LRA%s W%s%s | no focus track plays", i, nm(reg.name), string.format("%.2f", reg.start_s),
                string.format("%.2f", reg.end_s), f1(mr.integrated), f1(mr.max_m), f1(mr.max_s), f1(mr.lra), i0(reg.width), mnotable(mr))
        else
            local mr, rd = reg.mr, devs_in(reg.dev)
            draft[#draft + 1] = string.format("R%d %s %s-%s | I%s M%s S%s LRA%s W%s%s%s", i, nm(reg.name), string.format("%.2f", reg.start_s), string.format("%.2f", reg.end_s),
                f1(mr.integrated), f1(mr.max_m), f1(mr.max_s), f1(mr.lra), i0(reg.width), mnotable(mr),
                #rd > 0 and (" | " .. devs(rd, true)) or "")
            local rc = chain(reg.mi, mr)
            if rc then draft[#draft + 1] = " " .. rc end
            local lines, apx, mreg, role, tail = reg.sel, reg.approx, reg, nil, nil
            if part.region then lines, apx, mreg, role, tail = part.region(B, i, reg) end
            role = role or {}
            local shown = {}
            for _, d in ipairs(lines) do
                if part.all_lines or d.share >= MA_A.MIN_SHARE then
                    shown[d] = true
                    named[d.t.guid] = true
                    local dn = devs_in(d.notable)
                    draft[#draft + 1] = string.format(" %s%s%s%s %s%s%s", nm(d.t.name), role[d] and (" (" .. table.concat(role[d], ", ") .. ")") or "",
                        d.share and (" s" .. i0(d.share)) or "", rs[d] and (" rs" .. i0(rs[d])) or "", tok(d),
                        #dn > 0 and (" | " .. devs(dn, true)) or "", B.rlev and B.rlev(d) or "")
                end
            end
            for _, s in ipairs(tail or {}) do draft[#draft + 1] = s end
            if part.also then
                -- Every other counted track that plays in the region (no folder buses), in track order, with its play time there
                local also = {}
                for _, d in ipairs(reg.all) do
                    if not shown[d] and d.r.role ~= "bus" and plays(d) then also[#also + 1] = nm(d.t.name) .. " a" .. i0(d.act) end
                end
                if #also > 0 then draft[#draft + 1] = string.format(" R%d also %s", i, table.concat(also, ", ")) end
            end
            for _, m in ipairs(mreg.mask) do
                for _, e in ipairs(m.list) do named[e.d.t.guid] = true end
            end
            local mk, ap = mask_ranges(mreg, nm), {}
            for _, d in ipairs(apx) do ap[#ap + 1] = nm(d.t.name) end
            if #mk > 0 or #ap > 0 then
                draft[#draft + 1] = " " .. (#mk > 0 and ("mask " .. table.concat(mk, "; ")) or "") ..
                    ((#mk > 0 and #ap > 0) and " | " or "") .. (#ap > 0 and ("approx: " .. table.concat(ap, ",")) or "")
            end
        end
    end
    if part.finish then named = part.finish(B, named) or named end
    return table.concat(draft, "\n"), named, omitted, B.listed
end

--- Stage 4 console output (append to the collection test): ROUTING, SONG, regions, OVERVIEW, DATA BLOCK, TOKENS, SELF-CHECK. Returns the data block, the GUIDs it names and (task 4f.6) the stored
-- measurements D for build_data_block; nil when the region data failed.
local function print_region_summary(out, tracks, max_sec, run_id, offsets)
    local D, err = collect_region_data(tracks, max_sec, run_id, offsets)
    if not D then out[#out + 1] = "\nREGION SUMMARY skipped: " .. tostring(err) return end
    local song, route, m_peak, m_clips = D.song, D.route, D.m_peak, D.m_clips
    local f1, n1, _, _, _, chain, pan_label, devs, mask_ranges = MA_A.fmt()

    -- ROUTING
    out[#out + 1] = "\nROUTING (fader, pan and automation are measured on the phantom tracks, not modelled; parent = folder parent idx)"
    out[#out + 1] = " idx name                     role  slot parent fader  approx"
    for _, t in ipairs(tracks) do
        local r = route[t.idx]
        local why = {}
        if r.no_direct then why[#why + 1] = "NOT COUNTED (" .. r.no_direct .. ", no direct path to the master)" end
        for _, x in ipairs(r.reasons) do why[#why + 1] = x end
        out[#out + 1] = string.format("%4d %-24s %-4s %4d %6s %6.1f  %s", t.idx, t.name:sub(1, 24), r.role, t.slot,
            r.parent and tostring(r.parent) or "-", r.fader_db, table.concat(why, ", "))
    end

    -- SONG
    out[#out + 1] = string.format("\nSONG (%.1f s) | integrated %s LUFS | max M %s | max S %s | LRA %s LU | peak %s dBFS post-fader | clips %s",
        D.proj_len, n1(song.integrated), n1(song.max_m), n1(song.max_s), n1(song.lra), f1(m_peak), m_clips and tostring(m_clips) or "n/a")
    local hdr, mline, sline = "      ", "  mid ", " side "
    for b = 1, 15 do
        local fc = math.sqrt(B15_EDGES[b] * B15_EDGES[b + 1])
        hdr = hdr .. string.format("%6s", fc >= 1000 and (string.format("%.3g", fc / 1000) .. "k") or string.format("%.3g", fc))
        mline = mline .. string.format("%6.1f", song.mid_db[b])
        sline = sline .. string.format("%6.1f", song.side_db[b])
    end
    out[#out + 1] = hdr .. "\n" .. mline .. "\n" .. sline
    local song_chain = chain(song.mi, song)
    out[#out + 1] = "  " .. (song_chain or "chain: n/a (no master input data)")
    if D.pre_fx then
        out[#out + 1] = string.format("  master Volume (Pre-FX) envelope active: %s dB (it lowers the mix before the master FX; included in the check)",
            math.abs(D.pre_fx.hi - D.pre_fx.lo) < 0.05 and string.format("%+.1f", D.pre_fx.lo) or string.format("%+.1f..%+.1f", D.pre_fx.lo, D.pre_fx.hi))
    end
    out[#out + 1] = string.format("  phantom check: top-level tracks against the master input %s dB (expect about -3 to 0)",
        D.song_chk and string.format("%+.1f", D.song_chk) or "n/a")

    -- One track line (region or overview)
    local function track_line(d, indent, with_clips)
        local tail = devs(d.notable)
        return string.format("%s%-22s %-4s %s  L%7.1f  pk%7.1f  cr%6s  a%6s  W%4.0f  c%6.2f  %-6s %s%s%s", indent,
            d.t.name:sub(1, 22), d.r.role == "bus" and "bus" or "", d.share and string.format("s%5.1f%%", d.share) or "s  bus ", d.L, d.pk, n1(d.crest), n1(d.act), d.width, d.corr, pan_label(d.pan100),
            d.sub_risk and "sub! " or "", with_clips and string.format("clips %.0f prepk%.1f ", d.s.clips, d.pk - d.r.fader_db) or "",
            tail ~= "" and ("| " .. tail) or "")
    end

    -- Regions
    for i, reg in ipairs(D.regions) do
        if reg.na or not reg.mr then
            out[#out + 1] = string.format("\nR%d %s %.1f-%.1f (%.1f s) | n/a (under 1 s or no master data)", i, reg.name, reg.start_s, reg.end_s, reg.wsum)
        else
            local mr = reg.mr
            out[#out + 1] = string.format("\nR%d %s %.1f-%.1f (%.1f s used) | I %s M %s S %s LRA %s W %.0f | vs song: %s", i, reg.name,
                reg.start_s, reg.end_s, reg.wsum, n1(mr.integrated), n1(mr.max_m), n1(mr.max_s), n1(mr.lra), reg.width,
                #reg.dev > 0 and devs(reg.dev) or "-")
            out[#out + 1] = "  " .. (chain(reg.mi, mr) or "chain: n/a")
            for _, d in ipairs(reg.sel) do out[#out + 1] = track_line(d, "  ", false) end
            local mk = mask_ranges(reg, function(s) return s end)
            out[#out + 1] = "  masking: " .. (#mk > 0 and table.concat(mk, " | ") or "none")
            local ap = {}
            for _, d in ipairs(reg.approx) do ap[#ap + 1] = d.t.name .. " (" .. table.concat(d.reasons, ", ") .. ")" end
            out[#out + 1] = string.format("  approx: %s | phantom check: top-level tracks against the master input %s dB (expect about -3 to 0)",
                #ap > 0 and table.concat(ap, "; ") or "none", reg.chk and string.format("%+.1f", reg.chk) or "n/a")
        end
    end

    -- OVERVIEW (whole song, every track with data)
    out[#out + 1] = "\nOVERVIEW (whole song, every counted track with data; s = share of the K energy of all counted tracks except folder buses, adds up to 100; bus = folder bus (no share, its children carry it); L, pk, pan = after the track's own fader and pan; prepk = pk minus the track's static fader)"
    for _, d in ipairs(D.over) do out[#out + 1] = track_line(d, string.format("%3d ", d.t.idx), true) end

    -- DATA BLOCK (task 4f.6: from the stored measurements, the same builder the send uses)
    local text, named, omitted = build_data_block(D)
    out[#out + 1] = "\nDATA BLOCK (the measured part of the prompt):\n" .. text

    -- TOKENS and SELF-CHECK
    local est = MA_A.tokens(#text)
    out[#out + 1] = string.format("\nTOKENS (estimate from the measured characters per token): data block %d chars = about %d tokens = %.0f%% of the %d ceiling | %d tracks below %d%% active left out of the overview",
        #text, est, 100 * est / MA_A.TOKEN_CEILING, MA_A.TOKEN_CEILING, omitted, MA_A.ACTIVE_MIN_PCT)
    local chk = D.check
    out[#out + 1] = string.format("SELF-CHECK: region weights %.2f s + gap seconds %.2f s = %.2f s vs song %.2f s (%s) | regions n/a: %d | tracks counted with data: %d of %d (%d not counted: no direct path to the master)",
        chk.weights, chk.gaps, chk.weights + chk.gaps, D.proj_len, math.abs(chk.weights + chk.gaps - D.proj_len) < 0.05 and "OK" or "MISMATCH",
        chk.n_na, D.tracks_with_data, #tracks, D.dropped)
    return text, named, D
end

--- Task 4e: the whole prompt of the JSFX path. Fixed text first (role, legend, instructions: the same for every project, so a
-- cached prompt start can be reused), then the data block and the compact project YAML.
local function build_jsfx_prompt(block, yaml, focus) -- focus: an AI.FOCUS entry (nil = no focus, as in the report)
    local bands = {}
    for b = 1, 15 do bands[b] = string.format("%s %g-%g", MA_A.KEYS[b], B15_EDGES[b], B15_EDGES[b + 1]) end
    -- stage 6: what this focus's data adds or leaves out comes from its mode (MA_A.PARTS)
    local A, part = MA_A, MA_A.PARTS[focus and focus.mode or "song"]
    local legend = part.legend and table.concat(part.legend(focus), "\n") or ""
    return table.concat({
        "=== ROLE ===",
        "You are an experienced mixing and mastering engineer. Analyse this REAPER mix from the measured data and the project YAML below and give concrete advice.",
        "",
        "=== LEGEND OF THE MEASURED DATA ===",
        "One render of the whole song. Each track is measured after its own fader, pan and automation, before its folder and the master FX. \"_\" in a name = a space (match names to the YAML).",
        "Bands (Hz): " .. table.concat(bands, ", ") .. ".",
        "SONG = the master after its FX: I integrated, M max momentary, S max short-term loudness (LUFS), LRA loudness range (LU), pk sample peak (dBFS), clip clipped samples; mid / side = song-average master band levels (dB) of the mid and side signal.",
        "chain in: master loudness before the master FX, after it is the line above; gain = loudness the chain adds (dB).",
        "TRACKS (whole song), one line per playing track:",
        "- s = % share of the mix (loudness-weighted energy; all counted tracks add up to 100). Folder buses have no s (their children carry it). Tracks with no path to the master are left out; what they send is measured on the receiving tracks.",
        "- L = average loudness including pauses (LUFS, ungated; a track that plays more often gets a higher L at the same level, compare pk), pk = sample peak (dBFS), cr = crest factor (dB, median per second of peak minus RMS; low = dense or heavily compressed), a = % of the time the track plays.",
        "- W = width (0 mono, about 50 wide and uncorrelated, above 50 more side than mid), c = left/right correlation (1 mono, 0 unrelated, below 0 out of phase), pC / pL n / pR n = measured balance (0-100 towards that side), sub! = out of phase below 120 Hz (cancels in mono), clip n = clipped samples.",
        "- after \"|\": bands that stand out from their neighbouring bands in the same track (dB, + bump, - dip). A bump right next to the track's high-pass or low-pass filter is usually only the filter's slope (the filter cuts the band next to it, so this band only looks raised); do not cut it for that reason alone.",
        "REGIONS: R n name start-end (seconds), the region's master numbers; after \"|\": master bands against the song average with the loudness difference removed (dB). Then the region's top tracks by share (same keys). \"R n also\" = every other track playing in region n, a = % of the region it plays; compare regions to see arrangement changes.",
        "On a region's master numbers, c, pL/pR, sub! and clip appear only when notable (c below 0, balance " .. MA_A.M_BAL_MIN .. " or more); none shown = normal.",
        "mask: Hz ranges where 2 or more of these tracks each hold at least " .. string.format("%g", A.MASK_SHARE * 100) .. "% of the energy, measured over the seconds they play together; number = each track's % of all energy in the whole range (a narrow overlap looks small in a wide range). approx: these tracks' shares are approximate (their folder also receives sends).",
        "Differences under 1 dB are measurement noise. Width, correlation and balance are measured after pan. The LRA of a single region is naturally small (one section changes little in loudness); judge compression by crest, not by region LRA." .. legend,
        "",
        "=== PROJECT YAML ===",
        "Routing and settings: folders (parent, flags: folder), sends (connections; sidechain = feeds a side-chain input; send volume 0 dB when omitted), faders (vol_db), pan, envelopes (auto), plugins in chain order. The master and the tracks named under REGIONS, with their folders, list full plugin settings. All other tracks list plugin names only (fx: \"A > B\"); when you need their settings, ask for \"DETAIL <track name>\" and I will send that track's full plugin settings, sends, automation and measurements per region. Settings with a common name start are grouped: band_1: {freq: 181} means the setting band_1_freq. A renamed plugin shows its original in brackets, e.g. Ducking Comp (ReaComp). Muted tracks that make no sound are left out. \"Name: same as plugin 3 on Lead Vox\" = exactly the settings of the 3rd plugin in Lead Vox's chain. Plugin values are shown as each plugin reports them; some plugins label units or on/off states wrongly (e.g. a reverb time of 2.5 ms that means 2.5 s), so judge by plausibility. An automated setting shows its range over the song (e.g. sat: 0.5-1.2); its envelope is under auto.",
        "",
        "=== INSTRUCTIONS ===",
        "Answer in three parts.",
        "Part 1 \"Overview\": 3 to 5 short lines on what already works and 3 to 5 on the main problems, each with the measured number that shows it.",
        "Part 2: one section per area below, in this order. In each: what the data shows (numbers, regions, tracks), the cause (which tracks and plugins), then the fixes. A fix = what to do (track, plugin and parameter exactly as in the YAML, current value -> new value; or a new plugin with its settings; or a fader, pan or automation move), why (with the number) and what to listen for. Name the settings that already work. In the band areas go band by band where a band shows something. An area with nothing to fix gets one line saying why.",
        "1. Dynamics and loudness: loudness, LRA and crest across the regions and tracks, the build from verse to chorus. Do not judge compression by a region's LRA; use crest.",
        "2. Low end (rumble, deepsub, sub, bass: 20-125 Hz): kick against bass, sub! and the mask ranges.",
        "3. Low mids (body, mud, boxy: 125-500 Hz).",
        "4. Mids (honk, nasal, bite: 500-2000 Hz).",
        "5. Highs (presence, harsh, sibilance, sizzle, air: 2000-20000 Hz): tell \"harsh\" apart from \"sibilance\"; a de-esser or a dynamic EQ where needed.",
        "In areas 2-5 use the track band bumps, the mask ranges and the master band deviations; give frequency, gain and Q. Before cutting a bump, check the track's high-pass and low-pass filters. Band levels fall towards the highs in nearly every mix: do not call a mix dark from that alone.",
        "6. Stereo and mono: W, c, the balance and sub!; phase or width problems and how to fix them.",
        "7. Arrangement: two regions of the same kind that differ (e.g. Verse 1 and Verse 2): compare their track lines and also lines and say what changed.",
        "8. Master: the chain gain, the final loudness and the peak.",
        "Part 3 \"To-do by priority\": a table of the fixes from part 2, biggest effect first, at most 12 rows: priority, track, plugin and parameter, change (current -> new), why (the number).",
        "If the prompt ends with a FOCUS line, keep only the areas that matter for that focus. Do not write a FOCUS line yourself.",
        "A setting inside a module or band that is switched off (Out, Off, bypassed, active: Off) has no effect. Never give a threshold (compressor, limiter, gate, de-esser or dynamic EQ band, also in a new plugin): the levels going into a plugin are not measured, so give the gain reduction or cut to aim for on the loud parts (dB) instead. Only advise on tracks that play in that region. Quote exact track, plugin and parameter names from the YAML. When the data does not support a claim, say so. Be honest and short, and say briefly why, so I learn.",
        "Write for a musician in plain studio words. The data keys above are for you only: never write s, L, pk, cr, a, W, c, pL/pR or sub! in your answer; say e.g. \"the kick plays 39% of the time\" or \"the bass makes up 21% of the mix\". Name bands with their Hz range, e.g. \"mud (200-315 Hz)\". Never compute values the data does not give (e.g. a share for a folder bus); say what is missing instead.",
        "",
        "=== MEASURED DATA ===",
        block,
        "",
        "=== REAPER PROJECT (YAML) ===",
        yaml,
    }, "\n")
end

--- Task 4f.1: one JSFX collection run (analyzers + phantoms, render, read, cleanup that always runs, undo).
-- Returns nil when the analyzer file cannot be written (a message box says why); otherwise ok, the report lines,
-- the data block, the GUIDs of the tracks it names and the stored measurements (build_data_block).
local function collect_jsfx_data()
    local run_t0 = reaper.time_precise()
    remove_all_analyzers() -- leftovers from an earlier crash

    local path, write_err = write_analyzer_file()
    if not path then reaper.ShowMessageBox(write_err, "Analyzer file", 0) return nil end

    local times = { close = 0, open = 0 } -- task 7b: seconds per part, printed in the report after the setup line

	reaper.Undo_BeginBlock2(0)
    local render_opts = math.floor(reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, false))
    -- Task 4f: tick "Automatically close when finished" in the render window for this run (bit 1 of renderclosewhendone; needs SWS), restored in the cleanup
    local close_opt = reaper.SNM_GetIntConfigVar and reaper.SNM_GetIntConfigVar("renderclosewhendone", -1) or -1
    if close_opt >= 0 and close_opt & 1 == 0 then reaper.SNM_SetIntConfigVar("renderclosewhendone", close_opt | 1) end
    -- Task 4f.9: a normal render into a temporary folder instead of the dry run (the dry run window cannot close by itself and looks
    -- frozen until the cleanup ends). The project's render path and file name are restored and the folder emptied in the cleanup;
    -- the folder is emptied before the render too (no overwrite question).
    local _, r_file = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
    local _, r_pat = reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", false)
    -- Task 5g.6: this run renders the master mix over the entire project whatever the Render window says; both restored in the cleanup.
    -- Cleared bits of RENDER_SETTINGS: 1, 2 stems; 8 render matrix; 32, 64, 128 selected items / tracks; 2048 second pass (would measure twice)
    local r_src = math.floor(reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false))
    local r_bounds = math.floor(reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false))
    local tmp_dir = (os.getenv("TEMP") or os.getenv("TMP") or reaper.GetResourcePath()) .. "/MixAssistant_render"
    local function clear_tmp()
        reaper.EnumerateFiles(tmp_dir, -1) -- rescan, REAPER caches the listing
        local names, k = {}, 0
        while true do
            local f = reaper.EnumerateFiles(tmp_dir, k)
            if not f then break end
            names[#names + 1] = f
            k = k + 1
        end
        for _, f in ipairs(names) do os.remove(tmp_dir .. "/" .. f) end
    end
    local out = {}
    local data_block, named, coll -- task 4e: the data block and the GUIDs of the tracks it names; 4f.6: the stored measurements
    local rate_warn -- task 5g.3: set when the device rate differs from the project rate; goes to the status line with coll

    local ok, err = pcall(function()
        reaper.gmem_attach(GMEM_NAME)

        local top = 8388607
        reaper.gmem_write(top, 12345.5)
        out[#out + 1] = "gmem top index write/read: " .. (reaper.gmem_read(top) == 12345.5 and "OK" or "FAILED")
        reaper.gmem_write(top, 0)

        reaper.gmem_write(0, 0)
        reaper.gmem_write(6, 0)
        local run_id = math.floor(reaper.time_precise() * 1000) % 2000000000 + 1

        reaper.gmem_write(185, B15_C)
        -- task 5b: the layout follows the project: seconds = length + 2 s, then as many track slots as fit (header, tracks, master, master input)
        local nsec = math.ceil(reaper.GetProjectLength(0)) + 2
        local max_tr = math.min(4096, math.floor((MA_A.GMEM_SIZE - MA_HDR - nsec * 10 * (MA_MSTRIDE + MA_A.MISTRIDE)) / (nsec * MA_STRIDE)))
        -- Task 7b: the audio device stays closed until the cleanup. With it open, routing changes can wait up to about 1 s each on the running
        -- audio engine (setup 0.6-22 s, removing the phantoms 0-15 s; closed 0.2 s and 0.1 s, with the same numbers). A closed device stays closed.
        if reaper.Audio_IsRunning() ~= 0 then
            local c0 = reaper.time_precise()
            reaper.Audio_Quit()
            times.reopen, times.close = true, reaper.time_precise() - c0
        end
        local tracks, skipped, inject_err = inject_analyzers(max_tr)
        if not tracks then error(inject_err, 0) end
        MA_MAXSEC, MA_MAXTR = nsec, math.max(#tracks, 1)
        MA_MBASE = MA_HDR + MA_MAXTR * MA_MAXSEC * MA_STRIDE
        MA_A.MIBASE = MA_MBASE + MA_MAXSEC * 10 * MA_MSTRIDE
        out[#out + 1] = string.format("Analyzer memory: %d track slots x %d s, %d of %d gmem slots used (%.1f%%; at this length up to %d tracks fit)",
            MA_MAXTR, MA_MAXSEC, MA_A.MIBASE + MA_MAXSEC * 10 * MA_A.MISTRIDE, MA_A.GMEM_SIZE,
            100 * (MA_A.MIBASE + MA_MAXSEC * 10 * MA_A.MISTRIDE) / MA_A.GMEM_SIZE, max_tr)
        out[#out + 1] = string.format("Analyzers: %d phantom tracks + master (%d tracks skipped)", #tracks, skipped)
        local tm = tracks.timing
        out[#out + 1] = string.format("Setup time %.1f s (inserting the phantom tracks %.1f s, copying the first phantom's chunk / naming + main send off %.1f s, hiding %.1f s, creating the sends %.1f s, analyzers %.1f s, master %.1f s, final check %.1f s; phantoms the check had to repair: %d of %d)",
            tm.total, tm.ins, tm.set, tm.hide, tm.send, tm.fx, tm.master, tm.check, tm.fixed, #tracks)
        times.line = #out
        out[#out + 1] = "JSFX handshake after injection: " .. (reaper.gmem_read(0) == MA_MAGIC and "yes" or "no (advisory only)")

        -- The rendered file is not added to the project
        reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", render_opts & ~1, true)
        -- Stage 3 thresholds (the JSFX reads them when the run id changes, so they go in before slot 9)
        local master_vol = reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "D_VOL")
        if master_vol < 1e-9 then master_vol = 1e9 end
        reaper.gmem_write(MA_H_ACTIVE, 2 * 10 ^ (MA_ACTIVE_DB / 10))
        reaper.gmem_write(MA_H_CLIP_TRK, MA_CLIP_THRESHOLD)
        reaper.gmem_write(MA_H_CLIP_MST, MA_CLIP_THRESHOLD / master_vol)
        reaper.gmem_write(MA_H_MCLIPS, 0)
        reaper.gmem_write(MA_H_MSTAMP, 0)
        reaper.gmem_write(MA_H_MPEAK, 0)
        reaper.gmem_write(11, MA_MAXSEC) -- task 5b: the run's layout, read by the JSFX on the run-id change
        reaper.gmem_write(12, MA_MAXTR)
		reaper.gmem_write(9, run_id)
        reaper.gmem_write(7, 0)
        reaper.gmem_write(6, 1)
        local render_t0 = reaper.time_precise()
        out[#out + 1] = string.format("Script work before the render command: %.1f s (the wait before the render window beyond this is REAPER's own)", render_t0 - run_t0)
        -- 42230 = render with the most recent settings and close the render window; task 4f.9: into the temporary folder (was the
        -- dry run 43349)
        reaper.RecursiveCreateDirectory(tmp_dir, 0)
        clear_tmp()
        reaper.GetSetProjectInfo_String(0, "RENDER_FILE", tmp_dir, true)
        reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "MixAssistant_temp", true)
        reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", r_src & ~(1 | 2 | 8 | 32 | 64 | 128 | 2048), true)
        reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 1, true)
        out[#out + 1] = string.format("Render for this run: master mix, entire project (the project's own settings, restored afterwards: source flags %d, bounds %d)", r_src, r_bounds)
        reaper.Main_OnCommand(42230, 0)
        local render_s = reaper.time_precise() - render_t0
        reaper.gmem_write(6, 0)
        times.render_end = reaper.time_precise()

        local proj_len = reaper.GetProjectLength(0)
        local max_sec = math.min(MA_MAXSEC, math.ceil(proj_len) + 2)
        local project_sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
        out[#out + 1] = string.format("Project length %.1f s | project SR %d | JSFX reported SR %d | master seen: %s",
            proj_len, project_sr, reaper.gmem_read(2), reaper.gmem_read(10) == run_id and "yes" or "NO")
        out[#out + 1] = string.format("Render time %.1f s (%.1fx realtime, %s)", render_s, proj_len / math.max(render_s, 0.001),
            "render to a temporary file")

        local jsfx_sr = reaper.gmem_read(2)
        -- task 5g.3: the rate the project works at: its own setting if switched on, else the render rate if one is set (0 = neither, no warning)
        local want_sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE_USE", 0, false) > 0 and project_sr or reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, false)
        if want_sr > 0 and jsfx_sr >= 8000 and math.abs(jsfx_sr - want_sr) > 0.5 then
            rate_warn = string.format("Warning: the audio device runs at %d Hz, this project at %d Hz, so the render is slower and the numbers differ slightly. Set the device to %d Hz, then Collect again.", jsfx_sr, want_sr, want_sr)
            out[#out + 1] = "WARNING: " .. rate_warn:gsub("^Warning: ", "")
        end
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
            local s = summarize_track(t.slot, max_sec, run_id)
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
        -- Task 4f: a cancelled render leaves the master data short; stop here so nothing half-collected is used (1 s tolerance)
        if m.valid_blocks < math.floor(proj_len * 10) - 10 then
            error(string.format("The render stopped early (cancelled?) or did not cover the whole project: master data for %.1f of %.1f s. Nothing was collected.",
                m.valid_blocks / 10, proj_len), 0)
        end
        -- Stage 3: max 100 ms K level (blocks with at least half of 100 ms), master peak/clips from the header slots
        local max_100 = -144.0
        for k = 0, math.min(MA_MAXSEC * 10, max_sec * 10) - 1 do
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
            -- task 5a: the new per-block master values (report only; the prompt uses them from task 5d)
            local x = MA_A.mstereo(m, master_fader)
            local pk_ok = stamped and math.abs(math.max(m.pkl, m.pkr) - reaper.gmem_read(MA_H_MPEAK)) < 1e-12
            local cl_ok = stamped and m.clips == reaper.gmem_read(MA_H_MCLIPS)
            out[#out + 1] = string.format("  stereo: corr %.3f | sub corr %.3f%s | balance %+d (+ = right) | width %.1f (broadband) | rms %.1f dBFS | crest %.1f dB | clips %d",
                x.corr, x.sub_corr, x.sub_risk and " sub!" or "", x.pan100, x.width, x.rms, x.crest, m.clips)
            out[#out + 1] = string.format("self-check (5a): highest block peak = song peak: %s | block clips add up to the song clips: %s",
                pk_ok and "yes" or "NO", cl_ok and "yes" or "NO")
        end

        do
            data_block, named, coll = print_region_summary(out, tracks, max_sec, run_id, offsets)
            if coll then -- task 5a: the new master values per region
                out[#out + 1] = "\nMASTER PER REGION (task 5a, report only): corr | sub corr | balance | width (broadband / bands) | peak | rms | crest | clips"
                for i, reg in ipairs(coll.regions) do
                    if reg.mr then
                        local x = MA_A.mstereo(reg.mr, master_fader)
                        out[#out + 1] = string.format("  R%d %-16s corr %.3f | sub %.3f%s | bal %+d | W %.1f / %.1f | pk %.1f | rms %.1f | crest %.1f | clips %d",
                            i, reg.name:sub(1, 16), x.corr, x.sub_corr, x.sub_risk and " sub!" or "", x.pan100, x.width, reg.width or 0, x.pk, x.rms, x.crest, reg.mr.clips)
                    end
                end
            end
        end
        times.read = reaper.time_precise() - times.render_end

    end)

    -- Cleanup ALWAYS runs (success, error or cancelled render)
    local clean_t0 = reaper.time_precise()
    reaper.gmem_write(6, 0)
    remove_all_analyzers()
    remove_analyzer_file()
    reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", render_opts, true)
    if close_opt >= 0 and close_opt & 1 == 0 then reaper.SNM_SetIntConfigVar("renderclosewhendone", close_opt) end
    reaper.GetSetProjectInfo_String(0, "RENDER_FILE", r_file, true)
    reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", r_pat, true)
    reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", r_src, true)
    reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", r_bounds, true)
    clear_tmp()
    reaper.UpdateArrange()

	local block_name = "Mix Assistant temp collection"
    reaper.Undo_EndBlock2(0, block_name, -1)
    if reaper.Undo_CanUndo2(0) == block_name then reaper.Undo_DoUndo2(0) end
    local clean_s = reaper.time_precise() - clean_t0
    -- Task 7b: the device goes back on last, also after an error or a cancelled render
    local dev_warn
    if times.reopen then
        local c0 = reaper.time_precise()
        reaper.Audio_Init()
        times.open = reaper.time_precise() - c0
        if reaper.Audio_IsRunning() == 0 then dev_warn = "Warning: REAPER's audio device did not reopen after Collect. If there is no sound, restart REAPER." end
    end
    -- Inserted after the setup line: the status line reads the report's last line after a failed run
    table.insert(out, (times.line or 0) + 1, string.format("Times: closing the audio device %.2f s, reopening %.2f s | reading the data %s s | cleanup and undo %.1f s | whole run %.1f s%s",
        times.close, times.open, times.read and string.format("%.1f", times.read) or "n/a", clean_s, reaper.time_precise() - run_t0, dev_warn and (" | " .. dev_warn) or ""))

    if not ok then out[#out + 1] = "ERROR: " .. tostring(err) .. (dev_warn and (" " .. dev_warn) or "") end
    if coll then coll.warn = dev_warn and ((rate_warn and (rate_warn .. " ") or "") .. dev_warn) or rate_warn end
    return ok, out, data_block, named, coll
end

--- Task 4f: the whole prompt from a collection (compact YAML read after the cleanup, so no analyzer or phantom is in it).
-- Returns prompt, compact YAML; or nil, error text.
local function build_collected_prompt(data_block, named, listed, focus, snap) -- listed (task 4f.7b): see build_data_block; focus: the AI.FOCUS entry; snap (4g.3): the settings read at Collect
    local cok, cyaml = pcall(extract_full_project_yaml, { full = named, listed = listed, snap = snap })
    if not (cok and type(cyaml) == "string") then return nil, tostring(cyaml) end
    return build_jsfx_prompt(data_block, cyaml, focus), cyaml
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

            -- column widths, measured once per block: nat = longest cell, min = longest single word
            if not block.nat then
                block.nat, block.min = {}, {}
                for c = 1, block.cols do block.nat[c], block.min[c] = 0, 0 end
                for _, cells in ipairs(block.rows) do
                    for c, cell in ipairs(cells) do
                        if c <= block.cols then
                            block.nat[c] = math.max(block.nat[c], (reaper.ImGui_CalcTextSize(ctx, cell)))
                            for word in cell:gmatch("%S+") do
                                block.min[c] = math.max(block.min[c], (reaper.ImGui_CalcTextSize(ctx, word)))
                            end
                        end
                    end
                end
            end
            -- too wide for the window: shrink every column in proportion (never below its longest word) and wrap the cells
            local padx = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding())
            local avail = reaper.ImGui_GetContentRegionAvail(ctx) - block.cols * 2 * padx - (block.cols + 1) - 2
            local widths, total = nil, 0
            for c = 1, block.cols do total = total + block.nat[c] end
            if total > avail then
                widths = {}
                local fixed, free, rest = {}, avail, total
                for _ = 1, block.cols do -- a column that would fall below its longest word keeps that width; the rest share what is left
                    local changed = false
                    for c = 1, block.cols do
                        if not fixed[c] and rest > 0 and block.nat[c] * free / rest < block.min[c] then
                            fixed[c], changed = true, true
                            free, rest = free - block.min[c], rest - block.nat[c]
                        end
                    end
                    if not changed then break end
                end
                for c = 1, block.cols do
                    widths[c] = (fixed[c] or rest <= 0) and block.min[c] or math.max(1, block.nat[c] * free / rest)
                end
            end

            local table_id = "MDTable_" .. tostring(msg_id or 0) .. "_" .. table_counter
            if reaper.ImGui_BeginTable(ctx, table_id, block.cols, flags) then
                for c = 0, block.cols - 1 do
                    if widths then
                        reaper.ImGui_TableSetupColumn(ctx, "Col" .. c, reaper.ImGui_TableColumnFlags_WidthFixed(), widths[c + 1])
                    else
                        reaper.ImGui_TableSetupColumn(ctx, "Col" .. c)
                    end
                end
                for _, cells in ipairs(block.rows) do
                    reaper.ImGui_TableNextRow(ctx)
                    for col_idx, cell in ipairs(cells) do
                        reaper.ImGui_TableSetColumnIndex(ctx, col_idx - 1)
                        if widths then reaper.ImGui_TextWrapped(ctx, cell) else reaper.ImGui_Text(ctx, cell) end
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
local scroll_to_bottom = false

-- Task 4f: the JSFX path's session state and actions (one table, to save top-level locals)
local AI = { collected = nil, sent = false, status = "" }

--- Peak price now? Returns true and the local time ("hh:mm") when the peak period ends, or false.
function AI.peak()
    local u, now = os.date("!*t"), os.time()
    if u.wday >= 2 and u.wday <= 6 then -- Monday to Friday (os.date: 1 = Sunday)
        for _, p in ipairs(MA_A.PEAK_UTC) do
            if u.hour >= p[1] and u.hour < p[2] then
                return true, os.date("%H:%M", now + (p[2] - u.hour) * 3600 - u.min * 60 - u.sec)
            end
        end
    end
    return false
end

--- USD for cached + uncached prompt tokens + output tokens at the price that applies now
function AI.cost(model, n_hit, n_miss, n_out)
    local p = MA_A.PRICE[model] or MA_A.PRICE["deepseek-v4-pro"]
    return (AI.peak() and 1e-6 or 0.5e-6) * (n_hit * p[1] + n_miss * p[2] + n_out * p[3])
end

--- Grey line after a reply, from the API's own count; est = our characters / 4 estimate (first message only).
-- completion_tokens is assumed to include the thinking (if "thinking" ever shows more than "output", it does not).
function AI.usage_line(u, model, est)
    local pt, hit = u.prompt_tokens or 0, u.prompt_cache_hit_tokens or 0
    local miss, out_n = u.prompt_cache_miss_tokens or math.max(pt - hit, 0), u.completion_tokens or 0
    local th = type(u.completion_tokens_details) == "table" and u.completion_tokens_details.reasoning_tokens or 0
    -- e.g. "Tokens: In 18617 (est 18400 +1%, cache 0) | Out 950 (think 420) | $0.014 (off-peak)"
    local line = string.format("Tokens: In %d (%scache %d) | Out %d%s | $%.3f (%s)", pt,
        (est and est > 0) and string.format("est %d %+.0f%%, ", est, 100 * (pt - est) / est) or "", hit,
        out_n, th > 0 and string.format(" (think %d)", th) or "", AI.cost(model, hit, miss, out_n), AI.peak() and "peak" or "off-peak")
    return line
end

--- One API turn on the current chat. An error text becomes an alert line (never sent back to the AI). Returns true on success.
function AI.ask(model_choice, think, est)
    local model = get_model_name(model_choice)
    local reply, u = ask_deep_seek(chat_history, model, think)
    table.insert(chat_history, { role = u and "assistant" or "alert", content = reply })
    if u then table.insert(chat_history, { role = "info", content = AI.usage_line(u, model, est) }) end
    fetch_deep_seek_balance()
    scroll_to_bottom = true
    return u ~= nil, u
end

--- Task 4g.3: every setting the prompts use, read once at Collect (the project exactly as it sounds in the measurement,
-- without the analyzers): the YAML parts (extract_full_project_yaml take mode) + per track the automation, the return candidates
-- (counted sends on channels 1/2), the name group, is_return (non-folder answer), muted along the folder chain and the selection.
function AI.snapshot()
    local S = extract_full_project_yaml({ take = true })
    S.len = math.min(reaper.GetProjectLength(0), MA_MAXSEC)
    S.auto, S.ret_to, S.group, S.ret, S.muted, S.sel = {}, {}, {}, {}, {}, {}
    for _, tr in ipairs(S.list) do
        S.auto[tr] = AI.auto_lines(tr, S.len)
        -- & 1023 strips the mono flag 1024, so a mono send to channel 1 or 2 counts too
        local to = {}
        for k = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
            if reaper.GetTrackSendInfo_Value(tr, 0, k, "B_MUTE") ~= 1 and reaper.GetTrackSendInfo_Value(tr, 0, k, "I_SRCCHAN") >= 0
                and math.floor(reaper.GetTrackSendInfo_Value(tr, 0, k, "I_DSTCHAN")) & 1023 < 2 then
                to[#to + 1] = reaper.GetTrackSendInfo_Value(tr, 0, k, "P_DESTTRACK")
            end
        end
        S.ret_to[tr] = to
        S.group[tr], S.ret[tr], S.muted[tr], S.sel[tr] = AI.track_group(tr), AI.is_return(tr, false), is_track_hierarchy_muted(tr), reaper.IsTrackSelected(tr)
    end
    return S
end

--- "Collect": one collection run, then the Whole Song prompt. Task 5g.1: with MA_A.DEV the report goes next to the script and the prompt is
-- saved next to the project at once (Copy / Send then find it saved); without it only a failed run leaves a report, next to the project.
function AI.collect()
    local ok, out, block, named, D = collect_jsfx_data()
    if not out then AI.status = "Collection failed: the analyzer file could not be written." return end
    local function report_path()
        local dir
        if MA_A.DEV then
            dir = (debug.getinfo(1, "S").source or ""):match("^@(.*[\\/])")
        else
            local _, pf = reaper.EnumProjects(-1, "")
            dir = pf and pf:match("^(.*[\\/])")
            if not dir then
                local p = reaper.GetProjectPath("")
                dir = p and p ~= "" and (p .. PATH_SEPARATOR) or nil
            end
        end
        return (dir or (reaper.GetResourcePath() .. PATH_SEPARATOR)) .. "MixAssistant_report.txt"
    end
    local function fail(what, msg)
        local path = report_path()
        AI.status = what .. msg .. (write_lines(path, out) and (" (details in " .. path .. ")") or (" (the report could not be saved to " .. path .. ")"))
    end
    if not (ok and block) then
        fail("Collection failed: ", (tostring(out[#out]):gsub("^ERROR: ", "")))
        return
    end
    -- task 4g.3: read after the collection's cleanup (analyzers removed, the run undone; REAPER blocks editing while it renders)
    local sok, S = pcall(AI.snapshot)
    if not sok then
        out[#out + 1] = "ERROR: reading the project settings failed: " .. tostring(S)
        fail("Reading the project settings failed: ", tostring(S))
        return
    end
    -- task 5e2: muted (also by a folder), no measured sound and no Mute envelope on the way up: see extract_full_project_yaml
    local sound = {}
    for _, d in ipairs(D.over) do
        if d.s.peak > 0 then sound[d.t.guid] = true end
    end
    S.silent = {}
    for _, tr in ipairs(S.list) do
        if S.muted[tr] and not sound[S.guid[tr]] then
            local p, envelope = tr, false
            while p do
                local a = S.td[p].full.auto
                if a and a:find("Mute", 1, true) then envelope = true end
                p = S.parent[p]
            end
            if not envelope then S.silent[tr] = true end
        end
    end
    local prompt, cyaml = build_collected_prompt(block, named, nil, AI.FOCUS[1], S)
    if not prompt then
        out[#out + 1] = "ERROR: the prompt build failed: " .. tostring(cyaml)
        fail("Prompt build failed: ", tostring(cyaml))
        return
    end
    -- Task 4f.6: the measurements are kept (D), prompts are built per focus from them (cache, keyed by the focus name);
    -- Whole Song is built now so a build error shows at once. The file is saved at send / copy time (AI.full_prompt), with MA_A.DEV also below.
    -- Task 4g.3: snap = the settings at the measurement; every prompt and the focus lists come from it until the next Collect.
    AI.collected = { D = D, snap = S, cache = { [AI.FOCUS[1][1]] = { prompt = prompt, tokens = MA_A.tokens(#prompt) } },
        when = os.date("%H:%M"), changes = reaper.GetProjectStateChangeCount(0), soloed = reaper.AnyTrackSolo(0),
        undo = reaper.Undo_CanUndo2(0) or "", sel = AI.sel_sig() } -- task 4f.7b: see AI.changed
    AI.sent = false
    if MA_A.DEV then
        out[#out + 1] = string.format("PROMPT (task 4e, estimate): compact YAML %d chars = about %d tokens | whole prompt %d chars = about %d tokens",
            #cyaml, MA_A.tokens(#cyaml), #prompt, MA_A.tokens(#prompt))
        local pok, text, e = pcall(AI.full_prompt, 1)
        if pok and text and e.path then
            out[#out + 1] = "PROMPT FILE: " .. e.path
        else
            out[#out + 1] = "Whole Song prompt not saved: " .. tostring(not pok and text or (not text and e) or "the file could not be written")
        end
        local path = report_path()
        if not write_lines(path, out) then reaper.ShowConsoleMsg("Could not save the report file: " .. path .. "\n") end
    end
end

--- Task 4f.6: the collected prompt for focus i (without the soloed note and the FOCUS line), built from the stored measurements on
-- first use and cached (no gmem reading; tracks are found by GUID, missing ones are skipped by the YAML). Returns the cache entry
-- { prompt, tokens, path, saved }, or nil and a message.
--- Task 4f.9: the automation of one track for the focus data (4g "Send Track Detail" can reuse it): "NAME unit: v@t ..." per active
-- envelope (track, send and plugin-parameter envelopes, not hardware outputs), joined by "; "; nil without envelopes. Sampled every
-- 100 ms over len seconds with Envelope_Evaluate (automation items and every curve shape included), then reduced (Ramer-Douglas-Peucker):
-- the kept points follow the curve within the tolerance, so curved (non-linear) shapes simply keep more points. Above MA_A.AUTO_MAX points
-- the tolerance doubles until it fits ("~" after the name). Flat envelopes are left out; Mute lists the switching points. Volume in dB (own
-- formula), everything else as REAPER formats it (Envelope_FormatValue), spaces removed; a unit shared by every value moves to the name.
function AI.auto_lines(tr, len)
    local A, n, items = MA_A, math.max(1, math.floor(len * 10)), {}
    local function tm(i) return (string.format("%.1f", i / 10):gsub("%.0$", "")) end
    for ei = 0, reaper.CountTrackEnvelopes(tr) - 1 do
        local env = reaper.GetTrackEnvelope(tr, ei)
        local ok, act = reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", "", false)
        if not (ok and act == "0") and reaper.GetEnvelopeInfo_Value(env, "I_HWOUT_IDX") == 0 then
            local _, name = reaper.GetEnvelopeName(env, "")
            local _, fx, prm = reaper.Envelope_GetParentTrack(env)
            local vol, mute, tol = false, false, A.AUTO_TOL_PCT / 50 -- pan / width run from -1 to 1
            if fx and fx >= 0 then
                local _, fxn = reaper.TrackFX_GetFXName(tr, fx, "")
                local _, pn = reaper.TrackFX_GetParamName(tr, fx, prm, "")
                local _, lo, hi = reaper.TrackFX_GetParam(tr, fx, prm)
                name = fxn:gsub("^%w+i?:%s*", ""):gsub("%s*%(.-%)$", "") .. "/" .. pn
                tol = A.AUTO_TOL_FX_PCT / 100 * ((hi > lo) and (hi - lo) or 1)
            else
                vol, mute = name:find("Volume") ~= nil, name:find("Mute") ~= nil
                if vol then tol = A.AUTO_TOL_DB end
            end
            local si = reaper.GetEnvelopeInfo_Value(env, "I_SEND_IDX") -- 1-based send index, 0 = not a send envelope
            if si > 0 then
                local dst = reaper.GetTrackSendInfo_Value(tr, 0, si - 1, "P_DESTTRACK")
                if dst then
                    local _, dn = reaper.GetTrackName(dst)
                    name = name .. ">" .. dn
                end
            end
            name = name:gsub("[:;]", ""):gsub("%s+", "_")
            -- sample: y = the value the tolerance applies to (dB for volume), raw = the envelope value
            local mode, y, raw, ymin, ymax = reaper.GetEnvelopeScalingMode(env), {}, {}, math.huge, -math.huge
            for i = 0, n do
                local _, v = reaper.Envelope_Evaluate(env, i / 10, 0, 0)
                raw[i] = v
                if vol then
                    local g = reaper.ScaleFromEnvelopeMode(mode, v)
                    v = g > 0 and math.max(A.AUTO_FLOOR_DB, 20 * math.log(g, 10)) or A.AUTO_FLOOR_DB
                end
                y[i] = v
                ymin, ymax = math.min(ymin, v), math.max(ymax, v)
            end
            local keep, mark = { 0 }, ""
            if ymax - ymin <= tol then
                -- flat: one value
            elseif mute then
                for i = 1, n do
                    if (raw[i] >= 0.5) ~= (raw[i - 1] >= 0.5) then keep[#keep + 1] = i end
                end
            else
                repeat
                    local k, st = { [0] = true, [n] = true }, { 0, n }
                    while #st > 0 do
                        local b = table.remove(st)
                        local a = table.remove(st)
                        local dm, im = tol, nil
                        for i = a + 1, b - 1 do
                            local d = math.abs(y[i] - y[a] - (y[b] - y[a]) * (i - a) / (b - a))
                            if d > dm then dm, im = d, i end
                        end
                        if im then
                            k[im] = true
                            st[#st + 1] = a; st[#st + 1] = im; st[#st + 1] = im; st[#st + 1] = b
                        end
                    end
                    keep = {}
                    for i = 0, n do if k[i] then keep[#keep + 1] = i end end
                    if #keep > A.AUTO_MAX then tol, mark = tol * 2, "~" end
                until #keep <= A.AUTO_MAX
            end
            local v = {}
            for j, i in ipairs(keep) do
                if vol then
                    v[j] = y[i] <= A.AUTO_FLOOR_DB and "-inf" or (string.format("%.1f", y[i]):gsub("^%-0%.0$", "0.0")) -- no "-0.0"
                else
                    local s = (reaper.Envelope_FormatValue(env, raw[i], "") or ""):gsub("%s+", "")
                    v[j] = s ~= "" and s or string.format("%.3g", raw[i])
                end
            end
            local unit = vol and "dB" or v[1]:match("%d(%D+)$")
            if not vol then
                for _, s in ipairs(v) do if unit and s:match("%d(%D+)$") ~= unit then unit = nil end end
                if unit then for j, s in ipairs(v) do v[j] = s:sub(1, #s - #unit) end end
            end
            if #v > 1 then -- flat envelopes are left out (the user, 2026-11-05)
                local p = {}
                for j, i in ipairs(keep) do p[j] = v[j] .. "@" .. tm(i) end
                items[#items + 1] = string.format("%s%s%s: %s", name, mark, unit and (" " .. unit) or "", table.concat(p, " "))
            end
        end
    end
    return #items > 0 and table.concat(items, "; ") or nil
end

function AI.prompt(i)
    local c, f = AI.collected, AI.FOCUS[i] or AI.FOCUS[1]
    -- task 4f.7b: a group focus shapes the data block and the YAML; Selected Tracks is cached per selection
    local lists = f.mode == "group" and AI.focus_lists() or nil
    local l = lists and lists[i]
    if l and #l == 0 then
        local _, msg = AI.focus_line(i)
        return nil, msg
    end
    -- task 4f.11: the plugin notes file goes into every prompt; when its text changes, the cached prompts are rebuilt (checked every 5 s)
    local now = reaper.time_precise()
    if not c.notes_t or now - c.notes_t > 5 then
        c.notes_t = now
        local dir = (debug.getinfo(1, "S").source or ""):match("^@(.*[\\/])")
        local fh = dir and io.open(dir .. "MixAssistant_plugin_notes.txt", "r")
        local txt = fh and fh:read("*a") or ""
        if fh then fh:close() end
        if c.notes and c.notes ~= txt then c.cache = {} end
        c.notes = txt
    end
    local key = f[1] -- task 4g.3: Selected Tracks = the selection at Collect, so one entry per focus
    local e = c.cache[key]
    if not e then
        local fs
        if l then
            -- F = the focus tracks; R = their returns: counted tracks an F track sends audio to on channel 1 or 2
            -- (task 4g.3: the sends as they were at Collect, see AI.snapshot)
            fs = { F = {}, R = {} }
            local by_tr = {}
            for _, t in ipairs(c.D.tracks) do
                if not c.D.route[t.idx].no_direct then by_tr[t.track] = t end
            end
            for _, x in ipairs(l) do fs.F[x.t.idx] = true end
            for _, x in ipairs(l) do
                for _, d in ipairs(c.snap.ret_to[x.tr] or {}) do
                    local dst = by_tr[d]
                    if dst and not fs.F[dst.idx] then fs.R[dst.idx] = true end
                end
            end
            -- task 4f.9: the automation of the focus tracks and returns (4g.3: read at Collect)
            fs.auto = {}
            for _, t in ipairs(c.D.tracks) do
                if fs.F[t.idx] or fs.R[t.idx] then fs.auto[t.idx] = c.snap.auto[t.track] end
            end
        end
        local block, named, _, listed = build_data_block(c.D, f, fs)
        local prompt, err = build_collected_prompt(block, named, listed, f, c.snap)
        if not prompt then return nil, "Prompt build failed: " .. tostring(err) end
        e = { prompt = prompt, tokens = MA_A.tokens(#prompt) }
        c.cache[key] = e
    end
    return e
end

-- Task 4f.5: "Focus on" choices (decision A: all data is always sent; the focus is one line at the END of the prompt, so the rest stays
-- byte-identical and DeepSeek's cache still hits). Task 4f.7a: g = name groups (AI.track_group), inst = every non-return track outside
-- Vocals and Drums & Bass, ret = returns (AI.is_return), sel = tracks selected in REAPER (a selected folder brings its children),
-- text = topic focus (no track list). Stage 6: mode = the kind of focus, the one place for it: song, group, band, stereo, master (MA_A.PARTS).
AI.FOCUS = { { "Whole Song", mode = "song" }, { "Vocals", mode = "group", g = { vocals = true } }, { "Drums & Bass", mode = "group", g = { drums = true, bass = true } },
    { "Guitars", mode = "group", g = { guitars = true } }, { "Keys & Synths", mode = "group", g = { keys = true } }, { "Strings & Brass", mode = "group", g = { sb = true } },
    { "Instruments", mode = "group", inst = true }, { "Effects & Returns", mode = "group", ret = true }, { "Selected Tracks", mode = "group", sel = true },
    { "Low End", mode = "band", lo = 1, hi = 6, text = "the low end (20-315 Hz: rumble, deepsub, sub, bass, body, mud): kick and bass balance, sub energy, mud, mono compatibility" },
    { "Mids", mode = "band", lo = 7, hi = 12, text = "the mids (315 Hz-5 kHz: boxy, honk, nasal, bite, presence, harsh): boxiness, honk, clarity, presence, harshness" },
    { "High End", mode = "band", lo = 13, hi = 15, text = "the high end (5-20 kHz: sibilance, sizzle, air): brightness, sibilance, air" },
    { "Stereo Image", mode = "stereo", text = "the stereo image: width, panning, side energy, mono compatibility" },
    { "Master & Loudness", mode = "master", text = "the master chain and the whole mix's loudness, dynamics and tonal balance (mastering)" } }

-- Task 4f.7a: focus name matching, a new classifier. A key matches the start of a
-- word, a WHOLE key only a whole word. Groups are checked in this order; the first that matches wins.
AI.GROUP_KEYS = {
    { "drums", "drum kick snare tom toms clap rim ride crash splash china cymbal hat hats hihat hh oh ohs overhead perc shaker tamb conga bongo cajon kit bd sd 808 909" },
    { "bass", "bass sub subbass" },
    { "vocals", "vox vocal voc vx vo voice bgv bgvs bv bvs choir adlib harm harmony harmonies rap singer acap acapella" },
    { "guitars", "gtr guitar acoustic uke ukulele banjo mandolin dobro steel ag eg" },
    { "keys", "piano pno keys keyboard organ rhodes wurli clav ep synth pad pluck arp mellotron" },
    { "sb", "strings string violin viola cello orch brass horn trumpet trombone sax flute woodwind harp" } }
AI.WHOLE, AI.NOT_BASS_NEXT = {}, { clarinet = true, flute = true, trombone = true, harmonica = true }
for w in ("oh hh bd sd bv bvs vx vo ep ag eg sub kit tom rim rap"):gmatch("%S+") do AI.WHOLE[w] = true end
AI.NOT_VOCAL = { "gtr", "guitar", "synth", "pad", "piano", "keys", "organ", "string", "brass" }

--- Task 4f.7a: the group of a track name ("drums", "bass", "vocals", "guitars", "keys", "sb") or nil. Words: camelCase and
-- letter/digit boundaries split, lowercase, split on everything that is not a letter or digit.
function AI.name_group(name)
    local words = {}
    for x in name:gsub("(%l)(%u)", "%1 %2"):gsub("(%a)(%d)", "%1 %2"):gsub("(%d)(%a)", "%1 %2"):lower():gmatch("%w+") do words[#words + 1] = x end
    local function starts(w, key) return w == key or (not AI.WHOLE[key] and w:sub(1, #key) == key) end
    local not_vocal = false
    for _, w in ipairs(words) do
        for _, x in ipairs(AI.NOT_VOCAL) do if w:sub(1, #x) == x then not_vocal = true end end
    end
    for _, g in ipairs(AI.GROUP_KEYS) do
        if not (g[1] == "vocals" and not_vocal) then
            for key in g[2]:gmatch("%S+") do
                for i, w in ipairs(words) do
                    -- bass: not bassoon, not "bass clarinet" and the like
                    if starts(w, key) and not (g[1] == "bass" and (w:sub(1, 7) == "bassoon" or AI.NOT_BASS_NEXT[words[i + 1] or ""])) then return g[1] end
                end
            end
        end
    end
end

--- Task 4f.7a: the group of a track: its own name first, else its nearest folder whose name matches (so "Chr Synth audio stem" in
-- the Brass Buss folder stays in Keys & Synths)
function AI.track_group(tr)
    local cur = tr
    while cur do
        local _, name = reaper.GetSetMediaTrackInfo_String(cur, "P_NAME", "", false)
        local g = AI.name_group(name)
        if g then return g end
        cur = reaper.GetParentTrack(cur)
    end
end

--- Task 4f.7a: a return (reverb, delay, parallel bus), found by routing: not a folder, no media items, no instrument plugin, receives audio on channels 1/2;
-- or a parallel name (nyc, rear, parallel)
function AI.is_return(tr, folder)
    if folder then return false end
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name_has_any(name:lower(), PARALLEL_WORDS) then return true end
    -- media items, or an instrument plugin (a sampler played by MIDI sends, e.g. the drum tracks fed by a sequencer): not a return
    if reaper.CountTrackMediaItems(tr) > 0 or reaper.TrackFX_GetInstrument(tr) >= 0 then return false end
    for k = 0, reaper.GetTrackNumSends(tr, -1) - 1 do
        if reaper.GetTrackSendInfo_Value(tr, -1, k, "B_MUTE") ~= 1 and reaper.GetTrackSendInfo_Value(tr, -1, k, "I_SRCCHAN") >= 0
            and math.floor(reaper.GetTrackSendInfo_Value(tr, -1, k, "I_DSTCHAN")) & 1023 < 2 then
            -- only when the sending track is also heard on its own (main send on along its folder chain, fader not off): a track fed by
            -- a silent source (e.g. the drum tracks fed by a send-only sequencer) carries the real sound, it is not a return
            local cur, lin = reaper.GetTrackSendInfo_Value(tr, -1, k, "P_SRCTRACK"), 1
            while cur and lin > 1e-5 do
                lin = lin * reaper.GetMediaTrackInfo_Value(cur, "D_VOL")
                if reaper.GetMediaTrackInfo_Value(cur, "B_MAINSEND") ~= 1 then lin = 0 end
                cur = reaper.GetParentTrack(cur)
            end
            if lin > 1e-5 then return true end
        end
    end
    return false
end

--- Task 4f.7a: the focus track lists from the collected tracks (counted ones only, not muted, still in the project), indexed like
-- AI.FOCUS: lists[i] = { { t = track entry, tr = track }, ... } in track order; nil for Whole Song and the topic focuses.
-- Task 4g.3: built once per collection from the snapshot (names, routing, mutes and the track selection as they were at Collect).
function AI.focus_lists()
    local c = AI.collected
    if not c then return {} end
    if c.lists then return c.lists end
    local S, info = c.snap, {}
    for _, t in ipairs(c.D.tracks) do
        local tr, r = t.track, c.D.route[t.idx]
        if r and not r.no_direct and S.td[tr] and not S.muted[tr] then
            info[#info + 1] = { t = t, tr = tr, g = S.group[tr], ret = r.role ~= "bus" and S.ret[tr] }
        end
    end
    local lists = {}
    for i, f in ipairs(AI.FOCUS) do
        if f.mode == "group" then
            local l = {}
            for _, x in ipairs(info) do
                local hit
                if f.sel then
                    local cur = x.tr
                    while cur and not hit do hit, cur = S.sel[cur], S.parent[cur] end
                elseif f.inst then hit = not x.ret and x.g ~= "vocals" and x.g ~= "drums" and x.g ~= "bass"
                elseif f.ret then hit = x.ret
                else hit = f.g[x.g or ""] end
                if hit then l[#l + 1] = x end
            end
            lists[i] = l
        end
    end
    c.lists = lists
    return lists
end

--- The FOCUS line for choice i ("" for Whole Song), or nil and a message when the focus has no track
function AI.focus_line(i)
    local f = AI.FOCUS[i] or AI.FOCUS[1]
    if f.text then return "\n\nFOCUS: " .. f[1] .. ". Give advice only about " .. f.text .. "." end
    local l = AI.focus_lists()[i]
    if not l then return "" end
    if #l == 0 then
        return nil, f.sel and "No track was selected at Collect. Select the tracks to focus on, then Collect Project Info again." or ("No track belongs to " .. f[1] .. ".")
    end
    local names = {}
    for _, x in ipairs(l) do names[#names + 1] = (x.t.name:gsub("%s+", "_")) end -- as the data block writes names
    return string.format("\n\nFOCUS: %s. Give advice only about these tracks: %s. Mention other tracks only where they affect these (for example masking).",
        f[1], table.concat(names, ", "))
end

--- The text that is sent (and copied): the focus's prompt + the soloed note + the FOCUS line; or nil and a message.
-- Task 4f.6: saved next to the project as AI_Mix_Prompt_JSFX_<focus>_NN.txt (the same text only once); returns the text and the cache entry.
function AI.full_prompt(i)
    local c = AI.collected
    local fl, err = AI.focus_line(i)
    if not fl then return nil, err end
    local e, perr = AI.prompt(i)
    if not e then return nil, perr end
    local note = c.soloed and "\n\nNOTE: only the soloed tracks were playing when this was measured, so the master and region numbers describe them, not the whole mix." or ""
    local text = e.prompt .. note .. fl
    if e.saved ~= text then e.path, e.saved = save_prompt_to_txt(text, "JSFX " .. (AI.FOCUS[i] or AI.FOCUS[1])[1]), text end
    return text, e
end

--- Runs a collection run (fn: Collect) without marking the earlier collection as outdated: every run undoes its own
-- changes, so a project that was unchanged before the run is unchanged after it (REAPER's change counter still moves).
function AI.keep(fn)
    local c, before = AI.collected, reaper.GetProjectStateChangeCount(0)
    fn()
    if c and c == AI.collected and c.changes == before then c.changes, c.undo = reaper.GetProjectStateChangeCount(0), reaper.Undo_CanUndo2(0) or "" end
end

--- Task 4f.7b: the track selection as text (selected tracks + the number of selected items); task 4f.9: + the edit cursor and the
-- time selection (a ruler click moves REAPER's change counter too)
function AI.sel_sig()
    local t0, t1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local parts = { reaper.CountSelectedMediaItems(0), reaper.GetCursorPosition(), t0, t1 }
    for k = 0, reaper.CountSelectedTracks(0) - 1 do parts[#parts + 1] = tostring(reaper.GetSelectedTrack(0, k)) end
    return table.concat(parts, ",")
end

--- Task 4f.7b: has the project changed since the collection? Selecting tracks also moves REAPER's change counter, so a counter
-- change with a new selection and no new undo point (or a selection undo point) is taken as "unchanged". Once changed, it stays changed.
function AI.changed()
    local c = AI.collected
    local n = reaper.GetProjectStateChangeCount(0)
    if c.dirty or n == c.changes then return c.dirty end
    local undo, sel = reaper.Undo_CanUndo2(0) or "", AI.sel_sig()
    if sel ~= c.sel and (undo == c.undo or undo:lower():find("selection", 1, true)) then
        c.changes, c.undo, c.sel = n, undo, sel
        return false
    end
    c.dirty = true
    return true
end

--- "Send Project Info to Agent": a new chat that starts with the collected prompt (the chat shows only a short line for it).
-- The API's prompt count re-measures the characters-per-token ratio for the next estimates.
function AI.send(model_choice, think, focus_idx)
    local c = AI.collected
    local text, e = AI.full_prompt(focus_idx)
    if not text then AI.status = e return end
    chat_history = { { role = "user", content = text, display_content = string.format(
        "Project info sent (collected %s, about %d tokens, focus: %s).\nPrompt file: %s",
        c.when, MA_A.tokens(#text), (AI.FOCUS[focus_idx] or AI.FOCUS[1])[1], e.path or "not saved") } }
    scroll_to_bottom = true
    local u
    AI.sent, u = AI.ask(model_choice, think, MA_A.tokens(#text))
    if u and (u.prompt_tokens or 0) > 1000 then
        reaper.SetExtState("MixAssistant", "chars_per_token", string.format("%.3f", #text / u.prompt_tokens), true)
    end
end

--- Task 4g.3 "Send Track Detail": the tracks selected in REAPER now (track order), as they were at Collect: the whole-song line and one
-- line per region where the track plays (the data block's keys + clip, prepk and all 15 levels), its automation, then its YAML (full
-- plugin settings with the notes-file rules, its sends). Returns the text and { names, tokens, skipped }, or nil and a message.
function AI.detail_text()
    local c = AI.collected
    local S, D, KEYS = c.snap, c.D, MA_A.KEYS
    local f1, _, i0, _, nm, _, _, devs, _, track_keys = MA_A.fmt()
    local only, skipped, names, any = {}, {}, {}, false
    -- matched by GUID (task 5b fix): REAPER can reuse a deleted track's pointer for a new track
    local by_guid = {}
    for _, st in ipairs(S.list) do by_guid[S.guid[st]] = st end
    for k = 0, reaper.CountSelectedTracks(0) - 1 do
        local tr = reaper.GetSelectedTrack(0, k)
        local st = by_guid[reaper.GetTrackGUID(tr)]
        if st then only[st], any = true, true else
            local _, n = reaper.GetTrackName(tr)
            skipped[#skipped + 1] = n
        end
    end
    if not any then
        return nil, #skipped > 0 and "The selected tracks were not in the last Collect. Collect Project Info again first." or "Select the tracks to send in REAPER first."
    end
    local by_tr = {}
    for _, t in ipairs(D.tracks) do by_tr[t.track] = t end
    local function line(d)
        local l = {}
        for b = 1, 15 do l[b] = KEYS[b] .. i0(d.bands[b]) end
        return string.format("%s%s clip%.0f prepk%s%s | levels %s", d.share and ("s" .. i0(d.share) .. " ") or "", track_keys(d, true),
            d.s.clips, f1(d.pk - d.r.fader_db), #d.notable > 0 and (" | " .. devs(d.notable, true)) or "", table.concat(l, " "))
    end
    local plays = MA_A.plays
    -- when the track plays inside a region: "a-b,c-d" in song seconds (gaps under 3 s ignored); nil = the whole region
    local function spans(t, reg)
        local pp = D.ps and D.ps[t.idx]
        if not pp then return nil end
        local s0, s1 = MA_A.reg_win(reg.start_s, reg.end_s)
        local function g1(x) return (string.format("%.1f", x):gsub("%.0$", "")) end
        local out, a, last = {}, nil, nil
        local function close() out[#out + 1] = g1(math.max(a, reg.start_s)) .. "-" .. g1(math.min(last + 1, reg.end_s)) end
        for sec = s0, s1 - 1 do
            if MA_A.on_sec(pp, sec) then
                if a and sec - last - 1 >= 3 then close(); a = nil end
                a, last = a or sec, sec
            end
        end
        if not a then return nil end
        if #out == 0 and a <= s0 and last + 1 >= s1 then return nil end
        close()
        return table.concat(out, ",")
    end
    local p = { string.format("TRACK DETAIL (settings, sends and automation as they were when measured at %s; same keys as the data block). Per track: "
        .. "song = the whole-song line, then R n = one line per region where it plays; on = when it plays inside the region (seconds of the song, "
        .. "short pauses ignored; no on = the whole region); clip n = clipped samples, prepk = sample peak before its "
        .. "own fader (dB), levels = all 15 band levels (dB); auto = its envelopes over the whole song, ENVELOPE unit: value@seconds (straight "
        .. "lines between the points; the measured numbers already include the automation). Then the YAML (same format as the project YAML). "
        .. "The rules of the first message still hold: never give a threshold, give the gain reduction or cut to aim for (dB) instead.", c.when) }
    for _, tr in ipairs(S.list) do
        if only[tr] then
            local t = by_tr[tr]
            local name = t and t.name or S.td[tr].full.track
            names[#names + 1] = name
            p[#p + 1] = "TRACK " .. nm(name)
            local od, quiet = nil, {}
            for _, d in ipairs(t and D.over or {}) do if d.t == t then od = d break end end
            p[#p + 1] = plays(od) and (" song " .. line(od)) or " song: not playing or not measured"
            for i, reg in ipairs(t and D.regions or {}) do
                if not reg.na and reg.mr then
                    local rd
                    for _, d in ipairs(reg.all) do if d.t == t then rd = d break end end
                    if plays(rd) then
                        local on = spans(t, reg)
                        p[#p + 1] = string.format(" R%d %s%s %s", i, nm(reg.name), on and (" on " .. on) or "", line(rd))
                    else quiet[#quiet + 1] = "R" .. i end
                end
            end
            if #quiet > 0 then p[#p + 1] = " not playing in " .. table.concat(quiet, ", ") end
            if S.auto[tr] then p[#p + 1] = " auto " .. S.auto[tr] end
        end
    end
    local ok, y = pcall(extract_full_project_yaml, { full = {}, only = only, snap = S })
    if not (ok and type(y) == "string") then return nil, "Track detail failed: " .. tostring(y) end
    p[#p + 1] = "YAML:"
    p[#p + 1] = y
    local text = table.concat(p, "\n")
    return text, { names = table.concat(names, ", "), tokens = MA_A.tokens(#text), skipped = skipped }
end

--- Task 4g.3: adds the detail to the chat (the chat shows a short line; the text is saved next to the project) and asks the AI.
function AI.detail_send(model_choice, think, text, info)
    local path = save_prompt_to_txt(text, "JSFX Detail")
    table.insert(chat_history, { role = "user", content = text, display_content = string.format(
        "Track detail sent: %s (about %d tokens).\nFile: %s", info.names, info.tokens, path or "not saved") })
    scroll_to_bottom = true
    AI.ask(model_choice, think)
end

local MODEL_ITEMS = "DeepSeek V4 Pro (Flagship Reasoning)\0DeepSeek Flash (Fast / Low-Cost)\0\0"

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

    local focus_idx = 1 -- task 4f.5: index into AI.FOCUS
    local model_idx = 1 -- DeepSeek Flash by default (4h: about a third of Pro's price, same quality range)
    local think = true
    local pending = nil -- task 4f: the action to run after the frame delay (collect, send, follow-up)

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

            -- COLLECT (task 4f)
            render_section_header(ctx, "  COLLECT AND MANAGE PROJECT INFORMATION")
            local is_busy = (scan_state and scan_state > 0)
            local bh, bpad = 26, 12 -- every button: the same height, horizontal padding inside
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), bpad, 3)
            if is_busy then reaper.ImGui_BeginDisabled(ctx, true) end
            if reaper.ImGui_Button(ctx, is_busy and "Working..." or "Collect Project Info", -1, bh) and (not reaper.AnyTrackSolo(0) or
                reaper.ShowMessageBox("Some tracks are soloed. Collect Project Info will measure only the soloed tracks, and the master numbers will describe only them.\n\nContinue?",
                    "Soloed tracks", 1) == 1) then
                pending, AI.status = function() AI.keep(AI.collect) end, "⏳ Rendering the project and reading the analyzers... please wait."
            end
            local c = AI.collected

            -- SEND (greyed out until collected)
            reaper.ImGui_Dummy(ctx, 0, 4)
            reaper.ImGui_SetNextItemWidth(ctx, 320)
            _, model_idx = reaper.ImGui_Combo(ctx, "AI Model", model_idx, MODEL_ITEMS)
            reaper.ImGui_SameLine(ctx)
            _, think = reaper.ImGui_Checkbox(ctx, "Think (hidden)", think)
            reaper.ImGui_Dummy(ctx, 0, 4) -- same gap below the combo row as above it
            if not c then reaper.ImGui_BeginDisabled(ctx, true) end -- task 4g.3: usable after a project change too (prompts come from the snapshot)
            -- "Focus on" combo first (it shapes both Send and Copy): standard combo look, same height as the buttons
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), bpad, (bh - reaper.ImGui_GetTextLineHeight(ctx)) / 2)
            -- Task 4f.7a: track counts, empty groups greyed out, hovering lists the focus tracks (the name guess can be wrong)
            local lists = AI.focus_lists()
            local function flabel(i) return AI.FOCUS[i][1] .. (lists[i] and string.format(" (%d)", #lists[i]) or "") end
            local function ftip(i)
                if not reaper.ImGui_IsItemHovered(ctx) then return end
                local l, n = lists[i], {}
                for _, x in ipairs(l or {}) do n[#n + 1] = x.t.name end
                if #n > 0 then reaper.ImGui_SetTooltip(ctx, table.concat(n, "\n"))
                elseif AI.FOCUS[i].text then reaper.ImGui_SetTooltip(ctx, "Advice about " .. AI.FOCUS[i].text) end
            end
            reaper.ImGui_SetNextItemWidth(ctx, reaper.ImGui_CalcTextSize(ctx, "Focus: Effects & Returns (99)") + 2 * bpad + bh)
            if reaper.ImGui_BeginCombo(ctx, "##focus", "Focus: " .. flabel(focus_idx), reaper.ImGui_ComboFlags_HeightLargest()) then
                for i, f in ipairs(AI.FOCUS) do
                    local empty = lists[i] and #lists[i] == 0 -- task 4g.3: Selected Tracks too (the selection at Collect counts)
                    if empty then reaper.ImGui_BeginDisabled(ctx, true) end
                    if reaper.ImGui_Selectable(ctx, flabel(i), i == focus_idx) then focus_idx = i end
                    if empty then reaper.ImGui_EndDisabled(ctx) end
                    ftip(i)
                end
                reaper.ImGui_EndCombo(ctx)
            else
                ftip(focus_idx)
            end
            reaper.ImGui_PopStyleVar(ctx, 1)
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, "Send Project Info to Agent", 0, bh) then
                pending, AI.status = function() AI.send(model_idx + 1, think, focus_idx) end, "⏳ Waiting for DeepSeek (with Think on this can take a few minutes)..."
            end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, "Copy Project Info", 0, bh) then -- the whole prompt with the focus line, for the web chat
                local text, err = AI.full_prompt(focus_idx)
                if text then reaper.ImGui_SetClipboardText(ctx, text) else AI.status = err end
            end
            reaper.ImGui_SameLine(ctx)
            -- task 4g.3: only after Send Project Info in this chat (Clear Chat locks it again); asks before sending
            if not AI.sent then reaper.ImGui_BeginDisabled(ctx, true) end
            if reaper.ImGui_Button(ctx, "Send Track Detail...", 0, bh) then
                local text, info = AI.detail_text()
                if not text then
                    reaper.ShowMessageBox(info, "Send Track Detail", 0)
                elseif reaper.ShowMessageBox(string.format("Send the detail of: %s?\n\nAbout %d tokens (sending this part costs about $%.3f now; the earlier chat is mostly cached).%s",
                    info.names, info.tokens, AI.cost(get_model_name(model_idx + 1), 0, info.tokens, 0),
                    #info.skipped > 0 and ("\n\nLeft out (not in the last Collect): " .. table.concat(info.skipped, ", ")) or ""), "Send Track Detail", 1) == 1 then
                    pending, AI.status = function() AI.detail_send(model_idx + 1, think, text, info) end, "⏳ Waiting for DeepSeek (with Think on this can take a few minutes)..."
                end
            end
            if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
                reaper.ImGui_SetTooltip(ctx, (AI.sent and "" or "Send Project Info first. ") .. "Sends the selected tracks' full data to this chat.")
            end
            if not AI.sent then reaper.ImGui_EndDisabled(ctx) end
            -- Clear Chat right-aligned on the same row
            reaper.ImGui_SameLine(ctx)
            local w2 = reaper.ImGui_CalcTextSize(ctx, "Clear Chat") + 2 * bpad
            local gap = reaper.ImGui_GetContentRegionAvail(ctx) - w2
            if gap > 0 then reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + gap) end
            if reaper.ImGui_Button(ctx, "Clear Chat", w2, bh) then chat_history, AI.sent = {}, false end
            if not c then reaper.ImGui_EndDisabled(ctx) end
            if is_busy then reaper.ImGui_EndDisabled(ctx) end
            reaper.ImGui_PopStyleVar(ctx, 1)

            -- One status line below the buttons: progress or error, else the project-changed warning, else the collection and its cost
            local st, col = nil, 0xFFD54FFF
            if AI.status ~= "" then
                st = AI.status
            elseif c then
                local pk, till = AI.peak()
                local e, perr = AI.prompt(focus_idx) -- task 4f.6: the chosen focus's prompt (built once, then cached)
                st = e and string.format("Collected %s%s, about %d tokens; sending costs about $%.3f now (%s)", c.when, c.soloed and " (soloed tracks only)" or "", e.tokens,
                    AI.cost(get_model_name(model_idx + 1), 0, e.tokens, 0), pk and ("peak until " .. till) or "off-peak") or perr
                -- task 4g.3: the prompts keep describing the project as it was collected
                if AI.changed() then
                    st, col = string.format("Project changed since Collect at %s. Prompts describe the project as it was then; Collect again to include your changes (free). %s",
                        c.when, st), 0xFFB74DFF
                end
                if c.D.warn then st, col = c.D.warn .. " " .. st, 0xFFB74DFF end -- task 5g.3: device rate differs from the project rate
            else
                st = "No project info yet. Click Collect Project Info (free)."
            end
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col)
            reaper.ImGui_TextWrapped(ctx, "Status: " .. st)
            reaper.ImGui_PopStyleColor(ctx, 1)
            reaper.ImGui_Separator(ctx)

			-- 2. Strict Frame Delay & Click-Absorption Cooldown
            -- (the status line is drawn a few frames before the blocking action runs)
            if pending and scan_state == 0 then
                scroll_to_bottom = true
                scan_state = 1
            elseif scan_state == 1 then scan_state = 2
            elseif scan_state == 2 then scan_state = 3
            elseif scan_state == 3 then
                local fn = pending
                pending, AI.status = nil, ""
                if fn then fn() end
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
            local scroll_h = math.max(150, avail_h - 74) -- room for the input box (2 x button height + spacing)

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
                        render_role_badge(ctx, " ALERT ", 0xEF5350FF, 0x111111FF, idx)
                        -- Bright red warning text
                        reaper.ImGui_TextColored(ctx, 0xEF5350FF, msg.content)
                    elseif msg.role == "info" then
                        -- Grey token/cost line (task 4f; never sent to the AI), wrapped so a narrow window does not cut it off
                        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x9E9E9EFF)
                        reaper.ImGui_TextWrapped(ctx, msg.content)
                        reaper.ImGui_PopStyleColor(ctx, 1)
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
            local changed, new_text = reaper.ImGui_InputTextMultiline(ctx, "##chat_in", chat_input_text, -95, 2 * bh + 4) -- as high as the two stacked buttons
            if changed then
                chat_input_text = new_text
            end
            pop_chat_font()

            reaper.ImGui_SameLine(ctx)

            -- Stacked action buttons
            reaper.ImGui_BeginGroup(ctx)
            local can_send = AI.sent and scan_state == 0 -- follow-ups only after "Send Analysis" (task 4f)
            if not can_send then reaper.ImGui_BeginDisabled(ctx, true) end
            if reaper.ImGui_Button(ctx, "Send", 85, bh) then
                if trim_string(chat_input_text) ~= "" then
                    table.insert(chat_history, { role = "user", content = chat_input_text })
                    chat_input_text = ""
                    scroll_to_bottom = true
                    pending, AI.status = function() AI.ask(model_idx + 1, think) end, "⏳ Waiting for DeepSeek (with Think on this can take a few minutes)..."
                end
            end
            if not can_send then reaper.ImGui_EndDisabled(ctx) end

            if reaper.ImGui_Button(ctx, "Copy Chat", 85, bh) then
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
