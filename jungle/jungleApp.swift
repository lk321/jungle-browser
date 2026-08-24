//
//  jungleApp.swift
//  jungle
//
//  Created by Antonio Orozco on 8/24/26.
//

import SwiftUI

@main
struct JungleApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserWorkspaceView()
                .ignoresSafeArea()
                .background(WindowChromeConfigurator())
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .jungleNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
                Button("Back") {
                    NotificationCenter.default.post(name: .jungleGoBack, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)
                Button("Forward") {
                    NotificationCenter.default.post(name: .jungleGoForward, object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)
                Button("Reload") {
                    NotificationCenter.default.post(name: .jungleReload, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Open Command Palette") {
                    NotificationCenter.default.post(name: .jungleCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Browser Settings") {
                    NotificationCenter.default.post(name: .jungleOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
                Button("Next Open Tab") {
                    NotificationCenter.default.post(name: .jungleCycleTabs, object: nil)
                }
                .keyboardShortcut(.tab, modifiers: [.command, .option])
                Button("Next Tab") {
                    NotificationCenter.default.post(name: .jungleMoveTab, object: nil, userInfo: ["offset": 1])
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Previous Tab") {
                    NotificationCenter.default.post(name: .jungleMoveTab, object: nil, userInfo: ["offset": -1])
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .jungleToggleSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
                ForEach(1...3, id: \.self) { number in
                    Button("Switch to Profile \(number)") {
                        NotificationCenter.default.post(name: .jungleSwitchProfile, object: nil, userInfo: ["number": number])
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .control)
                }
            }
        }
    }
}

extension Notification.Name {
    static let jungleNewTab = Notification.Name("jungle.new-tab")
    static let jungleCommandPalette = Notification.Name("jungle.command-palette")
    static let jungleCycleTabs = Notification.Name("jungle.cycle-tabs")
    static let jungleMoveTab = Notification.Name("jungle.move-tab")
    static let jungleToggleSidebar = Notification.Name("jungle.toggle-sidebar")
    static let jungleSwitchProfile = Notification.Name("jungle.switch-profile")
    static let jungleTrafficLightsVisibility = Notification.Name("jungle.traffic-lights-visibility")
    static let jungleOpenSettings = Notification.Name("jungle.open-settings")
    static let jungleGoBack = Notification.Name("jungle.go-back")
    static let jungleGoForward = Notification.Name("jungle.go-forward")
    static let jungleReload = Notification.Name("jungle.reload")
}
