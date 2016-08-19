/*
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import KituraNet
import KituraSys
import SwiftyJSON

import Foundation
import LoggerAPI

// MARK: RouterResponse

///
public class RouterResponse {

    struct State {

        /// Whether the response has ended
        var invokedEnd = false

        /// Whether data has been added to buffer
        var invokedSend = false
    }

    struct Lifecycle {

        /// Lifecycle hook called on end()
        var onEndInvoked: LifecycleHandler = {}

        /// Current pre-write lifecycle handler
        var writtenDataFilter: WrittenDataFilter = { body in
            return body
        }
    }

    /// The server response
    let response: ServerResponse

    /// The router
    unowned let router: Router

    /// The associated request
    let request: RouterRequest

    /// The buffer used for output
    private let buffer = BufferList()

    /// State of the request
    var state = State()

    private var lifecycle = Lifecycle()

    /// Set of cookies to return with the response
    public var cookies = [String: HTTPCookie]()

    /// Optional error value
    public var error: Swift.Error?

    public var headers: Headers

    public var statusCode: HTTPStatusCode {
        get {
            return response.statusCode ?? .unknown
        }

        set(newValue) {
            response.statusCode = newValue
        }
    }

    /// Initializes a RouterResponse instance
    ///
    /// - Parameter response: the server response
    /// - Parameter router: the router
    /// - Parameter request: the router request
    /// - Returns: a ServerResponse instance
    init(response: ServerResponse, router: Router, request: RouterRequest) {
        self.response = response
        self.router = router
        self.request = request
        headers = Headers(headers: response.headers)
        statusCode = .unknown
    }

    /// Ends the response
    ///
    /// - Throws: ???
    @discardableResult
    public func end() throws {
        lifecycle.onEndInvoked()

        // Sets status code if unset
        if statusCode == .unknown {
            statusCode = .OK
        }

        let content = lifecycle.writtenDataFilter(body: buffer.data)
        let contentLength = headers["Content-Length"]
        if  contentLength == nil {
            headers["Content-Length"] = String(content.count)
        }
        addCookies()

        if  request.method != .head {
            try response.write(from: content)
        }
        state.invokedEnd = true
        try response.end()
    }

    /// Add Set-Cookie headers
    private func addCookies() {
        var cookieStrings = [String]()

        for  (_, cookie) in cookies {
            var cookieString = cookie.name + "=" + cookie.value + "; path=" + cookie.path + "; domain=" + cookie.domain
            if  let expiresDate = cookie.expiresDate {
                cookieString += "; expires=" + SPIUtils.httpDate(expiresDate)
            }

            if  cookie.isSecure {
                cookieString += "; secure; HTTPOnly"
            }

            cookieStrings.append(cookieString)
        }
        response.headers.append("Set-Cookie", value: cookieStrings)
    }

    /// Sends a string
    ///
    /// - Parameter str: the string to send
    /// - Returns: this RouterResponse
    @discardableResult
    public func send(_ str: String) -> RouterResponse {
        if let data = StringUtils.toUtf8String(str) {
            send(data: data)
        }
        return self
    }

    /// Sends data
    ///
    /// - Parameter data: the data to send
    /// - Returns: this RouterResponse
    @discardableResult
    public func send(data: Data) -> RouterResponse {
        buffer.append(data: data)
        state.invokedSend = true
        return self
    }

    /// Sends a file
    ///
    /// - Parameter fileName: the name of the file to send.
    /// - Returns: this RouterResponse
    ///
    /// - Note: Sets the Content-Type header based on the "extension" of the file.
    ///       If the fileName is relative, it is relative to the current directory.
    @discardableResult
    public func send(fileName: String) throws -> RouterResponse {
        let data = try Data(contentsOf: URL(fileURLWithPath: fileName))

        let contentType =  ContentType.sharedInstance.getContentType(forFileName: fileName)
        if  let contentType = contentType {
            headers["Content-Type"] = contentType
        }

        send(data: data)

        return self
    }

    /// Sends JSON
    ///
    /// - Parameter json: the JSON object to send
    /// - Returns: this RouterResponse
    @discardableResult
    public func send(json: JSON) -> RouterResponse {
        let jsonStr = json.description
        headers.setType("json")
        send(jsonStr)
        return self
    }

    /// Sends JSON with JSONP callback
    ///
    /// - Parameter json: the JSON object to send
    /// - Parameter callbackParameter: the name of the URL query
    /// parameter whose value contains the JSONP callback function
    ///
    /// - Throws: `JSONPError.invalidCallbackName` if the the callback
    /// query parameter of the request URL is missing or its value is
    /// empty or contains invalid characters (the set of valid characters
    /// is the alphanumeric characters and `[]$._`).
    /// - Returns: this RouterResponse
    public func send(jsonp: JSON, callbackParameter: String = "callback") throws -> RouterResponse {
        func sanitizeJSIdentifier(_ ident: String) -> String {
            return ident.replacingOccurrences(of: "[^\\[\\]\\w$.]", with: "", options:
                    NSString.CompareOptions.regularExpression)
        }
        func validJsonpCallbackName(_ name: String?) -> String? {
            if let name = name {
                if name.characters.count > 0 && name == sanitizeJSIdentifier(name) {
                    return name
                }
            }
            return nil
        }
        func jsonToJS(_ json: String) -> String {
            // Translate JSON characters that are invalid in javascript
            return json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                       .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }

        let jsonStr = jsonp.description
        let taintedJSCallbackName = request.queryParameters[callbackParameter]
        if let jsCallbackName = validJsonpCallbackName(taintedJSCallbackName) {
            headers.setType("js")
            // Set header "X-Content-Type-Options: nosniff" and prefix body with
            // "/**/ " as security mitigation for Flash vulnerability
            // CVE-2014-4671, CVE-2014-5333 "Abusing JSONP with Rosetta Flash"
            headers["X-Content-Type-Options"] = "nosniff"
            send("/**/ " + jsCallbackName + "(" + jsonToJS(jsonStr) + ")")
        } else {
            throw JSONPError.invalidCallbackName(name: taintedJSCallbackName)
        }
        return self
    }

    /// Set the status code
    ///
    /// - Parameter status: the status code object
    /// - Returns: this RouterResponse
    @discardableResult
    public func status(_ status: HTTPStatusCode) -> RouterResponse {
        response.statusCode = status
        return self
    }

    /// Sends the HTTP status code
    ///
    /// - Parameter status: the HTTP status code
    /// - Throws: ???
    /// - Returns: this RouterResponse
    public func send(status: HTTPStatusCode) throws -> RouterResponse {
        self.status(status)
        if let statusCode = HTTP.statusCodes[status.rawValue] {
            send(statusCode)
        }
        return self
    }

    /// Redirect to path with status code
    ///
    /// - Parameter: the path for the redirect
    /// - Parameter: the status code for the redirect
    /// - Returns: this RouterResponse
    @discardableResult
    public func redirect(_ path: String, status: HTTPStatusCode = .movedTemporarily) throws -> RouterResponse {
        headers.setLocation(path)
        try self.status(status).end()
        return self
    }

    /// Renders a resource using Router's template engine
    ///
    /// - Parameter resource: the resource name without extension
    /// - Parameter context:
    /// - Returns: a RouterResponse instance
    ///
    // influenced by http://expressjs.com/en/4x/api.html#app.render
    public func render(_ resource: String, context: [ String: Any]) throws -> RouterResponse {
        let renderedResource = try router.render(template: resource, context: context)
        return send(renderedResource)
    }

    /// Sets headers and attaches file for downloading
    ///
    /// - Parameter download: the file to download
    public func send(download: String) throws {
        try send(fileName: download)
        headers.addAttachment(for: download)
    }

    /// Sets the pre-flush lifecycle handler and returns the previous one
    ///
    /// - Parameter newOnEndInvoked: The new pre-flush lifecycle handler
    /// - Returns: The old pre-flush lifecycle handler
    public func setOnEndInvoked(_ newOnEndInvoked: LifecycleHandler) -> LifecycleHandler {
        let oldOnEndInvoked = lifecycle.onEndInvoked
        lifecycle.onEndInvoked = newOnEndInvoked
        return oldOnEndInvoked
    }

    /// Sets the written data filter and returns the previous one
    ///
    /// - Parameter newWrittenDataFilter: The new written data filter
    /// - Returns: The old written data filter
    public func setWrittenDataFilter(_ newWrittenDataFilter: WrittenDataFilter) -> WrittenDataFilter {
        let oldWrittenDataFilter = lifecycle.writtenDataFilter
        lifecycle.writtenDataFilter = newWrittenDataFilter
        return oldWrittenDataFilter
    }

    /// Performs content-negotiation on the Accept HTTP header on the request, when present. It uses
    /// request.accepts() to select a handler for the request, based on the acceptable types ordered by their
    /// quality values. If the header is not specified, the default callback is invoked. When no match is found,
    /// the server invokes the default callback if exists, or responds with 406 “Not Acceptable”.
    /// The Content-Type response header is set when a callback is selected.
    ///
    /// - Parameter callbacks: a dictionary that maps content types to handlers
    public func format(callbacks: [String : ((RouterRequest, RouterResponse) -> Void)]) throws {
        let callbackTypes = Array(callbacks.keys)
        if let acceptType = request.accepts(types: callbackTypes) {
            headers["Content-Type"] = acceptType
            callbacks[acceptType]!(request, self)
        } else if let defaultCallback = callbacks["default"] {
            defaultCallback(request, self)
        } else {
            try status(.notAcceptable).end()
        }
    }
}

/// Type alias for "Before flush" (i.e. before headers and body are written) lifecycle handler
public typealias LifecycleHandler = () -> Void

/// Type alias for written data filter, i.e. pre-write lifecycle handler
public typealias WrittenDataFilter = (body: Data) -> Data
