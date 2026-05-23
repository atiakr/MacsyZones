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

/// bundleId → layoutName 매핑.
/// per-desktop layout 보다 우선순위가 높다 — 특정 앱(Xcode, Figma 등) 활성화 시 항상
/// 같은 레이아웃을 강제하고 싶을 때 사용. 매핑되지 않은 앱은 기존 동작(per-desktop or
/// 마지막 선택 레이아웃) 으로 fallback.
private struct AppLayoutData: Codable {
    var version: Int = 1
    var enabled: Bool
    var mappings: [String: String]
}

class AppLayoutPreferences: UserData, ObservableObject {
    @Published var enabled: Bool = false
    @Published var mappings: [String: String] = [:]

    init() {
        super.init(name: "AppLayoutPreferences", data: "{}", fileName: "AppLayoutPreferences.json")
    }

    override func load() {
        super.load()
        guard let json = data.data(using: .utf8) else { return }
        if let decoded = try? JSONDecoder().decode(AppLayoutData.self, from: json) {
            enabled = decoded.enabled
            mappings = decoded.mappings
        }
    }

    override func save() {
        do {
            let payload = AppLayoutData(version: 1, enabled: enabled, mappings: mappings)
            let encoded = try JSONEncoder().encode(payload)
            if let str = String(data: encoded, encoding: .utf8) {
                data = str
                super.save()
            }
        } catch {
            debugLog("AppLayoutPreferences save error: \(error)")
        }
    }

    /// 매핑이 있고 활성화돼 있으면 layoutName 반환. 매핑된 layoutName 이 더 이상 존재하지
    /// 않으면 nil 을 돌려 호출자가 기존 fallback 로직(per-desktop/last selected) 으로
    /// 빠지게 한다 — 사일런트로 임의 레이아웃으로 강제 변경하지 않는다.
    func layoutName(for bundleId: String) -> String? {
        guard enabled else { return nil }
        guard let name = mappings[bundleId] else { return nil }
        guard userLayouts.layouts.keys.contains(name) else { return nil }
        return name
    }

    func setMapping(bundleId: String, layoutName: String) {
        mappings[bundleId] = layoutName
        save()
    }

    func removeMapping(bundleId: String) {
        mappings.removeValue(forKey: bundleId)
        save()
    }
}

let appLayoutPreferences = AppLayoutPreferences()
