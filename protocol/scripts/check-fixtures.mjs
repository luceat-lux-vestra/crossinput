#!/usr/bin/env node
// 프로토콜 문서와 fixture 디렉토리 일치 검사 (CI용)
// Phase 2에서 실제 golden fixture 비교 로직 구현.
import { readdirSync } from "node:fs";
import { join } from "node:path";

const fixturesDir = new URL("../fixtures/", import.meta.url).pathname;

try {
  const files = readdirSync(fixturesDir);
  if (files.length === 0) {
    console.log("check-fixtures: fixture 없음 (아직 Phase 2 이전)");
    process.exit(0);
  }
  for (const f of files) {
    if (f.startsWith(".")) continue;
    if (!f.endsWith(".bin") && !f.endsWith(".json")) {
      console.error(`check-fixtures: 예상하지 못한 파일: ${f}`);
      process.exit(1);
    }
  }
  console.log(`check-fixtures: ${files.length}개 fixture 검사 완료`);
} catch (err) {
  console.error("check-fixtures: fixture 디렉토리 없음:", err.message);
  process.exit(1);
}
