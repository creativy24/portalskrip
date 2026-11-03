local M = {}
local http = require "luci.http"
local fs = require "nixio.fs"
local ok, json = pcall(require, "luci.jsonc")
if not ok then
    json = require "luci.json"
end
local util = require "luci.util"
local sys = require "luci.sys"

local SCRIPT_DIR = (sys.exec("uci -q get portal.config.script_dir 2>/dev/null"):gsub("\n", ""))
if SCRIPT_DIR == "" then SCRIPT_DIR = "/usr/lib/portal" end

local DETECT_LOCK_PREFIX = "/tmp/portal_detect_"
local DETECT_LOCK_SUFFIX = ".lock"
local DETECT_LOCK_TIMEOUT = 300
local PROFILE_DIR = "/etc/portal/profiles"
local STATE_DIR = "/etc/portal/state"

local function portal_log(level, message)
    local cmd = string.format("logger -t portal '[%s] portal.lua: %s' >/dev/null 2>&1", level, message:gsub("'", "'\\''"))
    os.execute(cmd)
end

local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function json_escape_string(s)
    s = tostring(s)
    return (s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == '\\' then return '\\\\' end
        if c == '\n' then return '\\n' end
        if c == '\r' then return '\\r' end
        if c == '\t' then return '\\t' end
        if c == '\b' then return '\\b' end
        if c == '\f' then return '\\f' end
        return string.format('\\u%04x', c:byte())
    end))
end

local function json_is_array(t)
    if type(t) ~= "table" then return false end

    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" or math.floor(k) ~= k or k < 1 then
            return false
        end
        count = count + 1
    end

    if count == 0 then return false end

    for i = 1, count do
        if t[i] == nil then return false end
    end

    return true
end

local function json_pretty_encode(value, indent)
    indent = indent or ""

    local t = type(value)

    if value == nil then
        return "null"
    end

    if t == "boolean" then
        return value and "true" or "false"
    end

    if t == "number" then
        if value ~= value then
            return "null"
        end
        if value == math.huge or value == -math.huge then
            return "null"
        end
        if math.floor(value) == value then
            return string.format("%d", value)
        end
        return string.format("%.14g", value)
    end

    if t == "string" then
        return '"' .. json_escape_string(value) .. '"'
    end

    if t ~= "table" then
        return '"' .. json_escape_string(tostring(value)) .. '"'
    end

    if json_is_array(value) then
        if #value == 0 then
            return "[]"
        end

        local parts = {}
        local child_indent = indent .. "  "

        for i = 1, #value do
            table.insert(parts, child_indent .. json_pretty_encode(value[i], child_indent))
        end

        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    end

    local keys = {}
    for k in pairs(value) do
        table.insert(keys, tostring(k))
    end

    table.sort(keys)

    if #keys == 0 then
        return "{}"
    end

    local parts = {}
    local child_indent = indent .. "  "

    for _, k in ipairs(keys) do
        local v = value[k]
        if v ~= nil then
            table.insert(parts, child_indent .. '"' .. json_escape_string(k) .. '": ' .. json_pretty_encode(v, child_indent))
        end
    end

    if #parts == 0 then
        return "{}"
    end

    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function write_json_response(tbl)
    http.prepare_content("application/json")
    http.write(json.stringify(tbl))
end

local function contract_lookup_identity(portal_type, path_url)
    if not portal_type or portal_type == "" or not path_url or path_url == "" then
        return nil
    end

    if not SCRIPT_DIR:match("^[a-zA-Z0-9/_%.%-]+$") or SCRIPT_DIR:match("%.%.") then
        return nil
    end

    local cmd = string.format(
        "NETWORK_SH_EXEC=1 sh %s contract_lookup_identity %s %s 2>/dev/null",
        util.shellquote(SCRIPT_DIR .. "/network.sh"),
        util.shellquote(portal_type),
        util.shellquote(path_url)
    )

    local out = trim(sys.exec(cmd))
    if out == "" then
        return nil
    end

    local landing, executor = out:match("^([^|]+)|([^|]+)$")
    if not landing or not executor then
        return nil
    end

    return {
        landing = landing,
        executor = executor
    }
end

local function contract_lookup_url(url)
    if not url or url == "" then
        return nil
    end

    if not SCRIPT_DIR:match("^[a-zA-Z0-9/_%.%-]+$") or SCRIPT_DIR:match("%.%.") then
        return nil
    end

    local cmd = string.format(
        "NETWORK_SH_EXEC=1 sh %s contract_lookup_url %s 2>/dev/null",
        util.shellquote(SCRIPT_DIR .. "/network.sh"),
        util.shellquote(url)
    )

    local out = trim(sys.exec(cmd))
    if out == "" then
        return nil
    end

    local portal_type, show_params, corrected_path, encode, path_url, landing, executor =
        out:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")

    if not portal_type or portal_type == "unknown" then
        return nil
    end

    if not path_url or path_url == "" then
        return nil
    end

    if not landing or landing == "" or not executor or executor == "" then
        return nil
    end

    return {
        portal_type = portal_type,
        show_params = show_params,
        corrected_path = corrected_path or "",
        encode = encode or "spaces",
        path_url = path_url,
        landing = landing,
        executor = executor
    }
end

local function resolve_uci_section(log, dev)
    local safe_log = log and log:match("^[a-zA-Z0-9_.%-]+$")
    if not safe_log then
        portal_log("ERROR", "resolve_uci_section: logical name tidak valid: " .. (log or "nil"))
        return nil
    end
    local safe_dev = dev and dev:match("^[a-zA-Z0-9_.%-]+$") or ""
    portal_log("INFO", "resolve_uci_section: mencari logical=" .. safe_log .. " device=" .. safe_dev)

    local w_path = sys.exec(string.format(
        "uci -q show wireless 2>/dev/null | grep -E \"\\.network='?%s'?\" | head -1 | awk -F. '{print $1\".\"$2}'",
        safe_log
    )):gsub("\n", "")
    if w_path ~= "" then
        portal_log("INFO", "resolve_uci_section: ditemukan di wireless: " .. w_path)
        return w_path
    end

    local d_path = sys.exec(string.format(
        "uci -q show network 2>/dev/null | grep -E \"\\.name='?%s'?\" | head -1 | awk -F. '{print $1\".\"$2}'",
        safe_dev
    )):gsub("\n", "")
    if d_path ~= "" then
        portal_log("INFO", "resolve_uci_section: ditemukan di network (name): " .. d_path)
        return d_path
    end

    local l_path = sys.exec(string.format(
        "uci -q show network 2>/dev/null | grep -E \"\\.(ifname|device)='?%s'?\" | head -1 | awk -F. '{print $1\".\"$2}'",
        safe_dev
    )):gsub("\n", "")
    if l_path ~= "" then
        portal_log("INFO", "resolve_uci_section: ditemukan di network (ifname/device): " .. l_path)
        return l_path
    end

    local fallback = sys.exec(string.format(
        "uci -q get network.%s 2>/dev/null",
        safe_log
    )):gsub("\n", "")
    if fallback ~= "" then
        portal_log("INFO", "resolve_uci_section: fallback network." .. safe_log)
        return "network." .. fallback
    end

    portal_log("INFO", "resolve_uci_section: tidak ditemukan")
    return nil
end

function M.index()
    entry({"admin", "portal"}, firstchild(), _("Portal Manager"), 100)
    entry({"admin", "portal", "portal"}, template("portal/index"), _("Konfigurasi"), 1)
    entry({"admin", "portal", "scan"}, call("action_scan"))
    entry({"admin", "portal", "check_mac_spoof"}, call("check_mac_spoof_api"))
    entry({"admin", "portal", "apply_mac"}, call("apply_mac_api"))
    entry({"admin", "portal", "revert_mac"}, call("revert_mac_api"))
    entry({"admin", "portal", "mac_status"}, call("get_mac_status_api"))
    entry({"admin", "portal", "sync_time"}, call("sync_time_api"))
    entry({"admin", "portal", "rebind_protection"}, call("rebind_protection_api"))
    entry({"admin", "portal", "detect_url"}, call("detect_url_api"))
    entry({"admin", "portal", "quick_scan"}, call("quick_scan_api"))
    entry({"admin", "portal", "run_landing"}, call("run_landing_api"))
    entry({"admin", "portal", "normalize_path"}, call("normalize_path_api"))
    entry({"admin", "portal", "check_profile"}, call("check_profile_api"))
    entry({"admin", "portal", "get_profile"}, call("get_profile_api"))
    entry({"admin", "portal", "save_profile"}, call("save_profile_api"))
    entry({"admin", "portal", "list_profiles"}, call("list_profiles_api"))
    entry({"admin", "portal", "delete_profile"}, call("delete_profile_api"))
    entry({"admin", "portal", "execute_login"}, call("execute_login_api"))
    entry({"admin", "portal", "execute_logout"}, call("execute_logout_api"))
    entry({"admin", "portal", "autologin_status"}, call("autologin_status_api"))
    entry({"admin", "portal", "autologin_reset"}, call("autologin_reset_api"))
    entry({"admin", "portal", "autologin_start"}, call("autologin_start_api"))
    entry({"admin", "portal", "autologin_stop"}, call("autologin_stop_api"))
end

function M.action_scan()
    local script = SCRIPT_DIR .. "/deteksiportal.sh"
    portal_log("INFO", "portal.lua: Menjalankan pemindaian portal: " .. script)

    if not SCRIPT_DIR:match("^[a-zA-Z0-9/_%.%-]+$") or SCRIPT_DIR:match("%.%.") then
        portal_log("ERROR", "portal.lua: SCRIPT_DIR tidak valid: " .. SCRIPT_DIR)
        http.status(500, "Internal Server Error")
        http.write('{"error":"SCRIPT_DIR invalid"}')
        return
    end

    local f = io.popen(script, "r")
    if not f then
        portal_log("ERROR", "portal.lua: Gagal menjalankan script pemindaian")
        http.status(500, "Internal Server Error")
        http.write('{"error":"Gagal menjalankan script"}')
        return
    end

    local output = f:read("*a")
    f:close()

    local ok_parse, result = pcall(json.parse, output)
    if not ok_parse or not result or not result.interfaces then
        portal_log("ERROR", "action_scan - Gagal parse JSON: " .. tostring(result))
        http.prepare_content("application/json")
        http.write(output)
        return
    end

    local saved_profiles = {}
    local dir_iter = fs.dir(PROFILE_DIR)
    if dir_iter then
        for filename in dir_iter do
            if filename:match("%.json$") then
                local iface_name = filename:gsub("%.json$", "")
                saved_profiles[iface_name] = true
                portal_log("INFO", "action_scan - Profil tersimpan ditemukan: " .. iface_name)
            end
        end
    end

    local original_interface_count = #result.interfaces
    local filtered_interfaces = {}
    for idx, iface in ipairs(result.interfaces) do
        if saved_profiles[iface.interface] then
            portal_log("INFO", "action_scan - Interface " .. iface.interface .. " sudah tersimpan, dilewati dari hasil scan")
        else
            table.insert(filtered_interfaces, iface)
            portal_log("INFO", "action_scan - Interface " .. iface.interface .. " ditambahkan ke hasil scan")
        end
    end
    result.interfaces = filtered_interfaces
    portal_log("INFO", "action_scan - Total interface setelah filter: " .. #filtered_interfaces .. " dari " .. original_interface_count .. " asli")

    portal_log("INFO", "portal.lua: Pemindaian selesai. Panjang output: " .. string.len(output))
    http.prepare_content("application/json")
    http.write(json.stringify(result))
end

function M.check_mac_spoof_api()
    http.prepare_content("application/json")

    if not SCRIPT_DIR:match("^[a-zA-Z0-9/_%.%-]+$") or SCRIPT_DIR:match("%.%.") then
        portal_log("ERROR", "portal.lua: SCRIPT_DIR tidak valid: " .. SCRIPT_DIR)
        http.write('{"supported":false,"level":"none","checked_at":' .. os.time() .. '}')
        return
    end

    local cache_file = "/etc/portal/mac_spoof.cache"
    local cache_content = nil
    local f = io.open(cache_file, "r")
    if f then
        cache_content = f:read("*all")
        f:close()
    end

    if cache_content and cache_content:match('"supported"%s*:%s*true') then
        portal_log("INFO", "portal.lua: Cache MAC spoof ditemukan, supported=true")
        http.write(cache_content)
        return
    end

    if not cache_content or cache_content == "" then
        portal_log("INFO", "portal.lua: Cache MAC spoof kosong, jalankan deteksi")
        local f2 = io.popen(". " .. SCRIPT_DIR .. "/mac_spoof.sh && check_mac_spoof_support 2>/dev/null", "r")
        if f2 then
            cache_content = f2:read("*a")
            f2:close()
        end
    end

    if cache_content and cache_content:match('"supported"') then
        portal_log("INFO", "portal.lua: Deteksi MAC spoof selesai")
        http.write(cache_content)
    else
        portal_log("ERROR", "portal.lua: Deteksi MAC spoof gagal, kembalikan default")
        http.write('{"supported":false,"level":"none","checked_at":' .. os.time() .. '}')
    end
end

function M.apply_mac_api()
    http.prepare_content("application/json")
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "apply_mac - Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end

    local logical = http.formvalue("logical")
    local device = http.formvalue("device")
    local target = http.formvalue("target_mac")
    local device_type = http.formvalue("device_type")

    if not logical or not device or not target then
        portal_log("ERROR", "apply_mac - Parameter kurang")
        http.write('{"status":"error","message":"Missing parameters"}')
        return
    end

    portal_log("INFO", "apply_mac - logical=" .. logical .. " device=" .. device .. " target=" .. target)

    local uci_section = resolve_uci_section(logical, device)
    if not uci_section then
        portal_log("ERROR", "apply_mac - UCI section tidak ditemukan untuk " .. logical .. "/" .. device)
        http.write('{"status":"error","message":"UCI section not found"}')
        return
    end

    local cmd = string.format("%s apply %s %s %s %s",
        util.shellquote(SCRIPT_DIR .. "/mac_apply.sh"),
        util.shellquote(uci_section),
        util.shellquote(device),
        util.shellquote(target),
        util.shellquote(device_type or "")
    )

    local f = io.popen(cmd, "r")
    if not f then
        portal_log("ERROR", "apply_mac - Gagal eksekusi backend")
        http.write('{"status":"error","message":"Backend execution failed"}')
        return
    end

    local output = f:read("*a")
    f:close()

    if output and output ~= "" then
        portal_log("INFO", "apply_mac - Berhasil")
        local mac_backup_file = STATE_DIR .. "/" .. logical .. ".mac"
        sys.call(string.format("mkdir -p %s >/dev/null 2>&1", util.shellquote(STATE_DIR)))
        local current_orig = sys.exec(string.format("uci -q get %s.original_macaddr 2>/dev/null", util.shellquote(uci_section))):gsub("\n", "")
        if current_orig ~= "" then
            local f_bak = io.open(mac_backup_file, "w")
            if f_bak then
                f_bak:write(current_orig .. "\n")
                f_bak:close()
                portal_log("INFO", "apply_mac - Original MAC dibackup ke " .. mac_backup_file)
            end
        end
        http.write(output)
        sys.call("NETWORK_SH_EXEC=1 sh " .. SCRIPT_DIR .. "/network.sh restart_interface_specific " .. util.shellquote(logical) .. " >/dev/null 2>&1")
    else
        portal_log("ERROR", "apply_mac - Backend kembalikan output kosong")
        http.write('{"status":"error","message":"Backend execution failed"}')
    end
end

function M.revert_mac_api()
    http.prepare_content("application/json")
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "revert_mac - Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end

    local logical = http.formvalue("logical")
    local device = http.formvalue("device")
    local orig = http.formvalue("original_mac")

    if not logical or not device or not orig then
        portal_log("ERROR", "revert_mac - Parameter kurang")
        http.write('{"status":"error","message":"Missing parameters"}')
        return
    end

    portal_log("INFO", "revert_mac - logical=" .. logical .. " device=" .. device .. " orig=" .. orig)

    local uci_section = resolve_uci_section(logical, device)
    if not uci_section then
        portal_log("ERROR", "revert_mac - UCI section tidak ditemukan untuk " .. logical .. "/" .. device)
        http.write('{"status":"error","message":"UCI section not found"}')
        return
    end

    local cmd = string.format("%s revert %s %s %s",
        util.shellquote(SCRIPT_DIR .. "/mac_apply.sh"),
        util.shellquote(uci_section),
        util.shellquote(device),
        util.shellquote(orig)
    )

    local f = io.popen(cmd, "r")
    if not f then
        portal_log("ERROR", "revert_mac - Gagal eksekusi backend")
        http.write('{"status":"error","message":"Backend execution failed"}')
        return
    end

    local output = f:read("*a")
    f:close()

    if output and output ~= "" then
        portal_log("INFO", "revert_mac - Berhasil")
        http.write(output)
        portal_log("INFO", "revert_mac - Merestart interface spesifik: " .. logical)
        sys.call("NETWORK_SH_EXEC=1 sh " .. SCRIPT_DIR .. "/network.sh restart_interface_specific " .. util.shellquote(logical) .. " >/dev/null 2>&1")
    else
        portal_log("ERROR", "revert_mac - Backend kembalikan output kosong")
        http.write('{"status":"error","message":"Backend execution failed"}')
    end
end

function M.get_mac_status_api()
    http.prepare_content("application/json")

    local logical = http.formvalue("logical")
    local device = http.formvalue("device")

    if not logical or not device then
        portal_log("ERROR", "get_mac_status - Parameter kurang")
        http.write('{"is_modified":false,"uci_section":null}')
        return
    end

    local uci_section = resolve_uci_section(logical, device)
    if not uci_section then
        portal_log("INFO", "get_mac_status - UCI section tidak ditemukan untuk " .. logical .. "/" .. device)
        http.write('{"is_modified":false,"uci_section":null}')
        return
    end

    local macaddr = sys.exec(string.format("uci -q get %s.macaddr 2>/dev/null", util.shellquote(uci_section))):gsub("\n", "")
    local mac_vendor = sys.exec(string.format("uci -q get %s.mac_vendor 2>/dev/null", util.shellquote(uci_section))):gsub("\n", "")
    local original_macaddr = sys.exec(string.format("uci -q get %s.original_macaddr 2>/dev/null", util.shellquote(uci_section))):gsub("\n", "")

    if original_macaddr == "" then
        local mac_backup_file = STATE_DIR .. "/" .. logical .. ".mac"
        if fs.access(mac_backup_file) then
            local f_bak = io.open(mac_backup_file, "r")
            if f_bak then
                original_macaddr = f_bak:read("*l") or ""
                f_bak:close()
                portal_log("INFO", "get_mac_status - Original MAC dibaca dari backup: " .. original_macaddr)
            end
        end
    end
    
    local is_modified = (macaddr ~= "") and (macaddr ~= original_macaddr)

    portal_log("INFO", "get_mac_status - section=" .. uci_section .. " modified=" .. tostring(is_modified))

    local result = {
        is_modified = is_modified,
        uci_section = uci_section,
        macaddr = macaddr,
        mac_vendor = mac_vendor,
        original_macaddr = original_macaddr
    }
    http.write(json.stringify(result))
end

function M.sync_time_api()
    http.prepare_content("application/json")

    local current_tz = sys.exec("uci -q get system.@system[0].zonename 2>/dev/null"):gsub("\n", "")
    local cache_tz = sys.exec("tail -1 /etc/portal/tz.cache 2>/dev/null"):gsub("\n", "")

    if current_tz ~= "" and current_tz ~= "UTC" and current_tz ~= "Etc/UTC" and current_tz == cache_tz then
        portal_log("INFO", "sync_time - Zona waktu sudah valid (" .. current_tz .. "), lewati")
        http.write(string.format('{"status":"skipped","message":"Zona waktu sudah valid","system_time":"%s","timezone":"%s"}',
            os.date("%H:%M:%S %d-%m-%Y"), current_tz))
        return
    end

    portal_log("INFO", "sync_time - Mulai sinkronisasi zona waktu")
    local safe_dir = SCRIPT_DIR:gsub("'", "'\\''")
    os.execute("sh '" .. safe_dir .. "/auto_timezone.sh' >/dev/null 2>&1 &")

    local display_tz = current_tz
    if display_tz == "" then display_tz = "mendeteksi..." end

    http.write(string.format('{"status":"initiated","message":"Sinkronisasi zona waktu dimulai","system_time":"%s","timezone":"%s"}',
        os.date("%H:%M:%S %d-%m-%Y"), display_tz))
end

function M.rebind_protection_api()
    http.prepare_content("application/json")

    portal_log("INFO", "rebind_protection - Dijalankan")
    local safe_dir = SCRIPT_DIR:gsub("'", "'\\''")

    sys.call("NETWORK_SH_EXEC=1 sh " .. safe_dir .. "/network.sh disable_rebind_protection >/dev/null 2>&1")

    http.write('{"status":"done"}')
end

function M.detect_url_api()
    http.prepare_content("application/json")

    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "detect_url - Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end

    local logical = http.formvalue("logical")
    local device  = http.formvalue("device")

    if not logical or not device then
        portal_log("ERROR", "detect_url - Parameter kurang")
        http.write('{"status":"error","message":"Missing parameters"}')
        return
    end

    local safe_logical = logical:match("^[a-zA-Z0-9_.%-]+$")
    local safe_device  = device:match("^[a-zA-Z0-9_.%-]+$")
    if not safe_logical or not safe_device then
        portal_log("ERROR", "detect_url - Nama interface tidak valid: " .. (logical or "nil") .. "/" .. (device or "nil"))
        http.write('{"status":"error","message":"Invalid interface name"}')
        return
    end

    if not SCRIPT_DIR:match("^[a-zA-Z0-9/_%.%-]+$") or SCRIPT_DIR:match("%.%.") then
        portal_log("ERROR", "detect_url - SCRIPT_DIR tidak valid: " .. (SCRIPT_DIR or "nil"))
        http.write('{"status":"error","message":"SCRIPT_DIR invalid"}')
        return
    end

    portal_log("INFO", "detect_url - Mulai proses untuk logical=" .. safe_logical .. " device=" .. safe_device)

    local safe_lock_name = safe_logical:gsub("[^%w_%-%.]", "_")
    local detect_lock_path = DETECT_LOCK_PREFIX .. safe_lock_name .. DETECT_LOCK_SUFFIX

    if fs.access(detect_lock_path) then
        local lock_allowed = false
        local f_lock = io.open(detect_lock_path .. "/started_at", "r")

        if f_lock then
            local started = tonumber(f_lock:read("*l"))
            f_lock:close()

            if (not started) or started <= 0 or (os.time() - started) >= DETECT_LOCK_TIMEOUT then
                lock_allowed = true
            end
        else
            lock_allowed = true
        end

        if not lock_allowed then
            portal_log("WARN", "detect_url - Lock deteksi masih aktif untuk " .. safe_logical)
            http.write('{"status":"error","message":"Detection already in progress for interface"}')
            return
        end

        portal_log("WARN", "detect_url - Stale lock deteksi dibiarkan dibersihkan oleh backend: " .. safe_logical)
    end

    local restart_cmd = "NETWORK_SH_EXEC=1 sh " .. SCRIPT_DIR .. "/network.sh restart_interface " .. util.shellquote(safe_logical) .. " >/dev/null 2>&1"
    portal_log("INFO", "detect_url - Menjalankan: " .. restart_cmd)
    local restart_ok = sys.call(restart_cmd)
    if restart_ok ~= 0 then
        portal_log("ERROR", "detect_url - Gagal restart interface " .. safe_logical)
        http.write('{"status":"error","message":"Interface restart failed"}')
        return
    end

    portal_log("INFO", "detect_url - Menunggu " .. safe_device .. " UP...")
    local max_wait = 15
    local waited = 0
    local link_up = false
    local operstate_path = "/sys/class/net/" .. safe_device .. "/operstate"
    while waited < max_wait do
        local f_state = io.open(operstate_path, "r")
        if f_state then
            local state = f_state:read("*l")
            f_state:close()
            if state == "up" or state == "unknown" then
                link_up = true
                break
            end
        end
        sys.call("sleep 1 >/dev/null 2>&1")
        waited = waited + 1
    end

    if not link_up then
        portal_log("ERROR", "detect_url - " .. safe_device .. " tidak UP setelah " .. waited .. " detik")
        http.write(string.format('{"status":"error","message":"Interface %s not ready after %d seconds"}', safe_device, waited))
        return
    end
    portal_log("INFO", "detect_url - " .. safe_device .. " UP setelah " .. waited .. " detik")

    portal_log("INFO", "detect_url - Menunggu " .. safe_device .. " mendapatkan IP...")
    waited = 0
    local has_ip = false
    local ok_ubus, ubus_mod = pcall(require, "ubus")
    local conn = ok_ubus and ubus_mod.connect()

    if conn then
        while waited < max_wait do
            local status = conn:call("network.interface." .. safe_logical, "status", {})
            if status and status["ipv4-address"] and #status["ipv4-address"] > 0 then
                has_ip = true
                portal_log("INFO", "detect_url - IP didapat via ubus setelah " .. waited .. " detik")
                break
            end
            sys.call("sleep 1 >/dev/null 2>&1")
            waited = waited + 1
        end
        conn:close()
    else
        portal_log("WARN", "detect_url - ubus tidak tersedia, gunakan fallback ip addr")
        while waited < max_wait do
            local ip_check = sys.exec("ip -4 addr show dev " .. util.shellquote(safe_device) .. " 2>/dev/null | grep -oE 'inet [0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+' | awk '{print $2}' | head -1"):gsub("\n", "")
            if ip_check ~= "" then
                has_ip = true
                portal_log("INFO", "detect_url - IP didapat via fallback setelah " .. waited .. " detik: " .. ip_check)
                break
            end
            sys.call("sleep 1 >/dev/null 2>&1")
            waited = waited + 1
        end
    end

    if not has_ip then
        portal_log("ERROR", "detect_url - " .. safe_device .. " tidak mendapatkan IP setelah " .. waited .. " detik")
        http.write(string.format('{"status":"error","message":"Interface %s did not get IP after %d seconds"}', safe_device, waited))
        return
    end
    portal_log("INFO", "detect_url - " .. safe_device .. " mendapatkan IP setelah " .. waited .. " detik")

    local script = SCRIPT_DIR .. "/deteksiportal.sh"
    local cmd = string.format("%s single %s %s",
        script,
        util.shellquote(safe_logical),
        util.shellquote(safe_device))
    portal_log("INFO", "detect_url - Menjalankan: " .. cmd)
    local f = io.popen(cmd, "r")
    if not f then
        portal_log("ERROR", "detect_url - Gagal eksekusi script deteksi")
        http.write('{"status":"error","message":"Detection script failed"}')
        return
    end

    local output = f:read("*a")
    f:close()
    portal_log("INFO", "detect_url - Output panjang: " .. string.len(output))
    portal_log("DEBUG", "detect_url - Output: " .. output:sub(1, 500))

    local ok_parse, result = pcall(json.parse, output)
    if not ok_parse or not result then
        portal_log("ERROR", "detect_url - Gagal parse JSON: " .. tostring(result))
        http.write('{"status":"error","message":"Invalid detection result"}')
        return
    end

    if result.status == "error" then
        portal_log("WARN", "detect_url - Deteksi ditolak backend: " .. tostring(result.message or "unknown"))
        http.write(json.stringify({
            status = "error",
            message = result.message or "Detection already in progress for interface"
        }))
        return
    end

    if not result.interfaces then
        portal_log("ERROR", "detect_url - Hasil deteksi tidak memiliki daftar interface")
        http.write('{"status":"error","message":"Invalid detection result"}')
        return
    end

    portal_log("INFO", "detect_url - Jumlah interface terdeteksi: " .. #result.interfaces)
    for idx, iface in ipairs(result.interfaces) do
        portal_log("INFO", "detect_url - Interface[" .. idx .. "]: " .. (iface.interface or "nil") .. " ==? " .. safe_logical)
        if iface.interface == safe_logical then
            portal_log("INFO", "detect_url - COCOK, mengembalikan data")
            http.write(json.stringify(iface))
            return
        end
    end

    portal_log("ERROR", "detect_url - Tidak menemukan " .. safe_logical .. " di hasil deteksi")
    http.write(string.format('{"status":"error","message":"Interface %s not found in detection result"}', safe_logical))
end

function M.quick_scan_api()
    http.prepare_content("application/json")
    
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "quick_scan - Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end

    local logical = http.formvalue("logical")
    local device = http.formvalue("device")

    if not logical or not device then
        portal_log("ERROR", "quick_scan - Parameter kurang")
        http.write('{"status":"error","message":"Missing parameters"}')
        return
    end

    local safe_logical = logical:match("^[a-zA-Z0-9_.%-]+$")
    local safe_device = device:match("^[a-zA-Z0-9_.%-]+$")
    if not safe_logical or not safe_device then
        portal_log("ERROR", "quick_scan - Nama interface tidak valid: " .. (logical or "nil") .. "/" .. (device or "nil"))
        http.write('{"status":"error","message":"Invalid interface name"}')
        return
    end

    if not SCRIPT_DIR:match("^[a-zA-Z0-9/_%.%-]+$") or SCRIPT_DIR:match("%.%.") then
        portal_log("ERROR", "quick_scan - SCRIPT_DIR tidak valid: " .. (SCRIPT_DIR or "nil"))
        http.write('{"status":"error","message":"SCRIPT_DIR invalid"}')
        return
    end

    portal_log("INFO", "quick_scan - Mulai deteksi cepat untuk logical=" .. safe_logical .. " device=" .. safe_device)

    local script = SCRIPT_DIR .. "/deteksiportal.sh"
    local cmd = string.format("%s single %s %s skip_landing",
        script,
        util.shellquote(safe_logical),
        util.shellquote(safe_device))
    portal_log("INFO", "quick_scan - Menjalankan: " .. cmd)
    
    local f = io.popen(cmd, "r")
    if not f then
        portal_log("ERROR", "quick_scan - Gagal eksekusi script deteksi")
        http.write('{"status":"error","message":"Detection script failed"}')
        return
    end

    local output = f:read("*a")
    f:close()
    portal_log("INFO", "quick_scan - Output panjang: " .. string.len(output))

    local ok_parse, result = pcall(json.parse, output)
    if not ok_parse or not result then
        portal_log("ERROR", "quick_scan - Gagal parse JSON: " .. tostring(result))
        http.write('{"status":"error","message":"Invalid detection result"}')
        return
    end

    if result.status == "error" then
        portal_log("WARN", "quick_scan - Deteksi ditolak backend: " .. tostring(result.message or "unknown"))
        http.write(json.stringify({
            status = "error",
            message = result.message or "Detection already in progress for interface"
        }))
        return
    end

    if not result.interfaces then
        portal_log("ERROR", "quick_scan - Hasil deteksi tidak memiliki daftar interface")
        http.write('{"status":"error","message":"Invalid detection result"}')
        return
    end

    portal_log("INFO", "quick_scan - Jumlah interface terdeteksi: " .. #result.interfaces)
    for idx, iface in ipairs(result.interfaces) do
        portal_log("INFO", "quick_scan - Interface[" .. idx .. "]: " .. (iface.interface or "nil") .. " ==? " .. safe_logical)
        if iface.interface == safe_logical then
            portal_log("INFO", "quick_scan - COCOK, mengembalikan data")
            http.write(json.stringify(iface))
            return
        end
    end

    portal_log("ERROR", "quick_scan - Tidak menemukan " .. safe_logical .. " di hasil deteksi")
    http.write(string.format('{"status":"error","message":"Interface %s not found in detection result"}', safe_logical))
end

function M.normalize_path_api()
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        write_json_response({status = "error", message = "Method not allowed"})
        return
    end

    local url = http.formvalue("url") or ""
    local contract = contract_lookup_url(url)

    if not contract then
        write_json_response({status = "error", message = "Path tidak dikenali atau bukan portal resmi"})
        return
    end

    write_json_response({
        status = "success",
        portal_type = contract.portal_type,
        path_url = contract.path_url,
        landing_script = contract.landing,
        login_executor = contract.executor,
        show_params = tonumber(contract.show_params) or 0,
        corrected_path = contract.corrected_path,
        encode = contract.encode
    })
end

function M.run_landing_api()
    portal_log("INFO", "run_landing - Dijalankan")

    http.prepare_content("application/json")

    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "run_landing - Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end

    local url = http.formvalue("url")
    local ip = http.formvalue("ip")
    local path = http.formvalue("path")
    local gateway = http.formvalue("gateway")
    local logical = http.formvalue("logical") or ""
    local ipc = http.formvalue("ipc") or ""
    local device = http.formvalue("device") or ""

    if not url or not ip or not path or not gateway then
        portal_log("ERROR", "run_landing - Parameter kurang")
        http.write('{"status":"error","message":"Missing parameters"}')
        return
    end

    local portal_type = http.formvalue("portal_type") or ""
    local path_url = http.formvalue("path_url") or ""
    local contract = nil
    local landing_script = nil

    if portal_type ~= "" and path_url ~= "" then
        local ident = contract_lookup_identity(portal_type, path_url)
        if ident then
            contract = {
                portal_type = portal_type,
                path_url = path_url,
                landing = ident.landing,
                executor = ident.executor
            }
        end
    end

    if not contract then
        contract = contract_lookup_url(url)
    end

    if not contract then
        portal_log("ERROR", "run_landing - Kontrak portal tidak valid untuk url=" .. url)
        write_json_response({status = "error", message = "Portal tidak resmi atau path_url tidak valid"})
        return
    end

    landing_script = "/usr/lib/portal/landing/" .. contract.landing

    if landing_script and fs.access(landing_script, "x") then
        portal_log("INFO", "run_landing - Menjalankan " .. landing_script .. " (portal_type=" .. contract.portal_type .. ", path_url=" .. contract.path_url .. ")")
        local cmd = string.format(
            "sleep 2 && env PORTAL_TYPE=%s PATH_URL=%s sh %s %s %s %s %s %s %s %s >/dev/null 2>&1 &",
            util.shellquote(contract.portal_type),
            util.shellquote(contract.path_url),
            util.shellquote(landing_script),
            util.shellquote(url),
            util.shellquote(ip),
            util.shellquote(path),
            util.shellquote(gateway),
            util.shellquote(ipc),
            util.shellquote(logical),
            util.shellquote(device)
        )
        os.execute(cmd)
        write_json_response({
            status = "success",
            message = "Landing script executed",
            portal_type = contract.portal_type,
            path_url = contract.path_url,
            landing_script = contract.landing
        })
    else
        portal_log("ERROR", "run_landing - Landing script tidak ditemukan: " .. tostring(landing_script))
        write_json_response({status = "error", message = "Landing script not found"})
    end
end

function M.check_profile_api()
    http.prepare_content("application/json")
    local logical = http.formvalue("logical")
    
    if not logical or not logical:match("^[a-zA-Z0-9_.%-]+$") then
        portal_log("ERROR", "check_profile: Logical name tidak valid")
        http.write('{"exists":false}')
        return
    end
    
    local file_path = PROFILE_DIR .. "/" .. logical .. ".json"
    local exists = fs.access(file_path)

    local exists_json = exists and "true" or "false"
    
    portal_log("INFO", "check_profile: " .. logical .. " exists=" .. exists_json)
    http.write('{"exists":' .. exists_json .. '}')
end

function M.save_profile_api()
    http.prepare_content("application/json")
    
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "save_profile: Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end

    local raw_data = http.content()
    local ok, data = pcall(json.parse, raw_data)
    if not ok or not data then
        portal_log("ERROR", "save_profile: Gagal parse JSON payload")
        http.write('{"status":"error","message":"Invalid JSON payload"}')
        return
    end

    local logical = data.interface
    if not logical or not logical:match("^[a-zA-Z0-9_.%-]+$") then
        portal_log("ERROR", "save_profile: Interface name tidak valid atau kosong")
        http.write('{"status":"error","message":"Invalid interface name"}')
        return
    end

    if not data.username or not data.password or not data.portal_url or not data.device then
        portal_log("ERROR", "save_profile: Field wajib kosong untuk " .. logical)
        write_json_response({status = "error", message = "Field wajib (Username, Password, URL Portal, Device) tidak boleh kosong"})
        return
    end

    local resolved_contract = nil

    if data.portal_url and data.portal_url ~= "" then
        resolved_contract = contract_lookup_url(data.portal_url)
    end

    if not resolved_contract and data.portal_type and data.path_url then
        local ident = contract_lookup_identity(data.portal_type, data.path_url)
        if ident then
            resolved_contract = {
                portal_type = data.portal_type,
                path_url = data.path_url,
                landing = ident.landing,
                executor = ident.executor
            }
        end
    end

    if not resolved_contract then
        portal_log("ERROR", "save_profile: Portal tidak resmi atau path_url tidak valid untuk " .. logical)
        write_json_response({status = "error", message = "Portal tidak resmi atau path_url tidak valid"})
        return
    end

    data.portal_type = resolved_contract.portal_type
    data.path_url = resolved_contract.path_url

    local mode = data.mode or "create"
    local file_path = PROFILE_DIR .. "/" .. logical .. ".json"

    if mode == "create" then
        if fs.access(file_path) then
            portal_log("WARN", "save_profile: Profil sudah ada untuk " .. logical)
            http.write('{"status":"error","message":"Profil sudah ada"}')
            return
        end
    elseif mode == "update" then
        if not fs.access(file_path) then
            portal_log("ERROR", "save_profile: Profil tidak ditemukan untuk diupdate: " .. logical)
            http.write('{"status":"error","message":"Profil tidak ditemukan untuk diupdate"}')
            return
        end
        portal_log("INFO", "save_profile: Mode update untuk " .. logical)
    else
        portal_log("ERROR", "save_profile: Mode tidak valid: " .. tostring(mode))
        http.write('{"status":"error","message":"Invalid mode"}')
        return
    end

    local mkdir_cmd = string.format("mkdir -p %s >/dev/null 2>&1", util.shellquote(PROFILE_DIR))
    os.execute(mkdir_cmd)

    local lock_dir = "/tmp/portal_profile_" .. logical .. ".lock"
    local function release_profile_lock()
        os.execute(string.format("rmdir %s >/dev/null 2>&1", util.shellquote(lock_dir)))
    end

    local lock_acquired = false
    local lock_wait = 0
    local lock_max_wait = 50
    while lock_wait < lock_max_wait do
        if not fs.access(lock_dir) then
            local mkdir_lock = string.format("mkdir %s >/dev/null 2>&1", util.shellquote(lock_dir))
            if os.execute(mkdir_lock) == 0 then
                lock_acquired = true
                break
            end
        end
        os.execute("sleep 0.1 >/dev/null 2>&1")
        lock_wait = lock_wait + 1
    end

    if not lock_acquired then
        portal_log("WARN", "save_profile: Timeout menunggu lock untuk " .. logical .. ". Daemon sedang aktif. Coba lagi.")
        http.write('{"status":"error","message":"Profil sedang dikunci oleh daemon. Coba beberapa detik lagi."}')
        return
    end

    local exists = fs.access(file_path)

    if mode == "create" and exists then
        release_profile_lock()
        portal_log("WARN", "save_profile: Profil sudah ada untuk " .. logical)
        http.write('{"status":"error","message":"Profil sudah ada"}')
        return
    end

    if mode == "update" and not exists then
        release_profile_lock()
        portal_log("ERROR", "save_profile: Profil tidak ditemukan untuk diupdate: " .. logical)
        http.write('{"status":"error","message":"Profil tidak ditemukan untuk diupdate"}')
        return
    end

    local old_data = nil
    if exists then
        local f_old = io.open(file_path, "r")
        if f_old then
            local old_content = f_old:read("*a")
            f_old:close()
            local ok_old, parsed_old = pcall(json.parse, old_content)
            if ok_old and parsed_old then
                old_data = parsed_old
            end
        end
    end

    local raw_username = ""
    if type(data.username_raw) == "string" then
        raw_username = trim(data.username_raw)
    end
    if raw_username == "" and type(data.username) == "string" then
        raw_username = data.username
    end
    data.username_raw = raw_username

    local new_gateway = ""
    if type(data.gateway) == "string" then
        new_gateway = trim(data.gateway)
    end
    if new_gateway == "" and old_data and type(old_data.gateway) == "string" then
        new_gateway = trim(old_data.gateway)
    end
    data.gateway = new_gateway

    local now = os.date("%H:%M:%S %d-%m-%Y")
    local old_created_at = ""
    if old_data and type(old_data.created_at) == "string" then
        old_created_at = trim(old_data.created_at)
    end

    if mode == "update" and old_created_at ~= "" then
        data.created_at = old_created_at
    else
        data.created_at = now
    end
    data.updated_at = now

    if resolved_contract and resolved_contract.show_params == "0" then
        data.gw_id = nil
        data.client_mac = nil
        data.wlan = nil
        data.sessionid = nil
        data.ipc = nil
    end

    local json_str = json_pretty_encode(data, "")

    local tmp_path = file_path .. ".tmp"
    local file = io.open(tmp_path, "w")
    if not file then
        release_profile_lock()
        portal_log("ERROR", "save_profile: Gagal membuka file untuk ditulis: " .. tmp_path)
        http.write('{"status":"error","message":"Gagal membuka file sistem"}')
        return
    end

    file:write(json_str .. "\n")
    file:close()

    local rename_ok, rename_err = os.rename(tmp_path, file_path)
    if not rename_ok then
        os.remove(tmp_path)
        release_profile_lock()
        portal_log("ERROR", "save_profile: Gagal rename file profil: " .. tostring(rename_err))
        http.write('{"status":"error","message":"Gagal menyimpan file profil"}')
        return
    end

    release_profile_lock()

    portal_log("INFO", "save_profile: Berhasil menyimpan profil untuk " .. logical)

    local state_file = "/etc/portal/state/" .. logical .. ".state"
    local initial_state = "first_login"

    if mode == "update" then
        portal_log("INFO", "save_profile: Mode update. State awal = FIRST_LOGIN; status real-time akan ditentukan oleh oneshot hybrid check.")
    else
        portal_log("INFO", "save_profile: Mode create. State awal = FIRST_LOGIN; status real-time akan ditentukan oleh oneshot hybrid check.")
    end

    local state_dir = "/etc/portal/state"
    if not fs.access(state_dir) then
        os.execute("mkdir -p " .. util.shellquote(state_dir) .. " >/dev/null 2>&1")
    end

    local f_state = io.open(state_file, "w")
    if f_state then
        f_state:write("STATE=" .. initial_state .. "\n")
        f_state:write("RETRY_COUNT=0\n")
        f_state:write("LAST_ATTEMPT=" .. os.date("%H:%M:%S %d-%m-%Y") .. "\n")
        f_state:write("LAST_ACTION=profile_save\n")
        f_state:write("LAST_RESULT=success\n")
        f_state:write("LAST_MESSAGE=Profil baru disimpan untuk " .. logical .. "\n")
        if initial_state == "active" then
            f_state:write("LAST_LOGIN=" .. os.date("%H:%M:%S %d-%m-%Y") .. "\n")
        end
        f_state:close()
        portal_log("INFO", "save_profile: State file ditulis: " .. state_file .. " (STATE=" .. initial_state .. ")")
    else
        portal_log("ERROR", "save_profile: Gagal menulis state file: " .. state_file)
    end

    if data.autoLoginReconnect and data.autoLoginReconnect.enabled == true then
        portal_log("INFO", "save_profile: Auto-Login ON terdeteksi. Menginisialisasi backend daemon untuk " .. logical)
        sys.call("/etc/init.d/portal_autologin enable >/dev/null 2>&1")
        portal_log("INFO", "save_profile: Service auto-login di-enable untuk persistence pasca-reboot")

        sys.call("/etc/init.d/portal_autologin start >/dev/null 2>&1")
        portal_log("INFO", "save_profile: Service auto-login dipastikan berjalan (monitoring mode)")

        portal_log("INFO", "save_profile: Memicu eksekusi login real-time (oneshot) di background untuk " .. logical)
        local safe_logical = logical:match("^[a-zA-Z0-9_.%-]+$")
        if safe_logical then
            local oneshot_cmd = string.format("sh /usr/lib/portal/autologin.sh oneshot %s >/dev/null 2>&1 &", util.shellquote(safe_logical))
            os.execute(oneshot_cmd)
            portal_log("INFO", "save_profile: Trigger oneshot berhasil dilepas ke background")
        else
            portal_log("ERROR", "save_profile: Nama logical tidak valid untuk trigger oneshot")
        end
    else
        portal_log("INFO", "save_profile: Auto-Login OFF. Backend daemon tidak diaktifkan untuk " .. logical)
    end

    http.write('{"status":"success","message":"Profil berhasil disimpan"}')
end

local function is_enabled(obj)
    if type(obj) == "table" then
        return obj.enabled == true
    end
    return obj == true
end

local function read_state_file(logical)
    local safe = logical and logical:match("^[a-zA-Z0-9_.%-]+$")
    if not safe then
        return {
            STATE = "unknown",
            RETRY_COUNT = "0",
            LAST_ATTEMPT = "",
            LAST_LOGIN = ""
        }
    end

    local path = "/etc/portal/state/" .. safe .. ".state"
    local state = {
        STATE = "unknown",
        RETRY_COUNT = "0",
        LAST_ATTEMPT = "",
        LAST_LOGIN = ""
    }

    local f = io.open(path, "r")
    if not f then
        return state
    end

    for line in f:lines() do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key and value then
            state[key] = value
        end
    end

    f:close()
    return state
end

function M.list_profiles_api()
    http.prepare_content("application/json")

    local profiles = {}
    local dir_iter = fs.dir(PROFILE_DIR)

    if dir_iter then
        for filename in dir_iter do
            if filename:match("%.json$") then
                local iface_name = filename:gsub("%.json$", "")
                local file_path = PROFILE_DIR .. "/" .. filename
                local f = io.open(file_path, "r")

                if f then
                    local content = f:read("*a")
                    f:close()

                    local ok, data = pcall(json.parse, content)
                    if ok and data then
                        local auto_login_enabled = is_enabled(data.autoLoginReconnect)
                        local anti_block_enabled = is_enabled(data.antiBlocking)
                        local hostname_enabled = is_enabled(data.randomHostname)
                        local notif_enabled = is_enabled(data.notification)

                        local has_advanced = auto_login_enabled
                            or anti_block_enabled
                            or hostname_enabled
                            or notif_enabled

                        local state = read_state_file(iface_name)
                        local real_status = state.STATE or "unknown"
                        local retry_count = tonumber(state.RETRY_COUNT) or 0

                        table.insert(profiles, {
                            interface = data.interface or iface_name,
                            device = data.device or "-",
                            portal_type = data.portal_type or "Unknown",
                            path_url = data.path_url or "-",
                            ip = data.ipc or "-",
                            auto_login = auto_login_enabled,
                            anti_block = anti_block_enabled,
                            hostname = hostname_enabled,
                            notif = notif_enabled,
                            status = real_status,
                            retry_count = retry_count,
                            last_attempt = state.LAST_ATTEMPT or "",
                            last_login = state.LAST_LOGIN or "",
                            username = data.username or "-",
                            has_advanced = has_advanced,
                            updated_at = data.updated_at or "Unknown"
                        })
                    end
                end
            end
        end
    end

    portal_log("INFO", "list_profiles: Ditemukan " .. #profiles .. " profil")
    http.write(json.stringify(profiles))
end

function M.get_profile_api()
    http.prepare_content("application/json")
    local logical = http.formvalue("logical")
    
    if not logical or not logical:match("^[a-zA-Z0-9_.%-]+$") then
        portal_log("ERROR", "get_profile: Logical name tidak valid")
        http.write('{"error":"Invalid logical name"}')
        return
    end
    
    local file_path = PROFILE_DIR .. "/" .. logical .. ".json"
    if not fs.access(file_path) then
        portal_log("WARN", "get_profile: Profil tidak ditemukan untuk " .. logical)
        http.write('{"error":"Profile not found"}')
        return
    end
    
    local f = io.open(file_path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        portal_log("INFO", "get_profile: Berhasil membaca profil untuk " .. logical)
        http.write(content)
    else
        portal_log("ERROR", "get_profile: Gagal membuka file " .. file_path)
        http.write('{"error":"Failed to read file"}')
    end
end

function M.delete_profile_api()
    http.prepare_content("application/json")
    
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "delete_profile: Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end

    local logical = http.formvalue("logical")
    if not logical or not logical:match("^[a-zA-Z0-9_.%-]+$") then
        portal_log("ERROR", "delete_profile: Logical name tidak valid")
        http.write('{"status":"error","message":"Invalid logical name"}')
        return
    end

    local file_path = PROFILE_DIR .. "/" .. logical .. ".json"
    if not fs.access(file_path) then
        portal_log("WARN", "delete_profile: Profil tidak ditemukan untuk " .. logical)
        http.write('{"status":"error","message":"Profil tidak ditemukan"}')
        return
    end

    portal_log("INFO", "delete_profile: Memulai proses penghapusan untuk " .. logical)

    local profile_data = {}
    local f = io.open(file_path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(json.parse, content)
        if ok and data then
            profile_data = data
            portal_log("INFO", "delete_profile: Data profil berhasil dibaca (portal_type=" .. (data.portal_type or "nil") .. ", device=" .. (data.device or "nil") .. ")")
        end
    end

    if profile_data.portal_type and profile_data.device then
        local logout_path_url = profile_data.path_url or ""

        if logout_path_url == "" and profile_data.portal_url and profile_data.portal_url ~= "" then
            local c = contract_lookup_url(profile_data.portal_url)
            if c then
                profile_data.portal_type = c.portal_type
                logout_path_url = c.path_url
            end
        end

        portal_log("INFO", "delete_profile: Memicu logout terisolasi di background untuk " .. logical)
        local logout_cmd = string.format(
            "env LOGICAL=%s DEVICE=%s PORTAL_TYPE=%s PATH_URL=%s PORTAL_URL=%s IPC=%s sh %s/logout_executor.sh >/dev/null 2>&1 &",
            util.shellquote(logical),
            util.shellquote(profile_data.device),
            util.shellquote(profile_data.portal_type),
            util.shellquote(logout_path_url),
            util.shellquote(profile_data.portal_url or ""),
            util.shellquote(profile_data.ipc or ""),
            util.shellquote(SCRIPT_DIR)
        )
        os.execute(logout_cmd)
    end

    local uci_section = resolve_uci_section(logical, profile_data.device or "")
    if uci_section then
        local original_mac = sys.exec(string.format("uci -q get %s.original_macaddr 2>/dev/null", util.shellquote(uci_section))):gsub("\n", "")
        local current_mac = sys.exec(string.format("uci -q get %s.macaddr 2>/dev/null", util.shellquote(uci_section))):gsub("\n", "")
        
        if original_mac ~= "" and original_mac ~= current_mac then
            portal_log("INFO", "delete_profile: Memicu revert MAC otomatis di background untuk " .. logical)
            local revert_cmd = string.format(
                "sh %s/mac_apply.sh revert %s %s %s >/dev/null 2>&1 &",
                util.shellquote(SCRIPT_DIR),
                util.shellquote(uci_section),
                util.shellquote(profile_data.device or logical),
                util.shellquote(original_mac)
            )
            os.execute(revert_cmd)

            portal_log("INFO", "delete_profile: Merestart interface spesifik setelah revert MAC: " .. logical)
            sys.call("NETWORK_SH_EXEC=1 sh " .. SCRIPT_DIR .. "/network.sh restart_interface_specific " .. util.shellquote(logical) .. " >/dev/null 2>&1")
        end
    end

    portal_log("INFO", "delete_profile: Menghapus file profil: " .. file_path)
    os.remove(file_path)

    local state_file = STATE_DIR .. "/" .. logical .. ".state"
    portal_log("INFO", "delete_profile: Menghapus file state: " .. state_file)
    os.remove(state_file)

    local session_file = "/etc/portal/portal_session_" .. logical
    portal_log("INFO", "delete_profile: Menghapus file session: " .. session_file)
    os.remove(session_file)

    portal_log("INFO", "delete_profile: Membersihkan file temporary di /tmp/ untuk " .. logical)
    os.execute(string.format("rm -f /tmp/%s_* >/dev/null 2>&1", logical))

    local autologin_lifecycle_lock = "/tmp/portal_autologin_" .. logical .. ".lifecycle.lock"
    local autologin_exec_lock = "/tmp/portal_autologin_" .. logical .. ".exec.lock"

    local autologin_lifecycle_pid_file = autologin_lifecycle_lock .. "/pid"
    if fs.access(autologin_lifecycle_pid_file) then
        local f_pid = io.open(autologin_lifecycle_pid_file, "r")
        if f_pid then
            local child_pid = f_pid:read("*l")
            f_pid:close()
            if child_pid and child_pid:match("^%d+$") then
                portal_log("INFO", "delete_profile: Menghentikan child autologin PID " .. child_pid .. " untuk " .. logical)
                os.execute(string.format("kill -9 %s >/dev/null 2>&1", child_pid))
            end
        end
    end

    local autologin_exec_pid_file = autologin_exec_lock .. "/pid"
    if fs.access(autologin_exec_pid_file) then
        local f_exec_pid = io.open(autologin_exec_pid_file, "r")
        if f_exec_pid then
            local exec_pid = f_exec_pid:read("*l")
            f_exec_pid:close()
            if exec_pid and exec_pid:match("^%d+$") then
                portal_log("INFO", "delete_profile: Menghentikan exec process PID " .. exec_pid .. " untuk " .. logical)
                os.execute(string.format("kill -9 %s >/dev/null 2>&1", exec_pid))
            end
        end
    end

    portal_log("INFO", "delete_profile: Membersihkan lock autologin: " .. autologin_lifecycle_lock .. ", " .. autologin_exec_lock)
    os.execute(string.format(
        "rm -rf %s %s >/dev/null 2>&1",
        util.shellquote(autologin_lifecycle_lock),
        util.shellquote(autologin_exec_lock)
    ))

    portal_log("INFO", "delete_profile: Penghapusan profil " .. logical .. " berhasil")
    http.write('{"status":"success","message":"Profil berhasil dihapus"}')
end

function M.execute_login_api()
    http.prepare_content("application/json")
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "execute_login - Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end

    local raw_data = http.content()
    local ok, data = pcall(json.parse, raw_data)
    if not ok or not data then
        portal_log("ERROR", "execute_login - Gagal parse JSON payload")
        http.write('{"status":"error","message":"Invalid JSON payload"}')
        return
    end

    if not data.logical or not data.device or not data.username or not data.password then
        portal_log("ERROR", "execute_login - Parameter kurang")
        http.write('{"status":"error","message":"Missing required parameters"}')
        return
    end

    portal_log("INFO", "execute_login - Memulai proses login untuk " .. data.logical)

    local resolved_contract = nil

    if data.url and data.url ~= "" then
        resolved_contract = contract_lookup_url(data.url)
    end

    if not resolved_contract and data.portal_type and data.path_url then
        local ident = contract_lookup_identity(data.portal_type, data.path_url)
        if ident then
            resolved_contract = {
                portal_type = data.portal_type,
                path_url = data.path_url,
                landing = ident.landing,
                executor = ident.executor
            }
        end
    end

    if not resolved_contract then
        portal_log("ERROR", "execute_login - Portal tidak resmi atau path_url tidak valid")
        write_json_response({status = "error", message = "Portal tidak resmi atau path_url tidak valid"})
        return
    end

    data.portal_type = resolved_contract.portal_type
    data.path_url = resolved_contract.path_url

    local executor_script = SCRIPT_DIR .. "/" .. resolved_contract.executor
	
	
    if not fs.access(executor_script, "x") then
        portal_log("ERROR", "execute_login - Executor script tidak ditemukan: " .. executor_script)
        http.write('{"status":"error","message":"Executor script not found"}')
        return
    end

    local env = {
        "LOGICAL=" .. util.shellquote(data.logical),
        "DEVICE=" .. util.shellquote(data.device),
        "USERNAME=" .. util.shellquote(data.username),
        "PASSWORD=" .. util.shellquote(data.password),
        "PORTAL_TYPE=" .. util.shellquote(data.portal_type or ""),
        "PATH_URL=" .. util.shellquote(data.path_url or ""),
        "PORTAL_URL=" .. util.shellquote(data.url or ""),
        "GW_ID=" .. util.shellquote(data.gw_id or ""),
        "CLIENT_MAC=" .. util.shellquote(data.client_mac or ""),
        "WLAN=" .. util.shellquote(data.wlan or ""),
        "SESSIONID=" .. util.shellquote(data.sessionid or ""),
        "IPC=" .. util.shellquote(data.ipc or ""),
        "SSID=" .. util.shellquote("wifi.id")
    }

    local cmd = "env " .. table.concat(env, " ") .. " " .. util.shellquote(executor_script)
    portal_log("INFO", "execute_login - Menjalankan: " .. cmd)

    local f = io.popen(cmd, "r")
    if not f then
        portal_log("ERROR", "execute_login - Gagal menjalankan executor script")
        http.write('{"status":"error","message":"Backend execution failed"}')
        return
    end

    local output = f:read("*a")
    local success, _, code = f:close()
    
    local clean_msg = output:gsub("^%s*(.-)%s*$", "%1")

    if (success and code == 0) or clean_msg:match("Berhasil") or clean_msg:match("Sukses") then
        portal_log("INFO", "execute_login - Berhasil: " .. clean_msg)
        write_json_response({
            status = "success",
            message = clean_msg,
            portal_type = data.portal_type,
            path_url = data.path_url
        })
    else
        local err_msg = clean_msg ~= "" and clean_msg or "Login gagal tanpa pesan"
        portal_log("ERROR", "execute_login - Gagal: " .. err_msg)
        write_json_response({
            status = "error",
            message = err_msg,
            portal_type = data.portal_type,
            path_url = data.path_url
        })
    end
end

function M.execute_logout_api()
    http.prepare_content("application/json")
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "execute_logout - Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end

    local raw_data = http.content()
    local ok, data = pcall(json.parse, raw_data)
    if not ok or not data then
        portal_log("ERROR", "execute_logout - Gagal parse JSON payload")
        http.write('{"status":"error","message":"Invalid JSON payload"}')
        return
    end

    if not data.logical or not data.device or not data.portal_type then
        portal_log("ERROR", "execute_logout - Parameter kurang")
        http.write('{"status":"error","message":"Missing required parameters"}')
        return
    end

    portal_log("INFO", "execute_logout - Memulai proses logout untuk " .. data.logical)

    local executor_script = SCRIPT_DIR .. "/logout_executor.sh"

    if not fs.access(executor_script, "x") then
        portal_log("ERROR", "execute_logout - Executor script tidak ditemukan: " .. executor_script)
        http.write('{"status":"error","message":"Executor script not found"}')
        return
    end

    if not data.path_url or data.path_url == "" then
        local c = contract_lookup_url(data.url or "")
        if c then
            data.portal_type = c.portal_type
            data.path_url = c.path_url
        end
    end

    local env = {
        "LOGICAL=" .. util.shellquote(data.logical),
        "DEVICE=" .. util.shellquote(data.device),
        "PORTAL_TYPE=" .. util.shellquote(data.portal_type or ""),
        "PATH_URL=" .. util.shellquote(data.path_url or ""),
        "PORTAL_URL=" .. util.shellquote(data.url or ""),
        "IPC=" .. util.shellquote(data.ipc or "")
    }

    local cmd = "env " .. table.concat(env, " ") .. " " .. util.shellquote(executor_script)
    portal_log("INFO", "execute_logout - Menjalankan: " .. cmd)

    local f = io.popen(cmd, "r")
    if not f then
        portal_log("ERROR", "execute_logout - Gagal menjalankan executor script")
        http.write('{"status":"error","message":"Backend execution failed"}')
        return
    end

    local output = f:read("*a")
    local success, _, code = f:close()
    
    local clean_msg = output:gsub("^%s*(.-)%s*$", "%1")

    if (success and code == 0) or clean_msg:match("Berhasil") then
        portal_log("INFO", "execute_logout - Berhasil: " .. clean_msg)
        write_json_response({
            status = "success",
            message = clean_msg,
            portal_type = data.portal_type,
            path_url = data.path_url
        })
    else
        local err_msg = clean_msg ~= "" and clean_msg or "Logout gagal tanpa pesan"
        portal_log("ERROR", "execute_logout - Gagal: " .. err_msg)
        write_json_response({
            status = "error",
            message = err_msg,
            portal_type = data.portal_type,
            path_url = data.path_url
        })
    end
end

function M.autologin_status_api()
    http.prepare_content("application/json")
    
    local logical = http.formvalue("logical")
    if not logical or not logical:match("^[a-zA-Z0-9_.%-]+$") then
        portal_log("ERROR", "autologin_status: Logical name tidak valid")
        http.write('{"status":"error","message":"Invalid logical name"}')
        return
    end
    
    local state_file = "/etc/portal/state/" .. logical .. ".state"
    if not fs.access(state_file) then
        portal_log("INFO", "autologin_status: State file tidak ditemukan untuk " .. logical)
        http.write('{"status":"not_found","state":"unknown"}')
        return
    end
    
    local state_data = {}
    local f = io.open(state_file, "r")
    if f then
        for line in f:lines() do
            local key, value = line:match("^([^=]+)=(.*)$")
            if key and value then
                state_data[key] = value
            end
        end
        f:close()
    end
    
    portal_log("INFO", "autologin_status: State untuk " .. logical .. " = " .. (state_data.STATE or "unknown"))
    http.write(json.stringify({
        status = "success",
        logical = logical,
        state = state_data.STATE or "unknown",
        retry_count = tonumber(state_data.RETRY_COUNT) or 0,
        last_login = state_data.LAST_LOGIN or "",
        last_attempt = state_data.LAST_ATTEMPT or "",
        last_action = state_data.LAST_ACTION or "",
        last_result = state_data.LAST_RESULT or "",
        last_message = state_data.LAST_MESSAGE or ""
    }))
end

function M.autologin_reset_api()
    http.prepare_content("application/json")
    
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "autologin_reset: Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end
    
    local logical = http.formvalue("logical")
    if not logical or not logical:match("^[a-zA-Z0-9_.%-]+$") then
        portal_log("ERROR", "autologin_reset: Logical name tidak valid")
        http.write('{"status":"error","message":"Invalid logical name"}')
        return
    end
    
    local state_file = "/etc/portal/state/" .. logical .. ".state"
    if not fs.access(state_file) then
        portal_log("WARN", "autologin_reset: State file tidak ditemukan untuk " .. logical)
        http.write('{"status":"error","message":"State file not found"}')
        return
    end
    
    local f = io.open(state_file, "r")
    local state_data = {}
    if f then
        for line in f:lines() do
            local key, value = line:match("^([^=]+)=(.*)$")
            if key and value then
                state_data[key] = value
            end
        end
        f:close()
    end
    
    state_data.RETRY_COUNT = "0"
    state_data.STATE = "first_login"
    state_data.LAST_ACTION = "reset_counter"
    state_data.LAST_RESULT = "success"
    state_data.LAST_MESSAGE = "Counter retry direset ke 0"
    state_data.LAST_ATTEMPT = os.date("%H:%M:%S %d-%m-%Y")
    
    local f = io.open(state_file, "w")
    if f then
        for key, value in pairs(state_data) do
            f:write(key .. "=" .. value .. "\n")
        end
        f:close()
        portal_log("INFO", "autologin_reset: Counter reset untuk " .. logical)
        http.write('{"status":"success","message":"Counter reset berhasil"}')
    else
        portal_log("ERROR", "autologin_reset: Gagal tulis state file")
        http.write('{"status":"error","message":"Failed to write state file"}')
    end
end

function M.autologin_start_api()
    http.prepare_content("application/json")
    
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "autologin_start: Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end
    
    portal_log("INFO", "autologin_start: Memulai daemon auto-login")
    local result = sys.call("/etc/init.d/portal_autologin start >/dev/null 2>&1")
    
    if result == 0 then
        http.write('{"status":"success","message":"Daemon started"}')
    else
        http.write('{"status":"error","message":"Failed to start daemon"}')
    end
end

function M.autologin_stop_api()
    http.prepare_content("application/json")
    
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        portal_log("ERROR", "autologin_stop: Method tidak diizinkan")
        http.write('{"status":"error","message":"Method not allowed"}')
        return
    end
    
    portal_log("INFO", "autologin_stop: Menghentikan daemon auto-login")
    local result = sys.call("/etc/init.d/portal_autologin stop >/dev/null 2>&1")
    
    if result == 0 then
        http.write('{"status":"success","message":"Daemon stopped"}')
    else
        http.write('{"status":"error","message":"Failed to stop daemon"}')
    end
end

return M