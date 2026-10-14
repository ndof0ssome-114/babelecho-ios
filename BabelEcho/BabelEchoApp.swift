import SwiftUI

@main
struct BabelEchoApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--ui-test-large-text") {
                workspace.dynamicTypeSize(.accessibility5)
            } else if ProcessInfo.processInfo.arguments.contains("--ui-test-dark") {
                workspace.preferredColorScheme(.dark)
            } else {
                workspace
            }
            #else
            workspace
            #endif
        }
    }

    private var workspace: some View {
        ContentView()
            .environmentObject(model)
            .tint(Color(red: 0.30, green: 0.38, blue: 0.85))
    }
}
