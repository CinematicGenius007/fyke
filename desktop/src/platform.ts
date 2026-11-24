/** How the app names the computer it runs on, from the webview's user agent. The
 * daemon's own copy (`src/runner.zig` `not_found`) uses the same words. */
export function computerName(userAgent: string): "this PC" | "this Mac" | "this computer" {
  return userAgent.includes("Windows") ? "this PC" : userAgent.includes("Macintosh") ? "this Mac" : "this computer";
}

const platform = typeof navigator === "undefined" ? "" : navigator.userAgent;
export const isWindows = platform.includes("Windows");
export const thisComputer = computerName(platform);
