//
//  LineFramer.swift
//  MudClient
//
//  xirr_line_framer_basic: the dclient 1.105 RPC wire codec.
//  10-byte header (payload_size u32 LE, payload_crc32 u32 LE, header_checksum u16 LE) + payload.
//

import Foundation

enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

struct LineFramer: Sendable {
    enum FrameError: Error, Equatable {
        case sizeExceedsMax(UInt32)
        case headerChecksumMismatch
        case payloadCrcMismatch
    }

    static let maxPayloadSize: UInt32 = 4_000_000
    static let headerSize = 10

    private var buffer = Data()

    static func encode(_ payload: Data) -> Data {
        var header = Data(capacity: headerSize)
        var size = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
        var payloadCrc = CRC32.checksum(payload).littleEndian
        withUnsafeBytes(of: &payloadCrc) { header.append(contentsOf: $0) }
        var checksum = UInt16(truncatingIfNeeded: CRC32.checksum(header)).littleEndian
        withUnsafeBytes(of: &checksum) { header.append(contentsOf: $0) }
        return header + payload
    }

    mutating func push(_ bytes: some Sequence<UInt8>) throws -> [Data] {
        buffer.append(contentsOf: bytes)

        var payloads: [Data] = []
        while true {
            guard buffer.count >= Self.headerSize else { break }

            let start = buffer.startIndex
            let headerBytes = buffer.subdata(in: start..<(start + Self.headerSize))

            let payloadSize = headerBytes[headerBytes.startIndex..<(headerBytes.startIndex + 4)]
                .withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            let payloadCrcExpected = headerBytes[(headerBytes.startIndex + 4)..<(headerBytes.startIndex + 8)]
                .withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            let headerChecksumExpected = headerBytes[(headerBytes.startIndex + 8)..<(headerBytes.startIndex + 10)]
                .withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian

            guard payloadSize <= Self.maxPayloadSize else {
                throw FrameError.sizeExceedsMax(payloadSize)
            }

            let headerChecksumActual = UInt16(truncatingIfNeeded: CRC32.checksum(headerBytes.prefix(8)))
            guard headerChecksumActual == headerChecksumExpected else {
                throw FrameError.headerChecksumMismatch
            }

            let frameTotal = Self.headerSize + Int(payloadSize)
            guard buffer.count >= frameTotal else { break }

            let payloadStart = start + Self.headerSize
            let payload = buffer.subdata(in: payloadStart..<(payloadStart + Int(payloadSize)))

            guard CRC32.checksum(payload) == payloadCrcExpected else {
                throw FrameError.payloadCrcMismatch
            }

            payloads.append(payload)
            buffer.removeSubrange(start..<(payloadStart + Int(payloadSize)))
        }

        return payloads
    }
}
