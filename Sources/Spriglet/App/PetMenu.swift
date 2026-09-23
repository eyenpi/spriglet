import AppKit
import SwiftUI

struct PetMenu: View {
    let runtime: PetRuntime
    let presentation: AppPresentation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(runtime.petName) · \(runtime.status)")
        Divider()
        PetCommandActions(runtime: runtime, compact: true)
        Divider()
        SettingsLink { Text("Settings…") }
        Button(AppText.quickGuide + "…") { openWindow(id: "welcome"); NSApp.activate() }
        Button(AppText.privacyTitle + "…") { openWindow(id: "privacy"); NSApp.activate() }
        Button(AppText.supportTitle + "…") { openWindow(id: "support"); NSApp.activate() }
        if presentation.developerToolsAvailable {
            Button("Developer Diagnostics…") { openWindow(id: "diagnostics"); NSApp.activate() }
        }
        if runtime.sampling { Button("Cancel Development Check") { runtime.cancelProbe() } }
        Divider()
        Button(AppText.quitApp) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// The menu and main-menu commands share their actions and eligibility.
struct PetCommandActions: View {
    let runtime: PetRuntime
    var compact = false

    var body: some View {
        Group {
            Button("Pet \(runtime.petName)") { runtime.play() }
                .keyboardShortcut("p", modifiers: [.command, .option]).disabled(!runtime.canInteract)
            Button(AppText.playWithFirefly) { runtime.playWithFirefly() }
                .keyboardShortcut("f", modifiers: [.command, .option]).disabled(!runtime.canPlayWithFirefly)
            Toggle(AppText.parkedMode, isOn: Binding(get: { runtime.isParked }, set: { runtime.setParked($0) }))
                .keyboardShortcut("k", modifiers: [.command, .option])
            Button(runtime.isPaused ? AppText.resume : AppText.pause) { runtime.setPaused(!runtime.isPaused) }
                .keyboardShortcut(".", modifiers: [.command, .option])
            Button(runtime.isHidden ? AppText.showPet : AppText.hidePet) { runtime.setHidden(!runtime.isHidden) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            if runtime.isEyeDocked {
                Button("Return Acorn to Desktop") { runtime.returnFromTopBar() }
            } else {
                Button("Move Acorn to Top Bar") { runtime.moveToTopBar() }
            }
            if !compact {
                Divider()
                Button(runtime.isSleeping ? "Wake Up" : "Take a Nap") {
                    runtime.preview(runtime.isSleeping ? .wakeUp : .fallAsleep)
                }.disabled(!runtime.canInteract)
                Button("Short Walk") { runtime.walk() }
                    .keyboardShortcut("w", modifiers: [.command, .option]).disabled(!runtime.canInteract)
                Button(AppText.bringPetHome) { runtime.recenter() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Menu("Move Pet") {
                    Button("Left") { runtime.nudge(dx: -48) }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    Button("Right") { runtime.nudge(dx: 48) }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    Button("Up") { runtime.nudge(dy: 48) }
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Button("Down") { runtime.nudge(dy: -48) }
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    Button(AppText.nextDisplay) { runtime.moveToNextDisplay() }
                }
            }
        }.disabled(runtime.sampling)
    }
}

struct CompanionCommands: Commands {
    let runtime: PetRuntime
    let presentation: AppPresentation
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Companion") { PetCommandActions(runtime: runtime) }
        CommandGroup(after: .help) {
            Button("\(AppText.appName) \(AppText.quickGuide)") { openWindow(id: "welcome"); NSApp.activate() }
        }
        if presentation.developerToolsAvailable {
            CommandMenu("Developer") {
                Button("Diagnostics…") { openWindow(id: "diagnostics"); NSApp.activate() }
            }
        }
    }
}

struct SprigletMenuLabel: View {
    let runtime: PetRuntime
    let presentation: AppPresentation
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "leaf.fill")
            .accessibilityLabel("Spriglet menu, \(runtime.petName), \(runtime.status)")
            .task {
                runtime.onShowSettingsRequested = { openSettings(); NSApp.activate() }
                presentation.presentInitial(
                    settings: { openSettings(); NSApp.activate() },
                    window: { openWindow(id: $0); NSApp.activate() }
                )
            }
    }
}
