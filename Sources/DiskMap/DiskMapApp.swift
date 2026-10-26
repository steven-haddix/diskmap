import SwiftUI

@main
struct DiskMapApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("DiskMap") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 820)
    }
}
