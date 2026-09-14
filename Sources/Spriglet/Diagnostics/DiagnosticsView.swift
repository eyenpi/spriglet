import SwiftUI

struct DiagnosticsView: View {
    let runtime: PetRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Developer Diagnostics").font(.title2.bold())
            Text("Finite checks of this process and its character sample.").foregroundStyle(.secondary)
            Form {
                stat("Submitted frames", value: "\(runtime.submittedFrames)")
                stat("Automatic moments", value: "\(runtime.automaticActionCount)")
                stat("Resting deadline", value: runtime.hasScheduledBehavior ? "Scheduled" : "None")
                stat("Physical footprint", value: runtime.footprintMiB.map { $0.formatted(.number.precision(.fractionLength(1))) + " MiB" } ?? "Unavailable")
                stat("Desktop position", value: runtime.positionDescription)
                stat("Low Power Mode", value: runtime.lowPower ? "On" : "Off")
                stat("Reduce Motion", value: runtime.reduceMotion ? "On" : "Off")
                HStack {
                    Button("Refresh") { runtime.refreshMeasurements() }
                    Button("Copy Report") { runtime.copyReport() }.disabled(runtime.reportJSON == nil)
                }
                Section("Character sample") {
                    Button("Play Character Sample") { runtime.characterSample() }.disabled(!runtime.canInteract)
                    Text("Idle → short walk → petting reaction → settle.").foregroundStyle(.secondary)
                }
                Section("Runtime checks") {
                    HStack {
                        Button("Run Automatic Check") { runtime.runProbe() }.disabled(runtime.sampling)
                        Button("Run 100-Cycle Check") { runtime.runSoak() }.disabled(runtime.sampling)
                    }
                    Text("Choices and placement are restored afterward. Diagnostics do not learn preferences or play sounds.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if runtime.sampling {
                Text(runtime.diagnosticProgress).font(.callout)
                Button("Cancel Check") { runtime.cancelProbe() }.keyboardShortcut(.cancelAction)
            } else {
                Text(runtime.message).font(.callout).foregroundStyle(.secondary)
            }
        }.padding(22).frame(width: 530, height: 560)
            .onAppear { runtime.refreshMeasurements() }
    }
    private func stat(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
