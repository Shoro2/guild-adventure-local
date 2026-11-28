# Shared functions of the Guild Adventure local installer and launcher (install.ps1, control.ps1).
# Windows PowerShell 5.1; nothing here needs administrator rights except the VC++ runtime installer.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'      # Invoke-WebRequest is many times slower with its progress bar

$GaRepo    = Split-Path -Parent $PSScriptRoot
$GaRelease = Get-Content (Join-Path $PSScriptRoot 'release.json') -Raw | ConvertFrom-Json

function Write-Step([string] $Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }

# --- the installation's own settings (guild-adventure.json in the install folder) ---------------------------------

function Get-GaInstall([string] $Dir)
{
    $file = Join-Path $Dir 'guild-adventure.json'
    if (-not (Test-Path $file)) { throw "No Guild Adventure installation in $Dir (guild-adventure.json missing)" }
    $inst = Get-Content $file -Raw | ConvertFrom-Json
    $inst | Add-Member -NotePropertyName Dir -NotePropertyValue $Dir -Force
    return $inst
}

function Save-GaInstall($Inst)
{
    $copy = $Inst | Select-Object * -ExcludeProperty Dir
    $copy | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Inst.Dir 'guild-adventure.json') -Encoding UTF8
}

function Test-GaStep($Inst, [string] $Step) { return @($Inst.Done) -contains $Step }

function Get-GaLatestRelease
{
    # The release file of the newest installer on GitHub, or $null: no network, GitHub down or slow, no updates entry.
    if (-not $GaRelease.PSObject.Properties['updates']) { return $null }
    try
    {
        $r = Invoke-WebRequest -Uri $GaRelease.updates.release -UseBasicParsing -TimeoutSec 5
        $text = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string] $r.Content }
        $latest = $text.TrimStart([char] 0xFEFF) | ConvertFrom-Json
        if (-not $latest.version) { return $null }
        return $latest
    }
    catch { return $null }
}

function Test-GaNewer([string] $Latest, [string] $Current)
{
    try { return ([version] $Latest) -gt ([version] $Current) } catch { return $false }
}

function Update-GaFiles($Latest)
{
    # Downloads the newest installer files and copies them over these; the install folder (game) stays as it is.
    $zip = Join-Path $env:TEMP "guild-adventure-local-$($Latest.version).zip"
    $tmp = Join-Path $env:TEMP "guild-adventure-local-$($Latest.version)"
    Invoke-WebRequest -Uri $GaRelease.updates.files -OutFile $zip -UseBasicParsing -TimeoutSec 120
    if (-not (Test-FileKind $zip $zip)) { throw "The download of $($GaRelease.updates.files) is no zip file" }
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive -Path $zip -DestinationPath $tmp
    $items = @(Get-ChildItem $tmp)
    $src = if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $items[0].FullName } else { $tmp }
    if (-not (Test-Path (Join-Path $src 'installer\install.ps1'))) { throw 'The download holds no installer' }
    Get-ChildItem $src -Force | Where-Object { $_.Name -ne 'game' } | Copy-Item -Destination $GaRepo -Recurse -Force
    Remove-Item -Recurse -Force $tmp, $zip
}

function Invoke-GaUpdateCheck($Inst)
{
    # Start.cmd: when GitHub has a newer release, offers to update (new installer files, then Install.cmd, which
    # replaces the server). Returns $true when the update ran; without a network it says nothing and goes on.
    $latest = Get-GaLatestRelease
    if (-not $latest -or -not (Test-GaNewer $latest.version $GaRelease.version)) { return $false }
    if ($Inst.PSObject.Properties['UpdateDeclined'] -and $Inst.UpdateDeclined -eq $latest.version)
    {
        Write-Host "Guild Adventure $($latest.version) is available (you have $($GaRelease.version)): see README.md, Update." -ForegroundColor Yellow
        return $false
    }
    Add-Type -AssemblyName System.Windows.Forms
    $top = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    $question = "Guild Adventure $($latest.version) is available (you have $($GaRelease.version)).`n`nUpdate now? " +
        "The new files and the new server are downloaded; your characters, databases and server data stay. " +
        "It takes a few minutes.`n`nNo: start as it is (you are asked again for the next version)."
    $answer = [System.Windows.Forms.MessageBox]::Show($top, $question, 'Guild Adventure', 'YesNo', 'Question')
    $top.Dispose()
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes)
    {
        $Inst | Add-Member -NotePropertyName UpdateDeclined -NotePropertyValue $latest.version -Force
        Save-GaInstall $Inst
        return $false
    }
    Write-Step "Update to Guild Adventure $($latest.version)"
    try { Update-GaFiles $latest }
    catch
    {
        Write-Warning "The update could not be downloaded ($($_.Exception.Message)); Guild Adventure starts as it is."
        return $false
    }
    Write-Host 'new installer files in place: Install.cmd replaces the server'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $GaRepo 'installer\install.ps1') -InstallDir $Inst.Dir
    if ($LASTEXITCODE -ne 0) { throw 'The update stopped with an error: run Install.cmd again to go on where it stopped' }
    return $true
}

function Update-GaRelease($Inst, [string] $Version)
{
    # An installation of an older release: its server is replaced in the server step (the downloads of this release),
    # the configs and the addon are written anew as on every run; databases, characters, account and server data stay.
    if ("$($Inst.Version)" -eq $Version) { return $false }
    $old = if ($Inst.Version) { $Inst.Version } else { 'an older version' }
    if (Test-GaStep $Inst 'server')
    {
        Write-Step "Update from $old to $Version"
        Write-Host 'The server is replaced; your databases, characters, account and server data stay.'
        Stop-GaServers $Inst
        $Inst.Done = @(@($Inst.Done) | Where-Object { $_ -ne 'server' })
    }
    $Inst.Version = $Version
    Save-GaInstall $Inst
    return $true
}

function Complete-GaStep($Inst, [string] $Step)
{
    $Inst.Done = @(@($Inst.Done) + $Step | Select-Object -Unique)
    Save-GaInstall $Inst
}

function New-GaSecret([int] $Length = 16)
{
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# --- ports ----------------------------------------------------------------------------------------------------------

function Test-PortFree([int] $Port)
{
    foreach ($ip in @([Net.IPAddress]::Loopback, [Net.IPAddress]::Any))
    {
        $listener = New-Object Net.Sockets.TcpListener($ip, $Port)
        try { $listener.Start(); $listener.Stop() } catch { return $false }
    }
    return $true
}

function Get-FreePort([int] $From, [int[]] $Taken = @())
{
    for ($p = $From; $p -lt $From + 100; $p++)
    {
        if ($Taken -notcontains $p -and (Test-PortFree $p)) { return $p }
    }
    throw "No free TCP port from $From to $($From + 99)"
}

function Wait-Port([int] $Port, [int] $Seconds, [Diagnostics.Process] $Process = $null)
{
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline)
    {
        if ($Process -and $Process.HasExited) { return $false }
        $client = New-Object Net.Sockets.TcpClient
        try { $client.Connect('127.0.0.1', $Port); $client.Close(); return $true } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# --- downloads ------------------------------------------------------------------------------------------------------

function Get-ReleaseUrls($Entry)
{
    # The sources of a download in release.json: "urls" (tried in that order), else "url".
    if ($Entry.PSObject.Properties['urls'] -and $Entry.urls) { return @($Entry.urls) }
    return @($Entry.url)
}

function Test-FileKind([string] $Path, [string] $Name)
{
    # A server that cannot deliver a file often sends an HTML page with status 200 instead; a zip starts with "PK", a
    # Windows program with "MZ". Other kinds are not checked.
    $want = switch ([IO.Path]::GetExtension($Name).ToLowerInvariant()) { '.zip' { 'PK' } '.exe' { 'MZ' } default { '' } }
    if (-not $want) { return $true }
    $bytes = New-Object byte[] 2
    $stream = [IO.File]::OpenRead($Path)
    try { $read = $stream.Read($bytes, 0, 2) } finally { $stream.Dispose() }
    return $read -eq 2 -and [Text.Encoding]::ASCII.GetString($bytes) -eq $want
}

function Get-Checked($Urls, [string] $File, [string] $Sha256, [string] $Hint = '')
{
    # Downloads $File from the first source of $Urls that delivers it. A failed request, a page instead of the file and
    # a wrong checksum count as a failure of that source, and the next one is tried; when none delivers, the error
    # names every source with its reason, and $Hint says what the user can do instead.
    if ((Test-Path $File) -and $Sha256 -and (Get-FileHash $File -Algorithm SHA256).Hash -eq $Sha256) { return }
    $part = "$File.part"
    $failed = @()
    foreach ($url in @($Urls | Where-Object { $_ }))
    {
        Write-Host "download: $url"
        if (Test-Path $part) { Remove-Item -Force $part }
        $why = ''
        try { Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing -ErrorAction Stop }
        catch
        {
            $response = $_.Exception.Response
            if ($response -and $response.StatusCode) { $why = "the server answered $([int]$response.StatusCode) $($response.StatusCode)" }
            else
            {
                $why = [string]($_.Exception.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                if (-not $why) { $why = 'the download failed' }
                elseif ($why.Length -gt 160) { $why = $why.Substring(0, 160) + ' ...' }
            }
        }
        if (-not $why -and -not (Test-Path $part)) { $why = 'nothing arrived' }
        if (-not $why -and -not (Test-FileKind $part $File)) { $why = 'the server sent a web page instead of the file' }
        if (-not $why -and $Sha256)
        {
            $hash = (Get-FileHash $part -Algorithm SHA256).Hash
            if ($hash -ne $Sha256) { $why = "the checksum does not match (got $hash, want $Sha256)" }
        }
        if (-not $why)
        {
            Move-Item -Force $part $File
            return
        }
        Write-Host "  failed: $why" -ForegroundColor Yellow
        $failed += "  $url : $why"
        if (Test-Path $part) { Remove-Item -Force $part }
    }
    $text = "Could not download $([IO.Path]::GetFileName($File)):`n" + ($failed -join "`n")
    if ($Hint) { $text += "`n$Hint" }
    throw $text
}

function Expand-Into([string] $Zip, [string] $Dest)
{
    # Unpacks a zip whose content sits in one top folder into $Dest (the top folder dropped).
    $tmp = "$Dest.unpack"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive -Path $Zip -DestinationPath $tmp
    $items = @(Get-ChildItem $tmp)
    $src = if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $items[0].FullName } else { $tmp }
    New-Item -ItemType Directory -Force $Dest | Out-Null
    Get-ChildItem $src -Force | Move-Item -Destination $Dest -Force
    Remove-Item -Recurse -Force $tmp
}

# --- MySQL ----------------------------------------------------------------------------------------------------------

function Get-MySqlBin($Inst) { return Join-Path $Inst.MySqlRoot 'bin' }

function Invoke-GaSql($Inst, [string] $Sql, [string] $Database = '')
{
    $exe = Join-Path (Get-MySqlBin $Inst) 'mysql.exe'
    $cnf = Join-Path $Inst.Dir 'db\client.cnf'
    $sqlArgs = @("--defaults-extra-file=$cnf", '--batch', '--skip-column-names', '-e', $Sql)
    if ($Database) { $sqlArgs += $Database }
    $out = & $exe @sqlArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "mysql failed: $out" }
    return $out
}

function Write-MySqlFiles($Inst)
{
    $db = Join-Path $Inst.Dir 'db'
    New-Item -ItemType Directory -Force $db | Out-Null
    # Its own temp folder: MySQL's default is the user's %TEMP%, which fails to start when the Windows user name
    # holds letters outside ASCII (Cyrillic, umlauts).
    New-Item -ItemType Directory -Force (Join-Path $db 'tmp') | Out-Null
    $fwd = { param($p) $p -replace '\\', '/' }
    @(
        '[mysqld]'
        "basedir=$(& $fwd $Inst.MySqlRoot)"
        "datadir=$(& $fwd (Join-Path $db 'data'))"
        "tmpdir=$(& $fwd (Join-Path $db 'tmp'))"
        "port=$($Inst.Ports.Db)"
        'bind-address=127.0.0.1'
        'mysqlx=OFF'
        'max_allowed_packet=64M'
        "log-error=$(& $fwd (Join-Path $db 'mysqld.err'))"
    ) | Set-Content (Join-Path $db 'my.ini') -Encoding ascii
    @(
        '[client]'
        'host=127.0.0.1'
        "port=$($Inst.Ports.Db)"
        'user=root'
        "password=$($Inst.Db.RootPassword)"
    ) | Set-Content (Join-Path $db 'client.cnf') -Encoding ascii
}

function Get-PortOwner([int] $Port)
{
    # The process that listens on $Port, or $null.
    $id = $null
    try { $id = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1).OwningProcess }
    catch
    {
        $line = netstat -ano -p TCP | Select-String -Pattern ":$Port\s+\S+\s+LISTENING\s+(\d+)" | Select-Object -First 1
        if ($line) { $id = [int]$line.Matches[0].Groups[1].Value }
    }
    if (-not $id) { return $null }
    return Get-Process -Id $id -ErrorAction SilentlyContinue
}

function Test-OurDatabase($Inst)
{
    # Is what listens on the database port this installation's own mysqld?
    $owner = Get-PortOwner $Inst.Ports.Db
    if (-not $owner) { return $false }
    $path = ''
    try { $path = $owner.Path } catch { }
    return $path -and $path.StartsWith((Get-MySqlBin $Inst), [StringComparison]::OrdinalIgnoreCase)
}

function Get-LogTail([string] $Path, [int] $Lines = 25)
{
    if (-not (Test-Path $Path)) { return "  ($Path does not exist)" }
    return ((Get-Content $Path -Tail $Lines -ErrorAction SilentlyContinue | ForEach-Object { "  $_" }) -join "`n")
}

function Start-GaDatabase($Inst)
{
    $err = Join-Path $Inst.Dir 'db\mysqld.err'
    if (-not (Test-PortFree $Inst.Ports.Db))
    {
        if (Test-OurDatabase $Inst) { return }
        $owner = Get-PortOwner $Inst.Ports.Db
        $who = 'another program'
        if ($owner)
        {
            $ownerPath = ''
            try { $ownerPath = $owner.Path } catch { }
            $who = "$($owner.ProcessName) (process $($owner.Id)$(if ($ownerPath) { ', ' + $ownerPath }))"
        }
        throw ("Port $($Inst.Ports.Db) for Guild Adventure's database is taken by $who. Stop that program, " +
            "or run Install.cmd again before the database is set up to choose another port.")
    }
    $mysqld = Join-Path (Get-MySqlBin $Inst) 'mysqld.exe'
    $ini = Join-Path $Inst.Dir 'db\my.ini'
    $p = Start-Process $mysqld -ArgumentList "--defaults-file=`"$ini`"" -WindowStyle Hidden -PassThru
    if (-not (Wait-Port $Inst.Ports.Db 300 $p))
    {
        $how = if ($p.HasExited) { "it ended with code $($p.ExitCode)" } else { 'it did not open its port within 5 minutes' }
        throw "MySQL did not start: $how. The end of its log ($err):`n$(Get-LogTail $err)"
    }
}

function Stop-GaDatabase($Inst)
{
    if (Test-PortFree $Inst.Ports.Db) { return }
    $admin = Join-Path (Get-MySqlBin $Inst) 'mysqladmin.exe'
    & $admin "--defaults-extra-file=$(Join-Path $Inst.Dir 'db\client.cnf')" shutdown 2>&1 | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-PortFree $Inst.Ports.Db) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
}

# --- accounts (SRP6, as AzerothCore's own account create) -----------------------------------------------------------

function New-GaAccount($Inst, [string] $User, [string] $Password, [int] $GmLevel = 0)
{
    $user = $User.ToUpperInvariant()
    if ($user -notmatch '^[A-Z0-9]{1,16}$') { throw 'Account name: 1-16 letters and digits' }
    if ($Password.Length -lt 1 -or $Password.Length -gt 16) { throw 'Password: 1-16 characters (client limit)' }
    $pass = $Password.ToUpperInvariant()
    $exists = Invoke-GaSql $Inst "SELECT COUNT(*) FROM account WHERE username = '$user';" $Inst.Db.Auth
    if ([int]"$exists" -gt 0) { Write-Host "account exists: $user"; return }

    $sha1 = [Security.Cryptography.SHA1]::Create()
    $salt = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $h1 = $sha1.ComputeHash([Text.Encoding]::UTF8.GetBytes("${user}:${pass}"))
    $h2 = $sha1.ComputeHash([byte[]]($salt + $h1))
    $toBig = { param([byte[]] $le) [Numerics.BigInteger]::new([byte[]]($le + [byte]0)) }
    $nHex = '894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7'
    $nBe = for ($i = 0; $i -lt $nHex.Length; $i += 2) { [Convert]::ToByte($nHex.Substring($i, 2), 16) }
    [array]::Reverse($nBe)
    $v = [Numerics.BigInteger]::ModPow([Numerics.BigInteger]7, (& $toBig $h2), (& $toBig $nBe))
    $vBytes = New-Object byte[] 32
    $raw = $v.ToByteArray()
    [array]::Copy($raw, $vBytes, [Math]::Min(32, $raw.Length))
    $hex = { param([byte[]] $b) ($b | ForEach-Object { $_.ToString('X2') }) -join '' }

    Invoke-GaSql $Inst ("INSERT INTO account (username, salt, verifier, expansion, reg_mail, email, joindate) " +
        "VALUES ('$user', 0x$(& $hex $salt), 0x$(& $hex $vBytes), 2, '', '', NOW());") $Inst.Db.Auth | Out-Null
    Invoke-GaSql $Inst ("INSERT INTO realmcharacters (realmid, acctid, numchars) SELECT realmlist.id, account.id, 0 " +
        "FROM realmlist, account LEFT JOIN realmcharacters ON acctid = account.id WHERE acctid IS NULL;") $Inst.Db.Auth | Out-Null
    if ($GmLevel -gt 0)
    {
        $id = Invoke-GaSql $Inst "SELECT id FROM account WHERE username = '$user';" $Inst.Db.Auth
        Invoke-GaSql $Inst "INSERT INTO account_access (id, gmlevel, RealmID) VALUES ($id, $GmLevel, -1);" $Inst.Db.Auth | Out-Null
    }
    Write-Host "account created: $user"
}

# --- server configs -------------------------------------------------------------------------------------------------

function Set-ConfValue([string] $Text, [string] $Key, [string] $Value)
{
    $pattern = '(?m)^(\s*)' + [regex]::Escape($Key) + '\s*=.*$'
    if ($Text -notmatch $pattern) { throw "Config key not found in template: $Key" }
    return [regex]::Replace($Text, $pattern, { param($m) "$($m.Groups[1].Value)$Key = $Value" })
}

function Write-Conf([string] $Dist, [string] $Target, [hashtable] $Values, [Collections.Specialized.OrderedDictionary] $Extra)
{
    if (-not (Test-Path $Dist)) { throw "Template missing: $Dist" }
    $text = [IO.File]::ReadAllText($Dist)
    foreach ($k in $Values.Keys) { $text = Set-ConfValue $text $k $Values[$k] }
    if ($Extra)
    {
        $text = $text.TrimEnd() + "`r`n`r`n# Added by the Guild Adventure installer`r`n"
        foreach ($k in $Extra.Keys) { $text += "$k = $($Extra[$k])`r`n" }
    }
    [IO.File]::WriteAllText($Target, $text)
}

function Write-GaConfigs($Inst)
{
    $server = Join-Path $Inst.Dir 'server'
    $configs = Join-Path $server 'configs'
    $mods = Join-Path $configs 'modules'
    $dataDir = if ($Inst.PSObject.Properties['DataDir'] -and $Inst.DataDir) { $Inst.DataDir } else { Join-Path $server 'Data' }
    $fwd = { param($p) $p -replace '\\', '/' }
    $q = { param($s) '"' + $s + '"' }
    $dbInfo = { param($name) & $q "127.0.0.1;$($Inst.Ports.Db);$($Inst.Db.User);$($Inst.Db.Password);$name" }
    $logs = Join-Path $Inst.Dir 'logs'
    New-Item -ItemType Directory -Force $logs | Out-Null
    $source = & $fwd (Join-Path $server 'source')
    $mysqlExe = & $fwd (Join-Path (Get-MySqlBin $Inst) 'mysql.exe')

    Write-Conf (Join-Path $configs 'authserver.conf.dist') (Join-Path $configs 'authserver.conf') @{
        'RealmServerPort'         = "$($Inst.Ports.Auth)"
        'BindIP'                  = & $q '127.0.0.1'
        'LoginDatabaseInfo'       = & $dbInfo $Inst.Db.Auth
        'LogsDir'                 = & $q (& $fwd $logs)
        'SourceDirectory'         = & $q $source
        'MySQLExecutable'         = & $q $mysqlExe
        'Updates.EnableDatabases' = '0'
    }
    Write-Conf (Join-Path $configs 'worldserver.conf.dist') (Join-Path $configs 'worldserver.conf') @{
        'WorldServerPort'         = "$($Inst.Ports.World)"
        'BindIP'                  = & $q '127.0.0.1'
        'LoginDatabaseInfo'       = & $dbInfo $Inst.Db.Auth
        'WorldDatabaseInfo'       = & $dbInfo $Inst.Db.World
        'CharacterDatabaseInfo'   = & $dbInfo $Inst.Db.Characters
        'DataDir'                 = & $q (& $fwd $dataDir)
        'LogsDir'                 = & $q (& $fwd $logs)
        'SourceDirectory'         = & $q $source
        'MySQLExecutable'         = & $q $mysqlExe
        'Updates.EnableDatabases' = '7'
        'Updates.AutoSetup'       = '1'
        'SOAP.Enabled'            = '1'
        'SOAP.IP'                 = & $q '127.0.0.1'
        'SOAP.Port'               = "$($Inst.Ports.Soap)"
        'MaxPlayerLevel'          = '60'
        'Rate.XP.Kill'            = '2'
        'Rate.XP.Quest'           = '2'
        'Rate.XP.Quest.DF'        = '2'
        'Rate.XP.Explore'         = '2'
        'Rate.XP.Pet'             = '2'
        'Rate.Drop.Item.Uncommon' = '2'
        'Rate.Drop.Item.Rare'     = '2'
        'Rate.Drop.Item.Epic'     = '2'
        'Rate.Drop.Item.Legendary' = '2'
        'Rate.Drop.Item.Artifact' = '2'
        'Rate.Drop.Item.Referenced' = '2'
        'Rate.Drop.Money'         = '2'
        'Rate.Creature.Aggro'     = '0.5'
        'Death.SicknessLevel'     = '81'
        'SkipCinematics'          = '1'
        'AllFlightPaths'          = '0'
        'InstantFlightPaths'      = '0'
        'MaxCoreStuckTime'        = '600'
        'MapUpdate.Threads'       = '4'
        'MinWorldUpdateTime'      = '10'
        'Creature.Instance.TeleportToUnreachableTarget' = '1'
        'PreventAFKLogout'        = '2'
        'Appender.Server'         = '2,5,1,Server.log,a,52428800'
        'Appender.Errors'         = '2,2,1,Errors.log,a,10485760'
        'Appender.Playerbots'     = '2,5,1,Playerbots.log,w,104857600'
    } ([ordered]@{
        'Appender.GuildAdventure'   = '2,5,1,GuildAdventure.log,a,20971520'
        'Logger.module.ga.activity' = '4,GuildAdventure'
    })
    Write-Conf (Join-Path $mods 'playerbots.conf.dist') (Join-Path $mods 'playerbots.conf') @{
        'PlayerbotsDatabaseInfo'             = & $dbInfo $Inst.Db.Playerbots
        'Playerbots.Updates.EnableDatabases' = '1'
        'Playerbots.Enabled'                 = '1'
        'Playerbots.RandomBotAutologin'      = '0'
        'Playerbots.MinRandomBots'           = '0'
        'Playerbots.MaxRandomBots'           = '0'
        'Playerbots.AddClassAccountPoolSize' = '0'
        'Playerbots.MaxAddedBots'            = '40'
        'Playerbots.AllowGuildBots'          = '1'
        'Playerbots.AllowAccountBots'        = '1'
        'Playerbots.KeepAltsInGroup'         = '1'
        'Playerbots.BotAutologin'            = '0'
        'Playerbots.SelfBotLevel'            = '1'
        'Playerbots.RpgStatusProbWeight.WanderRandom' = '0'
        'Playerbots.RpgStatusProbWeight.WanderNpc'    = '0'
        'Playerbots.RpgStatusProbWeight.GoGrind'      = '0'
        'Playerbots.RpgStatusProbWeight.GoCamp'       = '0'
        'Playerbots.RpgStatusProbWeight.DoQuest'      = '0'
        'Playerbots.RpgStatusProbWeight.TravelFlight' = '0'
        'Playerbots.RpgStatusProbWeight.Rest'         = '0'
        'Playerbots.RpgStatusProbWeight.OutdoorPvp'   = '0'
        'Playerbots.RpgStatusProbWeight.DoGather'     = '0'
        'Playerbots.BotCheats'                        = '""'
        'Playerbots.SummonWhenGroup'                  = '0'
        'Playerbots.AutoPickTalentsForPlayerControlledBots' = '0'
        'Playerbots.RandomBotTalk'                    = '0'
    }
    Write-Conf (Join-Path $mods 'mod_guild_adventure.conf.dist') (Join-Path $mods 'mod_guild_adventure.conf') @{}
    $ah = Join-Path $mods 'mod_ahbot.conf.dist'
    if (Test-Path $ah)
    {
        Write-Conf $ah (Join-Path $mods 'mod_ahbot.conf') @{
            'AuctionHouseBot.EnableSeller'  = 'false'
            'AuctionHouseBot.Buyer.Enabled' = 'false'
        }
    }
    $al = Join-Path $mods 'mod_autolearn_skills.conf.dist'
    if (Test-Path $al)
    {
        Write-Conf $al (Join-Path $mods 'mod_autolearn_skills.conf') @{
            'AutoLearnSkills.Enable'                      = '1'
            'AutoLearnSkills.AutoLearnWeaponSkills'       = '1'
            'AutoLearnSkills.MaxWeaponSkills'             = '1'
            'AutoLearnSkills.AutoLearnRiding'             = '1'
            'AutoLearnSkills.Riding.Apprentice'           = '1'
            'AutoLearnSkills.Riding.GrantApprenticeMount' = '1'
            'AutoLearnSkills.Riding.Journeyman'           = '1'
            'AutoLearnSkills.Riding.GrantJourneymanMount' = '1'
            'AutoLearnSkills.Riding.Expert'               = '0'
            'AutoLearnSkills.Riding.GrantExpertMount'     = '0'
            'AutoLearnSkills.Riding.Artisan'              = '0'
            'AutoLearnSkills.Riding.GrantArtisanMount'    = '0'
            'AutoLearnSkills.Riding.ColdWeather'          = '0'
        }
    }
}

# --- servers --------------------------------------------------------------------------------------------------------

function Get-GaProcess($Inst, [string] $Name)
{
    $exe = Join-Path $Inst.Dir "server\$Name.exe"
    return @(Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $exe })
}

function Start-GaServer($Inst, [string] $Name, [int] $Port, [int] $Seconds)
{
    if (Get-GaProcess $Inst $Name) { return }
    $server = Join-Path $Inst.Dir 'server'
    $conf = Join-Path $server "configs\$Name.conf"
    $p = Start-Process (Join-Path $server "$Name.exe") -ArgumentList "-c `"$conf`"" -WorkingDirectory $server `
        -WindowStyle Minimized -PassThru
    if (-not (Wait-Port $Port $Seconds $p)) { throw "$Name did not start (see $(Join-Path $Inst.Dir 'logs'))" }
}

function Invoke-GaSoap($Inst, [string] $Command)
{
    $body = '<?xml version="1.0" encoding="utf-8"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" ' +
        'xmlns:ns1="urn:AC"><SOAP-ENV:Body><ns1:executeCommand><command>' + [Security.SecurityElement]::Escape($Command) +
        '</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>'
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Inst.Soap.User):$($Inst.Soap.Password)"))
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$($Inst.Ports.Soap)/" -Method Post -Body $body -ContentType 'text/xml' `
        -Headers @{ Authorization = "Basic $auth" } -UseBasicParsing
    return $r.Content
}

function Stop-GaServers($Inst)
{
    $world = Get-GaProcess $Inst 'worldserver'
    if ($world)
    {
        try { Invoke-GaSoap $Inst 'server shutdown 1' | Out-Null } catch { Write-Warning "SOAP shutdown failed: $_" }
        if (-not $world[0].WaitForExit(120000)) { Write-Warning 'worldserver did not stop in 2 minutes: ending it'; $world | Stop-Process -Force }
    }
    Get-GaProcess $Inst 'authserver' | Stop-Process -Force
}
