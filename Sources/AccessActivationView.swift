import SwiftUI

struct AccessActivationView: View {
    @EnvironmentObject private var telegram: TelegramClient
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                CinespiceWordmark()
                Image(systemName: "checkmark.shield.fill").font(.system(size: 48)).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Activate your access").font(.largeTitle.bold())
                if let config = telegram.accessConfiguration {
                    Text("Activate once on this device. Stay in the paid group to keep access.").foregroundStyle(.secondary)
                    Text(telegram.accessMessage).accessibilityAddTraits(.updatesFrequently)
                    Button { telegram.checkAccess(start: true) } label: {
                        HStack { if telegram.accessBusy { ProgressView() }; Text(telegram.accessBusy ? "Verifying…" : "Activate") }
                    }.buttonStyle(.borderedProminent).disabled(telegram.accessBusy)
                    if !config.channels.isEmpty {
                        Text("Optional: join our channel for updates.").foregroundStyle(.secondary)
                        ForEach(config.channels) { channel in
                            if let url = AccessConfiguration.safeLink(channel.url) { Link("Open \(channel.title)", destination: url) }
                        }
                    }
                    if telegram.accessNeedsPaid || telegram.accessDenied, let url = AccessConfiguration.safeLink(config.contactURL) {
                        Link(telegram.accessDenied ? "Contact support" : "Request paid-group access", destination: url)
                    }
                } else {
                    Text("Access setup is pending. Please contact the app owner for a configured build.").foregroundStyle(.secondary)
                }
                Button("Sign out") { telegram.logOut() }.buttonStyle(.bordered)
            }.buttonBorderShape(.capsule).controlSize(.large).padding(28).frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}
