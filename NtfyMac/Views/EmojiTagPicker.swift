//
//  EmojiTagPicker.swift
//  NtfyMac
//
//  An Emoji Picker that returns the shortcodes for tags.
//

import SwiftUI

struct EmojiTagPicker: View {
    @Binding var tagsText: String

    @State private var searchText = ""
    @State private var isPresented = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 6
    )

    private var filteredEntries: [EmojiEntry] {
        guard !searchText.isEmpty else {
            return EmojiMap.entries
        }

        return EmojiMap.entries.filter {
            $0.shortcode.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Button {
            if !isPresented {
                searchText = ""
            }
            isPresented.toggle()
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 16))
                .frame(width: 28, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(
                            Color.secondary.opacity(0.3),
                            lineWidth: 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Insert emoji tag")
        .popover(isPresented: $isPresented) {
            VStack(spacing: 10) {
                TextField("Search emojis...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(EmojiCategory.allCases) { category in
                            let entries = filteredEntries.filter {
                                $0.category == category
                            }

                            if !entries.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(category.rawValue)
                                        .font(.headline)
                                        .padding(.vertical, 4)

                                    LazyVGrid(
                                        columns: columns,
                                        spacing: 8
                                    ) {
                                        ForEach(entries) { entry in
                                            Button {
                                                insertTag(entry.shortcode)
                                                DispatchQueue.main.async {
                                                    isPresented = false
                                                }
                                            } label: {
                                                Text(entry.emoji)
                                                    .font(.system(size: 22))
                                                    .frame(maxWidth: .infinity)
                                                    .frame(height: 36)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .help(entry.shortcode)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(width: 300, height: 280)
            }
            .padding(12)
            .frame(width: 324)
        }
    }

    private func insertTag(_ shortcode: String) {
        let current = tagsText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if current.isEmpty {
            tagsText = shortcode
        } else if current.hasSuffix(",") {
            tagsText = current + " " + shortcode
        } else {
            tagsText = current + ", " + shortcode
        }
    }
}
