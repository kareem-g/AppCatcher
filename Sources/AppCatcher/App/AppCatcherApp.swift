import SwiftUI

@main
struct AppCatcherApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.mint)
        }
    }
}
