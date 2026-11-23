import SwiftUI

@main struct MotionPhotoConverterApp: App {
    init() { Diagnostics.runIfAsked() }
    var body: some Scene { WindowGroup { ContentView() } }
}
