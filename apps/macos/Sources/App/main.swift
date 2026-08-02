import SwiftUI

@main
struct AmpersandApp: App {
    var body: some Scene {
        MenuBarExtra("Ampersand", systemImage: "cursorarrow.motionlines") {
            Text("Ampersand (스켈레톤)")
            Divider()
            Button("종료") { NSApplication.shared.terminate(nil) }
        }
    }
}
