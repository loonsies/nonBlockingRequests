[CmdletBinding()]
param([string]$AshitaPath = 'C:\Ashita')

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$runtime = Join-Path $repo '.test-runtime'
$source = Join-Path $runtime 'moonjit'
$runner = Join-Path $source 'src\luajit.exe'
$manifestPath = Join-Path $runtime 'build.json'
$bootstrapVersion = 1

foreach ($relative in @('plugins\addons.dll', 'addons\libs\socket.lua', 'addons\libs\socket\ssl.lua', 'addons\libs\socket\ssl.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $AshitaPath $relative) -PathType Leaf)) {
        throw "Missing Ashita dependency: $relative (under $AshitaPath)"
    }
}

$null = Get-Command git.exe -ErrorAction Stop
$remote = 'https://github.com/AshitaXI/moonjit.git'
$head = & git ls-remote $remote HEAD
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^([0-9a-f]{40})\s+HEAD$') {
    throw 'Could not resolve the latest Ashita MoonJIT commit.'
}
$revision = $Matches[1]

if ((Test-Path -LiteralPath $runner) -and (Test-Path -LiteralPath $manifestPath)) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.revision -eq $revision -and $manifest.bootstrapVersion -eq $bootstrapVersion) {
        Write-Host 'Using cached Ashita MoonJIT x86 runner.'
        return
    }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Install Visual Studio Build Tools with Desktop development with C++ (x86 tools and Windows SDK).'
}
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudio) { throw 'Visual Studio C++ x86 build tools were not found.' }
$vcvars = Join-Path $visualStudio 'VC\Auxiliary\Build\vcvars32.bat'

$null = New-Item -ItemType Directory -Force -Path $runtime
if (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) {
    & git clone --quiet --depth 1 --no-checkout $remote $source
    if ($LASTEXITCODE -ne 0) { throw 'Could not clone Ashita MoonJIT.' }
}
& git -C $source fetch --quiet --depth 1 origin $revision
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch the latest MoonJIT revision.' }
& git -C $source reset --quiet --hard $revision
if ($LASTEXITCODE -ne 0) { throw 'Could not check out the latest MoonJIT revision.' }

# The standalone runner loads socket.core from Ashita's addons.dll.
$initPath = Join-Path $source 'src\lib_init.c'
$init = Get-Content -LiteralPath $initPath
$init = $init | Where-Object {
    $_ -notmatch '../../luaex/' -and
    $_ -notmatch 'luaopen_(struct|lsqlite3|socket_core|mime_core)'
}
[IO.File]::WriteAllLines($initPath, $init, [Text.UTF8Encoding]::new($false))

# Let the build script run tools from its working directory.
$buildPath = Join-Path $runtime 'build.cmd'
$build = @"
@echo off
setlocal
set NoDefaultCurrentDirectoryInExePath=
call "$($vcvars.Replace('%', '%%'))"
if errorlevel 1 exit /b 1
cd /d "$((Join-Path $source 'src').Replace('%', '%%'))"
call .\msvcbuild.bat
"@
[IO.File]::WriteAllText($buildPath, $build, [Text.UTF8Encoding]::new($false))
$logPath = Join-Path $runtime 'build.log'
Write-Host "Building Ashita MoonJIT x86; build log: $logPath"
# Keep compiler stderr in its own log.
$process = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', "`"$buildPath`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput $logPath -RedirectStandardError (Join-Path $runtime 'build.stderr.log')
$process.WaitForExit()
if (-not (Test-Path -LiteralPath $runner) -or
    -not (Select-String -LiteralPath $logPath -SimpleMatch 'Successfully built LuaJIT for Windows/x86' -Quiet)) {
    throw "MoonJIT build failed. See $logPath and build.stderr.log."
}
$smokePath = Join-Path $runtime 'smoke.lua'
[IO.File]::WriteAllText($smokePath, 'assert(jit.arch == "x86"); print(jit.version)', [Text.UTF8Encoding]::new($false))
& $runner $smokePath
if ($LASTEXITCODE -ne 0) { throw 'Built runner failed its x86 smoke check.' }
@{
    revision = $revision
    bootstrapVersion = $bootstrapVersion
    visualStudio = $visualStudio
    architecture = 'x86'
} | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
