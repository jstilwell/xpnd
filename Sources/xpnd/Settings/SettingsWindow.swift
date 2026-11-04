import AppKit
import SwiftUI

/// The Settings window's sections, in order. An enum so later projects can add sections.
enum SettingsSection: String, CaseIterable, Sendable {
    case general, terminal, remoteDesktop, passwordManager, importExport

    var title: String {
        switch self {
        case .general: "General"
        case .terminal: "Terminal"
        case .remoteDesktop: "Remote Desktop"
        case .passwordManager: "Password Manager"
        case .importExport: "Import/Export"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .terminal: "terminal"
        case .remoteDesktop: "pc"
        case .passwordManager: "key"
        case .importExport: "square.and.arrow.up.on.square"
        }
    }
}

/// The Settings window: a toolbar of sections, each a SwiftUI view. Adapted from HoverEnhance's.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: AppSettings, store: SnippetStore, connections: ConnectionEditing) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func host<Content: View>(_ view: Content) -> NSViewController {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = .preferredContentSize
            // The tab view controller owns the toolbar; keep SwiftUI (NavigationSplitView) out of it.
            host.sceneBridgingOptions = []
            return host
        }
        for section in SettingsSection.allCases {
            let host = switch section {
            case .general: host(GeneralSettingsView(settings: settings))
            case .terminal: host(TerminalSettingsView(settings: settings))
            case .remoteDesktop: host(RemoteDesktopSettingsView(settings: settings))
            case .passwordManager: host(PasswordManagerSettingsView(settings: settings, editing: connections))
            case .importExport: host(ImportExportView(store: store, connections: connections.store))
            }
            host.title = section.title
            let item = NSTabViewItem(viewController: host)
            item.label = section.title
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            item.identifier = section.rawValue
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.showFromMenuBar()
    }
}
