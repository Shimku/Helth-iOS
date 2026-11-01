import SwiftUI

@main
struct HealthCopyApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView(receive: app.receive)
                .environmentObject(app)
                .onOpenURL { app.open($0) }
                #if DEBUG
                .task { await DebugRunner.run(app) }
                .overlay(alignment: .bottom) { DebugBadge() }
                #endif
        }
    }
}
