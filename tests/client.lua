-- Run each case in a fresh MoonJIT process.
local directory = arg[0]:match('^(.*[/\\])') or './'
local socket, ssl = dofile(directory .. 'bootstrap.lua')(assert(arg[1]))
local library, target = assert(arg[2]), assert(arg[3])
local total, concurrency = tonumber(arg[4]), tonumber(arg[5])
local kind = arg[6] or 'get'

local metrics = {
    sendCalls = 0, sendRetries = 0, partialSends = 0, partialLines = 0,
    handshakeRetries = 0, maxSendMs = 0, maxFrameMs = 0, peakActive = 0,
    unexpectedCallbacks = 0
}
local sendErrors, results, ids = {}, {}, {}
local hooked = {}
local function instrument(sock)
    local methods = getmetatable(sock).__index
    if hooked[methods] then return end
    hooked[methods] = true
    local send, receive, handshake = methods.send, methods.receive, methods.dohandshake
    methods.send = function (self, data, first, last)
        local begin = socket.gettime()
        local sent, err, partial = send(self, data, first, last)
        metrics.maxSendMs = math.max(metrics.maxSendMs, (socket.gettime() - begin) * 1000)
        metrics.sendCalls = metrics.sendCalls + 1
        if err then sendErrors[err] = (sendErrors[err] or 0) + 1 end
        if err == 'timeout' or err == 'wantread' or err == 'wantwrite' then
            metrics.sendRetries = metrics.sendRetries + 1
        end
        if partial and partial >= (first or 1) then metrics.partialSends = metrics.partialSends + 1 end
        return sent, err, partial
    end
    methods.receive = function (self, pattern, prefix)
        local data, err, partial = receive(self, pattern, prefix)
        if pattern == '*l' and not data and partial and #partial > 0 then
            metrics.partialLines = metrics.partialLines + 1
        end
        return data, err, partial
    end
    if handshake then
        methods.dohandshake = function (self)
            local ok, err = handshake(self)
            if err == 'wantread' or err == 'wantwrite' then
                metrics.handshakeRetries = metrics.handshakeRetries + 1
            end
            return ok, err
        end
    end
end
local tcp = socket.tcp
socket.tcp = function (...)
    local sock, err = tcp(...)
    if sock then instrument(sock) end
    return sock, err
end
local wrap = ssl.wrap
ssl.wrap = function (tcpSocket, params)
    if kind == 'backpressure' then assert(tcpSocket:setoption('send-buffer-size', 1024)) end
    local sock, err = wrap(tcpSocket, params)
    if sock then instrument(sock) end
    return sock, err
end

local http = assert(loadfile(library))()
local started, completed = 0, 0
local cancelledId
local function enqueue()
    started = started + 1
    local id
    local callback = function (body, err, status)
        if not ids[id] then metrics.unexpectedCallbacks = metrics.unexpectedCallbacks + 1 end
        ids[id] = nil
        completed = completed + 1
        results[#results + 1] = {
            id = id, body = body and body:sub(1, 1024), bodyBytes = body and #body,
            error = err, status = status
        }
    end
    if kind == 'backpressure' or kind == 'post' then
        local body = kind == 'backpressure' and
            (string.rep('A', 8000) .. string.rep('B', 8000) .. string.rep('C', 8000)) or 'hello=Ashita'
        id = http.post(target, body, { ['X-Test'] = 'standalone' }, callback)
    else
        id = http.get(target, { ['X-Test'] = 'standalone' }, callback)
    end
    ids[id] = true
end

if kind == 'cancel' then
    cancelledId = http.get(target, nil, function ()
        metrics.unexpectedCallbacks = metrics.unexpectedCallbacks + 1
    end)
    -- Cancel after the request has created its socket.
    http.processAll()
    assert(http.cancel(cancelledId) == true)
    assert(http.cancel(cancelledId) == false)
    assert(http.getActiveCount() == 0)
end

local begin = socket.gettime()
while completed < total and socket.gettime() - begin < 12 do
    while started < total and http.getActiveCount() < concurrency do enqueue() end
    metrics.peakActive = math.max(metrics.peakActive, http.getActiveCount())
    local frame = socket.gettime()
    http.processAll()
    local elapsed = socket.gettime() - frame
    metrics.maxFrameMs = math.max(metrics.maxFrameMs, elapsed * 1000)
    socket.sleep(math.max(0, 1 / 60 - elapsed))
end
local timedOut = completed < total
for id in pairs(ids) do http.cancel(id) end
for _ = 1, 3 do http.processAll() end

local function json(value)
    local t = type(value)
    if t == 'string' then
        return '"' .. value:gsub('[%z\1-\31\127-\255\\"]', function (c)
            return string.format('\\u%04x', c:byte())
        end) .. '"'
    elseif t == 'number' or t == 'boolean' then return tostring(value)
    elseif t == 'table' then
        local parts = {}
        if value == results then
            for _, item in ipairs(value) do parts[#parts + 1] = json(item) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        for key, item in pairs(value) do parts[#parts + 1] = json(key) .. ':' .. json(item) end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return 'null'
end
print('TEST_RESULT ' .. json({
    environment = { vm = jit.version, arch = jit.arch, socket = socket._VERSION, ssl = ssl._VERSION },
    completed = completed, started = started,
    activeAfterCleanup = http.getActiveCount(), timedOut = timedOut,
    elapsed = socket.gettime() - begin, metrics = metrics, sendErrors = sendErrors,
    results = results
}))
