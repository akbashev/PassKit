import Foundation

extension URL {
  var unixPath: String {
    self.absoluteString.replacingOccurrences(of: "file://", with: "")
  }
}
