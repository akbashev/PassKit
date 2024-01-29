import Foundation
import Crypto
import Logging
import NIOCore
import NIOFoundationCompat

actor PassGeneratorWorker<P: PassKitPass>: Worker {

  let logger: Logger
  let configuration: PassKitConfiguration<P>
  let encoder: JSONEncoder
  
  init(
    logger: Logger,
    configuration: PassKitConfiguration<P>,
    encoder: JSONEncoder = .init()
  ) {
    self.logger = logger
    self.configuration = configuration
    self.encoder = encoder
  }
  
  func submit(work item: P) async throws -> Data {
    let tmp = FileManager.default.temporaryDirectory
    let root = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let zipFile = tmp.appendingPathComponent("\(UUID().uuidString).zip")
    
    let src = configuration.templateDirectory
    var isDir: ObjCBool = false
    
    guard
      src.hasDirectoryPath,
      FileManager.default.fileExists(atPath: src.unixPath, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw PassKitError.templateNotDirectory
    }
    
    defer {
      _ = try? FileManager.default.removeItem(at: root)
      _ = try? FileManager.default.removeItem(at: zipFile)
    }
    
    try FileManager.default.copyItem(at: src, to: root)
    let encoded = try await configuration.encode(item, encoder)
    try encoded.write(to: root.appendingPathComponent("pass.json"))
    
    try await injectFiles(for: item, to: root)
    
    try Self.generateManifestFile(using: encoder, in: root)
    try self.generateSignatureFile(in: root)
    
    try self.zip(directory: root, to: zipFile)

    return try Data(contentsOf: zipFile)
  }
  
  private func injectFiles(
    for item: P,
    to root: URL
  ) async throws {
    let files = try await self.configuration.inject(item)
    guard !files.isEmpty else { return }
    await withTaskGroup(of: Void.self) { group in
      for file in files {
        group.addTask {
          do {
            try file.data.write(
              to: root.appendingPathComponent(file.filename)
            )
          } catch {
            self.logger.error("\(error)")
          }
        }
        return await group.waitForAll()
      }
    }
  }
  
  // MARK: - pkpass file generation
  private static func generateManifestFile(using encoder: JSONEncoder, in root: URL) throws {
    var manifest: [String: String] = [:]
    
    let paths = try FileManager.default.subpathsOfDirectory(atPath: root.unixPath)
    try paths.forEach { relativePath in
      let file = URL(fileURLWithPath: relativePath, relativeTo: root)
      guard !file.hasDirectoryPath else {
        return
      }
      
      let data = try Data(contentsOf: file)
      let hash = Insecure.SHA1.hash(data: data)
      manifest[relativePath] = hash.hexEncodedString()
    }
    
    let encoded = try encoder.encode(manifest)
    try encoded.write(to: root.appendingPathComponent("manifest.json"))
  }
  
  private func generateSignatureFile(in root: URL) throws {
    if configuration.generateSignatureFile(root) {
      // If the caller's delegate generated a file we don't have to do it.
      return
    }
    
    let sslBinary = configuration.sslBinary
    
    guard FileManager.default.fileExists(atPath: sslBinary.unixPath) else {
      throw PassKitError.opensslBinaryMissing
    }
    
    let proc = Process()
    proc.currentDirectoryURL = configuration.sslSigningFilesDirectory
    proc.executableURL = sslBinary
    
    proc.arguments = [
      "smime", "-binary", "-sign",
      "-certfile", configuration.wwdrCertificate,
      "-signer", configuration.pemCertificate,
      "-inkey", configuration.pemPrivateKey,
      "-in", root.appendingPathComponent("manifest.json").unixPath,
      "-out", root.appendingPathComponent("signature").unixPath,
      "-outform", "DER"
    ]
    
    let pwd = configuration.pemPrivateKeyPassword
    proc.arguments!.append(contentsOf: ["-passin", "pass:\(pwd)"])
    
    try proc.run()
    
    proc.waitUntilExit()
  }
  
  private func zip(directory: URL, to: URL) throws {
    let zipBinary = configuration.zipBinary
    guard FileManager.default.fileExists(atPath: zipBinary.unixPath) else {
      throw PassKitError.zipBinaryMissing
    }
    
    let proc = Process()
    proc.currentDirectoryURL = directory
    proc.executableURL = zipBinary
    
    proc.arguments = [ to.unixPath, "-r", "-q", "." ]
    
    try proc.run()
    proc.waitUntilExit()
  }
}

extension ByteBuffer {
  var data: Data? {
    var body = self
    return body.readData(length: body.readableBytes)
  }
}

extension Sequence where Element == UInt8 {
  public var hex: String {
    self.hexEncodedString()
  }
  
  public func hexEncodedString(uppercase: Bool = false) -> String {
    return String(decoding: self.hexEncodedBytes(uppercase: uppercase), as: Unicode.UTF8.self)
  }
  
  public func hexEncodedBytes(uppercase: Bool = false) -> [UInt8] {
    let table: [UInt8] = uppercase ? radix16table_uppercase : radix16table_lowercase
    var result: [UInt8] = []
    
    result.reserveCapacity(self.underestimatedCount * 2) // best guess
    return self.reduce(into: result) { output, byte in
      output.append(table[numericCast(byte / 16)])
      output.append(table[numericCast(byte % 16)])
    }
  }
}

extension Collection where Element == UInt8 {
  public func hexEncodedBytes(uppercase: Bool = false) -> [UInt8] {
    let table: [UInt8] = uppercase ? radix16table_uppercase : radix16table_lowercase
    
    return .init(unsafeUninitializedCapacity: self.count * 2) { buffer, outCount in
      for byte in self {
        let nibs = byte.quotientAndRemainder(dividingBy: 16)
        
        buffer[outCount + 0] = table[numericCast(nibs.quotient)]
        buffer[outCount + 1] = table[numericCast(nibs.remainder)]
        outCount += 2
      }
    }
  }
}

fileprivate let radix16table_uppercase: [UInt8] = [
  0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46
]

fileprivate let radix16table_lowercase: [UInt8] = [
  0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66
]
