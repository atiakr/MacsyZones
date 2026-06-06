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
    /// 모니터 ↔ layout 1:1 매핑. 사용자 요구: 같은 모니터면 어느 macOS Space 든
    /// 동일 layout 적용. 이전엔 (screenId, spaceNumber) 키였는데, 다중 모니터 +
    /// Spaces 환경에서 `CGSGetActiveSpace` 의 globally-focused-only 특성과 결합해
    /// 의도치 않은 layout 전환을 일으켜 단순화.
    var screenLayouts: [String: String] = [:]
    static let defaultConfigFileName = "SpaceLayoutPreferences.json"

    override init(name: String = "SpaceLayoutPreferences", data: String = "{}", fileName: String = SpaceLayoutPreferences.defaultConfigFileName) {
        super.init(name: name, data: data, fileName: fileName)
    }

    /// `spaceNumber` 는 backward-compat 위해 시그니처 유지 — 실제로는 무시.
    func set(screenId: String, spaceNumber: Int, layoutName: String) {
        _ = spaceNumber
        screenLayouts[screenId] = layoutName
        save()
    }

    /// `spaceNumber` 는 backward-compat 위해 시그니처 유지 — 실제로는 무시.
    func get(screenId: String, spaceNumber: Int) -> String? {
        _ = spaceNumber
        let name = screenLayouts[screenId]

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
        guard let spaceNumber = getCurrentSpaceNumber(forScreenId: screenId) else { return nil }

        debugLog("getCurrentScreenAndSpace(): screenId: \(screenId), spaceNumber: \(spaceNumber)")

        return (screenId, spaceNumber)
    }

    /// 특정 screen 의 현재 활성 space index 를 반환한다.
    ///
    /// 다중 모니터 + "Displays have separate Spaces" 환경에서 `CGSGetActiveSpace` 는
    /// 유저가 마지막으로 클릭(포커스)한 디스플레이의 active space 만 돌려준다.
    /// 따라서 마우스가 다른 모니터로 넘어간 상태에서 query 하면 globally-active space
    /// 가 query 대상 screen 의 space 와 일치하지 않아, 디스플레이 순회 매칭에서
    /// 엉뚱한 screen 의 인덱스가 반환된다 — `(screenId: B, spaceNumber: A's-index)`
    /// 같은 잘못된 키로 layout lookup 이 일어나 "이상한 layout 으로 전환" 버그를 유발.
    ///
    /// 이 함수는 query 대상 screen 의 UUID 와 managedSpaces 의 "Display Identifier"
    /// 를 직접 매칭하고, 그 디스플레이의 "Current Space" → "Spaces" 인덱스를 반환한다.
    static func getCurrentSpaceNumber(forScreenId screenId: String) -> Int? {
        let connection = CGSMainConnectionID()

        guard let managedSpaces = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }

        for display in managedSpaces {
            guard let displayIdentifier = display["Display Identifier"] as? String,
                  displayIdentifier == screenId else { continue }

            guard let currentSpace = display["Current Space"] as? [String: Any],
                  let currentSpaceID = currentSpace["ManagedSpaceID"] as? UInt64,
                  let spaces = display["Spaces"] as? [[String: Any]] else {
                return nil
            }

            for (index, space) in spaces.enumerated() {
                if let sid = space["ManagedSpaceID"] as? UInt64, sid == currentSpaceID {
                    return index + 1
                }
            }

            return nil
        }

        return nil
    }

    /// 레거시 경로 — 호출자가 screenId 를 모르는 경우 globally-active space 로 폴백.
    /// 다중 모니터 정합성이 필요한 경로는 `getCurrentSpaceNumber(forScreenId:)` 를 쓸 것.
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
        }

        return nil
    }

    override func save() {
        do {
            let jsonData = try JSONEncoder().encode(screenLayouts)
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

        // 1) 새 포맷: [screenId: layoutName] — 모니터당 1 layout.
        if let parsed = try? JSONDecoder().decode([String: String].self, from: jsonData) {
            screenLayouts = parsed
            debugLog("SpaceLayoutPreferences loaded (per-monitor format, \(parsed.count) entries).")
            return
        }

        // 2) 구포맷: [ScreenSpacePair: String] — 같은 모니터의 여러 space 항목을
        //    하나로 collapse (마지막 등장 우선). 사용자가 어느 space 에 어떤 layout
        //    을 마지막으로 지정했든 그 layout 이 모니터 전체에 적용된다.
        if let parsed = try? JSONDecoder().decode([ScreenSpacePair: String].self, from: jsonData) {
            var migrated: [String: String] = [:]
            for (key, value) in parsed {
                migrated[key.screen] = value
            }
            screenLayouts = migrated
            debugLog("SpaceLayoutPreferences: collapsed \(parsed.count) (screen,space) entries → \(migrated.count) screens.")
            save()
            return
        }

        // 3) 레거시(Int 스크린 인덱스 키) → 모니터당 1 layout 으로 collapse + 마이그레이션.
        if let legacy = try? JSONDecoder().decode([LegacyScreenSpacePair: String].self, from: jsonData) {
            let screens = ScreenCache.screens
            var migrated: [String: String] = [:]
            for (key, value) in legacy {
                guard key.screen >= 0, key.screen < screens.count,
                      let screenId = getScreenId(screen: screens[key.screen]) else { continue }
                migrated[screenId] = value
            }
            screenLayouts = migrated
            debugLog("SpaceLayoutPreferences: legacy(Int) → per-monitor, \(migrated.count) entries.")
            save()
            return
        }

        screenLayouts = [:]
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
                // 디스플레이 재구성: hit-test 캐시를 즉시 비워 옛 픽셀 좌표로 hover 가
                // 잡히는 짧은 윈도를 제거. ScreenCache 는 동일 알림에서 self-invalidate.
                invalidateSectionGeometryCache()
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
