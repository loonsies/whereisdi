-----------------------------------------------------------------------------
-- Non-blocking HTTP(S) client for Ashita addons
-- Handles HTTP and HTTPS requests without blocking the main thread
-- Call processAll() from your d3d_present callback to advance requests
-----------------------------------------------------------------------------

local socket = require('socket')
local url = require('socket.url')
local ssl = require('socket.ssl')
local nonBlockingRequests = {}

-- Request states
local REQUEST_STATE = {
    INIT = 1,
    CONNECTING = 2,
    SSL_HANDSHAKE = 3,
    SENDING_REQUEST = 4,
    RECEIVING_STATUS = 5,
    RECEIVING_HEADERS = 6,
    RECEIVING_BODY = 7,
    COMPLETE = 8,
    ERROR = 9
}

-- Active requests storage
local activeRequests = {}
local nextRequestId = 1

-- Settings
local CONNECT_TIMEOUT = 0     -- 0 = non-blocking socket operations
local READ_CHUNK_SIZE = 4096  -- Bytes to read per frame
local CONNECTION_TIMEOUT = 30 -- Max seconds to wait for connection
local HANDSHAKE_TIMEOUT = 15  -- Max seconds for SSL handshake
local DEBUG = false

-- Print debug messages when enabled
local function debug(msg)
    if DEBUG then
        print('[HTTP] ' .. msg)
    end
end

-- Create TCP socket for HTTP/HTTPS requests
local function createSocket(isSecure)
    local sock = socket.tcp()
    if not sock then
        return nil, 'Failed to create TCP socket'
    end

    debug('Created TCP socket for ' .. (isSecure and 'HTTPS' or 'HTTP'))
    return sock, nil
end

-- Clean up request resources
local function cleanupRequest(request)
    if request.socket then
        pcall(request.socket.close, request.socket)
        request.socket = nil
    end
    -- Clear large data structures
    request.requestData = nil
    request.responseBody = nil
end

-- Parse URL and validate
local function parseURL(fullUrl)
    if not fullUrl or type(fullUrl) ~= 'string' or fullUrl == '' then
        error('Invalid URL: empty or non-string')
    end

    local parsed = url.parse(fullUrl)
    if not parsed or not parsed.scheme or not parsed.host then
        error('Invalid URL: ' .. fullUrl)
    end

    if parsed.scheme ~= 'http' and parsed.scheme ~= 'https' then
        error('Unsupported scheme: ' .. parsed.scheme)
    end

    local isSecure = parsed.scheme == 'https'
    local port = parsed.port or (isSecure and 443 or 80)

    return {
        scheme = parsed.scheme,
        host = parsed.host,
        port = port,
        path = parsed.path or '/',
        query = parsed.query,
        fragment = parsed.fragment,
        isSecure = isSecure
    }
end

-- Build HTTP request string
local function buildRequest(method, parsedUrl, requestHeaders, body)
    local uri = parsedUrl.path
    if parsedUrl.query then
        uri = uri .. '?' .. parsedUrl.query
    end

    local requestLine = method .. ' ' .. uri .. ' HTTP/1.1\r\n'

    -- Standard headers
    local headers = {
        ['Host'] = parsedUrl.host .. (parsedUrl.port ~= (parsedUrl.isSecure and 443 or 80) and ':' .. parsedUrl.port or ''),
        ['Connection'] = 'close',
        ['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:144.0) Gecko/20100101 Firefox/144.0'
    }

    -- Body handling for POST
    if body and #body > 0 then
        headers['Content-Length'] = tostring(#body)
        if not (requestHeaders and requestHeaders['Content-Type']) then
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
        end
    end

    -- Merge custom headers
    if requestHeaders then
        for k, v in pairs(requestHeaders) do
            headers[k] = v
        end
    end

    -- Build header string
    local headerString = ''
    for k, v in pairs(headers) do
        headerString = headerString .. k .. ': ' .. v .. '\r\n'
    end
    headerString = headerString .. '\r\n'

    local request = requestLine .. headerString
    if body and #body > 0 then
        request = request .. body
    end

    return request
end

-- Parse HTTP status line
local function parseStatusLine(line)
    local version, code, message = line:match('^HTTP/(%d+%.%d+) (%d+) (.*)$')
    if version and code then
        return tonumber(code), message:gsub('\r', '')
    end
    return nil, 'Invalid status line'
end

-- Parse response headers into table
local function parseHeaders(headerLines)
    local headers = {}
    for _, line in ipairs(headerLines) do
        local name, value = line:match('^([^:]+):%s*(.*)$')
        if name and value then
            headers[name:lower()] = value:gsub('\r', '')
        end
    end
    return headers
end

-- Process a single request state
local function processRequest(request)
    if request.state == REQUEST_STATE.INIT then
        -- Parse URL and create socket
        local success, result = pcall(parseURL, request.url)
        if not success then
            request.state = REQUEST_STATE.ERROR
            request.error = 'URL parse error: ' .. tostring(result)
            debug('URL parse failed: ' .. tostring(result))
            return
        end
        request.parsedUrl = result

        local sock, err = createSocket(request.parsedUrl.isSecure)
        if not sock then
            request.state = REQUEST_STATE.ERROR
            request.error = err or 'Failed to create socket'
            debug('Socket creation failed: ' .. (err or 'unknown'))
            return
        end

        request.socket = sock

        -- Set non-blocking mode
        local success, err = pcall(function ()
            request.socket:settimeout(CONNECT_TIMEOUT)
        end)
        if not success then
            request.state = REQUEST_STATE.ERROR
            request.error = 'Socket timeout setup failed: ' .. tostring(err)
            debug('Socket settimeout failed: ' .. tostring(err))
            cleanupRequest(request)
            return
        end

        request.state = REQUEST_STATE.CONNECTING
        request.connectStartTime = os.clock()
        debug('Starting connection to ' .. request.parsedUrl.host .. ':' .. request.parsedUrl.port)
    elseif request.state == REQUEST_STATE.CONNECTING then
        -- Handle connection establishment
        if not request.connectAttempted then
            -- First connection attempt
            local result, err = request.socket:connect(request.parsedUrl.host, request.parsedUrl.port)
            request.connectAttempted = true

            if result == 1 then
                debug('Connected immediately to ' .. request.parsedUrl.host)
                -- Connection successful, proceed to next state
            elseif err == 'timeout' then
                debug('Connection pending for ' .. request.parsedUrl.host)
                return -- Keep trying
            else
                request.state = REQUEST_STATE.ERROR
                request.error = 'Connection failed: ' .. (err or 'unknown')
                debug('Connection failed: ' .. (err or 'unknown'))
                cleanupRequest(request)
                return
            end
        else
            -- Check connection status using getsockname
            local ip, port = request.socket:getsockname()
            if ip and port then
                debug('Connection established to ' .. request.parsedUrl.host)
                -- Connection is ready
            else
                -- Check timeout
                local elapsed = os.clock() - request.connectStartTime
                if elapsed > CONNECTION_TIMEOUT then
                    request.state = REQUEST_STATE.ERROR
                    request.error = 'Connection timeout after ' .. math.floor(elapsed) .. 's'
                    debug('Connection timeout for ' .. request.url)
                    cleanupRequest(request)
                    return
                else
                    return -- Keep waiting
                end
            end
        end

        -- Connection successful, set up SSL or HTTP
        if request.parsedUrl.isSecure then
            debug('Setting up SSL for ' .. request.parsedUrl.host)

            local sslParams = {
                mode = 'client',
                protocol = 'any',
                options = { 'all', 'no_sslv2', 'no_sslv3', 'no_tlsv1' },
                verify = 'none'
            }

            local sslSock, err = ssl.wrap(request.socket, sslParams)
            if not sslSock then
                request.state = REQUEST_STATE.ERROR
                request.error = 'SSL setup failed: ' .. (err or 'unknown')
                debug('SSL wrap failed: ' .. (err or 'unknown'))
                cleanupRequest(request)
                return
            end

            request.socket = sslSock

            -- Set Server Name Indication
            pcall(function () sslSock:sni(request.parsedUrl.host) end)
            sslSock:settimeout(0)

            request.state = REQUEST_STATE.SSL_HANDSHAKE
            request.handshakeStart = os.clock()
            debug('SSL handshake started for ' .. request.parsedUrl.host)
        else
            debug('HTTP ready for ' .. request.parsedUrl.host)
        end

        -- Prepare request data for both HTTP and HTTPS
        if not request.parsedUrl.isSecure then
            request.state = REQUEST_STATE.SENDING_REQUEST
            request.requestData = buildRequest(request.method, request.parsedUrl, request.headers, request.body)
            request.sentBytes = 0
        end
    elseif request.state == REQUEST_STATE.SSL_HANDSHAKE then
        -- Complete SSL handshake
        local result, err = request.socket:dohandshake()

        if result == 1 or result == true then
            debug('SSL ready for ' .. request.parsedUrl.host)
            -- SSL handshake complete, prepare to send request
            request.state = REQUEST_STATE.SENDING_REQUEST
            request.requestData = buildRequest(request.method, request.parsedUrl, request.headers, request.body)
            request.sentBytes = 0
        elseif err == 'timeout' or err == 'wantread' or err == 'wantwrite' then
            -- Handshake in progress, check timeout
            local elapsed = os.clock() - request.handshakeStart
            if elapsed > HANDSHAKE_TIMEOUT then
                request.state = REQUEST_STATE.ERROR
                request.error = 'SSL handshake timeout after ' .. math.floor(elapsed) .. 's'
                debug('SSL handshake timeout for ' .. request.url)
                cleanupRequest(request)
            end
        else
            request.state = REQUEST_STATE.ERROR
            request.error = 'SSL handshake failed: ' .. (err or 'unknown')
            debug('SSL handshake failed: ' .. (err or 'unknown'))
            cleanupRequest(request)
        end
    elseif request.state == REQUEST_STATE.SENDING_REQUEST then
        -- Send request data
        local remaining = request.requestData:sub(request.sentBytes + 1)
        if #remaining == 0 then
            request.state = REQUEST_STATE.RECEIVING_STATUS
            request.headerLines = {}
            request.responseHeaders = {}
            request.responseBody = {}
            debug('Request sent to ' .. request.url)
            return
        end

        local chunk = remaining:sub(1, READ_CHUNK_SIZE)
        local sent, err = request.socket:send(chunk)

        if sent then
            request.sentBytes = request.sentBytes + sent
        elseif err ~= 'timeout' and err ~= 'wantwrite' then
            request.state = REQUEST_STATE.ERROR
            request.error = 'Send error: ' .. (err or 'unknown')
            cleanupRequest(request)
        end
    elseif request.state == REQUEST_STATE.RECEIVING_STATUS then
        -- Get status line
        local data, err = request.socket:receive('*l')

        if data then
            local code, message = parseStatusLine(data)
            if code then
                request.statusCode = code
                request.statusMessage = message
                request.state = REQUEST_STATE.RECEIVING_HEADERS
                debug('Status: ' .. code .. ' ' .. (message or ''))
            else
                request.state = REQUEST_STATE.ERROR
                request.error = 'Invalid status line: ' .. data
                cleanupRequest(request)
            end
        elseif err == 'timeout' or err == 'wantread' then
            -- Keep waiting
        elseif err == 'closed' then
            request.state = REQUEST_STATE.ERROR
            request.error = 'Connection closed during status'
            cleanupRequest(request)
        else
            request.state = REQUEST_STATE.ERROR
            request.error = 'Status receive error: ' .. (err or 'unknown')
            cleanupRequest(request)
        end
    elseif request.state == REQUEST_STATE.RECEIVING_HEADERS then
        -- Get headers line by line
        local data, err = request.socket:receive('*l')

        if data then
            if data == '' then
                -- End of headers
                request.responseHeaders = parseHeaders(request.headerLines)
                request.state = REQUEST_STATE.RECEIVING_BODY
                request.contentLength = tonumber(request.responseHeaders['content-length'])
                request.receivedBodyBytes = 0
                debug('Headers complete, content-length: ' .. (request.contentLength or 'chunked'))
            else
                table.insert(request.headerLines, data)
            end
        elseif err == 'timeout' or err == 'wantread' then
            -- Keep waiting
        elseif err == 'closed' then
            request.state = REQUEST_STATE.ERROR
            request.error = 'Connection closed during headers'
            cleanupRequest(request)
        else
            request.state = REQUEST_STATE.ERROR
            request.error = 'Header receive error: ' .. (err or 'unknown')
            cleanupRequest(request)
        end
    elseif request.state == REQUEST_STATE.RECEIVING_BODY then
        -- Get response body
        local bytesToRead = READ_CHUNK_SIZE
        if request.contentLength then
            local remaining = request.contentLength - request.receivedBodyBytes
            if remaining <= 0 then
                request.state = REQUEST_STATE.COMPLETE
                debug('Body complete')
                return
            end
            bytesToRead = math.min(bytesToRead, remaining)
        end

        local data, err = request.socket:receive(bytesToRead)

        if data then
            table.insert(request.responseBody, data)
            request.receivedBodyBytes = request.receivedBodyBytes + #data

            if request.contentLength and request.receivedBodyBytes >= request.contentLength then
                request.state = REQUEST_STATE.COMPLETE
                debug('Body complete')
            end
        elseif err == 'timeout' or err == 'wantread' then
            -- Keep waiting
        elseif err == 'closed' then
            -- Connection closed - might be normal
            if #request.responseBody > 0 or not request.contentLength then
                request.state = REQUEST_STATE.COMPLETE
                debug('Body complete (connection closed)')
            else
                request.state = REQUEST_STATE.ERROR
                request.error = 'Connection closed unexpectedly'
                cleanupRequest(request)
            end
        else
            request.state = REQUEST_STATE.ERROR
            request.error = 'Body receive error: ' .. (err or 'unknown')
            cleanupRequest(request)
        end
    end
end

-- Complete request and invoke callback
local function completeRequest(request)
    if request.state == REQUEST_STATE.COMPLETE then
        local body = table.concat(request.responseBody or {})
        debug('Request done: ' .. #body .. ' bytes')
        cleanupRequest(request)
        pcall(request.callback, body, nil, request.statusCode)
    else
        debug('Request failed: ' .. (request.error or 'Unknown error'))
        cleanupRequest(request)
        pcall(request.callback, nil, request.error or 'Unknown error', request.statusCode)
    end
end

-- Process all active requests (call from d3d_present)
function nonBlockingRequests.processAll()
    local toComplete = {}

    for id, request in pairs(activeRequests) do
        if request.state == REQUEST_STATE.COMPLETE or request.state == REQUEST_STATE.ERROR then
            table.insert(toComplete, id)
        else
            local success, err = pcall(processRequest, request)
            if not success then
                debug('Processing error for request ' .. id .. ': ' .. tostring(err))
                request.state = REQUEST_STATE.ERROR
                request.error = 'Internal error: ' .. tostring(err)
                table.insert(toComplete, id)
            elseif request.state == REQUEST_STATE.COMPLETE or request.state == REQUEST_STATE.ERROR then
                table.insert(toComplete, id)
            end
        end
    end

    -- Complete finished requests
    for _, id in ipairs(toComplete) do
        local request = activeRequests[id]
        if request then
            completeRequest(request)
            activeRequests[id] = nil
        end
    end
end

-- Make HTTP GET request
function nonBlockingRequests.get(url, headers, callback)
    if type(callback) ~= 'function' then
        error('Callback must be a function')
    end

    local request = {
        id = nextRequestId,
        url = url,
        method = 'GET',
        headers = headers,
        callback = callback,
        state = REQUEST_STATE.INIT
    }

    activeRequests[nextRequestId] = request
    nextRequestId = nextRequestId + 1

    debug('GET ' .. url)
    return request.id
end

-- Make HTTP POST request
function nonBlockingRequests.post(url, body, headers, callback)
    if type(callback) ~= 'function' then
        error('Callback must be a function')
    end

    local request = {
        id = nextRequestId,
        url = url,
        method = 'POST',
        headers = headers,
        body = body,
        callback = callback,
        state = REQUEST_STATE.INIT
    }

    activeRequests[nextRequestId] = request
    nextRequestId = nextRequestId + 1

    debug('POST ' .. url)
    return request.id
end

-- Cancel pending request
function nonBlockingRequests.cancel(requestId)
    local request = activeRequests[requestId]
    if request then
        cleanupRequest(request)
        activeRequests[requestId] = nil
        return true
    end
    return false
end

-- Get count of active requests
function nonBlockingRequests.getActiveCount()
    local count = 0
    for _ in pairs(activeRequests) do
        count = count + 1
    end
    return count
end

-- Enable/disable debug output
function nonBlockingRequests.setDebug(enabled)
    DEBUG = enabled
    debug('Debug ' .. (enabled and 'on' or 'off'))
end

return nonBlockingRequests
