import SwiftUI

@main
struct DeckApp: App {
    @StateObject private var model = DeckModel()

    var body: some Scene {
        WindowGroup {
            DeckScreen()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
