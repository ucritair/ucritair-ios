import Foundation

enum CSVExporter {

    static let header = [
        "cell_number", "timestamp", "datetime", "flags",
        "temperature_C", "pressure_hPa", "humidity_pct",
        "co2_ppm", "co2_uncomp_ppm",
        "pm1_0", "pm2_5", "pm4_0", "pm10",
        "pn0_5", "pn1_0", "pn2_5", "pn4_0", "pn10",
        "voc_index", "nox_index",
        "stroop_cong_ms", "stroop_incong_ms", "stroop_throughput",
    ].joined(separator: ",")

    static func toCSV(_ cells: [LogCellEntity]) -> String {
        var lines = [header]
        let isoFormatter = ISO8601DateFormatter()

        for c in cells {
            let datetime = isoFormatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(c.timestamp))
            )
            let row = [
                "\(c.cellNumber)",
                "\(c.timestamp)",
                datetime,
                String(format: "0x%02X", c.flags),
                String(format: "%.3f", c.temperature),
                String(format: "%.1f", c.pressure),
                String(format: "%.2f", c.humidity),
                "\(c.co2)",
                "\(c.co2Uncomp)",
                String(format: "%.2f", c.pm1_0),
                String(format: "%.2f", c.pm2_5),
                String(format: "%.2f", c.pm4_0),
                String(format: "%.2f", c.pm10),
                String(format: "%.2f", c.pn0_5),
                String(format: "%.2f", c.pn1_0),
                String(format: "%.2f", c.pn2_5),
                String(format: "%.2f", c.pn4_0),
                String(format: "%.2f", c.pn10),
                "\(c.voc)",
                "\(c.nox)",
                String(format: "%.3f", c.stroopMeanCong),
                String(format: "%.3f", c.stroopMeanIncong),
                "\(c.stroopThroughput)",
            ].joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    static func writeTemporaryFile(_ csv: String) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "ucrit-logs-\(timestamp)-\(UUID().uuidString).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
