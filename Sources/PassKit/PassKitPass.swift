import Foundation

public protocol PassKitPass: Encodable, Sendable {

  /// The pass type
  var type: String { get }
  
  /// The last time the pass was modified.
  var modified: Date { get }
}
