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

function Get-Checked([string] $Url, [string] $File, [string] $Sha256)
{
    if ((Test-Path $File) -and $Sha256 -and (Get-FileHash $File -Algorithm SHA256).Hash -eq $Sha256) { return }
    Write-Host "download: $Url"
    $part = "$File.part"
    Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing
    if ($Sha256)
    {
        $hash = (Get-FileHash $part -Algorithm SHA256).Hash
        if ($hash -ne $Sha256) { Remove-Item $part; throw "Checksum mismatch for $Url (got $hash, want $Sha256)" }
    }
    Move-Item -Force $part $File
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
    $fwd = { param($p) $p -replace '\\', '/' }
    @(
        '[mysqld]'
        "basedir=$(& $fwd $Inst.MySqlRoot)"
        "datadir=$(& $fwd (Join-Path $db 'data'))"
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

function Start-GaDatabase($Inst)
{
    if (-not (Test-PortFree $Inst.Ports.Db)) { return }
    $mysqld = Join-Path (Get-MySqlBin $Inst) 'mysqld.exe'
    $ini = Join-Path $Inst.Dir 'db\my.ini'
    $p = Start-Process $mysqld -ArgumentList "--defaults-file=`"$ini`"" -WindowStyle Hidden -PassThru
    if (-not (Wait-Port $Inst.Ports.Db 120 $p)) { throw "MySQL did not start (see $(Join-Path $Inst.Dir 'db\mysqld.err'))" }
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
        'AllFlightPaths'          = '1'
        'InstantFlightPaths'      = '1'
        'MaxCoreStuckTime'        = '600'
        'MapUpdate.Threads'       = '4'
        'MinWorldUpdateTime'      = '10'
        'Creature.Instance.TeleportToUnreachableTarget' = '1'
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
