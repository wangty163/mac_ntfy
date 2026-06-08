//
//  MainView.swift
//  NtfyMac
//
//  The full management window: subscriptions sidebar, message list, and detail.
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject var manager: SubscriptionManager
    @State private var selection: SidebarSelection? = .all
    @State private var selectedMessageID: String?
    @State private var showingAdd = false
    @State private var editingSub: Subscription?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, showingAdd: $showingAdd, editing: $editingSub)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } content: {
            MessageListView(selection: selection ?? .all,
                            selectedMessageID: $selectedMessageID)
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        } detail: {
            detailColumn
        }
        .frame(minWidth: 920, minHeight: 560)
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionView()
        }
        .sheet(item: $editingSub) { sub in
            AddSubscriptionView(editing: sub)
        }
        .onChange(of: selection) { _ in selectedMessageID = nil }
        // `.task(id:)` (rather than `.onChange`) so a reveal that was queued
        // before this view existed — e.g. a notification clicked while the
        // window was closed — is still honoured when the view first appears.
        .task(id: manager.pendingReveal?.subscriptionID) {
            if let reveal = manager.pendingReveal {
                selection = .subscription(reveal.subscriptionID)
            }
        }
        .onDisappear { AppActivation.exitWindowModeIfNeeded() }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selectedMessageID,
           let stored = manager.messages.first(where: { $0.id == id }),
           let sub = manager.subscription(id: stored.subscriptionID) {
            MessageDetailView(stored: stored, subscription: sub)
        } else {
            DetailPlaceholder()
        }
    }
}

struct DetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.brandGradient.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "bell.and.waves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.brandGradient)
            }
            Text("Select a message")
                .font(.title2.weight(.semibold))
            Text("Pick a notification from the list to see its full content, attachments and actions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
