import Foundation
import Testing

@testable import MudClient

@Test func crc32MatchesKnownVector() {
  #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF43926)
}

@Test func lineFramerRoundTripsAPayload() throws {
  let payload = Data("hello, xirr".utf8)
  let frame = LineFramer.encode(payload)

  var framer = LineFramer()
  let decoded = try framer.push(frame)
  #expect(decoded == [payload])
}

@Test func lineFramerRoundTripsEmptyPayload() throws {
  let payload = Data()
  let frame = LineFramer.encode(payload)

  var framer = LineFramer()
  let decoded = try framer.push(frame)
  #expect(decoded == [payload])
}

@Test func lineFramerDecodesFrameSplitByteByByte() throws {
  let payload = Data("streamed byte at a time".utf8)
  let frame = LineFramer.encode(payload)

  var framer = LineFramer()
  var decoded: [Data] = []
  for byte in frame {
    decoded += try framer.push([byte])
  }
  #expect(decoded == [payload])
}

@Test func lineFramerDecodesFrameSplitAtArbitraryBoundary() throws {
  let payload = Data("arbitrary boundary split payload".utf8)
  let frame = LineFramer.encode(payload)
  let splitPoint = frame.count / 3

  var framer = LineFramer()
  var decoded = try framer.push(frame.prefix(splitPoint))
  #expect(decoded.isEmpty)
  decoded += try framer.push(frame.suffix(from: splitPoint))
  #expect(decoded == [payload])
}

@Test func lineFramerDecodesTwoFramesInOnePush() throws {
  let first = Data("first payload".utf8)
  let second = Data("second payload".utf8)
  let combined = LineFramer.encode(first) + LineFramer.encode(second)

  var framer = LineFramer()
  let decoded = try framer.push(combined)
  #expect(decoded == [first, second])
}

@Test func lineFramerBuffersTrailingPartialFrame() throws {
  let first = Data("complete payload".utf8)
  let second = Data("partial next payload".utf8)
  var combined = LineFramer.encode(first)
  combined.append(LineFramer.encode(second).prefix(5))

  var framer = LineFramer()
  let decoded = try framer.push(combined)
  #expect(decoded == [first])

  // Finish feeding the second frame; it should now decode from the buffered remainder.
  let secondFrame = LineFramer.encode(second)
  var framer2 = LineFramer()
  let firstDecoded = try framer2.push(LineFramer.encode(first) + secondFrame.prefix(5))
  #expect(firstDecoded == [first])
  let rest = try framer2.push(secondFrame.suffix(from: 5))
  #expect(rest == [second])
}

@Test func lineFramerThrowsOnCorruptedPayload() throws {
  let payload = Data("corrupt me".utf8)
  var frame = LineFramer.encode(payload)
  frame[frame.count - 1] ^= 0xFF // flip a payload byte

  var framer = LineFramer()
  #expect(throws: LineFramer.FrameError.payloadCrcMismatch) {
    _ = try framer.push(frame)
  }
}

@Test func lineFramerThrowsOnCorruptedHeader() throws {
  let payload = Data("corrupt my header".utf8)
  var frame = LineFramer.encode(payload)
  frame[0] ^= 0xFF // flip a header byte (payload_size), invalidating header_checksum

  var framer = LineFramer()
  #expect(throws: LineFramer.FrameError.headerChecksumMismatch) {
    _ = try framer.push(frame)
  }
}

@Test func lineFramerThrowsOnOversizedPayload() throws {
  var header = Data(capacity: 10)
  var size = (LineFramer.maxPayloadSize + 1).littleEndian
  withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
  var payloadCrc = UInt32(0).littleEndian
  withUnsafeBytes(of: &payloadCrc) { header.append(contentsOf: $0) }
  var checksum = UInt16(truncatingIfNeeded: CRC32.checksum(header)).littleEndian
  withUnsafeBytes(of: &checksum) { header.append(contentsOf: $0) }

  var framer = LineFramer()
  #expect(throws: LineFramer.FrameError.sizeExceedsMax(LineFramer.maxPayloadSize + 1)) {
    _ = try framer.push(header)
  }
}
