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
    /// The maximum number of locations to save.
    static let maximumLocationCount = 256

    /// The saved locations, ordered by position in the menu bar.
    var locations: [SavedItemLocation]

    /// Creates a saved layout with the given locations.
    ///
    /// - Parameter locations: The locations to save, ordered by position
    ///   in the menu bar.
    init(locations: [SavedItemLocation]) {
        self.locations = locations
    }

    /// Creates an empty saved layout.
    init() {
        self.init(locations: [])
    }

    /// Loads the saved layout from user defaults.
    ///
    /// - Returns: The saved layout, or `nil` if no valid layout is saved.
    static func load() -> MenuBarItemLayout? {
        guard
            let data = Defaults.data(forKey: .menuBarItemLayout),
            let layout = try? JSONDecoder().decode(MenuBarItemLayout.self, from: data)
        else {
            return nil
        }
        return layout
    }

    /// Saves the layout to user defaults.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            Logger.menuBarItemLayout.error("Failed to encode menu bar item layout")
            return
        }
        Defaults.set(data, forKey: .menuBarItemLayout)
    }

    /// Returns the saved section for the item with the given info.
    ///
    /// - Parameter info: The info of the item to return the section for.
    func section(for info: MenuBarItemInfo) -> MenuBarSection.Name? {
        locations.first { $0.info == info }?.section
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
        guard let index = locations.firstIndex(where: { $0.info == item.info }) else {
            // The item has never been seen before. New items are added to the
            // far left of the menu bar by the system, which is where the
            // always-hidden section is located. Place the item in the hidden
            // section, where it would be if the always-hidden section were
            // disabled.
            return .leftOfItem(hiddenControlItem)
        }

        switch locations[index].section {
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
        guard let item = cache[section].first(where: { $0.info == neighbor.info }) else {
            // The neighbor is no longer in the menu bar.
            return nil
        }
        return offset > 0 ? .leftOfItem(item) : .rightOfItem(item)
    }
}

// MARK: - Logger

private extension Logger {
    /// The logger to use for the menu bar item layout.
    static let menuBarItemLayout = Logger(category: "MenuBarItemLayout")
}
