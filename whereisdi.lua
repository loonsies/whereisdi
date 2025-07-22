addon.name = 'whereisdi'
addon.version = '0.1'
addon.author = 'looney'
addon.desc = 'If you\'re that lazy...'
addon.link = 'https://github.com/loonsies/whereisdi'

require 'common'
local settings = require('settings')
local config = require('config')
local chat = require('chat')
local json = require('json')
local http = require('socket.http')
local ltn12 = require('socket.ltn12')

local token = 'Bearer 82j1GCjQxUCxriN-XhXicb6Ts8G400l7'
local cfg = {}

local function getBaseUrl(url)
    return url:match('^(https?://[^/]+)')
end

local function fetchDiApi()
    local response_body = {}
    local _, status = http.request {
        url = 'https://api.whereisdi.com/items/di?fields=*.*',
        method = 'GET',
        headers = {
            ['Authorization'] = token,
            ['Accept'] = 'application/json'
        },
        sink = ltn12.sink.table(response_body)
    }
    if status ~= 200 then
        print(chat.header(addon.name):append(chat.error('API HTTP error: ' .. tostring(status))))
        return nil
    end
    return table.concat(response_body)
end

local function iso8601_to_unix(str)
    if type(str) ~= 'string' then
        return nil
    end
    local year, month, day, hour, min, sec = str:match('^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)')
    year = tonumber(year) or 1970
    month = tonumber(month) or 1
    day = tonumber(day) or 1
    hour = tonumber(hour) or 0
    min = tonumber(min) or 0
    sec = tonumber(sec) or 0
    return os.time({
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = min,
        sec = sec,
        isdst = false
    })
end

local function printStatus(filter_server)
    local raw = fetchDiApi()
    if not raw then return end
    local decoded, _, err = json.decode(raw)
    if not decoded or not decoded.data then
        print(chat.header(addon.name):append(chat.error('JSON decode failed: ' .. tostring(err))))
        return
    end

    local found = false
    for _, entry in ipairs(decoded.data) do
        local server = entry.server and entry.server.name or 'Unknown'
        if not filter_server or (server:lower() == filter_server:lower()) then
            found = true
            local status = '(no info)'
            if type(entry.location) == 'table' and entry.location.en_us then
                status = entry.location.en_us
            end

            local ago = ''
            if entry.date_updated then
                local updated_unix = iso8601_to_unix(entry.date_updated)
                if updated_unix then
                    local now = os.time(os.date('!*t')) -- UTC
                    local diff = now - updated_unix
                    if diff < 60 then
                        ago = '(just now)'
                    else
                        local mins = math.floor(diff / 60)
                        ago = string.format('(%d minute%s ago)', mins, mins == 1 and '' or 's')
                    end
                end
            end

            print(chat.header(addon.name):append(chat.message(('%s: %s %s'):format(server, status, ago))))
        end
    end
    if filter_server and not found then
        print(chat.header(addon.name):append(chat.error('No info found for server: ' .. filter_server)))
    end
end

local function fetchUrl(url)
    local maxRedirects = 5
    local redirects = 0

    while redirects < maxRedirects do
        local response_body = {}
        local _, statusCode, headers = http.request {
            url = url,
            sink = ltn12.sink.table(response_body)
        }

        local body = table.concat(response_body)

        if not body then
            print(chat.header(addon.name):append(chat.error('HTTP request failed')))
            return nil, statusCode, headers
        end

        if statusCode >= 300 and statusCode < 400 then
            local location = headers.location
            if type(location) ~= 'string' then
                print(chat.header(addon.name):append(chat.error('Redirect status but no Location header')))
                return nil, statusCode, headers
            end

            if not location:match('^https?://') then
                local base = getBaseUrl(url)
                location = base .. location
            end

            url = location
            redirects = redirects + 1
        else
            return body, statusCode, headers
        end
    end

    print(chat.header(addon.name):append(chat.error('Too many redirections')))
    return nil, nil, nil
end


ashita.events.register('command', 'command_cb', function (cmd, nType)
    local args = cmd.command:args()
    if #args == 0 then
        return
    end

    local command = string.lower(args[1])
    if command == '/whereisdi' or command == '/di' then
        if #args >= 2 and string.lower(args[2]) == 'all' then
            printStatus()
            return
        elseif #args >= 3 and string.lower(args[2]) == 'setserver' then
            local serverName = table.concat(args, ' ', 3)
            if serverName and #serverName > 0 then
                cfg.server = serverName
                settings.save()
                print(chat.header(addon.name):append(chat.message('Server set to: ' .. serverName)))
            else
                print(chat.header(addon.name):append(chat.error('Usage: /di setserver <ServerName>')))
            end
            return
        end

        if not cfg.server or cfg.server == '' then
            print(chat.header(addon.name):append(chat.error('No server set. Use /di setserver <ServerName>')))
            return
        end

        printStatus(cfg.server)
    end
end)


ashita.events.register('load', 'load_cb', function ()
    cfg = config.load()

    settings.register('settings', 'settings_update_cb', function (newConfig)
        cfg = newConfig
    end)
end)
