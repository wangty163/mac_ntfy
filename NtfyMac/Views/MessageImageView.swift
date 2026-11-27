//
//  MessageImageView.swift
//  NtfyMac
//

import SwiftUI

struct MessageImageView<Failure: View>: View {
    private let url: URL?
    private let loadedImage: NSImage?

    @ViewBuilder
    let failure: () -> Failure

    init(url: URL, @ViewBuilder failure: @escaping () -> Failure) {
        self.url = url
        self.loadedImage = nil
        self.failure = failure
    }

    init(image: NSImage, @ViewBuilder failure: @escaping () -> Failure) {
        self.url = nil
        self.loadedImage = image
        self.failure = failure
    }

    private var imageShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
    }

    var body: some View {
        Group {
            if let loadedImage {
                imageContent(Image(nsImage: loadedImage))
            }
            else if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                        case .success(let image):
                            imageContent(image)

                        case .failure:
                            failure()

                        default:
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 100)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func imageContent(_ image: Image) -> some View {
        ViewThatFits(in: .horizontal) {
            image
                .clipShape(imageShape)

            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(imageShape)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
