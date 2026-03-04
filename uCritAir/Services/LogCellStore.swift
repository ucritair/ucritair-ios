import Foundation
import SwiftData
import os.log

/// SwiftData CRUD operations for log cell persistence, scoped by device.
/// Ported from src/lib/db.ts (IndexedDB → SwiftData).
enum LogCellStore {

    private static let logger = Logger(subsystem: "com.ucritter.ucritair", category: "LogCellStore")

    /// Save an array of ParsedLogCell values to the database for a specific device.
    /// Uses insert — LogCellEntity.compositeKey is @Attribute(.unique) for upsert behavior.
    @MainActor
    static func saveCells(_ cells: [ParsedLogCell], deviceId: String, context: ModelContext) throws {
        logger.info("saveCells: inserting \(cells.count) cells for device \(deviceId)")
        for cell in cells {
            let entity = LogCellEntity(from: cell, deviceId: deviceId)
            context.insert(entity)
        }
        try context.save()
        logger.info("saveCells: save completed")
    }

    /// Fetch all log cells for a device, sorted by cellNumber ascending.
    @MainActor
    static func fetchAllCells(deviceId: String, context: ModelContext) throws -> [LogCellEntity] {
        // Fetch with device predicate
        let descriptor = FetchDescriptor<LogCellEntity>(
            predicate: #Predicate { $0.deviceId == deviceId },
            sortBy: [SortDescriptor(\.cellNumber, order: .forward)]
        )
        let results = try context.fetch(descriptor)

        // Diagnostic: if predicate returned 0, check total count
        if results.isEmpty {
            let allDescriptor = FetchDescriptor<LogCellEntity>()
            let totalCount = try context.fetchCount(allDescriptor)
            if totalCount > 0 {
                // Data exists but predicate didn't match — log for debugging
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

    /// Get the highest cached cell number for a device, or -1 if empty.
    @MainActor
    static func maxCachedCellNumber(deviceId: String, context: ModelContext) throws -> Int {
        var descriptor = FetchDescriptor<LogCellEntity>(
            predicate: #Predicate { $0.deviceId == deviceId },
            sortBy: [SortDescriptor(\.cellNumber, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let results = try context.fetch(descriptor)
        let result = results.first?.cellNumber ?? -1
        logger.info("maxCachedCellNumber: device=\(deviceId) max=\(result)")
        return result
    }

    /// Get count of cached cells for a device.
    @MainActor
    static func cachedCellCount(deviceId: String, context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<LogCellEntity>(
            predicate: #Predicate { $0.deviceId == deviceId }
        )
        return try context.fetchCount(descriptor)
    }

    /// Delete all cached log cells for a device.
    @MainActor
    static func clearAllCells(deviceId: String, context: ModelContext) throws {
        let cells = try fetchAllCells(deviceId: deviceId, context: context)
        for cell in cells {
            context.delete(cell)
        }
        try context.save()
    }
}
