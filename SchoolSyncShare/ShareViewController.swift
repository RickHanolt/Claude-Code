import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Principal class for the share extension (no storyboard). Extracts a
/// subject + body from whatever Mail (or another app) shared, runs
/// `EmailParserService` over it, and presents `ShareConfirmationView` so the
/// user picks which detected date(s) are real events and which kid/school
/// they belong to before anything is saved.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { await loadContent() }
    }

    private func loadContent() async {
        guard
            let item = extensionContext?.inputItems.first as? NSExtensionItem,
            let attachments = item.attachments,
            !attachments.isEmpty
        else {
            close()
            return
        }

        var subject = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var bodyText = ""

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await provider.loadItemAsync(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    bodyText += text + "\n"
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
                if let html = try? await provider.loadItemAsync(forTypeIdentifier: UTType.html.identifier) as? String {
                    bodyText += html.strippingHTMLTags() + "\n"
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                // Covers .eml attachments. Read as raw text rather than a full
                // MIME parse — good enough to find dates, imperfect for
                // heavily HTML-formatted emails.
                if let url = try? await provider.loadItemAsync(forTypeIdentifier: UTType.fileURL.identifier) as? URL,
                   let raw = try? String(contentsOf: url, encoding: .utf8) {
                    if let subjectLine = raw.range(of: #"(?m)^Subject:\s*(.+)$"#, options: .regularExpression) {
                        subject = String(raw[subjectLine]).replacingOccurrences(of: "Subject:", with: "").trimmingCharacters(in: .whitespaces)
                    }
                    bodyText += raw.strippingHTMLTags() + "\n"
                }
            }
        }

        let candidates = EmailParserService().extractCandidateEvents(subject: subject, bodyText: bodyText)
        presentConfirmation(subject: subject, candidates: candidates)
    }

    private func presentConfirmation(subject: String, candidates: [ParsedCandidateEvent]) {
        let confirmationView = ShareConfirmationView(
            subject: subject.isEmpty ? "Forwarded event" : subject,
            candidates: candidates,
            onSave: { [weak self] dtos in
                self?.save(dtos)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )

        let hosting = UIHostingController(rootView: confirmationView)
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hosting.didMove(toParent: self)
    }

    private func save(_ dtos: [SchoolEventDTO]) {
        try? SharedEventQueue.append(dtos)
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "SchoolSyncShare", code: 1))
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
