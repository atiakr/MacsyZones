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
import ApplicationServices
import SwiftUI
import Accessibility
import CoreGraphics

var userLayouts: UserLayouts = .init()
var layoutSwitcherPanel: LayoutSwitcherPanel = .init()
var updateState: UpdateState = .init()
var toLeaveElement: AXUIElement?
var toLeaveSectionWindow: SectionWindow?
var toLeaveGridRect: NSRect?

var isFitting = false
var isEditing = false
var isQuickSnapping = false
var isSnapResizing = false
var isSwitcherUsed = false

var movingWindowInfo: (element: AXUIElement, windowId: UInt32)?
var isMovingAWindow = false
var draggedWindowElement: AXUIElement?
var draggedWindowInitialPosition: CGPoint?

var windowMovingOnScreen: NSScreen? = nil
var placedWindowMoveStartPosition: CGPoint?

func setIsFitting(_ fitting: Bool) {
    isFitting = fitting
}

func isSnapKeyPressed() -> Bool {
    guard appSettings.snapKey != "None" else { return false }

    let currentFlags = NSEvent.modifierFlags

    switch appSettings.snapKey {
    case "Shift":
        return currentFlags.contains(.shift)
    case "Control":
        return currentFlags.contains(.control)
    case "Command":
        return currentFlags.contains(.command)
    case "Option":
        return currentFlags.contains(.option)
    default:
        return false
    }
}

// invertSnapKey가 true이면 "스냅이 기본, snap key 누르면 자유 이동"
// false(기본)이면 기존대로 "snap key 누르면 스냅".
func shouldSnapFromKey() -> Bool {
    guard appSettings.snapKey != "None" else { return appSettings.invertSnapKey }
    return isSnapKeyPressed() != appSettings.invertSnapKey
}

func checkSnapKeyOnWindowMoveStart() {
    if !macsyReady.isReady { return }

    if shouldSnapFromKey() && !isFitting {
        if appSettings.selectPerDesktopLayout {
            if let layoutName = spaceLayoutPreferences.getCurrent() {
                userLayouts.setCurrentLayout(name: layoutName)
            }
        }

        setIsFitting(true)

        let currentLayout = userLayouts.currentLayout

        switch currentLayout.layoutType {
            case .zone:
                currentLayout.layoutWindow.show()
            case .grid:
                currentLayout.gridLayoutWindow?.show()
                currentLayout.gridLayoutWindow?.setAnchorAtMousePosition()
        }
    }
}

let spaceLayoutPreferences = SpaceLayoutPreferences()

func getWindowUnderMouse() -> (element: AXUIElement, windowId: UInt32)? {
    let mouseLocation = NSEvent.mouseLocation
    
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    
    for windowInfo in windowList {
        guard let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
              let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
              let windowId = windowInfo[kCGWindowNumber as String] as? UInt32 else {
            continue
        }
        
        if windowLayer != 0 { continue }
        
        let x = bounds["X"] ?? 0
        let y = bounds["Y"] ?? 0
        let width = bounds["Width"] ?? 0
        let height = bounds["Height"] ?? 0
        
        if mouseLocation.x >= x && mouseLocation.x <= x + width &&
           mouseLocation.y >= y && mouseLocation.y <= y + height {
            
            if let element = retrieveFreshWindowElement(for: windowId) {
                var subroleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success {
                    if let subrole = subroleRef as? String, subrole == kAXStandardWindowSubrole {
                        return (element: element, windowId: windowId)
                    }
                }
            }
        }
    }
    
    return nil
}

func onMouseDown(event: NSEvent) {
    draggedWindowElement = nil
    draggedWindowInitialPosition = nil

    if let preferredLayoutName = spaceLayoutPreferences.getCurrent() {
        userLayouts.currentLayoutName = preferredLayoutName
    }
}

func startEditing() {
    setIsFitting(false)
    isEditing = true
    userLayouts.currentLayout.layoutWindow.startEditing()
}

func stopEditing() {
    setIsFitting(false)
    isEditing = false
    userLayouts.currentLayout.layoutWindow.stopEditing()
}

@discardableResult
func toggleEditing() -> Bool {
    setIsFitting(false)
    isEditing = !isEditing
    if isEditing {
        userLayouts.currentLayout.layoutWindow.startEditing()
    } else {
        userLayouts.currentLayout.layoutWindow.stopEditing()
    }
    return isEditing
}

func getMenuBarHeight() -> CGFloat? {
    if let screen = NSScreen.main {
        let fullHeight = screen.frame.height
        let visibleHeight = screen.visibleFrame.height
        let menuBarHeight = fullHeight - visibleHeight
        return menuBarHeight
    }
    return nil
}

func getWindowSizeAndPosition(from windowID: UInt32) -> (CGSize?, CGPoint?) {
    let windowList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as NSArray?
    
    guard let windowInfoList = windowList as? [[String: AnyObject]], let windowInfo = windowInfoList.first else {
        debugLog("Failed to retrieve window info")
        return (nil, nil)
    }
    
    if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat] {
        let x = boundsDict["X"] ?? 0
        let y = boundsDict["Y"] ?? 0
        let width = boundsDict["Width"] ?? 0
        let height = boundsDict["Height"] ?? 0
        
        let size = CGSize(width: width, height: height)
        let position = CGPoint(x: x, y: y)
        return (size, position)
    } else {
        debugLog("Failed to retrieve window bounds")
        return (nil, nil)
    }
}

func getWindowID(from axElement: AXUIElement) -> UInt32? {
    var windowID: UInt32 = 0
    let result = _AXUIElementGetWindow(axElement, &windowID)

    if result == .success {
        return windowID
    } else {
        debugLog("Failed to get window ID, error code: \(result.rawValue)")
        return nil
    }
}

func onObserverNotification(observer: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    if isEditing { return }
    if isSnapResizing { return }
    
    var result: AXError
    
    var roleRef: CFTypeRef?
    result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    let role = roleRef as? String ?? "Unknown"
    
    if role != kAXWindowRole {
        return
    }
    
    var appRef: CFTypeRef?
    result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &appRef)
    guard result == .success,
          let appRef = appRef,
          CFGetTypeID(appRef) == AXUIElementGetTypeID()
    else {
        return
    }
    let appElement = appRef as! AXUIElement

    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(appElement, kAXTitleAttribute as CFString, &titleRef)
    let title = (titleRef as? String) ?? ""

    switch notification as String {
    case kAXWindowMovedNotification:
        var position: CGPoint = .zero
        var positionRef: CFTypeRef?
        result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
        if result == .success,
           let posRef = positionRef,
           CFGetTypeID(posRef) == AXValueGetTypeID()
        {
            AXValueGetValue(posRef as! AXValue, AXValueType.cgPoint, &position)
        }

        onWindowMoved(observer: observer, element: element, notification: notification, title: title, position: position)

    case kAXUIElementDestroyedNotification:
        debugLog("App exited: \(title)")

    default:
        break
    }
}

let shakeCoolDown: TimeInterval = 0.75

var previousPosition: CGPoint?
var previousVelocity: CGPoint?
var previousTime: TimeInterval?
var lastShakeTime: TimeInterval = 0

let shakeClearInterval: TimeInterval = 0.25
var lastShakeClearTime: TimeInterval = 0

var shakeMagnitudeCount: CGFloat = 0

var justDidMouseUp = false

// Per-section precomputed geometry. Independent of mouse position — only depends
// on (layout, screen, section frames). Lets each mouse-move tick run pure
// arithmetic (CGRect.contains, squared distance) instead of recomputing bounds.
struct CachedSectionGeometry {
    let window: SectionWindow
    let rect: CGRect          // full snap area in screen coords
    let centerHitRect: CGRect // 100×100 box around center for prioritizeCenterToSnap
    let center: CGPoint
    let area: CGFloat
}

var cachedSectionGeometries: [CachedSectionGeometry] = []
var cachedSectionGeometriesKey: (layoutName: String, screenId: ObjectIdentifier, signature: CGFloat, count: Int)?

func getHoveredSectionWindow() -> SectionWindow? {
    debugLog("getHoveredSectionWindow(): isFitting = \(isFitting)")

    guard let focusedScreen = getFocusedScreen() else {
        for layout in userLayouts.layouts.values {
            for sectionWindow in layout.layoutWindow.sectionWindows {
                if sectionWindow.isHovered { sectionWindow.isHovered = false }
            }
        }
        cachedSectionGeometriesKey = nil
        return nil
    }

    let mouseLocation = NSEvent.mouseLocation
    let sectionWindows = userLayouts.currentLayout.layoutWindow.sectionWindows
    var hoveredSectionWindow: SectionWindow?

    if isFitting {
        let currentLayoutName = userLayouts.currentLayoutName
        let screenId = ObjectIdentifier(focusedScreen)

        // Cheap O(n) signature of section frames — detects in-place edits
        // (resize/move) without touching getBounds() unless something changed.
        var signature: CGFloat = 0
        for sw in sectionWindows {
            let f = sw.window.frame
            signature += f.origin.x + f.origin.y + f.width + f.height
        }

        let needsRecompute: Bool = {
            guard let key = cachedSectionGeometriesKey else { return true }
            return key.layoutName != currentLayoutName
                || key.screenId != screenId
                || key.count != sectionWindows.count
                || key.signature != signature
        }()

        if needsRecompute {
            let screenFrame = focusedScreen.frame
            let screenSize = screenFrame.size
            let screenOrigin = screenFrame.origin

            cachedSectionGeometries = sectionWindows.map { sw in
                let b = sw.getBounds(for: focusedScreen)
                let width = b.widthPercentage * screenSize.width
                let height = b.heightPercentage * screenSize.height
                let x = screenOrigin.x + b.xPercentage * screenSize.width
                let y = screenOrigin.y + b.yPercentage * screenSize.height
                let cx = x + width / 2
                let cy = y + height / 2
                return CachedSectionGeometry(
                    window: sw,
                    rect: CGRect(x: x, y: y, width: width, height: height),
                    centerHitRect: CGRect(x: cx - 50, y: cy - 50, width: 100, height: 100),
                    center: CGPoint(x: cx, y: cy),
                    area: width * height
                )
            }
            cachedSectionGeometriesKey = (currentLayoutName, screenId, signature, sectionWindows.count)
        }

        if appSettings.snapHighlightStrategy != .centerProximity && appSettings.prioritizeCenterToSnap {
            for cs in cachedSectionGeometries {
                if cs.centerHitRect.contains(mouseLocation) {
                    hoveredSectionWindow = cs.window
                    break
                }
            }
        }

        if hoveredSectionWindow == nil {
            let sorted: [CachedSectionGeometry]
            if appSettings.snapHighlightStrategy == .centerProximity {
                sorted = cachedSectionGeometries.sorted {
                    let dx1 = mouseLocation.x - $0.center.x
                    let dy1 = mouseLocation.y - $0.center.y
                    let dx2 = mouseLocation.x - $1.center.x
                    let dy2 = mouseLocation.y - $1.center.y
                    return (dx1 * dx1 + dy1 * dy1) < (dx2 * dx2 + dy2 * dy2)
                }
            } else {
                sorted = cachedSectionGeometries.sorted { $0.area < $1.area }
            }

            for cs in sorted {
                if cs.rect.contains(mouseLocation) {
                    hoveredSectionWindow = cs.window
                    break
                }
            }
        }
    }

    for sectionWindow in sectionWindows {
        let shouldHover = (sectionWindow === hoveredSectionWindow)
        if sectionWindow.isHovered != shouldHover {
            sectionWindow.isHovered = shouldHover
        }
    }

    if let hoveredSectionWindow = hoveredSectionWindow {
        hoveredSectionWindow.window.orderFront(nil)
    }

    return hoveredSectionWindow
}

func onWindowMoved(observer: AXObserver, element: AXUIElement, notification: CFString, title: String, position: CGPoint) {
    guard macsyReady.isReady else { return }

    if let movingOnScreen = windowMovingOnScreen {
        if let screen = getFocusedScreen(), screen != movingOnScreen {
            movingWindowInfo = (element: element, windowId: getWindowID(from: element) ?? 0)
            windowMovingOnScreen = screen
            
            for layout in userLayouts.layouts.values {
                if layout.layoutType == .zone {
                    for sectionWindow in layout.layoutWindow.sectionWindows {
                        sectionWindow.isHovered = false
                        sectionWindow.window.orderOut(nil)
                    }
                } else {
                    layout.gridLayoutWindow?.hide()
                }
            }
            
            if appSettings.selectPerDesktopLayout {
                if let layoutName = spaceLayoutPreferences.getCurrent() {
                    userLayouts.currentLayoutName = layoutName
                }
            }
            
            if isFitting {
                let currentLayout = userLayouts.currentLayout
                switch currentLayout.layoutType {
                    case .zone:
                        currentLayout.layoutWindow.show()
                    case .grid:
                        isFitting = false
                    }
            } else if appSettings.enableLayoutSwitcher {
                layoutSwitcherPanel.move(to: screen)
            }

            toLeaveElement = nil
            toLeaveSectionWindow = nil
            toLeaveGridRect = nil

            return
        }
    }
    
    windowMovingOnScreen = getFocusedScreen()
    
    if appSettings.shakeToSnap && !isSwitcherUsed {
        let currentTime = Date().timeIntervalSince1970
        
        if lastShakeClearTime + shakeClearInterval >= currentTime {
            lastShakeTime = currentTime
            shakeMagnitudeCount = 0
        }
    }
    
    guard !isEditing,
          !isSnapResizing,
          !isQuickSnapping
    else { return }
    
    var subroleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
    
    let subrole = subroleRef as? String ?? "Unknown"
    
    if subrole != kAXStandardWindowSubrole {
        return
    }
    
    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    
    let role = roleRef as? String ?? "Unknown"
    
    if role != kAXWindowRole {
        debugLog("Element is not a window! Role: \(role), Subrole: \(subrole)")
        return
    }
    
    if NSEvent.pressedMouseButtons & 1 != 0 {
        isMovingAWindow = true
        checkSnapKeyOnWindowMoveStart()
        
        if appSettings.enableLayoutSwitcher && !isFitting,
           let screen = getFocusedScreen() {
            layoutSwitcherPanel.showActualMode(on: screen)
        }
    }

    let currentLayout = userLayouts.currentLayout

    switch currentLayout.layoutType {
        case .zone:
            if let hoveredSectionWindow = getHoveredSectionWindow() {
                toLeaveElement = element
                toLeaveSectionWindow = hoveredSectionWindow
            }
        case .grid:
            if isFitting {
                currentLayout.gridLayoutWindow?.updateSelectionToMousePosition()
                toLeaveElement = element
                toLeaveGridRect = currentLayout.gridLayoutWindow?.getSelectionAXRect()
            }
    }
    
    guard let windowId = getWindowID(from: element) else {
        debugLog("Failed to get window ID")
        return
    }
    
    let isPlaced = PlacedWindows.isPlaced(windowId: windowId)
    let originalSize = OriginalWindowProperties.getWindowSize(for: windowId)
    
    if isPlaced && !justDidMouseUp &&
        (!appSettings.onlyFallbackToPreviousSizeWithUserEvent || (NSEvent.pressedMouseButtons & 0x1) != 0)
    {
        if placedWindowMoveStartPosition == nil {
            placedWindowMoveStartPosition = position
        }
        
        if let startPosition = placedWindowMoveStartPosition {
            let distanceMoved = sqrt(pow(position.x - startPosition.x, 2) +
                                     pow(position.y - startPosition.y, 2))
            
            if distanceMoved > 10 {
                placedWindowMoveStartPosition = nil
                PlacedWindows.unplace(windowId: windowId)
                
                if appSettings.fallbackToPreviousSize {
                    if let originalSize,
                       case let (currentSize?, currentPosition?) = getWindowSizeAndPosition(from: windowId)
                    {
                        let mouseLocation = NSEvent.mouseLocation
                        let relativeX = (mouseLocation.x - currentPosition.x) / currentSize.width

                        let widthDifference = currentSize.width - originalSize.width
                        if widthDifference != 0 {
                            let newXPosition = mouseLocation.x - (originalSize.width * relativeX)
                            
                            resizeAndMoveWindow(element: element,
                                                newPosition: CGPoint(x: newXPosition, y: currentPosition.y),
                                                newSize: originalSize)
                        }
                    } else if let originalSize {
                        resizeWindow(element: element, newSize: originalSize)
                        debugLog("Window resized to original size!")
                    }
                }
            } else {
                return
            }
        }
    }
    
    justDidMouseUp = false
    placedWindowMoveStartPosition = nil
    
    if isPlaced {
        return
    }
    
    if appSettings.shakeToSnap && !isSwitcherUsed {
        let isSnapKeyPressed = isSnapKeyPressed()

        guard !isSnapKeyPressed else { return }
        
        let dependingPosition = NSEvent.mouseLocation
        let currentTime = Date().timeIntervalSince1970

        if let previousPosition = previousPosition, let previousTime = previousTime {
            let deltaTime = currentTime - previousTime
            let deltaPosition = CGPoint(x: dependingPosition.x - previousPosition.x, y: dependingPosition.y - previousPosition.y)
            let currentVelocity = CGPoint(x: deltaPosition.x / CGFloat(deltaTime), y: deltaPosition.y / CGFloat(deltaTime))

            if let previousVelocity = previousVelocity {
                let oppositeDirectionOnX = (currentVelocity.x > 0 && previousVelocity.x < 0) || (currentVelocity.x < 0 && previousVelocity.x > 0)
                let oppositeDirectionOnY = (currentVelocity.y > 0 && previousVelocity.y < 0) || (currentVelocity.y < 0 && previousVelocity.y > 0)
                
                let deltaVelocity = CGPoint(x: currentVelocity.x - previousVelocity.x, y: currentVelocity.y - previousVelocity.y)
                let acceleration = CGPoint(x: deltaVelocity.x / CGFloat(deltaTime), y: deltaVelocity.y / CGFloat(deltaTime))
                let accelerationMagnitude = sqrt(pow(acceleration.x, 2) + pow(acceleration.y, 2))

                if (oppositeDirectionOnX || oppositeDirectionOnY) && accelerationMagnitude > appSettings.shakeAccelerationThreshold && currentTime - lastShakeTime > shakeCoolDown {
                    shakeMagnitudeCount += 1
                    
                    if shakeMagnitudeCount >= ((100000 - appSettings.shakeAccelerationThreshold) / 10000) {
                        lastShakeTime = currentTime
                        
                        if appSettings.selectPerDesktopLayout {
                            if let layoutName = spaceLayoutPreferences.getCurrent() {
                                userLayouts.setCurrentLayout(name: layoutName)
                            }
                        }
                        
                        isFitting = !isFitting
                        if isFitting {
                            userLayouts.currentLayout.show()
                        } else {
                            userLayouts.currentLayout.hide()
                        }
                        
                        shakeMagnitudeCount = 0
                        lastShakeTime = currentTime
                        lastShakeClearTime = currentTime
                    }
                }
            }

            previousVelocity = currentVelocity
        }

        previousPosition = dependingPosition
        previousTime = currentTime
    }
}

func getWindowTitle(from axElement: AXUIElement?) -> String? {
    guard let axElement = axElement else {
        return nil
    }
    
    var titleRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleRef)
    
    guard result == .success, let title = titleRef as? String else {
        debugLog("Failed to get window title, error code: \(result.rawValue)")
        return nil
    }
    
    return title
}

func getWindowDetails(element: AXUIElement) -> String {
    var details = "Window details: "
    
    var title: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
    if let windowTitle = title as? String {
        details += "Title: \(windowTitle)"
    } else {
        details += "Title: Unknown"
    }
    
    return details
}

func isElementResizable(element: AXUIElement) -> Bool {
    var resizable: DarwinBoolean = true
    AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &resizable)
    return resizable.boolValue
}

func resizeAndMoveWindow(element: AXUIElement, newPosition: CGPoint, newSize: CGSize, retries: Int = 0, retryParent: Bool = false, useFallback: Bool = true) {
    if retryParent && !isElementResizable(element: element) {
        debugLog("Window is not resizable! Trying parent window...")
        
        var iterationCount = 0

        while iterationCount < 5 {
            iterationCount += 1
            
            var result: AXError
            var parentElementRef: CFTypeRef?
            
            result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentElementRef)
            if result != .success { return }
            
            var subroleRef: CFTypeRef?
            result = AXUIElementCopyAttributeValue(parentElementRef as! AXUIElement, kAXSubroleAttribute as CFString, &subroleRef)
            if result != .success { return }
            let subrole = subroleRef as! String
            
            let parentElement = parentElementRef as! AXUIElement
            
            if subrole == kAXStandardWindowSubrole {
                return resizeAndMoveWindow(element: parentElement, newPosition: newPosition, newSize: newSize, retries: retries, useFallback: useFallback)
            }
        }
        
        return
    }
    
    /*
     * Fix macOS bug!
     * --------------
     * macOS has a bug, when you move & resize a window downward, the window is not being resized correctly.
     * This code fixes this buggy behavior of macOS 😇
     */
    if ScreenCache.screens.count > 1 {
        var sizeValue = CGSize(width: newSize.width, height: newSize.height - 10)
        if let sizeAXValue = AXValueCreate(.cgSize, &sizeValue) {
            let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeAXValue)
            
            if result != .success {
                debugLog("Failed to set window size, error code: \(result.rawValue)")
                debugLog(getWindowDetails(element: element))
            }
        }
    }
    
    var lastPositionResult: AXError = .success
    var lastSizeResult: AXError = .success
    
    // 비동기 retry 큐잉: async setter는 함수 리턴 뒤 실행되므로 같은 메인 스레드에서
    // 결과를 동기 검사할 수 없다(과거에는 stale state를 보고 early return을 시도하던 dead path가 있었음).
    for i in 0..<(retries == 0 ? 1 : retries) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (0.05 * Double(i))) { [element] in
            var positionValue = newPosition
            if let positionAXValue = AXValueCreate(.cgPoint, &positionValue) {
                let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionAXValue)

                if result != .success {
                    debugLog("Failed to set window position, error code: \(result.rawValue)")
                    debugLog(getWindowDetails(element: element))
                }
            }

            var sizeValue = newSize
            if let sizeAXValue = AXValueCreate(.cgSize, &sizeValue) {
                let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeAXValue)

                if result != .success {
                    debugLog("Failed to set window size, error code: \(result.rawValue)")
                    debugLog(getWindowDetails(element: element))
                }
            }
        }
    }
    
    var positionValue = newPosition
    if let positionAXValue = AXValueCreate(.cgPoint, &positionValue) {
        lastPositionResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionAXValue)
    }
    
    var sizeValue = newSize
    if let sizeAXValue = AXValueCreate(.cgSize, &sizeValue) {
        lastSizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeAXValue)
    }

    if (lastPositionResult != .success || lastSizeResult != .success) && useFallback {
        debugLog("Snap operation failed (position: \(lastPositionResult.rawValue), size: \(lastSizeResult.rawValue)), attempting fallback with fresh window element...")
        
        if let freshElement = getFocusedWindowAXUIElement() {
            debugLog("Retrieved fresh window element by ID, retrying snap operation...")
            resizeAndMoveWindow(element: freshElement, newPosition: newPosition, newSize: newSize, retries: retries, retryParent: retryParent, useFallback: false)
            return
        }
        
        if let title = getWindowTitle(from: element) {
            var currentPosition: CGPoint?
            var positionRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success {
                var position: CGPoint = .zero
                AXValueGetValue(positionRef as! AXValue, AXValueType.cgPoint, &position)
                currentPosition = position
            }
            
            if let freshElementInfo = retrieveFreshWindowElementByTitle(title: title, approximatePosition: currentPosition) {
                debugLog("Retrieved fresh window element by title, retrying snap operation...")
                resizeAndMoveWindow(element: freshElementInfo.element, newPosition: newPosition, newSize: newSize, retries: retries, retryParent: retryParent, useFallback: false)
                return
            }
        }
        
        debugLog("Fallback failed: could not retrieve fresh window element")
    }
}

func getElementSizeAndPosition(element: AXUIElement) -> (size: CGSize, position: CGPoint)? {
    var result: AXError
    
    var sizeRef: CFTypeRef?
    result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &sizeRef)
    if result != .success {
        debugLog("Failed to get window size, error code: \(result.rawValue)")
        return nil
    }
    let size = sizeRef as! CGSize
    
    var positionRef: CFTypeRef?
    result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
    if result != .success {
        debugLog("Failed to get window position, error code: \(result.rawValue)")
        return nil
    }
    let position = positionRef as! CGPoint
    
    return (size, position)
}

func getAXPosition(for window: NSWindow) -> CGPoint? {
    let windowId = CGWindowID(window.windowNumber)
    
    let windowList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowId) as NSArray?
    
    guard let windowInfoList = windowList as? [[String: AnyObject]], let windowInfo = windowInfoList.first else {
        debugLog("Failed to retrieve window info")
        return nil
    }
    
    if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat] {
        guard let x = boundsDict["X"], let y = boundsDict["Y"] else {
            debugLog("Failed to retrieve window bounds from bounds dict")
            return nil
        }
        
        let position = CGPoint(x: x, y: y)
        
        return position
    } else {
        debugLog("Failed to retrieve window bounds")
    }
    
    return nil
}

extension NSScreen {
    var axY: CGFloat {
        let primaryFrame = ScreenCache.screens.first!.frame
        let toppestY = primaryFrame.origin.y + primaryFrame.height
        return toppestY - (frame.origin.y + frame.height)
    }
}

func moveWindowToMatch(element: AXUIElement, targetWindow: NSWindow, targetScreen: NSScreen? = nil, sectionConfig: SectionConfig? = nil, retries: Int = 10) {
    guard let position = getAXPosition(for: targetWindow) else { return }
    
    var newPosition: CGPoint = position
    var newSize: CGSize = targetWindow.frame.size
    
    if let targetScreen, let sectionConfig {
        let rect = sectionConfig.getAXRect(on: targetScreen)
        newPosition = rect.origin
        newSize = rect.size
    }
    
    resizeAndMoveWindow(element: element,
                        newPosition: newPosition,
                        newSize: newSize,
                        retries: retries)
}

func resizeWindow(element: AXUIElement, newSize: CGSize) {
    var sizeValue = newSize
    let sizeAXValue = AXValueCreate(.cgSize, &sizeValue)
    
    if let sizeAXValue = sizeAXValue {
        let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeAXValue)
        
        if result != .success {
            debugLog("Failed to set window size, error code: \(result.rawValue) Retrying with fresh window element...")

            if let freshElement = getFocusedWindowAXUIElement() {
                debugLog("Retrieved fresh window element by ID, retrying resize operation...")
                resizeWindow(element: freshElement, newSize: newSize)
                return
            }
        }
    }
}

/// Scan one app's AX window list and return the first window matching `predicate`.
/// Returns nil if the app exposes no windows or AX denies the query.
fileprivate func findAXWindowInApp(pid: pid_t, matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    let appElement = AXUIElementCreateApplication(pid)
    var windowListRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef)
    guard result == .success, let windowList = windowListRef as? [AXUIElement] else {
        return nil
    }
    return windowList.first(where: predicate)
}

func retrieveFreshWindowElement(for windowId: UInt32) -> AXUIElement? {
    debugLog("Attempting to retrieve fresh window element for window ID: \(windowId)")

    let matchesWindowId: (AXUIElement) -> Bool = { window in
        getWindowID(from: window) == windowId
    }

    // Fast path: ask CGWindowList who owns this CGWindowID, then probe only that app.
    if let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowId) as? [[String: Any]],
       let info = infoList.first,
       let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t,
       let element = findAXWindowInApp(pid: ownerPid, matching: matchesWindowId) {
        debugLog("Successfully retrieved fresh window element via owner pid for window ID: \(windowId)")
        return element
    }

    // Fallback: scan every running app (CGWindowList lookup can fail for
    // off-screen / suspended windows).
    let runningApps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular
    }
    for app in runningApps {
        if let element = findAXWindowInApp(pid: app.processIdentifier, matching: matchesWindowId) {
            debugLog("Successfully retrieved fresh window element via full scan for window ID: \(windowId)")
            return element
        }
    }

    debugLog("Failed to retrieve fresh window element for window ID: \(windowId)")
    return nil
}

fileprivate func pickClosestCandidate(
    _ candidates: [(element: AXUIElement, windowId: UInt32, position: CGPoint?)],
    approximatePosition: CGPoint?
) -> (element: AXUIElement, windowId: UInt32, position: CGPoint?)? {
    if candidates.isEmpty { return nil }
    guard let approximatePosition = approximatePosition else { return candidates.first }
    return candidates.min { c1, c2 in
        guard let p1 = c1.position, let p2 = c2.position else {
            return c1.position != nil
        }
        let dx1 = p1.x - approximatePosition.x
        let dy1 = p1.y - approximatePosition.y
        let dx2 = p2.x - approximatePosition.x
        let dy2 = p2.y - approximatePosition.y
        return (dx1 * dx1 + dy1 * dy1) < (dx2 * dx2 + dy2 * dy2)
    }
}

fileprivate func resolveAXWindow(
    pid: pid_t,
    expectedWindowId: UInt32,
    expectedTitle: String
) -> (element: AXUIElement, windowId: UInt32)? {
    let appElement = AXUIElementCreateApplication(pid)
    var windowListRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef)
    guard result == .success, let windowList = windowListRef as? [AXUIElement] else {
        return nil
    }
    for window in windowList {
        guard let windowId = getWindowID(from: window), windowId == expectedWindowId else { continue }
        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
        guard let windowTitle = titleValue as? String, windowTitle == expectedTitle else { continue }
        return (window, windowId)
    }
    return nil
}

func retrieveFreshWindowElementByTitle(title: String, approximatePosition: CGPoint? = nil) -> (element: AXUIElement, windowId: UInt32)? {
    debugLog("Attempting to retrieve fresh window element by title: \(title)")

    // Fast path: filter CGWindowList by title (kCGWindowName) and probe only owning apps.
    // kCGWindowName may be nil without Screen Recording permission; we fall through then.
    if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        var owners: [(pid: pid_t, windowId: UInt32, position: CGPoint?)] = []
        for info in infoList {
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 { continue }
            guard let cgName = info[kCGWindowName as String] as? String, cgName == title,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let windowId = info[kCGWindowNumber as String] as? UInt32 else { continue }

            var position: CGPoint?
            if let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
               let x = bounds["X"], let y = bounds["Y"] {
                position = CGPoint(x: x, y: y)
            }
            owners.append((pid, windowId, position))
        }

        if !owners.isEmpty {
            var resolved: [(element: AXUIElement, windowId: UInt32, position: CGPoint?)] = []
            for owner in owners {
                if let match = resolveAXWindow(pid: owner.pid, expectedWindowId: owner.windowId, expectedTitle: title) {
                    resolved.append((match.element, match.windowId, owner.position))
                }
            }
            if let pick = pickClosestCandidate(resolved, approximatePosition: approximatePosition) {
                debugLog("Successfully retrieved fresh window element by title via CGWindowList for: \(title)")
                return (pick.element, pick.windowId)
            }
        }
    }

    // Fallback: full AX scan (e.g. when Screen Recording perm is missing or
    // CGWindowName lags the AX title).
    let runningApps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular
    }
    var candidates: [(element: AXUIElement, windowId: UInt32, position: CGPoint?)] = []
    for app in runningApps {
        let pid = app.processIdentifier as pid_t
        let appElement = AXUIElementCreateApplication(pid)
        var windowListRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef)
        if result != .success { continue }
        guard let windowList = windowListRef as? [AXUIElement] else { continue }

        for window in windowList {
            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            if let windowTitle = titleValue as? String, windowTitle == title {
                if let windowId = getWindowID(from: window) {
                    var positionRef: CFTypeRef?
                    var windowPosition: CGPoint?
                    if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success {
                        var position: CGPoint = .zero
                        AXValueGetValue(positionRef as! AXValue, AXValueType.cgPoint, &position)
                        windowPosition = position
                    }
                    candidates.append((window, windowId, windowPosition))
                }
            }
        }
    }

    if let pick = pickClosestCandidate(candidates, approximatePosition: approximatePosition) {
        debugLog("Successfully retrieved fresh window element by title via full scan for: \(title)")
        return (pick.element, pick.windowId)
    }

    debugLog("Failed to retrieve fresh window element by title: \(title)")
    return nil
}

func getFocusedWindowAXUIElement() -> AXUIElement? {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
    
    let pid = frontmostApp.processIdentifier
    let focusedApp = AXUIElementCreateApplication(pid)
    
    var focusedWindow: AnyObject?
    let windowResult = AXUIElementCopyAttributeValue(focusedApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
    
    guard windowResult == .success else {
        debugLog("Failed to get focused window!")
        return nil
    }
    
    return focusedWindow as! AXUIElement?
}

func onMouseDragged(event: NSEvent) {
}

func onMouseUp(event: NSEvent) {
    guard macsyReady.isReady else { return }

    // Hide the layout switcher regardless of mode (actualMode or directMode).
    layoutSwitcherPanel.hide()

    movingWindowInfo = nil
    isMovingAWindow = false
    placedWindowMoveStartPosition = nil
    previousPosition = nil
    previousVelocity = nil
    previousTime = nil
    lastShakeTime = Date().timeIntervalSince1970 + 0.75

    guard !isQuickSnapping,
          isFitting
    else { return }

    if isEditing || isSnapResizing || isQuickSnapping {
        setIsFitting(false)
    }

    let currentLayout = userLayouts.currentLayout

    switch currentLayout.layoutType {
    case .zone:
        handleZoneMouseUp()
    case .grid:
        handleGridMouseUp()
    }

    draggedWindowElement = nil
    draggedWindowInitialPosition = nil
}

private func handleZoneMouseUp() {
    if let hoveredSectionWindow = getHoveredSectionWindow() {
        toLeaveSectionWindow = hoveredSectionWindow
    }

    // Mirror handleGridMouseUp: resolve the element from multiple fallback sources
    // so snap still works even if onWindowMoved didn't set toLeaveElement.
    toLeaveElement = toLeaveElement ?? draggedWindowElement ?? getFocusedWindowAXUIElement()

    guard let window = toLeaveElement else {
        setIsFitting(false)
        toLeaveElement = nil
        toLeaveSectionWindow = nil
        userLayouts.currentLayout.layoutWindow.hide()
        return
    }
    guard let windowId = getWindowID(from: window) else {
        setIsFitting(false)
        toLeaveElement = nil
        toLeaveSectionWindow = nil
        userLayouts.currentLayout.layoutWindow.hide()
        return
    }

    if let sectionWindow = toLeaveSectionWindow {
        if isFitting {
            OriginalWindowProperties.update(windowID: windowId)

            moveWindowToMatch(element: window, targetWindow: sectionWindow.window)

            if let (screenNumber, workspaceNumber) = SpaceLayoutPreferences.getCurrentScreenAndSpace() {
                PlacedWindows.place(windowId: windowId,
                                    screenNumber: screenNumber,
                                    workspaceNumber: workspaceNumber,
                                    layoutName: userLayouts.currentLayoutName,
                                    sectionNumber: toLeaveSectionWindow!.number,
                                    element: toLeaveElement!)
            }

            justDidMouseUp = true
        }

        setIsFitting(false)
        userLayouts.currentLayout.layoutWindow.hide()
    } else {
        setIsFitting(false)
        toLeaveElement = nil
        toLeaveSectionWindow = nil
        userLayouts.currentLayout.layoutWindow.hide()
    }
}

private func handleGridMouseUp() {
    let gridLayoutWindow = userLayouts.currentLayout.gridLayoutWindow

    gridLayoutWindow?.updateSelectionToMousePosition()
    toLeaveElement = toLeaveElement ?? draggedWindowElement ?? getFocusedWindowAXUIElement()
    toLeaveGridRect = gridLayoutWindow?.getSelectionAXRect()

    guard let window = toLeaveElement else {
        setIsFitting(false)
        toLeaveElement = nil
        toLeaveGridRect = nil
        gridLayoutWindow?.hide()
        return
    }
    guard let windowId = getWindowID(from: window) else {
        setIsFitting(false)
        toLeaveElement = nil
        toLeaveGridRect = nil
        gridLayoutWindow?.hide()
        return
    }
    guard let snapRect = toLeaveGridRect else {
        setIsFitting(false)
        toLeaveElement = nil
        toLeaveGridRect = nil
        gridLayoutWindow?.hide()
        return
    }

    if isFitting {
        OriginalWindowProperties.update(windowID: windowId)

        resizeAndMoveWindow(
            element: window,
            newPosition: snapRect.origin,
            newSize: snapRect.size,
            retries: 10
        )

        if let (screenNumber, workspaceNumber) = SpaceLayoutPreferences.getCurrentScreenAndSpace() {
            PlacedWindows.place(windowId: windowId,
                                screenNumber: screenNumber,
                                workspaceNumber: workspaceNumber,
                                layoutName: userLayouts.currentLayoutName,
                                sectionNumber: -1,
                                element: window)
        }

        justDidMouseUp = true
    }

    setIsFitting(false)
    toLeaveElement = nil
    toLeaveGridRect = nil
    gridLayoutWindow?.hide()
}

// MARK: - Window Cycling Functions

func cycleWindowsInZone(forward: Bool) {
    guard let focusedElement = getFocusedWindowAXUIElement(),
          let focusedWindowId = getWindowID(from: focusedElement) else {
        debugLog("No focused window found for cycling")
        return
    }
    
    // Check if the focused window is placed in a zone
    guard PlacedWindows.isPlaced(windowId: focusedWindowId) else {
        debugLog("Focused window is not placed in any zone")
        return
    }
    
    let windowsInZone = getWindowsInSameZone(as: focusedWindowId)
    
    // Need at least 2 windows to cycle
    guard windowsInZone.count > 1 else {
        debugLog("Not enough windows in zone to cycle (found \(windowsInZone.count))")
        return
    }
    
    // Find current window index
    guard let currentIndex = windowsInZone.firstIndex(where: { $0.windowId == focusedWindowId }) else {
        debugLog("Could not find current window in zone list")
        return
    }
    
    // Calculate next index
    let nextIndex: Int
    if forward {
        nextIndex = (currentIndex + 1) % windowsInZone.count
    } else {
        nextIndex = (currentIndex - 1 + windowsInZone.count) % windowsInZone.count
    }
    
    let targetWindow = windowsInZone[nextIndex]
    
    // Activate the target window
    activateWindow(element: targetWindow.element, windowId: targetWindow.windowId)
    
    debugLog("Cycled \(forward ? "forward" : "backward") to window \(targetWindow.windowId)")
}

func getWindowsInSameZone(as windowId: UInt32) -> [(windowId: UInt32, element: AXUIElement)] {
    guard let sectionNumber = PlacedWindows.windows[windowId],
          let layoutName = PlacedWindows.layouts[windowId],
          let screenNumber = PlacedWindows.screens[windowId],
          let workspaceNumber = PlacedWindows.workspaces[windowId] else {
        return []
    }
    
    var windowsInZone: [(windowId: UInt32, element: AXUIElement)] = []
    
    for (otherWindowId, otherSectionNumber) in PlacedWindows.windows {
        // Check if window is in the same zone (section, layout, screen, workspace)
        if otherSectionNumber == sectionNumber,
           PlacedWindows.layouts[otherWindowId] == layoutName,
           PlacedWindows.screens[otherWindowId] == screenNumber,
           PlacedWindows.workspaces[otherWindowId] == workspaceNumber,
           let element = PlacedWindows.elements[otherWindowId] {
            
            windowsInZone.append((windowId: otherWindowId, element: element))
        }
    }
    
    // Sort by window ID for consistent ordering
    windowsInZone.sort { $0.windowId < $1.windowId }
    
    return windowsInZone
}

func activateWindow(element: AXUIElement, windowId: UInt32) {
    // Get the application from the window element
    var pid: pid_t = 0
    let result = AXUIElementGetPid(element, &pid)
    
    guard result == .success else {
        debugLog("Failed to get PID for window \(windowId)")
        return
    }
    
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        debugLog("Failed to get running application for PID \(pid)")
        return
    }
    
    // Activate the application and bring the window to front
    app.activate()
    
    // Use AX API to raise the specific window
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    
    debugLog("Activated window \(windowId) in application \(app.localizedName ?? "Unknown")")
}

func presentingShortcut(_ shortcut: String) -> String {
    let formattedShortcut = shortcut
        .replacingOccurrences(of: "Command", with: "⌘")
        .replacingOccurrences(of: "Control", with: "⌃")
        .replacingOccurrences(of: "Option", with: "⌥")
        .replacingOccurrences(of: "Shift", with: "⇧")
    
    return formattedShortcut
}
