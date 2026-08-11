import Foundation

public struct RPCRequest: Codable, Equatable, Sendable {
    public let id: String
    public let method: String
    public let params: JSONValue?

    public init(id: String, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct RPCResponse: Codable, Equatable, Sendable {
    public let id: String
    public let ok: Bool
    public let result: JSONValue?
    public let error: PluginErrorPayload?

    public init(id: String, result: JSONValue) {
        self.id = id
        self.ok = true
        self.result = result
        self.error = nil
    }

    public init(id: String, error: PluginError) {
        self.id = id
        self.ok = false
        self.result = nil
        self.error = error.payload
    }
}

public struct PluginErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let domain: String
    public let details: JSONValue?
}

public struct PluginError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let domain: String
    public let details: JSONValue?

    public init(
        code: String,
        message: String,
        retryable: Bool = false,
        domain: String = "desktop",
        details: JSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.domain = domain
        self.details = details
    }

    public var payload: PluginErrorPayload {
        PluginErrorPayload(code: code, message: message, retryable: retryable, domain: domain, details: details)
    }

    public var description: String { "\(code): \(message)" }

    public static func invalidArguments(_ message: String) -> PluginError {
        PluginError(code: "INVALID_ARGUMENTS", message: message, domain: "protocol")
    }

    public static func unsupported(_ message: String) -> PluginError {
        PluginError(code: "UNSUPPORTED", message: message, domain: "protocol")
    }
}

public struct ExecuteParams: Codable, Equatable, Sendable {
    public let action: String
    public let arguments: JSONValue

    public init(action: String, arguments: JSONValue = .object([:])) {
        self.action = action
        self.arguments = arguments
    }
}
