import SwiftUI
import AnkerCore

@main
struct AnkerControllerApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Anker Controller") {
            MainWindow()
                .environment(state)
                .frame(minWidth: 1020, minHeight: 680)
                .task { await state.start() }
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Export Sanitized Diagnostics…") { Task { await state.exportDiagnostics() } }
            }
        }
    }
}
