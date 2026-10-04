/// Complete native presentation data supplied by the runtime. Preference values
/// remain independent of these session-only controls and display choices.
struct SettingsState {
    let preferences: CompanionPreferences
    let displays: [HomeDisplay]
    let controls: CompanionControlState
}
