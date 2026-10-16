[CmdletBinding()]
param(
    [string]$AshitaPath = 'C:\Ashita',
    [string[]]$LiveUrl = @(),
    [string]$OpenSslPath,
    [string]$LibraryPath,
    [string]$OutputPath,
    [string]$Case = '*'
)

$ErrorActionPreference = 'Stop'
try {
    $repo = Split-Path $PSScriptRoot -Parent
    if (-not $LibraryPath) { $LibraryPath = Join-Path $repo 'nonBlockingRequests.lua' }
    if (-not $OutputPath) { $OutputPath = Join-Path $repo 'test-results' }
    & (Join-Path $PSScriptRoot 'setup-runtime.ps1') -AshitaPath $AshitaPath
    $runner = Join-Path $repo '.test-runtime\moonjit\src\luajit.exe'

    if (-not $OpenSslPath) {
        $openssl = Get-Command openssl.exe -ErrorAction SilentlyContinue
        if ($openssl) {
            $OpenSslPath = $openssl.Source
        } else {
            $git = Get-Command git.exe -ErrorAction Stop
            $gitRoot = Split-Path (Split-Path $git.Source -Parent) -Parent
            $OpenSslPath = Join-Path $gitRoot 'usr\bin\openssl.exe'
        }
    }
    if (-not (Test-Path -LiteralPath $OpenSslPath -PathType Leaf)) {
        throw 'OpenSSL was not found. Install Git for Windows or pass -OpenSslPath.'
    }

    $arguments = @(
        (Join-Path $PSScriptRoot 'run.py'),
        '--lua', $runner,
        '--ashita', (Resolve-Path -LiteralPath $AshitaPath).Path,
        '--library', (Resolve-Path -LiteralPath $LibraryPath).Path,
        '--openssl', $OpenSslPath,
        '--output', $OutputPath,
        '--case', $Case
    )
    foreach ($url in $LiveUrl) { $arguments += @('--live-url', $url) }

    if (Get-Command py.exe -ErrorAction SilentlyContinue) {
        & py.exe -3 @arguments
    } elseif (Get-Command python.exe -ErrorAction SilentlyContinue) {
        & python.exe @arguments
    } else {
        throw 'Python 3.9 or newer is required (standard library only).'
    }
    exit $LASTEXITCODE
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 2
}
