import Foundation
import Logging

public actor PassKit<P: PassKitPass> {
  
  public enum Error: Swift.Error {
    case notModified
    case fullPathToZipMissing
  }
  
  public let configuration: PassKitConfiguration<P>
  private let logger: Logger
  private let worker: PassGeneratorWorker<P>
  
  public init(
    configuration: PassKitConfiguration<P>,
    logger: Logger,
    workerCount: Int = 4
  ) {
    self.configuration = configuration
    self.logger = logger
    self.worker = PassGeneratorWorker<P>(
      logger: logger,
      configuration: configuration,
      encoder: JSONEncoder()
    )
  }
  
  public func execute(
    request: PassKitRequest<P>
  ) async throws -> PassKitResponse {
    logger.debug("Called latestVersionOfPass")
    
    guard FileManager.default.fileExists(atPath: self.configuration.zipBinary.unixPath) else {
      throw Error.fullPathToZipMissing
    }
    
    let ifModifiedSince: TimeInterval = {
      guard
        let header = request.headers["If-Modified-Since"],
        let ims = TimeInterval(header) else {
        return 0
      }
      return ims
    }()
    
    guard ifModifiedSince < request.pass.modified.timeIntervalSince1970 else {
      throw Error.notModified
    }
    
    let data = try await self.generatePassContent(for: request.pass)
    
    var headers = [String: String]()
    headers["Content-Type"] = "application/vnd.apple.pkpass"
    headers["Last-Modified"] = String(request.pass.modified.timeIntervalSince1970)
    headers["Content-Transfer-Encoding"] = "binary"
    
    return PassKitResponse(
      body: data,
      headers: headers
    )
  }
  
  private func generatePassContent(for pass: P) async throws -> Data {
    try await self.worker.submit(
      work: pass
    )
  }
}

public struct PassKitRequest<P: PassKitPass>: Sendable {
  public let pass: P
  public let headers: [String: String]
  
  public init(
    pass: P,
    headers: [String : String]
  ) {
    self.pass = pass
    self.headers = headers
  }
}

public struct PassKitResponse: Sendable {
  
  public let body: Data
  public let headers: [String: String]
  
  public init(
    body: Data,
    headers: [String : String]
  ) {
    self.headers = headers
    self.body = body
  }
}
