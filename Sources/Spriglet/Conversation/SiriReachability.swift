import Security

/// macOS delivers Siri and Shortcuts actions only to apps signed by a developer
/// team; `linkd` rejects ad hoc builds, such as the unsigned preview downloads.
enum SiriReachability {
    static let isReachable: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        return hasTeamIdentifier(staticCode)
    }()

    static func hasTeamIdentifier(_ code: SecStaticCode) -> Bool {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return !team.isEmpty
    }
}
