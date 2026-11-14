//
//  ComposeView.swift
//  NtfyMac
//
//  Publish a message to a topic — covers titles, priority, tags, click URL,
//  scheduled delivery, attachments and Markdown.
//

import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    private enum AttachmentMode: String, CaseIterable {
        case url = "Attach file by URL"
        case file = "Attach local file"
    }

    let subscription: Subscription
    @Environment(\.dismiss) private var dismiss

    @State private var req = PublishRequest()
    @State private var tagsText = ""
    @State private var sending = false
    @State private var errorText: String?
    @State private var attachmentMode: AttachmentMode = .url
    @State private var selectedFileURL: URL?
    @State private var showingFileImporter = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Publish Message").appFont(.title3, weight: .bold)
                    Text(subscription.topicURLString)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledField("Title") {
                        TextField("Optional title", text: $req.title)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledField("Message") {
                        TextEditor(text: $req.message)
                            .frame(height: 110)
                            .appFont(.body)
                            .padding(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.quaternary)
                            )
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
                        HStack(spacing: 8) {
                            EmojiTagPicker(tagsText: $tagsText)

                            TextField("warning, skull", text: $tagsText)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    LabeledField("Click URL") {
                        TextField("https://…", text: $req.click)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledField("Delay") {
                        TextField("e.g. 30min, 9am", text: $req.delay)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledField("Attachment") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Attachment type", selection: $attachmentMode) {
                                ForEach(AttachmentMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Group {
                                if attachmentMode == .url {
                                    TextField("https://…/file.jpg", text: $req.attachURL)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    HStack(spacing: 8) {
                                        if let selectedFileURL {
                                            Label(
                                                selectedFileURL.lastPathComponent,
                                                systemImage: "doc"
                                            )
                                            .lineLimit(1)
                                            .truncationMode(.middle)

                                            Spacer()

                                            Button {
                                                self.selectedFileURL = nil
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Remove attachment")
                                        } else {
                                            Text("No file selected")
                                                .foregroundStyle(.secondary)

                                            Spacer()

                                            Button("Choose File…") {
                                                showingFileImporter = true
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(height: 28)
                        }
                    }

                    Toggle("Format body as Markdown", isOn: $req.markdown)

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .appFont(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    send()
                } label: {
                    if sending {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 60)
                    } else {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(sending || req.message.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 720)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                selectedFileURL = urls.first
                req.attachURL = ""
                errorText = nil

            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        .onChange(of: attachmentMode) { newMode in
            if newMode == .url {
                selectedFileURL = nil
            } else {
                req.attachURL = ""
            }
            errorText = nil
        }
    }

    private func send() {
        sending = true
        errorText = nil

        req.tags =
            tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Only URL mode sends the attach URL through the JSON API.
        if attachmentMode == .file {
            req.attachURL = ""
        }

        let requestToSend = req
        let fileURLToSend = attachmentMode == .file ? selectedFileURL : nil

        Task { @MainActor in
            do {
                var attachment: LocalAttachment?

                if let fileURL = fileURLToSend {
                    let didStartAccessing =
                        fileURL.startAccessingSecurityScopedResource()
                    defer {
                        if didStartAccessing {
                            fileURL.stopAccessingSecurityScopedResource()
                        }
                    }

                    let data = try Data(contentsOf: fileURL)
                    let filename = fileURL.lastPathComponent
                    let contentType =
                        UTType(
                            filenameExtension: fileURL.pathExtension
                        )?.preferredMIMEType ?? "application/octet-stream"

                    attachment = LocalAttachment(
                        data: data,
                        filename: filename,
                        contentType: contentType
                    )
                }

                try await NtfyPublisher.publish(
                    requestToSend,
                    to: subscription,
                    attachment: attachment
                )

                sending = false
                dismiss()
            } catch {
                sending = false
                errorText =
                    (error as? NtfyError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
