// The desktop UI in a plain browser, against a real daemon through tools/bridge.ts.
// WebKit is the engine closest to both the Mac app's text and WebKitGTK on Linux;
// WebView2 is Chromium, so the Chromium project runs the same checks for Windows.
// Pictures go to zig-out/desktop-snapshots under the names zig-out/gui-snapshots uses.
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "tests/e2e",
  outputDir: "test-results",
  fullyParallel: false,
  workers: 1,
  timeout: 60_000,
  reporter: [["list"]],
  use: {
    baseURL: "http://127.0.0.1:1420",
    // The Mac window's size and a Retina screen, so pictures line up pixel for pixel.
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 2,
    // Headless always: checks never take focus from the person at the computer.
    headless: true,
  },
  projects: [
    { name: "webkit", use: { ...devices["Desktop Safari"], viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 } },
    { name: "chromium", use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 } },
  ],
  webServer: {
    command: "bunx vite --strictPort",
    url: "http://127.0.0.1:1420",
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
  },
});
