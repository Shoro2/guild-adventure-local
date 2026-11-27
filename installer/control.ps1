# Starts or stops the local Guild Adventure server (Start.cmd, Stop.cmd).
#
#   .\installer\control.ps1                    # start MySQL, the login and the world server, then the client
#   .\installer\control.ps1 -Action Stop       # save and stop everything
#   .\installer\control.ps1 -Action Status

param(
    [ValidateSet('Start', 'Stop', 'Status')] [string] $Action = 'Start',
    [string] $InstallDir = '',
    [switch] $NoClient
)

. "$PSScriptRoot\common.ps1"
if (-not $InstallDir) { $InstallDir = Join-Path $GaRepo 'game' }
$inst = Get-GaInstall (Resolve-Path $InstallDir).Path
if (@($inst.Done) -notcontains 'done') { throw 'The installation is not finished: run Install.cmd again' }

switch ($Action)
{
    'Start'
    {
        Write-Step 'Starting Guild Adventure'
        Start-GaDatabase $inst
        Start-GaServer $inst 'authserver' $inst.Ports.Auth 60
        Write-Host 'world server: starting (about a minute) ...'
        Start-GaServer $inst 'worldserver' $inst.Ports.World 900
        Write-Host "running: login 127.0.0.1:$($inst.Ports.Auth), world 127.0.0.1:$($inst.Ports.World)"
        if (-not $NoClient) { Start-Process (Join-Path $inst.Client 'Wow.exe') -WorkingDirectory $inst.Client }
    }
    'Stop'
    {
        Write-Step 'Stopping Guild Adventure'
        Stop-GaServers $inst
        Stop-GaDatabase $inst
        Write-Host 'stopped'
    }
    'Status'
    {
        foreach ($p in @(@('database', $inst.Ports.Db), @('login', $inst.Ports.Auth), @('world', $inst.Ports.World)))
        {
            Write-Host ("{0,-9} port {1}: {2}" -f $p[0], $p[1], $(if (Test-PortFree $p[1]) { 'stopped' } else { 'running' }))
        }
    }
}
