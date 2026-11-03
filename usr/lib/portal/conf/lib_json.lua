local ok, json = pcall(require, "luci.jsonc")
if not ok then
    json = require "luci.json"
end

local function log(level, message)
    local safe = tostring(message or ""):gsub("'", "'\\''")
    os.execute(string.format(
        "logger -t portal_json '[%s] lib_json.lua: %s' >/dev/null 2>&1",
        level,
        safe
    ))
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_file(path, data)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function pretty_json(val, indent)
    indent = indent or 0
    local t = type(val)
    local pad = string.rep("    ", indent)
    local pad_inner = string.rep("    ", indent + 1)

    if t == "table" then
        local is_array = false
        local count = 0
        for _ in pairs(val) do count = count + 1 end
        if count == #val and #val > 0 then
            is_array = true
        end

        local parts = {}
        if is_array then
            for i, v in ipairs(val) do
                table.insert(parts, pad_inner .. pretty_json(v, indent + 1))
            end
            if #parts == 0 then return "[]" end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
        else
            local keys = {}
            for k in pairs(val) do table.insert(keys, k) end
            table.sort(keys)
            
            for _, k in ipairs(keys) do
                local v = val[k]
                local key_str = string.format("%q", k):gsub("\\/", "/")
                table.insert(parts, string.format("%s%s: %s", pad_inner, key_str, pretty_json(v, indent + 1)))
            end
            if #parts == 0 then return "{}" end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
        end
    elseif t == "string" then
        return string.format("%q", val):gsub("\\/", "/")
    elseif t == "number" then
        return tostring(val)
    elseif t == "boolean" then
        return tostring(val)
    elseif val == nil then
        return "null"
    else
        return string.format("%q", tostring(val))
    end
end

local function main()
    if #arg < 3 then
        log("ERROR", "Usage: lua lib_json.lua <json_file> <key1> <value1> [key2 value2 ...]")
        return 2
    end

    local file = arg[1]
    log("INFO", "Mulai update JSON atomik: " .. file)

    local original = read_file(file)
    if not original then
        log("ERROR", "Gagal membaca file: " .. file)
        return 1
    end

    local ok_parse, data = pcall(json.parse, original)
    if not ok_parse or type(data) ~= "table" then
        log("ERROR", "JSON awal tidak valid: " .. file)
        return 1
    end

    local keys = {}
    for i = 2, #arg, 2 do
        local key = arg[i]
        local value = arg[i + 1]
        if key and value ~= nil then
            data[key] = value
            table.insert(keys, key)
        end
    end

    if #keys == 0 then
        log("WARN", "Tidak ada key valid untuk diupdate")
        return 0
    end

    local new_content = pretty_json(data) .. "\n"
    local tmp = file .. ".tmp"
    local bak = file .. ".bak"

    if not write_file(bak, original) then
        log("ERROR", "Gagal membuat backup: " .. bak)
        return 1
    end

    if not write_file(tmp, new_content) then
        log("ERROR", "Gagal menulis file temporary: " .. tmp)
        os.remove(bak)
        return 1
    end

    local validate_raw = read_file(tmp)
    local ok_validate, validate_data = pcall(json.parse, validate_raw or "")
    if not ok_validate or type(validate_data) ~= "table" then
        log("ERROR", "Validasi JSON temporary gagal, rollback: " .. file)
        os.remove(tmp)
        os.remove(bak)
        return 1
    end

    local ok_rename = os.rename(tmp, file)
    if not ok_rename then
        log("ERROR", "Gagal rename file temporary ke file asli: " .. file)
        os.remove(tmp)
        os.remove(bak)
        return 1
    end

    os.remove(bak)
    log("INFO", "Update JSON (Pretty Print) berhasil untuk keys: " .. table.concat(keys, ","))
    return 0
end

os.exit(main())