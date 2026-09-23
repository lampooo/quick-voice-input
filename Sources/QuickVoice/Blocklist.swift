import AppKit
import QuickVoiceCore
import SwiftUI
import UniformTypeIdentifiers

/// Name and icon of an app, looked up by bundle ID. Main thread only.
struct AppInfo: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage
    let isInstalled: Bool

    var id: String { bundleID }

    var menuIcon: NSImage { MenuBarController.menuIcon(icon) }

    private init(bundleID: String, name: String, icon: NSImage, isInstalled: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
        self.isInstalled = isInstalled
    }

    init(running app: NSRunningApplication, bundleID: String) {
        self.init(bundleID: bundleID, name: app.localizedName ?? bundleID,
                  icon: app.icon ?? NSWorkspace.shared.icon(for: .application), isInstalled: true)
    }

    /// Prefers a running instance, then the installed copy; blocked apps that were deleted
    /// still show their bundle ID.
    init(bundleID: String) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            self.init(running: running, bundleID: bundleID)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            self.init(bundleID: bundleID, name: Self.displayName(of: url), icon: NSWorkspace.shared.icon(forFile: url.path), isInstalled: true)
        } else {
            self.init(bundleID: bundleID, name: bundleID, icon: NSWorkspace.shared.icon(for: .application), isInstalled: false)
        }
    }

    static func displayName(of url: URL) -> String {
        let bundle = Bundle(url: url)
        let localized = bundle?.localizedInfoDictionary
        let info = bundle?.infoDictionary
        let candidates = [
            localized?["CFBundleDisplayName"], localized?["CFBundleName"],
            info?["CFBundleDisplayName"], info?["CFBundleName"],
        ]
        return candidates.compactMap { $0 as? String }.first { !$0.isEmpty } ?? url.deletingPathExtension().lastPathComponent
    }
}

/// Regular apps that are running right now, for 「从正在运行的软件中添加」.
final class RunningAppsModel: ObservableObject {
    @Published private(set) var apps: [AppInfo] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func refresh() {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppInfo? in
                guard let bundleID = app.bundleIdentifier, bundleID != own, AppRules.canChangeRule(for: bundleID),
                      seen.insert(bundleID).inserted else { return nil }
                return AppInfo(running: app, bundleID: bundleID)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct BlocklistPage: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var running = RunningAppsModel()

    var body: some View {
        let blocked = settings.blockedBundleIDs.map(AppInfo.init(bundleID:)).sorted { lhs, rhs in
            if lhs.isInstalled != rhs.isInstalled { return lhs.isInstalled }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let candidates = running.apps.filter { !settings.isBlocked($0.bundleID) }
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "屏蔽的软件",
                subtitle: "在这些软件里长按鼠标不会触发语音输入，快捷语音输入也不会读取它们的界面信息。菜单栏里的「在〈当前软件〉中屏蔽」和这里是同一份列表。"
            )
            HStack(spacing: 10) {
                Menu("从正在运行的软件中添加") {
                    if candidates.isEmpty {
                        Text("没有可以添加的软件")
                    }
                    ForEach(candidates) { app in
                        Button {
                            settings.block(app.bundleID)
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: app.menuIcon) }
                        }
                    }
                }
                .fixedSize()
                Button("从「应用程序」文件夹选择…") { chooseApplications() }
            }

            if blocked.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("还没有屏蔽任何软件")
                    Text("也可以在要屏蔽的软件里点菜单栏图标，选「在〈当前软件〉中屏蔽」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(blocked.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider() }
                        row(for: app)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            }

            Text("移除屏蔽后，软件会回到它原来的规则：大多数软件是「自动识别输入框」，终端类软件是「任意位置都触发」。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { running.refresh() }
    }

    private func row(for app: AppInfo) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                Text(app.isInstalled ? app.bundleID : "\(app.bundleID)（没有找到这个软件）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("移除") { settings.unblock(app.bundleID) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.title = "选择要屏蔽的软件"
        panel.prompt = "屏蔽"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                settings.block(bundleID)
            }
        }
    }
}
