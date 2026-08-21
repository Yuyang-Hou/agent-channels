// `rogerthat receive-recipe` is a pure recipe printer — no network, no fs.
// So we test it by importing renderRecipe directly and asserting on the string.

import { describe, expect, it } from "vitest";
import { renderRecipe } from "../src/receive-recipe.js";

describe("receive-recipe", () => {
  it("renders both steps with the correct flags and the literal Monitor command", () => {
    const out = renderRecipe({
      channel: "ch1",
      token: "tok1",
      session: "sid1",
      origin: "https://rogerthat.chat",
      inbox: "/tmp/rr-ch1.log",
      format: "text",
    });
    // Listener command includes all the flags we expect to flow through.
    expect(out).toContain("nohup npx -y rogerthat listen-here");
    expect(out).toContain("--channel ch1");
    expect(out).toContain("--token tok1");
    expect(out).toContain("--session sid1");
    expect(out).toContain("--inbox /tmp/rr-ch1.log");
    expect(out).toContain("--format text");
    // Monitor command is the literal `tail -F` (no parser piped in).
    expect(out).toContain("stdbuf -oL tail -n 0 -F /tmp/rr-ch1.log");
    // The Monitor STEP must not contain a pipe — that's the rule we're enforcing.
    // We slice out just the Step 2 block (between the Step 2 header and the next ───)
    // and assert no pipe character appears in it.
    const step2Match = out.match(/─── Step 2[\s\S]*?─── Do NOT/);
    expect(step2Match).toBeTruthy();
    expect(step2Match![0]).not.toContain("|");
    expect(step2Match![0]).not.toMatch(/\bjq\b/);
    expect(step2Match![0]).not.toMatch(/\bpython\b/);
    // The "do NOT" warning is present so an agent reading the recipe knows
    // why this command shape is non-negotiable.
    expect(out).toMatch(/DO NOT|Do NOT|do NOT/);
  });

  it("renders jsonl format with .jsonl-style commands", () => {
    const out = renderRecipe({
      channel: "ch2",
      token: "tok2",
      session: "sid2",
      origin: "http://localhost:7424",
      inbox: "/tmp/rr-ch2.jsonl",
      format: "jsonl",
    });
    expect(out).toContain("--format jsonl");
    expect(out).toContain("/tmp/rr-ch2.jsonl");
    expect(out).toContain("stdbuf -oL tail -n 0 -F /tmp/rr-ch2.jsonl");
  });
});
