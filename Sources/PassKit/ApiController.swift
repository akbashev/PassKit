/// Copyright 2020 Gargoyle Software, LLC
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
///
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import Fluent
import FluentKit
import Vapor
import ZIPFoundation
import APNS
import Logging

// https://developer.apple.com/library/archive/documentation/PassKit/Reference/PassKit_WebService/WebService.html
// https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/Updating.html
// https://developer.apple.com/library/archive/documentation/UserExperience/Reference/PassKit_Bundle/Chapters/Introduction.html
internal struct ApiController<P, D, R: PassKitRegistration, E: PassKitErrorLog> where P == R.PassType, D == R.DeviceType {
    unowned var delegate: PassKitDelegate
    private var logger: Logger?

    init(delegate: PassKitDelegate, logger: Logger? = nil) {
        self.delegate = delegate
        self.logger = logger
    }

    func registerDevice(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        logger?.debug("Called register device")

        guard let serial = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let pushToken: String
        do {
            let content = try req.content.decode(RegistrationDto.self)
            pushToken = content.pushToken
        } catch {
            throw Abort(.badRequest)
        }

        let type = req.parameters.get("type")!
        let deviceLibraryIdentifier = req.parameters.get("deviceLibraryIdentifier")!

        return P.query(on: req.db)
            .filter(\._$type == type)
            .filter(\._$id == serial)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap { pass in
                D.query(on: req.db)
                    .filter(\._$deviceLibraryIdentifier == deviceLibraryIdentifier)
                    .filter(\._$pushToken == pushToken)
                    .first()
                    .flatMap { device in
                        if let device = device {
                            return self.createRegistration(device: device, pass: pass, req: req)
                        } else {
                            let newDevice = D(deviceLibraryIdentifier: deviceLibraryIdentifier, pushToken: pushToken)

                            return newDevice
                                .create(on: req.db)
                                .flatMap { _ in self.createRegistration(device: newDevice, pass: pass, req: req) }
                        }
                }
        }
    }

    func passesForDevice(req: Request) throws -> EventLoopFuture<PassesForDeviceDto> {
        logger?.debug("Called passesForDevice")

        let type = req.parameters.get("type")!
        let deviceLibraryIdentifier = req.parameters.get("deviceLibraryIdentifier")!

        var query = R.for(deviceLibraryIdentifier: deviceLibraryIdentifier, passTypeIdentifier: type, on: req.db)

        if let since: TimeInterval = req.query["passesUpdatedSince"] {
            let when = Date(timeIntervalSince1970: since)
            query = query.filter(P.self, \._$modified > when)
        }

        return query
            .all()
            .flatMapThrowing { registrations in
                guard !registrations.isEmpty else {
                    throw Abort(.noContent)
                }

                var serialNumbers: [String] = []
                var maxDate = Date.distantPast

                registrations.forEach { r in
                    let pass = r.pass

                    serialNumbers.append(pass.id!.uuidString)
                    if pass.modified > maxDate {
                        maxDate = pass.modified
                    }
                }

                return PassesForDeviceDto(with: serialNumbers, maxDate: maxDate)
        }
    }

    func latestVersionOfPass(req: Request) throws -> EventLoopFuture<Response> {
        logger?.debug("Called latestVersionOfPass")

        var ifModifiedSince: TimeInterval = 0

        if let header = req.headers[.ifModifiedSince].first, let ims = TimeInterval(header) {
            ifModifiedSince = ims
        }

        guard let type = req.parameters.get("type"),
            let id = req.parameters.get("passSerial", as: UUID.self) else {
                throw Abort(.badRequest)
        }

        return P.query(on: req.db)
            .filter(\._$id == id)
            .filter(\._$type == type)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap { pass in
                guard ifModifiedSince < pass.modified.timeIntervalSince1970 else {
                    return req.eventLoop.makeFailedFuture(Abort(.notModified))
                }

                return self.generatePassContent(for: pass, on: req.db)
                    .map { data in
                        let body = Response.Body(data: data)

                        var headers = HTTPHeaders()
                        headers.add(name: .contentType, value: "application/vnd.apple.pkpass")
                        headers.add(name: .lastModified, value: String(pass.modified.timeIntervalSince1970))
                        headers.add(name: .contentTransferEncoding, value: "binary")

                        return Response(status: .ok, headers: headers, body: body)
                }
        }
    }

    func unregisterDevice(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        logger?.debug("Called unregisterDevice")

        let type = req.parameters.get("type")!

        guard let passId = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let deviceLibraryIdentifier = req.parameters.get("deviceLibraryIdentifier")!

        return R.for(deviceLibraryIdentifier: deviceLibraryIdentifier, passTypeIdentifier: type, on: req.db)
            .filter(P.self, \._$id == passId)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap { $0.delete(on: req.db).map { .ok } }
    }

    func logError(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        logger?.debug("Called logError")

        let body: ErrorLogDto

        do {
            body = try req.content.decode(ErrorLogDto.self)
        } catch {
            throw Abort(.badRequest)
        }

        guard body.logs.isEmpty == false else {
            throw Abort(.badRequest)
        }

        return body.logs
            .map { E(message: $0).create(on: req.db) }
            .flatten(on: req.eventLoop)
            .map { .ok }
    }

    func pushUpdatesForPass(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        logger?.debug("Called pushUpdatesForPass")

        return try registrationsForPush(req: req)
            .flatMap {
                $0.map { reg in
                    let payload = "{}".data(using: .utf8)!
                    var rawBytes = ByteBufferAllocator().buffer(capacity: payload.count)
                    rawBytes.writeBytes(payload)

                    return req.apns.send(rawBytes: rawBytes, pushType: .background, to: reg.device.pushToken, topic: reg.pass.type)
                        .flatMapError {
                            // Unless APNs said it was a bad device token, just ignore the error.
                            guard case let APNSwiftError.ResponseError.badRequest(response) = $0, response == .badDeviceToken else {
                                return req.eventLoop.future()
                            }

                            // Be sure the device deletes before the registration is deleted.
                            // If you let them run in parallel issues might arise depending on
                            // the hooks people have set for when a registration deletes, as it
                            // might try to delete the same device again.
                            return reg.device.delete(on: req.db)
                                .flatMapError { _ in req.eventLoop.future() }
                                .flatMap { reg.delete(on: req.db) }
                    }
                }
                .flatten(on: req.eventLoop)
            }
            .map { _ in .noContent }
    }

    func tokensForPassUpdate(req: Request) throws -> EventLoopFuture<[String]> {
        logger?.debug("Called tokensForPassUpdate")

        return try registrationsForPush(req: req).map { $0.map { $0.device.pushToken } }
    }
}

// MARK: Private methods
private extension ApiController {
    func registrationsForPush(req: Request) throws -> EventLoopFuture<[R]> {
        guard let id = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let type = req.parameters.get("type")!

        // This could be done by enforcing the caller to have a Siblings property
        // wrapper, but there's not really any value to forcing that on them when
        // we can just do the query ourselves like this.
        return R.query(on: req.db)
            .join(\._$pass)
            .join(\._$device)
            .with(\._$pass)
            .with(\._$device)
            .filter(P.self, \._$type == type)
            .filter(P.self, \._$id == id)
            .all()
    }

    func generateManifestFile(using encoder: JSONEncoder, in root: URL) throws {
        var manifest: [String: String] = [:]

        let noDotFiles = NoDotFiles()
        let fm = FileManager()
        fm.delegate = noDotFiles
        
        let paths = try fm.subpathsOfDirectory(atPath: root.unixPath())
        try paths
            .forEach { relativePath in
                let file = URL(fileURLWithPath: relativePath, relativeTo: root)
                guard !file.hasDirectoryPath else {
                    return
                }

                let data = try Data(contentsOf: file)
                let hash = Insecure.SHA1.hash(data: data)
                manifest[relativePath] = hash.description
        }

        let encoded = try encoder.encode(manifest)
        try encoded.write(to: root.appendingPathComponent("manifest.json"))
    }

    func generateSignatureFile(in root: URL) throws {
        if delegate.generateSignatureFile(in: root) {
            // If the caller's delegate generated a file we don't have to do it.
            return
        }

        // TODO: Is there any way to write this with native libraries instead of spawning a blocking process?
        let proc = Process()
        proc.currentDirectoryURL = delegate.sslSigningFilesDirectory
        proc.executableURL = delegate.sslBinary

        proc.arguments = [
            "smime", "-binary", "-sign",
            "-certfile", delegate.wwdrCertificate,
            "-signer", delegate.pemCertificate,
            "-inkey", delegate.pemPrivateKey,
            "-in", root.appendingPathComponent("manifest.json").unixPath(),
            "-out", root.appendingPathComponent("signature").unixPath(),
            "-outform", "DER",
            "-passin", "pass:\(delegate.pemPrivateKeyPassword)"
        ]

        try proc.run()

        proc.waitUntilExit()
    }

    func generatePassContent(for pass: P, on db: Database) -> EventLoopFuture<Data> {
        let tmp = FileManager.default.temporaryDirectory
        let root = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipFile = tmp.appendingPathComponent(UUID().uuidString)
        let encoder = JSONEncoder()

        return delegate.template(for: pass, db: db)
            .flatMap { src in
                return self.delegate.encode(pass: pass, db: db, encoder: encoder)
                    .flatMap { encoded in
                        do {
                            // Remember that FileManager isn't thread safe, so don't create it outside and use it here!
                            let noDotFiles = NoDotFiles()
                            let fileManager = FileManager()
                            fileManager.delegate = noDotFiles

                            if src.hasDirectoryPath {
                                try fileManager.copyItem(at: src, to: root)
                            } else {
                                try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
                                try fileManager.unzipItem(at: src, to: root)
                            }

                            defer {
                                _ = try? fileManager.removeItem(at: root)
                            }

                            try encoded.write(to: root.appendingPathComponent("pass.json"))
                            
                            try self.generateManifestFile(using: encoder, in: root)
                            try self.generateSignatureFile(in: root)
                            
                            try fileManager.zipItem(at: root, to: zipFile, shouldKeepParent: false)
                            
                            defer {
                                _ = try? fileManager.removeItem(at: zipFile)
                            }
                            
                            let data = try Data(contentsOf: zipFile)
                            return db.eventLoop.makeSucceededFuture(data)
                        } catch {
                            return db.eventLoop.makeFailedFuture(error)
                        }
                }
        }
    }

    func createRegistration(device: D, pass: P, req: Request) -> EventLoopFuture<HTTPStatus> {
        R.for(deviceLibraryIdentifier: device.deviceLibraryIdentifier, passTypeIdentifier: pass.type, on: req.db)
            .filter(P.self, \._$id == pass.id!)
            .first()
            .flatMap { r in
                if r != nil {
                    // If the registration already exists, docs say to return a 200
                    return req.eventLoop.makeSucceededFuture(.ok)
                }

                let registration = R()
                registration._$pass.id = pass.id!
                registration._$device.id = device.id!

                return registration.create(on: req.db)
                    .map { .created }
        }
    }
}