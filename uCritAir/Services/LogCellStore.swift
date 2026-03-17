import Foundation
@preconcurrency import SwiftData
import os.log

enum LogCellStore {

    private static let logger = Logger(subsystem: "com.ucritter.ucritair", category: "LogCellStore")

    @MainActor
    private static func fetchStoredCells(context: ModelContext) throws -> [LogCellEntity] {
        // SwiftData's predicate/sort macro expansions currently trigger Swift 6 Sendable
        // warnings for @Model key paths under targeted strict concurrency. Keep the store
        // query simple here and apply the small amount of device-specific filtering/sorting
        // in memory instead.
        try context.fetch(FetchDescriptor<LogCellEntity>())
    }

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

    @MainActor
    static func fetchAllCells(deviceId: String, context: ModelContext) throws -> [LogCellEntity] {
        let allCells = try fetchStoredCells(context: context)
        let results = allCells
            .filter { $0.deviceId == deviceId }
            .sorted { $0.cellNumber < $1.cellNumber }

        if results.isEmpty {
            let totalCount = allCells.count
            if totalCount > 0 {
                let sampleId = allCells.first?.deviceId ?? "nil"
                logger.error("fetchAllCells: 0 results for deviceId='\(deviceId)' but \(totalCount) total cells exist. First cell's deviceId='\(sampleId)'")
            } else {
                logger.info("fetchAllCells: 0 results — database is empty")
            }
        } else {
            logger.info("fetchAllCells: returning \(results.count) cells for device \(deviceId)")
        }

        return results
    }

    @MainActor
    static func maxCachedCellNumber(deviceId: String, context: ModelContext) throws -> Int {
        let results = try fetchAllCells(deviceId: deviceId, context: context)
        let result = results.last?.cellNumber ?? -1
        logger.info("maxCachedCellNumber: device=\(deviceId) max=\(result)")
        return result
    }

    @MainActor
    static func clearAllCells(deviceId: String, context: ModelContext) throws {
        let cells = try fetchAllCells(deviceId: deviceId, context: context)
        for cell in cells {
            context.delete(cell)
        }
        try context.save()
    }
}
