import Foundation
import SwiftData
import os.log

// MARK: - File Overview
// ============================================================================
// LogCellStore.swift
// uCritAir
//
// PURPOSE:
//   Provides CRUD (Create, Read, Update, Delete) operations for persisting
//   air quality log cell data using Apple's SwiftData framework. Each log cell
//   represents one timestamped snapshot of all sensor readings from the device.
//
// WHAT IS SWIFTDATA?
//   SwiftData is Apple's modern persistence framework (introduced in iOS 17).
//   It replaces Core Data for many use cases. Key concepts used here:
//
//   - **ModelContext**: The "workspace" where you create, read, update, and
//     delete model objects. Think of it like a scratchpad -- changes are
//     not saved to disk until you call `context.save()`.
//
//   - **FetchDescriptor**: Describes *what* data you want to fetch. It has
//     three main parts:
//       1. **Predicate** (`#Predicate`): A filter expression (like SQL WHERE).
//          Example: `#Predicate { $0.deviceId == deviceId }` means "only rows
//          where deviceId matches."
//       2. **SortDescriptor**: How to order results (like SQL ORDER BY).
//          Example: `SortDescriptor(\.cellNumber, order: .forward)` means
//          "sort by cellNumber ascending."
//       3. **fetchLimit**: Maximum number of results to return.
//
//   - **@Attribute(.unique)**: A property decorator on model fields that makes
//     SwiftData enforce uniqueness. When you `insert` a model with a duplicate
//     unique key, SwiftData performs an *upsert* (update-or-insert) instead
//     of creating a duplicate.
//
// DEVICE SCOPING:
//   All operations are scoped by `deviceId` (the BLE peripheral's UUID string).
//   This means multiple devices can store their logs in the same database
//   without conflicts.
//
// THREAD SAFETY:
//   All methods are marked `@MainActor` because SwiftData's `ModelContext`
//   is not thread-safe. In SwiftUI apps, the shared model context lives on
//   the main actor, so all database access must happen there.
//
// ORIGIN:
//   Ported from the web app's `src/lib/db.ts`, which used IndexedDB (a
//   browser-based database). SwiftData is the native iOS equivalent.
// ============================================================================

/// Stateless utility providing SwiftData CRUD operations for `LogCellEntity` objects,
/// scoped by device identifier.
///
/// `LogCellStore` is declared as a caseless `enum` to prevent instantiation -- it acts
/// as a namespace for static database helper methods. All methods require a `ModelContext`
/// to be passed in (dependency injection), making them testable without global state.
///
/// ## Usage
/// ```swift
/// // Save new cells from BLE download
/// try LogCellStore.saveCells(parsedCells, deviceId: device.id, context: modelContext)
///
/// // Fetch all cells for charting
/// let cells = try LogCellStore.fetchAllCells(deviceId: device.id, context: modelContext)
///
/// // Check how many cells are cached
/// let count = try LogCellStore.cachedCellCount(deviceId: device.id, context: modelContext)
///
/// // Find where to resume downloading
/// let maxCell = try LogCellStore.maxCachedCellNumber(deviceId: device.id, context: modelContext)
/// ```
///
/// Ported from `src/lib/db.ts` (IndexedDB -> SwiftData).
enum LogCellStore {

    /// System logger for database operations. Messages appear in Console.app under
    /// the "LogCellStore" category, useful for debugging fetch issues.
    private static let logger = Logger(subsystem: "com.ucritter.ucritair", category: "LogCellStore")

    /// Save an array of parsed log cells to the persistent database for a specific device.
    ///
    /// This method converts each `ParsedLogCell` (a lightweight struct parsed from raw BLE
    /// data) into a `LogCellEntity` (a SwiftData model object) and inserts it into the
    /// model context.
    ///
    /// **Upsert behavior**: `LogCellEntity` has a `compositeKey` property marked with
    /// `@Attribute(.unique)`. The composite key combines `deviceId` and `cellNumber`,
    /// ensuring that if a cell with the same key already exists, SwiftData will *update*
    /// the existing record instead of creating a duplicate. This is called an "upsert"
    /// (update-or-insert) and makes it safe to re-download cells without worrying about
    /// duplicates.
    ///
    /// **Batch behavior**: All cells are inserted in a loop, then `context.save()` is
    /// called once at the end. This is more efficient than saving after each insert
    /// because SwiftData can batch the writes into a single database transaction.
    ///
    /// - Parameters:
    ///   - cells: Array of parsed log cells from BLE data.
    ///   - deviceId: The BLE peripheral's UUID string (scopes data to one device).
    ///   - context: The SwiftData model context to insert into.
    /// - Throws: SwiftData persistence errors if the save fails.
    @MainActor
    static func saveCells(_ cells: [ParsedLogCell], deviceId: String, context: ModelContext) throws {
        logger.info("saveCells: inserting \(cells.count) cells for device \(deviceId)")
        for cell in cells {
            let entity = LogCellEntity(from: cell, deviceId: deviceId)
            context.insert(entity)  // Upsert thanks to @Attribute(.unique) on compositeKey
        }
        try context.save()  // Commit all inserts as a single transaction
        logger.info("saveCells: save completed")
    }

    /// Fetch all log cells for a specific device, sorted by cell number in ascending order.
    ///
    /// This is the primary read operation, used to load data for charting, CSV export,
    /// and timeline display.
    ///
    /// **How the FetchDescriptor works:**
    /// - **Predicate** (`#Predicate { $0.deviceId == deviceId }`): Only return cells
    ///   belonging to this device. The `#Predicate` macro compiles this into an
    ///   efficient database query (similar to SQL `WHERE deviceId = ?`).
    /// - **SortDescriptor** (`.cellNumber`, `.forward`): Sort results by cell number
    ///   in ascending order (oldest first). `.forward` means ascending; `.reverse`
    ///   would mean descending.
    ///
    /// **Diagnostic logging**: If the fetch returns zero results but the database is
    /// not empty, this likely means the `deviceId` changed (e.g., the user re-paired
    /// the device). The method logs the mismatch to help debug this situation.
    ///
    /// - Parameters:
    ///   - deviceId: The BLE peripheral's UUID string to filter by.
    ///   - context: The SwiftData model context to fetch from.
    /// - Returns: Array of `LogCellEntity` sorted by `cellNumber` ascending.
    ///   Returns an empty array if no cells exist for this device.
    /// - Throws: SwiftData fetch errors.
    @MainActor
    static func fetchAllCells(deviceId: String, context: ModelContext) throws -> [LogCellEntity] {
        // Build a fetch descriptor with a predicate (filter) and sort order
        let descriptor = FetchDescriptor<LogCellEntity>(
            predicate: #Predicate { $0.deviceId == deviceId },
            sortBy: [SortDescriptor(\.cellNumber, order: .forward)]
        )
        let results = try context.fetch(descriptor)

        // Diagnostic: if predicate returned 0 results, investigate why.
        // This helps catch issues where deviceId format changed between app versions.
        if results.isEmpty {
            let allDescriptor = FetchDescriptor<LogCellEntity>()
            let totalCount = try context.fetchCount(allDescriptor)
            if totalCount > 0 {
                // Data exists for other devices but not this one -- likely a deviceId mismatch
                let sample = try context.fetch(FetchDescriptor<LogCellEntity>(sortBy: [SortDescriptor(\.cellNumber)]))
                let sampleId = sample.first?.deviceId ?? "nil"
                logger.error("fetchAllCells: 0 results for deviceId='\(deviceId)' but \(totalCount) total cells exist. First cell's deviceId='\(sampleId)'")
            } else {
                logger.info("fetchAllCells: 0 results — database is empty")
            }
        } else {
            logger.info("fetchAllCells: returning \(results.count) cells for device \(deviceId)")
        }

        return results
    }

    /// Get the highest cached cell number for a device, or -1 if no cells exist.
    ///
    /// This is used to determine where to resume downloading log cells from the device.
    /// If the database has cells 0 through 42, this returns 42, so the next BLE download
    /// can start at cell 43.
    ///
    /// **Optimization**: Instead of fetching all cells and finding the max (which would
    /// load every cell into memory), this uses a `FetchDescriptor` that:
    /// 1. Sorts by `cellNumber` in **reverse** (descending) order
    /// 2. Sets `fetchLimit = 1` to only load the single highest-numbered cell
    ///
    /// This is equivalent to the SQL query:
    /// ```sql
    /// SELECT cellNumber FROM LogCellEntity
    /// WHERE deviceId = ? ORDER BY cellNumber DESC LIMIT 1
    /// ```
    ///
    /// - Parameters:
    ///   - deviceId: The BLE peripheral's UUID string to filter by.
    ///   - context: The SwiftData model context to fetch from.
    /// - Returns: The highest cell number in the cache, or `-1` if no cells exist
    ///   for this device (the sentinel value `-1` simplifies "start from 0" logic
    ///   in the caller since `-1 + 1 = 0`).
    /// - Throws: SwiftData fetch errors.
    @MainActor
    static func maxCachedCellNumber(deviceId: String, context: ModelContext) throws -> Int {
        var descriptor = FetchDescriptor<LogCellEntity>(
            predicate: #Predicate { $0.deviceId == deviceId },
            sortBy: [SortDescriptor(\.cellNumber, order: .reverse)]  // Descending -- highest first
        )
        descriptor.fetchLimit = 1  // Only need the single highest cell
        let results = try context.fetch(descriptor)
        let result = results.first?.cellNumber ?? -1
        logger.info("maxCachedCellNumber: device=\(deviceId) max=\(result)")
        return result
    }

    /// Get the number of cached log cells for a specific device.
    ///
    /// Uses `context.fetchCount(_:)` instead of `context.fetch(_:).count` for efficiency.
    /// `fetchCount` asks the database for just the count without loading any model objects
    /// into memory -- it's equivalent to SQL `SELECT COUNT(*) FROM ... WHERE ...`.
    ///
    /// This is used to display "X cells cached" in the UI and to estimate download progress.
    ///
    /// - Parameters:
    ///   - deviceId: The BLE peripheral's UUID string to filter by.
    ///   - context: The SwiftData model context.
    /// - Returns: The number of cells stored for this device.
    /// - Throws: SwiftData fetch errors.
    @MainActor
    static func cachedCellCount(deviceId: String, context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<LogCellEntity>(
            predicate: #Predicate { $0.deviceId == deviceId }
        )
        return try context.fetchCount(descriptor)
    }

    /// Delete all cached log cells for a specific device.
    ///
    /// This performs a batch delete by:
    /// 1. Fetching all cells for the device (reuses ``fetchAllCells(deviceId:context:)``).
    /// 2. Deleting each one from the model context.
    /// 3. Saving the context to commit the deletions to disk.
    ///
    /// **Why not use a batch delete?** SwiftData's `ModelContext` doesn't have a
    /// built-in "delete where" API at the time of writing. The fetch-then-delete
    /// pattern is the standard approach. For the typical data sizes in this app
    /// (hundreds to low thousands of cells), this is fast enough.
    ///
    /// This is triggered by the user via the "Clear Cache" button in the developer
    /// tools, or when re-downloading all data from the device.
    ///
    /// - Parameters:
    ///   - deviceId: The BLE peripheral's UUID string identifying which device's data to clear.
    ///   - context: The SwiftData model context.
    /// - Throws: SwiftData fetch or save errors.
    @MainActor
    static func clearAllCells(deviceId: String, context: ModelContext) throws {
        // Fetch all cells for this device first
        let cells = try fetchAllCells(deviceId: deviceId, context: context)
        // Mark each cell for deletion in the model context
        for cell in cells {
            context.delete(cell)
        }
        // Commit all deletions as a single transaction
        try context.save()
    }
}
