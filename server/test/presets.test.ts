// Unit tests for the preset resolver + defaults merger. No server, no fetch —
// just exercises the pure functions in src/presets.ts.

import { describe, expect, it } from "vitest";
import {
  type Mode,
  applyPresetDefaults,
  getPreset,
  resolveMode,
} from "../src/presets.js";

describe("resolveMode", () => {
  it("returns 'default' for the canonical host", () => {
    expect(resolveMode("rogerthat.chat")).toBe("default");
    expect(resolveMode("rogerthat.chat:443")).toBe("default");
  });
  it("returns 'default' for undefined/empty input", () => {
    expect(resolveMode(undefined)).toBe("default");
    expect(resolveMode(null)).toBe("default");
    expect(resolveMode("")).toBe("default");
  });
  it("returns 'default' for unknown subdomains", () => {
    expect(resolveMode("foo.rogerthat.chat")).toBe("default");
    expect(resolveMode("backdoors.rogerthat.chat")).toBe("default"); // backdoors is handled separately
  });
  it("recognizes each named preset by host prefix", () => {
    expect(resolveMode("park.rogerthat.chat")).toBe("park");
    expect(resolveMode("live.rogerthat.chat")).toBe("live");
    expect(resolveMode("go.rogerthat.chat")).toBe("go");
  });
  it("is case-insensitive on the host", () => {
    expect(resolveMode("PARK.rogerthat.chat")).toBe("park");
    expect(resolveMode("Go.RogerThat.Chat")).toBe("go");
  });
  it("ignores trailing port and path-like junk", () => {
    expect(resolveMode("go.rogerthat.chat:8080")).toBe("go");
    expect(resolveMode("park.rogerthat.chat ")).toBe("park"); // trailing space treated like trailing junk via startsWith
  });
});

describe("getPreset", () => {
  it("returns undefined for default mode (caller falls back to canonical behavior)", () => {
    expect(getPreset("default")).toBeUndefined();
  });
  it("returns a real preset for each named mode", () => {
    for (const mode of ["park", "live", "go"] as Mode[]) {
      const p = getPreset(mode);
      expect(p).toBeDefined();
      expect(p!.mode).toBe(mode);
      expect(p!.hostPrefix).toMatch(/^[a-z]+\.$/);
    }
  });
  it("each preset has a sane TTL within the 1-86400s allowed range", () => {
    for (const mode of ["park", "live", "go"] as Mode[]) {
      const p = getPreset(mode)!;
      expect(p.defaults.session_ttl_seconds).toBeGreaterThanOrEqual(1);
      expect(p.defaults.session_ttl_seconds).toBeLessThanOrEqual(86400);
    }
  });
  it("go is trusted (the named-trust mode)", () => {
    expect(getPreset("go")!.defaults.trust_mode).toBe("trusted");
  });
  it("park and live are untrusted (safe defaults for unknown peers)", () => {
    expect(getPreset("park")!.defaults.trust_mode).toBe("untrusted");
    expect(getPreset("live")!.defaults.trust_mode).toBe("untrusted");
  });
  it("go auto-mints owner_password and pre-arms the listener", () => {
    const p = getPreset("go")!;
    expect(p.autoMintOwnerPassword).toBe(true);
    expect(p.preArmListener).toBe(true);
  });
});

describe("applyPresetDefaults", () => {
  it("leaves body untouched in default mode", () => {
    const out = applyPresetDefaults("default", {});
    expect(out.retention).toBeUndefined();
    expect(out.trust_mode).toBe("untrusted");
    expect(out.session_ttl_seconds).toBeUndefined();
  });
  it("fills missing fields from the preset", () => {
    const out = applyPresetDefaults("park", {});
    const park = getPreset("park")!.defaults;
    expect(out.retention).toBe(park.retention);
    expect(out.trust_mode).toBe(park.trust_mode);
    expect(out.session_ttl_seconds).toBe(park.session_ttl_seconds);
  });
  it("body wins over preset (escape hatch for power users)", () => {
    const out = applyPresetDefaults("park", {
      retention: "full",
      trust_mode: "untrusted",
      session_ttl_seconds: 60,
    });
    expect(out.retention).toBe("full");
    expect(out.trust_mode).toBe("untrusted");
    expect(out.session_ttl_seconds).toBe(60);
  });
});
