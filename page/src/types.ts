// Zone types from OpenRGB protocol
export type ZoneType = 'single' | 'linear' | 'matrix';

// OpenRGB device type names (from protocol.lua DEVICE_TYPE_MAP)
export type DeviceType =
  | 'motherboard' | 'dram' | 'gpu' | 'cooler' | 'ledstrip'
  | 'keyboard' | 'mouse' | 'mousemat' | 'headset' | 'headsetstand'
  | 'gamepad' | 'light' | 'speaker' | 'virtual' | 'storage'
  | 'case' | 'microphone' | 'accessory' | 'keypad' | 'laptop'
  | 'monitor' | 'unknown';

export interface ZoneInfo {
  name: string;
  zone_type: ZoneType;
  leds_count: number;
  leds_min: number;
  leds_max: number;
  matrix_width?: number;
  matrix_height?: number;
}

export interface OpenRGBDevice {
  controller_port: string;     // "openrgb://127.0.0.1:6742/{identifier}"
  device_path: string;         // display path
  dev_idx: number;             // OpenRGB controller index
  name: string;
  vendor: string;
  description: string;
  serial: string;
  location: string;
  device_type: DeviceType;
  device_type_id: number;      // raw numeric type
  num_leds: number;            // total LED count
  zones: ZoneInfo[];
  disabled: boolean;           // whether user has disabled this device
  registered: boolean;         // whether currently registered in Skydimo
}

export interface ConnectionStatus {
  connected: boolean;
  host: string;
  port: number;
  protocol_version: number;
  openrgb_running: boolean;
}

export interface DevicesSnapshot {
  devices: OpenRGBDevice[];
  connection: ConnectionStatus;
}

/** Payload shape sent by the Lua backend for devices_snapshot messages */
export interface DevicesSnapshotPayload {
  devices: OpenRGBDevice[];
}
