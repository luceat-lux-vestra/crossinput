# Architecture Rebaseline Integration Audit

> Scope: issue #41 / PR #42 after rebasing onto `origin/main` at `7d1f66f`.
> Date: 2026-08-13. This record distinguishes source validation from physical
> device verification.

## Audit method

The review restarted from the current main branch and followed the runtime
path end to end: macOS capture, handoff, session publication, target selection,
semantic input delivery, CXI v1 framing, Android display discovery, backend
selection, injection, and cleanup. The review also checked the hard safety
rules, existing ADRs, protocol fixtures, tests, and the changes integrated into
main after the original PR branch diverged.

No CXI frame or fixture changed in this follow-up.

## Findings and corrections

1. The rebase exposed an integration regression in external-control takeover.
   The main-branch takeover reason no longer crossed every rebaseline boundary.
   The complete path now returns through `ControlHandoffController`, resets the
   handoff state, passes the triggering external event through without waiting
   for remote cleanup, and never warps the local pointer. Queued key releases
   and accepted held pointer-button releases then complete in order.
2. `SessionController` previously published the candidate session before HELLO
   and capability negotiation completed. Input delivery can now observe only a
   ready session. Failed and exhausted reconnect paths clear both candidate and
   live channels and enter a consistent terminal state.
3. Initial target selection was launched as hidden asynchronous work. Refresh
   now waits for the helper's matching `DISPLAY_CHANGED` confirmation, rejects
   stale session generations and selection tokens, and only then permits input
   capture to start.
4. The control presentation state carried an optional target even though target
   ownership belongs to `TargetSelectionController`. The control lifecycle is
   now only local or remote; target identity remains in the target lifecycle.
5. Android display callbacks and stdin frame handling could concurrently touch
   the same pointer backend. `PointerDispatcher` now serializes selection,
   metric refresh, injection, and close operations.
6. The smoke tool used deprecated transport configuration and did not require a
   semantic pointer acknowledgement. It now uses `AdbTransport` directly and
   requires a delivered `POINTER_RESULT`.
7. The rebaseline composition-root rewrite accidentally omitted the existing
   host-display edge picker even though persisted edge settings and capture
   application remained active. This made a stored edge effective but
   invisible and unchangeable in the menu. The application now publishes an
   explicit host-display snapshot and restores the per-display
   `None`/`Left`/`Right`/`Top`/`Bottom` picker. Regression tests cover multiple
   host displays, persisted edges, labels, and invalid stored values.

## Safety and compatibility boundary

- No pointer-trapping mechanism was introduced.
- External takeover and every failure path return local control immediately;
  remote cleanup is best effort and does not block that return.
- No display identifier is hardcoded.
- Diagnostics remain metadata-only and do not log key codes, clipboard data,
  or input payloads.
- CXI v1 protocol bytes and golden fixtures are unchanged.
- Dedicated display-removal propagation remains deferred to issue #17.

## Validation status

The following automated gates passed for this integration on 2026-08-13:

```text
cd apps/macos && swift test --quiet
cd apps/macos && swift build -c release
./scripts/build-android-helper.sh test
./scripts/build-android-helper.sh assembleDebug
node protocol/scripts/check-fixtures.mjs
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
git diff --check
```

Results:

- macOS: 75 XCTest cases and 30 Swift Testing cases passed; the release app
  and `cxi-smoke` built successfully.
- Android: debug and release unit-test/compile tasks passed; the debug APK
  assembled successfully.
- Protocol: all 15 CXI v1 fixtures matched.
- Shell syntax and whitespace validation passed.

The macOS suite includes host-display edge presentation, handshake publication,
superseded-handshake cleanup, terminal session failure, stale-session input,
confirmed target selection, external takeover cleanup, and 100 handoff cycles.
Android tests cover display discovery, backend selection/failure, injection,
and cleanup. Passing these gates demonstrates source-level consistency only.

Toolchain used: Apple Swift 6.3.3, Amazon Corretto JDK 17.0.18, Gradle 8.10.2,
Kotlin 1.9.24, Android Gradle Plugin 8.5.2, compileSdk 35, Node.js 26.7.0, and
ADB 37.0.1. Gradle emitted the existing warning that AGP 8.5.2 was tested only
through compileSdk 34; no build or test failed.

## Physical verification status

The initial ADB check used an obsolete wireless endpoint and incorrectly
reported no attached device. After using the device's current connection port,
the physical SM-G977N was confirmed as Android 12 / API 31. The exact locally
built helper APK matched the pushed APK by SHA-256. A fresh semantic session
completed HELLO, discovered the built-in display plus dynamically assigned
HDMI and Desktop targets, selected the Desktop target, received delivered
`POINTER_RESULT` responses through the explicit InputManager backend, answered
PING, and shut down cleanly. A forced InputManager run independently confirmed
selection and accepted movement on the dynamically discovered Desktop target.

The rebuilt menu was also inspected directly and confirmed to expose every
current macOS host display with the restored per-display edge choices. This is
physical host UI evidence, not target-screen pointer evidence.

The Desktop display returned a readable ADB screen capture, but the static
capture did not contain the cursor sprite. Semantic pointer visibility,
click/scroll observation, keyboard composition, full failure recovery, and the
screen-confirmed 100-cycle matrix therefore remain **NOT VERIFIED** on this
head. Historical evidence is retained but is not promoted to fresh-head
evidence.
