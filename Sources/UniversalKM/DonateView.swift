import SwiftUI
import UniversalKMCore

/// The donate section of the panel, as in LocalAIBar: the message and the ways to donate from
/// DeMoZ/donations (design D18). A click on a way opens its payment page in the browser.
struct DonateView: View {
    @ObservedObject var model: DonateModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Support UniversalKM").font(.subheadline.weight(.semibold))
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { close() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Close")
            }
            if let info = model.info {
                if let message = info.message?.resolved(for: model.languages) {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(info.methods, id: \.id) { method in
                    Button { model.open(method) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.title.resolved(for: model.languages) ?? method.id)
                                .font(.callout.weight(.semibold))
                            if let description = method.description?.resolved(for: model.languages) {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.pink.opacity(0.12)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(method.url.absoluteString)
                }
            } else if !model.isLoading {
                Text("Could not load the ways to support. Check your internet connection and open this again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
