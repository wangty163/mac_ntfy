//
//  AddSubscriptionView.swift
//  NtfyMac
//

import SwiftUI

struct AddSubscriptionView: View {
    @EnvironmentObject var manager: SubscriptionManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// When set, the sheet edits an existing subscription instead of creating one.
    var editing: Subscription? = nil

    @State private var server = "https://ntfy.sh"
    @State private var topic = ""
    @State private var displayName = ""
    @State private var authMode: AuthMode = .none
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var accentHex = Theme.accentPalette[0]
    @State private var priorityFilter: Set<Int> = []
    @State private var tagFilter = ""

    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    enum AuthMode: String, CaseIterable { case none = "None", basic = "Username", token = "Token" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    serverSection
                    authSection
                    appearanceSection
                    filterSection
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 640)
        .onAppear(perform: loadEditing)
    }

    private var isValid: Bool {
        !topic.trimmingCharacters(in: .whitespaces).isEmpty
            && !server.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 40, height: 40)
                Image(systemName: editing == nil ? "plus" : "pencil")
                    .foregroundStyle(.white).font(.headline)
            }
            VStack(alignment: .leading) {
                Text(editing == nil ? "Add Subscription" : "Edit Subscription")
                    .font(.title3.bold())
                Text("Receive notifications from an ntfy topic")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var serverSection: some View {
        SectionCard(title: "Server & Topic", systemImage: "server.rack") {
            LabeledField("Server URL") {
                TextField("https://ntfy.sh", text: $server)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Topic") {
                TextField("my-alerts", text: $topic)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Display Name (optional)") {
                TextField(topic.isEmpty ? "My Alerts" : topic, text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var authSection: some View {
        SectionCard(title: "Authentication", systemImage: "lock") {
            Picker("", selection: $authMode) {
                ForEach(AuthMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch authMode {
            case .none:
                Text("Use for public, unprotected topics.")
                    .font(.caption).foregroundStyle(.secondary)
            case .basic:
                LabeledField("Username") {
                    TextField("user", text: $username).textFieldStyle(.roundedBorder)
                }
                LabeledField("Password") {
                    SecureField("••••••", text: $password).textFieldStyle(.roundedBorder)
                }
            case .token:
                LabeledField("Access Token") {
                    SecureField("tk_…", text: $token).textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var appearanceSection: some View {
        SectionCard(title: "Appearance", systemImage: "paintpalette") {
            HStack(spacing: 10) {
                ForEach(Theme.accentPalette, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex) ?? .accentColor)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().stroke(Color.primary, lineWidth: accentHex == hex ? 2 : 0)
                        )
                        .onTapGesture { accentHex = hex }
                }
            }
        }
    }

    private var filterSection: some View {
        SectionCard(title: "Filters (optional)", systemImage: "line.3.horizontal.decrease.circle") {
            Text("Only notify for these priorities:")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(NtfyPriority.allCases, id: \.self) { p in
                    Toggle(isOn: Binding(
                        get: { priorityFilter.contains(p.rawValue) },
                        set: { on in
                            if on { priorityFilter.insert(p.rawValue) }
                            else { priorityFilter.remove(p.rawValue) }
                        }
                    )) {
                        Text(p.label)
                    }
                    .toggleStyle(.button)
                    .tint(p.tint)
                }
            }
            LabeledField("Required tags (comma separated)") {
                TextField("alert, server", text: $tagFilter)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                runTest()
            } label: {
                if testing { ProgressView().scaleEffect(0.6).frame(width: 60) }
                else { Label("Test", systemImage: "bolt.horizontal") }
            }
            .disabled(!isValid || testing)

            if let testResult {
                Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(testOK ? .green : .red)
            }

            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(editing == nil ? "Subscribe" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
        }
        .padding(16)
    }

    // MARK: Logic

    private func loadEditing() {
        if let editing {
            server = editing.normalizedBaseURL
            topic = editing.topic
            displayName = editing.displayName
            accentHex = editing.accentHex
            priorityFilter = editing.filters.priorities
            tagFilter = editing.filters.tags.joined(separator: ", ")
            switch editing.auth {
            case .none: authMode = .none
            case let .basic(u, p): authMode = .basic; username = u; password = p
            case let .token(t): authMode = .token; token = t
            }
        } else {
            server = settings.defaultServer
        }
    }

    private func buildSubscription() -> Subscription {
        var sub = editing ?? Subscription()
        sub.baseURL = server
        sub.topic = topic.trimmingCharacters(in: .whitespaces)
        sub.displayName = displayName.trimmingCharacters(in: .whitespaces)
        sub.accentHex = accentHex
        switch authMode {
        case .none: sub.auth = .none
        case .basic: sub.auth = .basic(username: username, password: password)
        case .token: sub.auth = .token(token)
        }
        var filters = SubscriptionFilters()
        filters.priorities = priorityFilter
        filters.tags = tagFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        sub.filters = filters
        return sub
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task { @MainActor in
            let result = await NtfyPublisher.test(subscription: buildSubscription())
            testing = false
            switch result {
            case .success:
                testOK = true; testResult = "Connection OK"
            case let .failure(error):
                testOK = false
                testResult = (error as? NtfyError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func save() {
        let sub = buildSubscription()
        if editing != nil {
            manager.updateSubscription(sub)
        } else {
            manager.addSubscription(sub)
        }
        dismiss()
    }
}

// MARK: - Reusable building blocks

struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}
