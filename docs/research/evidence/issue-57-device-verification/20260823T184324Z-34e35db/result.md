# Issue #57 device verification - 20260823T184324Z-34e35db

- revision: `34e35dba7d52dcb43b56cc8eb42f34ac9ec20df9` (requested: `34e35dba7d52dcb43b56cc8eb42f34ac9ec20df9`, HEAD at start: `34e35dba7d52dcb43b56cc8eb42f34ac9ec20df9`)
- device: SM-G977N selector=single-adb-device Android 12 (API 31); raw adb serial redacted
- dex display id: 2
- started (UTC): 20260823T184324Z
- overall: **AUTOMATED_PASS_PHYSICAL_VISUAL_PENDING**

| check | result | notes |
|---|---|---|
| auto_uhid_selection | PASS | backend=uhid routing=system target=2 |
| first_move_after_select | PASS | POINTER_RESULT delivered immediately after SELECT_DISPLAY |
| uhid_device_registration | PASS | dumpsys input + getevent -pl (/dev/input/event13) |
| pointer_result_smoke | PASS | all 12 pointer requests delivered (status=0) |
| forced_uhid | PASS | all 12 pointer requests delivered (status=0) (system-routed, marker mode=uhid) |
| forced_input_manager | PASS | all 12 pointer requests delivered (status=0) (marker mode=input-manager) |
| four_direction_protocol_semantics | PASS | kernel REL_WHEEL/REL_HWHEEL signs verified via bounded getevent; four-direction scrolls delivered on UHID and InputManager |
| clean_shutdown | PASS | 3 session(s) ended with graceful SHUTDOWN |
| visible_pointer_motion | MANUAL_REQUIRED | video artifact attached (cursor visibility not machine-verifiable) |
| idle_pointer_reappearance | MANUAL_REQUIRED | post-idle moves delivered (protocol level); visibility needs screen/video confirmation; idle-fade window captured in video timeline when available |
| visual_scroll_direction | MANUAL_REQUIRED | kernel REL_WHEEL/REL_HWHEEL signs verified for UHID; visible direction needs physical screen |
| full_edge_handoff_return | MANUAL_REQUIRED | macOS->Android->macOS handoff needs human operation; edge logic covered by existing automated macOS tests |
| mid_session_physical_failover | PASS | injected failure -> UHID cleanup -> InputManager retry-once -> next event delivered; no duplicate results; held button released |

MANUAL_REQUIRED items require human confirmation on the physical DeX
screen and are never collapsed into PASS. NOT_RUN items carry the
reason in the notes column.
