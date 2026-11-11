import CLibVLC
import Foundation
import Synchronization

/// A byte source that libVLC reads media from instead of opening a URL itself.
///
/// Conform to this to feed libVLC from something it cannot open directly, or
/// from a source where *how* the bytes are read matters. A typical case is a
/// network file system that is mounted locally: libVLC's own `file` access
/// reads it in small blocks with the operating system's read-ahead turned
/// off, which is slow when every request costs a network round trip. A custom
/// stream can read large blocks and keep its own read-ahead.
///
/// libVLC calls a stream from one thread at a time and may move it between
/// threads, so a conforming type can keep unsynchronized mutable state if it
/// declares `@unchecked Sendable`. The stream is closed by releasing it:
/// release resources in `deinit`.
///
/// ```swift
/// final class FileStream: MediaByteStream, @unchecked Sendable {
///   private let handle: FileHandle
///   let length: UInt64?
///   init(url: URL) throws { /* open, measure */ }
///   func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { /* ... */ }
///   func seek(to offset: UInt64) throws { /* ... */ }
/// }
/// let media = try Media(streamFactory: { try FileStream(url: url) })
/// ```
public protocol MediaByteStream: AnyObject, Sendable {
  /// Total length in bytes, or `nil` if unknown.
  ///
  /// Demuxers use it to find data at the end of a file (an MP4 `moov` box,
  /// for example), so report it whenever it is known.
  var length: UInt64? { get }

  /// Reads up to `buffer.count` bytes into `buffer`.
  ///
  /// - Returns: The number of bytes read, which must be greater than zero
  ///   unless the end of the stream is reached, in which case `0`. Blocking
  ///   until data is available is allowed.
  /// - Throws: Any error. libVLC treats it as a non-recoverable read failure.
  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int

  /// Moves the read position to an absolute byte offset.
  /// - Throws: Any error. libVLC treats it as a failed seek.
  func seek(to offset: UInt64) throws
}

/// Stream factories keyed by the integer libVLC carries as the opaque pointer of
/// a stream media. A factory is registered when the media is created and removed
/// by libVLC's release callback, which runs when the native media is freed, so
/// the open callback always finds it while libVLC can still call it.
enum MediaStreamFactories {
  typealias Factory = @Sendable () throws -> any MediaByteStream

  private struct Table {
    var nextKey: UInt = 1
    var factories: [UInt: Factory] = [:]
  }

  private static let table = Mutex(Table())

  static func register(_ factory: @escaping Factory) -> UInt {
    table.withLock { table in
      let key = table.nextKey
      table.nextKey += 1
      table.factories[key] = factory
      return key
    }
  }

  static func unregister(_ key: UInt) {
    _ = table.withLock { $0.factories.removeValue(forKey: key) }
  }

  static func factory(forKey key: UInt) -> Factory? {
    table.withLock { $0.factories[key] }
  }
}

/// The retained object behind the `void *` that libVLC hands to the read,
/// seek and close callbacks of one opened stream.
private final class OpenedStream {
  let stream: any MediaByteStream
  init(_ stream: any MediaByteStream) {
    self.stream = stream
  }
}

// MARK: - C callbacks

private func mediaStreamOpen(
  _ opaque: UnsafeMutableRawPointer?,
  _ datap: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
  _ sizep: UnsafeMutablePointer<UInt64>?
) -> Int32 {
  guard
    let opaque,
    let datap,
    let sizep,
    let factory = MediaStreamFactories.factory(forKey: UInt(bitPattern: opaque))
  else { return -1 }
  guard let stream = try? factory() else { return -1 }
  datap.pointee = Unmanaged.passRetained(OpenedStream(stream)).toOpaque()
  sizep.pointee = stream.length ?? UInt64.max
  return 0
}

private func mediaStreamRead(
  _ opaque: UnsafeMutableRawPointer?,
  _ buffer: UnsafeMutablePointer<UInt8>?,
  _ length: Int
) -> Int {
  guard let opaque, let buffer else { return -1 }
  guard length > 0 else { return 0 }
  let opened = Unmanaged<OpenedStream>.fromOpaque(opaque).takeUnretainedValue()
  do {
    let count = try opened.stream.read(
      into: UnsafeMutableRawBufferPointer(start: buffer, count: length)
    )
    // libVLC trusts the count, so a stream that reports more than it was asked
    // for would make libVLC read or write past its buffer.
    guard (0...length).contains(count) else { return -1 }
    return count
  } catch {
    return -1
  }
}

private func mediaStreamSeek(_ opaque: UnsafeMutableRawPointer?, _ offset: UInt64) -> Int32 {
  guard let opaque else { return -1 }
  let opened = Unmanaged<OpenedStream>.fromOpaque(opaque).takeUnretainedValue()
  do {
    try opened.stream.seek(to: offset)
    return 0
  } catch {
    return -1
  }
}

private func mediaStreamRelease(_ opaque: UnsafeMutableRawPointer?) {
  guard let opaque else { return }
  MediaStreamFactories.unregister(UInt(bitPattern: opaque))
}

private func mediaStreamClose(_ opaque: UnsafeMutableRawPointer?) {
  guard let opaque else { return }
  Unmanaged<OpenedStream>.fromOpaque(opaque).release()
}

extension Media {
  /// Whether this media reads through a ``MediaByteStream``. libVLC keeps the
  /// locator it was created with, which is `imem://` for callback media.
  var isStreamBacked: Bool {
    mrl == "imem://"
  }

  /// Creates media that libVLC reads through a ``MediaByteStream``.
  ///
  /// `streamFactory` runs each time libVLC opens the media (for playback and
  /// again for any later replay), on a libVLC thread. Return a fresh stream
  /// positioned at offset zero, or throw to make the open fail.
  ///
  /// libVLC does not look for sidecar files (external subtitles) next to a
  /// media it cannot locate by path. Add them with the player's subtitle API.
  ///
  /// - Parameters:
  ///   - streamFactory: Opens the byte source.
  ///   - isSeekable: Pass `false` for a stream whose ``MediaByteStream/seek(to:)``
  ///     is unsupported, so libVLC does not try to use it.
  /// - Throws: ``VLCError/mediaCreationFailed(source:)`` if libVLC cannot
  ///   create the media.
  public convenience init(
    streamFactory: @escaping @Sendable () throws -> any MediaByteStream,
    isSeekable: Bool = true
  )
    throws(VLCError) {
    guard swiftvlc_libvlc_pip_extensions_version() >= 13 else {
      throw .mediaCreationFailed(source: "stream: engine lacks the release callback")
    }
    let key = MediaStreamFactories.register(streamFactory)
    guard
      let media = libvlc_media_new_callbacks_with_release(
        mediaStreamOpen,
        mediaStreamRead,
        isSeekable ? mediaStreamSeek : nil,
        mediaStreamClose,
        UnsafeMutableRawPointer(bitPattern: key),
        mediaStreamRelease
      )
    else {
      MediaStreamFactories.unregister(key)
      throw .mediaCreationFailed(source: "stream")
    }
    self.init(retaining: media)
  }
}
