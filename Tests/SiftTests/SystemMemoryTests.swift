import Darwin
import XCTest
@testable import Sift

final class SystemMemoryTests: XCTestCase {
    func testRAMUsesMemoryUnitsRatherThanDiskUnits() {
        XCTAssertEqual(MemoryFormatting.string(64 * 1_024 * 1_024 * 1_024), "64 GB")
    }
    func testUsageIncludesAnonymousWiredAndPhysicalCompressedPagesOnly() throws {
        var statistics = vm_statistics64_data_t()
        statistics.internal_page_count = 100
        statistics.purgeable_count = 20
        statistics.wire_count = 30
        statistics.compressor_page_count = 10
        statistics.external_page_count = 500
        statistics.total_uncompressed_pages_in_compressor = 1_000
        let usage = try XCTUnwrap(SystemMemoryUsage.calculate(statistics, pageSize: 16_384, physicalBytes: 1_000 * 16_384))
        XCTAssertEqual(usage.usedBytes, 120 * 16_384)
        XCTAssertEqual(usage.availableBytes, 880 * 16_384)
        XCTAssertEqual(usage.usedFraction, 0.12, accuracy: 0.0001)
    }

    func testUsageClampsRacingCountersAndRejectsInvalidInputs() throws {
        var statistics = vm_statistics64_data_t()
        statistics.internal_page_count = 5
        statistics.purgeable_count = 10
        statistics.wire_count = 20
        let usage = try XCTUnwrap(SystemMemoryUsage.calculate(statistics, pageSize: 4_096, physicalBytes: 10 * 4_096))
        XCTAssertEqual(usage.usedFraction, 1)
        XCTAssertEqual(usage.availableBytes, 0)
        XCTAssertNil(SystemMemoryUsage.calculate(statistics, pageSize: 0, physicalBytes: 10))
        XCTAssertNil(SystemMemoryUsage.calculate(statistics, pageSize: 1, physicalBytes: 0))
        XCTAssertNil(SystemMemoryUsage.calculate(statistics, pageSize: UInt64.max, physicalBytes: 10))
    }

    func testLiveSystemUsageIsBoundedByPhysicalRAM() throws {
        let usage = try XCTUnwrap(MemoryService.systemUsage())
        XCTAssertEqual(usage.totalBytes, Int64(ProcessInfo.processInfo.physicalMemory))
        XCTAssertGreaterThan(usage.usedBytes, 0)
        XCTAssertLessThanOrEqual(usage.usedBytes, usage.totalBytes)
    }
}
