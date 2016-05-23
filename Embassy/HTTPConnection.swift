//
//  HTTPConnection.swift
//  Embassy
//
//  Created by Fang-Pen Lin on 5/21/16.
//  Copyright © 2016 Fang-Pen Lin. All rights reserved.
//

import Foundation



/// HTTPConnection represents an active HTTP connection
public final class HTTPConnection {
    enum RequestState {
        case ParsingHeader
        case ReadingBody
    }
    
    enum ResponseState {
        case SendingHeader
        case SendingBody
    }
    
    let logger = Logger()
    let transport: Transport
    let app: SWSGI
    let serverName: String
    let serverPort: Int
    private(set) var requestState: RequestState = .ParsingHeader
    private(set) var responseState: ResponseState = .SendingHeader
    private(set) weak var eventLoop: EventLoop!
    private var headerParser: HTTPHeaderParser!
    private var headerElements: [HTTPHeaderParser.Element] = []
    private var request: HTTPRequest!
    
    init(app: SWSGI, serverName: String, serverPort: Int, transport: Transport, eventLoop: EventLoop) {
        self.app = app
        self.serverName = serverName
        self.serverPort = serverPort
        self.transport = transport
        self.eventLoop = eventLoop
        
        transport.readDataCallback = handleDataReceived
        transport.closedCallback = handleConnectionClosed
    }
    
    // called to handle data received
    private func handleDataReceived(data: [UInt8]) {
        switch requestState {
        case .ParsingHeader:
            handleHeaderData(data)
        case .ReadingBody:
            handleBodyData(data)
        }
    }
    
    // called to handle header data
    private func handleHeaderData(data: [UInt8]) {
        if headerParser == nil {
            headerParser = HTTPHeaderParser()
        }
        headerElements += headerParser.feed(data)
        // we only handle when there are elements in header parser
        guard let lastElement = headerElements.last else {
            return
        }
        // we only handle the it when we get the end of header
        guard case .End = lastElement else {
            return
        }
        
        var method: String!
        var path: String!
        var version: String!
        var headers: [(String, String)] = []
        var body: [UInt8]!
        for element in headerElements {
            switch element {
            case .Head(let headMethod, let headPath, let headVersion):
                method = headMethod
                path = headPath
                version = headVersion
            case .Header(let key, let value):
                headers.append((key, value))
            case .End(let bodyPart):
                body = bodyPart
            }
        }
        logger.debug("Header parsed, method=\(method), path=\(path.debugDescription), version=\(version.debugDescription), headers=\(headers)")
        request = HTTPRequest(
            method: HTTPRequest.Method.fromString(method),
            path: path,
            version: version,
            rawHeaders: headers
        )
        var environ = SWSGIUtils.environForRequest(request)
        environ["SERVER_NAME"] = serverName
        environ["SERVER_PORT"] = String(serverPort)
        environ["SERVER_PROTOCOL"] = "HTTP/1.1"
        
        // set SWSGI keys
        environ["swsgi.version"] = "0.1"
        environ["swsgi.url_scheme"] = "http"
        // TODO: add file for incoming body
        environ["swsgi.input"] = ""
        // TODO: add output file for error
        environ["swsgi.error"] = ""
        environ["swsgi.multithread"] = false
        environ["swsgi.multiprocess"] = false
        environ["swsgi.run_once"] = false
        
        // change state for incoming request to
        requestState = .ReadingBody
        // pass the initial body data
        handleBodyData(body)
        
        app(environ: environ, startResponse: startResponse, sendBody: sendBody)
    }
    
    private func handleBodyData(data: [UInt8]) {
        // TODO:
    }
    
    private func startResponse(status: String, headers: [(String, String)]) {
        guard case .SendingHeader = responseState else {
            logger.error("Response is not ready for sending header")
            return
        }
        var headers = headers
        let headerList = HTTPHeaderList(headers: headers)
        // we don't support keep-alive connection for now, just force it to be closed
        if headerList["Connection"] == nil {
            headers.append(("Connection", "close"))
        }
        if headerList["Server"] == nil {
            headers.append(("Server", "Embassy"))
        }
        logger.debug("Start response, status=\(status.debugDescription), headers=\(headers.debugDescription)")
        let headersPart = headers.map { (key, value) in
            return "\(key): \(value)"
        }.joinWithSeparator("\r\n")
        let parts = [
            "HTTP/1.1 \(status)",
            headersPart,
            "\r\n"
        ]
        transport.writeUTF8(parts.joinWithSeparator("\r\n"))
        responseState = .SendingBody
    }
    
    private func sendBody(data: [UInt8]) {
        guard case .SendingBody = responseState else {
            logger.error("Response is not ready for sending body")
            return
        }
        guard data.count > 0 else {
            // TODO: support keep-alive connection here?
            transport.close()
            return
        }
        transport.write(data)
    }
    
    // called to handle connection closed
    private func handleConnectionClosed(reason: Transport.CloseReason) {
        
    }
}