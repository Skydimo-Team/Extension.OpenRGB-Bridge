import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { ChakraProvider } from '@chakra-ui/react'
import { chakraSystem } from './theme'
import App from './App'

document.addEventListener('contextmenu', e => e.preventDefault())

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ChakraProvider value={chakraSystem}>
      <App />
    </ChakraProvider>
  </StrictMode>,
)
