import SwiftUI

@main
struct AmpersandApp: App {
    var body: some Scene {
        MenuBarExtra("Ampersand", systemImage: "cursorarrow.motionlines") {
            Text("Ampersand (skeleton)")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
