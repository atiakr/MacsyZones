//
// MacsyZones, macOS system utility for managing windows on your Mac.
// 
// https://macsyzones.com
// 
// Copyright © 2024, Oğuzhan Eroğlu <meowingcate@gmail.com> (https://meowingcat.io)
// 
// This file is part of MacsyZones.
// Licensed under GNU General Public License v3.0
// See LICENSE file.
//

import Foundation
import SwiftUI

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"

class MacsyReady: ObservableObject {
    @Published var isReady: Bool = false
}

let macsyReady = MacsyReady()
let macsyProLock = ProLock()
let donationReminder = DonationReminder()
let appUpdater = AppUpdater()

@available(macOS 12.0, *)
let quickSnapper = QuickSnapper()

@available(macOS 12.0, *)
let cycleForwardHotkey = GlobalHotkey() {
    cycleWindowsInZone(forward: true)
    return noErr
}

@available(macOS 12.0, *)
let cycleBackwardHotkey = GlobalHotkey() {
    cycleWindowsInZone(forward: false)
    return noErr
}

var hasAccessibilityPermission = false
var statusItem: NSStatusItem!
var popover: NSPopover!
var accessibilityDialog: AccessibilityDialog?
var updateFailedDialog: UpdateFailedDialog?

var mouseUpMonitor: Any?
var mouseDownMonitor: Any?
var mouseDragMonitor: Any?
var rightClickMonitor: Any?
var shortcutMonitor: Any?

/// NSWorkspace.notificationCenter `addObserver(forName:)` 블록형 등록의 토큰 저장소.
/// target-action 형은 `removeObserver(self)` 로 일괄 해제되지만 블록형은 토큰별로
/// 명시 해제해야 한다 — 누락 시 AppDelegate 가 종료되어도 observer 가 남아 누수된다.
var workspaceObservers: [NSObjectProtocol] = []

var isPreview: Bool {
    return ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

@main
struct MacsyZonesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, Sendable {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if isPreview {
            debugLog("Running in preview mode, skipping setup.")
            
            macsyReady.isReady = true
            
            return
        }
        
        NSApp.setActivationPolicy(.prohibited)
        
        checkIfRunning()
        createTrayIcon()
        setupPopover()
        userLayouts.load()
        checkAccessibilityPermission()
        requestAccessibilityPermissions()
        monitorActivations()
        GlobalHotkey.setup()
        
        if #available(macOS 12.0, *) {
            quickSnapper.setup()
        }
        
        Thread { [self] in
            let apps = NSWorkspace.shared.runningApplications

            for app in apps {
                let pid = app.processIdentifier

                // 앱당 MainActor Task 하나로 묶어 app-level + 윈도우 관찰을 일괄 등록.
                // 원본은 윈도우마다 Task를 만들어 시작 시 수백 개가 큐잉되던 문제가 있었음.
                Task { @MainActor in
                    observeAppAndWindows(pid: pid)
                }
            }

            debugLog("All apps are being observed for window movement.")

            // 새로 실행되는 앱: app-level 옵저버 + (이미 떠 있는) 윈도우 enumerate.
            // 런치 직후엔 윈도우가 0 일 수 있는데, app 레벨 kAXWindowCreatedNotification 이
            // 잡아서 onObserverNotification 에서 새 창을 관찰 큐에 추가한다.
            // 반환 토큰은 workspaceObservers 에 모아 종료 시 removeObserver 로 일괄 해제.
            let launchObs = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                                               object: nil, queue: nil) { notification in
                if let userInfo = notification.userInfo,
                   let launchedApp = userInfo[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    debugLog("Newly launched app is being observed: \(launchedApp)")
                    let pid = launchedApp.processIdentifier
                    Task { @MainActor in
                        observeAppAndWindows(pid: pid)
                    }
                }
            }

            // 종료된 앱: 보유 중이던 AXObserver 해제 (메모리/IPC 누수 방지).
            let termObs = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                             object: nil, queue: nil) { notification in
                if let userInfo = notification.userInfo,
                   let terminatedApp = userInfo[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    let pid = terminatedApp.processIdentifier
                    Task { @MainActor in
                        releaseAXObservers(for: pid)
                        cleanupPlacedWindowsAgainstSystem()
                    }
                }
            }

            Task { @MainActor in
                workspaceObservers.append(launchObs)
                workspaceObservers.append(termObs)
            }
            
            Task { @MainActor in
                mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { event in
                    onMouseDown(event: event)
                }

                mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { event in
                    onMouseDragged(event: event)
                }

                mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { event in
                    onMouseUp(event: event)
                }

                spaceLayoutPreferences.startObserving()
                monitorShortcuts()
                monitorRightClick()

                spaceLayoutPreferences.switchToCurrent()

                // 영속화된 snap state 재부착: AX 옵저버 등록까지 끝난 뒤에 호출해야
                // restore 가 부착한 윈도우들의 destroy/move 알림이 정상 라우팅된다.
                placedWindowsStore.restore()

                macsyReady.isReady = true
                
                if #available(macOS 12.0, *) {
                   if !onboardingState.hasCompletedOnboarding && hasAccessibilityPermission {
                       showOnboarding()
                   }
                    
                    cycleForwardHotkey.register(for: appSettings.cycleWindowsForwardShortcut)
                    cycleBackwardHotkey.register(for: appSettings.cycleWindowsBackwardShortcut)
                }
            }
        }
        .start()
        
        checkUpdateState()
    }
    
    
    func checkIfRunning() {
        let notificationName = "MeowingCat.MacsyZones.CheckIfRunning"
        let uniqueNotification = Notification.Name(notificationName)
        
        let runningApps = NSWorkspace.shared.runningApplications
        let isRunning = runningApps.contains {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        
        if isRunning {
            DistributedNotificationCenter.default().postNotificationName(
                uniqueNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            
            let alert = NSAlert()
            alert.window.level = .screenSaver
            alert.window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            alert.alertStyle = .critical
            alert.messageText = "MacsyZones is already running"
            alert.informativeText = "Another instance of MacsyZones is already running. This instance will exit."
            alert.addButton(withTitle: "OK")
            
            alert.window.center()
            
            alert.window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            alert.runModal()
            
            NSApp.terminate(nil)
            return
        }
    }
    
    func checkUpdateState() {
        #if DEBUG
        // Debug 빌드는 자가 업데이트하지 않는다 — 로컬 dev build 가 release 로 덮어쓰기되어
        // ad-hoc 서명/번들 ID 가 바뀌고, 그 결과 TCC 권한이 무효화되는 회귀를 막는다.
        debugLog("checkUpdateState(): skipping auto-update in DEBUG build")
        return
        #else
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"

        if updateState.hasFailedUpdate(currentVersion: currentVersion) {
            showUpdateFailedDialog()
        } else {
            if let targetVersion = updateState.targetVersion {
                if currentVersion == targetVersion || isVersionGreater(currentVersion, than: targetVersion) {
                    updateState.clearUpdateAttempt()
                }
            }

            appUpdater.checkForUpdates()
        }
        #endif
    }
    
    func showUpdateFailedDialog() {
        if updateFailedDialog == nil {
            updateFailedDialog = UpdateFailedDialog()
        }
        
        updateFailedDialog?.show()
    }
    
    func createTrayIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            if let image = NSImage(named: "MenuBarIcon") {
                image.size = NSSize(width: 18, height: 18)
                button.image = image
                image.isTemplate = true
            } else {
                button.image = NSImage(systemSymbolName: "uiwindow.split.2x1", accessibilityDescription: "MacsyZones")
                button.image?.isTemplate = true
            }
            
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: TrayPopupView(layouts: userLayouts))
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
    
    @objc func togglePopover(sender: AnyObject?) {
        if let button = statusItem?.button {
            if popover.isShown {
                closePopover(sender: sender)
            } else {
                showPopover(sender: button)
            }
        }
    }
    
    func showPopover(sender: NSStatusBarButton) {
        if #available(macOS 12.0, *) {
            quickSnapper.close()
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    
    func closePopover(sender: AnyObject?) {
        PopoverState.shared.shouldStopListening = true
        popover.performClose(sender)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            PopoverState.shared.shouldStopListening = false
        }
    }
    
    func popoverWillClose(_ notification: Notification) {
        PopoverState.shared.shouldStopListening = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            PopoverState.shared.shouldStopListening = false
        }
    }
    
    func checkAccessibilityPermission() {
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func requestAccessibilityPermissions() {
        if !hasAccessibilityPermission {
            showAccessibilityPermissionPopover()
        } else {
            debugLog("Accessibility permissions granted.")
        }
    }
    
    func showAccessibilityPermissionPopover() {
        if accessibilityDialog == nil {
            accessibilityDialog = AccessibilityDialog()
        }
        accessibilityDialog?.show()
    }

    func monitorActivations() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc func handleAppActivation(_ notification: Notification) {
        guard !isQuickSnapping,
              !isEditing,
              !isFitting,
              !isSnapResizing
        else { return }

        // Per-app override 가 per-desktop 보다 우선. 활성화된 앱의 bundleId 가 매핑돼
        // 있으면 그 레이아웃으로 즉시 전환하고 per-desktop switch 는 건너뛴다.
        if let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           let bundleId = activatedApp.bundleIdentifier,
           let layoutName = appLayoutPreferences.layoutName(for: bundleId) {
            if userLayouts.currentLayoutName != layoutName {
                userLayouts.currentLayoutName = layoutName
            }
            return
        }

        guard appSettings.selectPerDesktopLayout else { return }
        spaceLayoutPreferences.switchToCurrent()
    }

    @objc func handleWindowDidBecomeKey(_ notification: Notification) {
        guard !isQuickSnapping,
              !isEditing,
              !isFitting,
              !isSnapResizing
        else { return }

        // 활성화 알림과 달리 userInfo 에 앱이 없어 frontmost 로 대체.
        if let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let layoutName = appLayoutPreferences.layoutName(for: bundleId) {
            if userLayouts.currentLayoutName != layoutName {
                userLayouts.currentLayoutName = layoutName
            }
            return
        }

        guard appSettings.selectPerDesktopLayout else { return }
        spaceLayoutPreferences.switchToCurrent()
    }
    
    func monitorShortcuts() {
        var modifierKeyTask: DispatchWorkItem?
        var snapKeyUsed = false
        var prevFlags = NSEvent.ModifierFlags()

        // 재진입 가드: 향후 설정 변경 등으로 monitorShortcuts() 가 다시 호출될 때
        // 이전 토큰을 해제하지 않으면 두 모니터가 동시에 살아 콜백이 중복 호출된다.
        if let prev = shortcutMonitor {
            NSEvent.removeMonitor(prev)
            shortcutMonitor = nil
        }

        // 반환 토큰을 전역에 저장해 applicationWillTerminate 의 일괄 정리 루프에 포함되도록 한다.
        // 470eef1 에서 마우스 모니터들은 잡혔는데 여기만 누락돼 있었던 부분 동기화.
        shortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if !macsyReady.isReady { return }
            var modifierKey: NSEvent.ModifierFlags = .control
            
            if appSettings.modifierKey == "Command" {
                modifierKey = .command
            } else if appSettings.modifierKey == "Option" {
                modifierKey = .option
            }
            
            modifierKeyTask?.cancel()
            modifierKeyTask = nil
            
            let modifierKeyUsed = !prevFlags.contains(modifierKey) && event.modifierFlags.contains(modifierKey)
            prevFlags = event.modifierFlags
            
            if isEditing || isQuickSnapping {
                return
            }
            
            if appSettings.snapKey != "None" {
                var snapKey: NSEvent.ModifierFlags = .shift
                
                if appSettings.snapKey == "Control" {
                    snapKey = .control
                } else if appSettings.snapKey == "Command" {
                    snapKey = .command
                } else if appSettings.snapKey == "Option" {
                    snapKey = .option
                }
                
                if appSettings.selectPerDesktopLayout {
                    if let layoutName = spaceLayoutPreferences.getCurrent() {
                        userLayouts.setCurrentLayout(name: layoutName)
                    }
                }
                
                let snapKeyHeld = event.modifierFlags.contains(snapKey)
                let snapEffective = snapKeyHeld != appSettings.invertSnapKey

                if snapEffective && !isFitting && isMovingAWindow {
                    snapKeyUsed = true
                    setIsFitting(true)
                    userLayouts.currentLayout.show()
                    if userLayouts.currentLayout.layoutType == .grid {
                        userLayouts.currentLayout.gridLayoutWindow?.setAnchorAtMousePosition()
                    }
                } else if isFitting && snapKeyUsed {
                    snapKeyUsed = false
                    setIsFitting(false)
                    if !isQuickSnapping {
                        userLayouts.currentLayout.hide()
                    }
                }

                if !snapEffective {
                    snapKeyUsed = false
                }
            }
            
            if !snapKeyUsed && appSettings.modifierKey != "None" && event.type == .flagsChanged {
                if appSettings.selectPerDesktopLayout {
                    if let layoutName = spaceLayoutPreferences.getCurrent() {
                        userLayouts.setCurrentLayout(name: layoutName)
                    }
                }
                
                let delay = Double(appSettings.modifierKeyDelay) / 1000.0
                
                if modifierKeyUsed {
                    if !isFitting {
                        modifierKeyTask = DispatchWorkItem {
                            if isFitting {
                                if userLayouts.currentLayout.layoutType == .zone {
                                    userLayouts.currentLayout.layoutWindow.show(showSnapResizers: true)
                                } else {
                                    userLayouts.currentLayout.show()
                                }
                            }
                        }
                        
                        setIsFitting(true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: modifierKeyTask!)
                    }
                } else {
                    modifierKeyTask?.cancel()
                    modifierKeyTask = nil
                    
                    if isFitting {
                        setIsFitting(false)
                        if !isQuickSnapping {
                            userLayouts.currentLayout.hide()
                        }
                    }
                }
            }
        }
    }
    
    private func monitorRightClick() {
        rightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { event in
            if !macsyReady.isReady { return }
            if event.buttonNumber != 1 { return }
            if !appSettings.snapWithRightClick { return }
            if isEditing { return }
            if isQuickSnapping { return }
            if isSnapResizing { return }
            if !isMovingAWindow { return }
            
            if !isFitting {
                if appSettings.selectPerDesktopLayout,
                   let layoutName = spaceLayoutPreferences.getCurrent()
                {
                    userLayouts.currentLayoutName = layoutName
                }

                userLayouts.currentLayout.show()
                if userLayouts.currentLayout.layoutType == .grid {
                    userLayouts.currentLayout.gridLayoutWindow?.setAnchorAtMousePosition()
                }
                setIsFitting(true)
            } else {
                userLayouts.currentLayout.hide()
                setIsFitting(false)
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        appSettings.flushPendingSave()
        for monitor in [mouseDownMonitor, mouseDragMonitor, mouseUpMonitor, rightClickMonitor, shortcutMonitor] {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        // 블록형 등록은 토큰별 명시 해제가 필요하다.
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()
        // target-action 형 (monitorActivations) 은 self 참조 기반이라 일괄 제거 가능.
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
}

func restartApp() {
    let task = Process()
    task.launchPath = "/bin/sh"
    task.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]
    task.launch()
    
    NSApp.terminate(nil)
}
