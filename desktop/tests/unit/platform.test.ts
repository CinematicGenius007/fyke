import { expect, test } from "bun:test";
import { computerName } from "../../src/platform";

test("the computer is named as its own system names it (C9)", () => {
  expect(computerName("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Edg/130.0")).toBe("this PC");
  expect(computerName("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15")).toBe("this computer");
  expect(computerName("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15")).toBe("this Mac");
});
