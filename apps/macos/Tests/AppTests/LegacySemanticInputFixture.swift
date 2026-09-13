@testable import InputCapture

/// Temporary test-only bridge for three pre-#103 InputSender fixtures that still
/// construct `CapturedKeyEvent` with the old Android-shaped labels. Production
/// code does not see this initializer. Remove before #103 final merge.
extension CapturedKeyEvent {
    init(keyCode: Int, metaState: UInt32, action: UInt8, repeatCount: UInt8) {
        precondition(keyCode == 29, "legacy fixture only supports existing KEYCODE_A tests")
        precondition(metaState == 0, "legacy fixture only supports unmodified key tests")
        let transition: KeyTransition
        switch action {
        case 0: transition = .down
        case 1: transition = .up
        default: preconditionFailure("unsupported legacy action")
        }
        self.init(key: .a, modifiers: [], transition: transition, repeatCount: repeatCount)
    }
}
