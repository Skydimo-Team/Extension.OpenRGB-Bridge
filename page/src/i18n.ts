type Translations = Record<string, string>

const I18N: Record<string, Translations> = {
  'en-US': {
    title: 'OpenRGB Bridge',
    connected: 'Connected',
    disconnected: 'Disconnected',
    rescan: 'Rescan',
    tab_devices: 'Devices',
    filter_all: 'All',
    filter_enabled: 'Enabled',
    filter_disabled: 'Disabled',
    loading: 'Loading\u2026',
    no_devices_title: 'No devices found',
    no_devices_desc: 'Make sure OpenRGB is running and the SDK server is enabled.',
    no_match: 'No devices match this filter',
    devices_stats: '{total} devices \u00b7 {enabled} enabled \u00b7 {disabled} disabled',
    device_type: 'Type',
    device_vendor: 'Vendor',
    device_location: 'Location',
    device_zones: '{count} zones',
    device_leds: '{count} LEDs',
    device_serial: 'Serial',
    device_idx: 'Index',
    enable: 'Enable',
    disable: 'Disable',
    disabled_label: 'Disabled',
    enabled_label: 'Enabled',
    openrgb_not_running: 'OpenRGB is not running',
    protocol_version: 'Protocol v{version}',
  },
  'zh-CN': {
    title: 'OpenRGB Bridge',
    connected: '\u5df2\u8fde\u63a5',
    disconnected: '\u672a\u8fde\u63a5',
    rescan: '\u91cd\u65b0\u626b\u63cf',
    tab_devices: '\u8bbe\u5907',
    filter_all: '\u5168\u90e8',
    filter_enabled: '\u5df2\u542f\u7528',
    filter_disabled: '\u5df2\u7981\u7528',
    loading: '\u52a0\u8f7d\u4e2d\u2026',
    no_devices_title: '\u672a\u627e\u5230\u8bbe\u5907',
    no_devices_desc: '\u8bf7\u786e\u4fdd OpenRGB \u5df2\u542f\u52a8\u4e14 SDK \u670d\u52a1\u5df2\u5f00\u542f\u3002',
    no_match: '\u6ca1\u6709\u5339\u914d\u7684\u8bbe\u5907',
    devices_stats: '{total} \u4e2a\u8bbe\u5907 \u00b7 {enabled} \u4e2a\u5df2\u542f\u7528 \u00b7 {disabled} \u4e2a\u5df2\u7981\u7528',
    device_type: '\u7c7b\u578b',
    device_vendor: '\u5382\u5546',
    device_location: '\u4f4d\u7f6e',
    device_zones: '{count} \u4e2a\u533a\u57df',
    device_leds: '{count} \u4e2a LED',
    device_serial: '\u5e8f\u5217\u53f7',
    device_idx: '\u7d22\u5f15',
    enable: '\u542f\u7528',
    disable: '\u7981\u7528',
    disabled_label: '\u5df2\u7981\u7528',
    enabled_label: '\u5df2\u542f\u7528',
    openrgb_not_running: 'OpenRGB \u672a\u8fd0\u884c',
    protocol_version: '\u534f\u8bae\u7248\u672c v{version}',
  },
  'zh-TW': {
    title: 'OpenRGB Bridge',
    connected: '\u5df2\u9023\u63a5',
    disconnected: '\u672a\u9023\u63a5',
    rescan: '\u91cd\u65b0\u6383\u63cf',
    tab_devices: '\u88dd\u7f6e',
    filter_all: '\u5168\u90e8',
    filter_enabled: '\u5df2\u555f\u7528',
    filter_disabled: '\u5df2\u505c\u7528',
    loading: '\u8f09\u5165\u4e2d\u2026',
    no_devices_title: '\u672a\u627e\u5230\u88dd\u7f6e',
    no_devices_desc: '\u8acb\u78ba\u4fdd OpenRGB \u5df2\u555f\u52d5\u4e14 SDK \u670d\u52d9\u5df2\u958b\u555f\u3002',
    no_match: '\u6c92\u6709\u5339\u914d\u7684\u88dd\u7f6e',
    devices_stats: '{total} \u500b\u88dd\u7f6e \u00b7 {enabled} \u500b\u5df2\u555f\u7528 \u00b7 {disabled} \u500b\u5df2\u505c\u7528',
    device_type: '\u985e\u578b',
    device_vendor: '\u5ee0\u5546',
    device_location: '\u4f4d\u7f6e',
    device_zones: '{count} \u500b\u5340\u57df',
    device_leds: '{count} \u500b LED',
    device_serial: '\u5e8f\u865f',
    device_idx: '\u7d22\u5f15',
    enable: '\u555f\u7528',
    disable: '\u505c\u7528',
    disabled_label: '\u5df2\u505c\u7528',
    enabled_label: '\u5df2\u555f\u7528',
    openrgb_not_running: 'OpenRGB \u672a\u904b\u884c',
    protocol_version: '\u5354\u5b9a\u7248\u672c v{version}',
  },
}

const _localeParam = window.__SKYDIMO_EXT_PAGE__?.locale
  ?? new URLSearchParams(window.location.search).get('locale')
let currentLocale = _localeParam && Object.keys(I18N).includes(_localeParam) ? _localeParam : 'en-US'
const localeListeners = new Set<(locale: string) => void>()

export function setLocale(locale: string) {
  currentLocale = locale
  for (const listener of localeListeners) {
    listener(locale)
  }
}

export function getLocale() {
  return currentLocale
}

export function onLocaleChange(listener: (locale: string) => void) {
  localeListeners.add(listener)
  return () => localeListeners.delete(listener)
}

export function t(key: string, vars?: Record<string, string | number>): string {
  const lang = I18N[currentLocale] ?? I18N['en-US']
  let str = lang[key] ?? I18N['en-US'][key] ?? key
  if (vars) {
    for (const [k, v] of Object.entries(vars)) {
      str = str.replace(`{${k}}`, String(v))
    }
  }
  return str
}
