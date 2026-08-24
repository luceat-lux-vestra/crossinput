#!/usr/bin/env bash
# One-shot headless wireless-ADB stress driver for issue #62, designed to run
# on the home Mac over SSH against the physically connected SM-G977N + DeX.
#
# Exercises the REAL macOS production delivery path
# (InputSender -> RemoteSession.requestBlocking -> AdbTransport -> helper)
# via the cxi-stress executable; deploy-helper.sh only provisions the helper.
#
# Usage:
#   scripts/verify-device-issue62.sh <revision> [--profile NAME] [--iterations N]
#                                    [--all] [--keep-video-off]
#
#   <revision>        exact SHA/rev under test; must equal `git rev-parse HEAD`.
#                     The script never checks out, merges, or rewrites history.
#   --profile NAME    single workload: baseline|scroll-burst|move-burst|mixed|burst-idle
#   --all             run every workload profile in sequence (default)
#
# Exit codes:
#   0  automated pass - no timeout/genuine-failure observations
#   1  product assertion failure - timeouts or genuine delivery failures observed
#   2  usage / environment / repository-state error
#   3  physical precondition unavailable - no ADB device / DeX display absent
#
# Privacy: evidence carries metadata only (latency samples, outcome taxonomy,
# transport class). Raw adb serials are redacted by scripts/lib/evidence-privacy.sh;
# no pointer deltas, scroll values, key codes, or HID payloads are recorded
# (AGENTS.md rule 4).
set -euo pipefail

EXIT_OK=0
EXIT_FAIL=1
EXIT_USAGE=2
EXIT_PRECONDITION=3

REV=""
PROFILE=""
RUN_ALL=0

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)
            [ -n "${2:-}" ] || { echo "--profile requires a value" >&2; exit "$EXIT_USAGE"; }
            PROFILE="$2"; shift ;;
        --all) RUN_ALL=1 ;;
        --iterations)
            [ -n "${2:-}" ] || { echo "--iterations requires a value" >&2; exit "$EXIT_USAGE"; }
            ITERATIONS="$2"; shift ;;
        -h|--help) usage; exit "$EXIT_OK" ;;
        -*)
            echo "unknown option: $1" >&2
            exit "$EXIT_USAGE"
            ;;
        *)
            if [ -n "$REV" ]; then
                echo "unexpected extra argument: $1" >&2
                exit "$EXIT_USAGE"
            fi
            REV="$1"
            ;;
    esac
    shift
done

if [ -z "$REV" ]; then
    usage >&2
    exit "$EXIT_USAGE"
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "not inside a git repository" >&2
    exit "$EXIT_USAGE"
}
cd "$ROOT"
[ -f scripts/deploy-helper.sh ] && [ -d android/helper ] || {
    echo "not the crossinput repository root: $ROOT" >&2
    exit "$EXIT_USAGE"
}
MACOS_DIR="$ROOT/apps/macos"

for tool in git adb python3 jq swift; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing required tool: $tool" >&2
        exit "$EXIT_USAGE"
    }
done

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/evidence-privacy.sh"
PRIVACY_FAIL_CODE="$EXIT_USAGE"
privacy_init_identifiers

ITERATIONS="${ITERATIONS:-}"

ev() { printf '%s/%s' "$RAW_EV" "$1"; }

REQUESTED_SHA="$(git rev-parse --verify "$REV^{commit}" 2>/dev/null)" || {
    echo "cannot resolve revision: $REV" >&2
    exit "$EXIT_USAGE"
}
HEAD_SHA="$(git rev-parse HEAD)"
if [ "$REQUESTED_SHA" != "$HEAD_SHA" ]; then
    echo "refusing to verify: requested $REQUESTED_SHA but HEAD is $HEAD_SHA" >&2
    echo "check out the exact revision first; this script does not mutate checkout state" >&2
    exit "$EXIT_USAGE"
fi
SHORT_SHA="$(git rev-parse --short "$REQUESTED_SHA")"

if ! git diff --quiet || ! git diff --cached --quiet; then
    if [ "${CROSSINPUT_ALLOW_DIRTY:-0}" != "1" ]; then
        echo "working tree is dirty; commit/stash first or set CROSSINPUT_ALLOW_DIRTY=1" >&2
        exit "$EXIT_USAGE"
    fi
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
TMP_LOCAL="$(mktemp -d /tmp/cxi-stress.XXXXXX)"
EVIDENCE="docs/research/evidence/issue-62-wireless-latency/${TS}-${SHORT_SHA}"
mkdir -p "$EVIDENCE"
RAW_EV="$TMP_LOCAL/raw-evidence"
mkdir -p "$RAW_EV"
PUBLISHED_EVIDENCE=0

cleanup() {
    if [ "$PUBLISHED_EVIDENCE" != "1" ]; then
        discard_unpublished_evidence "$RAW_EV" "$EVIDENCE" "$PUBLISHED_EVIDENCE"
    fi
    rm -rf "$TMP_LOCAL"
}
trap cleanup EXIT

ITERATIONS="${ITERATIONS:-}"

# ------------------------------------------------------- device selection ----
ADB_DEVICES_FILE="$(ev adb-devices.txt)"
adb devices -l | tee "$ADB_DEVICES_FILE"

SERIALS="$(awk '$2 == "device" {print $1}' "$ADB_DEVICES_FILE")"
if [ -n "${ANDROID_SERIAL:-}" ] && grep -qx "${ANDROID_SERIAL}" <<<"$SERIALS"; then
    DEVICE="$ANDROID_SERIAL"
elif [ "$(grep -c . <<<"$SERIALS" || true)" -eq 1 ]; then
    DEVICE="$(grep . <<<"$SERIALS")"
else
    while IFS= read -r serial; do
        [ -z "$serial" ] && continue
        model="$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
        if [ "$model" = "SM-G977N" ] || [ "$model" = "SM_G977N" ]; then
            DEVICE="$serial"
            break
        fi
    done <<<"$SERIALS"
fi
if [ -z "$DEVICE" ]; then
    echo "no usable adb device (set ANDROID_SERIAL to disambiguate)" >&2
    exit "$EXIT_PRECONDITION"
fi
export DEVICE
privacy_bind_device "$DEVICE"

# Wireless transport classification from the serial FORM (work order §9).
case "$DEVICE" in
    *_adb-tls-connect._tcp*) TRANSPORT_CLASS="wireless-mdns-tls" ;;
    *:*.*)                   TRANSPORT_CLASS="wireless-hostport" ;;
    *)                       TRANSPORT_CLASS="usb-or-other" ;;
esac

MODEL="$(adb -s "$DEVICE" shell getprop ro.product.model | tr -d '\r')"
RELEASE="$(adb -s "$DEVICE" shell getprop ro.build.version.release | tr -d '\r')"
SDK="$(adb -s "$DEVICE" shell getprop ro.build.version.sdk | tr -d '\r')"

{
    echo "revision_verified=$REQUESTED_SHA"
    echo "head_at_start=$HEAD_SHA"
    echo "started_utc=$TS"
    echo "host=$(uname -srm)"
    echo "serial=<redacted-adb-serial>"
    echo "transport_class=$TRANSPORT_CLASS"
    echo "device_selector=${ANDROID_SERIAL:+env-android-serial}${ANDROID_SERIAL:-single-or-model-match}"
    echo "model=$MODEL"
    echo "android_release=$RELEASE"
    echo "sdk=$SDK"
    echo "scrcpy_video=OFF (default per work order section 10)"
} >"$(ev metadata.txt)"

if [ "$TRANSPORT_CLASS" = "usb-or-other" ]; then
    if [ "${ALLOW_NON_WIRELESS_DIAGNOSTIC:-0}" != "1" ]; then
        echo "FAIL-CLOSED: selected device is not a wireless ADB endpoint." >&2
        echo "Primary #62 evidence must come from wireless ADB (work order section 2.1)." >&2
        echo "Set ALLOW_NON_WIRELESS_DIAGNOSTIC=1 only for explicit non-gating diagnostics." >&2
        exit "$EXIT_PRECONDITION"
    fi
    echo "transport_expectation=MISMATCH (explicitly allowed as non-gating diagnostic)" >>"$(ev metadata.txt)"
else
    echo "transport_expectation=match ($TRANSPORT_CLASS)" >>"$(ev metadata.txt)"
fi

# ------------------------------------------------------ DeX precondition -----
DEX_DISPLAYS_FILE="$(ev dex-displays.txt)"
adb -s "$DEVICE" exec-out dumpsys display >"$DEX_DISPLAYS_FILE" 2>/dev/null || true
DEX_ID="$(python3 -c '
import re, sys
content = open(sys.argv[1]).read()
ids = sorted({int(m) for m in re.findall(r"mDisplayId=(\d+)", content)})
print(ids[-1] if ids else "")
' "$DEX_DISPLAYS_FILE" 2>/dev/null || true)"
if [ -n "$DEX_ID" ]; then
    echo "dex_display_id=$DEX_ID" >>"$(ev metadata.txt)"
else
    if [ "${ALLOW_NON_WIRELESS_DIAGNOSTIC:-0}" != "1" ]; then
        echo "FAIL-CLOSED: no DeX/desktop display detected (work order section 9)." >&2
        echo "Confirm DeX is active, or set ALLOW_NON_WIRELESS_DIAGNOSTIC=1 for non-gating diagnostics." >&2
        exit "$EXIT_PRECONDITION"
    fi
    echo "dex_display_state=NOT_CONFIRMED (explicitly allowed as non-gating diagnostic)" >>"$(ev metadata.txt)"
fi

# --------------------------------------------------------- build artifacts ---
echo "== building cxi-stress and helper =="
( cd "$MACOS_DIR" && swift build -c debug >/dev/null 2>&1 ) || {
    echo "swift build failed" >&2
    exit "$EXIT_USAGE"
}
STRESS_BIN="$MACOS_DIR/.build/debug/cxi-stress"

scripts/deploy-helper.sh start >/dev/null 2>&1 || {
    echo "helper failed to start" >&2
    exit "$EXIT_PRECONDITION"
}
CLEANUP_HELPER=1
stop_helper() { [ "${CLEANUP_HELPER:-0}" = "1" ] && scripts/deploy-helper.sh stop >/dev/null 2>&1 || true; }

# ------------------------------------------------------------- workloads -----
PROFILES=(baseline scroll-burst move-burst mixed burst-idle queue-pressure)
if [ -n "$PROFILE" ]; then
    case "$PROFILE" in
        baseline|scroll-burst|move-burst|mixed|burst-idle|queue-pressure) PROFILES=("$PROFILE") ;;
        *) echo "unknown profile: $PROFILE" >&2; exit "$EXIT_USAGE" ;;
    esac
fi
[ "$RUN_ALL" = "1" ] && [ -n "$PROFILE" ] && {
    echo "--all and --profile are mutually exclusive" >&2
    exit "$EXIT_USAGE"
}

OVERALL="PASS"
SUMMARY_LINES=()
for p in "${PROFILES[@]}"; do
    echo "== running profile: $p ==" 
    ARGS=(--profile "$p")
    [ -n "$ITERATIONS" ] && ARGS+=(--iterations "$ITERATIONS")

    set +e
    ANDROID_SERIAL="$DEVICE" "$STRESS_BIN" "${ARGS[@]}" --out "$RAW_EV" >"$RAW_EV/$p.stdout" 2>"$RAW_EV/$p.stderr"
    RC=$?
    set -e

    RESULT_FILE="$(ls -t "$RAW_EV"/stress-result-*.json 2>/dev/null | head -1)"
    if [ -n "$RESULT_FILE" ] && [ -f "$RESULT_FILE" ]; then
        mv "$RESULT_FILE" "$(ev latency-$p.json)"
    fi

    TIMEOUTS="$(jq -r '.timeouts // 0' "$(ev latency-$p.json)" 2>/dev/null || echo 0)"
    SUCCESSES="$(jq -r '.successes // 0' "$(ev latency-$p.json)" 2>/dev/null || echo 0)"
    LATE="$(jq -r '.lateResponses // 0' "$(ev latency-$p.json)" 2>/dev/null || echo 0)"

    SUMMARY_LINES+=("$p: rc=$RC requests_success=$SUCCESSES timeouts=$TIMEOUTS late_responses=$LATE")
    echo "   $p: rc=$RC successes=$SUCCESSES timeouts=$TIMEOUTS late=$LATE"

    # rc 3/2 are environment errors -> precondition exit; rc 1 marks product failure
    if [ "$RC" = "3" ] || [ "$RC" = "2" ]; then
        OVERALL="PRECONDITION_NOT_MET"
        stop_helper
        PUBLISHED_EVIDENCE=0
        exit "$EXIT_PRECONDITION"
    elif [ "$RC" != "0" ]; then
        OVERALL="FAIL"
    fi

    # Review gate: a BURST profile that never coalesced did not actually
    # exercise queue accumulation — it was a serialized RTT measurement.
    case "$p" in
        scroll-burst|move-burst)
            COALESCED="$(jq -r '.coalescedIntoExistingBatch // 0' "$(ev latency-$p.json)" 2>/dev/null || echo 0)"
            if [ "${COALESCED:-0}" -le 0 ]; then
                echo "FAIL: $p produced zero coalesced batches — burst did not form" >&2
                OVERALL="FAIL"
            fi
            ;;
        queue-pressure)
            # Review round 2: the profile must produce REAL saturation —
            # at least one locally shed event — while remaining failure-free
            # (local backpressure must never masquerade as transport failure).
            SHED="$(jq -r '.shedLocally // 0' "$(ev latency-$p.json)" 2>/dev/null || echo 0)"
            if [ "${SHED:-0}" -le 0 ]; then
                echo "FAIL: queue-pressure produced zero shed events — no real saturation" >&2
                OVERALL="FAIL"
            fi
            ;;
    esac
done

python3 - "$RAW_EV" <<'PYEOF'
import json, os, sys
raw_ev = sys.argv[1]
summary = {"profiles": {}}
for name in ["baseline", "scroll-burst", "move-burst", "mixed", "burst-idle", "queue-pressure"]:
    path = os.path.join(raw_ev, f"latency-{name}.json")
    if not os.path.exists(path):
        continue
    with open(path) as f:
        data = json.load(f)
    samples = sorted(data.get("latencySamples", []))
    n = len(samples)
    def pct(p):
        if n < 20:
            return None
        rank = max(0, min(n - 1, int((p / 100) * n + 0.999999) - 1))
        return round(samples[rank], 4)
    summary["profiles"][name] = {
        "requests": data.get("requests", 0),
        "successes": data.get("successes", 0),
        "timeouts": data.get("timeouts", 0),
        "timeout_budgets": data.get("timeoutBudgets", []),
        "stream_closed": data.get("streamClosed", 0),
        "write_failed": data.get("writeFailed", 0),
        "unexpected_response": data.get("unexpectedResponse", 0),
        "malformed_response": data.get("malformedResponse", 0),
        "helper_reported_failure": data.get("helperReportedFailure", 0),
        "other_failure": data.get("otherFailure", 0),
        "late_responses": data.get("lateResponses", 0),
        "late_delay_seconds": data.get("lateDelaySeconds", []),
        "count": n,
        "p50": pct(50), "p90": pct(90), "p95": pct(95), "p99": pct(99),
        "max": round(max(samples), 4) if samples else None,
        "over_250ms": sum(1 for s in samples if s > 0.25) if n >= 20 else None,
        "over_500ms": sum(1 for s in samples if s > 0.5) if n >= 20 else None,
        "over_750ms": sum(1 for s in samples if s > 0.75) if n >= 20 else None,
        "over_1000ms": sum(1 for s in samples if s > 1.0) if n >= 20 else None,
        "admission_accepted": data.get("acceptedAsNewBatch", 0),
        "admission_coalesced": data.get("coalescedIntoExistingBatch", 0),
        "admission_shed": data.get("shedLocally", 0),
        "admission_safety_rejected": data.get("safetyRejected", 0),
    }
with open(os.path.join(raw_ev, "latency-summary.json"), "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
PYEOF

{
    echo "ISSUE62_WIRELESS_STRESS"
    echo
    echo "revision: $REQUESTED_SHA"
    echo "device: $MODEL Android $RELEASE (API $SDK); raw adb serial redacted"
    echo "transport_class: $TRANSPORT_CLASS"
    echo "scrcpy/video: OFF"
    echo
    for line in "${SUMMARY_LINES[@]}"; do
        echo "$line"
    done
    echo
    echo "overall: $OVERALL"
} | tee "$(ev result-summary.txt)"

# Publish every metadata-only artifact through the sanitizer into the
# git-bound evidence directory (fail-closed; residual scan on each file).
for f in metadata.txt adb-devices.txt result-summary.txt latency-summary.json; do
    [ -f "$(ev "$f")" ] && publish_sanitized "$(ev "$f")" "$EVIDENCE/$f"
done
for f in "$RAW_EV"/*; do
    case "$(basename "$f")" in
        metadata.txt|adb-devices.txt|result-summary.txt|latency-summary.json) ;;
        latency-*.json|dex-displays.txt|*.stdout) publish_sanitized "$f" "$EVIDENCE/$(basename "$f")" ;;
    esac
done

# Review round 3: the flag is set ONLY after every publication succeeded.
# A mid-loop sanitizer failure exits under set -e with PUBLISHED_EVIDENCE=0,
# so cleanup removes the partial evidence directory wholesale.
PUBLISHED_EVIDENCE=1


if [ "$OVERALL" = "PASS" ]; then
    exit "$EXIT_OK"
else
    exit "$EXIT_FAIL"
fi
