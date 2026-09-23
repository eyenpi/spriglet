import AppKit
import SprigletCore
import SwiftUI

struct SprigletSettingsView: View {
    let runtime: PetRuntime
    let login: LoginItemService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab: SettingsTab = .companion
    @State private var nameDraft = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Companion", systemImage: "leaf", value: .companion) { companion }
            Tab("Desktop", systemImage: "macwindow", value: .desktop) { desktop }
            Tab("General", systemImage: "gearshape", value: .general) { general }
        }
        .frame(width: 520, height: 590)
        .onAppear { nameDraft = runtime.petName; login.refresh() }
        .onChange(of: runtime.petName) { _, value in nameDraft = value }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { login.refresh() }
        }
    }

    private var companion: some View {
        settingsPage {
            Section("Your companion") {
                HStack {
                    TextField("Name", text: $nameDraft)
                        .accessibilityLabel("Companion name")
                        .onSubmit(commitName)
                    Button("Save Name", action: commitName)
                        .disabled(nameDraft == runtime.petName)
                }
                Text(runtime.traitDescription).foregroundStyle(.secondary)
                Picker("Size", selection: Binding(get: { runtime.displaySize }, set: { runtime.setDisplaySize($0) })) {
                    ForEach(PetDisplaySize.allCases, id: \.self) { size in Text(size.title).tag(size) }
                }.pickerStyle(.segmented)
            }

            Section("Activity") {
                Toggle(AppText.automaticMoments, isOn: Binding(get: { runtime.autonomousBehavior }, set: { runtime.setAutonomousBehavior($0) }))
                    .help("Allow occasional greetings, pauses, and naps. Turning this off keeps only the interactions you request.")
                Picker("Frequency", selection: Binding(get: { runtime.activityLevel }, set: { runtime.setActivityLevel($0) })) {
                    ForEach(PetActivityLevel.allCases, id: \.self) { level in Text(level.title).tag(level) }
                }.pickerStyle(.segmented).disabled(!runtime.autonomousBehavior)
                detail(runtime.autonomousBehavior ? runtime.activityLevel.summary : "Only the moments you ask for. Petting and play are still available.")
                Toggle(AppText.parkedMode, isOn: Binding(get: { runtime.isParked }, set: { runtime.setParked($0) }))
                    .help("Keep automatic moments and firefly play in one place. You can still drag or ask for a walk.")
                detail(runtime.isParked
                    ? "Staying put. You can still drag or ask for a walk."
                    : "Short strolls return to their starting spot on the same display.")
            }

            Section("Spend a moment together") {
                HStack {
                    Button("Pet \(runtime.petName)", systemImage: "hand.tap") { runtime.play() }
                        .disabled(!runtime.canInteract)
                    Button(AppText.playWithFirefly, systemImage: "sparkle") { runtime.playWithFirefly() }
                        .disabled(!runtime.canPlayWithFirefly)
                }
                if !runtime.permitsMotion { detail(motionUnavailableMessage) }
                else { detail("Sounds are optional in General. Parked firefly play stays in place.") }
            }

            Section("Recent preferences") {
                detail(runtime.recentPreferenceDescription)
                Button(AppText.clearRecentPreferences) { runtime.resetRecentPreferences() }
                    .help("Forget recent petting, games, and placement preferences. Keep the name, stable traits, and settings.")
            }
        }
    }

    private var desktop: some View {
        settingsPage {
            Section("Availability") {
                Toggle(AppText.pause, isOn: Binding(get: { runtime.isPaused }, set: { runtime.setPaused($0) }))
                    .help("Stop animation and movement until you resume.")
                Toggle(AppText.hidePet, isOn: Binding(get: { runtime.isHidden }, set: { runtime.setHidden($0) }))
                Toggle(AppText.passClicksThrough, isOn: Binding(get: { runtime.clickThrough }, set: { runtime.setClickThrough($0) }))
                detail("Send clicks through the entire pet window to the app underneath. The Spriglet menu and Settings remain available.")
                Toggle("Show on All Spaces", isOn: Binding(get: { runtime.allSpaces }, set: { runtime.setAllSpaces($0) }))
                detail("The pet may remain visible over full-screen apps. Use \(AppText.hidePet) or \(AppText.passClicksThrough) when needed.")
            }
            Section("Placement") {
                if runtime.isEyeDocked {
                    Button("Return Acorn to Desktop") { runtime.returnFromTopBar() }
                    detail("Click the eyes to return home, or drag them downward and release Acorn where you want it.")
                } else {
                    Button("Move Acorn to Top Bar") { runtime.moveToTopBar() }
                    detail("Drag Acorn toward the top edge to turn into eyes beside the notch or along the menu bar.")
                }
                HStack {
                    Button(AppText.bringPetHome) { runtime.recenter() }
                    Button(AppText.nextDisplay) { runtime.moveToNextDisplay() }
                }
                HStack {
                    Text("Move pet")
                    Spacer()
                    moveButton("Left", symbol: "arrow.left", dx: -48)
                    moveButton("Down", symbol: "arrow.down", dy: -48)
                    moveButton("Up", symbol: "arrow.up", dy: 48)
                    moveButton("Right", symbol: "arrow.right", dx: 48)
                }
                HStack {
                    Button("Walk Left") { runtime.walk(direction: .walkLeft) }
                    Button("Walk Right") { runtime.walk(direction: .walkRight) }
                }.disabled(!runtime.canInteract)
                detail("Drag to place your companion. Its home is remembered and stays reachable when displays change.")
            }
            Section("Keyboard and VoiceOver") {
                detail("Use the Companion menu for keyboard commands. VoiceOver offers petting, play, parking, pause, and placement actions on the pet itself.")
                shortcut("Pet", keys: "⌥⌘P", spoken: "Option Command P")
                shortcut("Firefly", keys: "⌥⌘F", spoken: "Option Command F")
                shortcut(AppText.parkedMode, keys: "⌥⌘K", spoken: "Option Command K")
                detail("These shortcuts work while using Spriglet. Keyboard navigation follows your Mac’s settings.")
            }
        }
    }

    private var general: some View {
        settingsPage {
            Section("Sound") {
                Toggle("Soft Interaction Sounds", isOn: Binding(get: { runtime.soundEnabled }, set: { runtime.setSoundEnabled($0) }))
                detail("A brief, quiet chime when you pet or play. Automatic activity stays silent.")
                Button(AppText.previewSound) { runtime.previewSound() }.disabled(!runtime.canPreviewSound)
                if runtime.soundEnabled && !runtime.canPreviewSound {
                    detail(AppPresentation.isTemporary ? "Sound previews are silent in temporary review mode." : "Show and resume the pet to preview its sound.")
                }
            }
            Section("Startup") {
                Toggle(AppText.launchAtLogin, isOn: Binding(get: { login.status.isRegistered }, set: { login.setEnabled($0) }))
                    .disabled(!login.allowsChanges)
                detail(loginDescription)
                if login.status == .requiresApproval || login.lastError != nil {
                    Button(AppText.openLoginItems + "…") { login.openSettings() }.disabled(!login.allowsChanges)
                }
                if let error = login.lastError {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("About \(AppText.appName)") {
                LabeledContent("Version", value: AppLinks.versionDescription)
                detail(AppText.aboutText)
                Button(AppText.showQuickGuide) { openWindow(id: "welcome") }
                Button(AppText.privacyTitle + "…") { openWindow(id: "privacy") }
                Button(AppText.supportTitle + "…") { openWindow(id: "support") }
                Button(AppText.licenseTitle + "…") { openWindow(id: "license") }
            }
        }
    }

    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(runtime.petName).font(.title3.weight(.semibold))
                Spacer()
                Text(runtime.status).font(.callout).foregroundStyle(.secondary)
                    .accessibilityLabel("Companion status")
                    .accessibilityValue(runtime.status)
            }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 6)
            Form(content: content).formStyle(.grouped).disabled(runtime.sampling)
            Text(runtime.sampling ? "A development check is running. Settings return when it finishes." : runtime.message)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 16)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func shortcut(_ title: String, keys: String, spoken: String) -> some View {
        LabeledContent(title, value: keys)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) shortcut")
            .accessibilityValue(spoken)
    }

    private func moveButton(_ title: String, symbol: String, dx: CGFloat = 0, dy: CGFloat = 0) -> some View {
        Button(title, systemImage: symbol) { runtime.nudge(dx: dx, dy: dy) }
            .labelStyle(.iconOnly).accessibilityLabel("Move pet \(title.lowercased())")
            .help("Move pet \(title.lowercased())")
    }

    private func commitName() {
        runtime.renamePet(nameDraft)
        nameDraft = runtime.petName
    }

    private var motionUnavailableMessage: String {
        if let issue = runtime.characterIssue { return issue }
        if runtime.isHidden { return "Show the pet in Desktop settings to interact." }
        if runtime.isPaused { return "Resume in Desktop settings to interact." }
        if runtime.reduceMotion { return "Reduce Motion is on, so your companion stays still." }
        return "Your companion is resting while the system is unavailable."
    }

    private var loginDescription: String {
        if !login.allowsChanges { return "Launch at login is unavailable in this temporary review or validation copy." }
        switch login.status {
        case .notRegistered: return "Off until you choose it. Keep Spriglet in a stable location, such as Applications."
        case .enabled: return "Spriglet will open when you sign in to your Mac."
        case .requiresApproval: return "Allow Spriglet in Login Items in System Settings to finish enabling it."
        case .notFound: return "macOS couldn’t locate this app as a login item. Keep it in a stable location and try again."
        }
    }

    private enum SettingsTab: Hashable { case companion, desktop, general }
}
