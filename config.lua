local settings = require('settings')

local config = {}

local default = T {
    server = ''
}

config.load = function ()
    return settings.load(default)
end

return config
