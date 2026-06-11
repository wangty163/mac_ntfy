//
//  MessageDetailView.swift
//  NtfyMac
//

import SwiftUI

struct MessageDetailView: View {
    let stored: StoredMessage
    let subscription: Subscription

    @State private var actionStatus: [String: String] = [:]
    @State private var runningActionID: String?

    private var message: NtfyMessage { stored.message }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let body = message.message, !body.isEmpty {
                    bodyView(body)
                }

                if let attachment = message.attachment {
                    attachmentView(attachment)
                }

                if let actions = message.actions, !actions.isEmpty {
                    actionsView(actions)
                }

                metadataView
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Chip(text: subscription.name, systemImage: "number", tint: subscription.accentColor)
                Chip(text: message.resolvedPriority.label,
                     systemImage: message.resolvedPriority.symbol,
                     tint: message.resolvedPriority.tint)
                Spacer()
                TimestampText(date: message.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(headerTitle)
                .font(.system(size: 24, weight: .bold))
                .textSelection(.enabled)

            if !message.labelTags.isEmpty {
                FlexibleTagRow(tags: message.labelTags, tint: subscription.accentColor)
            }
        }
    }

    private var headerTitle: String {
        let prefix = message.emojiTags.joined()
        let base = message.displayTitle(fallbackTopic: subscription.name)
        return prefix.isEmpty ? base : "\(prefix) \(base)"
    }

    @ViewBuilder
    private func bodyView(_ body: String) -> some View {
        Group {
            if message.isMarkdown, let attributed = try? AttributedString(
                markdown: body,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
            } else {
                Text(body)
            }
        }
        .font(.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
    }

    // MARK: Attachment

    private func attachmentView(_ attachment: NtfyAttachment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Attachment", systemImage: "paperclip")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if attachment.isImage, let url = attachment.fileURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFit()
                            .frame(maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    case .failure:
                        attachmentRow(attachment)
                    default:
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            } else {
                attachmentRow(attachment)
            }
        }
    }

    private func attachmentRow(_ attachment: NtfyAttachment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .font(.title2)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name).fontWeight(.medium)
                if let size = attachment.humanSize {
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let url = attachment.fileURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .cardBackground()
    }

    // MARK: Actions

    private func actionsView(_ actions: [NtfyAction]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Actions", systemImage: "bolt")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(actions) { action in
                HStack(spacing: 10) {
                    Button {
                        run(action)
                    } label: {
                        Label(action.label, systemImage: action.symbol)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(subscription.accentColor)
                    .disabled(runningActionID == action.id)

                    if runningActionID == action.id {
                        ProgressView().scaleEffect(0.6)
                    } else if let status = actionStatus[action.id] {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func run(_ action: NtfyAction) {
        runningActionID = action.id
        Task { @MainActor in
            let result = await ActionRunner.run(action)
            runningActionID = nil
            switch result {
            case .opened: actionStatus[action.id] = "Opened ↗"
            case let .httpSucceeded(code): actionStatus[action.id] = "Sent · \(code)"
            case let .httpFailed(reason): actionStatus[action.id] = "Failed · \(reason)"
            case let .unsupported(reason): actionStatus[action.id] = reason
            }
        }
    }

    // MARK: Metadata

    private var metadataView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            metaRow("Topic", subscription.topic)
            metaRow("Server", subscription.serverHost)
            metaRow("Message ID", message.id)
            if let click = message.clickURL {
                HStack {
                    Text("Click").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Link(click.absoluteString, destination: click).lineLimit(1)
                }
                .font(.caption)
            }
            metaRow("Received", AppDateFormat.fullTimestamp(message.date))
        }
        .font(.caption)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
    }
}

/// Wraps tag chips onto multiple lines.
struct FlexibleTagRow: View {
    let tags: [String]
    var tint: Color

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Chip(text: tag, tint: tint)
            }
        }
    }
}

/// A minimal flow layout for wrapping chips (macOS 13 compatible).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                height += rowHeight + spacing
                rowHeight = 0
                x = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
