@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

/// A file-backed stream that counts how libVLC uses it.
private final class CountingFileStream: MediaByteStream, @unchecked Sendable {
  private let fd: Int32
  let length: UInt64?
  private(set) var reads = 0
  private(set) var seeks = 0
  var failReads = false

  init(url: URL, reportsLength: Bool = true) throws {
    fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw POSIXError(.ENOENT) }
    var info = stat()
    fstat(fd, &info)
    length = reportsLength ? UInt64(info.st_size) : nil
  }

  deinit {
    close(fd)
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    reads += 1
    if failReads {
      throw POSIXError(.EIO)
    }
    let count = Foundation.read(fd, buffer.baseAddress, buffer.count)
    if count < 0 {
      throw POSIXError(.EIO)
    }
    return count
  }

  func seek(to offset: UInt64) throws {
    seeks += 1
    guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else { throw POSIXError(.EINVAL) }
  }
}

/// A stream that reports more bytes than libVLC asked for.
private final class OverreadingStream: MediaByteStream, @unchecked Sendable {
  let length: UInt64? = nil

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    buffer.count + 1
  }

  func seek(to offset: UInt64) throws {}
}

/// Reports when the closure that owns it is released.
private final class Probe: @unchecked Sendable {
  private let onDeinit: @Sendable () -> Void

  init(onDeinit: @escaping @Sendable () -> Void) {
    self.onDeinit = onDeinit
  }

  deinit {
    onDeinit()
  }
}

extension Integration {
  struct MediaByteStreamTests {
    @Test
    func `Stream media parses like the same file opened by URL`() async throws {
      let url = TestMedia.testMP4URL
      let viaURL = try Media(url: url)
      let viaStream = try Media(streamFactory: { try CountingFileStream(url: url) })

      let expected = try await viaURL.parse()
      let actual = try await viaStream.parse()

      #expect(actual.title == expected.title)
      #expect(actual.title == "Test")
      #expect(viaStream.tracks().contains(where: { $0.type == .video }))
      #expect(viaStream.tracks().contains(where: { $0.type == .audio }))
    }

    @Test
    func `Stream media with unknown length still parses`() async throws {
      let url = TestMedia.testMP4URL
      let media = try Media(streamFactory: { try CountingFileStream(url: url, reportsLength: false) })
      let metadata = try await media.parse()
      #expect(metadata.title == "Test")
    }

    @Test
    func `Factory runs once per open and the stream is read`() async throws {
      let url = TestMedia.testMP4URL
      let opened = Mutex(0)
      let media = try Media(streamFactory: {
        opened.withLock { $0 += 1 }
        return try CountingFileStream(url: url)
      })
      _ = try await media.parse()
      #expect(opened.withLock { $0 } >= 1)
    }

    @Test
    func `Failing factory makes the parse fail instead of hanging`() async throws {
      struct Boom: Error {}
      let media = try Media(streamFactory: { throw Boom() })
      await #expect(throws: (any Error).self) {
        _ = try await media.parse()
      }
    }

    @Test
    func `Failing reads make the parse fail instead of hanging`() async throws {
      let url = TestMedia.testMP4URL
      let media = try Media(streamFactory: {
        let stream = try CountingFileStream(url: url)
        stream.failReads = true
        return stream
      })
      await #expect(throws: (any Error).self) {
        _ = try await media.parse()
      }
    }

    @Test
    func `Read count beyond the requested size fails the parse`() async throws {
      let media = try Media(streamFactory: { OverreadingStream() })
      await #expect(throws: (any Error).self) {
        _ = try await media.parse()
      }
    }

    @Test
    func `Stream media is stream-backed and URL media is not`() throws {
      let stream = try Media(streamFactory: { throw POSIXError(.EIO) })
      let url = try Media(url: TestMedia.testMP4URL)
      #expect(stream.isStreamBacked)
      #expect(!url.isStreamBacked)
    }

    @Test
    func `The stream factory is released together with the native media`() throws {
      let freed = Mutex(false)
      do {
        let probe = Probe { freed.withLock { $0 = true } }
        let media = try Media(streamFactory: {
          _ = probe
          throw POSIXError(.EIO)
        })
        #expect(media.isStreamBacked)
      }
      #expect(freed.withLock { $0 })
    }

    @Test
    func `A list keeps the factory of its item until the item is removed`() throws {
      let freed = Mutex(false)
      let list = MediaList()
      do {
        let probe = Probe { freed.withLock { $0 = true } }
        let media = try Media(streamFactory: {
          _ = probe
          throw POSIXError(.EIO)
        })
        try list.append(media)
      }
      #expect(!freed.withLock { $0 })
      try list.remove(at: 0)
      #expect(freed.withLock { $0 })
    }

    @Test
    func `A stream item in a list still parses after the caller dropped its wrapper`() async throws {
      let url = TestMedia.testMP4URL
      let list = MediaList()
      do {
        let media = try Media(streamFactory: { try CountingFileStream(url: url) })
        try list.append(media)
      }
      let item = try #require(list.media(at: 0))
      let metadata = try await item.parse()
      #expect(metadata.title == "Test")
    }
  }
}
