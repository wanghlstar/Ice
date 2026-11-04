//
//  MenuBarItemManager.swift
//  Ice
//

import Cocoa
import Combine

/// Manager for menu bar items.
@MainActor
final class MenuBarItemManager: ObservableObject {
    /// Cache for menu bar items.
    struct ItemCache: Hashable {
        /// All cached menu bar items, keyed by section.
        private var items = [MenuBarSection.Name: [MenuBarItem]]()

        /// All cached menu bar items.
        var allItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: self[section])
            }
        }

        /// The cached menu bar items managed by Ice.
        var managedItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: managedItems(for: section))
            }
        }

        /// Clears the cache.
        mutating func clear() {
            items.removeAll()
        }

        /// Returns the cached menu bar items managed by Ice for the given section.
        func managedItems(for section: MenuBarSection.Name) -> [MenuBarItem] {
            self[section].filter { item in
                // Filter out items that can't be hidden.
                guard item.canBeHidden else {
                    return false
                }

                if item.owningApplication == .current {
                    // Ice icon is the only item owned by Ice that should be included.
                    guard item.title == ControlItem.Identifier.iceIcon.rawValue else {
                        return false
                    }
                }

                return true
            }
        }

        /// Returns the name of the section for the given menu bar item.
        func section(for item: MenuBarItem) -> MenuBarSection.Name? {
            for (section, items) in self.items where items.contains(where: { $0.info == item.info }) {
                return section
            }
            return nil
        }

        /// Accesses the items in the given section.
        subscript(section: MenuBarSection.Name) -> [MenuBarItem] {
            get { items[section, default: []] }
            set { items[section] = newValue }
        }
    }

    /// An anchor describing where to return a temporarily shown item.
    private struct ReturnAnchor {
        /// The side of the target item to place the shown item on.
        enum Side {
            case left
            case right
        }

        /// The window identifier of the target item at the time the anchor was created.
        let targetWindowID: CGWindowID

        /// The information of the target item at the time the anchor was created.
        let targetInfo: MenuBarItemInfo

        /// The side of the target item to place the shown item on.
        let side: Side
    }

    /// Context for a temporarily shown menu bar item.
    private struct TempShownItemContext {
        /// The window identifier of the item at the time it was shown.
        let windowID: CGWindowID

        /// The information associated with the item.
        let info: MenuBarItemInfo

        /// The anchor to resolve into a destination when rehiding the item.
        let returnAnchor: ReturnAnchor

        /// The window of the item's shown interface.
        let shownInterfaceWindow: WindowInfo?

        /// A Boolean value that indicates whether the menu bar item's interface is showing.
        var isShowingInterface: Bool {
            guard let currentWindow = shownInterfaceWindow.flatMap({ WindowInfo(windowID: $0.windowID) }) else {
                return false
            }
            return if
                currentWindow.layer != CGWindowLevelForKey(.popUpMenuWindow),
                let owningApplication = currentWindow.owningApplication
            {
                owningApplication.isActive && currentWindow.isOnScreen
            } else {
                currentWindow.isOnScreen
            }
        }
    }

    /// The manager's menu bar item cache.
    @Published private(set) var itemCache = ItemCache()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Cached signature for the most recent menu bar items.
    ///
    /// The signature includes the frame of each item, so that the cache is
    /// updated when items are rearranged, even if the set of item windows
    /// stays the same.
    private var cachedItemSignature: ItemSignature?

    /// The saved layout of the menu bar items.
    private var savedItemLayout: MenuBarItemLayout

    /// A Boolean value that indicates whether a saved layout is available.
    private var hasSavedItemLayout: Bool

    /// Context values for the current temporarily shown items.
    private var tempShownItemContexts = [TempShownItemContext]()

    /// A timer that determines when to rehide the temporarily shown items.
    private var tempShownItemsTimer: Timer?

    /// The last time an item was rescued for each item info.
    private var lastRescueDates = [MenuBarItemInfo: Date]()

    /// The number of failed rescue attempts for each item info.
    private var rescueAttemptCounts = [MenuBarItemInfo: Int]()

    /// A Boolean value that indicates whether items are currently being rescued.
    private var isRescuingItems = false

    /// The last time a menu bar item was moved.
    private var lastItemMoveStartDate: Date?

    /// The last time the mouse was moved.
    private var lastMouseMoveStartDate: Date?

    /// Counter to determine if a menu bar item, or group of menu bar
    /// items is being moved.
    private var itemMoveCount = 0

    /// A Boolean value that indicates whether a mouse button is down.
    private var isMouseButtonDown = false

    /// The frames of the menu bar items when a mouse button was pressed inside
    /// the menu bar, used to detect a drag that rearranges the items.
    private var menuBarItemFramesBeforeMouseDown: [CGWindowID: CGRect]?

    /// The window identifier of the item beneath the cursor when the mouse
    /// button was pressed, used to identify the item that a drag moved.
    private var draggedItemWindowID: CGWindowID?

    /// A Boolean value that indicates whether a drag check is in progress.
    private var isCheckingForUserItemDrag = false

    /// The time at which the current rescue attempt started.
    private var rescueStartDate: Date?

    /// The window identifiers of the menu bar items from the previous update.
    ///
    /// Items whose window identifier is new were created again by their app,
    /// which can cause them to appear in a different section.
    private var knownItemWindowIDs = Set<CGWindowID>()

    /// The number of consecutive cache passes in which an item has been
    /// observed in the always-hidden section at a stable position.
    private var misplacedPassCounts = [MenuBarItemInfo: Int]()

    /// The position of each item, relative to the always-hidden control item,
    /// during the most recent cache pass in which it was observed in the
    /// always-hidden section.
    ///
    /// Positions are measured relative to the control item so that items are
    /// not treated as unstable when another item's width changes and shifts
    /// the entire menu bar.
    private var lastMisplacedOffsets = [MenuBarItemInfo: CGFloat]()

    /// Event type mask for tracking mouse events.
    private let mouseTrackingMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .leftMouseUp,
        .rightMouseUp,
        .otherMouseUp,
    ]

    /// The maximum number of items to rescue per cache.
    private static let maxRescueCount = 3

    /// The number of failed rescue attempts after which the time between
    /// attempts is increased. The item is never recorded as always-hidden, so
    /// it is still rescued if it becomes movable later.
    private static let maxRescueAttempts = 3

    /// The minimum amount of time to wait between rescue attempts for the
    /// same item.
    private static let rescueCooldown: TimeInterval = 15

    /// The amount of time to wait between rescue attempts after the maximum
    /// number of attempts has been reached.
    private static let abandonedRescueCooldown: TimeInterval = 300

    /// The amount of time after which a rescue operation is considered stuck.
    private static let rescueTimeout: TimeInterval = 120

    /// The number of consecutive cache passes in which an item must be
    /// observed in the always-hidden section before it is rescued. Items move
    /// through this section while the menu bar is settling, and a single pass
    /// should not trigger a move.
    private static let rescueDebouncePasses = 2

    /// A Boolean value that indicates whether a menu bar item, or
    /// group of menu bar items is being moved.
    var isMovingItem: Bool {
        itemMoveCount > 0
    }

    /// A Boolean value that indicates whether a menu bar item has
    /// recently moved.
    var itemHasRecentlyMoved: Bool {
        guard let lastItemMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastItemMoveStartDate) <= 1
    }

    /// A Boolean value that indicates whether the mouse has recently moved.
    var mouseHasRecentlyMoved: Bool {
        guard let lastMouseMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastMouseMoveStartDate) <= 1
    }

    /// Creates a manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
        let layout = MenuBarItemLayout.load()
        self.savedItemLayout = layout ?? MenuBarItemLayout()
        self.hasSavedItemLayout = layout != nil
    }

    /// Sets up the manager.
    func performSetup() {
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        Timer.publish(every: 5, on: .main, in: .default)
            .autoconnect()
            .merge(with: Just(.now))
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .delay(for: 0.25, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        Publishers.Merge(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else {
                return
            }
            Task {
                // Give the system a moment to settle the new menu bar layout.
                try? await Task.sleep(for: .milliseconds(500))
                // Reset the signature, as the menu bar layout has changed.
                self.cachedItemSignature = nil
                await self.cacheItemsIfNeeded()
            }
        }
        .store(in: &c)

        Publishers.Merge(
            UniversalEventMonitor.publisher(for: mouseTrackingMask),
            RunLoopLocalEventMonitor.publisher(for: mouseTrackingMask, mode: .eventTracking)
        )
        .removeDuplicates()
        .sink { [weak self] event in
            guard let self else {
                return
            }
            switch event.type {
            case .mouseMoved:
                lastMouseMoveStartDate = .now
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                isMouseButtonDown = true
                if event.type == .leftMouseDown {
                    captureMenuBarItemFrames()
                }
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                isMouseButtonDown = false
                if event.type == .leftMouseUp {
                    scheduleUserItemDragCheck()
                }
            default:
                break
            }
        }
        .store(in: &c)

        cancellables = c
    }
}

// MARK: - Cache Items

extension MenuBarItemManager {
    /// Logs a warning that the given menu bar item was not added to the cache.
    private func logNotCachedWarning(for item: MenuBarItem) {
        Logger.itemManager.warning("\(item.logString) was not cached")
    }

    /// Logs a reason for skipping the cache.
    private func logSkippingCache(reason: String) {
        Logger.itemManager.debug("Skipping menu bar item cache as \(reason)")
    }

    /// Caches the given menu bar items, without checking whether the control
    /// items are in the correct order.
    private func uncheckedCacheItems(
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?,
        otherItems: [MenuBarItem],
        allItems: [MenuBarItem]
    ) {
        Logger.itemManager.debug("Caching menu bar items")

        let predicates = Predicates.sectionPredicates(
            hiddenControlItem: hiddenControlItem,
            alwaysHiddenControlItem: alwaysHiddenControlItem
        )

        var cache = ItemCache()
        var tempShownItems = [(MenuBarItem, ReturnAnchor)]()

        for item in otherItems {
            if let context = tempShownItemContexts.first(where: { $0.windowID == item.windowID })
                ?? tempShownItemContexts.first(where: { $0.info == item.info })
            {
                // Keep track of temporarily shown items and their return anchors separately.
                // We want to cache them as if they were in their original locations. Once all other
                // items are cached, use the return anchors to insert the items into the cache
                // at the correct position.
                tempShownItems.append((item, context.returnAnchor))
            } else if predicates.isInVisibleSection(item) {
                cache[.visible].append(item)
            } else if predicates.isInHiddenSection(item) {
                cache[.hidden].append(item)
            } else if predicates.isInAlwaysHiddenSection(item) {
                cache[.alwaysHidden].append(item)
            } else {
                logNotCachedWarning(for: item)
            }
        }

        for (item, anchor) in tempShownItems {
            let destination = resolveDestination(from: anchor, in: allItems)
                ?? fallbackDestination(in: allItems)

            guard let destination else {
                logNotCachedWarning(for: item)
                continue
            }
            switch destination {
            case .leftOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.hidden].append(item)
                case .alwaysHiddenControlItem:
                    cache[.alwaysHidden].append(item)
                default:
                    if
                        let section = cache.section(for: targetItem),
                        let index = cache[section].firstIndex(matching: targetItem.info)
                    {
                        let clampedIndex = index.clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            case .rightOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.visible].insert(item, at: 0)
                case .alwaysHiddenControlItem:
                    cache[.hidden].insert(item, at: 0)
                default:
                    if
                        let section = cache.section(for: targetItem),
                        let index = cache[section].firstIndex(matching: targetItem.info)
                    {
                        let clampedIndex = (index - 1).clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            }
        }

        itemCache = cache
    }

    /// Caches the current menu bar items if needed, ensuring that the control
    /// items are in the correct order.
    func cacheItemsIfNeeded() async {
        do {
            try await waitForItemsToStopMoving(timeout: .seconds(1))
        } catch is TaskTimeoutError {
            logSkippingCache(reason: "an item is currently being moved")
            return
        } catch {
            guard !itemHasRecentlyMoved else {
                logSkippingCache(reason: "an item was recently moved")
                return
            }
        }

        let itemWindowIDs = Bridging.getWindowList(option: [.menuBarItems, .activeSpace])
        let signature = ItemSignature(windowIDs: itemWindowIDs)
        if signature == cachedItemSignature {
            guard !misplacedPassCounts.isEmpty else {
                logSkippingCache(reason: "menu bar items have not changed")
                return
            }
            // A misplaced item is still waiting on a second pass before it can
            // be rescued. Those passes only happen while the cache is being
            // rebuilt, so keep rebuilding even though the menu bar itself has
            // not changed. Without this, an item that is moved to the wrong
            // section at login or wake stays there until the menu bar changes.
            Logger.itemManager.debug("Menu bar items have not changed, but an item is awaiting rescue")
        }

        let previousWindowIDs = knownItemWindowIDs

        var items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        let allItems = items

        let hiddenControlItem = items.firstIndex(matching: .hiddenControlItem).map { items.remove(at: $0) }
        let alwaysHiddenControlItem = items.firstIndex(matching: .alwaysHiddenControlItem).map { items.remove(at: $0) }

        guard let hiddenControlItem else {
            Logger.itemManager.warning("Missing control item for hidden section")
            Logger.itemManager.debug("Clearing menu bar item cache")
            itemCache.clear()
            // Reset the signature, as the cache could not be updated. Without
            // this, the cache would stay empty until the menu bar items change.
            cachedItemSignature = nil
            return
        }

        do {
            if let alwaysHiddenControlItem {
                try await enforceControlItemOrder(
                    hiddenControlItem: hiddenControlItem,
                    alwaysHiddenControlItem: alwaysHiddenControlItem
                )
            }
            uncheckedCacheItems(
                hiddenControlItem: hiddenControlItem,
                alwaysHiddenControlItem: alwaysHiddenControlItem,
                otherItems: items,
                allItems: allItems
            )
        } catch {
            Logger.itemManager.error("Error enforcing control item order: \(error)")
            Logger.itemManager.debug("Clearing menu bar item cache")
            itemCache.clear()
            // Reset the signature, as the cache could not be updated. Without
            // this, the cache would stay empty until the menu bar items change.
            cachedItemSignature = nil
            return
        }

        let misplacedItems = reconcileSavedItemLayout(
            previousWindowIDs: previousWindowIDs,
            newCache: itemCache,
            anchorX: (alwaysHiddenControlItem ?? hiddenControlItem).frame.minX
        )

        cachedItemSignature = signature
        knownItemWindowIDs = Set(allItems.map(\.windowID))

        rescueMisplacedItems(
            misplacedItems,
            hiddenControlItem: hiddenControlItem,
            alwaysHiddenControlItem: alwaysHiddenControlItem
        )
    }
}

// MARK: - Item Signature

extension MenuBarItemManager {
    /// A signature that describes the current state of the menu bar items.
    private struct ItemSignature: Equatable {
        /// The frame of each menu bar item, keyed by window identifier.
        private var frames: [CGWindowID: CGRect]

        /// Creates a signature for the menu bar items with the given
        /// window identifiers.
        ///
        /// - Parameter windowIDs: The window identifiers of the menu bar items.
        init(windowIDs: [CGWindowID]) {
            var frames = [CGWindowID: CGRect]()
            for windowID in windowIDs {
                guard let frame = Bridging.getWindowFrame(for: windowID) else {
                    continue
                }
                frames[windowID] = frame
            }
            self.frames = frames
        }
    }
}

// MARK: - Saved Layout

extension MenuBarItemManager {
    /// Updates the saved layout to match the given cache, returning the items
    /// that are not in the section they belong to.
    ///
    /// An item is only recorded as belonging to the always-hidden section if
    /// the user was observed placing it there with a drag. Items that the
    /// system created again in a different section are returned to the section
    /// they belong to, and items that cannot currently be moved are never
    /// recorded as always-hidden, so that a failed move does not make a
    /// misplacement permanent.
    ///
    /// - Parameters:
    ///   - previousWindowIDs: The window identifiers from the previous update.
    ///   - newCache: The current cache.
    ///
    /// - Returns: The items to return to their saved locations.
    private func reconcileSavedItemLayout(
        previousWindowIDs: Set<CGWindowID>,
        newCache: ItemCache,
        anchorX: CGFloat
    ) -> [MenuBarItem] {
        func isTempShown(_ item: MenuBarItem) -> Bool {
            tempShownItemContexts.contains { context in
                context.windowID == item.windowID || context.info == item.info
            }
        }

        var locations = [SavedItemLocation]()
        var misplacedItems = [MenuBarItem]()
        var savedInfos = Set<MenuBarItemInfo>()
        // The window identifiers are only known after a cache pass, so the
        // first pass after launch sees every item as newly created.
        let isFirstPass = previousWindowIDs.isEmpty

        for section in MenuBarSection.Name.menuBarOrder {
            for item in newCache[section] {
                // Items whose namespace could not be resolved are recorded
                // under the namespace that was resolved previously, so that a
                // single item does not end up with multiple locations.
                let previouslySavedInfo = savedItemLayout.location(for: item.info)?.info

                // Without a namespace, the item can't be identified reliably,
                // so leave its saved location alone until the namespace can be
                // resolved again. This happens while an app is restarting.
                guard item.info.namespace.optional != nil || previouslySavedInfo != nil else {
                    continue
                }

                let info = item.info.namespace.optional != nil
                    ? item.info
                    : (previouslySavedInfo ?? item.info)

                // Items are identified by their info, so only save a single
                // location for each one. Items that share the same info are
                // indistinguishable from one another.
                guard savedInfos.insert(info).inserted else {
                    continue
                }

                let savedSection = savedItemLayout.section(for: item.info)
                var sectionForLocation = section

                // An item that the system created again can appear in a
                // different section than the one it belongs to.
                let isNewWindow = !previousWindowIDs.contains(item.windowID)

                var isMisplaced = false

                let resolution = MenuBarItemLayout.resolveLocation(
                    saved: savedSection,
                    observed: section,
                    isNewWindow: isNewWindow,
                    isFirstPass: isFirstPass,
                    isMovable: item.isMovable
                )
                sectionForLocation = resolution.section
                isMisplaced = resolution.isMisplaced

                if
                    isMisplaced,
                    hasSavedItemLayout,
                    item.isMovable,
                    !isTempShown(item)
                {
                    // Require a stable position across multiple passes, so that
                    // an item that is passing through the section while the menu
                    // bar settles is not moved.
                    let offset = item.frame.minX - anchorX
                    let isStable = lastMisplacedOffsets[info].map { previous in
                        abs(previous - offset) <= 1
                    } ?? false
                    let passCount = isStable
                        ? (misplacedPassCounts[info] ?? 0) + 1
                        : 1
                    misplacedPassCounts[info] = passCount
                    lastMisplacedOffsets[info] = offset
                    if passCount >= Self.rescueDebouncePasses {
                        misplacedItems.append(item)
                    }
                } else {
                    rescueAttemptCounts[info] = nil
                    lastRescueDates[info] = nil
                    misplacedPassCounts[info] = nil
                    lastMisplacedOffsets[info] = nil
                }

                locations.append(SavedItemLocation(info: info, section: sectionForLocation))
            }
        }

        // Preserve the saved locations of items that are not currently in the
        // menu bar, so that they can be returned when they reappear.
        let currentInfos = Set(locations.map(\.info))
        let absentLocations = savedItemLayout.locations.filter { location in
            if currentInfos.contains(location.info) {
                return false
            }
            // Drop entries that duplicate a recorded item under a different
            // namespace resolution.
            return !locations.contains { recorded in
                recorded.info.title == location.info.title &&
                (recorded.info.namespace.optional == nil || location.info.namespace.optional == nil)
            }
        }
        locations.append(contentsOf: absentLocations)
        if locations.count > MenuBarItemLayout.maximumLocationCount {
            locations.removeLast(locations.count - MenuBarItemLayout.maximumLocationCount)
        }

        if locations != savedItemLayout.locations {
            savedItemLayout = MenuBarItemLayout(locations: locations)
            savedItemLayout.save()
        }
        hasSavedItemLayout = true

        return misplacedItems
    }
}

// MARK: - User Item Drags

extension MenuBarItemManager {
    /// Snapshots the frames of the menu bar items when a mouse button is
    /// pressed inside the menu bar, so that a drag can be detected when the
    /// button is released.
    private func captureMenuBarItemFrames() {
        draggedItemWindowID = nil
        guard
            !isMovingItem,
            appState?.eventManager.isMouseInsideMenuBar == true
        else {
            menuBarItemFramesBeforeMouseDown = nil
            return
        }
        var frames = [CGWindowID: CGRect]()
        for windowID in Bridging.getWindowList(option: [.menuBarItems, .activeSpace]) {
            guard let frame = Bridging.getWindowFrame(for: windowID) else {
                continue
            }
            frames[windowID] = frame
        }
        // The item that the user is dragging is the one beneath the cursor.
        // Prefer the narrowest frame, so that an expanded control item, which
        // spans the entire menu bar, does not shadow the item.
        if let location = MouseCursor.locationCoreGraphics {
            draggedItemWindowID = frames
                .filter { $0.value.contains(location) }
                .min { $0.value.width < $1.value.width }?
                .key
        }
        menuBarItemFramesBeforeMouseDown = frames.isEmpty ? nil : frames
    }

    /// Checks whether the mouse press that just ended rearranged a menu bar
    /// item, after giving the menu bar a moment to settle.
    private func scheduleUserItemDragCheck() {
        guard let framesBeforeMouseDown = menuBarItemFramesBeforeMouseDown else {
            draggedItemWindowID = nil
            return
        }
        let draggedWindowID = draggedItemWindowID
        menuBarItemFramesBeforeMouseDown = nil
        draggedItemWindowID = nil
        isCheckingForUserItemDrag = true
        Task {
            let items = await waitForMenuBarItemsToSettle()
            recordUserItemDrag(
                windowID: draggedWindowID,
                from: framesBeforeMouseDown,
                items: items
            )
            isCheckingForUserItemDrag = false
        }
    }

    /// Records the section that the user moved a menu bar item into, so that
    /// Ice does not return the item to a different section.
    ///
    /// - Parameters:
    ///   - windowID: The window identifier of the dragged item, if known.
    ///   - framesBeforeMouseDown: The frames of the menu bar items before the
    ///     drag began.
    ///   - items: The menu bar items after the drag settled.
    private func recordUserItemDrag(
        windowID: CGWindowID?,
        from framesBeforeMouseDown: [CGWindowID: CGRect],
        items: [MenuBarItem]
    ) {
        guard !isMovingItem else {
            return
        }

        let item: MenuBarItem?
        if let windowID {
            item = items.first { $0.windowID == windowID }
        } else if let mouseLocation = MouseCursor.locationCoreGraphics {
            // Fall back to the item that ended up beneath the pointer.
            item = items.first { item in
                movedFromFrame(item, framesBeforeMouseDown) &&
                item.frame.insetBy(dx: -8, dy: 0).contains(mouseLocation)
            }
        } else {
            item = nil
        }

        guard
            let item,
            movedFromFrame(item, framesBeforeMouseDown)
        else {
            return
        }

        if item.info == .hiddenControlItem || item.info == .alwaysHiddenControlItem {
            // The user moved a section divider, so the sections are now
            // arranged the way they want. Follow the new arrangement.
            adoptSections(of: items)
            return
        }

        guard let section = section(of: item, in: items) else {
            return
        }

        let previouslySavedInfo = savedItemLayout.location(for: item.info)?.info
        let info = item.info.namespace.optional != nil
            ? item.info
            : (previouslySavedInfo ?? item.info)

        guard savedItemLayout.section(for: info) != section else {
            return
        }

        var locations = savedItemLayout.locations.filter { location in
            // Drop the previous location of the item, along with a location
            // that was recorded under an unresolved namespace.
            location.info != info &&
            !(location.info.namespace.optional == nil && location.info.title == info.title)
        }
        locations.append(SavedItemLocation(info: info, section: section))
        savedItemLayout = MenuBarItemLayout(locations: locations)
        savedItemLayout.save()
        hasSavedItemLayout = true
        rescueAttemptCounts[info] = nil
        lastRescueDates[info] = nil

        Logger.itemManager.notice("Recorded user placement of \(info.description) in section \(section.rawValue)")
    }

    /// Records the section that each item is currently in, so that moving a
    /// section divider updates the saved layout.
    ///
    /// - Parameter items: The current menu bar items.
    private func adoptSections(of items: [MenuBarItem]) {
        var locations = savedItemLayout.locations
        var changed = false
        for item in items {
            guard
                item.info != .hiddenControlItem,
                item.info != .alwaysHiddenControlItem,
                let section = section(of: item, in: items)
            else {
                continue
            }
            let info = item.info.namespace.optional != nil
                ? item.info
                : (savedItemLayout.location(for: item.info)?.info ?? item.info)
            if let index = locations.firstIndex(where: { $0.info == info }) {
                if locations[index].section != section {
                    locations[index] = SavedItemLocation(info: info, section: section)
                    changed = true
                }
            } else {
                locations.append(SavedItemLocation(info: info, section: section))
                changed = true
            }
        }
        guard changed else {
            return
        }
        savedItemLayout = MenuBarItemLayout(locations: locations)
        savedItemLayout.save()
        hasSavedItemLayout = true
        Logger.itemManager.notice("Recorded user placement of section dividers")
    }

    /// Returns a Boolean value that indicates whether the item moved from the
    /// frame that it had before the mouse button was pressed.
    ///
    /// - Parameters:
    ///   - item: The item to check.
    ///   - framesBeforeMouseDown: The frames of the menu bar items before the
    ///     drag began.
    private func movedFromFrame(
        _ item: MenuBarItem,
        _ framesBeforeMouseDown: [CGWindowID: CGRect]
    ) -> Bool {
        guard let oldFrame = framesBeforeMouseDown[item.windowID] else {
            return false
        }
        return abs(oldFrame.minX - item.frame.minX) > 2
    }

    /// Waits for the menu bar items to stop moving, so that the section that a
    /// drag ended in can be determined from their settled frames.
    private func waitForMenuBarItemsToSettle() async -> [MenuBarItem] {
        var items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        var frames = menuBarItemFrames(of: items)
        var stablePasses = 0
        let deadline = Date.now.addingTimeInterval(3)
        while Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))
            items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
            let newFrames = menuBarItemFrames(of: items)
            if newFrames == frames {
                stablePasses += 1
            } else {
                stablePasses = 0
            }
            frames = newFrames
            if stablePasses >= 2 {
                break
            }
        }
        return items
    }

    /// Returns the frames of the given menu bar items, keyed by window ID.
    private func menuBarItemFrames(of items: [MenuBarItem]) -> [CGWindowID: CGRect] {
        var frames = [CGWindowID: CGRect]()
        for item in items {
            frames[item.windowID] = item.frame
        }
        return frames
    }

    /// Returns the section that contains the given item.
    ///
    /// - Parameters:
    ///   - item: The item to return the section for.
    ///   - items: The current menu bar items.
    private func section(of item: MenuBarItem, in items: [MenuBarItem]) -> MenuBarSection.Name? {
        guard let hiddenControlItem = items.first(where: { $0.info == .hiddenControlItem }) else {
            return nil
        }
        let alwaysHiddenControlItem = items.first(where: { $0.info == .alwaysHiddenControlItem })
        let predicates = Predicates.sectionPredicates(
            hiddenControlItem: hiddenControlItem,
            alwaysHiddenControlItem: alwaysHiddenControlItem
        )
        if predicates.isInVisibleSection(item) {
            return .visible
        }
        if predicates.isInHiddenSection(item) {
            return .hidden
        }
        if predicates.isInAlwaysHiddenSection(item) {
            return .alwaysHidden
        }
        return nil
    }
}

// MARK: - Rescue Items

extension MenuBarItemManager {
    /// A Boolean value that indicates whether misplaced items can currently
    /// be returned to their saved locations.
    private var canMoveMisplacedItems: Bool {
        guard let appState else {
            return false
        }
        // The menu bar is not being laid out normally, so item positions do
        // not reflect the sections they belong to.
        guard
            !appState.menuBarManager.isMenuBarHiddenBySystem,
            !appState.isActiveSpaceFullscreen
        else {
            return false
        }
        guard
            !isMouseButtonDown,
            !isMovingItem,
            !isCheckingForUserItemDrag,
            !mouseHasRecentlyMoved
        else {
            return false
        }
        return NSEvent.modifierFlags.isEmpty
    }

    /// A Boolean value that indicates whether the always-hidden section is
    /// enabled and hidden, and can therefore receive items.
    private var canMoveIntoAlwaysHiddenSection: Bool {
        guard
            let alwaysHiddenSection = appState?.menuBarManager.section(withName: .alwaysHidden),
            alwaysHiddenSection.isEnabled
        else {
            return false
        }
        return alwaysHiddenSection.isHidden
    }

    /// Returns a Boolean value that indicates whether a rescue can currently
    /// be attempted for the given item.
    ///
    /// - Parameter item: The item to check.
    private func canAttemptRescue(of item: MenuBarItem) -> Bool {
        guard item.isMovable else {
            return false
        }
        let key = rescueKey(for: item)
        guard let lastRescueDate = lastRescueDates[key] else {
            return true
        }
        let attempts = rescueAttemptCounts[key] ?? 0
        let cooldown = attempts >= Self.maxRescueAttempts
            ? Self.abandonedRescueCooldown
            : Self.rescueCooldown
        return Date.now.timeIntervalSince(lastRescueDate) >= cooldown
    }

    /// Returns the key used to track rescue attempts for the given item.
    ///
    /// - Parameter item: The item to return the key for.
    private func rescueKey(for item: MenuBarItem) -> MenuBarItemInfo {
        savedItemLayout.location(for: item.info)?.info ?? item.info
    }

    /// A Boolean value that indicates whether a new rescue operation can
    /// currently begin.
    private var canStartRescue: Bool {
        guard isRescuingItems else {
            return true
        }
        guard let rescueStartDate else {
            return true
        }
        // A rescue operation can get stuck waiting for a modifier key or a
        // mouse button to be released. Don't let it block later rescues
        // forever.
        return Date.now.timeIntervalSince(rescueStartDate) > Self.rescueTimeout
    }

    /// Rescues the given items, returning them to their saved locations.
    ///
    /// - Parameters:
    ///   - items: The items to rescue.
    ///   - hiddenControlItem: The control item for the hidden section.
    ///   - alwaysHiddenControlItem: The control item for the always-hidden
    ///     section, if the section is enabled.
    private func rescueMisplacedItems(
        _ items: [MenuBarItem],
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?
    ) {
        guard !items.isEmpty else {
            return
        }
        Task {
            await performRescue(
                of: items,
                hiddenControlItem: hiddenControlItem,
                alwaysHiddenControlItem: alwaysHiddenControlItem
            )
        }
    }

    /// Rescues the given items, returning them to their saved locations.
    ///
    /// - Parameters:
    ///   - items: The items to rescue.
    ///   - hiddenControlItem: The control item for the hidden section.
    ///   - alwaysHiddenControlItem: The control item for the always-hidden
    ///     section, if the section is enabled.
    private func performRescue(
        of items: [MenuBarItem],
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?
    ) async {
        guard canStartRescue else {
            return
        }
        isRescuingItems = true
        rescueStartDate = .now
        defer {
            isRescuingItems = false
            rescueStartDate = nil
        }

        for item in items.prefix(Self.maxRescueCount) {
            guard canMoveMisplacedItems else {
                Logger.itemManager.debug("Not rescuing \(item.logString), as an item may be in use")
                return
            }
            guard canAttemptRescue(of: item) else {
                continue
            }
            guard let destination = savedItemLayout.restoreDestination(
                for: item,
                in: itemCache,
                hiddenControlItem: hiddenControlItem,
                alwaysHiddenControlItem: alwaysHiddenControlItem
            ) else {
                continue
            }
            if savedItemLayout.section(for: item.info) == .alwaysHidden {
                // Only move items into the always-hidden section while it is
                // hidden, so that the move is not visible.
                guard canMoveIntoAlwaysHiddenSection else {
                    continue
                }
            }

            Logger.itemManager.notice("Returning \(item.logString) to \(destination.logString)")

            let key = rescueKey(for: item)
            do {
                try await move(item: item, to: destination)
                // Count every attempt. The count is cleared once the item is
                // observed in another section, which also covers a move that
                // reported success without taking effect.
                rescueAttemptCounts[key, default: 0] += 1
                lastRescueDates[key] = .now
            } catch {
                rescueAttemptCounts[key, default: 0] += 1
                lastRescueDates[key] = .now
                // Reset the signature, as the item is still misplaced. Without
                // this, the item would not be reevaluated until the menu bar
                // items change.
                cachedItemSignature = nil
                Logger.itemManager.error("Failed to return \(item.logString) (error: \(error))")
            }
        }
    }
}

// MARK: - Menu Bar Item Events -

extension MenuBarItemManager {
    /// An error that can occur during menu bar item event operations.
    struct EventError: Error, CustomStringConvertible, LocalizedError {
        /// Error codes within the domain of menu bar item event errors.
        enum ErrorCode: Int, CustomStringConvertible {
            /// An operation could not be completed.
            case couldNotComplete

            /// The creation of a menu bar item event failed.
            case eventCreationFailure

            /// The shared app state is invalid or could not be found.
            case invalidAppState

            /// An event source could not be created or is otherwise invalid.
            case invalidEventSource

            /// The location of the mouse cursor is invalid or could not be found.
            case invalidCursorLocation

            /// A menu bar item is invalid.
            case invalidItem

            /// A menu bar item cannot be moved.
            case notMovable

            /// A menu bar item event operation timed out.
            case eventOperationTimeout

            /// A menu bar item frame check timed out.
            case frameCheckTimeout

            /// An operation timed out.
            case otherTimeout

            /// Description of the code for debugging purposes.
            var description: String {
                switch self {
                case .couldNotComplete: "couldNotComplete"
                case .eventCreationFailure: "eventCreationFailure"
                case .invalidAppState: "invalidAppState"
                case .invalidEventSource: "invalidEventSource"
                case .invalidCursorLocation: "invalidCursorLocation"
                case .invalidItem: "invalidItem"
                case .notMovable: "notMovable"
                case .eventOperationTimeout: "eventOperationTimeout"
                case .frameCheckTimeout: "frameCheckTimeout"
                case .otherTimeout: "otherTimeout"
                }
            }

            /// A string to use for logging purposes.
            var logString: String {
                "\(self) (rawValue: \(rawValue))"
            }
        }

        /// The error code of this error.
        let code: ErrorCode

        /// The error's menu bar item.
        let item: MenuBarItem

        /// The message associated with this error.
        var message: String {
            switch code {
            case .couldNotComplete:
                "Could not complete event operation for \"\(item.displayName)\""
            case .eventCreationFailure:
                "Failed to create event for \"\(item.displayName)\""
            case .invalidAppState:
                "Invalid app state for \"\(item.displayName)\""
            case .invalidEventSource:
                "Invalid event source for \"\(item.displayName)\""
            case .invalidCursorLocation:
                "Invalid cursor location for \"\(item.displayName)\""
            case .invalidItem:
                "\"\(item.displayName)\" is invalid"
            case .notMovable:
                "\"\(item.displayName)\" is not movable"
            case .eventOperationTimeout:
                "Event operation timed out for \"\(item.displayName)\""
            case .frameCheckTimeout:
                "Frame check timed out for \"\(item.displayName)\""
            case .otherTimeout:
                "Operation timed out for \"\(item.displayName)\""
            }
        }

        /// Description of the error for debugging purposes.
        var description: String {
            var parameters = [String]()
            parameters.append("code: \(code.logString)")
            parameters.append("item: \(item.logString)")
            return "\(Self.self)(\(parameters.joined(separator: ", ")))"
        }

        /// Description of the error for display purposes.
        var errorDescription: String? {
            message
        }

        /// Suggestion for recovery from the error.
        var recoverySuggestion: String? {
            "Please try again. If the error persists, please file a bug report."
        }
    }
}

// MARK: - Async Waiters

extension MenuBarItemManager {
    /// Waits asynchronously for the given operation to complete.
    /// 
    /// - Parameters:
    ///   - timeout: Amount of time to wait before throwing an error.
    ///   - operation: The operation to perform.
    private func waitWithTask(timeout: Duration?, operation: @escaping @Sendable () async throws -> Void) async throws {
        let task = if let timeout {
            Task(timeout: timeout, operation: operation)
        } else {
            Task(operation: operation)
        }
        try await task.value
    }

    /// Waits asynchronously for all menu bar items to stop moving.
    ///
    /// - Parameter timeout: Amount of time to wait before throwing an error.
    func waitForItemsToStopMoving(timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) { [weak self] in
            guard let self else {
                return
            }
            while await isMovingItem {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Waits asynchronously for the mouse to stop moving.
    ///
    /// - Parameters:
    ///   - threshold: A threshold to use to determine whether the mouse has stopped moving.
    ///   - timeout: Amount of time to wait before throwing an error.
    func waitForMouseToStopMoving(threshold: TimeInterval = 0.1, timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) { [weak self] in
            guard let self else {
                return
            }
            while true {
                try Task.checkCancellation()
                guard let date = await lastMouseMoveStartDate else {
                    break
                }
                if Date.now.timeIntervalSince(date) > threshold {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Waits asynchronously until no modifier keys are pressed.
    ///
    /// - Parameter timeout: Amount of time to wait before throwing an error.
    func waitForNoModifiersPressed(timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) {
            // Return early if no flags are pressed.
            if NSEvent.modifierFlags.isEmpty {
                return
            }

            var cancellable: AnyCancellable?

            await withCheckedContinuation { continuation in
                cancellable = Publishers.Merge(
                    UniversalEventMonitor.publisher(for: .flagsChanged),
                    RunLoopLocalEventMonitor.publisher(for: .flagsChanged, mode: .eventTracking)
                )
                .removeDuplicates()
                .sink { _ in
                    if NSEvent.modifierFlags.isEmpty {
                        cancellable?.cancel()
                        continuation.resume()
                    }
                }
            }
        }
    }
}

// MARK: - Move Items

extension MenuBarItemManager {
    /// A destination that a menu bar item can be moved to.
    enum MoveDestination {
        /// The menu bar item will be moved to the left of the given menu bar item.
        case leftOfItem(MenuBarItem)

        /// The menu bar item will be moved to the right of the given menu bar item.
        case rightOfItem(MenuBarItem)

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .leftOfItem(let item): "left of \(item.logString)"
            case .rightOfItem(let item): "right of \(item.logString)"
            }
        }
    }

    /// Returns the current frame for the given item.
    ///
    /// - Parameter item: The item to return the current frame for.
    private func getCurrentFrame(for item: MenuBarItem) -> CGRect? {
        guard let frame = Bridging.getWindowFrame(for: item.window.windowID) else {
            Logger.itemManager.error("Couldn't get current frame for \(item.logString)")
            return nil
        }
        return frame
    }

    /// Returns the end point for moving an item to the given destination.
    ///
    /// - Parameter destination: The destination to return the end point for.
    private func getEndPoint(for destination: MoveDestination) throws -> CGPoint {
        switch destination {
        case .leftOfItem(let targetItem):
            guard let currentFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return CGPoint(x: currentFrame.minX, y: currentFrame.midY)
        case .rightOfItem(let targetItem):
            guard let currentFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return CGPoint(x: currentFrame.maxX, y: currentFrame.midY)
        }
    }

    /// Returns the fallback point for returning the given item to its original
    /// position if a move fails.
    ///
    /// - Parameter item: The item to return the fallback point for.
    private func getFallbackPoint(for item: MenuBarItem) throws -> CGPoint {
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }
        return CGPoint(x: currentFrame.midX, y: currentFrame.midY)
    }

    /// Returns the target item for the given destination.
    ///
    /// - Parameter destination: The destination to get the target item from.
    private func getTargetItem(for destination: MoveDestination) -> MenuBarItem {
        switch destination {
        case .leftOfItem(let targetItem), .rightOfItem(let targetItem): targetItem
        }
    }

    /// Returns a Boolean value that indicates whether the given item is in the
    /// correct position for the given destination.
    ///
    /// - Parameters:
    ///   - item: The item to check the position of.
    ///   - destination: The destination to compare the item's position against.
    private func itemHasCorrectPosition(item: MenuBarItem, for destination: MoveDestination) throws -> Bool {
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }
        switch destination {
        case .leftOfItem(let targetItem):
            guard let currentTargetFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return currentFrame.maxX == currentTargetFrame.minX
        case .rightOfItem(let targetItem):
            guard let currentTargetFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return currentFrame.minX == currentTargetFrame.maxX
        }
    }

    /// Returns a Boolean value that indicates whether the given events have the
    /// same values for each integer value field.
    ///
    /// - Parameters:
    ///   - events: The events to compare.
    ///   - integerFields: An array of integer value fields to compare on each event.
    private nonisolated func eventsMatch(_ events: [CGEvent], by integerFields: [CGEventField]) -> Bool {
        var fieldValues = Set<[Int64]>()
        for event in events {
            let values = integerFields.map(event.getIntegerValueField)
            fieldValues.insert(values)
            if fieldValues.count != 1 {
                return false
            }
        }
        return true
    }

    /// Posts an event to the given event tap location.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    private nonisolated func postEvent(_ event: CGEvent, to location: EventTap.Location) {
        Logger.itemManager.debug("Posting \(event.type.logString) to \(location.logString)")
        switch location {
        case .hidEventTap:
            event.post(tap: .cghidEventTap)
        case .sessionEventTap:
            event.post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap:
            event.post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid):
            event.postToPid(pid)
        }
    }

    /// Posts an event to the given event tap location and waits until it is
    /// received before returning.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    ///   - item: The menu bar item that the event affects.
    private func postEventAndWaitToReceive(
        _ event: CGEvent,
        to location: EventTap.Location,
        item: MenuBarItem
    ) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let eventTap = EventTap(
                options: .listenOnly,
                location: location,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else {
                    return nil
                }

                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                Logger.itemManager.debug("Received \(type.logString) at \(location.logString) (item: \(item.logString))")

                // Disable the tap and resume the continuation.
                proxy.disable()
                continuation.resume()

                return nil
            }

            eventTap.enable(timeout: .milliseconds(50)) {
                Logger.itemManager.error("Event tap \"\(eventTap.label)\" timed out (item: \(item.logString))")
                eventTap.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            // Post the event to the location.
            postEvent(event, to: location)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The menu bar item that the event affects.
    private func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        item: MenuBarItem
    ) async throws {
        // Create a null event and assign it unique user data.
        guard let nullEvent = CGEvent(source: nil) else {
            throw EventError(code: .eventCreationFailure, item: item)
        }
        let nullUserData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(nullEvent)))
        nullEvent.setIntegerValueField(.eventSourceUserData, value: nullUserData)

        return try await withCheckedThrowingContinuation { continuation in
            // Create an event tap for the null event at the first location.
            // This tap throws away all events it receives.
            let eventTap1 = EventTap(
                label: "EventTap 1",
                options: .defaultTap,
                location: firstLocation,
                place: .tailAppendEventTap,
                types: [nullEvent.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that this is the null event.
                guard rEvent.getIntegerValueField(.eventSourceUserData) == nullUserData else {
                    return nil
                }

                // Disable the tap and post the real event to the second location.
                proxy.disable()
                postEvent(event, to: secondLocation)

                return nil
            }

            // Create an event tap for the real event at the second location.
            // This tap can listen for events, but cannot alter or discard them.
            let eventTap2 = EventTap(
                label: "EventTap 2",
                options: .listenOnly,
                location: secondLocation,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else {
                    return nil
                }

                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                // Disable the tap, post the event to the first location, and resume
                // the continuation.
                proxy.disable()
                postEvent(event, to: firstLocation)
                continuation.resume()

                return nil
            }

            // Enable both taps, with a timeout on the second tap.
            eventTap1.enable()
            eventTap2.enable(timeout: .milliseconds(50)) {
                Logger.itemManager.error("Event tap \"\(eventTap2.label)\" timed out (item: \(item.logString))")
                eventTap1.disable()
                eventTap2.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            // Post the null event to the first location.
            postEvent(nullEvent, to: firstLocation)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event, then
    /// waits for the frame of the given menu bar item to change before returning.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The item whose frame should be observed.
    private func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        waitingForFrameChangeOf item: MenuBarItem
    ) async throws {
        guard let currentFrame = getCurrentFrame(for: item) else {
            try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
            Logger.itemManager.warning("Couldn't get menu bar item frame for \(item.logString), so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
            return
        }
        try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
        try await waitForFrameChange(of: item, initialFrame: currentFrame, timeout: .milliseconds(50))
    }

    /// Waits for a menu bar item's frame to change from an initial frame.
    ///
    /// - Parameters:
    ///   - item: The item whose frame should be observed.
    ///   - initialFrame: An initial frame to compare the item's frame against.
    ///   - timeout: The amount of time to wait before throwing a timeout error.
    private func waitForFrameChange(of item: MenuBarItem, initialFrame: CGRect, timeout: Duration) async throws {
        struct FrameCheckCancellationError: Error { }

        let frameCheckTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                guard let currentFrame = await self.getCurrentFrame(for: item) else {
                    throw FrameCheckCancellationError()
                }
                if currentFrame != initialFrame {
                    Logger.itemManager.debug("Menu bar item frame for \(item.logString) has changed to \(NSStringFromRect(currentFrame))")
                    return
                }
            }
        }
        do {
            try await frameCheckTask.value
        } catch is FrameCheckCancellationError {
            Logger.itemManager.warning("Menu bar item frame check for \(item.logString) was cancelled, so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
        } catch is TaskTimeoutError {
            throw EventError(code: .frameCheckTimeout, item: item)
        }
    }

    /// Permits all events for an event source during the given suppression states,
    /// suppressing local events for the given interval.
    private func permitAllEvents(
        for stateID: CGEventSourceStateID,
        during states: [CGEventSuppressionState],
        suppressionInterval: TimeInterval,
        item: MenuBarItem
    ) throws {
        guard let source = CGEventSource(stateID: stateID) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        for state in states {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
        }
        source.localEventsSuppressionInterval = suppressionInterval
    }

    /// Tries to wake up the given item if it is not responding to events.
    private func wakeUpItem(_ item: MenuBarItem) async throws {
        Logger.itemManager.debug("Attempting to wake up \(item.logString)")

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try await scrombleEvent(
            mouseDownEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item
        )
        try await scrombleEvent(
            mouseUpEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item
        )
    }

    /// Moves a menu bar item to the given destination, without restoring the mouse
    /// pointer to its initial location.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    private func moveItemWithoutRestoringMouseLocation(_ item: MenuBarItem, to destination: MoveDestination) async throws {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }

        guard item.isMovable else {
            throw EventError(code: .notMovable, item: item)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }

        let startPoint = CGPoint(x: 20_000, y: 20_000)
        let endPoint = try getEndPoint(for: destination)
        let fallbackPoint = try getFallbackPoint(for: item)
        let targetItem = getTargetItem(for: destination)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: startPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: endPoint,
                item: targetItem,
                pid: item.ownerPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: fallbackPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        lastItemMoveStartDate = .now

        do {
            try await scrombleEvent(
                mouseDownEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item
            )
            try await scrombleEvent(
                mouseUpEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item
            )
        } catch {
            do {
                Logger.itemManager.debug("Posting fallback event for moving \(item.logString)")
                // Catch this, as we still want to throw the existing error if the fallback fails.
                try await postEventAndWaitToReceive(
                    fallbackEvent,
                    to: .sessionEventTap,
                    item: item
                )
            } catch {
                Logger.itemManager.error("Failed to post fallback event for moving \(item.logString)")
            }
            throw error
        }
    }

    /// Moves a menu bar item to the given destination.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    func move(item: MenuBarItem, to destination: MoveDestination) async throws {
        if try itemHasCorrectPosition(item: item, for: destination) {
            Logger.itemManager.debug("\(item.logString) is already in the correct position")
            return
        }

        do {
            // Order of these waiters matters, as the modifiers could be released
            // while the mouse is still moving.
            try await waitForNoModifiersPressed()
            try await waitForMouseToStopMoving()
        } catch {
            throw EventError(code: .couldNotComplete, item: item)
        }

        Logger.itemManager.info("Moving \(item.logString) to \(destination.logString)")

        guard let appState else {
            throw EventError(code: .invalidAppState, item: item)
        }
        guard let cursorLocation = MouseCursor.locationCoreGraphics else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        guard let initialFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        appState.eventManager.stopAll()
        defer {
            appState.eventManager.startAll()
        }

        MouseCursor.hide()

        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        // Item movement can occasionally fail. Retry up to a total of 5 attempts,
        // throwing the last attempt's error if it fails.
        for n in 1...5 {
            do {
                try await moveItemWithoutRestoringMouseLocation(item, to: destination)
                guard let newFrame = getCurrentFrame(for: item) else {
                    throw EventError(code: .invalidItem, item: item)
                }
                if newFrame != initialFrame {
                    Logger.itemManager.info("Successfully moved \(item.logString)")
                    break
                } else {
                    throw EventError(code: .couldNotComplete, item: item)
                }
            } catch where n < 5 {
                Logger.itemManager.warning("Attempt \(n) to move \(item.logString) failed (error: \(error))")
                try await wakeUpItem(item)
                Logger.itemManager.info("Retrying move of \(item.logString)")
                continue
            }
        }
    }

    /// Moves a menu bar item to the given destination and waits until the move
    /// completes before returning.
    /// 
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    ///   - timeout: Amount of time to wait before throwing an error.
    func slowMove(item: MenuBarItem, to destination: MoveDestination, timeout: Duration = .seconds(1)) async throws {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }
        try await move(item: item, to: destination)
        let waitTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                if try await self.itemHasCorrectPosition(item: item, for: destination) {
                    return
                }
            }
        }
        do {
            try await waitTask.value
        } catch is TaskTimeoutError {
            throw EventError(code: .otherTimeout, item: item)
        }
    }
}

// MARK: - Click Items

extension MenuBarItemManager {
    /// Clicks the given menu bar item with the given mouse button.
    func click(item: MenuBarItem, with mouseButton: CGMouseButton) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        guard let cursorLocation = MouseCursor.locationCoreGraphics else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        let buttonStates = mouseButton.buttonStates
        let clickPoint = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.down),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.up),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.up),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        MouseCursor.hide()

        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        do {
            Logger.itemManager.info("Clicking \(item.logString) with \(mouseButton.logString)")
            try await postEventAndWaitToReceive(
                mouseDownEvent,
                to: .sessionEventTap,
                item: item
            )
            try await postEventAndWaitToReceive(
                mouseUpEvent,
                to: .sessionEventTap,
                item: item
            )
        } catch {
            do {
                Logger.itemManager.debug("Posting fallback event for clicking \(item.logString)")
                // Catch this, as we still want to throw the existing error if the fallback fails.
                try await postEventAndWaitToReceive(
                    fallbackEvent,
                    to: .sessionEventTap,
                    item: item
                )
            } catch {
                Logger.itemManager.error("Failed to post fallback event for clicking \(item.logString)")
            }
            throw error
        }
    }
}

// MARK: - Temporarily Show Items

extension MenuBarItemManager {
    /// Gets the anchor to return the given item to after it is temporarily shown.
    private func getReturnAnchor(for item: MenuBarItem, in items: [MenuBarItem]) -> ReturnAnchor? {
        let info = item.info
        if let index = items.firstIndex(where: { $0.info == info }) {
            if items.indices.contains(index + 1) {
                let target = items[index + 1]
                return ReturnAnchor(targetWindowID: target.windowID, targetInfo: target.info, side: .left)
            } else if items.indices.contains(index - 1) {
                let target = items[index - 1]
                return ReturnAnchor(targetWindowID: target.windowID, targetInfo: target.info, side: .right)
            }
        }
        return nil
    }

    /// Resolves an anchor into a destination using the current menu bar items.
    ///
    /// Matches the anchor's target by window identifier first, then by item
    /// information, so that a renamed or recreated item doesn't break the move.
    private func resolveDestination(from anchor: ReturnAnchor, in items: [MenuBarItem]) -> MoveDestination? {
        let target = items.first(where: { $0.windowID == anchor.targetWindowID })
            ?? items.first(where: { $0.info == anchor.targetInfo })
        guard let target else {
            return nil
        }
        return switch anchor.side {
        case .left: .leftOfItem(target)
        case .right: .rightOfItem(target)
        }
    }

    /// Returns a destination that hides the item to the left of the hidden
    /// control item, used when its original anchor can no longer be resolved.
    private func fallbackDestination(in items: [MenuBarItem]) -> MoveDestination? {
        guard let hiddenControlItem = items.first(where: { $0.info == .hiddenControlItem }) else {
            return nil
        }
        return .leftOfItem(hiddenControlItem)
    }

    /// Schedules a timer for the given interval, attempting to rehide the current
    /// temporarily shown items when the timer fires.
    private func runTempShownItemTimer(for interval: TimeInterval) {
        Logger.itemManager.debug("Running rehide timer for temporarily shown items with interval: \(interval)")
        tempShownItemsTimer?.invalidate()
        tempShownItemsTimer = .scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Logger.itemManager.debug("Rehide timer fired")
            Task {
                await self.rehideTempShownItems()
            }
        }
    }

    /// Temporarily shows the given item.
    ///
    /// The item is cached alongside a destination that it will be automatically returned
    /// to. If `true` is passed to the `clickWhenFinished` parameter, the item is clicked
    /// once movement is finished.
    ///
    /// - Parameters:
    ///   - item: An item to show.
    ///   - clickWhenFinished: A Boolean value that indicates whether the item should be
    ///     clicked once movement is finished.
    ///   - mouseButton: The mouse button of the click.
    func tempShowItem(_ item: MenuBarItem, clickWhenFinished: Bool, mouseButton: CGMouseButton) {
        if
            let latest = MenuBarItem(windowID: item.windowID),
            latest.isOnScreen
        {
            if clickWhenFinished {
                Task {
                    do {
                        try await click(item: latest, with: mouseButton)
                    } catch {
                        Logger.itemManager.error("ERROR: \(error)")
                    }
                }
            }
            return
        }

        guard
            let appState,
            let screen = NSScreen.main,
            let applicationMenuFrame = appState.menuBarManager.getApplicationMenuFrame(for: screen.displayID)
        else {
            Logger.itemManager.warning("No application menu frame, so not showing \(item.logString)")
            return
        }

        Logger.itemManager.info("Temporarily showing \(item.logString)")

        var items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)

        guard let returnAnchor = getReturnAnchor(for: item, in: items) else {
            Logger.itemManager.warning("No return anchor for \(item.logString)")
            return
        }

        // Remove all items up to the hidden control item.
        items.trimPrefix { $0.info != .hiddenControlItem }
        // Remove the hidden control item.
        items.removeFirst()
        // Remove all offscreen items.
        items.trimPrefix { !$0.isOnScreen }

        let maxX = if let rightArea = screen.auxiliaryTopRightArea {
            max(rightArea.minX + 20, applicationMenuFrame.maxX)
        } else {
            applicationMenuFrame.maxX
        }

        // Remove items until we have enough room to show this item.
        items.trimPrefix { $0.frame.minX - item.frame.width <= maxX }

        guard let targetItem = items.first else {
            let alert = NSAlert()
            alert.messageText = "Not enough room to show \"\(item.displayName)\""
            alert.runModal()
            return
        }

        let initialWindows = WindowInfo.getOnScreenWindows()

        Task {
            if clickWhenFinished {
                do {
                    try await slowMove(item: item, to: .leftOfItem(targetItem))
                    try await click(item: item, with: mouseButton)
                } catch {
                    Logger.itemManager.error("ERROR: \(error)")
                }
            } else {
                do {
                    try await move(item: item, to: .leftOfItem(targetItem))
                } catch {
                    Logger.itemManager.error("ERROR: \(error)")
                }
            }

            try? await Task.sleep(for: .milliseconds(100))

            let currentWindows = WindowInfo.getOnScreenWindows()

            let shownInterfaceWindow = currentWindows.first { currentWindow in
                currentWindow.ownerPID == item.ownerPID &&
                !initialWindows.contains { initialWindow in
                    currentWindow.windowID == initialWindow.windowID
                }
            }

            let context = TempShownItemContext(
                windowID: item.windowID,
                info: item.info,
                returnAnchor: returnAnchor,
                shownInterfaceWindow: shownInterfaceWindow
            )
            tempShownItemContexts.append(context)
            runTempShownItemTimer(for: appState.settingsManager.advancedSettingsManager.tempShowInterval)
        }
    }

    /// Rehides all temporarily shown items.
    ///
    /// If an item is currently showing its interface, this method waits for the
    /// interface to close before hiding the items.
    func rehideTempShownItems() async {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }

        guard !tempShownItemContexts.isEmpty else {
            return
        }

        guard !isMouseButtonDown else {
            Logger.itemManager.debug("Mouse button is down, so waiting to rehide")
            runTempShownItemTimer(for: 3)
            return
        }
        guard !tempShownItemContexts.contains(where: { $0.isShowingInterface }) else {
            Logger.itemManager.debug("Menu bar item interface is shown, so waiting to rehide")
            runTempShownItemTimer(for: 3)
            return
        }

        Logger.itemManager.info("Rehiding temporarily shown items")

        var failedContexts = [TempShownItemContext]()

        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)

        MouseCursor.hide()

        defer {
            MouseCursor.show()
        }

        while let context = tempShownItemContexts.popLast() {
            guard let item = items.first(where: { $0.windowID == context.windowID })
                ?? items.first(where: { $0.info == context.info })
            else {
                Logger.itemManager.warning("Could not find temporarily shown item \(context.info) to rehide")
                continue
            }

            let destination = resolveDestination(from: context.returnAnchor, in: items)
                ?? fallbackDestination(in: items)

            guard let destination else {
                Logger.itemManager.warning("No destination available to rehide \(item.logString)")
                failedContexts.append(context)
                continue
            }

            do {
                try await move(item: item, to: destination)
            } catch {
                Logger.itemManager.error("Failed to rehide \(item.logString) (error: \(error))")
                failedContexts.append(context)
            }
        }

        if failedContexts.isEmpty {
            tempShownItemsTimer?.invalidate()
            tempShownItemsTimer = nil
        } else {
            tempShownItemContexts = failedContexts
            Logger.itemManager.warning("Some items failed to rehide")
            runTempShownItemTimer(for: 3)
        }
    }

    /// Removes a temporarily shown item from the cache.
    ///
    /// This ensures that the item will _not_ be returned to its previous location.
    func removeTempShownItemFromCache(with info: MenuBarItemInfo) {
        tempShownItemContexts.removeAll { $0.info == info }
    }
}

// MARK: - Arrange Items

extension MenuBarItemManager {
    /// Enforces the order of the given control items, ensuring that the always-hidden
    /// control item stays to the left of the hidden control item.
    ///
    /// - Parameters:
    ///   - hiddenControlItem: A menu bar item that represents the control item for the
    ///     hidden section.
    ///   - alwaysHiddenControlItem: A menu bar item that represents the control item
    ///     for the always-hidden section.
    func enforceControlItemOrder(hiddenControlItem: MenuBarItem, alwaysHiddenControlItem: MenuBarItem) async throws {
        guard !isMouseButtonDown else {
            Logger.itemManager.debug("Mouse button is down, so will not enforce control item order")
            return
        }
        guard !mouseHasRecentlyMoved else {
            Logger.itemManager.debug("Mouse has recently moved, so will not enforce control item order")
            return
        }
        if hiddenControlItem.frame.maxX <= alwaysHiddenControlItem.frame.minX {
            Logger.itemManager.info("Arranging menu bar items")
            try await slowMove(item: alwaysHiddenControlItem, to: .leftOfItem(hiddenControlItem))
        }
    }
}

// MARK: - Menu Bar Item Event Helper Types

/// Button states for menu bar item events.
private enum MenuBarItemEventButtonState {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case otherMouseDown
    case otherMouseUp
}

/// Event types for menu bar item events.
private enum MenuBarItemEventType {
    /// The event type for moving a menu bar item.
    case move(MenuBarItemEventButtonState)

    /// The event type for clicking a menu bar item.
    case click(MenuBarItemEventButtonState)

    /// The button state of this event type.
    var buttonState: MenuBarItemEventButtonState {
        switch self {
        case .move(let state), .click(let state): state
        }
    }

    /// This event type's equivalent CGEventType.
    var cgEventType: CGEventType {
        switch buttonState {
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        case .rightMouseDown: .rightMouseDown
        case .rightMouseUp: .rightMouseUp
        case .otherMouseDown: .otherMouseDown
        case .otherMouseUp: .otherMouseUp
        }
    }

    /// The event flags for this event type.
    var cgEventFlags: CGEventFlags {
        switch self {
        case .move(.leftMouseDown): .maskCommand
        case .move, .click: []
        }
    }

    /// The mouse button for this event type.
    var mouseButton: CGMouseButton {
        switch buttonState {
        case .leftMouseDown, .leftMouseUp: .left
        case .rightMouseDown, .rightMouseUp: .right
        case .otherMouseDown, .otherMouseUp: .center
        }
    }
}

// MARK: - CGEventField Helpers

private extension CGEventField {
    /// Key to access a field that contains the event's window identifier.
    static let windowID = CGEventField(rawValue: 0x33)! // swiftlint:disable:this force_unwrapping

    /// An array of integer event fields that can be used to compare menu bar item events.
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowID,
    ]
}

// MARK: - CGEventFilterMask Helpers

private extension CGEventFilterMask {
    /// Specifies that all events should be permitted during event suppression states.
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]
}

// MARK: - CGEventType Helpers

private extension CGEventType {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .null: "null event"
        case .leftMouseDown: "leftMouseDown event"
        case .leftMouseUp: "leftMouseUp event"
        case .rightMouseDown: "rightMouseDown event"
        case .rightMouseUp: "rightMouseUp event"
        case .mouseMoved: "mouseMoved event"
        case .leftMouseDragged: "leftMouseDragged event"
        case .rightMouseDragged: "rightMouseDragged event"
        case .keyDown: "keyDown event"
        case .keyUp: "keyUp event"
        case .flagsChanged: "flagsChanged event"
        case .scrollWheel: "scrollWheel event"
        case .tabletPointer: "tabletPointer event"
        case .tabletProximity: "tabletProximity event"
        case .otherMouseDown: "otherMouseDown event"
        case .otherMouseUp: "otherMouseUp event"
        case .otherMouseDragged: "otherMouseDragged event"
        case .tapDisabledByTimeout: "tapDisabledByTimeout event"
        case .tapDisabledByUserInput: "tapDisabledByUserInput event"
        @unknown default: "unknown event"
        }
    }
}

// MARK: - CGMouseButton Helpers

private extension CGMouseButton {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .left: "left mouse button"
        case .right: "right mouse button"
        case .center: "center mouse button"
        @unknown default: "unknown mouse button"
        }
    }

    /// The equivalent down and up button states for menu bar item click events.
    var buttonStates: (down: MenuBarItemEventButtonState, up: MenuBarItemEventButtonState) {
        switch self {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
    }
}

// MARK: - CGEvent Constructor

private extension CGEvent {
    /// Returns an event that can be sent to the given menu bar item.
    ///
    /// - Parameters:
    ///   - type: The type of the event.
    ///   - location: The location of the event. Does not need to be within the bounds of the item.
    ///   - item: The target item of the event.
    ///   - pid: The target process identifier of the event. Does not need to be the item's `ownerPID`.
    ///   - source: The source of the event.
    class func menuBarItemEvent(type: MenuBarItemEventType, location: CGPoint, item: MenuBarItem, pid: pid_t, source: CGEventSource) -> CGEvent? {
        let mouseType = type.cgEventType
        let mouseButton = type.mouseButton

        guard let event = CGEvent(mouseEventSource: source, mouseType: mouseType, mouseCursorPosition: location, mouseButton: mouseButton) else {
            return nil
        }

        event.flags = type.cgEventFlags

        let targetPID = Int64(pid)
        let userData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(event)))
        let windowID = Int64(item.windowID)

        event.setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        event.setIntegerValueField(.windowID, value: windowID)

        if case .click = type {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        return event
    }
}

// MARK: - Logger

private extension Logger {
    /// The logger to use for the menu bar item manager.
    static let itemManager = Logger(category: "MenuBarItemManager")
}
