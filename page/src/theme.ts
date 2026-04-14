import { createSystem, defaultConfig, defineConfig } from "@chakra-ui/react";

const config = defineConfig({
  theme: {
    semanticTokens: {
      colors: {
        fg: {
          DEFAULT: { value: "var(--text-primary)" },
          muted: { value: "var(--text-secondary)" },
        },
        bg: {
          DEFAULT: { value: "var(--bg-app)" },
          muted: { value: "var(--bg-card)" },
          panel: { value: "var(--bg-panel)" },
        },
        border: {
          DEFAULT: { value: "var(--border-strong)" },
          muted: { value: "var(--border-subtle)" },
          subtle: { value: "var(--border-subtle)" },
        },
        accent: {
          solid: { value: "var(--accent-color)" },
          contrast: { value: "var(--accent-text)" },
          fg: { value: "var(--accent-color)" },
          muted: { value: "var(--badge-device-bg)" },
          subtle: { value: "var(--badge-device-bg)" },
          emphasized: { value: "var(--accent-hover)" },
          focusRing: { value: "var(--accent-color)" },
        },
      },
    },
    tokens: {
      fonts: {
        body: { value: "var(--font-sans)" },
        heading: { value: "var(--font-sans)" },
      },
    },
  },
  globalCss: {
    "*::selection": {
      bg: "accent.muted",
      color: "fg",
    },
  },
});

export const chakraSystem = createSystem(defaultConfig, config);
