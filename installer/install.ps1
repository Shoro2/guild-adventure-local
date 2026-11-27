# Guild Adventure: one-click installer for a single player on one Windows PC.
#
# Started by Install.cmd. It asks for your World of Warcraft 3.3.5a client (build 12340), downloads the Guild
# Adventure server and MySQL, extracts the server data from your client, sets up the databases, your account and the
# configs, puts the addon into the client and points the client's realmlist at 127.0.0.1. Everything else goes into
# one folder (default: "game" beside this repository). A run that was stopped goes on where it stopped.
#
#   .\installer\install.ps1                                  # asks what it needs
#   .\installer\install.ps1 -Client "D:\WoW 3.3.5a" -Account ME -Password secret
#
# -DataDir <folder> uses server data you already have (the folders dbc, maps, vmaps and mmaps of an AzerothCore server
# for 3.3.5a) instead of extracting it from your client; the folder is used where it is and never changed.
#
# Options for testing: -Package <server zip> and -MySqlZip <zip> use local files instead of the downloads, -MySqlRoot
# uses an installed MySQL 8.4 as it is (its own data folder still lies in the install folder).

param(
    [string] $Client = '',
    [string] $InstallDir = '',
    [string] $Package = '',
    [string] $MySqlZip = '',
    [string] $MySqlRoot = '',
    [string] $Account = '',
    [string] $Password = '',
    [string] $DataDir = '',
    [int] $Threads = 0,
    # Ports to start the search for a free one at (defaults: the game's 3724 and 8085, MySQL's 3306, SOAP 7878).
    [int] $AuthPort = 3724,
    [int] $WorldPort = 8085,
    [int] $DbPort = 3306,
    [int] $SoapPort = 7878,
    [switch] $NoShortcut,
    [switch] $NoStart
)

. "$PSScriptRoot\common.ps1"

if (-not $InstallDir) { $InstallDir = Join-Path $GaRepo 'game' }
New-Item -ItemType Directory -Force $InstallDir | Out-Null
$InstallDir = (Resolve-Path $InstallDir).Path
$downloads = Join-Path $InstallDir 'downloads'
New-Item -ItemType Directory -Force $downloads | Out-Null

# --- the installation's settings: new, or the ones of a run that stopped --------------------------------------------
$stateFile = Join-Path $InstallDir 'guild-adventure.json'
if (Test-Path $stateFile) { $inst = Get-GaInstall $InstallDir }
else
{
    $inst = [pscustomobject]@{
        Dir       = $InstallDir
        Version   = $GaRelease.version
        Client    = ''
        MySqlRoot = ''
        Ports     = $null
        Db        = [pscustomobject]@{ Auth = 'ga_auth'; World = 'ga_world'; Characters = 'ga_characters'; Playerbots = 'ga_playerbots'
                                       User = 'guildadventure'; Password = (New-GaSecret); RootPassword = (New-GaSecret) }
        Soap      = [pscustomobject]@{ User = 'GASOAP'; Password = (New-GaSecret 12) }
        Player    = ''
        Done      = @()
    }
    Save-GaInstall $inst
}

# --- 1. the client ---------------------------------------------------------------------------------------------------
Write-Step 'Your World of Warcraft 3.3.5a client'
if (-not $Client) { $Client = $inst.Client }
if (-not $Client)
{
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the folder of your World of Warcraft 3.3.5a client (the folder with Wow.exe)'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw 'No client folder chosen' }
    $Client = $dlg.SelectedPath
}
$wow = Join-Path $Client 'Wow.exe'
if (-not (Test-Path $wow)) { throw "No Wow.exe in $Client" }
$ver = (Get-Item $wow).VersionInfo
if ("$($ver.FileMajorPart).$($ver.FileMinorPart).$($ver.FileBuildPart).$($ver.FilePrivatePart)" -ne '3.3.5.12340')
{
    throw "Wow.exe in $Client is version $($ver.FileVersion); Guild Adventure needs 3.3.5a (build 12340)"
}
$locales = @(Get-ChildItem (Join-Path $Client 'Data') -Directory | Where-Object { $_.Name -match '^[a-z]{2}[A-Z]{2}$' })
if (-not $locales) { throw "No locale folder (for example enUS) in $(Join-Path $Client 'Data')" }
$inst.Client = (Resolve-Path $Client).Path
Write-Host "client: $($inst.Client) ($(($locales | ForEach-Object Name) -join ', '))"

# --- 2. ports --------------------------------------------------------------------------------------------------------
if (-not $inst.Ports)
{
    $auth = Get-FreePort $AuthPort
    $world = Get-FreePort $WorldPort @($auth)
    $soap = Get-FreePort $SoapPort @($auth, $world)
    $db = Get-FreePort $DbPort @($auth, $world, $soap)
    $inst.Ports = [pscustomobject]@{ Auth = $auth; World = $world; Soap = $soap; Db = $db }
}
Save-GaInstall $inst
Write-Host "ports: login $($inst.Ports.Auth), world $($inst.Ports.World), database $($inst.Ports.Db) (all on 127.0.0.1)"

# Server data you already have: checked here, used where it is (worldserver.conf's DataDir points at it).
if ($DataDir)
{
    if (-not (Test-Path $DataDir)) { throw "No folder $DataDir" }
    $DataDir = (Resolve-Path $DataDir).Path
    foreach ($need in @(@('dbc', '*.dbc'), @('maps', '*.map'), @('vmaps', '*.vmtree'), @('mmaps', '*.mmap')))
    {
        if (-not (Get-ChildItem (Join-Path $DataDir $need[0]) -Filter $need[1] -ErrorAction SilentlyContinue | Select-Object -First 1))
        {
            throw "$DataDir has no $($need[0]) folder with $($need[1]) files: give the folder that holds dbc, maps, vmaps and mmaps"
        }
    }
    $inst | Add-Member -NotePropertyName DataDir -NotePropertyValue $DataDir -Force
    Save-GaInstall $inst
}
$ownData = -not $inst.DataDir

$free = (Get-PSDrive -Name $InstallDir.Substring(0, 1)).Free
$needFree = if ($ownData -and -not (Test-GaStep $inst 'data')) { 8GB } else { 3GB }
if ($free -lt $needFree) { throw "The install folder's drive has $([int]($free / 1GB)) GB free; $($needFree / 1GB) GB are needed" }

# --- 3. Visual C++ runtime -------------------------------------------------------------------------------------------
Write-Step 'Visual C++ runtime'
$vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
if ($vc -and $vc.Installed -eq 1 -and [int]$vc.Major -ge 14) { Write-Host "present ($($vc.Version))" }
else
{
    $file = Join-Path $downloads 'vc_redist.x64.exe'
    Get-Checked $GaRelease.vcredist.url $file ''
    Write-Host 'installing (Windows asks for permission) ...'
    $p = Start-Process $file -ArgumentList '/install', '/quiet', '/norestart' -Verb RunAs -Wait -PassThru
    if ($p.ExitCode -notin 0, 1638, 3010) { throw "The Visual C++ runtime installer ended with code $($p.ExitCode)" }
}

# --- 4. the server ---------------------------------------------------------------------------------------------------
Write-Step 'Guild Adventure server'
$server = Join-Path $InstallDir 'server'
if (-not (Test-GaStep $inst 'server'))
{
    $zip = $Package
    if (-not $zip)
    {
        $zip = Join-Path $downloads $GaRelease.server.file
        Get-Checked $GaRelease.server.url $zip $GaRelease.server.sha256
    }
    if (Test-Path $server) { Get-ChildItem $server -Exclude 'Data' | Remove-Item -Recurse -Force }
    Expand-Into $zip $server
    Complete-GaStep $inst 'server'
}
Write-Host "server: $server"

# --- 5. MySQL --------------------------------------------------------------------------------------------------------
Write-Step 'MySQL'
if ($MySqlRoot) { $inst.MySqlRoot = (Resolve-Path $MySqlRoot).Path }
elseif (-not $inst.MySqlRoot -or -not (Test-Path (Join-Path $inst.MySqlRoot 'bin\mysqld.exe')))
{
    $zip = $MySqlZip
    if (-not $zip)
    {
        $zip = Join-Path $downloads $GaRelease.mysql.file
        Get-Checked $GaRelease.mysql.url $zip $GaRelease.mysql.sha256
    }
    $root = Join-Path $InstallDir 'mysql'
    Expand-Into $zip $root
    $inst.MySqlRoot = $root
}
Save-GaInstall $inst
Write-MySqlFiles $inst
if (-not (Test-GaStep $inst 'mysql'))
{
    $data = Join-Path $InstallDir 'db\data'
    if (Test-Path $data) { Remove-Item -Recurse -Force $data }
    $mysqld = Join-Path (Get-MySqlBin $inst) 'mysqld.exe'
    $ini = Join-Path $InstallDir 'db\my.ini'
    & $mysqld "--defaults-file=$ini" --initialize-insecure 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "MySQL could not create its data folder (see $(Join-Path $InstallDir 'db\mysqld.err'))" }
    Start-GaDatabase $inst
    $mysql = Join-Path (Get-MySqlBin $inst) 'mysql.exe'
    & $mysql -h 127.0.0.1 -P $inst.Ports.Db -u root --skip-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$($inst.Db.RootPassword)';"
    if ($LASTEXITCODE -ne 0) { throw 'Could not set the MySQL root password' }
    $sql = "CREATE USER IF NOT EXISTS '$($inst.Db.User)'@'localhost' IDENTIFIED BY '$($inst.Db.Password)';"
    foreach ($name in @($inst.Db.Auth, $inst.Db.World, $inst.Db.Characters, $inst.Db.Playerbots))
    {
        $sql += " CREATE DATABASE IF NOT EXISTS ``$name`` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        $sql += " GRANT ALL PRIVILEGES ON ``$name``.* TO '$($inst.Db.User)'@'localhost';"
    }
    Invoke-GaSql $inst $sql | Out-Null
    Complete-GaStep $inst 'mysql'
}
else { Start-GaDatabase $inst }
Write-Host "MySQL: $($inst.MySqlRoot), data in $(Join-Path $InstallDir 'db\data')"

# --- 6. server data from the client ----------------------------------------------------------------------------------
Write-Step 'Server data from your client (maps, vmaps, mmaps; the mmaps take one to three hours)'
$dataDir = if ($ownData) { Join-Path $server 'Data' } else { $inst.DataDir }
if (-not $ownData) { Write-Host 'the server data you gave is used; nothing is extracted' }
elseif (-not (Test-GaStep $inst 'data'))
{
    New-Item -ItemType Directory -Force $dataDir | Out-Null
    Push-Location $dataDir
    try
    {
        if (-not (Test-GaStep $inst 'data-maps'))
        {
            & (Join-Path $server 'map_extractor.exe') -i $inst.Client
            if (-not (Get-ChildItem (Join-Path $dataDir 'maps') -Filter *.map -ErrorAction SilentlyContinue | Select-Object -First 1)) { throw 'map_extractor made no maps' }
            Complete-GaStep $inst 'data-maps'
        }
        if (-not (Test-GaStep $inst 'data-vmaps'))
        {
            & (Join-Path $server 'vmap4_extractor.exe') -d (Join-Path $inst.Client 'Data')
            New-Item -ItemType Directory -Force (Join-Path $dataDir 'vmaps') | Out-Null
            & (Join-Path $server 'vmap4_assembler.exe') Buildings vmaps
            if (-not (Get-ChildItem (Join-Path $dataDir 'vmaps') -Filter *.vmtree | Select-Object -First 1)) { throw 'vmap4_assembler made no vmaps' }
            Remove-Item -Recurse -Force (Join-Path $dataDir 'Buildings')
            Complete-GaStep $inst 'data-vmaps'
        }
        $n = if ($Threads -gt 0) { $Threads } else { [Math]::Max(1, [Environment]::ProcessorCount - 1) }
        & (Join-Path $server 'mmaps_generator.exe') --threads $n
        if (-not (Get-ChildItem (Join-Path $dataDir 'mmaps') -Filter *.mmap -ErrorAction SilentlyContinue | Select-Object -First 1)) { throw 'mmaps_generator made no mmaps' }
    }
    finally { Pop-Location }
    Complete-GaStep $inst 'data'
}
Write-Host "data: $dataDir"

# --- 7. configs, first start, accounts --------------------------------------------------------------------------------
Write-Step 'Configuration and the first start (the databases are filled: several minutes)'
Write-GaConfigs $inst
if (-not (Test-GaStep $inst 'world'))
{
    Start-GaServer $inst 'worldserver' $inst.Ports.World 3600
    Invoke-GaSql $inst ("UPDATE realmlist SET name = 'Guild Adventure', address = '127.0.0.1', localAddress = '127.0.0.1', " +
        "port = $($inst.Ports.World) WHERE id = 1;") $inst.Db.Auth | Out-Null
    New-GaAccount $inst $inst.Soap.User $inst.Soap.Password 3
    Complete-GaStep $inst 'world'
}
if (-not (Test-GaStep $inst 'account'))
{
    Write-Step 'Your account'
    if (-not $Account) { $Account = Read-Host 'Account name (letters and digits, at most 16)' }
    if (-not $Password)
    {
        $secure = Read-Host 'Password (at most 16 characters)' -AsSecureString
        $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    }
    New-GaAccount $inst $Account $Password 0
    $inst.Player = $Account.ToUpperInvariant()
    Complete-GaStep $inst 'account'
}

# --- 8. the client: addon and realmlist -------------------------------------------------------------------------------
Write-Step 'Addon and realmlist in your client'
$addonSrc = Join-Path $server 'addon\GuildAdventure'
$addonDst = Join-Path $inst.Client 'Interface\AddOns\GuildAdventure'
if (Test-Path $addonDst) { Remove-Item -Recurse -Force $addonDst }
New-Item -ItemType Directory -Force (Split-Path $addonDst) | Out-Null
Copy-Item -Recurse $addonSrc $addonDst
foreach ($loc in $locales)
{
    $rl = Join-Path $loc.FullName 'realmlist.wtf'
    $backup = "$rl.before-guild-adventure"
    if ((Test-Path $rl) -and -not (Test-Path $backup)) { Copy-Item $rl $backup }
    "set realmlist 127.0.0.1:$($inst.Ports.Auth)" | Set-Content $rl -Encoding ascii
}
Write-Host "addon: $addonDst; realmlist: 127.0.0.1:$($inst.Ports.Auth) (the old one saved as realmlist.wtf.before-guild-adventure)"

if (-not $NoShortcut)
{
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Guild Adventure.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = Join-Path $GaRepo 'Start.cmd'
    $s.WorkingDirectory = $GaRepo
    $s.IconLocation = "$wow,0"
    $s.Save()
    Write-Host "desktop shortcut: $lnk"
}
Complete-GaStep $inst 'done'

Write-Step 'Done'
Write-Host "Start the game with Start.cmd (or the desktop shortcut), stop the server with Stop.cmd."
Write-Host "Log in with account $($inst.Player). Your first character on it becomes the guild leader."
if ($NoStart) { Stop-GaServers $inst; Stop-GaDatabase $inst }
else { & (Join-Path $PSScriptRoot 'control.ps1') -Action Start -InstallDir $InstallDir }
