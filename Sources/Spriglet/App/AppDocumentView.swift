import SwiftUI

enum AppLinks {
    static let privacy = URL(string: "https://meetspriglet.com/privacy")!
    static let support = URL(string: "https://meetspriglet.com/support")!
    static let email = URL(string: "mailto:support@meetspriglet.com")!

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
}

/// Bundled documents remain readable without an internet connection.
struct AppDocumentView: View {
    let title: String
    let resource: String
    let fileExtension: String
    let onlineURL: URL?

    private var document: String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: fileExtension) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ScrollView {
                if let document {
                    Text(document.replacingOccurrences(of: "# Privacy\n\n", with: ""))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 12)
                } else {
                    Text("This document could not be opened. Please contact support.")
                }
            }
            Divider()
            HStack {
                if let onlineURL { Link("Read Online", destination: onlineURL) }
                Spacer()
                Link("Get Support", destination: AppLinks.support)
                Link("Email Support", destination: AppLinks.email)
            }
        }
        .padding(24)
        .frame(minWidth: 400, minHeight: 320)
    }
}
