import SwiftUI

/// The menu bar panel. For now: header, a status placeholder (or the donate section) and the footer.
/// Task 3.3 adds the status, arrangement, hotkey and permission sections.
/// Layout and footer follow LocalAIBar.
struct MenuBarView: View {
    @ObservedObject var app: AppDelegate
    @ObservedObject var donate: DonateModel
    @State private var showDonate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if showDonate {
                DonateView(model: donate, close: { showDonate = false })
            } else {
                Text("Статус устройства появится после подключения Chameleon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        // Solid background: the default translucent material lets windows behind show through.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The app icon from the bundle; a `swift run` build has none and shows the generic one.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            Text("UniversalKM").font(.headline)
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                showDonate.toggle()
                if showDonate { donate.load() }
            } label: {
                Label("Поддержать", systemImage: "heart.fill")
            }
            .foregroundStyle(.pink)
            Button("Обновления") { app.checkForUpdates() }
                .help("Проверить обновления")
            Spacer()
            if !app.version.isEmpty {
                Text("v\(app.version)").foregroundStyle(.tertiary)
            }
            Button("Выход") { app.quit() }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}
