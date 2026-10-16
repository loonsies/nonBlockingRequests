# Non-blocking HTTP(S) for Ashita v4

HTTP client that doesn't freeze your game. Makes requests in chunks during d3d_present.

## Setup

```lua
local http = require('nonBlockingRequests')

-- In your d3d_present event:
ashita.events.register('d3d_present', 'd3d_present_cb', function ()
    http.processAll()
end)
```

## Usage

```lua
-- GET request
http.get('https://api.example.com/data', nil, function(body, err, status)
    if err then
        print('Failed: ' .. err)
        return
    end
    print('Got: ' .. body)
end)

-- POST with headers
local headers = { ['Content-Type'] = 'application/json' }
http.post('https://api.example.com/submit', '{"test":true}', headers, function(body, err, status)
    -- handle response
end)
```

## Functions

**http.get(url, headers, callback)**
- `url`: string
- `headers`: table or nil
- `callback`: function(body, error, statusCode)
- Returns: request ID

**http.post(url, body, headers, callback)**
- Same as GET but with body parameter

**http.processAll()**
- Call this every frame in d3d_present

**http.cancel(requestId)**
- Cancel a request by ID

**http.getActiveCount()**
- Returns number of active requests

## Notes

- Supports HTTP and HTTPS
- Handles multiple concurrent requests

That's it. Just make sure to call processAll() regularly.

## Standalone tests on Windows

From the repo root, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

The suite uses Ashita's MoonJIT and installed socket libraries against local HTTP
and HTTPS servers. See [tests/README.md](tests/README.md) for setup and options.
