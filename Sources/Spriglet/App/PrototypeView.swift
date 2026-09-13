import AppKit
import SwiftUI

private let welcomeCompletionKey = "dev.spriglet.welcomeCompleted"

struct PetMenu: View {
    let runtime: PetRuntime
    @Binding var presentingWelcome: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Spriglet · \(runtime.status)")
        Divider()
        Group {
            Button("Play Character Sample") { runtime.characterSample() }.disabled(!runtime.permitsMotion)
            Button(runtime.isHidden ? "Show Pet" : "Hide Pet") { runtime.setHidden(!runtime.isHidden) }
            Button(runtime.isPaused ? "Resume" : "Pause") { runtime.setPaused(!runtime.isPaused) }
            Button("Pet Spriglet") { runtime.play() }.disabled(!runtime.permitsMotion)
            Button(runtime.isSleeping ? "Wake Spriglet" : "Take a Nap") {
                runtime.preview(runtime.isSleeping ? .wakeUp : .fallAsleep)
            }.disabled(!runtime.permitsMotion)
            Button("Short Walk") { runtime.walk() }.disabled(!runtime.permitsMotion)
            Button("Walk Left") { runtime.walk(direction: .walkLeft) }.disabled(!runtime.permitsMotion)
            Button("Walk Right") { runtime.walk(direction: .walkRight) }.disabled(!runtime.permitsMotion)
            Button("Bring Pet Home") { runtime.recenter() }
            Divider()
            Toggle("Pass Clicks Through", isOn: Binding(get: { runtime.clickThrough }, set: { runtime.setClickThrough($0) }))
            Toggle("Quiet Behavior", isOn: Binding(get: { runtime.autonomousBehavior }, set: { runtime.setAutonomousBehavior($0) }))
        }.disabled(runtime.sampling)
        if runtime.sampling {
            Button("Cancel Automatic Check") { runtime.cancelProbe() }
        }
        Button("Spriglet Controls…") {
            presentingWelcome = false
            openWindow(id: "prototype")
            NSApp.activate()
        }
        Button("Show Welcome") {
            presentingWelcome = true
            openWindow(id: "prototype")
            NSApp.activate()
        }
        Divider()
        Button("Quit Spriglet", role: .destructive) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct PrototypeView: View {
    let runtime: PetRuntime
    @Binding var presentingWelcome: Bool
    @State private var diagnosticsExpanded = false

    private var isTemporaryReview: Bool {
        let arguments = CommandLine.arguments
        return arguments.contains("--welcome-review") || arguments.contains("--sample-review")
    }

    var body: some View {
        Group {
            if presentingWelcome {
                WelcomeView {
                    presentingWelcome = false
                    let arguments = CommandLine.arguments
                    let isProbe = arguments.contains("--probe") || arguments.contains("--soak")
                    if !isTemporaryReview && !isProbe {
                        UserDefaults.standard.set(true, forKey: welcomeCompletionKey)
                    }
                }
            } else {
                controls
            }
        }
        .frame(width: 480)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 28)).foregroundStyle(.green)
                    .frame(width: 52, height: 52)
                    .background(.green.opacity(0.08), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Spriglet Controls").font(.title2.bold())
                    Text("A little quiet company").foregroundStyle(.secondary)
                }
                Spacer()
                Text(runtime.status).font(.caption.weight(.medium))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.quaternary, in: .capsule)
            }

            Text("Meet Sprout: a small idle moment, a short walk, a happy pet reaction, and a gentle settle.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Play Character Sample", systemImage: "play.fill") { runtime.characterSample() }
                .buttonStyle(.borderedProminent)
                .disabled(!runtime.permitsMotion || runtime.sampling)

            Form {
                Section("Everyday controls") {
                    Toggle("Quiet Behavior", isOn: Binding(get: { runtime.autonomousBehavior }, set: { runtime.setAutonomousBehavior($0) }))
                    Text("Spriglet occasionally idles or naps. Your choices stay on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Idle") { runtime.preview(.lookAround) }
                        Button("Pet") { runtime.play() }
                        Button(runtime.isSleeping ? "Wake Up" : "Nap") {
                            runtime.preview(runtime.isSleeping ? .wakeUp : .fallAsleep)
                        }
                        Button("Walk") { runtime.walk() }
                    }.disabled(!runtime.permitsMotion || runtime.sampling)
                    HStack {
                        Button("Walk Left") { runtime.walk(direction: .walkLeft) }
                        Button("Walk Right") { runtime.walk(direction: .walkRight) }
                    }.disabled(!runtime.permitsMotion || runtime.sampling)
                    if !runtime.permitsMotion {
                        Text(motionUnavailableMessage)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.disabled(runtime.sampling)

                Section("Pet and placement") {
                    Toggle("Pause", isOn: Binding(get: { runtime.isPaused }, set: { runtime.setPaused($0) }))
                    Toggle("Hide Pet", isOn: Binding(get: { runtime.isHidden }, set: { runtime.setHidden($0) }))
                    Toggle("Pass Clicks Through", isOn: Binding(get: { runtime.clickThrough }, set: { runtime.setClickThrough($0) }))
                    Toggle("Show on All Spaces", isOn: Binding(get: { runtime.allSpaces }, set: { runtime.setAllSpaces($0) }))
                    HStack {
                        Button("Recenter") { runtime.recenter() }
                        Button("Next Display") { runtime.moveToNextDisplay() }
                    }
                    HStack {
                        Text("Move pet")
                        Spacer()
                        Button("Left", systemImage: "arrow.left") { runtime.nudge(dx: -48) }
                            .accessibilityLabel("Move pet left")
                        Button("Down", systemImage: "arrow.down") { runtime.nudge(dy: -48) }
                            .accessibilityLabel("Move pet down")
                        Button("Up", systemImage: "arrow.up") { runtime.nudge(dy: 48) }
                            .accessibilityLabel("Move pet up")
                        Button("Right", systemImage: "arrow.right") { runtime.nudge(dx: 48) }
                            .accessibilityLabel("Move pet right")
                    }.labelStyle(.iconOnly)
                    Text("Drag Sprout to place it. Spriglet remembers its position and keeps it reachable if a display changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(runtime.sampling)

                Section {
                    DisclosureGroup("Diagnostics", isExpanded: $diagnosticsExpanded) {
                        LabeledContent("Submitted frames", value: "\(runtime.submittedFrames)")
                        LabeledContent("Quiet moments", value: "\(runtime.automaticActionCount)")
                        LabeledContent("Resting deadline", value: runtime.hasScheduledBehavior ? "Scheduled" : "None")
                        LabeledContent("Physical footprint", value: runtime.footprintMiB.map { $0.formatted(.number.precision(.fractionLength(1))) + " MiB" } ?? "Unavailable")
                        LabeledContent("Desktop position", value: runtime.positionDescription)
                        LabeledContent("Low Power Mode", value: runtime.lowPower ? "On" : "Off")
                        LabeledContent("Reduce Motion", value: runtime.reduceMotion ? "On" : "Off")
                        HStack {
                            Button("Refresh") { runtime.refreshMeasurements() }
                            Button("Run Automatic Check") { runtime.runProbe() }.disabled(runtime.sampling)
                            if runtime.reportJSON != nil {
                                Button("Copy Report") { runtime.copyReport() }
                            }
                        }
                        Button("Run 100-Cycle Check") { runtime.runSoak() }.disabled(runtime.sampling)
                        Text("Checks are finite and can be cancelled. Saved choices are restored afterward.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)

            if let issue = runtime.characterIssue {
                Text(issue)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if runtime.sampling {
                Button("Cancel Check") { runtime.cancelProbe() }
            }
            Text(runtime.sampling ? runtime.diagnosticProgress : runtime.message)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .onAppear { runtime.refreshMeasurements() }
    }

    private var motionUnavailableMessage: String {
        if let issue = runtime.characterIssue { return issue }
        if runtime.isHidden { return "Motion is unavailable while Sprout is hidden. Show Sprout to interact." }
        if runtime.isPaused { return "Motion is paused. Resume Sprout to interact." }
        if runtime.reduceMotion { return "Reduce Motion is enabled, so Spriglet stays still." }
        return "Motion is temporarily unavailable while the system is resting or the character asset is unavailable."
    }
}

private struct WelcomeView: View {
    let onGetStarted: () -> Void

    private var sproutImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "rest", withExtension: "png", subdirectory: "SproutSample") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        VStack(spacing: 20) {
            if let sproutImage {
                Image(nsImage: sproutImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 190)
                    .accessibilityLabel("Sprout, the Spriglet companion")
            } else {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)
                    .frame(height: 190)
                    .accessibilityLabel("Sprout")
            }
            VStack(spacing: 8) {
                Text("Welcome to Spriglet").font(.largeTitle.bold())
                Text("A small, calm companion for your desktop.")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 12) {
                welcomeInstruction("hand.tap", "Click Sprout to pet it.")
                welcomeInstruction("arrow.up.and.down.and.arrow.left.and.right", "Drag Sprout to move it.")
                welcomeInstruction("leaf.fill", "Use the leaf menu for controls.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Spriglet is local by design: no account, no tracking, and no desktop capture.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Get Started", action: onGetStarted)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(30)
        .frame(minHeight: 600)
    }

    private func welcomeInstruction(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.body)
            .labelStyle(.titleAndIcon)
    }
}
