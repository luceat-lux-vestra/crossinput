# Issue #57 device verification - 20260823T150545Z-2efdffa

- revision: `2efdffa79960dd3d8e4c1e65b63e947784cfcd50` (requested: `2efdffa79960dd3d8e4c1e65b63e947784cfcd50`, HEAD at start: `2efdffa79960dd3d8e4c1e65b63e947784cfcd50`)
- device: SM-G977N selector=single-adb-device Android 12 (API 31); raw adb serial redacted
- dex display id: 2
- started (UTC): 20260823T150545Z
- overall: **FAIL**

| check | result | notes |
|---|---|---|
| auto_uhid_selection | FAIL | expected backend=uhid routing=system; helper reported: pointer backend selected backend=input-manager mode=auto |
| first_move_after_select | PASS | POINTER_RESULT delivered immediately after SELECT_DISPLAY |
| uhid_device_registration | PASS | dumpsys input shows Ampersand Mouse (evidence from forced-UHID session) |
| pointer_result_smoke | PASS | full semantic smoke delivered in the forced-UHID session (AUTO gate had failed earlier) |
| forced_uhid | PASS | all 12 pointer requests delivered (status=0) (system-routed, marker mode=uhid) |
| forced_input_manager | FAIL | request 1214: status=1 |
| four_direction_protocol_semantics | PASS | kernel REL_WHEEL/REL_HWHEEL signs verified via bounded getevent; four-direction scrolls delivered on UHID and InputManager |
| clean_shutdown | PASS | 3 session(s) ended with graceful SHUTDOWN |
| visible_pointer_motion | MANUAL_REQUIRED | video artifact attached (cursor visibility not machine-verifiable) |
| idle_pointer_reappearance | MANUAL_REQUIRED | idle-fade window captured in video timeline when available |
| visual_scroll_direction | MANUAL_REQUIRED | kernel REL_WHEEL/REL_HWHEEL signs verified for UHID; visible direction needs physical screen |
| full_edge_handoff_return | MANUAL_REQUIRED | macOS->Android->macOS handoff needs human operation; edge logic covered by existing automated macOS tests |
| mid_session_physical_failover | NOT_RUN | built helper lacks the --fail-uhid-report test hook (revision predates issue #60); covered by unit tests only |

MANUAL_REQUIRED items require human confirmation on the physical DeX
screen and are never collapsed into PASS. NOT_RUN items carry the
reason in the notes column.
video kept locally at ~/crossinput-artifacts/screen-recording-auto.mp4 (not committed; sha256 in screen-recording.manifest.txt)
