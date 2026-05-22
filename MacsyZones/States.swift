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

class OriginalWindowProperties {
    static var windowSizeMap: [UInt32: CGSize] = [:]
    static var windowPositionMap: [UInt32: CGPoint] = [:]
    
    static func update(windowID: UInt32) {
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
    }

    static func unplace(windowId: UInt32) {
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
    }
    
    static func isPlaced(windowId: UInt32) -> Bool {
        return windows.keys.contains(windowId)
    }
    
    static func isPlaced(layoutName: String, windowId: UInt32) -> Bool {
        return layouts.keys.contains(windowId) && layouts[windowId] == layoutName
    }
}
