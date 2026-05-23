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
import ApplicationServices

/// 스냅된 윈도우의 영속화 단위. CGWindowID 는 매 런치마다 달라져 그대로 저장할 수 없으므로
/// (bundleId, title) 의 베스트-에포트 매칭으로 재부착한다. 동일 앱에 같은 title 의 윈도우가
/// 여러 개면 첫 매칭만 부착 — 나머지는 사용자가 직접 재스냅.
struct PersistedSnap: Codable {
    let bundleId: String
    let title: String
    let layoutName: String
    let screenId: String
    let workspaceNumber: Int
    let sectionNumber: Int
}

private struct PlacedWindowsStoreData: Codable {
    var version: Int = 1
    var enabled: Bool
    var entries: [PersistedSnap]
}

class PlacedWindowsStore: UserData, ObservableObject {
    @Published var enabled: Bool = false
    var entries: [PersistedSnap] = []

    /// snapshot 디바운스 워크아이템. PlacedWindows.place/unplace 가 한 번의 사용자 액션에서
    /// 여러 번 호출될 수 있어 매 호출마다 디스크 IO 를 하지 않도록 묶는다.
    private var snapshotPending: DispatchWorkItem?
    private let snapshotDebounce: TimeInterval = 0.5

    init() {
        super.init(name: "PlacedWindowsStore", data: "{}", fileName: "PlacedWindowsStore.json")
    }

    override func load() {
        super.load()
        guard let json = data.data(using: .utf8) else { return }
        if let decoded = try? JSONDecoder().decode(PlacedWindowsStoreData.self, from: json) {
            enabled = decoded.enabled
            entries = decoded.entries
        }
    }

    override func save() {
        do {
            let payload = PlacedWindowsStoreData(version: 1, enabled: enabled, entries: entries)
            let encoded = try JSONEncoder().encode(payload)
            if let str = String(data: encoded, encoding: .utf8) {
                data = str
                super.save()
            }
        } catch {
            debugLog("PlacedWindowsStore save error: \(error)")
        }
    }

    /// PlacedWindows 의 현재 상태를 entries 로 캡처하고 디스크에 영속화.
    /// PlacedWindows.place/unplace 가 호출될 때 scheduleSnapshot() 으로 디바운싱.
    @MainActor
    func performSnapshot() {
        guard enabled else { return }

        var snaps: [PersistedSnap] = []
        snaps.reserveCapacity(PlacedWindows.windows.count)

        for (windowId, sectionNumber) in PlacedWindows.windows {
            guard let layoutName = PlacedWindows.layouts[windowId],
                  let screenId = PlacedWindows.screens[windowId],
                  let workspaceNumber = PlacedWindows.workspaces[windowId],
                  let element = PlacedWindows.elements[windowId] else { continue }

            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundleId = app.bundleIdentifier else { continue }

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""

            snaps.append(PersistedSnap(
                bundleId: bundleId,
                title: title,
                layoutName: layoutName,
                screenId: screenId,
                workspaceNumber: workspaceNumber,
                sectionNumber: sectionNumber
            ))
        }

        entries = snaps
        save()
    }

    /// place/unplace 폭주 시 디스크 쓰기를 묶기 위한 트레일링 디바운스 트리거.
    @MainActor
    func scheduleSnapshot() {
        guard enabled else { return }
        snapshotPending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSnapshot()
        }
        snapshotPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + snapshotDebounce, execute: work)
    }

    /// 부팅 시 호출: 저장된 entries 와 현재 살아있는 AX 윈도우들을 매칭해 PlacedWindows 에
    /// 메타데이터만 재부착. 윈도우 좌표를 강제 변경하지는 않는다 (사용자가 의도적으로 옮긴
    /// 상태일 수 있고, 재부팅 직후 좌표 점프는 UX 가 깨진다). cycleWindowsInZone /
    /// snap resizer 가 인식할 수 있도록 PlacedWindows 만 채운다.
    @MainActor
    func restore() {
        guard enabled, !entries.isEmpty else { return }

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        var attached: Set<UInt32> = []
        for snap in entries {
            guard let app = runningApps.first(where: { $0.bundleIdentifier == snap.bundleId }) else { continue }
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var winsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef) == .success,
                  let wins = winsRef as? [AXUIElement] else { continue }

            for win in wins {
                guard let wid = getWindowID(from: win), !attached.contains(wid) else { continue }
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""
                if title == snap.title {
                    PlacedWindows.place(
                        windowId: wid,
                        screenId: snap.screenId,
                        workspaceNumber: snap.workspaceNumber,
                        layoutName: snap.layoutName,
                        sectionNumber: snap.sectionNumber,
                        element: win
                    )
                    attached.insert(wid)
                    break
                }
            }
        }
        debugLog("PlacedWindowsStore.restore: re-attached \(attached.count)/\(entries.count) entries")
    }
}

let placedWindowsStore = PlacedWindowsStore()
