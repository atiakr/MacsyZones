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
import Cocoa

struct ScreenSpacePair: Hashable, Codable {
    let screen: String
    let space: Int
}

/// 구버전(Int 스크린 인덱스) 포맷. 현재 디스플레이 구성과 같은 머신에 한해 1회 마이그레이션에만 사용.
private struct LegacyScreenSpacePair: Hashable, Codable {
    let screen: Int
    let space: Int
}

class SpaceLayoutPreferences: UserData {
    var spaces: [ScreenSpacePair: String] = [:]
    static let defaultConfigFileName = "SpaceLayoutPreferences.json"

    override init(name: String = "SpaceLayoutPreferences", data: String = "{}", fileName: String = SpaceLayoutPreferences.defaultConfigFileName) {
        super.init(name: name, data: data, fileName: fileName)
    }

    func set(screenId: String, spaceNumber: Int, layoutName: String) {
        spaces[ScreenSpacePair(screen: screenId, space: spaceNumber)] = layoutName
        save()
    }

    func get(screenId: String, spaceNumber: Int) -> String? {
        let name = spaces[ScreenSpacePair(screen: screenId, space: spaceNumber)]

        if name == nil {
            return nil
        }

        if !userLayouts.layouts.keys.contains(name!) {
            return userLayouts.layouts.keys.sorted().first
        }

        return name
    }

    func setCurrent(layoutName: String) {
        guard let (screenId, spaceNumber) = SpaceLayoutPreferences.getCurrentScreenAndSpace() else {
            debugLog("Unable to get the current screen and space")
            return
        }

        set(screenId: screenId, spaceNumber: spaceNumber, layoutName: layoutName)
    }

    func getCurrent() -> String? {
        guard let (screenId, spaceNumber) = SpaceLayoutPreferences.getCurrentScreenAndSpace() else {
            debugLog("Unable to get the current screen and space")
            return nil
        }

        debugLog("Getting layout for screen \(screenId) and space \(spaceNumber)")

        return get(screenId: screenId, spaceNumber: spaceNumber)
    }

    static func getCurrentScreenAndSpace() -> (String, Int)? {
        guard let focusedScreen = getFocusedScreen() else { return nil }
        guard let screenId = getScreenId(screen: focusedScreen) else { return nil }
        guard let spaceNumber = getCurrentSpaceNumber() else { return nil }

        debugLog("getCurrentScreenAndSpace(): screenId: \(screenId), spaceNumber: \(spaceNumber)")

        return (screenId, spaceNumber)
    }

    static func getCurrentSpaceNumber() -> Int? {
        let connection = CGSMainConnectionID()
        let activeSpaceID = CGSGetActiveSpace(connection)

        guard let managedSpaces = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }

        for display in managedSpaces {
            if let spaces = display["Spaces"] as? [[String: Any]] {
                for (index, space) in spaces.enumerated() {
                    if let spaceID = space["ManagedSpaceID"] as? UInt64,
                    spaceID == activeSpaceID {
                        return index + 1
                    }
                }
            }

            if let currentSpaces = display["Current Space"] as? [String: Any],
            let spaceID = currentSpaces["ManagedSpaceID"] as? UInt64,
            spaceID == activeSpaceID {

                if let spaces = display["Spaces"] as? [[String: Any]] {
                    for (index, space) in spaces.enumerated() {
                        if let sid = space["ManagedSpaceID"] as? UInt64,
                        sid == activeSpaceID {
                            return index + 1
                        }
                    }
                }
            }
        }

        return nil
    }

    override func save() {
        do {
            let jsonData = try JSONEncoder().encode(spaces)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            data = jsonString
            super.save()
        } catch {
            debugLog("Error saving SpaceLayoutPreferences: \(error)")
        }
    }

    override func load() {
        super.load()
        guard let jsonData = data.data(using: .utf8) else { return }

        // 1) 현재 포맷(String screenId 키) 으로 시도.
        if let parsed = try? JSONDecoder().decode([ScreenSpacePair: String].self, from: jsonData) {
            spaces = parsed
            debugLog("Preferences loaded successfully (current format, \(parsed.count) entries).")
            return
        }

        // 2) 구버전(Int 스크린 인덱스 키) 포맷이면 현재 디스플레이 구성에 한해 1회 마이그레이션.
        //    같은 머신에서 같은 모니터 세팅을 쓰던 사용자는 설정을 보존할 수 있다.
        //    매핑 불가능한 인덱스(다른 머신, 모니터 갯수 변경 등)는 그냥 누락 — 사용자가 다시 지정하면 됨.
        if let legacy = try? JSONDecoder().decode([LegacyScreenSpacePair: String].self, from: jsonData) {
            let screens = ScreenCache.screens
            var migrated: [ScreenSpacePair: String] = [:]
            for (key, value) in legacy {
                guard key.screen >= 0, key.screen < screens.count,
                      let screenId = getScreenId(screen: screens[key.screen]) else { continue }
                migrated[ScreenSpacePair(screen: screenId, space: key.space)] = value
            }
            spaces = migrated
            debugLog("SpaceLayoutPreferences: migrated \(migrated.count)/\(legacy.count) legacy entries.")
            save()  // 마이그레이션 결과를 새 포맷으로 즉시 영속화.
            return
        }

        spaces = [:]
        debugLog("SpaceLayoutPreferences: unrecognized format; clearing.")
    }
    
    func switchToCurrent() {
        if let layoutName = self.getCurrent() {
            userLayouts.currentLayoutName = layoutName
            
            for (_, layout) in userLayouts.layouts {
                layout.hideAllWindows()
            }

            stopEditing()
            
            debugLog("Switched to layout: \(userLayouts.currentLayoutName) for current space")
        }
    }
    
    func startObserving() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil,
            using: { notification in
                stopEditing()
                setIsFitting(false)
                userLayouts.hideAllSectionWindows()
                if #available(macOS 12.0, *) { quickSnapper.close() }
                
                if !appSettings.selectPerDesktopLayout { return }
                
                self.switchToCurrent()
            }
        )
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil,
            using: { _ in
                if #available(macOS 12.0, *) { quickSnapper.close() }
                if !appSettings.selectPerDesktopLayout { return }
                
                if let layoutName = self.getCurrent() {
                    userLayouts.currentLayoutName = layoutName
                    
                    for (_, layout) in userLayouts.layouts {
                        layout.hideAllWindows()
                    }
                }
            }
        )
    }
}
