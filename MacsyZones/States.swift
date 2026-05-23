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
import CoreGraphics

/// 메인스레드 전용 mutation 보장을 위한 디버그 가드.
/// AX 콜백, NSEvent monitor, NSWorkspace notification 등 모든 호출 경로가 main runloop /
/// MainActor Task 안에서 실행되도록 설계돼 있으므로, 새 호출 경로가 다른 스레드에서
/// PlacedWindows / OriginalWindowProperties 를 건드릴 경우 즉시 드러나도록 막는다.
/// release 빌드에서는 precondition 이 비활성화되어 비용 없음.
@inline(__always)
private func assertWindowStateMainThread(_ where: StaticString = #function) {
    assert(Thread.isMainThread, "WindowState mutation off main thread: \(`where`)")
}

class OriginalWindowProperties {
    static var windowSizeMap: [UInt32: CGSize] = [:]
    static var windowPositionMap: [UInt32: CGPoint] = [:]

    static func update(windowID: UInt32) {
        assertWindowStateMainThread()
        let windowList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as NSArray?
        
        guard let windowInfoList = windowList as? [[String: AnyObject]], let windowInfo = windowInfoList.first else {
            debugLog("Failed to retrieve window info")
            return
        }
        
        if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat] {
            let width = boundsDict["Width"] ?? 0
            let height = boundsDict["Height"] ?? 0
            let size = CGSize(width: width, height: height)
            windowSizeMap[windowID] = size
            
            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let position = CGPoint(x: x, y: y)
            windowPositionMap[windowID] = position
        } else {
            debugLog("Failed to retrieve window bounds")
        }
    }
    
    static func getWindowSize(for windowID: UInt32) -> CGSize? {
        return windowSizeMap[windowID]
    }
    
    static func getWindowPosition(for windowID: UInt32) -> CGPoint? {
        return windowPositionMap[windowID]
    }

    /// 시스템에 더 이상 존재하지 않는 windowID 들을 일괄 제거.
    /// AX destroyed 알림이 발생했을 때 cleanupPlacedWindowsAgainstSystem 에서 호출.
    static func purgeStale(liveIds: Set<UInt32>) {
        assertWindowStateMainThread()
        for id in Array(windowSizeMap.keys) where !liveIds.contains(id) {
            windowSizeMap.removeValue(forKey: id)
            windowPositionMap.removeValue(forKey: id)
        }
    }
}

class PlacedWindows {
    static var windows: [UInt32: Int] = [:]
    static var elements: [UInt32: AXUIElement] = [:]
    static var layouts: [UInt32: String] = [:]
    static var workspaces: [UInt32: Int] = [:]
    static var screens: [UInt32: String] = [:]
    /// 섹션 번호 → 그 섹션에 배치된 윈도우 ID 집합. snap resizer 가 매 드래그마다
    /// 전체 배치 윈도우를 순회하는 O(N) 비용을 O(matching) 으로 줄이기 위한 역인덱스.
    static var bySection: [Int: Set<UInt32>] = [:]

    static func place(windowId: UInt32, screenId: String, workspaceNumber: Int, layoutName: String, sectionNumber: Int, element: AXUIElement) {
        assertWindowStateMainThread()
        if let oldSection = windows[windowId], oldSection != sectionNumber {
            bySection[oldSection]?.remove(windowId)
            if bySection[oldSection]?.isEmpty == true { bySection.removeValue(forKey: oldSection) }
        }
        bySection[sectionNumber, default: []].insert(windowId)

        windows[windowId] = sectionNumber
        elements[windowId] = element
        layouts[windowId] = layoutName
        screens[windowId] = screenId
        workspaces[windowId] = workspaceNumber

        donationReminder.count()
        Task { @MainActor in placedWindowsStore.scheduleSnapshot() }
    }

    static func unplace(windowId: UInt32) {
        assertWindowStateMainThread()
        if let oldSection = windows[windowId] {
            bySection[oldSection]?.remove(windowId)
            if bySection[oldSection]?.isEmpty == true { bySection.removeValue(forKey: oldSection) }
        }

        windows.removeValue(forKey: windowId)
        elements.removeValue(forKey: windowId)
        layouts.removeValue(forKey: windowId)
        screens.removeValue(forKey: windowId)
        workspaces.removeValue(forKey: windowId)

        donationReminder.count()
        Task { @MainActor in placedWindowsStore.scheduleSnapshot() }
    }
    
    static func isPlaced(windowId: UInt32) -> Bool {
        return windows.keys.contains(windowId)
    }
    
    static func isPlaced(layoutName: String, windowId: UInt32) -> Bool {
        return layouts.keys.contains(windowId) && layouts[windowId] == layoutName
    }
}
