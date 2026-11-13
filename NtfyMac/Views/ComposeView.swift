//
//  ComposeView.swift
//  NtfyMac
//
//  Publish a message to a topic — covers titles, priority, tags, click URL,
//  scheduled delivery, attachments and Markdown.
//

import SwiftUI

struct ComposeView: View {
    let subscription: Subscription
    @Environment(\.dismiss) private var dismiss

    @State private var req = PublishRequest()
    @State private var tagsText = ""
    @State private var sending = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Publish Message").appFont(.title3, weight: .bold)
                    Text(subscription.topicURLString).appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledField("Title") {
                        TextField("Optional title", text: $req.title).textFieldStyle(.roundedBorder)
                    }
                    LabeledField("Message") {
                        TextEditor(text: $req.message)
                            .frame(height: 110)
                            .appFont(.body)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                    LabeledField("Priority") {
                        HStack(spacing: 6) {
                            ForEach(NtfyPriority.allCases, id: \.self) { priority in
                                let isSelected = req.priority == priority.rawValue

                                Button {
                                    req.priority = priority.rawValue
                                } label: {
                                    VStack(spacing: 2) {
                                        Image(systemName: priority.symbol)
                                            .font(.system(size: 15, weight: .semibold))

                                        Text(priority.label)
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundStyle(
                                        isSelected ? priority.tint : .secondary
                                    )
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(
                                                isSelected
                                                    ? priority.tint.opacity(0.15)
                                                    : Color.clear
                                            )
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(
                                                isSelected
                                                    ? priority.tint
                                                    : Color.secondary.opacity(0.2),
                                                lineWidth: isSelected ? 1.5 : 1
                                            )
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .help(priority.label)
                            }
                        }
                    }
                    LabeledField("Tags (comma separated)") {
                        TextField("warning, skull", text: $tagsText).textFieldStyle(.roundedBorder)
                    }
                    LabeledField("Click URL") {
                        TextField("https://…", text: $req.click).textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 12) {
                        LabeledField("Delay") {
                            TextField("e.g. 30min, 9am", text: $req.delay).textFieldStyle(.roundedBorder)
                        }
                        LabeledField("Attach URL") {
                            TextField("https://…/file.jpg", text: $req.attachURL).textFieldStyle(.roundedBorder)
                        }
                    }
                    Toggle("Format body as Markdown", isOn: $req.markdown)
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .appFont(.caption).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    send()
                } label: {
                    if sending { ProgressView().scaleEffect(0.6).frame(width: 60) }
                    else { Label("Send", systemImage: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(sending || req.message.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 620)
    }

    private func send() {
        sending = true
        errorText = nil
        req.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task { @MainActor in
            do {
                try await NtfyPublisher.publish(req, to: subscription)
                sending = false
                dismiss()
            } catch {
                sending = false
                errorText = (error as? NtfyError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
