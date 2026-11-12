//
//  MessageImageView.swift
//  NtfyMac
//

import SwiftUI

struct MessageImageView<Failure: View>: View {
    let url: URL
    @ViewBuilder let failure: () -> Failure

    private var imageShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: Theme.cornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                ViewThatFits(in: .horizontal) {
                    // Natural image size, with its own clipping bounds.
                    image
                        .clipShape(imageShape)

                    // Scale down when the natural size doesn't fit.
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(imageShape)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .failure:
                failure()

            default:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
