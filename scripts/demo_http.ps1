$ErrorActionPreference = 'Stop'

$log = Join-Path $PSScriptRoot '..\obj\http_server_demo.log'
$errorLog = Join-Path $PSScriptRoot '..\obj\http_server_demo.err.log'
$server = Start-Process -FilePath (Join-Path $PSScriptRoot '..\bin\http_server.exe') `
    -RedirectStandardOutput $log -RedirectStandardError $errorLog -PassThru

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ((-not (Test-Path $log)) -or
           -not (Select-String -Path $log -SimpleMatch 'listening on port' -Quiet)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw 'http_server did not announce readiness within 10 seconds'
        }
        Start-Sleep -Milliseconds 50
    }

    & (Join-Path $PSScriptRoot '..\bin\http_client.exe')
    exit $LASTEXITCODE
}
finally {
    if (-not $server.HasExited) {
        Stop-Process -Id $server.Id -Force
    }
}