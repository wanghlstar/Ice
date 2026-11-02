//
//  MenuBarItemLayout.swift
//  Ice
//

import Foundation

/// A saved location for a menu bar item.
struct SavedItemLocation: Codable, Hashable {
    /// The information for the item.
    let info: MenuBarItemInfo

    /// The section that the item belongs to.
    let section: MenuBarSection.Name
}

/// The saved layout of the menu bar items.
///
/// macOS adds new menu bar items to the far left of the menu bar, which is the
/// location of the always-hidden section. Items that an app fails to remember
/// the position of are treated as new items each time they appear, so they can
/// end up hidden in the always-hidden section. The saved layout keeps track of
/// the section that each item belongs to, so that these items can be returned
/// to their previous locations.
struct MenuBarItemLayout: Codable, Hashable {
    /// The current version of the saved layout.
    ///
    /// Version 1 recorded items in the always-hidden section using heuristics
    /// that could not distinguish a deliberate placement from a misplacement
    /// by the system, so its always-hidden records cannot be trusted.
    static let currentVersion = 2

    /// The maximum number of locations to save.
    static let maximumLocationCount = 256

    /// The version of the saved layout.
    var version: Int

    /// The saved locations, ordered by position in the menu bar.
    var locations: [SavedItemLocation]

    /// Creates a saved layout with the given locations.
    ///
    /// - Parameter locations: The locations to save, ordered by position
    ///   in the menu bar.
    init(locations: [SavedItemLocation]) {
        self.version = Self.currentVersion
        self.locations = locations
    }

    /// Creates an empty saved layout.
    init() {
        self.init(locations: [])
    }

    /// The keys used to encode and decode the saved layout.
    private enum CodingKeys: String, CodingKey {
        case version
        case locations
    }

    /// Creates a saved layout from the given decoder.
    ///
    /// - Parameter decoder: The decoder to read from.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.locations = try container.decode([SavedItemLocation].self, forKey: .locations)
    }

    /// Loads the saved layout from user defaults.
    ///
    /// - Returns: The saved layout, or `nil` if no valid layout is saved.
    static func load() -> MenuBarItemLayout? {
        guard
            let data = Defaults.data(forKey: .menuBarItemLayout),
            var layout = try? JSONDecoder().decode(MenuBarItemLayout.self, from: data)
        else {
            return nil
        }
        if layout.version < Self.currentVersion {
            layout.migrateFromPreviousVersions()
            layout.save()
        }
        return layout
    }

    /// Migrates a layout saved by a previous version of Ice.
    private mutating func migrateFromPreviousVersions() {
        // Earlier versions could not tell whether an item was placed in the
        // always-hidden section by the user or by the system, so these records
        // are discarded. Items that are still in the always-hidden section are
        // returned to the hidden section, where they can be moved again.
        locations.removeAll { location in
            location.section == .alwaysHidden
        }
        // Earlier versions could record the same item twice: once with its
        // resolved namespace and once with an unresolved (<null>) namespace.
        // Unresolved records cannot be matched reliably, so drop them.
        locations.removeAll { location in
            location.info.namespace.optional == nil
        }
        version = Self.currentVersion
    }

    /// Saves the layout to user defaults.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            Logger.menuBarItemLayout.error("Failed to encode menu bar item layout")
            return
        }
        Defaults.set(data, forKey: .menuBarItemLayout)
    }

    /// Returns the saved location for the item with the given info.
    ///
    /// An item's namespace can be unavailable while macOS is still creating
    /// its window. When the match is otherwise unambiguous, the item is
    /// recognized by its title alone, so that these items are still returned
    /// to their saved locations.
    ///
    /// - Parameter info: The info of the item to return the location for.
    func location(for info: MenuBarItemInfo) -> SavedItemLocation? {
        if let exact = locations.first(where: { $0.info == info }) {
            return exact
        }
        let sameTitle = locations.filter { $0.info.title == info.title }
        if info.namespace.optional == nil {
            let resolved = sameTitle.filter { $0.info.namespace.optional != nil }
            if resolved.count == 1 {
                return resolved[0]
            }
        } else {
            let unresolved = sameTitle.filter { $0.info.namespace.optional == nil }
            if unresolved.count == 1 {
                return unresolved[0]
            }
        }
        return nil
    }

    /// Returns the saved section for the item with the given info.
    ///
    /// - Parameter info: The info of the item to return the section for.
    func section(for info: MenuBarItemInfo) -> MenuBarSection.Name? {
        location(for: info)?.section
    }
}

// MARK: - Destinations

extension MenuBarItemLayout {
    /// Returns a destination that returns the given item to its saved location,
    /// or `nil` if the item should stay in the always-hidden section.
    ///
    /// - Parameters:
    ///   - item: The item to return a destination for.
    ///   - cache: The current menu bar item cache.
    ///   - hiddenControlItem: The control item for the hidden section.
    func restoreDestination(
        for item: MenuBarItem,
        in cache: MenuBarItemManager.ItemCache,
        hiddenControlItem: MenuBarItem
    ) -> MenuBarItemManager.MoveDestination? {
        guard
            let location = location(for: item.info),
            let index = locations.firstIndex(of: location)
        else {
            // The item has never been seen before. New items are added to the
            // far left of the menu bar by the system, which is where the
            // always-hidden section is located. Place the item in the hidden
            // section, where it would be if the always-hidden section were
            // disabled.
            return .leftOfItem(hiddenControlItem)
        }

        switch location.section {
        case .alwaysHidden:
            // The item was deliberately placed in the always-hidden section.
            return nil
        case .hidden:
            return destination(for: index, section: .hidden, in: cache)
                ?? .leftOfItem(hiddenControlItem)
        case .visible:
            return destination(for: index, section: .visible, in: cache)
                ?? .rightOfItem(hiddenControlItem)
        }
    }

    /// Returns a destination that places an item next to its closest saved
    /// neighbor in the given section.
    ///
    /// - Parameters:
    ///   - index: The index of the item's saved location.
    ///   - section: The section that the item belongs to.
    ///   - cache: The current menu bar item cache.
    private func destination(
        for index: Int,
        section: MenuBarSection.Name,
        in cache: MenuBarItemManager.ItemCache
    ) -> MenuBarItemManager.MoveDestination? {
        // Prefer the closest neighbor, checking the neighbor to the right
        // before the neighbor to the left.
        for offset in 1..<locations.count {
            if let destination = destination(offsetBy: offset, from: index, section: section, in: cache) {
                return destination
            }
            if let destination = destination(offsetBy: -offset, from: index, section: section, in: cache) {
                return destination
            }
        }
        return nil
    }

    /// Returns a destination that places an item next to its saved neighbor at
    /// the given offset.
    ///
    /// - Parameters:
    ///   - offset: The offset of the neighbor from the item's saved location.
    ///     A positive offset looks to the right, and a negative offset looks
    ///     to the left.
    ///   - index: The index of the item's saved location.
    ///   - section: The section that the item belongs to.
    ///   - cache: The current menu bar item cache.
    private func destination(
        offsetBy offset: Int,
        from index: Int,
        section: MenuBarSection.Name,
        in cache: MenuBarItemManager.ItemCache
    ) -> MenuBarItemManager.MoveDestination? {
        let neighborIndex = index + offset
        guard locations.indices.contains(neighborIndex) else {
            return nil
        }
        let neighbor = locations[neighborIndex]
        guard neighbor.section == section else {
            return nil
        }
        guard let item = cache[section].first(where: { isMatchingInfo($0.info, neighbor.info) }) else {
            // The neighbor is no longer in the menu bar.
            return nil
        }
        return offset > 0 ? .leftOfItem(item) : .rightOfItem(item)
    }

    /// Returns a Boolean value that indicates whether the two infos refer to
    /// the same item, allowing for an unresolved namespace.
    ///
    /// - Parameters:
    ///   - lhs: The first info to compare.
    ///   - rhs: The second info to compare.
    private func isMatchingInfo(_ lhs: MenuBarItemInfo, _ rhs: MenuBarItemInfo) -> Bool {
        if lhs == rhs {
            return true
        }
        guard lhs.namespace.optional == nil || rhs.namespace.optional == nil else {
            return false
        }
        return lhs.title == rhs.title
    }
}

// MARK: - Logger

private extension Logger {
    /// The logger to use for the menu bar item layout.
    static let menuBarItemLayout = Logger(category: "MenuBarItemLayout")
}
