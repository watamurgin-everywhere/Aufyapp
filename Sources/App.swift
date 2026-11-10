import SwiftUI
import UIKit

// MARK: - App entry

@main
struct AufyApp: App {
    init() {
        // Runs a scheduled wipe (if any) the next time the app is opened.
        WipeManager.runPending()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

// MARK: - Wipe logic

enum WipeKind: String {
    case small
    case full
}

enum WipeManager {
    private static let flagKey = "aufy.pendingWipe"
    static var lastRun: WipeKind?

    static func schedule(_ kind: WipeKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: flagKey)
        UserDefaults.standard.synchronize()
    }

    static func runPending() {
        guard let raw = UserDefaults.standard.string(forKey: flagKey),
              let kind = WipeKind(rawValue: raw) else { return }

        let home = URL(fileURLWithPath: NSHomeDirectory())

        // Small delete: the app's own files and caches.
        clear(home.appendingPathComponent("Documents"))
        clear(home.appendingPathComponent("tmp"))
        clear(home.appendingPathComponent("Library/Caches"))
        clear(home.appendingPathComponent("Library/Application Support"))

        // Full delete: also settings, saved folder access, everything in Library.
        if kind == .full {
            if let id = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: id)
            }
            clear(home.appendingPathComponent("Library"))
        }

        UserDefaults.standard.removeObject(forKey: flagKey)
        UserDefaults.standard.synchronize()
        lastRun = kind
    }

    private static func clear(_ dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: []) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }
}

// MARK: - Signing profile info (App ID + expiry)

struct ProvisionInfo {
    var appID: String?
    var teamID: String?
    var expiry: Date?

    static func load() -> ProvisionInfo {
        var info = ProvisionInfo(appID: nil, teamID: nil, expiry: nil)
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound else { return info }

        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any] else {
            return info
        }
        info.expiry = plist["ExpirationDate"] as? Date
        if let ent = plist["Entitlements"] as? [String: Any] {
            info.appID = ent["application-identifier"] as? String
        }
        if let teams = plist["TeamIdentifier"] as? [String] {
            info.teamID = teams.first
        }
        return info
    }
}

func formatRemaining(until date: Date, now: Date) -> String {
    let total = Int(date.timeIntervalSince(now))
    if total <= 0 { return "EXPIRED" }
    let d = total / 86400
    let h = (total % 86400) / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return "\(d)d \(h)h \(m)m \(s)s"
}

// MARK: - Home screen

struct HomeView: View {
    @State private var showExplorer = false
    @State private var showWipeChoice = false
    @State private var message: String?

    private let info = ProvisionInfo.load()

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        showWipeChoice = true
                    } label: {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 52, height: 52)
                    }
                    .accessibilityLabel("Delete options")
                    .confirmationDialog("Delete Aufy data", isPresented: $showWipeChoice, titleVisibility: .visible) {
                        Button("Small delete") {
                            WipeManager.schedule(.small)
                            announce("Small delete scheduled. Close Aufy completely and open it again. Its data will be erased on that next open.")
                        }
                        Button("Full delete", role: .destructive) {
                            WipeManager.schedule(.full)
                            announce("Full delete scheduled. Close Aufy completely and open it again. Everything will be erased on that next open.")
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Small: erases Aufy's data on the next open.\nFull: erases everything, including settings and saved folder access, on the next open. iOS doesn't let an app uninstall itself, so you remove the icon yourself afterwards.")
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                HStack(spacing: 36) {
                    Button {
                        showExplorer = true
                    } label: {
                        Rectangle()
                            .fill(Color.black)
                            .frame(width: 150, height: 150)
                    }
                    .accessibilityLabel("File explorer")

                    Button {
                        switchIcon()
                    } label: {
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: 150, height: 150)
                    }
                    .accessibilityLabel("Switch app icon")
                }

                Spacer()

                VStack(spacing: 8) {
                    Text(appIDText)
                        .foregroundColor(.black)
                        .multilineTextAlignment(.center)
                    expiryText
                }
                .font(.system(.footnote, design: .monospaced))
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.light)
        .fullScreenCover(isPresented: $showExplorer) {
            ExplorerView()
        }
        .alert("Aufy", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .onAppear { reportWipeIfNeeded() }
    }

    // MARK: Bottom texts

    private var appIDText: String {
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        let id = info.appID ?? "not available"
        return "App ID: \(id)\nBundle ID: \(bundle)"
    }

    @ViewBuilder
    private var expiryText: some View {
        if let expiry = info.expiry {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text("Expires in: " + formatRemaining(until: expiry, now: context.date))
                    .foregroundColor(.black)
            }
        } else {
            Text("Expires in: unknown")
                .foregroundColor(.black)
        }
    }

    // MARK: Actions

    private func announce(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            message = text
        }
    }

    private func switchIcon() {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else {
            message = "This build can't switch icons."
            return
        }
        let target: String? = (app.alternateIconName == nil) ? "AppIconRed" : nil
        app.setAlternateIconName(target) { error in
            DispatchQueue.main.async {
                if let error = error {
                    message = "Couldn't change the icon: \(error.localizedDescription)"
                }
            }
        }
    }

    private func reportWipeIfNeeded() {
        guard let kind = WipeManager.lastRun else { return }
        WipeManager.lastRun = nil
        switch kind {
        case .small:
            message = "Small delete finished. Aufy's data was erased."
        case .full:
            message = "Full delete finished. Everything was erased. To remove the app itself, touch and hold the Aufy icon and choose Remove App."
            if UIApplication.shared.alternateIconName != nil {
                UIApplication.shared.setAlternateIconName(nil)
            }
        }
    }
}
