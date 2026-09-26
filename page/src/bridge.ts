import type { DevicesSnapshotPayload, OpenRGBDevice } from './types'
import { setLocale } from './i18n'
import { authenticateExtensionSocket } from './extensionPageSession.js'

interface ExtPageEnv {
  extId: string
  wsUrl: string
  locale?: string
}

declare global {
  interface Window {
    __SKYDIMO_EXT_PAGE__?: Partial<ExtPageEnv>
  }
}

export type ConnectionStatus = 'disconnected' | 'connecting' | 'connected'

export type BridgeEvent =
  | { type: 'devices_snapshot'; data: DevicesSnapshotPayload }
  | { type: 'connection_status'; data: { connected: boolean } }
  | { type: 'error'; data: { message: string } }

type BridgeListener = (event: BridgeEvent) => void
type StatusListener = (status: ConnectionStatus) => void

const _params = new URLSearchParams(window.location.search)

export const PAGE: ExtPageEnv = {
  extId: window.__SKYDIMO_EXT_PAGE__?.extId ?? _params.get('extId') ?? 'openrgb_bridge',
  wsUrl: window.__SKYDIMO_EXT_PAGE__?.wsUrl ?? _params.get('wsUrl') ?? 'ws://127.0.0.1:42070',
}

function normalizeDevices(value: unknown): OpenRGBDevice[] {
  if (!Array.isArray(value)) return []
  return value.filter((device): device is OpenRGBDevice => {
    return !!device
      && typeof device === 'object'
      && typeof (device as OpenRGBDevice).name === 'string'
  })
}

class ExtensionBridge {
  private ws: WebSocket | null = null
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null
  private listeners = new Set<BridgeListener>()
  private statusListeners = new Set<StatusListener>()
  private rpcId = 1
  private status: ConnectionStatus = 'disconnected'
  private shouldReconnect = false

  getStatus() {
    return this.status
  }

  subscribe(listener: BridgeListener) {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  subscribeStatus(listener: StatusListener) {
    this.statusListeners.add(listener)
    listener(this.status)
    return () => this.statusListeners.delete(listener)
  }

  connect() {
    this.shouldReconnect = true
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = null
    }
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)) {
      return
    }

    this.setStatus('connecting')
    const socket = new WebSocket(PAGE.wsUrl)
    this.ws = socket

    this.ws.onopen = () => {
      if (this.ws !== socket) return
      this.setStatus('connected')
      this.send('bootstrap')
    }

    this.ws.onmessage = (event) => {
      if (this.ws !== socket) return
      let payload: Record<string, unknown>
      try {
        payload = JSON.parse(event.data) as Record<string, unknown>
      } catch {
        return
      }

      if (payload.method !== 'event' || typeof payload.params !== 'object' || payload.params === null) {
        return
      }

      const params = payload.params as Record<string, unknown>
      const eventName = typeof params.event === 'string' ? params.event : ''

      if (eventName === 'locale-changed') {
        const locale = typeof (params.data as Record<string, unknown> | undefined)?.locale === 'string'
          ? (params.data as Record<string, unknown>).locale as string
          : null
        if (locale) {
          setLocale(locale)
        }
        return
      }

      if (eventName !== `ext-page-message:${PAGE.extId}`) {
        return
      }

      const data = params.data
      if (!data || typeof data !== 'object') {
        return
      }

      const msg = data as Record<string, unknown>
      if (typeof msg.type !== 'string') {
        return
      }

      if (msg.type === 'devices_snapshot') {
        const bridgeEvent: BridgeEvent = {
          type: 'devices_snapshot',
          data: { devices: normalizeDevices((msg as Record<string, unknown>).devices) },
        }
        for (const listener of this.listeners) {
          listener(bridgeEvent)
        }
      }

      if (msg.type === 'connection_status') {
        const bridgeEvent: BridgeEvent = {
          type: 'connection_status',
          data: { connected: !!(msg as Record<string, unknown>).connected },
        }
        for (const listener of this.listeners) {
          listener(bridgeEvent)
        }
      }
    }

    this.ws.onclose = () => {
      if (this.ws !== socket) return
      this.ws = null
      this.setStatus('disconnected')
      if (this.shouldReconnect && !this.reconnectTimer) {
        this.reconnectTimer = setTimeout(() => {
          this.reconnectTimer = null
          this.connect()
        }, 3000)
      }
    }

    this.ws.onerror = () => {
      // onclose handles reconnection.
    }
    authenticateExtensionSocket(socket, {
      onError: (error) => {
        if (this.ws !== socket) return
        if (error.fatal) this.shouldReconnect = false
        for (const listener of this.listeners) {
          listener({ type: 'error', data: { message: error.message } })
        }
      },
    })
  }

  disconnect() {
    this.shouldReconnect = false
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = null
    }
    if (this.ws) {
      this.ws.close()
      this.ws = null
    }
    this.setStatus('disconnected')
  }

  send(type: string, payload: Record<string, unknown> = {}) {
    if (this.status !== 'connected' || !this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return
    }

    const message = {
      jsonrpc: '2.0',
      id: this.rpcId++,
      method: 'ext_page_send',
      params: {
        extId: PAGE.extId,
        data: {
          type,
          ...payload,
        },
      },
    }

    this.ws.send(JSON.stringify(message))
  }

  private setStatus(status: ConnectionStatus) {
    this.status = status
    for (const listener of this.statusListeners) {
      listener(status)
    }
  }
}

export const bridge = new ExtensionBridge()
