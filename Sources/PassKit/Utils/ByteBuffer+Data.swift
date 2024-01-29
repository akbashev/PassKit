import Foundation
import NIOCore
import NIOFoundationCompat

extension ByteBuffer {
  var data: Data? {
    var body = self
    return body.readData(length: body.readableBytes)
  }
}
