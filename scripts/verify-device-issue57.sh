#!/usr/bin/env bash
# One-shot real-device verification driver for issue #57 (PR #59), designed to
# run on the home Mac over SSH against the physically connected SM-G977N +
# Samsung DeX. Evidence lands under
# docs/research/evidence/issue-57-device-verification/<ts>-<sha>/.
#
# Usage:
#   scripts/verify-device-issue57.sh <revision> [--with-failover] [--skip-video]
#
#   <revision>        exact SHA/rev under test; must equal `git rev-parse HEAD`.
#                     The script never checks out, merges, or rewrites history.
#   --with-failover   add the deterministic mid-session UHID->InputManager
#                     failover scenario. Requires the --fail-uhid-report test
#                     hook in the built helper (auto-detected; otherwise the
#                     item is recorded NOT_RUN, never failed silently).
#   --skip-video      do not attempt the scrcpy DeX-display recording.
#
# Environment:
#   ANDROID_SERIAL            deterministic ADB selection when several are up.
#   CROSSINPUT_ALLOW_DIRTY=1  permit a dirty working tree (recorded in evidence).
#
# Exit codes:
#   0  PASS or AUTOMATED_PASS_PHYSICAL_VISUAL_PENDING
#   1  FAIL - at least one automatable assertion failed
#   2  usage / environment / repository-state error
#   3  PRECONDITION_NOT_MET - e.g. DeX inactive (not a product-code failure)
#
# Privacy: evidence carries protocol/backend metadata only - never keystrokes,
# clipboard contents, or HID/input payloads (AGENTS.md rule 4). getevent
# capture is time-bounded and filtered to the Ampersand virtual device node.
set -euo pipefail

EXIT_OK=0
EXIT_FAIL=1
EXIT_USAGE=2
EXIT_PRECONDITION=3

REV=""
WITH_FAILOVER=0
SKIP_VIDEO=0

usage() {
    sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --with-failover) WITH_FAILOVER=1 ;;
        --skip-video) SKIP_VIDEO=1 ;;
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

for tool in git adb python3 jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing required tool: $tool" >&2
        exit "$EXIT_USAGE"
    }
done

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
BRANCH="$(git branch --show-current)"
[ -n "$BRANCH" ] || BRANCH="(detached:$(git rev-parse --short HEAD))"
SHORT_SHA="$(git rev-parse --short "$REQUESTED_SHA")"

if ! git diff --quiet || ! git diff --cached --quiet; then
    if [ "${CROSSINPUT_ALLOW_DIRTY:-0}" != "1" ]; then
        echo "working tree is dirty; commit/stash first or set CROSSINPUT_ALLOW_DIRTY=1" >&2
        exit "$EXIT_USAGE"
    fi
    DIRTY=1
else
    DIRTY=0
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="docs/research/evidence/issue-57-device-verification/${TS}-${SHORT_SHA}"
mkdir -p "$EVIDENCE"

declare -a RESULTS_ORDER=(
    auto_uhid_selection
    first_move_after_select
    uhid_device_registration
    pointer_result_smoke
    forced_uhid
    forced_input_manager
    four_direction_protocol_semantics
    clean_shutdown
    visible_pointer_motion
    idle_pointer_reappearance
    visual_scroll_direction
    full_edge_handoff_return
    mid_session_physical_failover
)
# Results/notes live in per-key dynamic variables (RESULT_<key>/NOTE_<key>)
# instead of associative arrays so the driver also runs under macOS's stock
# bash 3.2.
for key in "${RESULTS_ORDER[@]}"; do
    printf -v "RESULT_$key" '%s' "NOT_RUN"
    printf -v "NOTE_$key" '%s' ""
done
OVERALL="NOT_SET"
SHUTDOWN_FAILURES=0
SESSIONS_STOPPED=0
FOURDIR_UHID_PROBE="none"

record() { # record <key> <status> [note]
    local result_var="RESULT_$1" note_var="NOTE_$1"
    printf -v "$result_var" '%s' "$2"
    if [ -n "${3:-}" ]; then
        printf -v "$note_var" '%s' "$3"
    fi
    echo "[result] $1=$(eval "printf '%s' \"\$$result_var\"")${3:+ ($3)}"
}

result_of() { # result_of <key> → prints current status
    eval "printf '%s' \"\$RESULT_$1\""
}

note() { # note <key> <text> — append evidence note for a check
    local note_var="NOTE_$1" current
    current="$(eval "printf '%s' \"\$$note_var\"")"
    printf -v "$note_var" '%s' "${current:+$current; }$2"
}

ev() { printf '%s/%s' "$EVIDENCE" "$1"; }

TMP_LOCAL="$(mktemp -d /tmp/cxi-verify.XXXXXX)"
SCRCPLY_PID=""
GETEVENT_PID=""
DEVICE=""
DEX_ID=""

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [ -n "$GETEVENT_PID" ]; then
        kill "$GETEVENT_PID" 2>/dev/null || true
        wait "$GETEVENT_PID" 2>/dev/null || true
    fi
    if [ -n "$SCRCPLY_PID" ]; then
        kill "$SCRCPLY_PID" 2>/dev/null || true
    fi
    if [ -n "$DEVICE" ]; then
        adb -s "$DEVICE" shell \
            "pkill -f 'crossinput-[h]elper.apk' 2>/dev/null; pkill -f 'cxi-[h]elper-stdin' 2>/dev/null; rm -f /data/local/tmp/cxi-helper-stdin /data/local/tmp/cxi-helper-stdout.bin /data/local/tmp/cxi-helper.log" \
            >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_LOCAL"
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------ CXI codec ----
CXI="$TMP_LOCAL/cxi.py"
cat >"$CXI" <<'PYEOF'
import io
import json
import struct
import sys

MAGIC = b"CXI"
TYPES = {
    0x0001: "HELLO", 0x0002: "LIST_DISPLAYS", 0x0003: "SELECT_DISPLAY",
    0x0004: "CREATE_HID_DEVICE", 0x0007: "PING", 0x0008: "SHUTDOWN",
    0x0009: "POINTER_MOVE_REL", 0x000A: "POINTER_BUTTON",
    0x000B: "POINTER_SCROLL", 0x000C: "KEY_EVENT",
    0x8001: "HELLO_ACK", 0x8002: "DISPLAY_LIST", 0x8003: "DISPLAY_CHANGED",
    0x8006: "PONG", 0x8007: "LOG_EVENT", 0x8008: "FATAL_ERROR",
    0x8009: "POINTER_RESULT",
}
NAMES = {v: k for k, v in TYPES.items()}


def rd(bb, n):
    return bb.read(n)


def i32(bb):
    return struct.unpack("<i", rd(bb, 4))[0]


def le_str(bb):
    return rd(bb, i32(bb)).decode("utf-8", "replace")


def le_display(bb):
    d = {
        "displayId": i32(bb),
        "type": rd(bb, 1)[0],
        "flags": i32(bb),
        "state": rd(bb, 1)[0],
        "width": i32(bb),
        "height": i32(bb),
        "densityDpi": i32(bb),
        "rotation": rd(bb, 1)[0],
    }
    d["name"] = le_str(bb)
    d["uniqueId"] = le_str(bb)
    d["layerStack"] = i32(bb)
    return d


def main():
    cmd = sys.argv[1]

    if cmd == "build":
        name, reqid = sys.argv[2], int(sys.argv[3])
        args = sys.argv[4:]
        payload = b""
        if name == "POINTER_MOVE_REL":
            payload = struct.pack("<ii", int(args[0]), int(args[1]))
        elif name == "POINTER_BUTTON":
            payload = struct.pack("<IB", int(args[0]), 1 if args[1] == "down" else 0)
        elif name == "POINTER_SCROLL":
            payload = struct.pack("<ff", float(args[0]), float(args[1]))
        elif name == "SELECT_DISPLAY":
            payload = struct.pack("<i", int(args[0]))
        elif name == "HELLO":
            payload = struct.pack("<H", 1)
        elif name not in ("LIST_DISPLAYS", "SHUTDOWN"):
            raise SystemExit(f"unknown frame: {name}")
        frame = MAGIC + struct.pack("<HHII", 1, NAMES[name], reqid, len(payload)) + payload
        sys.stdout.write(frame.hex())

    elif cmd == "frames":
        data = open(sys.argv[2], "rb").read()
        off = 0
        while off + 15 <= len(data):
            if data[off:off + 3] != MAGIC:
                off += 1
                continue
            ver, t, reqid, plen = struct.unpack_from("<HHII", data, off + 3)
            if ver != 1 or t not in TYPES or off + 15 + plen > len(data):
                off += 1
                continue
            payload = data[off + 15:off + 15 + plen]
            off += 15 + plen
            rec = {"type": TYPES[t], "reqid": reqid}
            try:
                if t == 0x8009 and len(payload) >= 9:
                    status, dx, dy = struct.unpack("<Bii", payload[:9])
                    rec.update(status=status, dx=dx, dy=dy)
                elif t == 0x8001 and len(payload) >= 6:
                    v, caps = struct.unpack("<Hi", payload[:6])
                    rec.update(version=v, capabilities=caps)
                elif t == 0x8002 and len(payload) >= 4:
                    count = struct.unpack_from("<i", payload)[0]
                    bb = io.BytesIO(payload[4:])
                    rec["displays"] = [le_display(bb) for _ in range(count)]
                elif t == 0x8003 and len(payload) >= 27:
                    rec["display"] = le_display(io.BytesIO(payload))
                elif t == 0x8007 and len(payload) >= 9:
                    bb = io.BytesIO(payload)
                    level = min(rd(bb, 1)[0], 3)
                    tag = le_str(bb)
                    msg = le_str(bb)
                    rec.update(level=["debug", "info", "warn", "error"][level], tag=tag, message=msg)
                elif t == 0x8008 and len(payload) >= 8:
                    rec.update(code=struct.unpack_from("<i", payload)[0],
                               message=payload[8:].decode("utf-8", "replace"))
            except Exception as exc:  # malformed tail must not abort the scan
                rec["decode_error"] = str(exc)
            print(json.dumps(rec))

    elif cmd == "getevent":
        REL = {0x00: "REL_X", 0x01: "REL_Y", 0x06: "REL_HWHEEL", 0x08: "REL_WHEEL"}
        KEY = {0x110: "BTN_LEFT", 0x111: "BTN_RIGHT", 0x112: "BTN_MIDDLE"}
        counts = {}
        for line in open(sys.argv[2]):
            fields = line.split()
            # Single-node captures print "type code value"; multi-device
            # output prefixes "/dev/input/eventN:".
            if len(fields) == 4 and fields[0].startswith("/dev/input/event"):
                fields = fields[1:]
            if len(fields) != 3:
                continue
            try:
                label = KEY.get(int(fields[1], 16)) or REL.get(int(fields[1], 16))
            except ValueError:
                continue
            if label is None:
                continue
            value = int(fields[2], 16)
            if value >= 2 ** 31:
                value -= 2 ** 32
            key = f"{label}{value:+d}" if label.startswith("REL") else f"{label}_{value}"
            counts[key] = counts.get(key, 0) + 1
        print(json.dumps(counts, sort_keys=True))

    else:
        raise SystemExit(f"unknown command: {cmd}")


main()
PYEOF

frame_hex() { python3 "$CXI" build "$@"; }
parse_frames() { python3 "$CXI" frames "$1"; }

pull_stdout() {
    # One-shot full snapshot; only safe once the helper has exited/quiesced.
    adb -s "$DEVICE" exec-out cat /data/local/tmp/cxi-helper-stdout.bin >"$1" 2>/dev/null || true
}

# stream_pull <master-file>: incrementally append newly written helper stdout
# using a persisted byte offset. Plain repeated `cat` snapshots race the
# growing file (torn/partial frames), and rename-based snapshots detach from
# the inode the helper keeps writing to — both starve live frame detection.
stream_pull() {
    local master="$1" remote_size off
    remote_size="$(adb -s "$DEVICE" shell "wc -c </data/local/tmp/cxi-helper-stdout.bin" 2>/dev/null | tr -dc '0-9')"
    [ -n "$remote_size" ] || return 0
    off="$(cat "$master.off" 2>/dev/null || printf '0')"
    case "$off" in '' | *[!0-9]*) off=0 ;;
    esac
    if [ "$remote_size" -lt "$off" ]; then
        off=0  # helper restarted; file was recreated
        : >"$master"
    fi
    if [ "$remote_size" -gt "$off" ]; then
        adb -s "$DEVICE" exec-out \
            "dd if=/data/local/tmp/cxi-helper-stdout.bin bs=1 skip=$off count=$((remote_size - off)) 2>/dev/null" \
            >>"$master" 2>/dev/null || true
        printf '%s\n' "$remote_size" >"$master.off"
    fi
}
pull_log_file() { adb -s "$DEVICE" exec-out cat /data/local/tmp/cxi-helper.log >"$1" 2>/dev/null || true; }
send_hex() { scripts/deploy-helper.sh send "$1" >/dev/null; }

wait_frame() { # wait_frame <stdout-file> <type-name> <reqid> <timeout-s>
    local file="$1" type_name="$2" reqid="$3" timeout_s="$4" deadline match polls=0
    deadline=$((SECONDS + timeout_s))
    while (( SECONDS < deadline )); do
        polls=$((polls + 1))
        stream_pull "$file"
        match="$(parse_frames "$file" 2>/dev/null | jq -ce --arg t "$type_name" --arg r "$reqid" \
            'select(.type==$t and (.reqid|tostring)==$r)' 2>/dev/null | head -n1 || true)"
        if [ -n "${VERIFY_DEBUG:-}" ]; then
            echo "[dbg wait_frame $type_name/$reqid] poll#$polls master=$(wc -c <"$file" 2>/dev/null) off=$(cat "$file.off" 2>/dev/null) match=${match:+yes}" >&2
        fi
        if [ -n "$match" ]; then
            printf '%s\n' "$match"
            return 0
        fi
        sleep 0.5
    done
    return 1
}

helper_alive() {
    # Wireless ADB can transiently return empty ps output while other
    # transports (e.g. scrcpy video) saturate the link; retry before
    # concluding the helper died.
    local try
    for try in 1 2 3; do
        if [ -n "$(adb -s "$DEVICE" shell "ps -A -o PID,ARGS" 2>/dev/null |
            awk '$2 == "app_process" && $0 ~ /crossinput-helper\.apk/ {print $1; exit}')" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

start_session() { # start_session <backend-token>
    POINTER_BACKEND="$1" scripts/deploy-helper.sh start 2>&1 |
        tee "$TMP_LOCAL/session-start-$1.log" >/dev/null
}

stop_helper() { scripts/deploy-helper.sh stop; }

# --------------------------------------------------------- evidence init ----
{
    echo "revision_requested=$REV"
    echo "revision_verified=$REQUESTED_SHA"
    echo "head_at_start=$HEAD_SHA"
    echo "branch=$BRANCH"
    echo "working_tree_dirty=$DIRTY"
    echo "started_utc=$TS"
    echo "host=$(uname -srm)"
    echo "with_failover=$WITH_FAILOVER"
    echo "skip_video=$SKIP_VIDEO"
} >"$(ev metadata.txt)"

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
    echo "no single usable adb device (set ANDROID_SERIAL to disambiguate)" >&2
    exit "$EXIT_USAGE"
fi
export DEVICE

MODEL="$(adb -s "$DEVICE" shell getprop ro.product.model | tr -d '\r')"
RELEASE="$(adb -s "$DEVICE" shell getprop ro.build.version.release | tr -d '\r')"
SDK="$(adb -s "$DEVICE" shell getprop ro.build.version.sdk | tr -d '\r')"
{
    echo "serial=$DEVICE"
    echo "model=$MODEL"
    echo "android_release=$RELEASE"
    echo "sdk=$SDK"
    if [ "$MODEL" != "SM-G977N" ] && [ "$MODEL" != "SM_G977N" ]; then
        echo "model_expectation=MISMATCH (expected SM-G977N lab rig; continuing, non-gating)"
    fi
    if [ "$SDK" != "31" ]; then
        echo "sdk_expectation=MISMATCH (expected API 31 lab rig; continuing, non-gating)"
    fi
} >>"$(ev metadata.txt)"

adb -s "$DEVICE" exec-out dumpsys display >"$(ev dumpsys-display.txt)"

# The home Mac default JVM may be newer than this project's Kotlin compiler
# supports; prefer an explicit 17 like CI (temurin 17).
if ! { [ -n "${JAVA_HOME:-}" ] && "$JAVA_HOME/bin/java" -version 2>&1 | grep -q '"17\.'; }; then
    for candidate in "$HOME"/.sdkman/candidates/java/17* /Library/Java/JavaVirtualMachines/*/Contents/Home; do
        if [ -x "$candidate/bin/java" ] && "$candidate/bin/java" -version 2>&1 | grep -q '"17\.'; then
            export JAVA_HOME="$candidate"
            break
        fi
    done
fi
echo "java_home=${JAVA_HOME:-default}" >>"$(ev metadata.txt)"

finish_summary() {
    {
        echo "ISSUE57_DEVICE_VERIFY"
        echo
        echo "revision: $REQUESTED_SHA"
        echo "device: $MODEL ($DEVICE)"
        echo "dex_display_id: ${DEX_ID:-unknown}"
        echo
        for key in "${RESULTS_ORDER[@]}"; do
            echo "$key: $(result_of "$key")"
        done
        echo
        echo "overall: $OVERALL"
    } | tee "$(ev result-summary.txt)"

    {
        echo "# Issue #57 device verification - ${TS}-${SHORT_SHA}"
        echo
        echo "- revision: \`$REQUESTED_SHA\` (requested: \`$REV\`, HEAD at start: \`$HEAD_SHA\`)"
        echo "- device: $MODEL serial=$DEVICE Android $RELEASE (API $SDK)"
        echo "- dex display id: ${DEX_ID:-unknown}"
        echo "- started (UTC): $TS"
        echo "- overall: **$OVERALL**"
        echo
        echo "| check | result | notes |"
        echo "|---|---|---|"
        for key in "${RESULTS_ORDER[@]}"; do
            echo "| $key | $(result_of "$key") | $(eval "printf '%s' \"\$NOTE_$key\"") |"
        done
        echo
        echo "MANUAL_REQUIRED items require human confirmation on the physical DeX"
        echo "screen and are never collapsed into PASS. NOT_RUN items carry the"
        echo "reason in the notes column."
    } >"$(ev result.md)"

    case "$OVERALL" in
        PASS | AUTOMATED_PASS_PHYSICAL_VISUAL_PENDING) exit "$EXIT_OK" ;;
        PRECONDITION_NOT_MET) exit "$EXIT_PRECONDITION" ;;
        *) exit "$EXIT_FAIL" ;;
    esac
}

# ------------------------------------------------------- DeX discovery core ---
# classify_desktop <stdout-file>: fills DEX_ID only when exactly one desktop-
# classified display exists (type==7 or FLAG_DESKTOP bit 0x40).
classify_desktop() {
    local file="$1" count
    parse_frames "$file" | jq -r 'select(.type=="DISPLAY_LIST") | .displays[] |
        select((.type==7)
            or (((.flags // 0) / 64 | floor) % 2 == 1)
            or ((.name // "") == "Desktop")
            or ((.uniqueId // "") | contains(",Desktop,"))) |
        "\(.displayId)|state=\(.state)|\(.width)x\(.height)|\(.name)|\(.uniqueId)"' \
        >"$TMP_LOCAL/desktop-candidates.txt" 2>/dev/null || true
    count="$(grep -c . "$TMP_LOCAL/desktop-candidates.txt" || true)"
    if [ "$count" -eq 1 ]; then
        DEX_ID="$(cut -d'|' -f1 "$TMP_LOCAL/desktop-candidates.txt")"
    fi
}

# session_hello_list <stdout-file> <base-reqid>: start handshake + DISPLAY_LIST.
session_hello_list() {
    local file="$1"
    local base="$2"
    send_hex "$(frame_hex HELLO "$base")" || return 1
    wait_frame "$file" HELLO_ACK "$base" 30 >/dev/null || return 1
    send_hex "$(frame_hex LIST_DISPLAYS $((base + 1)))" || return 1
    wait_frame "$file" DISPLAY_LIST $((base + 1)) 30 >/dev/null || return 1
    return 0
}

assert_dex_still_present() { # <stdout-file>
    parse_frames "$1" 2>/dev/null | jq -ce --arg id "$DEX_ID" \
        'select(.type=="DISPLAY_LIST") | .displays[] | select((.displayId|tostring)==$id)' \
        >/dev/null 2>&1
}

# ------------------------------------------------- UHID registration probe ----
find_uhid_event_node() {
    adb -s "$DEVICE" shell getevent -pl 2>/dev/null | awk '
        /add device/ { node = $NF }
        /name:/ { sub(/\r$/, ""); gsub(/"/, ""); if ($0 ~ /Ampersand Mouse/) { print node; exit } }'
}

capture_uhid_input() { # capture_uhid_input <outfile> <seconds>
    local outfile="$1" seconds="$2" node
    node="$(find_uhid_event_node)"
    if [ -z "$node" ]; then
        return 1
    fi
    # Bounded on both ends: device-side `timeout` plus a locally tracked pid.
    adb -s "$DEVICE" shell "timeout $seconds getevent $node" >"$outfile" 2>/dev/null &
    GETEVENT_PID=$!
    return 0
}

end_uhid_capture() {
    if [ -n "$GETEVENT_PID" ]; then
        wait "$GETEVENT_PID" 2>/dev/null || true
        GETEVENT_PID=""
    fi
}

record_dumpsys_input() { # <outfile> ; also prints registration metadata line
    adb -s "$DEVICE" shell dumpsys input >"$1"
    grep -i -B2 -A6 "Ampersand Mouse" "$1" | head -40 || true
}

# --------------------------------------------------------- pointer sequence ---
# smoke_pointer_sequence <stdout-file> <base-reqid>: full semantic sweep; each
# request gets a unique id and must come back POINTER_RESULT status=0.
smoke_pointer_sequence() {
    local file="$1"
    local base="$2"
    local rid="$base"
    local -a reqs=()
    local req

    send_req() { send_hex "$(frame_hex "$1" "$rid" "${@:2}")" && reqs+=("$rid"); }

    send_req POINTER_MOVE_REL 25 15; rid=$((rid + 1))
    sleep 0.6
    send_req POINTER_MOVE_REL -25 -20; rid=$((rid + 1))
    sleep 0.6
    send_req POINTER_BUTTON 0 down; rid=$((rid + 1))
    sleep 0.6
    send_req POINTER_BUTTON 0 up; rid=$((rid + 1))
    sleep 0.6
    send_req POINTER_BUTTON 1 down; rid=$((rid + 1))
    sleep 0.6
    send_req POINTER_BUTTON 1 up; rid=$((rid + 1))
    sleep 0.6
    send_req POINTER_BUTTON 2 down; rid=$((rid + 1))
    sleep 0.6
    send_req POINTER_BUTTON 2 up; rid=$((rid + 1))
    sleep 0.6
    # Four-direction scroll (CXI contract: +v up / -v down / +h left / -h right)
    send_req POINTER_SCROLL 0 1; rid=$((rid + 1))
    sleep 0.4
    send_req POINTER_SCROLL 0 -1; rid=$((rid + 1))
    sleep 0.4
    send_req POINTER_SCROLL 1 0; rid=$((rid + 1))
    sleep 0.4
    send_req POINTER_SCROLL -1 0; rid=$((rid + 1))
    sleep 1.5

    stream_pull "$file"
    for req in "${reqs[@]}"; do
        local result
        result="$(jq -ce --arg r "$req" 'select(.type=="POINTER_RESULT" and (.reqid|tostring)==$r)' \
            <(parse_frames "$file" 2>/dev/null) 2>/dev/null | head -n1 || true)"
        [ -n "$result" ] || { echo "request $req: NO_POINTER_RESULT"; return 1; }
        [ "$(jq -r '.status' <<<"$result" 2>/dev/null)" = "0" ] ||
            { echo "request $req: status=$(jq -r '.status' <<<"$result" 2>/dev/null)"; return 1; }
    done
    echo "all ${#reqs[@]} pointer requests delivered (status=0)"
    return 0
}

assert_scroll_directions_in_getevent() { # <getevent-outfile>
    python3 "$CXI" getevent "$1"
}

# four_scroll_probe <stdout-file> <base-reqid>: isolated four-direction scroll
# contract check (+v up / -v down / +h left / -h right); returns 0 iff all four
# POINTER_RESULTs are delivered.
four_scroll_probe() {
    local file="$1" rid="$2" i h v req
    local -a sent=()
    for i in 1 2 3 4; do
        case "$i" in
            1) h=0; v=1 ;;
            2) h=0; v=-1 ;;
            3) h=1; v=0 ;;
            4) h=-1; v=0 ;;
        esac
        local hex
        hex="$(frame_hex POINTER_SCROLL "$rid" "$h" "$v")"
        if ! send_hex "$hex"; then
            [ -n "${VERIFY_DEBUG:-}" ] && echo "[dbg probe] send#1 failed rid=$rid" >&2
            sleep 1
            send_hex "$hex" || { [ -n "${VERIFY_DEBUG:-}" ] && echo "[dbg probe] send#2 failed rid=$rid" >&2; return 1; }
        fi
        sent+=("$rid")
        rid=$((rid + 1))
        sleep 0.5
    done
    # Wait for the four results to land in the master stream.
    local waited=0 missing=0 req
    while :; do
        missing=0
        for req in "${sent[@]}"; do
            parse_frames "$file" 2>/dev/null |
                jq -ce --arg r "$req" \
                    'select(.type=="POINTER_RESULT" and (.reqid|tostring)==$r and .status==0)' \
                    >/dev/null 2>&1 ||
                { parse_frames "$file" 2>/dev/null |
                    jq -ce --arg r "$req" \
                        'select(.type=="POINTER_RESULT" and (.reqid|tostring)==$r)' \
                        >/dev/null 2>&1 || missing=$((missing + 1)); }
        done
        [ -n "${VERIFY_DEBUG:-}" ] && echo "[dbg probe] waited=$waited missing=$missing master=$(wc -c <"$file" 2>/dev/null)" >&2
        [ "$missing" -eq 0 ] && return 0
        if (( waited >= 16 )); then return 1; fi
        stream_pull "$file"
        waited=$((waited + 1))
        sleep 0.5
    done
}
echo "== building helper APK"
if ! scripts/deploy-helper.sh build >"$TMP_LOCAL/build.log" 2>&1; then
    tail -40 "$TMP_LOCAL/build.log" >&2
    record clean_shutdown FAIL "helper build failed before any session"
    OVERALL="FAIL"
    finish_summary
fi

APK="android/helper/app/build/outputs/apk/debug/app-debug.apk"
FAILOVER_SUPPORTED=0
if command -v unzip >/dev/null 2>&1 &&
    unzip -p "$APK" 'classes*.dex' 2>/dev/null | LC_ALL=C grep -aq "fail-uhid-report"; then
    FAILOVER_SUPPORTED=1
fi
echo "failover_hook_present=$FAILOVER_SUPPORTED" >>"$(ev metadata.txt)"

# ============================================================ session: AUTO ===
echo "== probe session: DeX discovery (POINTER_BACKEND=auto)"
STDOUT="$TMP_LOCAL/auto-stdout.bin"
: >"$STDOUT"; : >"$STDOUT.off"
if ! start_session auto; then
    echo "helper failed to start (probe)" >&2
    cat "$TMP_LOCAL/session-start-auto.log" >&2 || true
    record auto_uhid_selection FAIL "helper failed to start"
    OVERALL="FAIL"
    finish_summary
fi
session_hello_list "$STDOUT" 1000 || {
    echo "HELLO/LIST handshake failed" >&2
    pull_log_file "$(ev auto-helper.log)"
    record auto_uhid_selection FAIL "no HELLO_ACK/DISPLAY_LIST"
    OVERALL="FAIL"
    finish_summary
}
stream_pull "$STDOUT"
classify_desktop "$STDOUT"
if [ -z "$DEX_ID" ]; then
    parse_frames "$STDOUT" 2>/dev/null | jq -r 'select(.type=="DISPLAY_LIST") | .displays[]' 2>/dev/null \
        >"$(ev display-selection.txt)" || true
    record auto_uhid_selection SKIP \
        "no unambiguous Desktop-classified display in DISPLAY_LIST (DeX inactive?)"
    OVERALL="PRECONDITION_NOT_MET"
    echo "PRECONDITION NOT MET: DeX does not appear active; not a product-code failure." >&2
    scripts/deploy-helper.sh stop >/dev/null 2>&1 || true
    finish_summary
fi
DEX_DESC="$(grep "^${DEX_ID}|" "$TMP_LOCAL/desktop-candidates.txt" || true)"
{
    echo "selected_dex_display_id=$DEX_ID ($DEX_DESC)"
    echo "selection_rule=DISPLAY_LIST entry with type==7, FLAG_DESKTOP(0x40), name==Desktop, or uniqueId containing ',Desktop,'; exactly one candidate required (AGENTS.md rule 3: dynamic discovery, documented rule)"
    echo "-- all desktop candidates --"
    cat "$TMP_LOCAL/desktop-candidates.txt"
    echo "-- all displays --"
} >"$(ev display-selection.txt)"
parse_frames "$STDOUT" 2>/dev/null | jq -r 'select(.type=="DISPLAY_LIST") | .displays[]' 2>/dev/null \
    >>"$(ev display-selection.txt)" || true
echo "DeX display selected: $DEX_ID ($DEX_DESC)"
scripts/deploy-helper.sh stop >/dev/null 2>&1 || true

VIDEO_FILE="$(ev screen-recording-auto.mp4)"
VIDEO_ACTIVE=0
if [ "$SKIP_VIDEO" != "1" ] && command -v scrcpy >/dev/null 2>&1; then
    echo "== starting scrcpy DeX-display recording (display $DEX_ID)"
    # Options verified against installed scrcpy 4.1: --display-id, --no-window,
    # --no-control, --no-audio, --time-limit, --record.
    scrcpy -s "$DEVICE" --display-id="$DEX_ID" --no-window --no-control --no-audio \
        --time-limit=180 --record="$VIDEO_FILE" >"$TMP_LOCAL/scrcpy.log" 2>&1 &
    SCRCPLY_PID=$!
    sleep 6
    if kill -0 "$SCRCPLY_PID" 2>/dev/null; then
        VIDEO_ACTIVE=1
    else
        echo "scrcpy exited early; continuing without video" >&2
        tail -5 "$TMP_LOCAL/scrcpy.log" >&2 || true
        SCRCPLY_PID=""
    fi
fi

echo "== session AUTO: backend selection + first-move race + smoke"
: >"$STDOUT"; : >"$STDOUT.off"
if ! start_session auto; then
    record auto_uhid_selection FAIL "helper failed to start (main)"
    OVERALL="FAIL"
    finish_summary
fi

AUTO_OK=1
session_hello_list "$STDOUT" 1050 || AUTO_OK=0

if [ "$AUTO_OK" = "1" ]; then
    stream_pull "$STDOUT"
    if ! assert_dex_still_present "$STDOUT"; then
        record auto_uhid_selection FAIL "selected display $DEX_ID vanished before selection"
        AUTO_OK=0
    fi
fi

if [ "$AUTO_OK" = "1" ]; then
    # SELECT_DISPLAY followed IMMEDIATELY by the first move: issue #57 race.
    send_hex "$(frame_hex SELECT_DISPLAY 1052 "$DEX_ID")"
    send_hex "$(frame_hex POINTER_MOVE_REL 1053 30 20)"
    FIRST_RESULT="$(wait_frame "$STDOUT" POINTER_RESULT 1053 15 || true)"
    pull_log_file "$(ev auto-helper.log)"

    # Backend-marker verdict is evaluated independently of delivery so a
    # wrong AUTO selection is reported even when the move itself succeeds.
    if grep -Eq "pointer backend selected backend=uhid mode=auto" "$(ev auto-helper.log)" &&
        grep -Eq "routing=system" "$(ev auto-helper.log)" &&
        ! grep -q "failover" "$(ev auto-helper.log)"; then
        record auto_uhid_selection PASS "backend=uhid routing=system target=$DEX_ID"
    else
        SELECTED_LINE="$(grep 'pointer backend selected' "$(ev auto-helper.log)" | tail -1 | sed 's/^\[[^]]*\] //' || true)"
        record auto_uhid_selection FAIL \
            "expected backend=uhid routing=system; helper reported: ${SELECTED_LINE:-<none>}"
        AUTO_OK=0
    fi

    FIRST_STATUS="$(jq -r '.status' <<<"$FIRST_RESULT" 2>/dev/null || true)"
    if [ -n "${VERIFY_DEBUG:-}" ]; then
        echo "[dbg first_move] result_bytes=${#FIRST_RESULT} status='${FIRST_STATUS}' raw=${FIRST_RESULT:0:120}" >&2
    fi
    if [ -n "$FIRST_RESULT" ] && [ "$FIRST_STATUS" = "0" ]; then
        record first_move_after_select PASS "POINTER_RESULT delivered immediately after SELECT_DISPLAY"
        if ! helper_alive; then
            note first_move_after_select "helper_alive probe inconclusive under adb load (frame was delivered)"
        fi
    else
        record first_move_after_select FAIL \
            "no POINTER_RESULT(reqid=1053,status=0) within 15s of SELECT_DISPLAY"
        AUTO_OK=0
    fi
else
    pull_log_file "$(ev auto-helper.log)"
    record auto_uhid_selection FAIL "handshake/list failed in main AUTO session"
fi

UHID_NODE=""
GETEVENT_STARTED=0
if [ "$AUTO_OK" = "1" ]; then
    adb -s "$DEVICE" exec-out dumpsys input >"$(ev dumpsys-input.txt)"
    REG_EXCERPT="$(grep -i -B2 -A6 "Ampersand Mouse" "$(ev dumpsys-input.txt)" | head -20 || true)"
    UHID_NODE="$(find_uhid_event_node)"
    if [ -n "$REG_EXCERPT" ] && [ -n "$UHID_NODE" ]; then
        {
            echo "# Ampersand Mouse registration metadata (dumpsys input excerpt)"
            echo "$REG_EXCERPT"
            echo "# event node: $UHID_NODE"
        } >>"$(ev dumpsys-input.txt)"
        record uhid_device_registration PASS "dumpsys input + getevent -pl ($UHID_NODE)"
    elif [ -n "$REG_EXCERPT" ]; then
        record uhid_device_registration PASS "dumpsys input shows Ampersand Mouse (event node not listed by getevent -pl)"
    else
        record uhid_device_registration FAIL "Ampersand Mouse absent from dumpsys input"
        AUTO_OK=0
    fi

    if capture_uhid_input "$(ev getevent-uhid.txt)" 14; then
        GETEVENT_STARTED=1
    fi
    if ! SMOKE_OUT="$(smoke_pointer_sequence "$STDOUT" 1060)"; then
        record pointer_result_smoke FAIL "$SMOKE_OUT"
        AUTO_OK=0
    else
        record pointer_result_smoke PASS "$SMOKE_OUT"
    fi
    sleep 2
    end_uhid_capture
fi

if [ "$AUTO_OK" = "1" ]; then
    # Idle-fade window for human/video reappearance review (issue #57).
    send_hex "$(frame_hex POINTER_MOVE_REL 1080 10 10)" || true
    echo "idle window starts $(date -u +%H:%M:%SZ)"
    sleep 14
    IDLE_TAIL_OK=1
    send_hex "$(frame_hex POINTER_MOVE_REL 1081 -10 -10)" || IDLE_TAIL_OK=0
    send_hex "$(frame_hex POINTER_MOVE_REL 1082 15 -5)" || IDLE_TAIL_OK=0
    sleep 1
    stream_pull "$STDOUT"
    for rid in 1081 1082; do
        jq -ce --arg r "$rid" 'select(.type=="POINTER_RESULT" and (.reqid|tostring)==$r and .status==0)' \
            <(parse_frames "$STDOUT" 2>/dev/null) >/dev/null 2>&1 || IDLE_TAIL_OK=0
    done
    if [ "$IDLE_TAIL_OK" = "1" ]; then
        note idle_pointer_reappearance "post-idle moves delivered (protocol level); visibility needs screen/video confirmation"
    else
        note idle_pointer_reappearance "post-idle delivery incomplete"
    fi
fi

pull_stdout "$STDOUT"
parse_frames "$STDOUT" >"$(ev auto-protocol.txt)"
pull_log_file "$(ev auto-helper.log)"

STOP_OK=1
scripts/deploy-helper.sh stop >"$TMP_LOCAL/auto-stop.log" 2>&1 || STOP_OK=0
grep -q "graceful shutdown complete" "$TMP_LOCAL/auto-stop.log" || STOP_OK=0
SESSIONS_STOPPED=$((SESSIONS_STOPPED + 1))
if [ "$STOP_OK" != "1" ]; then
    SHUTDOWN_FAILURES=$((SHUTDOWN_FAILURES + 1))
    note clean_shutdown "AUTO session stop not graceful"
fi

if [ -n "$SCRCPLY_PID" ]; then
    kill "$SCRCPLY_PID" 2>/dev/null || true
    wait "$SCRCPLY_PID" 2>/dev/null || true
    SCRCPLY_PID=""
fi
VIDEO_NOTE="recording unavailable"
if [ -f "$VIDEO_FILE" ] && [ "$(wc -c <"$VIDEO_FILE" || echo 0)" -gt 51200 ]; then
    VIDEO_NOTE="video artifact attached (cursor visibility not machine-verifiable)"
    VIDEO_ACTIVE=2
fi

record visible_pointer_motion MANUAL_REQUIRED "$VIDEO_NOTE"
if [ "$(result_of idle_pointer_reappearance)" != "MANUAL_REQUIRED" ]; then
    record idle_pointer_reappearance MANUAL_REQUIRED ""
fi
note idle_pointer_reappearance "idle-fade window captured in video timeline when available"
record visual_scroll_direction MANUAL_REQUIRED \
    "kernel REL_WHEEL/REL_HWHEEL signs verified for UHID; visible direction needs physical screen"
record full_edge_handoff_return MANUAL_REQUIRED \
    "macOS->Android->macOS handoff needs human operation; edge logic covered by existing automated macOS tests"

# ==================================================== session: forced UHID ===
echo "== session forced UHID (POINTER_BACKEND=uhid)"
STDOUT="$TMP_LOCAL/forced-uhid-stdout.bin"
: >"$STDOUT"; : >"$STDOUT.off"
FUHID_OK=1
if ! start_session uhid; then
    record forced_uhid FAIL "helper failed to start"
    FUHID_OK=0
fi
if [ "$FUHID_OK" = "1" ] && ! session_hello_list "$STDOUT" 1100; then
    record forced_uhid FAIL "handshake failed"
    FUHID_OK=0
fi
if [ "$FUHID_OK" = "1" ]; then
    stream_pull "$STDOUT"
    assert_dex_still_present "$STDOUT" || {
        record forced_uhid FAIL "DeX display $DEX_ID no longer present"
        FUHID_OK=0
    }
fi
if [ "$FUHID_OK" = "1" ]; then
    send_hex "$(frame_hex SELECT_DISPLAY 1102 "$DEX_ID")"
    wait_frame "$STDOUT" DISPLAY_CHANGED 1102 15 >/dev/null || true
    sleep 0.5
    pull_log_file "$(ev forced-uhid-helper.log)"
    if grep -Eq "pointer backend selected backend=uhid mode=uhid" "$(ev forced-uhid-helper.log)" &&
        grep -q "forced UHID ignores target" "$(ev forced-uhid-helper.log)"; then
        if SMOKE_OUT="$(smoke_pointer_sequence "$STDOUT" 1110)"; then
            record forced_uhid PASS "$SMOKE_OUT (system-routed, marker mode=uhid)"
        else
            record forced_uhid FAIL "$SMOKE_OUT"
            FUHID_OK=0
        fi
        # Four-direction kernel-sign evidence rides the UHID session so it does
        # not depend on the AUTO backend gate.
        UHID_NODE="$(find_uhid_event_node)"
        if [ -n "$UHID_NODE" ] && capture_uhid_input "$(ev getevent-uhid.txt)" 12; then
            sleep 1
            if four_scroll_probe "$STDOUT" 1150; then
                FOURDIR_UHID_PROBE=pass
            else
                FOURDIR_UHID_PROBE=fail:scroll-not-delivered
            fi
            sleep 2
            end_uhid_capture
            COUNTS="$(assert_scroll_directions_in_getevent "$(ev getevent-uhid.txt)")"
            echo "getevent summary: $COUNTS" >>"$(ev getevent-uhid.txt)"
            for pair in "REL_WHEEL+1:+v(up)" "REL_WHEEL-1:-v(down)" "REL_HWHEEL-1:+h(left)" "REL_HWHEEL+1:-h(right)"; do
                key="${pair%%:*}"
                jq -ce --arg k "$key" '.[$k] // 0 | . >= 1' <<<"$COUNTS" >/dev/null 2>&1 ||
                    FOURDIR_UHID_PROBE="fail:$key missing (expected ${pair#*:})"
            done
        else
            FOURDIR_UHID_PROBE="skip:no-getevent-node"
        fi
    else
        record forced_uhid FAIL "expected forced-UHID markers absent"
        FUHID_OK=0
    fi
fi
pull_stdout "$STDOUT"
cp "$STDOUT" "$(ev forced-uhid-stdout.bin)"
parse_frames "$STDOUT" >>"$(ev auto-protocol.txt)"
pull_log_file "$(ev forced-uhid-helper.log)"

# When the AUTO gate failed early, the forced-UHID session still yields the
# registration and full-smoke evidence — record it from here instead of
# leaving the items NOT_RUN.
if [ "$(result_of uhid_device_registration)" = "NOT_RUN" ] && [ -n "${UHID_NODE:-}" ]; then
    adb -s "$DEVICE" exec-out dumpsys input >"$(ev dumpsys-input.txt)"
    if grep -qi "Ampersand Mouse" "$(ev dumpsys-input.txt)"; then
        record uhid_device_registration PASS "dumpsys input shows Ampersand Mouse (evidence from forced-UHID session)"
    fi
fi
if [ "$(result_of pointer_result_smoke)" = "NOT_RUN" ] &&
    [ "${FUHID_OK:-0}" = "1" ]; then
    record pointer_result_smoke PASS "full semantic smoke delivered in the forced-UHID session (AUTO gate had failed earlier)"
fi
STOP_OK=1
scripts/deploy-helper.sh stop >"$TMP_LOCAL/fuhid-stop.log" 2>&1 || STOP_OK=0
grep -q "graceful shutdown complete" "$TMP_LOCAL/fuhid-stop.log" || STOP_OK=0
SESSIONS_STOPPED=$((SESSIONS_STOPPED + 1))
if [ "$STOP_OK" != "1" ]; then
    SHUTDOWN_FAILURES=$((SHUTDOWN_FAILURES + 1))
    note clean_shutdown "forced-UHID session stop not graceful"
fi

# ============================================== session: forced InputManager ==
echo "== session forced input-manager (POINTER_BACKEND=input-manager)"
STDOUT="$TMP_LOCAL/forced-im-stdout.bin"
: >"$STDOUT"; : >"$STDOUT.off"
FIM_OK=1
if ! start_session input-manager; then
    record forced_input_manager FAIL "helper failed to start"
    FIM_OK=0
fi
if [ "$FIM_OK" = "1" ] && ! session_hello_list "$STDOUT" 1200; then
    record forced_input_manager FAIL "handshake failed"
    FIM_OK=0
fi
if [ "$FIM_OK" = "1" ]; then
    stream_pull "$STDOUT"
    assert_dex_still_present "$STDOUT" || {
        record forced_input_manager FAIL "DeX display $DEX_ID no longer present"
        FIM_OK=0
    }
fi
if [ "$FIM_OK" = "1" ]; then
    send_hex "$(frame_hex SELECT_DISPLAY 1202 "$DEX_ID")"
    wait_frame "$STDOUT" DISPLAY_CHANGED 1202 15 >/dev/null || true
    sleep 0.5
    pull_log_file "$(ev forced-input-manager-helper.log)"
    if grep -Eq "pointer backend selected backend=input-manager mode=input-manager" \
        "$(ev forced-input-manager-helper.log)"; then
        if SMOKE_OUT="$(smoke_pointer_sequence "$STDOUT" 1210)"; then
            if four_scroll_probe "$STDOUT" 1250; then
                record forced_input_manager PASS "$SMOKE_OUT (marker mode=input-manager)"
            else
                record forced_input_manager FAIL "$SMOKE_OUT; four-direction scroll probe failed"
                FIM_OK=0
            fi
        else
            record forced_input_manager FAIL "$SMOKE_OUT"
            FIM_OK=0
        fi
    else
        record forced_input_manager FAIL "expected input-manager marker absent"
        FIM_OK=0
    fi
fi
pull_stdout "$STDOUT"
cp "$STDOUT" "$(ev forced-im-stdout.bin)"
parse_frames "$STDOUT" >>"$(ev auto-protocol.txt)"
pull_log_file "$(ev forced-input-manager-helper.log)"
STOP_OK=1
scripts/deploy-helper.sh stop >"$TMP_LOCAL/fim-stop.log" 2>&1 || STOP_OK=0
grep -q "graceful shutdown complete" "$TMP_LOCAL/fim-stop.log" || STOP_OK=0
SESSIONS_STOPPED=$((SESSIONS_STOPPED + 1))
if [ "$STOP_OK" != "1" ]; then
    SHUTDOWN_FAILURES=$((SHUTDOWN_FAILURES + 1))
    note clean_shutdown "forced-InputManager session stop not graceful"
fi

# ------------------------------------- four-direction protocol semantics gate ==
case "${FOURDIR_UHID_PROBE:-none}" in
    pass)
        record four_direction_protocol_semantics PASS \
            "kernel REL_WHEEL/REL_HWHEEL signs verified via bounded getevent; four-direction scrolls delivered on UHID and InputManager"
        ;;
    fail:*|skip:*|none)
        record four_direction_protocol_semantics FAIL "direction evidence: ${FOURDIR_UHID_PROBE:-not collected}"
        ;;
esac

# ======================================================= session: failover ====
if [ "$WITH_FAILOVER" != "1" ]; then
    record mid_session_physical_failover NOT_RUN "opt-in (--with-failover) not requested for this run"
elif [ "$FAILOVER_SUPPORTED" != "1" ]; then
    record mid_session_physical_failover NOT_RUN \
        "built helper lacks the --fail-uhid-report test hook (revision predates issue #60); covered by unit tests only"
else
    echo "== session failover (auto + injected Nth-report failure)"
    STDOUT="$TMP_LOCAL/failover-stdout.bin"
    : >"$STDOUT"; : >"$STDOUT.off"
    FO_OK=1
    if ! { POINTER_BACKEND=auto FAIL_UHID_REPORT=3 scripts/deploy-helper.sh start 2>&1 |
        tee "$TMP_LOCAL/session-start-failover.log" >/dev/null; }; then
        record mid_session_physical_failover FAIL "helper failed to start"
        FO_OK=0
    fi
    if [ "$FO_OK" = "1" ] && ! session_hello_list "$STDOUT" 1300; then
        record mid_session_physical_failover FAIL "handshake failed"
        FO_OK=0
    fi
    if [ "$FO_OK" = "1" ]; then
        stream_pull "$STDOUT"
        assert_dex_still_present "$STDOUT" || FO_OK=0
    fi
    if [ "$FO_OK" = "1" ]; then
        send_hex "$(frame_hex SELECT_DISPLAY 1302 "$DEX_ID")"
        sleep 1.5 # UHID create (~500ms inside select) + DISPLAY_CHANGED settle
        send_hex "$(frame_hex POINTER_MOVE_REL 1303 8 8)"      # report #1 delivered
        sleep 0.4
        send_hex "$(frame_hex POINTER_BUTTON 1304 0 down)"     # report #2 delivered; button HELD
        sleep 0.4
        send_hex "$(frame_hex POINTER_SCROLL 1305 0 1)"        # report #3 INJECTED FAILURE
        sleep 2                                                # fallback + single retry on IM
        send_hex "$(frame_hex POINTER_MOVE_REL 1306 -6 4)"     # must ride InputManager now
        sleep 1
        stream_pull "$STDOUT"
        pull_log_file "$TMP_LOCAL/failover-log.txt"
        cp "$TMP_LOCAL/failover-log.txt" "$(ev failover-helper.log)"

        FAULT_HIT=$(grep -c "test-only report fault injected" "$(ev failover-helper.log)" || true)
        FAILOVER_HIT=$(grep -c "pointer backend failover backend=input-manager" "$(ev failover-helper.log)" || true)
        SCROLL_RESULT="$(jq -ce --arg r 1305 'select(.type=="POINTER_RESULT" and (.reqid|tostring)==$r)' \
            <(parse_frames "$STDOUT" 2>/dev/null) 2>/dev/null | head -n1 || true)"
        MOVE_AFTER="$(jq -ce --arg r 1306 'select(.type=="POINTER_RESULT" and (.reqid|tostring)==$r and .status==0)' \
            <(parse_frames "$STDOUT" 2>/dev/null) 2>/dev/null | head -n1 || true)"
        DUP_COUNTS="$(jq -r 'select(.type=="POINTER_RESULT") | .reqid' <(parse_frames "$STDOUT" 2>/dev/null) 2>/dev/null |
            sort | uniq -d | wc -l | tr -d ' ')"
        STUCK_LINE=$(grep -c "button release report failed during device close" "$(ev failover-helper.log)" || true)

        if [ "$FAULT_HIT" -ge 1 ] && [ "$FAILOVER_HIT" -ge 1 ] &&
            [ -n "$SCROLL_RESULT" ] && [ "$(jq -r '.status' <<<"$SCROLL_RESULT" 2>/dev/null)" = "0" ] &&
            [ -n "$MOVE_AFTER" ] && [ "$DUP_COUNTS" = "0" ] &&
            [ "$STUCK_LINE" = "0" ] && helper_alive; then
            record mid_session_physical_failover PASS \
                "injected failure -> UHID cleanup -> InputManager retry-once -> next event delivered; no duplicate results; held button released"
        else
            record mid_session_physical_failover FAIL \
                "fault_hit=$FAULT_HIT failover_marker=$FAILOVER_HIT scroll_retry=$([ -n "$SCROLL_RESULT" ] && jq -r '.status' <<<"$SCROLL_RESULT" || echo none) move_after=$([ -n "$MOVE_AFTER" ] && echo ok || echo missing) duplicate_reqids=$DUP_COUNTS stuck_release_line=$STUCK_LINE helper_alive=$(helper_alive && echo yes || echo no)"
        fi
    fi
    stream_pull "$STDOUT"
    parse_frames "$STDOUT" >>"$(ev auto-protocol.txt)"
    STOP_OK=1
    scripts/deploy-helper.sh stop >"$TMP_LOCAL/fo-stop.log" 2>&1 || STOP_OK=0
    grep -q "graceful shutdown complete" "$TMP_LOCAL/fo-stop.log" || STOP_OK=0
    if [ "$STOP_OK" != "1" ]; then
        SHUTDOWN_FAILURES=$((SHUTDOWN_FAILURES + 1))
        note clean_shutdown "failover session stop not graceful"
    fi
fi

# ------------------------------------------------------------------ verdict ---
if [ "$SHUTDOWN_FAILURES" -eq 0 ] && [ "$SESSIONS_STOPPED" -gt 0 ]; then
    record clean_shutdown PASS "$SESSIONS_STOPPED session(s) ended with graceful SHUTDOWN"
elif [ "$SHUTDOWN_FAILURES" -gt 0 ]; then
    record clean_shutdown FAIL "$SHUTDOWN_FAILURES of $SESSIONS_STOPPED stops were not graceful"
fi

OVERALL="PASS"
for key in "${RESULTS_ORDER[@]}"; do
    case "$(result_of "$key")" in
        FAIL) OVERALL="FAIL" ;;
    esac
done
if [ "$OVERALL" != "FAIL" ]; then
    for key in "${RESULTS_ORDER[@]}"; do
        case "$(result_of "$key")" in
            MANUAL_REQUIRED | NOT_RUN | SKIP)
                OVERALL="AUTOMATED_PASS_PHYSICAL_VISUAL_PENDING"
                break
                ;;
        esac
    done
fi

finish_summary
