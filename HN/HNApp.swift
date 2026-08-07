import SwiftUI

@main
struct HNApp: App {
    var body: some Scene {
        WindowGroup {
            StoriesView()
                .task { await launchSelfTest() }
        }
    }

    // Exercises both server endpoints on launch so an attached console
    // (devicectl launch --console) shows exactly what works and what doesn't.
    private func launchSelfTest() async {
        netlog("self-test: begin")
        if let error = await HNClient.healthCheck() {
            netlog("self-test health: FAILED \(error)")
        } else {
            netlog("self-test health: ok")
        }
        do {
            let status = try await HNClient.explainerStatus(storyID: 49201970)
            netlog("self-test explainerStatus: ok \(status)")
        } catch {
            netlog("self-test explainerStatus: FAILED \(error)")
        }
        netlog("self-test: end")
    }
}
