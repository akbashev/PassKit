import Foundation

public struct PassKitInject: Sendable {
  /// Data to inject into the pass json
  public let data: Data
  
  /// Desired filename for data to be represented
  public let filename: String
  
  public init(
    data: Data,
    filename: String
  ) {
    self.data = data
    self.filename = filename
  }
}
