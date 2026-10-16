# Standalone tests

Run these from the repo root on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

The first run builds the latest commit of Ashita's x86 MoonJIT fork and caches it
in `.test-runtime`. Each run checks for a newer commit and rebuilds if needed.
The Lua tests load LuaSocket and LuaSec from your Ashita installation (default
`C:\Ashita`). Python provides local HTTP and HTTPS servers. The game does not
need to be running.

You'll need Git for Windows (including OpenSSL), Python 3.9+, and Visual Studio
or Build Tools with C++ x86 tools and a Windows SDK. The first build also needs
internet access. Each run also needs access to check for updates.

A few useful options:

```powershell
.\tests\run-tests.ps1 -AshitaPath D:\Ashita
.\tests\run-tests.ps1 -Case 'https_split*'
.\tests\run-tests.ps1 -LibraryPath C:\work\candidate.lua -OutputPath .\test-results\candidate
.\tests\run-tests.ps1 -Case 'live_*' -LiveUrl 'https://www.playonline.com/ff11us/', 'https://google.com'
```

Live tests only run with `-LiveUrl`.

The local suite checks response bodies, redirects, chunking, POSTs, concurrency,
cancellation, and errors. It also splits status lines, headers, and chunk sizes
across writes, and slows a server's reads to force a send retry. Each case uses
real sockets and a fresh MoonJIT process.

The split status/header/chunk-size and backpressure cases cover partial reads
and writes.

Results go to `test-results/`: `results.json`, `junit.xml`, and a log per case.
The runner records the hashes of the library, VM, and Ashita DLLs. This is a
rebuild of the latest commit of [Ashita's MoonJIT fork](https://github.com/AshitaXI/moonjit);
it loads the installed socket DLLs, but it isn't the exact VM binary inside
`addons.dll`.
