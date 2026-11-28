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
# Before anything is downloaded it asks whether you already have the server data (the folders dbc, maps, vmaps and
# mmaps of an AzerothCore server for 3.3.5a); that folder is used where it is and never changed, else the data is
# extracted from your client. -DataDir <folder> gives the folder without asking, -Extract extracts without asking.
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
    [switch] $Extract,
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
# MySQL and the extractors take their paths in the system's code page: letters outside ASCII in the install folder's
# path (Cyrillic, umlauts, accents) break them.
if ($InstallDir -match '[^\x20-\x7E]')
{
    throw ("The install folder $InstallDir has letters outside A-Z in its path, which MySQL cannot use. Put this " +
        "folder somewhere like C:\Games\GuildAdventure and run Install.cmd there, or give another folder with " +
        "Install.cmd -InstallDir `"C:\Games\GuildAdventure\game`".")
}
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

# Server data you already have: asked for (unless -DataDir or -Extract says it), checked here, used where it is
# (worldserver.conf's DataDir points at it). Without it the server data is extracted from your client in step 6.
function Test-GaDataDir([string] $Dir)
{
    # $null when $Dir holds the server data, else why not.
    if (-not $Dir -or -not (Test-Path $Dir)) { return "There is no folder $Dir." }
    foreach ($need in @(@('dbc', '*.dbc'), @('maps', '*.map'), @('vmaps', '*.vmtree'), @('mmaps', '*.mmap')))
    {
        if (-not (Get-ChildItem (Join-Path $Dir $need[0]) -Filter $need[1] -ErrorAction SilentlyContinue | Select-Object -First 1))
        {
            return "$Dir has no folder $($need[0]) with $($need[1]) files. Choose the folder that holds dbc, maps, vmaps and mmaps."
        }
    }
    return $null
}

if (-not $DataDir -and -not $Extract -and -not $inst.DataDir -and -not $inst.DataAsked -and -not (Test-GaStep $inst 'data'))
{
    Write-Step 'Server data'
    Add-Type -AssemblyName System.Windows.Forms
    $top = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }   # keeps the dialogs in front of the console
    $question = "Do you already have the server data of an AzerothCore server for 3.3.5a (a folder with dbc, maps, " +
        "vmaps and mmaps)?`n`nYes: choose that folder; it is used where it is and never changed.`n" +
        "No: the data is extracted from your client, which takes one to three hours."
    while ($true)
    {
        $answer = [System.Windows.Forms.MessageBox]::Show($top, $question, 'Guild Adventure', 'YesNo', 'Question')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { break }
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose the folder with your server data (it holds dbc, maps, vmaps and mmaps)'
        if ($dlg.ShowDialog($top) -ne [System.Windows.Forms.DialogResult]::OK) { continue }
        $why = Test-GaDataDir $dlg.SelectedPath
        if (-not $why) { $DataDir = $dlg.SelectedPath; break }
        [void][System.Windows.Forms.MessageBox]::Show($top, $why, 'Guild Adventure', 'OK', 'Warning')
    }
    $top.Dispose()
    $inst | Add-Member -NotePropertyName DataAsked -NotePropertyValue $true -Force
    Save-GaInstall $inst
    if (-not $DataDir) { Write-Host 'the server data will be extracted from your client' }
}
if ($DataDir)
{
    $why = Test-GaDataDir $DataDir
    if ($why) { throw $why }
    $DataDir = (Resolve-Path $DataDir).Path
    $inst | Add-Member -NotePropertyName DataDir -NotePropertyValue $DataDir -Force
    Save-GaInstall $inst
    Write-Host "server data: $DataDir (used where it is)"
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
    Get-Checked (Get-ReleaseUrls $GaRelease.vcredist) $file '' ('Install the Visual C++ Redistributable for Visual Studio 2015-2022 (x64) from Microsoft yourself, then run Install.cmd again.')
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
        Get-Checked (Get-ReleaseUrls $GaRelease.server) $zip $GaRelease.server.sha256 ('Download ' + $GaRelease.server.file + ' yourself from the guild-adventure-server releases and run: Install.cmd -Package "<path to the zip>"')
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
        Get-Checked (Get-ReleaseUrls $GaRelease.mysql) $zip $GaRelease.mysql.sha256 ('Download ' + $GaRelease.mysql.file + ' (MySQL Community Server 8.4.5, Windows x64, ZIP Archive) yourself from dev.mysql.com and run: Install.cmd -MySqlZip "<path to the zip>"')
    }
    $root = Join-Path $InstallDir 'mysql'
    Expand-Into $zip $root
    $inst.MySqlRoot = $root
}
# The database's port was free when it was chosen; another MySQL may have taken it since. Until the database is
# set up another port can still be chosen (the server's configs are written after this step).
if (-not (Test-GaStep $inst 'mysql') -and -not (Test-PortFree $inst.Ports.Db) -and -not (Test-OurDatabase $inst))
{
    $old = $inst.Ports.Db
    $inst.Ports.Db = Get-FreePort ($old + 1) @($inst.Ports.Auth, $inst.Ports.World, $inst.Ports.Soap)
    Write-Host "port $old is taken by another program: the database uses port $($inst.Ports.Db)"
}
Save-GaInstall $inst
Write-MySqlFiles $inst
if (-not (Test-GaStep $inst 'mysql'))
{
    # A mysqld of this installation left from a run that stopped holds the data folder: end it first.
    Get-Process mysqld -ErrorAction SilentlyContinue | Where-Object {
        $path = ''; try { $path = $_.Path } catch { }
        $path -and $path.StartsWith((Get-MySqlBin $inst), [StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object { Write-Host "ending MySQL left from before (process $($_.Id))"; Stop-Process -Id $_.Id -Force; $_.WaitForExit(30000) | Out-Null }
    $data = Join-Path $InstallDir 'db\data'
    if (Test-Path $data) { Remove-Item -Recurse -Force $data }
    $mysqld = Join-Path (Get-MySqlBin $inst) 'mysqld.exe'
    $ini = Join-Path $InstallDir 'db\my.ini'
    & $mysqld "--defaults-file=$ini" --initialize-insecure 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0)
    {
        $err = Join-Path $InstallDir 'db\mysqld.err'
        throw "MySQL could not create its data folder (code $LASTEXITCODE). The end of its log ($err):`n$(Get-LogTail $err)"
    }
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
$realmLine = "set realmlist 127.0.0.1:$($inst.Ports.Auth)"
# The client's folder may not be writable (for example below C:\Program Files without administrator rights): then
# the installer goes on and says what to do by hand, here and again at the end.
$clientHints = @()
try
{
    if (Test-Path $addonDst) { Remove-Item -Recurse -Force $addonDst }
    New-Item -ItemType Directory -Force (Split-Path $addonDst) | Out-Null
    Copy-Item -Recurse $addonSrc $addonDst
}
catch { Write-Host "  could not write the addon into your client: $($_.Exception.Message)" -ForegroundColor Yellow }
if (Test-Path (Join-Path $addonDst 'GuildAdventure.toc')) { Write-Host "addon: $addonDst" }
else
{
    $clientHints += "Copy the folder $addonSrc by hand into $(Split-Path $addonDst) (like any other addon), " +
        "or run Install.cmd again as administrator."
}
foreach ($loc in $locales)
{
    $rl = Join-Path $loc.FullName 'realmlist.wtf'
    $backup = "$rl.before-guild-adventure"
    try
    {
        if ((Test-Path $rl) -and -not (Test-Path $backup)) { Copy-Item $rl $backup }
        $realmLine | Set-Content $rl -Encoding ascii
    }
    catch { Write-Host "  could not write $rl : $($_.Exception.Message)" -ForegroundColor Yellow }
    if ((Test-Path $rl) -and ((Get-Content $rl -Raw) -match [regex]::Escape($realmLine)))
    {
        Write-Host "realmlist: $rl (127.0.0.1:$($inst.Ports.Auth); the old one saved as realmlist.wtf.before-guild-adventure)"
    }
    else { $clientHints += "Open $rl in a text editor and put this line into it alone: $realmLine" }
}
if ($clientHints)
{
    Write-Host ''
    Write-Host 'The installer could not write into your client folder. Do this by hand:' -ForegroundColor Yellow
    $clientHints | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "  (Start the game with the Wow.exe of $($inst.Client).)" -ForegroundColor Yellow
}

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
if ($clientHints)
{
    Write-Host 'Still to do by hand in your client (see above):' -ForegroundColor Yellow
    $clientHints | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if ($NoStart) { Stop-GaServers $inst; Stop-GaDatabase $inst }
else { & (Join-Path $PSScriptRoot 'control.ps1') -Action Start -InstallDir $InstallDir }
