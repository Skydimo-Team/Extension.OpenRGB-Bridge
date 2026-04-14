import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  Badge,
  Box,
  Card,
  EmptyState,
  Flex,
  Icon,
  SimpleGrid,
  Spinner,
  Switch,
  Text,
  VStack,
} from '@chakra-ui/react'
import {
  Cable,
  CircuitBoard,
  Cpu,
  Fan,
  Gamepad2,
  HardDrive,
  Headphones,
  Keyboard,
  Laptop,
  Lightbulb,
  MemoryStick,
  Mic,
  Monitor,
  Mouse,
  Package,
  RefreshCw,
  Speaker,
  Wifi,
  WifiOff,
} from 'lucide-react'
import { bridge, type BridgeEvent, type ConnectionStatus } from './bridge'
import type { DeviceType, OpenRGBDevice } from './types'
import { onLocaleChange, t } from './i18n'
import './theme.css'

type DeviceFilter = 'all' | 'enabled' | 'disabled'

/* -- helpers ------------------------------------------------ */

function useForceUpdate() {
  const [, setState] = useState(0)
  return useCallback(() => setState((n) => n + 1), [])
}

function useBridge() {
  const [devices, setDevices] = useState<OpenRGBDevice[]>([])
  const [connectionStatus, setConnectionStatus] = useState<{ connected: boolean }>({ connected: false })
  const [wsStatus, setWsStatus] = useState<ConnectionStatus>('disconnected')
  const forceUpdate = useForceUpdate()

  useEffect(() => {
    const unsubEvent = bridge.subscribe((event: BridgeEvent) => {
      if (event.type === 'devices_snapshot') {
        setDevices(event.data.devices)
      }
      if (event.type === 'connection_status') {
        setConnectionStatus(event.data)
      }
    })
    const unsubStatus = bridge.subscribeStatus(setWsStatus)
    const unsubLocale = onLocaleChange(() => forceUpdate())
    bridge.connect()
    return () => {
      unsubEvent()
      unsubStatus()
      unsubLocale()
      bridge.disconnect()
    }
  }, [forceUpdate])

  return { devices, connectionStatus, wsStatus }
}

const DEVICE_TYPE_ICONS: Record<DeviceType, React.ElementType> = {
  motherboard: Cpu,
  dram: MemoryStick,
  gpu: CircuitBoard,
  cooler: Fan,
  ledstrip: Lightbulb,
  keyboard: Keyboard,
  mouse: Mouse,
  mousemat: Mouse,
  headset: Headphones,
  headsetstand: Headphones,
  gamepad: Gamepad2,
  light: Lightbulb,
  speaker: Speaker,
  virtual: Package,
  storage: HardDrive,
  case: HardDrive,
  microphone: Mic,
  accessory: Cable,
  keypad: Keyboard,
  laptop: Laptop,
  monitor: Monitor,
  unknown: Package,
}

function getDeviceIcon(type: DeviceType): React.ElementType {
  return DEVICE_TYPE_ICONS[type] ?? Package
}

/* -- StatusBadge -------------------------------------------- */

function StatusBadge({ connected }: { connected: boolean }) {
  return (
    <Badge
      px="2.5"
      py="0.5"
      borderRadius="var(--radius-l)"
      fontSize="xs"
      fontWeight="500"
      bg={connected ? 'var(--badge-ok-bg)' : 'var(--badge-error-bg)'}
      color={connected ? 'var(--badge-ok-text)' : 'var(--badge-error-text)'}
    >
      <Box
        as="span"
        display="inline-block"
        w="6px"
        h="6px"
        borderRadius="full"
        bg={connected ? 'var(--badge-ok-text)' : 'var(--badge-error-text)'}
        mr="1.5"
      />
      {connected ? t('connected') : t('disconnected')}
    </Badge>
  )
}

/* -- FilterBar ---------------------------------------------- */

function FilterBar({ filter, onFilter, counts }: {
  filter: DeviceFilter
  onFilter: (f: DeviceFilter) => void
  counts: Record<DeviceFilter, number>
}) {
  const filters: DeviceFilter[] = ['all', 'enabled', 'disabled']
  const labels: Record<DeviceFilter, string> = {
    all: t('filter_all'),
    enabled: t('filter_enabled'),
    disabled: t('filter_disabled'),
  }

  return (
    <Flex gap="1.5" flexWrap="wrap">
      {filters.map((entry) => {
        const active = filter === entry
        return (
          <Box
            key={entry}
            as="button"
            px="3"
            py="1"
            fontSize="13px"
            fontWeight="500"
            borderRadius="var(--radius-l)"
            cursor="pointer"
            transition="all 0.15s"
            border="1px solid"
            borderColor={active ? 'var(--accent-color)' : 'var(--border-subtle)'}
            bg={active ? 'var(--accent-color)' : 'transparent'}
            color={active ? 'var(--accent-text)' : 'var(--text-secondary)'}
            _hover={{
              bg: active ? 'var(--accent-hover)' : 'var(--bg-card-hover)',
            }}
            onClick={() => onFilter(entry)}
          >
            {labels[entry]} ({counts[entry]})
          </Box>
        )
      })}
    </Flex>
  )
}

/* -- DeviceCard --------------------------------------------- */

function DeviceCard({ device, onToggle }: {
  device: OpenRGBDevice
  onToggle: (controllerPort: string, disabled: boolean) => void
}) {
  const DevIcon = getDeviceIcon(device.device_type)
  const totalZoneLeds = device.zones.reduce((sum, z) => sum + z.leds_count, 0)

  return (
    <Card.Root
      variant="outline"
      bg="var(--bg-card)"
      borderColor="var(--border-subtle)"
      overflow="hidden"
      transition="all 0.15s"
      opacity={device.disabled ? 0.5 : 1}
      _hover={{ borderColor: 'var(--border-strong)', bg: 'var(--bg-card-hover)' }}
    >
      <Card.Body gap="3" p="4">
        {/* Top row: icon + info + toggle */}
        <Flex gap="3" align="start" justify="space-between">
          <Flex gap="3" align="start" minW="0" flex="1">
            <Flex
              align="center"
              justify="center"
              w="40px"
              h="40px"
              minW="40px"
              borderRadius="var(--radius-m)"
              bg="var(--card-icon-bg)"
            >
              <Icon color="var(--accent-color)" boxSize="19px">
                <DevIcon size={19} />
              </Icon>
            </Flex>

            <Box minW="0" flex="1">
              <Text fontSize="15px" fontWeight="700" color="var(--text-primary)" truncate>
                {device.name}
              </Text>
              <Text mt="0.5" fontSize="12px" color="var(--text-muted)" truncate>
                {device.vendor || device.device_type}
                {device.location ? ` \u00b7 ${device.location}` : ''}
              </Text>
            </Box>
          </Flex>

          <Switch.Root
            checked={!device.disabled}
            onCheckedChange={(details) => onToggle(device.controller_port, !details.checked)}
          >
            <Switch.HiddenInput />
            <Switch.Control>
              <Switch.Thumb />
            </Switch.Control>
          </Switch.Root>
        </Flex>

        {/* Badges row */}
        <Flex gap="1.5" flexWrap="wrap">
          <Badge
            fontSize="10.5px"
            px="1.5"
            py="0"
            borderRadius="var(--radius-s)"
            bg="var(--badge-device-bg)"
            color="var(--badge-device-text)"
            fontWeight="500"
          >
            {device.device_type}
          </Badge>
          {device.vendor && (
            <Badge
              fontSize="10.5px"
              px="1.5"
              py="0"
              borderRadius="var(--radius-s)"
              bg="var(--badge-idle-bg)"
              color="var(--badge-idle-text)"
              fontWeight="500"
            >
              {device.vendor}
            </Badge>
          )}
          <Badge
            fontSize="10.5px"
            px="1.5"
            py="0"
            borderRadius="var(--radius-s)"
            bg="var(--badge-idle-bg)"
            color="var(--badge-idle-text)"
            fontWeight="500"
          >
            {t('device_zones', { count: device.zones.length })}
          </Badge>
          <Badge
            fontSize="10.5px"
            px="1.5"
            py="0"
            borderRadius="var(--radius-s)"
            bg="var(--badge-idle-bg)"
            color="var(--badge-idle-text)"
            fontWeight="500"
          >
            {t('device_leds', { count: totalZoneLeds || device.num_leds })}
          </Badge>
          {device.disabled && (
            <Badge
              fontSize="10.5px"
              px="1.5"
              py="0"
              borderRadius="var(--radius-s)"
              bg="var(--badge-disabled-bg)"
              color="var(--badge-disabled-text)"
              fontWeight="500"
            >
              {t('disabled_label')}
            </Badge>
          )}
        </Flex>
      </Card.Body>
    </Card.Root>
  )
}

/* -- App ---------------------------------------------------- */

export default function App() {
  const { devices, connectionStatus, wsStatus } = useBridge()
  const [filter, setFilter] = useState<DeviceFilter>('all')

  const counts = useMemo(() => {
    const result: Record<DeviceFilter, number> = { all: 0, enabled: 0, disabled: 0 }
    for (const device of devices) {
      result.all++
      if (device.disabled) result.disabled++
      else result.enabled++
    }
    return result
  }, [devices])

  const filteredDevices = useMemo(() => {
    const list = devices.filter((device) => {
      switch (filter) {
        case 'enabled':
          return !device.disabled
        case 'disabled':
          return device.disabled
        default:
          return true
      }
    })

    list.sort((a, b) => {
      // enabled devices first, then alphabetical
      if (a.disabled !== b.disabled) return a.disabled ? 1 : -1
      return a.name.localeCompare(b.name)
    })

    return list
  }, [devices, filter])

  const handleToggle = useCallback((controllerPort: string, disabled: boolean) => {
    bridge.send('toggle_device', { controller_port: controllerPort, disabled })
  }, [])

  const handleRescan = useCallback(() => {
    bridge.send('rescan')
  }, [])

  const isConnected = wsStatus === 'connected' && connectionStatus.connected
  const hasDevices = devices.length > 0

  const summary = t('devices_stats', {
    total: counts.all,
    enabled: counts.enabled,
    disabled: counts.disabled,
  })

  return (
    <Box display="flex" flexDirection="column" h="100%" maxH="100vh" overflow="hidden">
      {/* -- Header ------------------------------------------ */}
      <Box
        px="5"
        pt="4"
        pb="3"
        borderBottom="1px solid var(--border-subtle)"
        bg="var(--bg-panel)"
        position="sticky"
        top="0"
        zIndex="10"
      >
        <Flex align="center" justify="space-between" gap="3" flexWrap="wrap">
          <Flex align="center" gap="3" minW="0">
            <Flex
              align="center"
              justify="center"
              w="40px"
              h="40px"
              minW="40px"
              borderRadius="var(--radius-l)"
              bg="var(--card-icon-bg)"
            >
              <Icon boxSize="20px" color="var(--accent-color)">
                {isConnected ? <Wifi size={20} /> : <WifiOff size={20} />}
              </Icon>
            </Flex>

            <Box minW="0">
              <Text fontSize="16px" fontWeight="700" color="var(--text-primary)" truncate>
                {t('title')}
              </Text>
              <Text fontSize="12px" color="var(--text-muted)" truncate>
                {summary}
              </Text>
            </Box>
          </Flex>

          <Flex align="center" gap="2" flexWrap="wrap">
            <StatusBadge connected={isConnected} />
            <Box
              as="button"
              display="flex"
              alignItems="center"
              gap="1.5"
              px="2.5"
              py="1"
              fontSize="13px"
              fontWeight="500"
              borderRadius="var(--radius-m)"
              border="1px solid var(--border-subtle)"
              bg="transparent"
              color="var(--text-secondary)"
              cursor="pointer"
              transition="all 0.15s"
              _hover={{ bg: 'var(--bg-card-hover)', color: 'var(--accent-color)', borderColor: 'var(--accent-color)' }}
              onClick={handleRescan}
            >
              <RefreshCw size={14} />
              {t('rescan')}
            </Box>
          </Flex>
        </Flex>

        {hasDevices && (
          <Box mt="3">
            <FilterBar filter={filter} onFilter={setFilter} counts={counts} />
          </Box>
        )}
      </Box>

      {/* -- Content ----------------------------------------- */}
      <Box flex="1" overflow="auto" px="5" py="4">
        {wsStatus !== 'connected' && !hasDevices ? (
          <Flex align="center" justify="center" h="100%" direction="column" gap="3">
            <Spinner size="md" color="var(--accent-color)" />
            <Text fontSize="13px" color="var(--text-muted)">
              {t('loading')}
            </Text>
          </Flex>
        ) : !hasDevices ? (
          <EmptyState.Root size="lg">
            <EmptyState.Content>
              <EmptyState.Indicator>
                <Cpu />
              </EmptyState.Indicator>
              <VStack textAlign="center" gap="1">
                <EmptyState.Title>{t('no_devices_title')}</EmptyState.Title>
                <EmptyState.Description>{t('no_devices_desc')}</EmptyState.Description>
              </VStack>
            </EmptyState.Content>
          </EmptyState.Root>
        ) : filteredDevices.length === 0 ? (
          <Flex align="center" justify="center" h="120px">
            <Text fontSize="13px" color="var(--text-muted)">
              {t('no_match')}
            </Text>
          </Flex>
        ) : (
          <SimpleGrid columns={{ base: 1, md: 2, lg: 3 }} gap="3">
            {filteredDevices.map((device) => (
              <DeviceCard
                key={device.controller_port}
                device={device}
                onToggle={handleToggle}
              />
            ))}
          </SimpleGrid>
        )}
      </Box>
    </Box>
  )
}
