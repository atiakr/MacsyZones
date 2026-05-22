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

import Cocoa
import CoreGraphics

/// Cached accessor for `NSScreen.screens`. The underlying property hits the
/// system every read; we invalidate on `didChangeScreenParametersNotification`
/// so the cache is always consistent with display reconfiguration.
enum ScreenCache {
    private static var cachedScreens: [NSScreen]?
    private static var cachedScreenIds: [CGDirectDisplayID: String] = [:]
    private static var observer: NSObjectProtocol?

    static var screens: [NSScreen] {
        if let cached = cachedScreens { return cached }
        let snapshot = NSScreen.screens
        cachedScreens = snapshot
        ensureObserver()
        return snapshot
    }

    /// 디스플레이 UUID 문자열을 캐시. CGDisplayCreateUUIDFromDisplayID + CFUUIDCreateString 은
    /// 드래그 등 핫패스에서 호출당 IPC + alloc 비용이 누적되어, 디스플레이 구성이 바뀌기
    /// 전까지 한 번만 계산하도록 메모이즈.
    static func screenId(for displayID: CGDirectDisplayID) -> String? {
        if let cached = cachedScreenIds[displayID] { return cached }
        ensureObserver()
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        guard let str = CFUUIDCreateString(nil, uuidRef) as String? else { return nil }
        cachedScreenIds[displayID] = str
        return str
    }

    private static func ensureObserver() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            cachedScreens = nil
            cachedScreenIds.removeAll()
        }
    }
}

private var lastFocusedScreen: NSScreen?

func getFocusedScreen() -> NSScreen? {
    if let screen = ScreenCache.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
        lastFocusedScreen = screen
        return screen
    }
    return lastFocusedScreen
}

extension NSScreen {
    fileprivate var macsyDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Stable, content-based identifier for a physical display.
/// - 내장 디스플레이: 디바이스 UUID (재부팅·업그레이드에서 안정)
/// - 외장 디스플레이: EDID(제조사/모델/시리얼) 기반이라 같은 모니터를 어느 Mac 에 꽂아도 동일 ID
func getScreenId(screen: NSScreen) -> String? {
    guard let displayID = screen.macsyDisplayID else { return nil }
    return ScreenCache.screenId(for: displayID)
}

func resolveScreen(screenId: String) -> NSScreen? {
    return ScreenCache.screens.first(where: { getScreenId(screen: $0) == screenId })
}

func centerWindowOnFocusedScreen(_ window: NSWindow) {
    guard let screen = getFocusedScreen() else {
        window.center()
        return
    }
    
    let screenFrame = screen.visibleFrame
    let windowFrame = window.frame
    
    let x = screenFrame.origin.x + (screenFrame.width - windowFrame.width) / 2
    let y = screenFrame.origin.y + (screenFrame.height - windowFrame.height) / 2
    
    window.setFrameOrigin(NSPoint(x: x, y: y))
}
