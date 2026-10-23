# Install only the verified portable Steam preview payload. Never imports a mod-manager ZIP.
[CmdletBinding(DefaultParameterSetName='Install')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Install')][string]$GamePath,
    [Parameter(Mandatory=$true,ParameterSetName='Rollback')][string]$Rollback
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$utf8=[Text.UTF8Encoding]::new($false)
$homePath=[IO.Path]::Combine($env:LOCALAPPDATA,'LLL','Helldivers2')
$servicePath=[IO.Path]::Combine($homePath,'Service')
$statePath=[IO.Path]::Combine($servicePath,'installed-steam-preview.json')
function Hash-Bytes([byte[]]$Bytes) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}
function Hash-File([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    $stream=[IO.File]::OpenRead($Path);$algorithm=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose();$algorithm.Dispose() }
}
function Assert-Closed {
    if (@(Get-Process -Name helldivers2 -ErrorAction SilentlyContinue).Count) { throw 'Close Helldivers 2 before installing or rolling back.' }
    # A waiting helper owns the same per-user service mutex even without a
    # game. Do not replace its binding/startup with a different pipe token.
    $helpers=@(Get-Process -Name 'lll_steam_service_*','steam_service','lll_steam_launcher_*' -ErrorAction SilentlyContinue|Where-Object { $_.Name -match '^(lll_steam_(service|launcher)_[0-9a-f]{16}|steam_service)$' })
    if ($helpers.Count) {
        throw ('Exit the waiting LLL Steam helper before installing or rolling back: '+(($helpers|ForEach-Object {$_.Name}) -join ', ')+'. No process was stopped.')
    }
}
function Full-Root([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { return $full.TrimEnd([char[]]'\/') }
    return $full
}
function Assert-StartupSlots([string]$Root) {
    # Only inspect this startup archive family, never unrelated mod archives.
    $paths=@([IO.Directory]::GetFiles([IO.Path]::Combine($Root,'data'),'9ba626afa44a3aa3.patch_*')|Where-Object {
        [IO.Path]::GetFileName($_) -match '^9ba626afa44a3aa3\.patch_[0-9]+$' -and [IO.Path]::GetFileName($_) -ne '9ba626afa44a3aa3.patch_0'
    })
    if ($paths.Count -gt 1000) { throw 'Too many startup patch slots to verify safely.' }
    foreach ($path in $paths) {
        $stream=[IO.File]::OpenRead($path);$reader=[IO.BinaryReader]::new($stream)
        try {
            if ($stream.Length -lt 104 -or $reader.ReadUInt32() -ne [Convert]::ToUInt32('f0000011',16)) { throw 'Invalid archive header.' }
            $types=$reader.ReadUInt32();$count=$reader.ReadUInt32()
            $start=72L+32L*$types;$end=$start+80L*$count
            if ($types -eq 0 -or $types -gt 100000 -or $count -gt 100000 -or $end -gt $stream.Length) { throw 'Invalid archive table.' }
            for ($index=0;$index -lt $count;$index++) {
                $stream.Position=$start+80L*$index
                $name=$reader.ReadUInt64();$kind=$reader.ReadUInt64();$offset=$reader.ReadUInt64()
                $stream.Position=$start+80L*$index+56;$size=$reader.ReadUInt32()
                if ($offset -lt $end -or $offset -gt $stream.Length -or $size -gt ($stream.Length-$offset)) { throw 'Invalid archive resource range.' }
                if ($name -eq [Convert]::ToUInt64('f476df93691895fa',16) -and $kind -eq [Convert]::ToUInt64('a14e8dfa2cd117e2',16)) {
                    throw 'Competing startup boot resource.'
                }
            }
        } catch { throw ('Cannot install beside startup slot '+[IO.Path]::GetFileName($path)+': '+$_.Exception.Message) }
        finally { $reader.Dispose();$stream.Dispose() }
    }
}
function Assert-Game([string]$Root,$Hashes) {
    foreach ($item in $Hashes.PSObject.Properties) {
        if ($item.Name -notin @('bin/helldivers2.exe','data/game/game.dll') -or $item.Value -notmatch '^[0-9a-f]{64}$') { throw 'Invalid game fingerprint manifest.' }
        if ((Hash-File ([IO.Path]::Combine($Root,$item.Name))) -ne $item.Value) { throw ('Unsupported game files: '+$item.Name) }
    }
    if (@($Hashes.PSObject.Properties).Count -ne 2) { throw 'Incomplete game fingerprints.' }
}
function Target-Path([string]$Root,[string]$Group,[string]$Name) {
    if ($Group -eq 'data' -and $Name -in @('9ba626afa44a3aa3.patch_0','9ba626afa44a3aa3.patch_0.stream','9ba626afa44a3aa3.patch_0.gpu_resources')) {
        return [IO.Path]::Combine($Root,'data',$Name)
    }
    if ($Group -eq 'service' -and ($Name -match '^lll_steam_(service|launcher)_[0-9a-f]{16}\.exe$' -or $Name -in @('game-root.txt','installed-steam-preview.json'))) {
        return [IO.Path]::Combine($servicePath,$Name)
    }
    throw 'Unexpected installation target.'
}
function Write-Atomic([string]$Path,[byte[]]$Bytes) {
    $temporary=$Path+'.lll-stage-'+[Guid]::NewGuid().ToString('N')
    try {
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($Bytes,0,$Bytes.Length);$stream.Flush() } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Write-Receipt([string]$Path,$Receipt) {
    Write-Atomic $Path ($utf8.GetBytes(($Receipt|ConvertTo-Json -Depth 12)+"`n"))
}
function Restore-Receipt([string]$ReceiptPath) {
    Assert-Closed
    $receipt=Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8|ConvertFrom-Json
    if ($receipt.format -ne 'LLL-Steam-preview-install-v1') { throw 'Unknown rollback receipt.' }
    $root=Full-Root $receipt.game_root
    # Stock files may have advanced through Steam since installation. Exact
    # receipt-owned target hashes, below, determine whether restoration is safe.
    $rows=@($receipt.files);$targets=@{}
    foreach ($row in $rows) {
        $target=Target-Path $root $row.group $row.name
        if ($targets.ContainsKey($target) -or $row.after -notmatch '^[0-9a-f]{64}$' -or ($null -ne $row.before -and $row.before -notmatch '^[0-9a-f]{64}$')) { throw 'Invalid rollback targets.' }
        $targets[$target]=$true;$current=Hash-File $target
        if ($current -ne $row.after -and $current -ne $row.before) { throw ('Installed bytes changed; rollback refused: '+$row.name) }
    }
    $archive=[IO.Compression.ZipFile]::OpenRead([IO.Path]::Combine([IO.Path]::GetDirectoryName($ReceiptPath),'rollback.zip'))
    try {
        $restore=@{}
        foreach ($row in $rows) {
            if ($null -ne $row.before) {
                $entry=$archive.GetEntry($row.group+'/'+$row.name)
                if (-not $entry -or $entry.Length -gt 67108864) { throw 'Rollback data missing or too large.' }
                $stream=$entry.Open();$memory=[IO.MemoryStream]::new()
                try { $stream.CopyTo($memory);$bytes=$memory.ToArray() } finally { $stream.Dispose();$memory.Dispose() }
                if ((Hash-Bytes $bytes) -ne $row.before) { throw 'Rollback bytes changed.' }
                $restore[$row.group+'/'+$row.name]=$bytes
            }
        }
        Assert-Closed
        for ($index=$rows.Count-1;$index -ge 0;$index--) {
            $row=$rows[$index];$target=Target-Path $root $row.group $row.name
            $current=Hash-File $target
            if ($current -eq $row.before) { continue }
            if ($current -ne $row.after) { throw 'Installation changed during rollback.' }
            if ($null -eq $row.before) { [IO.File]::Delete($target) }
            else { Write-Atomic $target $restore[$row.group+'/'+$row.name] }
            if ((Hash-File $target) -ne $row.before) { throw 'Rollback verification failed.' }
        }
    } finally { $archive.Dispose() }
    $receipt.state='rolled back; original bytes verified';Write-Receipt $ReceiptPath $receipt
    Write-Output ('Rolled back. Saved settings and Mods were retained. Receipt: '+$ReceiptPath)
}
Assert-Closed
if ($PSCmdlet.ParameterSetName -eq 'Rollback') { Restore-Receipt ([IO.Path]::GetFullPath($Rollback));return }
$GamePath=Full-Root $GamePath
if (-not [IO.Directory]::Exists([IO.Path]::Combine($GamePath,'data'))) { throw 'Select the game folder containing bin and data.' }
$package=Get-Content -LiteralPath ([IO.Path]::Combine($PSScriptRoot,'package.json')) -Raw -Encoding UTF8|ConvertFrom-Json
if ($package.format -ne 'LLL-Steam-portable-v1' -or $package.service -notmatch '^lll_steam_service_[0-9a-f]{16}\.exe$') { throw 'Invalid portable package.' }
Assert-Game $GamePath $package.game
Assert-StartupSlots $GamePath
if ([IO.File]::Exists($statePath)) {
    $previous=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
    if ($previous.format -ne 'LLL-Steam-preview-owner-v1' -or -not $previous.game_root) { throw 'Cannot verify the existing LLL installation marker.' }
    if (-not [String]::Equals((Full-Root $previous.game_root),$GamePath,[StringComparison]::OrdinalIgnoreCase)) { throw 'LLL is bound to another game folder. Roll back that installation before switching game folders.' }
}
$bindingPath=[IO.Path]::Combine($servicePath,'game-root.txt')
if ([IO.File]::Exists($bindingPath)) {
    $binding=[IO.File]::ReadAllText($bindingPath,[Text.Encoding]::UTF8).TrimEnd([char[]]"`r`n")
    if (-not [String]::Equals((Full-Root $binding),$GamePath,[StringComparison]::OrdinalIgnoreCase)) { throw 'LLL is bound to another game folder. Restore/remove that installation before switching game folders.' }
}
$desired=@{};$payloads=@($package.payloads.PSObject.Properties)
$hasLauncher=$package.PSObject.Properties.Name -contains 'launcher'
if ($hasLauncher -and $package.launcher -notmatch '^lll_steam_launcher_[0-9a-f]{16}\.exe$') { throw 'Invalid launcher name.' }
$expectedPayloads=4;if ($hasLauncher) { $expectedPayloads++ }
if ($payloads.Count -ne $expectedPayloads) { throw 'Incomplete payload manifest.' }
foreach ($item in $payloads) {
    $parts=$item.Name.Split('/')
    if ($parts.Count -ne 2 -or $parts[0] -notin @('data','service')) { throw 'Invalid package payload path.' }
    $null=Target-Path $GamePath $parts[0] $parts[1]
    if ($parts[0] -eq 'service' -and $parts[1] -ne $package.service -and (-not $hasLauncher -or $parts[1] -ne $package.launcher)) { throw 'Unexpected helper payload.' }
    if ($item.Value -notmatch '^[0-9a-f]{64}$') { throw 'Invalid payload checksum.' }
    $path=[IO.Path]::Combine($PSScriptRoot,$parts[0],$parts[1]);$bytes=[IO.File]::ReadAllBytes($path)
    if ((Hash-Bytes $bytes) -ne $item.Value) { throw ('Package payload changed: '+$item.Name) }
    $desired[$item.Name]=$bytes
}
$helperKey='service/'+$package.service
if (-not $desired.ContainsKey($helperKey) -or $package.service -ne ('lll_steam_service_'+(Hash-Bytes $desired[$helperKey]).Substring(0,16)+'.exe')) { throw 'Helper content address mismatch.' }
if ($hasLauncher) {
    $launcherKey='service/'+$package.launcher
    if (-not $desired.ContainsKey($launcherKey) -or $package.launcher -ne ('lll_steam_launcher_'+(Hash-Bytes $desired[$launcherKey]).Substring(0,16)+'.exe')) { throw 'Launcher content address mismatch.' }
}
$patchName='9ba626afa44a3aa3.patch_0';$patchKey='data/'+$patchName
foreach ($suffix in @('','.stream','.gpu_resources')) {
    if (-not $desired.ContainsKey($patchKey+$suffix)) { throw 'Startup payload missing.' }
    if ($suffix -and $desired[$patchKey+$suffix].Length -ne 0) { throw 'Unexpected startup sidecar payload.' }
    $existing=Target-Path $GamePath 'data' ($patchName+$suffix)
    if ($suffix -and [IO.File]::Exists($existing) -and ([IO.FileInfo]$existing).Length -ne 0) { throw 'Conflicting startup sidecar; disable the competing loader first.' }
}
$oldPatch=Hash-File (Target-Path $GamePath 'data' $patchName)
$owned=$oldPatch -eq (Hash-Bytes $desired[$patchKey]) -or $oldPatch -in @($package.known_lll_patch_sha256)
if ($oldPatch -and -not $owned -and [IO.File]::Exists($statePath)) {
    $previous=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
    $owned=$previous.format -eq 'LLL-Steam-preview-owner-v1' -and [String]::Equals($previous.game_root,$GamePath,[StringComparison]::OrdinalIgnoreCase) -and $previous.patch_sha256 -eq $oldPatch
}
if ($oldPatch -and -not $owned) { throw 'Unknown startup patch ownership; disable/remove the other loader before installing LLL.' }
if (-not $oldPatch) {
    foreach ($suffix in @('.stream','.gpu_resources')) {
        if ([IO.File]::Exists((Target-Path $GamePath 'data' ($patchName+$suffix)))) { throw 'Orphan startup sidecars; restore the prior installation first.' }
    }
}
$helperTarget=Target-Path $GamePath 'service' $package.service
if ([IO.File]::Exists($helperTarget) -and (Hash-File $helperTarget) -ne (Hash-Bytes $desired[$helperKey])) { throw 'Installed content-addressed helper changed.' }
$desired['service/game-root.txt']=$utf8.GetBytes($GamePath+"`n")
$owner=[ordered]@{format='LLL-Steam-preview-owner-v1';release=$package.release;game_root=$GamePath;patch_sha256=(Hash-Bytes $desired[$patchKey]);helper=$package.service}
$desired['service/installed-steam-preview.json']=$utf8.GetBytes(($owner|ConvertTo-Json -Depth 5)+"`n")
$rows=@()
foreach ($name in ($desired.Keys|Sort-Object)) {
    $parts=$name.Split('/');$target=Target-Path $GamePath $parts[0] $parts[1]
    $before=Hash-File $target;$after=Hash-Bytes $desired[$name]
    if ($before -ne $after) { $rows+=@{group=$parts[0];name=$parts[1];before=$before;after=$after} }
}
if (-not $rows.Count) { Write-Output 'This preview is already installed; no files changed.';return }
$configPath=[IO.Path]::Combine($homePath,'LLL.cfg');$configBefore=Hash-File $configPath
$backupPath=[IO.Path]::Combine($homePath,'Backups',('steam-preview-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N')))
$null=[IO.Directory]::CreateDirectory($backupPath);$null=[IO.Directory]::CreateDirectory($servicePath)
# First-launch failures happen before platform initialization creates its logs.
$null=[IO.Directory]::CreateDirectory([IO.Path]::Combine($homePath,'Logs'))
$archive=[IO.Compression.ZipFile]::Open([IO.Path]::Combine($backupPath,'rollback.zip'),[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($row in $rows) {
        if ($null -ne $row.before) {
            $target=Target-Path $GamePath $row.group $row.name
            if ((Hash-File $target) -ne $row.before) { throw 'Target changed while preparing rollback.' }
            $null=[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$target,($row.group+'/'+$row.name))
        }
    }
} finally { $archive.Dispose() }
$receipt=@{format='LLL-Steam-preview-install-v1';release=$package.release;game_root=$GamePath;game=$package.game;files=@($rows);configuration_sha256=$configBefore;state='prepared';live_validation='pending'}
$receiptPath=[IO.Path]::Combine($backupPath,'receipt.json');Write-Receipt $receiptPath $receipt
try {
    Assert-Closed
    Assert-StartupSlots $GamePath
    foreach ($row in $rows) {
        $target=Target-Path $GamePath $row.group $row.name
        if ((Hash-File $target) -ne $row.before) { throw 'Target changed before replacement.' }
    }
    foreach ($row in $rows) { Write-Atomic (Target-Path $GamePath $row.group $row.name) $desired[$row.group+'/'+$row.name] }
    foreach ($row in $rows) { if ((Hash-File (Target-Path $GamePath $row.group $row.name)) -ne $row.after) { throw 'Installed byte verification failed.' } }
    if ((Hash-File $configPath) -ne $configBefore) { throw 'Saved configuration changed during installation.' }
    $receipt.state='installed bytes verified; saved settings preserved';Write-Receipt $receiptPath $receipt
} catch {
    $failure=$_.Exception.Message
    try { Restore-Receipt $receiptPath|Out-Null } catch { throw ($failure+'; rollback pending: '+$receiptPath+'; '+$_.Exception.Message) }
    throw ($failure+'; changes rolled back. Receipt: '+$receiptPath)
}
Write-Output ('Installed '+$package.release+'. Start the game and press F8 or your saved manager key. Receipt: '+$receiptPath)
