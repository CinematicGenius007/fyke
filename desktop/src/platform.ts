const platform = navigator.userAgent;
export const isWindows = platform.includes("Windows");
export const thisComputer = isWindows ? "this PC" : platform.includes("Macintosh") ? "this Mac" : "this computer";
