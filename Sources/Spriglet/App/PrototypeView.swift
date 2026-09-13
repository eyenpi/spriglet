import SwiftUI

struct PetMenu: View {
    let runtime: PetRuntime
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
        Button("Prototype Controls…") {
            openWindow(id: "prototype")
            NSApp.activate()
        }
        Divider()
        Button("Quit Spriglet", role: .destructive) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct PrototypeView: View {
    let runtime: PetRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 32)).foregroundStyle(.green)
                    .frame(width: 58, height: 58).background(.green.opacity(0.08), in: .rect(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spriglet").font(.title.bold())
                    Text("A little quiet company").foregroundStyle(.secondary)
                }
                Spacer()
                Text(runtime.status).font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: .capsule)
            }

            Text("Meet Sprout: a small idle moment, a short walk, a happy pet reaction, and a gentle settle.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Play Character Sample", systemImage: "play.fill") { runtime.characterSample() }
                .buttonStyle(.borderedProminent)
                .disabled(!runtime.permitsMotion || runtime.sampling)
            if let issue = runtime.characterIssue {
                Text(issue).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Section("Quiet company") {
                    Toggle("Quiet Behavior", isOn: Binding(get: { runtime.autonomousBehavior }, set: { runtime.setAutonomousBehavior($0) }))
                    Text("Occasional idle moments and naps. Your choices stay on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Idle") { runtime.preview(.lookAround) }
                        Button(runtime.isSleeping ? "Wake Up" : "Nap") {
                            runtime.preview(runtime.isSleeping ? .wakeUp : .fallAsleep)
                        }
                    }.disabled(!runtime.permitsMotion)
                }.disabled(runtime.sampling)
                Section("Try the companion") {
                    HStack {
                        Button("Pet") { runtime.play() }
                        Button("Walk Left") { runtime.walk(direction: .walkLeft) }
                        Button("Walk Right") { runtime.walk(direction: .walkRight) }
                    }.disabled(!runtime.permitsMotion || runtime.sampling)
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
                    Text("Spriglet remembers where you place it. If that display is unavailable, it stays within reach on your main display.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(runtime.sampling)
                Section("Measurements · refresh on demand") {
                    LabeledContent("Submitted frames", value: "\(runtime.submittedFrames)")
                    LabeledContent("Quiet moments", value: "\(runtime.automaticActionCount)")
                    LabeledContent("Resting deadline", value: runtime.hasScheduledBehavior ? "Scheduled" : "None")
                    LabeledContent("Physical footprint", value: runtime.footprintMiB.map { $0.formatted(.number.precision(.fractionLength(1))) + " MiB" } ?? "Unavailable")
                    LabeledContent("Desktop position", value: runtime.positionDescription)
                    LabeledContent("Low Power Mode", value: runtime.lowPower ? "On" : "Off")
                    LabeledContent("Reduce Motion", value: runtime.reduceMotion ? "On" : "Off")
                    HStack {
                        Button("Refresh") { runtime.refreshMeasurements() }
                        Button(runtime.sampling ? "Checking…" : "Run Automatic Check") { runtime.runProbe() }
                        if runtime.reportJSON != nil {
                            Button("Copy Report") { runtime.copyReport() }
                        }
                    }.disabled(runtime.sampling)
                    Button("Run 100-Cycle Check") { runtime.runSoak() }
                        .disabled(runtime.sampling)
                    Text("About 6–7 minutes. Checks repeated activity and resting; cancel any time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if runtime.sampling {
                Button("Cancel Check") { runtime.cancelProbe() }
            }
            Text(runtime.sampling ? runtime.diagnosticProgress + " Your saved choices stay unchanged." : runtime.message)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { runtime.refreshMeasurements() }
    }
}
