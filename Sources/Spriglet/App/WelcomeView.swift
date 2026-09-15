import AppKit
import SwiftUI

struct WelcomeView: View {
    let runtime: PetRuntime
    @AppStorage(AppPresentation.welcomeCompletionKey) private var welcomeCompleted = false
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 20) {
            if let imageURL = runtime.characterPreviewURL,
               let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image).resizable().scaledToFit().frame(height: 150).accessibilityHidden(true)
            }
            VStack(spacing: 8) {
                Text("Meet \(runtime.petName)").font(.largeTitle.bold())
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text("A little quiet company for your Mac.").font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Label("Click to pet. Drag to find a good spot.", systemImage: "hand.tap")
                Label("Use the leaf menu for play and Settings.", systemImage: "leaf")
                Label("Start parked; allow short strolls whenever you like.", systemImage: "figure.walk")
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text("Choose a name and size in Settings. Sound and launch at login are optional. Everything stays on this Mac.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Get Started") {
                if !AppPresentation.isTemporary && !AppPresentation.isProbe { welcomeCompleted = true }
                openSettings()
                dismissWindow(id: "welcome")
                NSApp.activate()
            }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }.padding(30).frame(width: 440)
    }
}
