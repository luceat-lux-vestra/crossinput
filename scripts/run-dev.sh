#!/usr/bin/env bash
set -euo pipefail

# 개발 실행 스크립트 — macOS 앱을 디버그 빌드로 실행
# 사용: ./scripts/run-dev.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> run-dev"
echo "    (작성 중: 앱 스켈레톤 완성 후 xcodebuild + 실행으로 대체)"
echo "    참고: '실제 검증'은 실기기 ADB 로그와 DeX 화면 확인을 동반해야 합니다 (AGENTS.md)"

exit 0
