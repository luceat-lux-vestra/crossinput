#!/usr/bin/env node
// Check protocol docs match the fixture directory (CI)
// Real golden-fixture comparison implemented in Phase 2.
import { readdirSync } from "node:fs";
import { join } from "node:path";

const fixturesDir = new URL("../fixtures/", import.meta.url).pathname;

try {
  const files = readdirSync(fixturesDir);
  if (files.length === 0) {
    console.log("check-fixtures: no fixtures yet (pre-Phase 2)");
    process.exit(0);
  }
  for (const f of files) {
    if (f.startsWith(".")) continue;
    if (!f.endsWith(".bin") && !f.endsWith(".json")) {
      console.error(`check-fixtures: unexpected file: ${f}`);
      process.exit(1);
    }
  }
  console.log(`check-fixtures: checked ${files.length} fixtures`);
} catch (err) {
  console.error("check-fixtures: no fixture directory:", err.message);
  process.exit(1);
}
