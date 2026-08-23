#!/usr/bin/env bash
# Evidence privacy lifecycle primitives.
#
# Sourced by scripts/verify-device-issue57.sh (production flow) and exercised
# directly by scripts/test-verify-device-evidence-sanitizer.sh (regression
# tests), so the tests cover the exact functions the production run uses.
#
# Invariant: raw identifiers (adb serial, $HOME path, username) may live only
# in process state or temporary non-git-bound files. Any file under the
# committed evidence directory must have been sanitized AND residual-
# validated, or must not exist.

# Identifier state. IDENT_DEVICE starts empty and is bound exactly once via
# privacy_bind_device after the target device is resolved; it is never reset
# afterwards. ANDROID_SERIAL and the selected DEVICE serial are treated as
# distinct sources: both slots stay populated even when they hold the same
# value, and the selected serial must be protected even when ANDROID_SERIAL
# is unset.
privacy_init_identifiers() {
    IDENT_USER="$(id -un)"
    IDENT_HOME="${HOME:-}"
    IDENT_ANDROID_SERIAL="${ANDROID_SERIAL:-}"
    IDENT_DEVICE=""
}

privacy_bind_device() { # privacy_bind_device <selected-serial>
    IDENT_DEVICE="$1"
}

PRIVACY_FAIL_CODE="${PRIVACY_FAIL_CODE:-2}"

privacy_fail() {
    echo "evidence privacy violation: $*" >&2
    exit "$PRIVACY_FAIL_CODE"
}

privacy_check_residual() { # privacy_check_residual <file> -> 0 when clean
    local f="$1" val
    for val in "$IDENT_USER" "$IDENT_HOME" "$IDENT_ANDROID_SERIAL" "$IDENT_DEVICE"; do
        [ -n "$val" ] || continue
        if grep -Fq -- "$val" "$f"; then
            echo "residual identifier '$val' in $f" >&2
            return 1
        fi
    done
    if grep -Eq '/(Users|home)/' "$f"; then
        echo "residual host user path in $f" >&2
        return 1
    fi
    return 0
}

# sanitize_stream <src> <dst>
# Fixed-string replacement pass followed by a residual scan; <dst> is written
# only when validation passes. Returns non-zero on any failure without
# touching an existing destination.
sanitize_stream() {
    local src="$1" dst="$2" tmp
    [ -f "$src" ] || return 0
    tmp="$(mktemp "${TMP_LOCAL:-${TMPDIR:-/tmp}}/sanitize.XXXXXX")"
    if ! python3 - "$src" "$tmp" \
        "$IDENT_USER" "$IDENT_HOME" "$IDENT_ANDROID_SERIAL" "$IDENT_DEVICE" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
user, home, aserial, device = sys.argv[3:7]
data = open(src, "rb").read()
# Most-specific first: replacing the bare username before $HOME would rewrite
# /Users/<name> into /Users/<redacted-user>, defeating the home-path match and
# leaving a host path fragment behind.
for value, marker in (
    (home, b"<redacted-home-path>"),
    (aserial, b"<redacted-adb-serial>"),
    (device, b"<redacted-adb-serial>"),
    (user, b"<redacted-user>"),
):
    if value:
        data = data.replace(value.encode("utf-8", "surrogateescape"), marker)
open(dst, "wb").write(data)
PY
    then
        rm -f "$tmp"
        echo "sanitizer substitution step failed for $src" >&2
        return 1
    fi
    if ! privacy_check_residual "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$dst"
}

# publish_sanitized <raw-src> <git-bound-dst>
# The only sanctioned path from the raw capture zone into the committed
# evidence directory. Fails closed: on any sanitizer refusal the destination
# is never created and the process aborts with PRIVACY_FAIL_CODE while the
# raw artifact remains only in the temporary (non-git-bound) zone for
# diagnostics.
publish_sanitized() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if ! sanitize_stream "$src" "$dst"; then
        rm -f "$dst"
        privacy_fail "publish blocked; unsanitized artifact retained outside git-bound tree at $src"
    fi
}

# discard_unpublished_evidence <raw-dir> <git-dir> <published-flag>
# Cleanup semantics: the raw capture zone always dies; a git-bound directory
# that never completed publication is removed wholesale so aborted or
# sanitizer-refused runs leave no evidence-looking artifacts behind.
discard_unpublished_evidence() {
    local raw="$1" git_dir="$2" published="${3:-0}"
    rm -rf "$raw"
    if [ "$published" != "1" ]; then
        rm -rf "$git_dir"
    fi
}
