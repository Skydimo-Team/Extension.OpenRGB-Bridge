-------------------------------------------------------------------
-- OpenRGB Bridge Extension
--
-- Connects to a local OpenRGB server via TCP and bridges its devices
-- into Light as virtual controllers. Rendered frames are forwarded
-- to OpenRGB via the UpdateLEDs packet.
--
-- When the extension starts it automatically launches a bundled
-- OpenRGB instance in server mode, connects to it, and syncs
-- devices. Manual scan triggers an OpenRGB hardware rescan.
-------------------------------------------------------------------
local proto = require("protocol")
local tcp = ext.net.tcp

local OPENRGB_HOST = "127.0.0.1"
local OPENRGB_PORT = 6742
local CONNECT_TIMEOUT_MS = 3000
local RECV_TIMEOUT_MS = 5000
local RESCAN_TIMEOUT_MS = 30000
local CLIENT_NAME = "Skydimo"
local PROTOCOL_VERSION = 5

-- State
local conn = nil                -- TCP connection handle
local server_protocol = 0       -- Negotiated protocol version
local devices = {}              -- controller_port -> { dev_idx, info, device_path }
local registered_ports = {}     -- Ordered list of registered port names
local pending_device_list_update = false
local openrgb_process = nil     -- Process handle for the bundled OpenRGB instance
local sync_devices              -- Forward declaration (used by connect_and_sync)
local disconnect                -- Forward declaration (used by connect_and_sync)

local disabled_devices = {}     -- set of device identity strings (vendor|name|serial)
local DISABLED_FILE = "disabled_devices.json"

local function load_disabled_devices()
    local path = ext.data_dir .. "/" .. DISABLED_FILE
    local f = io.open(path, "r")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    local ok, list = pcall(ext.json_decode, raw)
    if ok and type(list) == "table" then
        disabled_devices = {}
        for _, port in ipairs(list) do
            if type(port) == "string" then
                disabled_devices[port] = true
            end
        end
    end
end

local function save_disabled_devices()
    local list = {}
    for port in pairs(disabled_devices) do
        list[#list + 1] = port
    end
    table.sort(list)
    local path = ext.data_dir .. "/" .. DISABLED_FILE
    local f = io.open(path, "w")
    if f then
        f:write(ext.json_encode(list))
        f:close()
    end
end

-------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------

local function send_packet(packet)
    if not conn then return false end
    local ok, err = pcall(tcp.write_all, conn, packet)
    if not ok then
        ext.error("TCP write failed: " .. tostring(err))
        return false
    end
    return true
end

local function recv_header()
    if not conn then return nil end
    local ok, data = pcall(tcp.read_exact, conn, 16, RECV_TIMEOUT_MS)
    if not ok then return nil end
    return proto.parse_header(data)
end

local function recv_body(size)
    if not conn then return nil end
    if size == 0 then return "" end
    local ok, data = pcall(tcp.read_exact, conn, size, RECV_TIMEOUT_MS)
    if not ok then return nil end
    return data
end

local function send_and_recv(packet, expected_pkt_id, expected_dev_idx)
    if not send_packet(packet) then return nil, nil end

    -- OpenRGB may send async notifications (e.g. DEVICE_LIST_UPDATED) while
    -- we are waiting for a command reply. Keep consuming until we see the
    -- expected response, or give up after a bounded number of packets.
    for _ = 1, 16 do
        local header = recv_header()
        if not header then return nil, nil end
        local body = recv_body(header.pkt_size)
        if body == nil then return nil, nil end

        if header.pkt_id == proto.DEVICE_LIST_UPDATED then
            pending_device_list_update = true
            ext.log("OpenRGB device list update notification received")
        elseif (expected_pkt_id == nil or header.pkt_id == expected_pkt_id)
            and (expected_dev_idx == nil or header.dev_idx == expected_dev_idx)
        then
            return header, body
        else
            ext.warn(
                "Unexpected OpenRGB packet while waiting for response: pkt_id="
                    .. tostring(header.pkt_id)
                    .. ", dev_idx="
                    .. tostring(header.dev_idx)
            )
        end
    end

    ext.warn("OpenRGB response wait exceeded packet limit")
    return nil, nil
end

-------------------------------------------------------------------
-- Process management
-------------------------------------------------------------------

local function launch_openrgb()
    local exe_path = ext.data_dir .. "/OpenRGB/OpenRGB.exe"
    local work_dir = ext.data_dir .. "/OpenRGB"

    ext.log("Launching OpenRGB: " .. exe_path)
    local ok, handle = pcall(ext.spawn_process, exe_path, {
        "--server",
        "--noautoconnect",
        "--server-host", OPENRGB_HOST,
        "--server-port", tostring(OPENRGB_PORT),
    }, {
        hidden = true,
        working_dir = work_dir,
    })

    if not ok then
        ext.error("Failed to launch OpenRGB: " .. tostring(handle))
        return false
    end

    openrgb_process = handle
    ext.log("OpenRGB process spawned (handle=" .. tostring(handle) .. ")")
    return true
end

local function is_openrgb_alive()
    if not openrgb_process then return false end
    local ok, alive = pcall(ext.is_process_alive, openrgb_process)
    return ok and alive
end

local function kill_openrgb()
    if openrgb_process then
        ext.log("Killing OpenRGB process")
        pcall(ext.kill_process, openrgb_process)
        openrgb_process = nil
    end
end

local function wait_for_openrgb_server(max_attempts, delay_ms)
    max_attempts = max_attempts or 30
    delay_ms = delay_ms or 1000

    ext.notify_persistent("openrgb-startup", "OpenRGB", "Waiting for OpenRGB to start...")

    for attempt = 1, max_attempts do
        -- Check if the process is still alive
        if not is_openrgb_alive() then
            ext.dismiss_persistent("openrgb-startup")
            ext.error("OpenRGB process died before server became available")
            return false
        end

        -- Try to connect
        local ok, handle = pcall(tcp.connect, {
            host = OPENRGB_HOST,
            port = OPENRGB_PORT,
            connect_timeout_ms = 500,
            no_delay = true,
        })
        if ok then
            -- Server is accepting connections, close this test connection
            pcall(tcp.close, handle)
            ext.dismiss_persistent("openrgb-startup")
            ext.log("OpenRGB server ready after " .. attempt .. " attempt(s)")
            return true
        end

        -- Update notification with elapsed time
        local elapsed_s = attempt
        ext.notify_persistent("openrgb-startup", "OpenRGB",
            "Waiting for OpenRGB to start... " .. elapsed_s .. "s")

        ext.sleep(delay_ms)
    end

    ext.dismiss_persistent("openrgb-startup")
    ext.warn("OpenRGB server did not become available after " .. max_attempts .. " attempts")
    return false
end

-------------------------------------------------------------------
-- Connection & negotiation
-------------------------------------------------------------------

local function negotiate_protocol()
    local pkt = proto.build_request_protocol_version(PROTOCOL_VERSION)
    local header, body = send_and_recv(pkt, proto.REQUEST_PROTOCOL_VERSION, 0)
    if not header or not body then
        -- Old servers (protocol v0) may not reply to protocol negotiation.
        -- Fall back so we can still attempt controller data requests.
        ext.warn("Protocol negotiation failed, fallback to protocol v0")
        server_protocol = 0
        return true
    end

    local server_max_protocol = proto.unpack_u32(body, 1) or 0
    -- Request/parse using the highest protocol both sides support.
    server_protocol = math.min(server_max_protocol, PROTOCOL_VERSION)

    ext.log(
        "OpenRGB server protocol version: "
            .. tostring(server_max_protocol)
            .. ", using: "
            .. tostring(server_protocol)
    )
    return true
end

local function set_client_name()
    local pkt = proto.build_set_client_name(CLIENT_NAME)
    send_packet(pkt)
    -- SET_CLIENT_NAME has no response
end

local function get_controller_count()
    local pkt = proto.build_request_controller_count()
    local header, body = send_and_recv(pkt, proto.REQUEST_CONTROLLER_COUNT, 0)
    if not header or not body then return 0 end
    return proto.unpack_u32(body, 1)
end

local function get_controller_data(dev_idx)
    local pkt = proto.build_request_controller_data(dev_idx, server_protocol)
    local header, body = send_and_recv(pkt, proto.REQUEST_CONTROLLER_DATA, dev_idx)
    if not header or not body then return nil end
    local ok, result = pcall(proto.parse_controller_data, body, server_protocol)
    if not ok then
        ext.warn("Failed to parse controller data for device " .. dev_idx .. ": " .. tostring(result))
        return nil
    end
    return result
end

--- Establish TCP connection, negotiate protocol, and sync devices.
local function connect_and_sync()
    ext.notify_persistent("openrgb-connect", "OpenRGB", "Connecting to " .. OPENRGB_HOST .. ":" .. OPENRGB_PORT .. "...")

    local ok, result = pcall(tcp.connect, {
        host = OPENRGB_HOST,
        port = OPENRGB_PORT,
        connect_timeout_ms = CONNECT_TIMEOUT_MS,
        read_timeout_ms = RECV_TIMEOUT_MS,
        write_timeout_ms = RECV_TIMEOUT_MS,
        no_delay = true,
    })
    ext.dismiss_persistent("openrgb-connect")

    if not ok then
        ext.notify("OpenRGB", "Server not available at " .. OPENRGB_HOST .. ":" .. OPENRGB_PORT, "warning")
        return false
    end

    conn = result
    ext.log("Connected to OpenRGB at " .. OPENRGB_HOST .. ":" .. OPENRGB_PORT)

    -- Negotiate protocol
    if not negotiate_protocol() then
        ext.notify("OpenRGB", "Protocol negotiation failed", "error")
        disconnect()
        return false
    end

    -- Set client name
    set_client_name()

    -- Sync devices
    local sync_ok, sync_err = pcall(sync_devices)
    if not sync_ok then
        ext.notify("OpenRGB", "Device sync failed: " .. tostring(sync_err), "error")
        disconnect()
        return false
    end

    pcall(send_connection_status)
    return true
end

local function make_controller_port(dev_idx, info)
    local identifier = info.serial
    if not identifier or identifier == "" then
        identifier = info.location
    end
    if not identifier or identifier == "" then
        identifier = "dev" .. dev_idx
    end
    return "openrgb://" .. OPENRGB_HOST .. ":" .. OPENRGB_PORT .. "/" .. identifier
end

--- Build a stable identity key for a device based on vendor + name + serial.
local function make_device_identity(info)
    local vendor = tostring(info.vendor or "")
    local name   = tostring(info.name or "")
    local serial = tostring(info.serial or "")
    return vendor .. "|" .. name .. "|" .. serial
end

local function strip_protocol_prefix(location)
    -- OpenRGB controllers prepend protocol prefixes like "HID: ", "USB: ", "I2C: "
    return location:match("^%a+:%s*(.+)") or location
end

local function make_device_path(dev_idx, info)
    if info.location ~= nil then
        local location = tostring(info.location)
        if location ~= "" then
            return strip_protocol_prefix(location)
        end
    end

    if info.serial ~= nil then
        local serial = tostring(info.serial)
        if serial ~= "" then
            return serial
        end
    end

    return "openrgb-device://" .. OPENRGB_HOST .. ":" .. OPENRGB_PORT .. "/dev/" .. tostring(dev_idx)
end

local function register_device(dev_idx, info)
    local controller_port = make_controller_port(dev_idx, info)
    local device_path = make_device_path(dev_idx, info)

    -- Skip registration if device is disabled (by identity: vendor|name|serial)
    local identity = make_device_identity(info)
    if disabled_devices[identity] then
        devices[controller_port] = {
            dev_idx = dev_idx,
            info = info,
            device_path = device_path,
            disabled = true,
        }
        ext.log("Skipping disabled device: " .. (info.name or "unknown") .. " [" .. identity .. "]")
        return
    end

    -- Build outputs from zones
    local outputs = {}
    for i, zone in ipairs(info.zones) do
        local output_type = "linear"
        if zone.zone_type == 0 then
            output_type = "single"
        elseif zone.zone_type == 2 then
            output_type = "matrix"
        end

        local leds_min = tonumber(zone.leds_min) or tonumber(zone.leds_count) or 0
        local leds_max = tonumber(zone.leds_max) or tonumber(zone.leds_count) or leds_min
        if leds_max < leds_min then
            leds_max = leds_min
        end
        local editable = leds_max > leds_min

        local matrix = nil
        if output_type == "matrix"
            and zone.matrix_width
            and zone.matrix_height
            and zone.matrix_width > 0
            and zone.matrix_height > 0
            and zone.matrix_map
        then
            matrix = {
                width = zone.matrix_width,
                height = zone.matrix_height,
                map = zone.matrix_map,
            }
        end

        local output_entry = {
            id       = "zone" .. (i - 1),
            name     = zone.name,
            output_type = output_type,
            matrix = matrix,
            editable = editable,
            min_total_leds = leds_min,
            max_total_leds = leds_max,
        }
        -- For editable zones, only pass leds_count when > 0;
        -- when 0, let core auto-assign half of max_total_leds.
        if not editable or (zone.leds_count and zone.leds_count > 0) then
            output_entry.leds_count = zone.leds_count
        end
        outputs[#outputs + 1] = output_entry
    end

    -- If no zones parsed, create a single default output
    if #outputs == 0 and info.num_leds > 0 then
        outputs[1] = {
            id       = "default",
            name     = "All LEDs",
            output_type = "linear",
            leds_count  = info.num_leds,
            editable = false,
            min_total_leds = info.num_leds,
            max_total_leds = info.num_leds,
        }
    end

    local device_info = {
        controller_port = controller_port,
        device_path = device_path,
        controller_id = "extension.openrgb_bridge",
        manufacturer = info.vendor or "OpenRGB",
        model       = info.name or "OpenRGB Device",
        serial_id   = info.serial or "",
        description = info.description or "",
        device_type = info.device_type or "light",
        outputs     = outputs,
    }

    ext.register_device(device_info)

    devices[controller_port] = {
        dev_idx = dev_idx,
        info    = info,
        device_path = device_path,
    }
    registered_ports[#registered_ports + 1] = controller_port

    ext.log("Registered device: " .. (info.name or "unknown") .. " (" .. controller_port .. ") -> " .. device_path)
end

local function recalc_device_num_leds(info)
    if not info or not info.zones then
        return
    end
    local total = 0
    for _, zone in ipairs(info.zones) do
        total = total + (tonumber(zone.leds_count) or 0)
    end
    info.num_leds = total
end

local function resize_zone_if_needed(device, zone_idx, desired_leds)
    local zones = device.info and device.info.zones
    if not zones then
        return 0
    end
    local zone = zones[zone_idx + 1]
    if not zone then
        return 0
    end

    local min_leds = tonumber(zone.leds_min) or tonumber(zone.leds_count) or 0
    local max_leds = tonumber(zone.leds_max) or tonumber(zone.leds_count) or desired_leds
    if max_leds < min_leds then
        max_leds = min_leds
    end

    local target = desired_leds
    if target < min_leds then
        ext.warn(
            "Requested zone size below minimum for dev="
                .. tostring(device.dev_idx)
                .. " zone="
                .. tostring(zone_idx)
                .. ": requested="
                .. tostring(target)
                .. ", min="
                .. tostring(min_leds)
        )
        target = min_leds
    elseif target > max_leds then
        ext.warn(
            "Requested zone size above maximum for dev="
                .. tostring(device.dev_idx)
                .. " zone="
                .. tostring(zone_idx)
                .. ": requested="
                .. tostring(target)
                .. ", max="
                .. tostring(max_leds)
        )
        target = max_leds
    end

    local current = tonumber(zone.leds_count) or 0
    if current == target then
        return current
    end

    local pkt = proto.build_resize_zone(device.dev_idx, zone_idx, target)
    if not send_packet(pkt) then
        ext.warn(
            "Failed to resize OpenRGB zone for dev="
                .. tostring(device.dev_idx)
                .. " zone="
                .. tostring(zone_idx)
                .. " target="
                .. tostring(target)
        )
        return current
    end

    zone.leds_count = target
    recalc_device_num_leds(device.info)
    ext.log(
        "Resized OpenRGB zone dev="
            .. tostring(device.dev_idx)
            .. " zone="
            .. tostring(zone_idx)
            .. " -> "
            .. tostring(target)
    )
    return target
end

local function same_matrix_map(a, b)
    if a == nil and b == nil then
        return true
    end
    if a == nil or b == nil then
        return false
    end
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

local function same_device_layout(lhs, rhs)
    local lhs_zones = lhs and lhs.zones or {}
    local rhs_zones = rhs and rhs.zones or {}
    if #lhs_zones ~= #rhs_zones then
        return false
    end

    for i = 1, #lhs_zones do
        local a = lhs_zones[i]
        local b = rhs_zones[i]
        if (a.zone_type or -1) ~= (b.zone_type or -1) then
            return false
        end
        if (a.leds_count or 0) ~= (b.leds_count or 0) then
            return false
        end
        if (a.name or "") ~= (b.name or "") then
            return false
        end
        if (a.matrix_width or 0) ~= (b.matrix_width or 0) then
            return false
        end
        if (a.matrix_height or 0) ~= (b.matrix_height or 0) then
            return false
        end
        if not same_matrix_map(a.matrix_map, b.matrix_map) then
            return false
        end
    end

    return (lhs.num_leds or 0) == (rhs.num_leds or 0)
end

local function remove_registered_device(controller_port)
    if not devices[controller_port] then
        return
    end
    pcall(ext.remove_extension_device, controller_port)
    devices[controller_port] = nil
    for idx, p in ipairs(registered_ports) do
        if p == controller_port then
            table.remove(registered_ports, idx)
            break
        end
    end
end

local function unregister_all_devices()
    local ports = {}
    for i, port in ipairs(registered_ports) do
        ports[i] = port
    end
    for _, port in ipairs(ports) do
        remove_registered_device(port)
    end
    devices = {}
    registered_ports = {}
end

-------------------------------------------------------------------
-- Page communication
-------------------------------------------------------------------

local ZONE_TYPE_NAMES = { [0] = "single", [1] = "linear", [2] = "matrix" }

local function send_connection_status()
    pcall(ext.page_emit, {
        type = "connection_status",
        connected = conn ~= nil,
    })
end

local function send_devices_snapshot()
    local device_list = {}
    for port, entry in pairs(devices) do
        local info = entry.info or {}
        local zones = {}
        for _, z in ipairs(info.zones or {}) do
            zones[#zones + 1] = {
                name = z.name or "",
                zone_type = ZONE_TYPE_NAMES[z.zone_type] or "unknown",
                zone_type_id = z.zone_type,
                leds_count = z.leds_count or 0,
                leds_min = z.leds_min or 0,
                leds_max = z.leds_max or 0,
                matrix_width = z.matrix_width,
                matrix_height = z.matrix_height,
            }
        end
        local identity = make_device_identity(info)
        device_list[#device_list + 1] = {
            controller_port = port,
            device_path = entry.device_path or "",
            dev_idx = entry.dev_idx or -1,
            name = info.name or "Unknown",
            vendor = info.vendor or "",
            description = info.description or "",
            serial = info.serial or "",
            location = info.location or "",
            device_type = info.device_type or "unknown",
            device_type_id = info.device_type_id or -1,
            num_leds = info.num_leds or 0,
            zones = zones,
            disabled = disabled_devices[identity] == true,
            registered = not (disabled_devices[identity] == true),
        }
    end

    -- Sort by dev_idx for stable ordering
    table.sort(device_list, function(a, b) return a.dev_idx < b.dev_idx end)

    ext.page_emit({
        type = "devices_snapshot",
        devices = device_list,
    })
end

-------------------------------------------------------------------
-- Sync device list
-------------------------------------------------------------------

sync_devices = function(allow_follow_up, prune_missing, silent)
    if prune_missing == nil then
        prune_missing = true
    end
    if silent ~= true then
        ext.notify_persistent("openrgb-sync", "OpenRGB", "Syncing devices...")
    end
    pending_device_list_update = false

    local count = get_controller_count()
    ext.log("OpenRGB reports " .. count .. " controller(s)")

    local fetched = {}       -- controller_port -> { dev_idx, info }
    local fetched_order = {} -- stable order
    local failures = 0

    for i = 0, count - 1 do
        local info = get_controller_data(i)
        if info then
            local controller_port = make_controller_port(i, info)
            if not fetched[controller_port] then
                fetched_order[#fetched_order + 1] = controller_port
            else
                ext.warn("Duplicate OpenRGB identity detected for " .. controller_port .. ", keeping latest entry")
            end
            fetched[controller_port] = {
                dev_idx = i,
                info = info,
            }
        else
            failures = failures + 1
        end
    end

    local synced = 0
    local discovered_ports = {}
    for _, controller_port in ipairs(fetched_order) do
        local entry = fetched[controller_port]
        discovered_ports[controller_port] = true

        -- Best effort: ask OpenRGB to switch this controller into direct mode.
        send_packet(proto.build_set_custom_mode(entry.dev_idx))

        -- Re-register only when topology changed; otherwise update cache in-place.
        local existing = devices[controller_port]
        if existing then
            local layout_changed = not same_device_layout(existing.info, entry.info)
            existing.dev_idx = entry.dev_idx
            existing.info = entry.info
            existing.device_path = make_device_path(entry.dev_idx, entry.info)
            if layout_changed then
                remove_registered_device(controller_port)
                register_device(entry.dev_idx, entry.info)
            end
        else
            register_device(entry.dev_idx, entry.info)
        end
        synced = synced + 1
    end

    local removed = 0
    if failures == 0 then
        local stale = {}
        for _, controller_port in ipairs(registered_ports) do
            if not discovered_ports[controller_port] then
                stale[#stale + 1] = controller_port
            end
        end

        if prune_missing then
            -- Only prune stale devices if all controller data requests succeeded.
            for _, controller_port in ipairs(stale) do
                remove_registered_device(controller_port)
                removed = removed + 1
            end
        elseif #stale > 0 then
            ext.log(
                "OpenRGB sync deferred stale prune (" .. tostring(#stale) .. " device(s))"
            )
        end
    else
        ext.warn(
            "OpenRGB sync partial failure (" .. failures .. " controller(s) failed), keeping existing unmatched devices"
        )
    end

    if silent ~= true then
        ext.dismiss_persistent("openrgb-sync")
    end
    local level = synced > 0 and "success" or "warning"
    local summary = "Found " .. count .. " device(s), synced " .. synced
    if removed > 0 then
        summary = summary .. ", removed " .. removed
    end
    if failures > 0 then
        summary = summary .. ", failed " .. failures
    end
    if silent ~= true then
        ext.notify("OpenRGB", summary, level)
    end

    -- If we received DEVICE_LIST_UPDATED during sync, perform one additional
    -- sync pass to converge on the latest server state.
    if allow_follow_up ~= false and pending_device_list_update then
        pending_device_list_update = false
        ext.log("Re-sync requested by OpenRGB device-list update")
        local ok, err = pcall(sync_devices, false, prune_missing, silent)
        if not ok then
            ext.warn("OpenRGB follow-up sync failed: " .. tostring(err))
        end
    end

    pcall(send_devices_snapshot)

    return {
        count = count,
        synced = synced,
        removed = removed,
        failures = failures,
    }
end

-------------------------------------------------------------------
-- Disconnect
-------------------------------------------------------------------

disconnect = function()
    if conn then
        pcall(tcp.close, conn)
        conn = nil
    end
    unregister_all_devices()
    server_protocol = 0
    pending_device_list_update = false
    pcall(send_connection_status)
end

-------------------------------------------------------------------
-- Rescan
-------------------------------------------------------------------

--- Ask OpenRGB to rescan hardware, then poll-sync until device list stabilizes.
local function request_rescan_and_sync()
    ext.notify_persistent("openrgb-rescan", "OpenRGB", "Rescanning hardware...")

    -- Send the rescan request. This has no direct reply; instead OpenRGB
    -- will asynchronously send DEVICE_LIST_UPDATED when the scan finishes.
    local pkt = proto.build_request_rescan_devices()
    if not send_packet(pkt) then
        ext.dismiss_persistent("openrgb-rescan")
        ext.notify("OpenRGB", "Failed to send rescan request", "error")
        return false
    end

    ext.log("Sent REQUEST_RESCAN_DEVICES, polling for updated controller list...")

    local had_existing_devices = #registered_ports > 0
    local poll_ms = 1000
    local elapsed_ms = 0
    local latest_count = -1

    while elapsed_ms < RESCAN_TIMEOUT_MS do
        local ok, stats_or_err = pcall(sync_devices, false, false, true)
        if ok then
            latest_count = tonumber(stats_or_err.count) or 0
            ext.log("Rescan poll: OpenRGB currently reports " .. tostring(latest_count) .. " controller(s)")
            -- During OpenRGB detection, controller list may transiently become 0.
            -- Wait for at least one controller before finalizing and pruning stale devices.
            if latest_count > 0 then
                break
            end
        else
            ext.warn("Rescan poll sync failed: " .. tostring(stats_or_err))
        end

        ext.sleep(poll_ms)
        elapsed_ms = elapsed_ms + poll_ms
        local secs = math.floor(elapsed_ms / 1000)
        ext.notify_persistent("openrgb-rescan", "OpenRGB",
            "Rescanning hardware... " .. secs .. "s (found " .. tostring(math.max(0, latest_count)) .. ")")
    end

    local allow_prune = (latest_count > 0) or (not had_existing_devices)
    if not allow_prune then
        ext.warn("Rescan timed out with 0 controllers; keeping existing mapped devices")
    end

    local ok, err = pcall(sync_devices, true, allow_prune, false)
    ext.dismiss_persistent("openrgb-rescan")
    if not ok then
        ext.warn("Post-rescan sync failed: " .. tostring(err))
        ext.notify("OpenRGB", "Rescan sync failed", "error")
        return false
    end

    if not allow_prune then
        ext.notify("OpenRGB", "Rescan still in progress, kept existing devices to avoid false removal", "warning")
    end

    return true
end

-------------------------------------------------------------------
-- Extension callbacks
-------------------------------------------------------------------

local P = {}

function P.on_start()
    load_disabled_devices()
    ext.log("OpenRGB Bridge extension starting")

    -- Launch the bundled OpenRGB in server mode
    if not launch_openrgb() then
        ext.notify("OpenRGB", "Failed to launch OpenRGB", "error")
        return
    end

    -- Wait for the server to become available
    if not wait_for_openrgb_server(30, 1000) then
        ext.notify("OpenRGB", "OpenRGB server failed to start", "error")
        kill_openrgb()
        return
    end

    -- Connect and sync devices
    if not connect_and_sync() then
        ext.warn("Initial connection failed, will retry on scan")
    end
end

function P.on_stop()
    ext.log("OpenRGB Bridge extension stopping")
    disconnect()
    kill_openrgb()
end

function P.on_scan_devices()
    -- Ensure the OpenRGB process is alive; restart if it died
    if openrgb_process and not is_openrgb_alive() then
        ext.warn("OpenRGB process died, restarting...")
        disconnect()
        openrgb_process = nil

        if not launch_openrgb() then
            ext.notify("OpenRGB", "Failed to relaunch OpenRGB", "error")
            return
        end
        if not wait_for_openrgb_server(30, 1000) then
            ext.notify("OpenRGB", "OpenRGB server failed to restart", "error")
            kill_openrgb()
            return
        end
    end

    if conn then
        -- Already connected: trigger OpenRGB hardware rescan
        local ok, err = pcall(request_rescan_and_sync)
        if not ok then
            ext.warn("Rescan failed: " .. tostring(err))
            ext.notify("OpenRGB", "Rescan failed, reconnecting...", "warning")
            disconnect()
            -- Fall through to reconnect below
        else
            return
        end
    end

    -- Not connected: establish connection and sync
    connect_and_sync()
end

function P.on_devices_changed(_devices)
    -- No action needed for now
end

function P.on_device_frame(port, outputs)
    local device = devices[port]
    if not device or not conn then return end

    local dev_idx = device.dev_idx

    -- Collect ALL LED colors across all outputs/zones into a single flat array
    -- OpenRGB UpdateLEDs works on the whole device, not per-zone
    local all_colors = {}
    if device.info.zones and #device.info.zones > 0 then
        local zone_index = 0
        for _, zone in ipairs(device.info.zones) do
            local zone_id = "zone" .. zone_index
            local zone_colors = outputs[zone_id]
            local target_leds = tonumber(zone.leds_count) or 0

            if zone_colors then
                local incoming_leds = math.floor(#zone_colors / 3)
                if incoming_leds ~= target_leds then
                    target_leds = resize_zone_if_needed(device, zone_index, incoming_leds)
                end
            end

            if zone_colors then
                -- zone_colors is flat: r,g,b,r,g,b,...
                -- Keep payload length aligned to current zone size.
                local expected_values = target_leds * 3
                local copy_values = math.min(#zone_colors, expected_values)
                for j = 1, copy_values do
                    all_colors[#all_colors + 1] = zone_colors[j]
                end
                for _ = copy_values + 1, expected_values do
                    all_colors[#all_colors + 1] = 0
                end
            else
                -- Fill with black for missing zone payload.
                for _ = 1, target_leds * 3 do
                    all_colors[#all_colors + 1] = 0
                end
            end
            zone_index = zone_index + 1
        end
    else
        -- Fallback for controllers that expose no zones: use "default" output.
        local default_colors = outputs["default"]
        if default_colors then
            for j = 1, #default_colors do
                all_colors[#all_colors + 1] = default_colors[j]
            end
        elseif device.info.num_leds and device.info.num_leds > 0 then
            for _ = 1, device.info.num_leds * 3 do
                all_colors[#all_colors + 1] = 0
            end
        end
    end

    if #all_colors == 0 then return end

    local pkt = proto.build_update_leds(dev_idx, all_colors)
    if not send_packet(pkt) then
        ext.warn("Failed to send LEDs for " .. port .. ", disconnecting")
        disconnect()
    end
end

function P.on_page_message(msg)
    if type(msg) ~= "table" then return end

    local msg_type = msg.type

    if msg_type == "bootstrap" then
        send_devices_snapshot()
        send_connection_status()

    elseif msg_type == "toggle_device" then
        local port = msg.controller_port
        if type(port) ~= "string" then return end

        local entry = devices[port]
        if not entry or not entry.info then return end
        local identity = make_device_identity(entry.info)

        if disabled_devices[identity] then
            -- Enable: remove from disabled list, re-register if we have info
            disabled_devices[identity] = nil
            save_disabled_devices()
            entry.disabled = nil
            register_device(entry.dev_idx, entry.info)
        else
            -- Disable: add to disabled list, unregister
            disabled_devices[identity] = true
            save_disabled_devices()
            entry.disabled = true
            pcall(ext.remove_extension_device, port)
            -- Remove from registered_ports list
            for idx, p in ipairs(registered_ports) do
                if p == port then
                    table.remove(registered_ports, idx)
                    break
                end
            end
        end
        send_devices_snapshot()

    elseif msg_type == "rescan" then
        local ok, err = pcall(request_rescan_and_sync)
        if not ok then
            ext.warn("Page-requested rescan failed: " .. tostring(err))
        end
    end
end

return P
