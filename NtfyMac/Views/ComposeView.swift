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
                    Text("Publish Message").font(.title3.bold())
                    Text(subscription.topicURLString).font(.caption).foregroundStyle(.secondary)
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
                            .font(.body)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                    LabeledField("Priority") {
                        Picker("", selection: $req.priority) {
                            ForEach(NtfyPriority.allCases, id: \.self) { p in
                                Text(p.label).tag(p.rawValue)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden()
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
                            .font(.caption).foregroundStyle(.red)
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
        .frame(width: 480, height: 600)
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
