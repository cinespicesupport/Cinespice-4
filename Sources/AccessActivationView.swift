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
                    Text("Activate once on this device. Your paid-group and channel memberships keep access available.").foregroundStyle(.secondary)
                    Text(telegram.accessMessage).accessibilityAddTraits(.updatesFrequently)
                    Button { telegram.checkAccess(start: true) } label: {
                        HStack { if telegram.accessBusy { ProgressView() }; Text(telegram.accessBusy ? "Verifying…" : "Activate") }
                    }.buttonStyle(.borderedProminent).disabled(telegram.accessBusy)
                    ForEach(Array(config.channels.enumerated()), id: \.offset) { index, channel in
                        if telegram.accessMissing.contains(index) {
                            HStack {
                                Button("Join \(channel.title)") { telegram.joinCommunity(channel) }
                                Spacer()
                                if let url = AccessConfiguration.safeLink(channel.url) { Link("Open", destination: url) }
                            }.disabled(telegram.accessBusy)
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
