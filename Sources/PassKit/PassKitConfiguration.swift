import Foundation

public struct PassKitConfiguration<P: PassKitPass>: Sendable {
  
  let inject: @Sendable (_ pass: P) async throws -> [PassKitInject]

  /// Should return a `URL` which points to the template data for the pass.
  ///
  /// The URL should point to a directory containing all the images and
  /// localizations for the generated pkpass archive but should *not* contain any of these items:
  ///  - manifest.json
  ///  - pass.json
  ///  - signature
  /// - Parameters:
  ///   - pass: The pass data from the SQL server.
  ///   - db: The SQL database to query against.
  ///
  /// ### Note ###
  /// Be sure to use the `URL(fileURLWithPath:isDirectory:)` constructor.
  let templateDirectory:  URL
  
  /// Generates the SSL `signature` file.
  ///
  /// If you need to implement custom S/Mime signing you can use this
  /// method to do so.  You must generate a detached DER signature of the
  /// `manifest.json` file.
  /// - Parameter root: The location of the `manifest.json` and where to write the `signature` to.
  /// - Returns: Return `true` if you generated a custom `signature`, otherwise `false`.
  let generateSignatureFile: @Sendable (_ root: URL) -> Bool
  
  /// Encode the pass into JSON.
  ///
  /// This method should generate the entire pass JSON. You are provided with
  /// the pass data from the SQL database and you should return a properly
  /// formatted pass file encoding.
  /// - Parameters:
  ///   - pass: The pass data from the SQL server
  ///   - db: The SQL database to query against.
  ///   - encoder: The `JSONEncoder` which you should use.
  /// - See: [Understanding the Keys](https://developer.apple.com/library/archive/documentation/UserExperience/Reference/PassKit_Bundle/Chapters/Introduction.html)
  let encode: @Sendable (_ pass: P, _ encoder: JSONEncoder) async throws -> Data
  
  /// Should return a `URL` which points to the template data for the pass.
  ///
  /// The URL should point to a directory containing the files specified by these keys:
  /// - wwdrCertificate
  /// - pemCertificate
  /// - pemPrivateKey
  ///
  /// ### Note ###
  /// Be sure to use the `URL(fileURLWithPath:isDirectory:)` initializer!
  let sslSigningFilesDirectory: URL
  
  /// The location of the `openssl` command as a file URL.
  /// - Note: Be sure to use the `URL(fileURLWithPath:)` constructor.
  let sslBinary: URL
  
  /// The full path to the `zip` command as a file URL.
  /// - Note: Be sure to use the `URL(fileURLWithPath:)` constructor.
  let zipBinary: URL
  
  /// The name of Apple's WWDR.pem certificate as contained in `sslSigningFiles` path.
  ///
  /// Defaults to `WWDR.pem`
  let wwdrCertificate: String
  
  /// The name of the PEM Certificate for signing the pass as contained in `sslSigningFiles` path.
  ///
  /// Defaults to `passcertificate.pem`
  let pemCertificate: String
  
  /// The name of the PEM Certificate's private key for signing the pass as contained in `sslSigningFiles` path.
  ///
  /// Defaults to `passkey.pkey`
  let pemPrivateKey: String
  
  /// The password to the private key file.
  let pemPrivateKeyPassword: String
  
  public init(
    templateDirectory: URL,
    generateSignatureFile: @escaping @Sendable (_: URL) -> Bool = { _ in false },
    encode: @escaping @Sendable (_: P, _: JSONEncoder) async throws -> Data,
    inject: @escaping @Sendable (_: P) async throws -> [PassKitInject] = { _ in [] },
    sslSigningFilesDirectory: URL,
    sslBinary: URL = URL(fileURLWithPath: "/usr/bin/openssl"),
    zipBinary: URL = URL(fileURLWithPath: "/usr/bin/zip"),
    wwdrCertificate: String = "WWDR.pem",
    pemCertificate: String = "passcertificate.pem",
    pemPrivateKey: String = "passkey.pkey",
    pemPrivateKeyPassword: String
  ) {
    self.templateDirectory = templateDirectory
    self.generateSignatureFile = generateSignatureFile
    self.encode = encode
    self.inject = inject
    self.sslSigningFilesDirectory = sslSigningFilesDirectory
    self.sslBinary = sslBinary
    self.zipBinary = zipBinary
    self.wwdrCertificate = wwdrCertificate
    self.pemCertificate = pemCertificate
    self.pemPrivateKey = pemPrivateKey
    self.pemPrivateKeyPassword = pemPrivateKeyPassword
  }
}
