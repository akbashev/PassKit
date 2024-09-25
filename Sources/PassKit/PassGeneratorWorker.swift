import Foundation
import Crypto
import Logging

actor PassGeneratorWorker<P: PassKitPass> {

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
    
    defer {
      _ = try? FileManager.default.removeItem(at: root)
      _ = try? FileManager.default.removeItem(at: zipFile)
    }
    
    let src = configuration.templateDirectory
    var isDir: ObjCBool = false
    
    guard
      src.hasDirectoryPath,
      FileManager.default.fileExists(atPath: src.unixPath, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw PassKitError.templateNotDirectory
    }
    

    try FileManager.default.copyItem(at: src, to: root)
    let encoded = try await configuration.encode(item, encoder)
    try encoded.write(to: root.appendingPathComponent("pass.json"))
    
    try await self.injectFiles(for: item, to: root)
    
    try Self.generateManifestFile(using: encoder, in: root)
    try self.generateSignatureFile(in: root)
    
    try self.zip(directory: root, to: zipFile)

    return try Data(contentsOf: zipFile)
  }
  
  private func injectFiles(
    for item: P,
    to root: URL
  ) async throws {
    let files = await self.configuration.inject(item)
    guard !files.isEmpty else { return }
    await withTaskGroup(of: Void.self) { group in
      for file in files {
        group.addTask { [logger] in
          do {
            try file.data.write(
              to: root.appendingPathComponent(file.filename)
            )
          } catch {
            logger.error("\(error)")
          }
        }
      }
      return await group.waitForAll()
    }
  }
  
  // MARK: - pkpass file generation
  private static func generateManifestFile(using encoder: JSONEncoder, in root: URL) throws {
    let paths = try FileManager.default.subpathsOfDirectory(atPath: root.unixPath)
    let manifest = try paths.reduce(into: [String:String]()) { partial, relativePath in
      let file = URL(fileURLWithPath: relativePath, relativeTo: root)
      guard !file.hasDirectoryPath else {
        return
      }
      let data = try Data(contentsOf: file)
      let hash = Insecure.SHA1.hash(data: data)
      partial[relativePath] = hash.hexEncodedString()
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
