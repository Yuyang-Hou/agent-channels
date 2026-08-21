import { describe, expect, it } from "vitest";
import { generateToken } from "../src/ids.js";

describe("generateToken", () => {
  it("is safe as a CLI option value", () => {
    for (let i = 0; i < 128; i++) expect(generateToken()).toMatch(/^rt_[A-Za-z0-9_-]{32}$/);
  });
});
