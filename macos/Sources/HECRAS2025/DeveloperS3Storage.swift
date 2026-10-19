import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Security

struct WorkspaceS3Credentials: Codable, Sendable {
    let accessKey: String
    let secretKey: String
}

@MainActor
protocol WorkspaceS3CredentialStoring {
    func load() -> WorkspaceS3Credentials?
    func save(_ credentials: WorkspaceS3Credentials) throws
    func delete() throws
}

@MainActor
final class WorkspaceS3KeychainStore: WorkspaceS3CredentialStoring {
    static let shared = WorkspaceS3KeychainStore()

    private let service = "org.hecras2025.developer-s3"
    private let account = "credentials"

    func load() -> WorkspaceS3Credentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(WorkspaceS3Credentials.self, from: data)
    }

    func save(_ credentials: WorkspaceS3Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = baseQuery
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else { throw WorkspaceDeveloperServiceError.keychain }
        } else if status != errSecSuccess {
            throw WorkspaceDeveloperServiceError.keychain
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WorkspaceDeveloperServiceError.keychain
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

enum WorkspaceDeveloperServiceError: LocalizedError {
    case missingCredentials
    case authenticationFailed
    case keychain
    case invalidKey
    case keyExists
    case archiveUnavailable
    case archiveMismatch
    case modelNotFound
    case invalidS3Response
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "Enter an S3 access key and secret."
        case .authenticationFailed: "S3 authentication failed."
        case .keychain: "The S3 credentials could not be saved in Keychain."
        case .invalidKey: "Please provide a valid key name."
        case .keyExists: "S3 key already exists."
        case .archiveUnavailable: "The project archive could not be created."
        case .archiveMismatch: "The project changed before its archive could be uploaded."
        case .modelNotFound: "The requested model could not be found."
        case .invalidS3Response: "The S3 service returned an invalid response."
        case .requestFailed: "The developer storage request failed."
        }
    }
}

struct S3ObjectRecord: Sendable {
    let key: String
    let size: Int64
    let owner: String
}

private struct S3ListPage: Sendable {
    let objects: [S3ObjectRecord]
    let isTruncated: Bool
    let nextToken: String?
}

private struct S3HTTPError: LocalizedError, Sendable {
    let status: Int
    let responseMessage: String?
    var errorDescription: String? {
        responseMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "The developer storage request failed."
    }
}

actor DeveloperS3Storage {
    static let endpoint = URL(string: "https://s3.hecdev.net")!
    static let bucket = "ras-model-uploads"
    private static let region = "us-east-1"
    private let credentials: WorkspaceS3Credentials
    private let session: URLSession = .shared

    init(credentials: WorkspaceS3Credentials) { self.credentials = credentials }

    func isAuthenticated() async -> Bool {
        do {
            _ = try await request(method: "GET", key: nil, query: [("location", "")])
            return true
        } catch {
            return false
        }
    }

    func listObjects(prefix: String = "") async throws -> [S3ObjectRecord] {
        var records: [S3ObjectRecord] = []
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("fetch-owner", "true"), ("prefix", prefix)]
            if let token { query.append(("continuation-token", token)) }
            let data = try await request(method: "GET", key: nil, query: query)
            let page = try Self.parseList(data)
            records.append(contentsOf: page.objects)
            token = page.isTruncated ? page.nextToken : nil
            if page.isTruncated && (token?.isEmpty ?? true) { throw WorkspaceDeveloperServiceError.invalidS3Response }
        } while token != nil
        return records
    }

    func objectExists(_ key: String) async throws -> Bool {
        do {
            _ = try await request(method: "HEAD", key: key)
            return true
        } catch let error as S3HTTPError where error.status == 404 {
            return false
        }
    }

    func presignedUploadURL(for key: String, expires: TimeInterval = 999 * 24 * 60 * 60) throws -> URL {
        let now = Date()
        let date = Self.timestamp(now)
        let day = String(date.prefix(8))
        let scope = "\(day)/\(Self.region)/s3/aws4_request"
        let path = Self.objectPath(key)
        let host = Self.host(Self.endpoint)
        let expiresSeconds = max(1, Int(expires))
        let query = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(credentials.accessKey)/\(scope)"),
            ("X-Amz-Date", date),
            ("X-Amz-Expires", String(expiresSeconds)),
            ("X-Amz-SignedHeaders", "host")
        ]
        let canonicalQuery = Self.canonicalQuery(query)
        let canonicalRequest = ["PUT", path, canonicalQuery, "host:\(host)\n", "host", "UNSIGNED-PAYLOAD"]
            .joined(separator: "\n")
        let stringToSign = ["AWS4-HMAC-SHA256", date, scope,
            Self.sha256(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let signature = Self.signature(stringToSign: stringToSign, secret: credentials.secretKey,
            date: day, region: Self.region)
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=" + signature
        guard let url = components.url else { throw WorkspaceDeveloperServiceError.invalidS3Response }
        return url
    }

    func upload(_ file: URL, to key: String, owner: String,
                progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        var request = try signedRequest(method: "PUT", key: key, headers: ["x-amz-meta-owner": owner],
            payloadHash: "UNSIGNED-PAYLOAD")
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        try await S3FileTransfer.run(request: request, uploadFile: file, destination: nil, progress: progress)
    }

    func download(_ key: String, to destination: URL,
                  progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        let request = try signedRequest(method: "GET", key: key)
        try await S3FileTransfer.run(request: request, uploadFile: nil,
            destination: destination, progress: progress)
    }

    func delete(_ key: String) async throws {
        _ = try await request(method: "DELETE", key: key)
    }

    func move(_ source: String, to destination: String) async throws {
        let sourcePath = "/\(Self.bucket)/\(Self.encodePath(source))"
        _ = try await request(method: "PUT", key: destination,
            headers: ["x-amz-copy-source": sourcePath])
        try await delete(source)
    }

    func copy(_ source: String, to destination: String) async throws {
        let sourcePath = "/\(Self.bucket)/\(Self.encodePath(source))"
        _ = try await request(method: "PUT", key: destination,
            headers: ["x-amz-copy-source": sourcePath])
    }

    private func request(method: String, key: String?, query: [(String, String)] = [],
                         headers: [String: String] = [:]) async throws -> Data {
        let request = try signedRequest(method: method, key: key, query: query, headers: headers)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, body: data)
        return data
    }

    private func signedRequest(method: String, key: String?, query: [(String, String)] = [],
                               headers extraHeaders: [String: String] = [:],
                               payloadHash: String? = nil) throws -> URLRequest {
        let path = key.map(Self.objectPath) ?? "/\(Self.bucket)"
        let canonicalQuery = Self.canonicalQuery(query)
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.percentEncodedQuery = canonicalQuery.isEmpty ? nil : canonicalQuery
        guard let url = components.url else { throw WorkspaceDeveloperServiceError.invalidS3Response }

        let now = Date()
        let amzDate = Self.timestamp(now)
        let day = String(amzDate.prefix(8))
        let bodyHash = payloadHash ?? Self.sha256(Data())
        var headers = Dictionary(uniqueKeysWithValues: extraHeaders.map { ($0.key.lowercased(), $0.value) })
        headers["host"] = Self.host(Self.endpoint)
        headers["x-amz-content-sha256"] = bodyHash
        headers["x-amz-date"] = amzDate
        let normalized = headers.mapValues(Self.normalizeHeader)
        let signedHeaders = normalized.keys.sorted().joined(separator: ";")
        let canonicalHeaders = normalized.keys.sorted().map { "\($0):\(normalized[$0]!)\n" }.joined()
        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders,
            signedHeaders, bodyHash].joined(separator: "\n")
        let scope = "\(day)/\(Self.region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
            Self.sha256(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let signature = Self.signature(stringToSign: stringToSign, secret: credentials.secretKey,
            date: day, region: Self.region)

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(bodyHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
        return request
    }

    private static func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw WorkspaceDeveloperServiceError.invalidS3Response }
        guard (200..<300).contains(http.statusCode) else {
            throw S3HTTPError(status: http.statusCode, responseMessage: parseError(body))
        }
    }

    private static func parseList(_ data: Data) throws -> S3ListPage {
        let delegate = S3ListXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw WorkspaceDeveloperServiceError.invalidS3Response }
        return delegate.page
    }

    private static func parseError(_ data: Data) -> String? {
        let delegate = S3ErrorXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.message
    }

    private static func objectPath(_ key: String) -> String {
        "/\(bucket)/\(encodePath(key))"
    }

    private static func encodePath(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func encodeQuery(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func canonicalQuery(_ pairs: [(String, String)]) -> String {
        let encodedPairs: [(name: String, value: String)] = pairs.map { pair in
            (name: encodeQuery(pair.0), value: encodeQuery(pair.1))
        }
        let sortedPairs = encodedPairs.sorted { left, right in
            if left.name != right.name { return left.name < right.name }
            return left.value < right.value
        }
        let queryItems = sortedPairs.map { pair in "\(pair.name)=\(pair.value)" }
        return queryItems.joined(separator: "&")
    }

    private static func host(_ url: URL) -> String {
        guard let host = url.host else { return "" }
        if let port = url.port, port != 443 && port != 80 { return "\(host):\(port)" }
        return host
    }

    private static func normalizeHeader(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func signature(stringToSign: String, secret: String, date: String, region: String) -> String {
        let kDate = HMAC<SHA256>.authenticationCode(for: Data(date.utf8), using: SymmetricKey(data: Data(("AWS4" + secret).utf8)))
        let kRegion = HMAC<SHA256>.authenticationCode(for: Data(region.utf8), using: SymmetricKey(data: Data(kDate)))
        let kService = HMAC<SHA256>.authenticationCode(for: Data("s3".utf8), using: SymmetricKey(data: Data(kRegion)))
        let kSigning = HMAC<SHA256>.authenticationCode(for: Data("aws4_request".utf8), using: SymmetricKey(data: Data(kService)))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: Data(kSigning)))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private final class S3ListXMLParser: NSObject, XMLParserDelegate {
    private var text = ""
    private var currentKey: String?
    private var currentSize: Int64 = 0
    private var currentOwner = ""
    private var currentPrefix: String?
    private var objects: [S3ObjectRecord] = []
    private var truncated = false
    private var nextToken: String?

    var page: S3ListPage { S3ListPage(objects: objects, isTruncated: truncated, nextToken: nextToken) }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "Contents" { currentKey = nil; currentSize = 0; currentOwner = "" }
        if elementName == "CommonPrefixes" { currentPrefix = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key": currentKey = value
        case "Size": currentSize = Int64(value) ?? 0
        case "DisplayName": currentOwner = value
        case "Prefix": currentPrefix = value
        case "IsTruncated": truncated = value.lowercased() == "true"
        case "NextContinuationToken": nextToken = value
        case "Contents":
            if let currentKey { objects.append(S3ObjectRecord(key: currentKey, size: currentSize, owner: currentOwner)) }
        case "CommonPrefixes":
            if let currentPrefix, !objects.contains(where: { $0.key == currentPrefix }) {
                objects.append(S3ObjectRecord(key: currentPrefix, size: 0, owner: ""))
            }
        default: break
        }
        text = ""
    }
}

private final class S3ErrorXMLParser: NSObject, XMLParserDelegate {
    private var inMessage = false
    private var text = ""
    var message: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "Message" { inMessage = true; text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inMessage { text += string } }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Message" { message = text.trimmingCharacters(in: .whitespacesAndNewlines); inMessage = false }
    }
}

private final class S3FileTransfer: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate,
                                   URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL?
    private let progress: @Sendable (Double?, String) -> Void
    private var responseData = Data()
    private var moveError: (any Error)?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var label: String

    private init(destination: URL?, label: String,
                 progress: @escaping @Sendable (Double?, String) -> Void) {
        self.destination = destination
        self.label = label
        self.progress = progress
    }

    static func run(request: URLRequest, uploadFile: URL?, destination: URL?,
                    progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        let transfer = S3FileTransfer(destination: destination,
            label: uploadFile == nil ? "Downloading model…" : "Uploading project…", progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: transfer, delegateQueue: nil)
        let task: URLSessionTask
        if let uploadFile { task = session.uploadTask(with: request, fromFile: uploadFile) }
        else { task = session.downloadTask(with: request) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.lock.withLock { transfer.continuation = continuation }
                transfer.progress(0, transfer.label)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        let fraction = totalBytesExpectedToSend > 0
            ? Double(totalBytesSent) / Double(totalBytesExpectedToSend) : nil
        progress(fraction, label)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        progress(fraction, label)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let destination else { return }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { lock.withLock { moveError = error } }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { responseData.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, (any Error)?) in
            let result = continuation
            continuation = nil
            if let error { return (result, error) }
            if let moveError { return (result, moveError) }
            if let response = task.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                let parser = S3ErrorXMLParser()
                let xml = XMLParser(data: responseData)
                xml.delegate = parser
                _ = xml.parse()
                let responseMessage = parser.message?.nilIfEmpty
                if let destination { try? FileManager.default.removeItem(at: destination) }
                return (result, S3HTTPError(status: response.statusCode, responseMessage: responseMessage))
            }
            return (result, nil)
        }
        if let error = completion.1 { completion.0?.resume(throwing: error) }
        else { progress(1, label); completion.0?.resume() }
        session.finishTasksAndInvalidate()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
