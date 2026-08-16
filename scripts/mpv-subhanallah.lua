-- mpv-subhanallah subtitle plugin
local mp = require "mp"
local input = require "mp.input"
local options = require "mp.options"
local utils = require "mp.utils"

local BRAND = "mpv-subhanallah"

local FILE_SEARCH = "https://api.subdl.com/api/v2/files/search"
local SUBTITLE_SEARCH = "https://api.subdl.com/api/v2/subtitles/search"
local API_BASE = "https://api.subdl.com"
local DOWNLOAD_BASE = "https://dl.subdl.com"
local OPENSUBTITLES_SEARCH = "https://api.opensubtitles.com/api/v1/subtitles"
local OPENSUBTITLES_LOGIN = "https://api.opensubtitles.com/api/v1/login"
local OPENSUBTITLES_DOWNLOAD = "https://api.opensubtitles.com/api/v1/download"
local OPENSUBTITLES_USER_AGENT = BRAND .. " v1.0"

local opts = {
    provider = "subdl",
    api_key = "",
    opensubtitles_api_key = "",
    opensubtitles_username = "",
    opensubtitles_password = "",
    languages = "en,tr",
    key_search_file = "F5",
    key_search_manual = "F6",
    key_settings = "F7",
}
options.read_options(opts, BRAND)

local config_path = mp.command_native({ "expand-path", "~~/script-opts/" .. BRAND .. ".conf" })
local platform = mp.get_property("platform") or ""
local state = {
    busy = false,
    media = nil,
    data = nil,
    provider = "subdl",
    languages = {},
    language_index = 1,
    opensubtitles_token = nil,
}

local bind_keys

local menu_style = {
    font_size = 24,
    background_alpha = 70,
    padding = 14,
    corner_radius = 10,
}

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function notify(message, seconds)
    mp.osd_message(BRAND .. ": " .. message, seconds or 3)
end

local function parse_languages(value)
    local languages, seen = {}, {}
    for part in tostring(value or ""):gmatch("[^,]+") do
        local code = trim(part):lower()
        if code ~= "" and not seen[code] then
            seen[code] = true
            languages[#languages + 1] = code
        end
    end
    return languages
end

local function save_config()
    local file, err = io.open(config_path, "w")
    if not file then
        notify("Could not save settings: " .. tostring(err), 5)
        return false
    end

    file:write("provider=", opts.provider:gsub("[\r\n]", ""), "\n")
    file:write("api_key=", opts.api_key:gsub("[\r\n]", ""), "\n")
    file:write("opensubtitles_api_key=", opts.opensubtitles_api_key:gsub("[\r\n]", ""), "\n")
    file:write("opensubtitles_username=", opts.opensubtitles_username:gsub("[\r\n]", ""), "\n")
    file:write("opensubtitles_password=", opts.opensubtitles_password:gsub("[\r\n]", ""), "\n")
    file:write("languages=", opts.languages:gsub("[\r\n]", ""), "\n")
    file:write("key_search_file=", opts.key_search_file:gsub("[\r\n]", ""), "\n")
    file:write("key_search_manual=", opts.key_search_manual:gsub("[\r\n]", ""), "\n")
    file:write("key_settings=", opts.key_settings:gsub("[\r\n]", ""), "\n")
    file:close()
    if bind_keys then
        bind_keys()
    end
    notify("Settings saved")
    return true
end

local function config_ready()
    opts.provider = trim(opts.provider):lower()
    if opts.provider ~= "subdl" and opts.provider ~= "opensubtitles" then
        opts.provider = "subdl"
    end
    opts.api_key = trim(opts.api_key)
    opts.opensubtitles_api_key = trim(opts.opensubtitles_api_key)
    state.languages = parse_languages(opts.languages)
    local api_key = opts.provider == "opensubtitles" and opts.opensubtitles_api_key or opts.api_key
    if api_key == "" then
        notify((opts.provider == "opensubtitles" and "OpenSubtitles" or "SubDL")
            .. " API key is missing; open settings to configure it", 4)
        return false
    end
    if #state.languages == 0 then
        notify("Language list is empty; press F7 to configure it", 4)
        return false
    end
    return true
end

local function local_media()
    local path = mp.get_property("path")
    if not path or path == "" then
        notify("No local video is playing")
        return nil
    end

    local info = utils.file_info(path)
    if not info then
        local cwd = mp.get_property("working-directory") or utils.getcwd()
        local absolute = utils.join_path(cwd, path)
        info = utils.file_info(absolute)
        if info then
            path = absolute
        end
    end
    if not info or info.is_dir then
        notify("Only local video files are supported", 4)
        return nil
    end

    local directory, filename = utils.split_path(path)
    if directory == "" then
        directory = mp.get_property("working-directory") or utils.getcwd()
    end
    local base = filename:gsub("%.[^%.]+$", "")
    if base == "" then
        base = filename
    end
    return {
        path = path,
        directory = directory,
        filename = filename,
        base = base,
    }
end

local function api_error(data, fallback)
    if type(data) == "table" and type(data.error) == "table" then
        return data.error.message or data.error.code or fallback
    end
    if type(data) == "table" and type(data.error) == "string" then
        return data.error
    end
    return fallback
end

local function run_json_request(args, callback)
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result)
        if not success or not result or result.status ~= 0 then
            local detail = result and trim(result.stderr) or ""
            callback(nil, detail ~= "" and detail or "Could not run curl")
            return
        end

        local data = utils.parse_json(result.stdout or "")
        if type(data) ~= "table" then
            callback(nil, "The API returned an invalid response")
            return
        end
        if data.status == false or data.error then
            callback(nil, api_error(data, "API request failed"))
            return
        end
        callback(data)
    end)
end

local function auth_args(endpoint)
    return {
        "curl", "-sS", "-L",
        "--connect-timeout", "10",
        "--max-time", "30",
        "--get", endpoint,
        "-H", "Authorization: Bearer " .. opts.api_key,
    }
end

local function add_opensubtitles_headers(args, token)
    args[#args + 1] = "-H"
    args[#args + 1] = "Api-Key: " .. opts.opensubtitles_api_key
    args[#args + 1] = "-H"
    args[#args + 1] = "User-Agent: " .. OPENSUBTITLES_USER_AGENT
    args[#args + 1] = "-H"
    args[#args + 1] = "Accept: application/json"
    if token and token ~= "" then
        args[#args + 1] = "-H"
        args[#args + 1] = "Authorization: Bearer " .. token
    end
end

local function opensubtitles_get_args(endpoint)
    local args = {
        "curl", "-sS", "-fL",
        "--connect-timeout", "10",
        "--max-time", "30",
        "--get", endpoint,
    }
    add_opensubtitles_headers(args)
    return args
end

local function opensubtitles_post_args(endpoint, body, token)
    local args = {
        "curl", "-sS", "-fL",
        "--connect-timeout", "10",
        "--max-time", "30",
        "-H", "Content-Type: application/json",
        "--data-binary", utils.format_json(body),
        endpoint,
    }
    add_opensubtitles_headers(args, token)
    return args
end

local function add_param(args, name, value)
    if value ~= nil and tostring(value) ~= "" then
        args[#args + 1] = "--data-urlencode"
        args[#args + 1] = name .. "=" .. tostring(value)
    end
end

local function matching_result(data)
    local wanted = data.match and data.match.sd_id
    for _, result in ipairs(data.results or {}) do
        if wanted == nil or tostring(result.sd_id) == tostring(wanted) then
            return result
        end
    end
    return (data.results or {})[1]
end

local function strip_query(url)
    return tostring(url or ""):match("^[^?]+") or ""
end

local function strip_api_key(url)
    local path, query = tostring(url or ""):match("^([^?]+)%??(.*)$")
    if not path or query == "" then
        return path or ""
    end
    local kept = {}
    for parameter in query:gmatch("[^&]+") do
        if not parameter:lower():match("^api_key=") then
            kept[#kept + 1] = parameter
        end
    end
    return #kept > 0 and (path .. "?" .. table.concat(kept, "&")) or path
end

local function same_path(a, b)
    a = tostring(a or ""):gsub("\\", "/")
    b = tostring(b or ""):gsub("\\", "/")
    if platform == "windows" then
        a, b = a:lower(), b:lower()
    end
    return a == b
end

local function remove_loaded_subtitle(path)
    for _, track in ipairs(mp.get_property_native("track-list", {}) or {}) do
        if track.type == "sub" and same_path(track["external-filename"], path) then
            mp.commandv("sub-remove", tostring(track.id))
        end
    end
end

local function load_subtitle(path, title, language)
    remove_loaded_subtitle(path)
    mp.commandv("sub-add", path, "select", title or "SubDL", language)
end

local function candidate_title(candidate)
    local attributes = candidate and candidate.attributes or {}
    return (candidate and (candidate.release_name or candidate.release or candidate.name))
        or attributes.release or "Subtitle"
end

local function download_url(url)
    local path = strip_api_key(url)
    if path:match("^https?://") then
        return path
    end
    if path:match("^/subtitle/") then
        return DOWNLOAD_BASE .. path
    end
    if path:sub(1, 1) == "/" then
        return API_BASE .. path
    end
    return nil
end

local subtitle_formats = {
    srt = true,
    ass = true,
    ssa = true,
    vtt = true,
    sub = true,
    smi = true,
}

local function subtitle_format(value)
    local format = trim(value):lower():match("^%.?([%w]+)$")
    if not format then
        format = tostring(value or ""):lower():match("%.([%w]+)$")
    end
    return format and subtitle_formats[format] and format or nil
end

local function install_subtitle(partial, candidate, language, format)
    local language_tag = language:gsub("[^%w%-]", "")
    if language_tag == "" then
        state.busy = false
        os.remove(partial)
        notify("Invalid language code for the output filename", 5)
        return
    end

    local stem = state.media.base .. "." .. language_tag
    local filename = stem .. "." .. format
    local target = utils.join_path(state.media.directory, filename)
    local info = utils.file_info(partial)
    state.busy = false
    if not info or not info.size or info.size == 0 then
        os.remove(partial)
        notify("The downloaded file is empty", 5)
        return
    end
    if utils.file_info(target) then
        remove_loaded_subtitle(target)
        if not os.remove(target) then
            os.remove(partial)
            load_subtitle(target, candidate_title(candidate), language)
            notify("Could not overwrite the existing subtitle", 5)
            return
        end
    end
    local renamed, err = os.rename(partial, target)
    if not renamed then
        os.remove(partial)
        notify("Could not save subtitle: " .. tostring(err), 5)
        return
    end

    load_subtitle(target, candidate_title(candidate), language)
    notify("Downloaded: " .. filename, 4)
end

local function finish_download(source, candidate, language, headers)
    local url = download_url(source.url)
    if not url then
        state.busy = false
        notify("Invalid download URL", 5)
        return
    end

    local stem = state.media.base .. "." .. language:gsub("[^%w%-]", "")
    local partial = utils.join_path(state.media.directory, stem .. ".subdl.part")
    local args = {
        "curl", "-sS", "-fL",
        "--connect-timeout", "10",
        "--max-time", "60",
    }
    if headers == nil then
        headers = { "X-API-Key: " .. opts.api_key }
    end
    for _, header in ipairs(headers) do
        args[#args + 1] = "-H"
        args[#args + 1] = header
    end
    args[#args + 1] = "-o"
    args[#args + 1] = partial
    args[#args + 1] = url

    notify("Downloading subtitle…")
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result)
        if not success or not result or result.status ~= 0 then
            state.busy = false
            os.remove(partial)
            local detail = result and trim(result.stderr) or ""
            notify(detail ~= "" and detail or "Download failed", 5)
            return
        end
        install_subtitle(partial, candidate, language,
            subtitle_format(source.format) or subtitle_format(source.name) or "srt")
    end)
end

local function little_endian(data, offset, bytes)
    local value = 0
    for index = bytes - 1, 0, -1 do
        value = value * 256 + (data:byte(offset + index + 1) or 0)
    end
    return value
end

local function archive_subtitles(path)
    local file = io.open(path, "rb")
    if not file then
        return nil, "Could not read the downloaded archive"
    end
    local size = file:seek("end") or 0
    local tail_size = math.min(size, 65557)
    file:seek("set", size - tail_size)
    local tail = file:read(tail_size) or ""
    local eocd
    for index = math.max(1, #tail - 21), 1, -1 do
        if tail:sub(index, index + 3) == "PK\005\006" then
            eocd = index
            break
        end
    end
    if not eocd then
        file:close()
        return nil, "The downloaded file is not a readable ZIP archive"
    end

    local count = little_endian(tail, eocd + 9, 2)
    local directory_size = little_endian(tail, eocd + 11, 4)
    local directory_offset = little_endian(tail, eocd + 15, 4)
    if count == 65535 or directory_offset == 4294967295 then
        file:close()
        return nil, "ZIP64 subtitle archives are not supported"
    end
    file:seek("set", directory_offset)
    local directory = file:read(directory_size) or ""
    file:close()

    local entries, position = {}, 1
    for _ = 1, count do
        if directory:sub(position, position + 3) ~= "PK\001\002" then
            break
        end
        local name_length = little_endian(directory, position + 27, 2)
        local extra_length = little_endian(directory, position + 29, 2)
        local comment_length = little_endian(directory, position + 31, 2)
        local name = directory:sub(position + 46, position + 45 + name_length):gsub("\\", "/")
        local format = subtitle_format(name)
        if format and name:sub(-1) ~= "/" then
            entries[#entries + 1] = { name = name, format = format }
        end
        position = position + 46 + name_length + extra_length + comment_length
    end
    if #entries == 0 then
        return nil, "The archive contains no supported subtitle file"
    end
    return entries
end

local function normalized_name(value)
    local name = tostring(value or ""):gsub("\\", "/"):match("([^/]+)$") or ""
    name = name:gsub("%.[^%.]+$", "")
    return name:lower():gsub("[^%w]", "")
end

local function choose_archive_subtitle(entries, candidate)
    local wanted = normalized_name(candidate.release_name or candidate.name)
    local best, best_score
    for _, entry in ipairs(entries) do
        local actual = normalized_name(entry.name)
        local score = 0
        if wanted ~= "" and actual == wanted then
            score = 1000000
        elseif wanted ~= "" and (actual:find(wanted, 1, true) or wanted:find(actual, 1, true)) then
            score = math.min(#actual, #wanted) * 100 - math.abs(#actual - #wanted)
        else
            while score < math.min(#actual, #wanted)
                and actual:sub(score + 1, score + 1) == wanted:sub(score + 1, score + 1) do
                score = score + 1
            end
        end
        if not best or score > best_score then
            best, best_score = entry, score
        end
    end
    return best
end

local function mpv_executables()
    local executables, seen = { "mpv" }, { mpv = true }
    local function add(path)
        if path and path ~= "" and not seen[path] then
            seen[path] = true
            executables[#executables + 1] = path
        end
    end
    if platform == "windows" then
        for _, root in ipairs({ os.getenv("ProgramFiles"), os.getenv("ProgramW6432") }) do
            if root and root ~= "" then
                add(utils.join_path(utils.join_path(root, "mpv"), "mpv.exe"))
            end
        end
    elseif platform == "darwin" or platform == "macos" then
        add("/Applications/mpv.app/Contents/MacOS/mpv")
    end
    return executables
end

local function extract_archive(archive, entry, partial, callback)
    local executables = mpv_executables()
    local archive_path = archive:gsub("\\", "/")
    local entry_path = entry.name:gsub("^/+", "")
    local source = "archive://" .. archive_path .. "|/" .. entry_path
    local function attempt(index)
        local executable = executables[index]
        if not executable then
            callback(false, "Could not extract this subtitle archive with mpv")
            return
        end
        os.remove(partial)
        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            capture_stdout = true,
            capture_stderr = true,
            args = {
                executable,
                "--no-config",
                "--no-terminal",
                "--msg-level=all=no",
                "--frames=0",
                "--stream-dump=" .. partial,
                source,
            },
        }, function(success, result)
            local info = utils.file_info(partial)
            if success and result and result.status == 0 and info and info.size and info.size > 0 then
                callback(true)
            else
                attempt(index + 1)
            end
        end)
    end
    attempt(1)
end

local function finish_archive_download(source, candidate, language)
    local url = download_url(source.url)
    if not url then
        state.busy = false
        notify("Invalid archive URL", 5)
        return
    end
    local stem = state.media.base .. "." .. language:gsub("[^%w%-]", "")
    local archive = utils.join_path(state.media.directory, stem .. ".subdl.zip.part")
    local partial = utils.join_path(state.media.directory, stem .. ".subdl.part")
    notify("Downloading subtitle…")
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "curl", "-sS", "-fL",
            "--connect-timeout", "10",
            "--max-time", "60",
            "-H", "X-API-Key: " .. opts.api_key,
            "-o", archive,
            url,
        },
    }, function(success, result)
        if not success or not result or result.status ~= 0 then
            state.busy = false
            os.remove(archive)
            local detail = result and trim(result.stderr) or ""
            notify(detail ~= "" and detail or "Download failed", 5)
            return
        end
        local entries, err = archive_subtitles(archive)
        if not entries then
            state.busy = false
            os.remove(archive)
            notify(err, 5)
            return
        end
        local entry = choose_archive_subtitle(entries, candidate)
        extract_archive(archive, entry, partial, function(extracted, extract_error)
            os.remove(archive)
            if not extracted then
                state.busy = false
                os.remove(partial)
                notify(extract_error, 5)
                return
            end
            install_subtitle(partial, candidate, language, entry.format)
        end)
    end)
end

local function choose_unpacked_file(parent, episode)
    local files = parent and parent.unpack_files or {}
    if episode ~= nil then
        for _, file in ipairs(files) do
            if tonumber(file.episode) == tonumber(episode) then
                return file
            end
        end
    end
    if #files == 1 then
        return files[1]
    end
    if episode == nil then
        return files[1]
    end
    return nil
end

local function resolve_and_download(candidate, language)
    if state.busy then
        notify("Another operation is already in progress")
        return
    end
    state.busy = true

    local result = matching_result(state.data)
    local match = state.data.match or {}
    local media_type = (result and result.type) or match.type
    local sd_id = match.sd_id or (result and result.sd_id)
    if not sd_id or not media_type then
        state.busy = false
        notify("Could not determine the title ID", 5)
        return
    end

    local args = auth_args(SUBTITLE_SEARCH)
    add_param(args, "sd_id", sd_id)
    add_param(args, "type", media_type)
    add_param(args, "languages", language)
    if media_type == "tv" then
        add_param(args, "season", match.season)
        add_param(args, "episode", match.episode)
    end
    add_param(args, "unpack", 1)
    add_param(args, "subs_per_page", 30)

    notify("Preparing subtitle…")
    run_json_request(args, function(data, err)
        if not data then
            state.busy = false
            notify(err, 5)
            return
        end

        local wanted_url = strip_query(candidate.url)
        local parent
        for _, item in ipairs(data.subtitles or {}) do
            if tostring(item.language or ""):lower() == language:lower()
                and wanted_url ~= "" and strip_query(item.url) == wanted_url then
                parent = item
                break
            end
        end
        if not parent then
            for _, item in ipairs(data.subtitles or {}) do
                if tostring(item.language or ""):lower() == language:lower()
                    and item.release_name == candidate.release_name then
                    parent = item
                    break
                end
            end
        end

        local source = choose_unpacked_file(parent, match.episode)
        if source then
            finish_download(source, candidate, language)
            return
        end
        local archive = parent and parent.url and parent or candidate
        if not archive.url then
            state.busy = false
            notify("No downloadable file was found for this result", 5)
            return
        end
        finish_archive_download(archive, candidate, language)
    end)
end

local function parse_episode(query)
    local season, episode = tostring(query or ""):lower():match("s(%d%d?)e(%d%d?)")
    if not season then
        season, episode = tostring(query or ""):lower():match("(%d%d?)x(%d%d?)")
    end
    return tonumber(season), tonumber(episode)
end

local function opensubtitles_token(callback)
    if state.opensubtitles_token then
        callback(state.opensubtitles_token)
        return
    end
    local username = trim(opts.opensubtitles_username)
    local password = trim(opts.opensubtitles_password)
    if username == "" or password == "" then
        callback(nil)
        return
    end
    run_json_request(opensubtitles_post_args(OPENSUBTITLES_LOGIN, {
        username = username,
        password = password,
    }), function(data, err)
        if not data or not data.token then
            callback(nil, err or "OpenSubtitles login failed")
            return
        end
        state.opensubtitles_token = data.token
        callback(data.token)
    end)
end

local function opensubtitles_download(candidate, language)
    if state.busy then
        notify("Another operation is already in progress")
        return
    end
    local attributes = candidate.attributes or {}
    local file = (attributes.files or {})[1]
    if not file or not file.file_id then
        notify("No downloadable file was found for this result", 5)
        return
    end
    state.busy = true
    notify("Preparing subtitle…")
    opensubtitles_token(function(token, login_error)
        if login_error then
            state.busy = false
            notify(login_error, 5)
            return
        end
        run_json_request(opensubtitles_post_args(OPENSUBTITLES_DOWNLOAD, {
            file_id = file.file_id,
        }, token), function(data, err)
            if not data or not data.link then
                state.busy = false
                notify(err or "OpenSubtitles did not return a download link", 5)
                return
            end
            finish_download({
                url = data.link,
                name = data.file_name or file.file_name,
            }, candidate, language, {})
        end)
    end)
end

local function opensubtitles_feature()
    for _, item in ipairs((state.data and state.data.data) or {}) do
        local feature = (item.attributes or {}).feature_details
        if feature then
            return feature
        end
    end
    return {}
end

local function subdl_result_header()
    local result = matching_result(state.data) or {}
    local match = state.data.match or {}
    local media_type = result.type or match.type
    local icon = media_type == "tv" and "📺" or (media_type == "movie" and "🎬" or "")
    local title = result.name or match.title or "Unknown title"
    local text = (icon ~= "" and icon .. " " or "") .. title
    if result.year or match.year then
        text = text .. " (" .. tostring(result.year or match.year) .. ")"
    end
    if media_type == "tv" and match.season ~= nil and match.episode ~= nil then
        text = text .. " • " .. tostring(match.season) .. "x" .. tostring(match.episode)
    end
    local language = state.languages[state.language_index] or ""
    return text .. " • ‹ " .. language:upper() .. " ›"
end

local function opensubtitles_result_header()
    local feature = opensubtitles_feature()
    local feature_type = tostring(feature.feature_type or ""):lower()
    local is_tv = feature_type == "episode"
    local icon = is_tv and "📺" or (feature_type == "movie" and "🎬" or "")
    local title = is_tv and (feature.parent_title or feature.title) or feature.title
    local text = (icon ~= "" and icon .. " " or "") .. (title or "Unknown title")
    if feature.year then
        text = text .. " (" .. tostring(feature.year) .. ")"
    end
    if is_tv and feature.season_number ~= nil and feature.episode_number ~= nil then
        text = text .. " • " .. tostring(feature.season_number) .. "x" .. tostring(feature.episode_number)
    end
    local language = state.languages[state.language_index] or ""
    return text .. " • ‹ " .. language:upper() .. " ›"
end

local function result_header()
    return state.provider == "opensubtitles"
        and opensubtitles_result_header() or subdl_result_header()
end

local function compact_download_count(value)
    local count = math.max(0, math.floor(tonumber(value) or 0))
    if count < 1000 then
        return tostring(count)
    end
    if count < 10000 then
        return (string.format("%.1f", count / 1000):gsub("%.0$", "")) .. "k"
    end
    return tostring(math.floor(count / 1000 + 0.5)) .. "k"
end

local function formatted_date(value)
    local year, month, day = tostring(value or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    return year and (year .. "/" .. month .. "/" .. day) or nil
end

local function opensubtitles_item(candidate)
    local attributes = candidate.attributes or {}
    local parts = {
        compact_download_count(attributes.download_count) .. "↓",
        attributes.release or ((attributes.files or {})[1] or {}).file_name or "Subtitle",
    }
    if attributes.hearing_impaired then parts[#parts + 1] = "HI" end
    if attributes.ai_translated then parts[#parts + 1] = "AI" end
    if attributes.machine_translated then parts[#parts + 1] = "MT" end
    if attributes.from_trusted then parts[#parts + 1] = "T+" end
    local date = formatted_date(attributes.upload_date)
    if date then parts[#parts + 1] = date end
    return table.concat(parts, " • ")
end

local function subdl_item(subtitle)
    local score = math.floor((tonumber(subtitle.match_score) or 0) * 100 + 0.5)
    local parts = {
        tostring(score) .. "%",
        subtitle.release_name or subtitle.name or "Subtitle",
    }
    if subtitle.hi == true then
        parts[#parts + 1] = "HI"
    end
    return table.concat(parts, " • ")
end

local open_results

local function change_language(delta)
    if #state.languages < 2 then
        return
    end
    state.language_index = ((state.language_index - 1 + delta) % #state.languages) + 1
    input.terminate()
    mp.add_timeout(0, open_results)
end

local function remove_language_bindings()
    mp.remove_key_binding("subdl-language-left")
    mp.remove_key_binding("subdl-language-right")
end

open_results = function()
    local language = state.languages[state.language_index]
    if not state.data or not language then
        return
    end

    local items, candidates = {}, {}
    if state.provider == "opensubtitles" then
        for _, candidate in ipairs(state.data.data or {}) do
            local attributes = candidate.attributes or {}
            if tostring(attributes.language or ""):lower() == language:lower() then
                items[#items + 1] = opensubtitles_item(candidate)
                candidates[#candidates + 1] = candidate
            end
        end
    else
        for _, subtitle in ipairs(state.data.subtitles or {}) do
            if tostring(subtitle.language or ""):lower() == language:lower() then
                items[#items + 1] = subdl_item(subtitle)
                candidates[#candidates + 1] = subtitle
            end
        end
    end
    if #items == 0 then
        items[1] = "No subtitles found for this language"
    end

    input.select({
        prompt = BRAND .. " • " .. result_header() .. "  ",
        items = items,
        default_item = 1,
        keep_open = true,
        console_opt_overrides = menu_style,
        opened = function()
            mp.add_forced_key_binding("LEFT", "subdl-language-left", function()
                change_language(-1)
            end)
            mp.add_forced_key_binding("RIGHT", "subdl-language-right", function()
                change_language(1)
            end)
        end,
        closed = remove_language_bindings,
        submit = function(index)
            local candidate = candidates[index]
            if not candidate then
                return
            end
            input.terminate()
            if state.provider == "opensubtitles" then
                opensubtitles_download(candidate, language)
            else
                resolve_and_download(candidate, language)
            end
        end,
    })
end

local function start_subdl_search(query, media)
    if state.busy then
        notify("Another operation is already in progress")
        return
    end
    if not config_ready() then
        return
    end
    query = trim(query)
    if query == "" then
        notify("Search text is empty")
        return
    end

    input.terminate()
    state.busy = true
    state.media = media
    state.data = nil
    state.provider = "subdl"
    state.language_index = 1

    local args = auth_args(FILE_SEARCH)
    add_param(args, "filename", query)
    add_param(args, "languages", table.concat(state.languages, ","))
    add_param(args, "episode_scope", "exact")
    add_param(args, "subs_per_page", 30)

    notify("Searching…")
    run_json_request(args, function(data, err)
        state.busy = false
        if not data then
            notify(err, 5)
            return
        end
        if not data.match or not matching_result(data) then
            notify("No matching title found", 4)
            return
        end
        state.data = data
        open_results()
    end)
end

local function start_opensubtitles_search(query, media)
    if state.busy then
        notify("Another operation is already in progress")
        return
    end
    if not config_ready() then
        return
    end
    query = trim(query)
    if query == "" then
        notify("Search text is empty")
        return
    end

    input.terminate()
    state.busy = true
    state.media = media
    state.data = nil
    state.provider = "opensubtitles"
    state.language_index = 1

    local args = opensubtitles_get_args(OPENSUBTITLES_SEARCH)
    add_param(args, "query", query)
    add_param(args, "languages", table.concat(state.languages, ","))
    local season, episode = parse_episode(query)
    add_param(args, "season_number", season)
    add_param(args, "episode_number", episode)

    notify("Searching…")
    run_json_request(args, function(data, err)
        state.busy = false
        if not data then
            notify(err, 5)
            return
        end
        if type(data.data) ~= "table" or #data.data == 0 then
            notify("No matching title found", 4)
            return
        end
        state.data = data
        open_results()
    end)
end

local function start_search(query, media)
    if trim(opts.provider):lower() == "opensubtitles" then
        start_opensubtitles_search(query, media)
    else
        start_subdl_search(query, media)
    end
end

local function search_current_file()
    local media = local_media()
    if media then
        start_search(media.filename, media)
    end
end

local function search_manually()
    local media = local_media()
    if not media or not config_ready() then
        return
    end
    input.get({
        prompt = BRAND .. " • Search: ",
        default_text = "",
        console_opt_overrides = menu_style,
        submit = function(text)
            start_search(text, media)
        end,
    })
end

local open_config

local function masked_secret(value, show_tail)
    local key = trim(value)
    if key == "" then
        return "not configured"
    end
    return "••••••••" .. (show_tail and key:sub(-4) or "")
end

local function edit_config(field)
    local prompts = {
        api_key = "SubDL API key: ",
        opensubtitles_api_key = "OpenSubtitles API key: ",
        opensubtitles_username = "OpenSubtitles username: ",
        opensubtitles_password = "OpenSubtitles password: ",
        languages = "Languages: ",
        key_search_file = "File search key: ",
        key_search_manual = "Manual search key: ",
        key_settings = "Settings key: ",
    }
    input.get({
        prompt = prompts[field] or "Value: ",
        default_text = tostring(opts[field] or ""),
        cursor_position = #tostring(opts[field] or "") + 1,
        keep_open = true,
        console_opt_overrides = menu_style,
        submit = function(value)
            value = trim(value):gsub("[\r\n]", "")
            if field == "languages" then
                local languages = parse_languages(value)
                if #languages == 0 then
                    notify("Language list cannot be empty", 4)
                    open_config()
                    return
                end
                opts.languages = table.concat(languages, ",")
                state.languages = languages
            else
                opts[field] = value
                if field:match("^opensubtitles_") then
                    state.opensubtitles_token = nil
                end
            end
            save_config()
            open_config()
        end,
    })
end

local function select_provider()
    input.select({
        prompt = BRAND .. " • Provider  ",
        items = { "SubDL", "OpenSubtitles" },
        default_item = opts.provider == "opensubtitles" and 2 or 1,
        keep_open = true,
        console_opt_overrides = menu_style,
        submit = function(index)
            opts.provider = index == 2 and "opensubtitles" or "subdl"
            save_config()
            open_config()
        end,
    })
end

open_config = function()
    local provider_name = opts.provider == "opensubtitles" and "OpenSubtitles" or "SubDL"
    input.select({
        prompt = BRAND .. " • Settings  ",
        items = {
            "Provider                 " .. provider_name,
            "Languages                " .. opts.languages,
            "SubDL API key            " .. masked_secret(opts.api_key, true),
            "OpenSubtitles API key    " .. masked_secret(opts.opensubtitles_api_key, true),
            "OpenSubtitles username   " .. (trim(opts.opensubtitles_username) ~= ""
                and opts.opensubtitles_username or "not configured"),
            "OpenSubtitles password   " .. masked_secret(opts.opensubtitles_password, false),
            "File search key          " .. (trim(opts.key_search_file) ~= "" and opts.key_search_file or "disabled"),
            "Manual search key        " .. (trim(opts.key_search_manual) ~= "" and opts.key_search_manual or "disabled"),
            "Settings key             " .. (trim(opts.key_settings) ~= "" and opts.key_settings or "disabled"),
        },
        default_item = 1,
        keep_open = true,
        console_opt_overrides = menu_style,
        submit = function(index)
            if index == 1 then
                select_provider()
            elseif index == 2 then
                edit_config("languages")
            elseif index == 3 then
                edit_config("api_key")
            elseif index == 4 then
                edit_config("opensubtitles_api_key")
            elseif index == 5 then
                edit_config("opensubtitles_username")
            elseif index == 6 then
                edit_config("opensubtitles_password")
            elseif index == 7 then
                edit_config("key_search_file")
            elseif index == 8 then
                edit_config("key_search_manual")
            elseif index == 9 then
                edit_config("key_settings")
            end
        end,
    })
end

bind_keys = function()
    mp.remove_key_binding("subdl-search-file")
    mp.remove_key_binding("subdl-search-manual")
    mp.remove_key_binding("subdl-settings")
    if trim(opts.key_search_file) ~= "" then
        mp.add_key_binding(trim(opts.key_search_file), "subdl-search-file", search_current_file)
    end
    if trim(opts.key_search_manual) ~= "" then
        mp.add_key_binding(trim(opts.key_search_manual), "subdl-search-manual", search_manually)
    end
    if trim(opts.key_settings) ~= "" then
        mp.add_key_binding(trim(opts.key_settings), "subdl-settings", open_config)
    end
end

bind_keys()
