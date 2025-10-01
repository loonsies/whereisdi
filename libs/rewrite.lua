package.cpath = package.cpath .. ('%s\\libs\\?.dll;'):fmt(addon.path);
local uv = require('luv')
local socket = require('socket')
local url = require('socket.url')
local ssl = require('socket.ssl')

local nonBlockingRequests = {}

local DEBUG = true
local READ_CHUNK_SIZE = 8192
local MAX_REDIRECTS = 5

local REQUEST_STATE = {
    INIT = 1,
    RESOLVING = 2,
    CONNECTING = 3,
    SSL_HANDSHAKE = 4,
    SENDING_REQUEST = 5,
    RECEIVING_STATUS = 6,
    RECEIVING_HEADERS = 7,
    RECEIVING_BODY = 8,
    COMPLETE = 9,
    ERROR = 10
}

local activeRequests = {}
local nextRequestId = 1

local function log(target, message, force)
    if message == nil then
        message = target
        target = nil
    end

    local shouldLog = force == true
    if not shouldLog then
        if target then
            shouldLog = DEBUG or target.debug
        else
            shouldLog = DEBUG
        end
    end

    if not shouldLog then
        return
    end

    local prefix = '[HTTP]'
    if target then
        local parts = {}
        if target.id then table.insert(parts, '#' .. tostring(target.id)) end
        if target.method then table.insert(parts, target.method) end
        if target.url then table.insert(parts, target.url) end
        if #parts > 0 then
            prefix = prefix .. ' ' .. table.concat(parts, ' ')
        end
    end

    print(prefix .. ' ' .. tostring(message))
end

local function parseURL(fullUrl)
    if not fullUrl or type(fullUrl) ~= 'string' or fullUrl == '' then
        return nil, 'Invalid URL: empty or non-string'
    end

    local parsed = url.parse(fullUrl)
    if not parsed or not parsed.scheme or not parsed.host then
        return nil, 'Invalid URL: ' .. fullUrl
    end

    if parsed.scheme ~= 'http' and parsed.scheme ~= 'https' then
        return nil, 'Unsupported scheme: ' .. parsed.scheme
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

local function buildRequest(method, parsedUrl, requestHeaders, body)
    local uri = parsedUrl.path
    if parsedUrl.query then
        uri = uri .. '?' .. parsedUrl.query
    end

    local requestLine = method .. ' ' .. uri .. ' HTTP/1.1\r\n'

    local headers = {
        ['Host'] = parsedUrl.host .. (parsedUrl.port ~= (parsedUrl.isSecure and 443 or 80) and ':' .. parsedUrl.port or ''),
        ['Connection'] = 'close',
        ['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:144.0) Gecko/20100101 Firefox/144.0',
    }

    if body and #body > 0 then
        headers['Content-Length'] = tostring(#body)
        if not (requestHeaders and requestHeaders['Content-Type']) then
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
        end
    end

    if requestHeaders then
        for k, v in pairs(requestHeaders) do
            headers[k] = v
        end
    end

    local headerString = ''
    for k, v in pairs(headers) do
        headerString = headerString .. k .. ': ' .. v .. '\r\n'
    end
    headerString = headerString .. '\r\n'

    local requestData = requestLine .. headerString
    if body and #body > 0 then
        requestData = requestData .. body
    end

    return requestData
end

local function parseStatusLine(line)
    local version, code, message = line:match('^HTTP/(%d+%.%d+) (%d+) (.*)$')
    if version and code then
        return tonumber(code), message:gsub('\r', '')
    end
    return nil, 'Invalid status line'
end

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

local function resolveRedirectUrl(baseUrl, location)
    if location:match('^https?://') then
        return location
    elseif location:match('^/') then
        local scheme, host, port = baseUrl:match('^(https?)://([^:/]+):?(%d*)')
        if scheme and host then
            local portPart = (port and port ~= '') and (':' .. port) or ''
            return scheme .. '://' .. host .. portPart .. location
        end
    else
        local basePart = baseUrl:match('^(.*/)')
        if basePart then
            return basePart .. location
        end
    end
    return location
end

local function cleanupRequest(request)
    if request.cleaningUp then
        return
    end
    request.cleaningUp = true

    if request.pollHandle then
        if not uv.is_closing(request.pollHandle) then
            pcall(uv.poll_stop, request.pollHandle)
            uv.close(request.pollHandle)
        end
        request.pollHandle = nil
    end

    if request.timeoutTimer then
        if not uv.is_closing(request.timeoutTimer) then
            pcall(uv.timer_stop, request.timeoutTimer)
            uv.close(request.timeoutTimer)
        end
        request.timeoutTimer = nil
    end

    if request.socket then
        pcall(request.socket.close, request.socket)
        request.socket = nil
    end

    request.requestData = nil
    request.responseBody = nil
end

local function resetForRedirect(request)
    request.state = REQUEST_STATE.INIT
    request.socket = nil
    request.pollHandle = nil
    request.timeoutTimer = nil
    request.headerLines = {}
    request.responseHeaders = {}
    request.responseBody = {}
    request.requestData = nil
    request.sentBytes = 0
    request.receivedBodyBytes = 0
    request.contentLength = nil
    request.statusCode = nil
    request.statusMessage = nil
    request.isChunked = false
    request.chunkSize = nil
    request.chunkBytesRead = 0
    request.expectingChunkTerminator = false
    request.awaitingTrailer = false
    request.readBuffer = ''
end

local function failRequest(request, error)
    request.state = REQUEST_STATE.ERROR
    request.error = error
    log(request, 'Request failed: ' .. error)
end

local function completeRequest(request)
    if request.state == REQUEST_STATE.COMPLETE then
        local body = table.concat(request.responseBody or {})
        log(request, 'Request complete: ' .. #body .. ' bytes')
        cleanupRequest(request)
        pcall(request.callback, body, nil, request.statusCode)
    else
        log(request, 'Request failed: ' .. (request.error or 'Unknown error'))
        cleanupRequest(request)
        pcall(request.callback, nil, request.error or 'Unknown error', request.statusCode)
    end
    activeRequests[request.id] = nil
end

local function processLine(request)
    local lineEnd = request.readBuffer:find('\r?\n')
    if not lineEnd then
        return nil
    end

    local line = request.readBuffer:sub(1, lineEnd - 1)
    line = line:gsub('\r$', '')
    request.readBuffer = request.readBuffer:sub(lineEnd + 1)

    if request.readBuffer:sub(1, 1) == '\n' then
        request.readBuffer = request.readBuffer:sub(2)
    end

    return line
end

local function handleChunkedBody(request)
    while true do
        if request.expectingChunkTerminator then
            if #request.readBuffer >= 2 then
                request.readBuffer = request.readBuffer:sub(3)
                request.expectingChunkTerminator = false
                request.chunkSize = nil
                request.chunkBytesRead = 0
            else
                return
            end
        end

        if request.awaitingTrailer then
            local line = processLine(request)
            if line == nil then
                return
            end
            if line == '' then
                request.state = REQUEST_STATE.COMPLETE
                return
            end
        end

        if not request.chunkSize then
            local line = processLine(request)
            if not line then
                return
            end

            local size = tonumber(line, 16)
            if not size then
                failRequest(request, 'Invalid chunk size line')
                return
            end

            if size == 0 then
                request.chunkSize = 0
                request.chunkBytesRead = 0
                request.awaitingTrailer = true
            else
                request.chunkSize = size
                request.chunkBytesRead = 0
            end
        end

        if request.chunkSize and request.chunkSize > 0 then
            local remaining = request.chunkSize - request.chunkBytesRead
            if remaining > 0 then
                local available = math.min(remaining, #request.readBuffer)
                if available > 0 then
                    local chunk = request.readBuffer:sub(1, available)
                    table.insert(request.responseBody, chunk)
                    request.chunkBytesRead = request.chunkBytesRead + available
                    request.receivedBodyBytes = request.receivedBodyBytes + available
                    request.readBuffer = request.readBuffer:sub(available + 1)
                end

                if request.chunkBytesRead < request.chunkSize then
                    return
                end

                request.expectingChunkTerminator = true
            end
        end
    end
end

local function handlePlainBody(request)
    if request.contentLength then
        local remaining = request.contentLength - request.receivedBodyBytes
        if remaining <= 0 then
            request.state = REQUEST_STATE.COMPLETE
            return
        end

        local toTake = math.min(remaining, #request.readBuffer)
        if toTake > 0 then
            local chunk = request.readBuffer:sub(1, toTake)
            table.insert(request.responseBody, chunk)
            request.receivedBodyBytes = request.receivedBodyBytes + toTake
            request.readBuffer = request.readBuffer:sub(toTake + 1)
        end

        if request.receivedBodyBytes >= request.contentLength then
            request.state = REQUEST_STATE.COMPLETE
        end
    else
        if #request.readBuffer > 0 then
            table.insert(request.responseBody, request.readBuffer)
            request.receivedBodyBytes = request.receivedBodyBytes + #request.readBuffer
            request.readBuffer = ''
        end
    end
end

local function processReceivedData(request, data)
    if not data then
        if request.state == REQUEST_STATE.RECEIVING_BODY then
            if not request.contentLength or request.receivedBodyBytes >= request.contentLength then
                request.state = REQUEST_STATE.COMPLETE
            else
                failRequest(request, 'Connection closed before body finished')
            end
        else
            failRequest(request, 'Connection closed unexpectedly')
        end
        completeRequest(request)
        return
    end

    request.readBuffer = request.readBuffer .. data

    if request.state == REQUEST_STATE.RECEIVING_STATUS then
        local line = processLine(request)
        if line then
            local code, message = parseStatusLine(line)
            if code then
                request.statusCode = code
                request.statusMessage = message
                request.state = REQUEST_STATE.RECEIVING_HEADERS
                log(request, 'Status: ' .. code .. ' ' .. (message or ''))
            else
                failRequest(request, 'Invalid status line: ' .. line)
                completeRequest(request)
                return
            end
        end
    end

    if request.state == REQUEST_STATE.RECEIVING_HEADERS then
        while true do
            local line = processLine(request)
            if not line then
                break
            end

            if line == '' then
                request.responseHeaders = parseHeaders(request.headerLines)

                if request.statusCode >= 300 and request.statusCode < 400 then
                    local location = request.responseHeaders['location']
                    if location then
                        request.redirectCount = request.redirectCount or 0

                        if request.redirectCount >= MAX_REDIRECTS then
                            failRequest(request, 'Too many redirects (max ' .. MAX_REDIRECTS .. ')')
                            completeRequest(request)
                            return
                        end

                        local newUrl = resolveRedirectUrl(request.url, location)
                        log(request, 'Redirecting to: ' .. newUrl)

                        request.redirectCount = request.redirectCount + 1
                        request.url = newUrl

                        local parsedUrl, err = parseURL(newUrl)
                        if not parsedUrl then
                            failRequest(request, 'Redirect URL parse error: ' .. err)
                            completeRequest(request)
                            return
                        end
                        request.parsedUrl = parsedUrl

                        cleanupRequest(request)
                        resetForRedirect(request)
                        startRequest(request)
                        return
                    else
                        failRequest(request, 'Redirect status but no Location header')
                        completeRequest(request)
                        return
                    end
                end

                request.state = REQUEST_STATE.RECEIVING_BODY
                request.contentLength = tonumber(request.responseHeaders['content-length'])
                local transferEncoding = request.responseHeaders['transfer-encoding']
                if transferEncoding and transferEncoding:lower():find('chunked', 1, true) then
                    request.isChunked = true
                    request.chunkSize = nil
                    request.chunkBytesRead = 0
                    request.awaitingTrailer = false
                else
                    request.isChunked = false
                end
                request.receivedBodyBytes = 0
                log(request, 'Headers complete, content-length: ' .. (request.contentLength or 'chunked'))
                break
            else
                table.insert(request.headerLines, line)
            end
        end
    end

    if request.state == REQUEST_STATE.RECEIVING_BODY then
        if request.isChunked then
            handleChunkedBody(request)
        else
            handlePlainBody(request)
        end

        if request.state == REQUEST_STATE.COMPLETE then
            completeRequest(request)
        end
    end
end

local function tryRead(request)
    if not request.socket then
        return
    end

    local data, err, partial = request.socket:receive(READ_CHUNK_SIZE)
    local chunk = data or partial

    if chunk and #chunk > 0 then
        processReceivedData(request, chunk)
    elseif err == 'closed' then
        processReceivedData(request, nil)
    elseif err ~= 'timeout' and err ~= 'wantread' then
        failRequest(request, 'Read error: ' .. (err or 'unknown'))
        completeRequest(request)
    end
end

local function tryWrite(request)
    if not request.socket then
        return
    end

    local remaining = request.requestData:sub(request.sentBytes + 1)
    if #remaining == 0 then
        request.state = REQUEST_STATE.RECEIVING_STATUS
        log(request, 'Request sent completely')
        return
    end

    local sent, err = request.socket:send(remaining)
    if sent then
        request.sentBytes = request.sentBytes + sent
        log(request, 'Sent ' .. sent .. ' bytes, total: ' .. request.sentBytes .. '/' .. #request.requestData)

        if request.sentBytes >= #request.requestData then
            request.state = REQUEST_STATE.RECEIVING_STATUS
            log(request, 'Request sent completely')
        end
    elseif err ~= 'timeout' and err ~= 'wantwrite' then
        failRequest(request, 'Write error: ' .. (err or 'unknown'))
        completeRequest(request)
    end
end

local function tryHandshake(request)
    if not request.socket then
        return
    end

    local result, err = request.socket:dohandshake()

    if result == 1 or result == true then
        log(request, 'SSL handshake complete')
        request.requestData = buildRequest(request.method, request.parsedUrl, request.headers, request.body)
        request.sentBytes = 0
        request.state = REQUEST_STATE.SENDING_REQUEST
    elseif err ~= 'timeout' and err ~= 'wantread' and err ~= 'wantwrite' then
        failRequest(request, 'SSL handshake failed: ' .. (err or 'unknown'))
        completeRequest(request)
    end
end

local tryConnect
local startPolling

local function onPollEvent(request, err, events)
    if request.cleaningUp or request.state == REQUEST_STATE.ERROR or request.state == REQUEST_STATE.COMPLETE then
        return
    end

    if err then
        failRequest(request, 'Poll error: ' .. err)
        completeRequest(request)
        return
    end

    log(request, 'Poll event in state: ' .. request.state)

    if request.state == REQUEST_STATE.CONNECTING then
        tryConnect(request)
    elseif request.state == REQUEST_STATE.SSL_HANDSHAKE then
        tryHandshake(request)
    elseif request.state == REQUEST_STATE.SENDING_REQUEST then
        tryWrite(request)
    elseif request.state == REQUEST_STATE.RECEIVING_STATUS or
        request.state == REQUEST_STATE.RECEIVING_HEADERS or
        request.state == REQUEST_STATE.RECEIVING_BODY then
        tryRead(request)
    end
end

startPolling = function (request)
    local fd = request.socket:getfd()
    if fd < 0 then
        failRequest(request, 'Invalid socket file descriptor')
        completeRequest(request)
        return
    end

    request.pollHandle = uv.new_socket_poll(fd)
    if not request.pollHandle then
        failRequest(request, 'Failed to create poll handle')
        completeRequest(request)
        return
    end

    local success, err = pcall(uv.poll_start, request.pollHandle, 'rw', function (poll_err, events)
        onPollEvent(request, poll_err, events)
    end)

    if not success then
        failRequest(request, 'Failed to start polling: ' .. tostring(err))
        completeRequest(request)
    end
end

tryConnect = function (request)
    if not request.socket then
        return
    end

    log(request, 'Attempting connection...')
    local result, err = request.socket:connect(request.resolvedIP, request.parsedUrl.port)

    log(request, 'Connect result: ' .. tostring(result) .. ', err: ' .. tostring(err))

    if result == 1 or err == 'already connected' then
        log(request, 'Connected to ' .. request.resolvedIP .. ':' .. request.parsedUrl.port)

        if request.parsedUrl.isSecure then
            local sslParams = {
                mode = 'client',
                protocol = 'any',
                options = { 'all', 'no_sslv2', 'no_sslv3', 'no_tlsv1', 'no_tlsv1_1' },
                verify = 'none',
                sni = request.parsedUrl.host
            }

            local sslSock, sslErr = ssl.wrap(request.socket, sslParams)
            if not sslSock then
                failRequest(request, 'SSL setup failed: ' .. (sslErr or 'unknown'))
                completeRequest(request)
                return
            end

            request.socket = sslSock
            pcall(function () sslSock:sni(request.parsedUrl.host) end)
            sslSock:settimeout(0)

            request.state = REQUEST_STATE.SSL_HANDSHAKE
            log(request, 'Starting SSL handshake')
        else
            request.requestData = buildRequest(request.method, request.parsedUrl, request.headers, request.body)
            request.sentBytes = 0
            request.state = REQUEST_STATE.SENDING_REQUEST
        end
    elseif err == 'timeout' then
        log(request, 'Connect timeout, setting up polling')
        if not request.pollHandle then
            startPolling(request)
        end
    else
        failRequest(request, 'Connection failed: ' .. (err or 'unknown'))
        completeRequest(request)
    end
end

local function connectToHost(request, ip)
    log(request, 'Connecting to ' .. ip .. ':' .. request.parsedUrl.port)

    request.socket = socket.tcp()
    if not request.socket then
        failRequest(request, 'Failed to create socket')
        completeRequest(request)
        return
    end

    request.socket:settimeout(0)
    request.resolvedIP = ip
    request.state = REQUEST_STATE.CONNECTING

    request.timeoutTimer = uv.new_timer()
    uv.timer_start(request.timeoutTimer, 15000, 0, function ()
        failRequest(request, 'Connection timeout')
        completeRequest(request)
    end)

    tryConnect(request)
end

function startRequest(request)
    if request.state ~= REQUEST_STATE.INIT then
        return
    end

    request.state = REQUEST_STATE.RESOLVING
    log(request, 'Resolving ' .. request.parsedUrl.host)

    uv.getaddrinfo(request.parsedUrl.host, nil, { socktype = 'stream' }, function (err, addresses)
        if err then
            failRequest(request, 'DNS resolution failed: ' .. err)
            completeRequest(request)
            return
        end

        if not addresses or #addresses == 0 then
            failRequest(request, 'No addresses found for host')
            completeRequest(request)
            return
        end

        local ip = addresses[1].addr
        log(request, 'Resolved to ' .. ip)
        connectToHost(request, ip)
    end)
end

local function enqueueRequest(method, url, headers, body, callback, options)
    if type(callback) ~= 'function' then
        error('Callback must be a function')
    end

    options = options or {}

    local parsedUrl, err = parseURL(url)
    if not parsedUrl then
        error(err)
    end

    local request = {
        id = nextRequestId,
        url = url,
        method = method,
        headers = headers,
        body = body,
        callback = callback,
        state = REQUEST_STATE.INIT,
        debug = options.debug or false,
        parsedUrl = parsedUrl,
        headerLines = {},
        responseBody = {},
        readBuffer = '',
        redirectCount = 0,
        sentBytes = 0,
        receivedBodyBytes = 0
    }

    activeRequests[nextRequestId] = request
    nextRequestId = nextRequestId + 1

    log(request, 'Queued request')
    startRequest(request)

    return request.id
end

function nonBlockingRequests.get(url, headers, callback, options)
    return enqueueRequest('GET', url, headers, nil, callback, options)
end

function nonBlockingRequests.post(url, body, headers, callback, options)
    return enqueueRequest('POST', url, headers, body, callback, options)
end

function nonBlockingRequests.cancel(requestId)
    local request = activeRequests[requestId]
    if request then
        cleanupRequest(request)
        activeRequests[requestId] = nil
        log(request, 'Cancelled request')
        return true
    end
    return false
end

function nonBlockingRequests.getActiveCount()
    local count = 0
    for _ in pairs(activeRequests) do
        count = count + 1
    end
    return count
end

function nonBlockingRequests.setDebug(enabled)
    DEBUG = enabled and true or false
    log('Global debug ' .. (DEBUG and 'enabled' or 'disabled'), nil, true)
end

function nonBlockingRequests.processAll()
    uv.run('nowait')
end

return nonBlockingRequests
