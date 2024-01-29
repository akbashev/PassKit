import Foundation
import Logging

public actor PassKit<P: PassKitPass> {
  
  public enum Error: Swift.Error {
    case notModified
    case fullPathToZipMissing
  }
  
  public let configuration: PassKitConfiguration<P>
  private let encoder: JSONEncoder
  private let logger: Logger
  private let pool: WorkerPool<PassGeneratorWorker<P>>
  
  public init(
    configuration: PassKitConfiguration<P>,
    logger: Logger,
    workerCount: Int = 4
  ) {
    self.configuration = configuration
    self.encoder = JSONEncoder()
    self.logger = logger
    self.pool = .init(
      logger: logger,
      workers: Array(
        repeating: PassGeneratorWorker<P>(
          logger: logger,
          configuration: configuration,
          encoder: self.encoder
        ),
        count: workerCount
      )
    )
  }
  
  public struct Request: Sendable {
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
  
  public struct Response: Sendable {
    public let headers: [String: String]
    public let body: Data
    
    public init(headers: [String : String], body: Data) {
      self.headers = headers
      self.body = body
    }
  }
    
  public func execute(
    request: Request
  ) async throws -> Response {
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
    
    return Response(
      headers: headers,
      body: data
    )
  }
  
  private func generatePassContent(for pass: P) async throws -> Data {
    try await pool.submit(
      work: pass
    )
  }
}
