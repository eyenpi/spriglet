import SwiftUI

/// Bundled documents remain readable without an internet connection.
struct AppDocumentView: View {
    @Environment(\.openWindow) private var openWindow
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
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(document.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                            if !block.hasPrefix("# ") {
                                documentBlock(block)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12)
                } else {
                    Text(AppText.documentUnavailable)
                }
            }
            Divider()
            HStack {
                if let onlineURL { Link(AppText.readOnline, destination: onlineURL) }
                Spacer()
                if resource != "Support" {
                    Button(AppText.supportTitle) { openWindow(id: "support") }
                }
                if onlineURL != AppLinks.support {
                    Link(AppText.getSupport, destination: AppLinks.support)
                }
                Link(AppText.emailSupport, destination: AppLinks.email)
            }
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 320)
    }

    @ViewBuilder
    private func documentBlock(_ block: String) -> some View {
        if fileExtension == "md", block.hasPrefix("## ") {
            Text(String(block.dropFirst(3))).font(.headline).accessibilityAddTraits(.isHeader)
        } else if fileExtension == "md" {
            Text((try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
        } else {
            Text(block)
        }
    }

}
