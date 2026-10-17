import SwiftUI

@main
struct MangoCUTApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView(demo: DemoRequest.fromArguments())
                .preferredColorScheme(.dark)
                .tint(.mango)
        }
    }
}
