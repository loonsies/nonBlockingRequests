-- Load the socket libraries installed with Ashita.
return function (ashitaPath)
    ashitaPath = ashitaPath:gsub('\\', '/')
    package.path = ashitaPath .. '/addons/libs/?.lua;' .. package.path
    string.fmt = string.format
    AshitaCore = { GetInstallPath = function () return ashitaPath end }
    package.preload['socket.core'] = assert(package.loadlib(
        ashitaPath .. '/plugins/addons.dll', 'luaopen_socket_core'))
    local socket = require('socket')
    local ssl = require('socket.ssl')
    assert(jit.arch == 'x86', 'Ashita native modules require x86 MoonJIT')
    return socket, ssl
end
