import SwiftUI

@main
struct XSideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("XSide", systemImage: "arrow.triangle.2.circlepath") {
            Text("XSide")
                .padding()
                .frame(width: 240)
        }
        .menuBarExtraStyle(.window)
    }
}
