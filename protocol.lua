-------------------------------------------------------------------
-- OpenRGB SDK protocol helpers (v5 compatible)
--
-- Binary TCP on port 6742.
-- Header: 16 bytes, little-endian
--   "ORGB" (4 bytes magic)
--   dev_idx (u32 LE)
--   pkt_id  (u32 LE)
--   pkt_size(u32 LE)
-------------------------------------------------------------------
local M = {}

-- Packet IDs
M.REQUEST_CONTROLLER_COUNT    = 0
M.REQUEST_CONTROLLER_DATA     = 1
M.RGBCONTROLLER_RESIZEZONE    = 1000
M.RGBCONTROLLER_UPDATELEDS    = 1050
M.RGBCONTROLLER_UPDATEZONELEDS= 1051
M.RGBCONTROLLER_UPDATESINGLELED=1052
M.RGBCONTROLLER_SETCUSTOMMODE = 1100
M.SET_CLIENT_NAME             = 50
M.DEVICE_LIST_UPDATED         = 100
M.REQUEST_PROTOCOL_VERSION    = 40
M.REQUEST_RESCAN_DEVICES      = 140

-- OpenRGB device types → Light device type strings
local DEVICE_TYPE_MAP = {
    [0] = "motherboard",
    [1] = "dram",
    [2] = "gpu",
    [3] = "cooler",
    [4] = "ledstrip",
    [5] = "keyboard",
    [6] = "mouse",
    [7] = "mousemat",
    [8] = "headset",
    [9] = "headsetstand",
    [10] = "gamepad",
    [11] = "light",
    [12] = "speaker",
    [13] = "virtual",
    [14] = "storage",
    [15] = "case",
    [16] = "microphone",
    [17] = "accessory",
    [18] = "keypad",
    [19] = "laptop",
    [20] = "monitor",
}

-------------------------------------------------------------------
-- Low-level packing helpers (little-endian)
-------------------------------------------------------------------

function M.pack_u16(val)
    return string.char(val % 256, math.floor(val / 256) % 256)
end

function M.pack_u32(val)
    return string.char(
        val % 256,
        math.floor(val / 256) % 256,
        math.floor(val / 65536) % 256,
        math.floor(val / 16777216) % 256
    )
end

function M.unpack_u16(data, offset)
    offset = offset or 1
    local b1, b2 = string.byte(data, offset, offset + 1)
    return b1 + b2 * 256
end

function M.unpack_u32(data, offset)
    offset = offset or 1
    local b1, b2, b3, b4 = string.byte(data, offset, offset + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

function M.unpack_i32(data, offset)
    local val = M.unpack_u32(data, offset)
    if val >= 0x80000000 then
        val = val - 0x100000000
    end
    return val
end

-------------------------------------------------------------------
-- String helpers (OpenRGB strings are u16-len prefixed, NUL-terminated)
-------------------------------------------------------------------

function M.unpack_string(data, offset)
    offset = offset or 1
    local str_len = M.unpack_u16(data, offset)
    offset = offset + 2
    if str_len == 0 then
        return "", offset
    end
    -- str_len includes NUL terminator
    local str = string.sub(data, offset, offset + str_len - 2)
    return str, offset + str_len
end

function M.pack_string(str)
    local with_nul = str .. "\0"
    return M.pack_u16(#with_nul) .. with_nul
end

-------------------------------------------------------------------
-- Packet construction
-------------------------------------------------------------------

function M.build_header(dev_idx, pkt_id, pkt_size)
    return "ORGB" .. M.pack_u32(dev_idx) .. M.pack_u32(pkt_id) .. M.pack_u32(pkt_size)
end

function M.build_packet(dev_idx, pkt_id, body)
    body = body or ""
    return M.build_header(dev_idx, pkt_id, #body) .. body
end

-------------------------------------------------------------------
-- Packet parsing
-------------------------------------------------------------------

function M.parse_header(data)
    if #data < 16 then return nil, "Header too short" end
    local magic = string.sub(data, 1, 4)
    if magic ~= "ORGB" then return nil, "Invalid magic: " .. magic end
    return {
        dev_idx  = M.unpack_u32(data, 5),
        pkt_id   = M.unpack_u32(data, 9),
        pkt_size = M.unpack_u32(data, 13),
    }
end

-------------------------------------------------------------------
-- Protocol negotiation
-------------------------------------------------------------------

function M.build_request_protocol_version(client_version)
    client_version = client_version or 4
    return M.build_packet(0, M.REQUEST_PROTOCOL_VERSION, M.pack_u32(client_version))
end

function M.build_set_client_name(name)
    return M.build_packet(0, M.SET_CLIENT_NAME, name .. "\0")
end

function M.build_request_controller_count()
    return M.build_packet(0, M.REQUEST_CONTROLLER_COUNT, "")
end

function M.build_request_controller_data(dev_idx, protocol_version)
    protocol_version = tonumber(protocol_version) or 0
    if protocol_version <= 0 then
        -- Protocol v0 uses an empty request body.
        return M.build_packet(dev_idx, M.REQUEST_CONTROLLER_DATA, "")
    end
    return M.build_packet(dev_idx, M.REQUEST_CONTROLLER_DATA, M.pack_u32(protocol_version))
end

-------------------------------------------------------------------
-- UpdateLEDs packet
-------------------------------------------------------------------

function M.build_update_leds(dev_idx, colors)
    -- colors: flat array { r, g, b, r, g, b, ... }
    local num_colors = math.floor(#colors / 3)
    -- Body: data_size (u32) + num_colors (u16) + colors (4 bytes each: r, g, b, pad)
    -- OpenRGB expects data_size to be the size of the WHOLE body, including
    -- the data_size field itself.
    local color_data_size = num_colors * 4
    local data_size = 4 + 2 + color_data_size

    local parts = { M.pack_u32(data_size), M.pack_u16(num_colors) }
    for i = 0, num_colors - 1 do
        local base = i * 3 + 1
        local r = colors[base] or 0
        local g = colors[base + 1] or 0
        local b = colors[base + 2] or 0
        parts[#parts + 1] = string.char(r, g, b, 0)
    end

    local body = table.concat(parts)
    return M.build_packet(dev_idx, M.RGBCONTROLLER_UPDATELEDS, body)
end

-------------------------------------------------------------------
-- ResizeZone packet
-------------------------------------------------------------------

function M.build_resize_zone(dev_idx, zone_idx, new_size)
    local body = M.pack_u32(zone_idx) .. M.pack_u32(new_size)
    return M.build_packet(dev_idx, M.RGBCONTROLLER_RESIZEZONE, body)
end

-------------------------------------------------------------------
-- Controller data parsing (minimal: name, type, num_leds, zones)
-------------------------------------------------------------------

function M.parse_controller_data(data, protocol_version)
    protocol_version = tonumber(protocol_version) or 0

    local offset = 1
    local data_len = #data
    local result = {}

    local function need(bytes, label)
        if offset + bytes - 1 > data_len then
            error(
                string.format(
                    "Controller data truncated while reading %s (need %d bytes at offset %d, total %d)",
                    label or "field",
                    bytes,
                    offset,
                    data_len
                )
            )
        end
    end

    local function read_u16(label)
        need(2, label)
        local val = M.unpack_u16(data, offset)
        offset = offset + 2
        return val
    end

    local function read_u32(label)
        need(4, label)
        local val = M.unpack_u32(data, offset)
        offset = offset + 4
        return val
    end

    local function read_i32(label)
        need(4, label)
        local val = M.unpack_i32(data, offset)
        offset = offset + 4
        return val
    end

    local function skip(bytes, label)
        if bytes <= 0 then
            return
        end
        need(bytes, label)
        offset = offset + bytes
    end

    local function read_string(label)
        local str_len = read_u16((label or "string") .. "_len")
        if str_len == 0 then
            return ""
        end

        need(str_len, label)
        local s = string.sub(data, offset, offset + str_len - 1)
        offset = offset + str_len

        -- SDK strings include a trailing NUL if non-empty.
        local last = string.byte(s, -1)
        if last == 0 then
            s = string.sub(s, 1, -2)
        end
        return s
    end

    -- data_size (u32) — total size of the remaining payload
    result.data_size = read_u32("data_size")

    -- type (i32)
    local dev_type = read_i32("device_type")
    result.device_type = DEVICE_TYPE_MAP[dev_type] or "unknown"
    result.device_type_id = dev_type

    -- controller strings
    result.name = read_string("name")
    if protocol_version >= 1 then
        result.vendor = read_string("vendor")
    else
        result.vendor = ""
    end
    result.description = read_string("description")
    result.version = read_string("version")
    result.serial = read_string("serial")
    result.location = read_string("location")

    -- modes
    local num_modes = read_u16("num_modes")
    result.active_mode = read_i32("active_mode")
    for _ = 1, num_modes do
        -- mode_name
        read_string("mode_name")
        -- mode_value, mode_flags, speed_min, speed_max
        skip(4 * 4, "mode_base_fields")
        -- brightness min/max were added in protocol v3.
        if protocol_version >= 3 then
            skip(4 * 2, "mode_brightness_range")
        end
        -- colors_min, colors_max, speed
        skip(4 * 3, "mode_color_and_speed")
        -- mode_brightness was added in protocol v3.
        if protocol_version >= 3 then
            skip(4, "mode_brightness")
        end
        -- direction, color_mode
        skip(4 * 2, "mode_direction_and_color_mode")
        -- mode colors
        local mode_num_colors = read_u16("mode_num_colors")
        skip(mode_num_colors * 4, "mode_colors")
    end

    -- zones
    local num_zones = read_u16("num_zones")
    result.zones = {}
    for z = 1, num_zones do
        local zone = {}
        zone.name = read_string("zone_name")
        zone.zone_type = read_i32("zone_type")
        zone.leds_min = read_u32("zone_leds_min")
        zone.leds_max = read_u32("zone_leds_max")
        zone.leds_count = read_u32("zone_leds_count")

        -- zone_matrix_len = 0 OR (height,width,map) total bytes
        local zone_matrix_len = read_u16("zone_matrix_len")
        zone.matrix_height = 0
        zone.matrix_width = 0
        zone.matrix_map = nil
        if zone_matrix_len > 0 then
            if zone_matrix_len < 8 then
                error("Invalid zone_matrix_len: " .. tostring(zone_matrix_len))
            end
            if ((zone_matrix_len - 8) % 4) ~= 0 then
                error("Invalid zone_matrix_len payload: " .. tostring(zone_matrix_len))
            end
            zone.matrix_height = read_u32("zone_matrix_height")
            zone.matrix_width = read_u32("zone_matrix_width")
            local matrix_cells = math.floor((zone_matrix_len - 8) / 4)
            zone.matrix_map = {}
            for mi = 1, matrix_cells do
                local v = read_u32("zone_matrix_cell")
                -- OpenRGB uses 0xFFFFFFFF for empty slots.
                zone.matrix_map[mi] = (v == 0xFFFFFFFF) and -1 or v
            end
        end

        -- protocol v4+: segments list for this zone
        if protocol_version >= 4 then
            local num_segments = read_u16("num_segments")
            zone.segments = {}
            for s = 1, num_segments do
                local seg = {}
                seg.name = read_string("segment_name")
                seg.segment_type = read_i32("segment_type")
                seg.start_idx = read_u32("segment_start_idx")
                seg.leds_count = read_u32("segment_leds_count")
                zone.segments[s] = seg
            end
        end

        -- protocol v5+: per-zone flags
        if protocol_version >= 5 then
            zone.zone_flags = read_u32("zone_flags")
        end

        result.zones[z] = zone
    end

    -- LED list
    local num_leds = read_u16("num_leds")
    result.num_leds = num_leds
    for _ = 1, num_leds do
        read_string("led_name")
        skip(4, "led_value")
    end

    -- color list
    local num_colors = read_u16("num_colors")
    result.num_colors = num_colors
    skip(num_colors * 4, "controller_colors")

    -- protocol v5+: alt LED names + controller flags
    if protocol_version >= 5 then
        local num_led_alt_names = read_u16("num_led_alt_names")
        for _ = 1, num_led_alt_names do
            read_string("led_alt_name")
        end
        result.flags = read_u32("controller_flags")
    end

    result.protocol_version = protocol_version
    return result
end

-------------------------------------------------------------------
-- SetCustomMode packet (sets device to "direct" control mode)
-------------------------------------------------------------------

function M.build_set_custom_mode(dev_idx)
    return M.build_packet(dev_idx, M.RGBCONTROLLER_SETCUSTOMMODE, "")
end

function M.build_request_rescan_devices()
    return M.build_packet(0, M.REQUEST_RESCAN_DEVICES, "")
end

return M
