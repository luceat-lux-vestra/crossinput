#!/usr/bin/env bash
# Regression tests for the evidence privacy lifecycle (issue #60 review).
#
# Exercises the REAL production library (scripts/lib/evidence-privacy.sh)
# sourced by scripts/verify-device-issue57.sh — no fake reimplementation, no
# device required. Runs offline on any host with bash + python3 + grep.
#
# Cases:
#   A  explicit ANDROID_SERIAL == selected DEVICE   -> both redacted
#   B  ANDROID_SERIAL unset + auto-selected DEVICE  -> selected serial redacted
#      (regression for the 3dbe7cc merge blocker: the selected serial was
#       wiped from identifier state by a second initialization)
#   C  early exit before publication                -> git-bound tree carries
#                                                      zero raw serials and
#                                                      the directory is gone
#   D  unknown /Users|/home residual                -> sanitize refuses,
#                                                      dst never created
#   E  abnormal cleanup mid-capture                 -> discard leaves no raw
#                                                      identifier anywhere
#   O  replacement ordering                         -> home before username
#   S  driver static lifecycle invariants           -> bind-once / publish gate
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/evidence-privacy.sh
source "$HERE/lib/evidence-privacy.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "ok  - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

expect() { # expect <name> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

new_case_dir() {
    mktemp -d "${TMPDIR:-/tmp}/privacy-case.XXXXXX"
}

count_occurrences() { # count_occurrences <needle> <file>
    grep -oF -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------- Case A ----
case_a() {
    local d; d="$(new_case_dir)"
    export ANDROID_SERIAL="SERIAL_EXPLICIT_123"
    privacy_init_identifiers
    privacy_bind_device "SERIAL_EXPLICIT_123"
    printf 'device SERIAL_EXPLICIT_123\nhome %s/data\n' "$HOME" >"$d/raw.txt"
    sanitize_stream "$d/raw.txt" "$d/out.txt" || { bad "A: sanitize returned error"; return; }
    expect "A raw serial occurrences" 0 "$(count_occurrences SERIAL_EXPLICIT_123 "$d/out.txt")"
    expect "A raw home occurrences" 0 "$(count_occurrences "$HOME" "$d/out.txt")"
    expect "A serial marker present" 1 "$(count_occurrences '<redacted-adb-serial>' "$d/out.txt")"
    expect "A home marker present" 1 "$(count_occurrences '<redacted-home-path>' "$d/out.txt")"
    rm -rf "$d"
}

# ---------------------------------------------------------------- Case B ----
case_b() {
    local d; d="$(new_case_dir)"
    unset ANDROID_SERIAL
    privacy_init_identifiers
    # Single-device auto-selection: the ONLY place the serial enters state.
    privacy_bind_device "SERIAL_AUTO_SELECTED_456"
    printf 'selected=SERIAL_AUTO_SELECTED_456\n' >"$d/raw.txt"
    sanitize_stream "$d/raw.txt" "$d/out.txt" || { bad "B: sanitize returned error"; return; }
    expect "B selected serial occurrences (merge blocker)" \
        0 "$(count_occurrences SERIAL_AUTO_SELECTED_456 "$d/out.txt")"
    expect "B serial marker present" 1 "$(count_occurrences '<redacted-adb-serial>' "$d/out.txt")"
    rm -rf "$d"
}

# ---------------------------------------------------------------- Case C ----
case_c() {
    local d; d="$(new_case_dir)"
    mkdir -p "$d/git-bound/issue-57-device-verification/x"
    printf 'adb devices:\nFAKE_SERIAL_C deadbeef device\n' >"$d/git-bound/issue-57-device-verification/adb-devices.txt"
    mkdir -p "$d/raw"
    printf 'raw FAKE_SERIAL_C\n' >"$d/raw/dump.txt"
    # Early-exit simulation: cleanup runs with nothing ever published.
    discard_unpublished_evidence "$d/raw" "$d/git-bound" 0
    if [ -e "$d/git-bound" ]; then
        bad "C: unpublished git-bound directory still exists"
    else
        ok "C: unpublished git-bound directory removed"
    fi
    if [ -n "$(find "$d" -type f -exec grep -l FAKE_SERIAL_C {} + 2>/dev/null)" ]; then
        bad "C: raw serial survived somewhere under case root"
    else
        ok "C: zero raw serial occurrences after early exit"
    fi
    rm -rf "$d"
}

# ---------------------------------------------------------------- Case D ----
case_d() {
    local d; d="$(new_case_dir)"
    unset ANDROID_SERIAL
    privacy_init_identifiers
    printf '/Users/another-stable-name/private/path\n' >"$d/in.txt"
    if sanitize_stream "$d/in.txt" "$d/out.txt" 2>/dev/null; then
        bad "D: unknown host path was accepted"
    elif [ -e "$d/out.txt" ]; then
        bad "D: destination created despite refusal"
    else
        ok "D: unknown /Users residual refused; artifact not published"
    fi
    # publish path fails closed with PRIVACY_FAIL_CODE
    (
        set -euo pipefail
        publish_sanitized "$d/in.txt" "$d/never" 2>/dev/null
    ) >/dev/null 2>&1
    local rc=$?
    expect "D: publish_sanitized exit code" "$PRIVACY_FAIL_CODE" "$rc"
    [ ! -e "$d/never" ] && ok "D: blocked destination absent" || bad "D: destination exists"
    rm -rf "$d"
}

# ---------------------------------------------------------------- Case E ----
case_e() {
    local d; d="$(new_case_dir)"
    ANDROID_SERIAL="SERIAL_E_KILL_789" privacy_init_identifiers
    privacy_bind_device "SERIAL_E_KILL_789"
    mkdir -p "$d/raw" "$d/git"
    printf 'SERIAL_E_KILL_789\n' >"$d/raw/helper.log"
    printf '%s/mid-write\n/home/someone/x\n' "$HOME" >"$d/raw/stdout.bin"
    printf 'already published, sanitized\n' >"$d/git/keep.txt"
    # Abnormal termination during capture: trap-style discard with publish
    # incomplete. Known serial/home/user must vanish from the whole tree;
    # previously published sanitized content may remain.
    discard_unpublished_evidence "$d/raw" "$d/unpublished-git" 0
    if [ -n "$(find "$d/raw" -type f 2>/dev/null)" ]; then
        bad "E: raw zone survived cleanup"
    fi
    if grep -rqE 'SERIAL_E_KILL_789|/Users/|/home/' "$d" 2>/dev/null; then
        bad "E: identifier residue found after abnormal cleanup"
    else
        ok "E: no raw serial/home/user residue after abnormal cleanup"
    fi
    rm -rf "$d"
}

# ------------------------------------------------------- Ordering pin (O) ---
case_o() {
    local d out; d="$(new_case_dir)"
    HOME_BAK="$HOME"
    printf '/Users/alice/report.md\nalice\n' >"$d/in.txt"
    # Pin the fixed order: home path substituted BEFORE the bare username so
    # /Users/alice collapses fully instead of becoming /Users/<redacted-user>.
    IDENT_USER="alice"
    IDENT_HOME="/Users/alice"
    IDENT_ANDROID_SERIAL=""
    IDENT_DEVICE=""
    sanitize_stream "$d/in.txt" "$d/out.txt" || { bad "O: sanitize error"; return; }
    out="$(cat "$d/out.txt")"
    expect "O home path marker" "<redacted-home-path>/report.md" "$(printf '%s' "$out" | head -1)"
    expect "O user marker" "<redacted-user>" "$(printf '%s' "$out" | tail -1)"
    if printf '%s' "$out" | grep -q '/Users/'; then bad "O: /Users fragment survived"; else ok "O: no /Users fragment"; fi
    rm -rf "$d"
    unset HOME_BAK
}

# --------------------------------------------- Driver static invariants (S) --
case_s() {
    local drv="$HERE/verify-device-issue57.sh"
    expect "S: single privacy_bind_device site" 1 \
        "$(grep -c 'privacy_bind_device "\$DEVICE"' "$drv")"
    if grep -n '^IDENT_DEVICE=""' "$drv" >/dev/null 2>&1; then
        bad "S: driver re-initializes IDENT_DEVICE after binding"
    else
        ok "S: no post-bind IDENT_DEVICE reset in driver"
    fi
    if grep -q 'ev() { printf .*RAW_EV' "$drv" && grep -q 'publish_raw_evidence$' "$drv"; then
        ok "S: captures target RAW zone and promotion goes through publish gate"
    else
        bad "S: RAW/publish wiring broken"
    fi
    if grep -q 'discard_unpublished_evidence "\$RAW_EV"' "$drv"; then
        ok "S: cleanup discards unpublished evidence"
    else
        bad "S: cleanup does not discard unpublished evidence"
    fi
}

case_a
case_b
case_c
case_d
case_e
case_o
case_s

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
