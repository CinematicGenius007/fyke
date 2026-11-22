import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

const repo = fileURLToPath(new URL("..", import.meta.url));

export default defineConfig({
  plugins: [solid()],
  // Tauri expects a fixed port, and the app talks only to this machine.
  server: { host: "127.0.0.1", port: 1420, strictPort: true, fs: { allow: [repo] } },
  clearScreen: false,
  build: {
    target: ["es2022", "safari16", "chrome105"],
    // Fonts are served as files, never inlined into the script.
    assetsInlineLimit: 0,
    sourcemap: false,
  },
});
