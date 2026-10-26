# Общие функции для всех скриптов optimize_dota.
# Рассчитано на Windows PowerShell 5.1 (есть в любой Windows 10/11).

$ErrorActionPreference = 'Continue'

# Здесь храним резервную копию изменённых настроек, чтобы их можно было откатить
$Script:DataDir = Join-Path $env:LOCALAPPDATA 'optimize_dota'
$Script:BackupFile = Join-Path $Script:DataDir 'changes.json'

$Script:PowerSaverGuid = 'a1841308-3541-4fab-bc81-f71556f20b4a'
$Script:BalancedGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
$Script:HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$Script:UltimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

# ---------- Вывод ----------

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
}

function Write-Ok([string]$Text) { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [!]  $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host "  [X]  $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "       $Text" -ForegroundColor Gray }

function Confirm-Action([string]$Question, [bool]$Default = $true) {
    $hint = if ($Default) { '[Д/н]' } else { '[д/Н]' }
    while ($true) {
        $answer = Read-Host "  $Question $hint"
        if ($null -eq $answer) { return $Default }
        $answer = $answer.Trim().ToLower()
        if ($answer -eq '') { return $Default }
        if ($answer -in @('д', 'да', 'y', 'yes')) { return $true }
        if ($answer -in @('н', 'нет', 'n', 'no')) { return $false }
        Write-Host '  Ответь «д» (да) или «н» (нет).' -ForegroundColor Yellow
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} МБ' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} КБ' -f ($Bytes / 1KB)) }
    return ('{0:N0} Б' -f $Bytes)
}

function Get-GuidFromText([string]$Text) {
    [regex]::Match($Text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Value.ToLower()
}

# ---------- Файлы ----------

# Размер папки. Ссылки (junction/symlink) не обходим, чтобы не считать чужие папки.
function Get-FolderSize([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return [double](Get-Item -LiteralPath $Path -Force).Length
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 0 }
    $total = 0.0
    $stack = New-Object System.Collections.Stack
    $stack.Push((New-Object IO.DirectoryInfo $Path))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in $dir.GetFiles()) { $total += $f.Length }
            foreach ($d in $dir.GetDirectories()) {
                if (-not ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($d) }
            }
        } catch { }
    }
    $total
}

# Удаляет всё содержимое папки (саму папку оставляет). Занятые файлы пропускает.
# Ссылки (junction/symlink) не обходит — так невозможно случайно удалить что-то за пределами папки.
# Возвращает количество освобождённых байт.
function Remove-DirContents([string]$Path) {
    $freed = 0.0
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $freed }
    $root = New-Object IO.DirectoryInfo $Path
    try {
        $files = $root.GetFiles()
        $dirs = $root.GetDirectories()
    } catch { return $freed }
    foreach ($f in $files) {
        try {
            $len = $f.Length
            if ($f.IsReadOnly) { $f.IsReadOnly = $false }
            $f.Delete()
            $freed += $len
        } catch { }
    }
    foreach ($d in $dirs) {
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $freed += Remove-DirContents $d.FullName
        try { $d.Delete($false) } catch { }
    }
    $freed
}

# Защита от ошибки в пути: никогда не чистим корень диска, Windows, профиль пользователя и т. п.
function Test-SafeToClean([string]$Path) {
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    if ($full.Length -le 3) { return $false }
    $protected = @(
        $env:windir, "$env:windir\System32", $env:USERPROFILE, "$env:SystemDrive\Users",
        $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA,
        [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments')
    )
    foreach ($p in $protected) {
        if ($p -and $full -eq $p.TrimEnd('\')) { return $false }
    }
    $true
}

function Remove-FileSafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    try {
        $f = New-Object IO.FileInfo $Path
        $len = $f.Length
        if ($f.IsReadOnly) { $f.IsReadOnly = $false }
        $f.Delete()
        return [double]$len
    } catch { return 0 }
}

# Раскрывает пути со звёздочками (например, профили браузера) в реально существующие папки
function Resolve-ExistingPaths([string[]]$Patterns) {
    foreach ($p in $Patterns) {
        if (-not $p) { continue }
        if ($p -match '[\*\?]') {
            Get-Item -Path $p -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
        } elseif (Test-Path -LiteralPath $p) {
            $p
        }
    }
}

# ---------- Диски ----------

function Get-MediaTypeName($Disk) {
    $mt = "$($Disk.MediaType)"
    $bus = "$($Disk.BusType)"
    if ($mt -in @('SSD', '4') -or $bus -in @('NVMe', '17')) { return 'SSD' }
    if ($mt -in @('HDD', '3')) { return 'HDD' }
    if ($bus -in @('USB', '7')) { return 'USB' }
    return 'Неизвестно'
}

# Тип диска (SSD/HDD), на котором находится буква диска или путь
function Get-DriveMediaType([string]$PathOrDrive) {
    try {
        $letter = $PathOrDrive.Substring(0, 1)
        $part = Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1
        $disk = Get-PhysicalDisk -ErrorAction Stop |
            Where-Object { "$($_.DeviceId)" -eq "$($part.DiskNumber)" } |
            Select-Object -First 1
        if ($disk) { return (Get-MediaTypeName $disk) }
    } catch { }
    'Неизвестно'
}

# ---------- Steam (только чтобы почистить его кэш) ----------

function Get-SteamPath {
    $p = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    if (-not $p) {
        $p = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
    }
    if ($p) {
        $p = $p -replace '/', '\'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $null
}

# ---------- Автозагрузка ----------

function Test-StartupEnabled([string]$ApprovedPath, [string]$Name) {
    if (-not (Test-Path -LiteralPath $ApprovedPath)) { return $true }
    $v = (Get-Item -LiteralPath $ApprovedPath).GetValue($Name, $null)
    # Так же хранит состояние «Диспетчер задач»: чётный первый байт — включено, нечётный — отключено
    if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
    $true
}

function Get-StartupItems {
    $approvedRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $items = @()
    $sources = @(
        @{ Reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKCU:\$approvedRoot\Run"; Where = 'реестр, текущий пользователь' },
        @{ Reg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$approvedRoot\Run"; Where = 'реестр, все пользователи' },
        @{ Reg = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$approvedRoot\Run32"; Where = 'реестр, все пользователи (32 бит)' }
    )
    foreach ($s in $sources) {
        if (-not (Test-Path -LiteralPath $s.Reg)) { continue }
        $key = Get-Item -LiteralPath $s.Reg
        foreach ($name in $key.GetValueNames()) {
            if (-not $name) { continue }
            $items += [pscustomobject]@{
                Name         = $name
                Command      = [string]$key.GetValue($name)
                Where        = $s.Where
                ApprovedPath = $s.Approved
                Enabled      = (Test-StartupEnabled $s.Approved $name)
            }
        }
    }
    $folders = @(
        @{ Dir = [Environment]::GetFolderPath('Startup'); Approved = "HKCU:\$approvedRoot\StartupFolder"; Where = 'папка автозагрузки пользователя' },
        @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM:\$approvedRoot\StartupFolder"; Where = 'общая папка автозагрузки' }
    )
    foreach ($f in $folders) {
        if (-not $f.Dir -or -not (Test-Path -LiteralPath $f.Dir)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $f.Dir -File -Force -ErrorAction SilentlyContinue) {
            if ($file.Name -eq 'desktop.ini') { continue }
            $items += [pscustomobject]@{
                Name         = $file.Name
                Command      = $file.FullName
                Where        = $f.Where
                ApprovedPath = $f.Approved
                Enabled      = (Test-StartupEnabled $f.Approved $file.Name)
            }
        }
    }
    $items
}

# Подсказка, что за программа в автозагрузке
function Get-StartupHint([string]$Text) {
    if ($Text -match 'SecurityHealth|Windows Defender|MSASCui') { return 'защита Windows — оставить' }
    if ($Text -match 'RtkAud|Realtek|Nahimic|Waves|Dolby|SoundBlaster|Audio') { return 'звук — лучше оставить' }
    if ($Text -match 'Synaptics|ETDCtrl|\bElan|Touchpad|TouchPad') { return 'тачпад — лучше оставить' }
    if ($Text -match 'Discord|Steam|EpicGames|Battle\.net|Origin|EADesktop|Ubisoft|GalaxyClient|Spotify|Telegram|Skype|Teams|uTorrent|qbittorrent|BitTorrent|MediaGet|Yandex|Opera|Browser|Edge|AdobeGCInvoker|Adobe|CCleaner|OneDrive|Zoom|Viber|WhatsApp|Wargaming|lghub|iCUE|Razer|Overwolf|Faceit') {
        return 'можно отключить — запустишь вручную, когда нужно'
    }
    ''
}

function Disable-StartupItem($Item) {
    $stamp = [BitConverter]::GetBytes((Get-Date).ToFileTime())
    $bytes = [byte[]](@(3, 0, 0, 0) + $stamp)
    Set-RegValue -Path $Item.ApprovedPath -Name $Item.Name -Value $bytes -Kind Binary
}

# ---------- Резервная копия и откат ----------

function Read-Backup {
    if (-not (Test-Path -LiteralPath $Script:BackupFile)) { return @() }
    $data = Get-Content -LiteralPath $Script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $list = @()
    foreach ($e in $data) { $list += $e }
    $list
}

function Add-BackupEntry([hashtable]$Entry) {
    if (-not (Test-Path -LiteralPath $Script:DataDir)) {
        New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null
    }
    $Entry['Time'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $all = @(Read-Backup) + @([pscustomobject]$Entry)
    ConvertTo-Json -InputObject $all -Depth 5 | Set-Content -LiteralPath $Script:BackupFile -Encoding UTF8
}

# Меняет значение в реестре, запоминая старое для отката
function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Kind = 'DWord'
    )
    $existed = $false
    $old = $null
    $oldKind = $null
    if (Test-Path -LiteralPath $Path) {
        $key = Get-Item -LiteralPath $Path
        if ($key.GetValueNames() -contains $Name) {
            $existed = $true
            $old = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            $oldKind = $key.GetValueKind($Name).ToString()
        }
    } else {
        New-Item -Path $Path -Force | Out-Null
    }
    if ($existed -and $oldKind -eq $Kind -and ("$old" -eq "$Value")) { return }
    Add-BackupEntry @{ Type = 'Registry'; Path = $Path; Name = $Name; Existed = $existed; OldValue = $old; OldKind = $oldKind }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
}

function Get-RegValue([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    (Get-Item -LiteralPath $Path).GetValue($Name, $null)
}

function Get-ActivePowerScheme {
    Get-GuidFromText ((powercfg /getactivescheme) -join ' ')
}

function Undo-Changes {
    $entries = @(Read-Backup)
    if ($entries.Count -eq 0) {
        Write-Info 'Откатывать нечего: скрипты ещё ничего не меняли.'
        return
    }
    [array]::Reverse($entries)
    foreach ($e in $entries) {
        try {
            switch ($e.Type) {
                'Registry' {
                    if ($e.Existed) {
                        $v = $e.OldValue
                        if ($e.OldKind -eq 'Binary') { $v = [byte[]]@($e.OldValue) }
                        if ($e.OldKind -eq 'MultiString') { $v = [string[]]@($e.OldValue) }
                        if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                        New-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $v -PropertyType $e.OldKind -Force | Out-Null
                    } else {
                        Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                    }
                }
                'PowerPlan' {
                    powercfg /setactive $e.OldGuid | Out-Null
                }
                'Pagefile' {
                    $cs = Get-CimInstance Win32_ComputerSystem
                    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = [bool]$e.OldValue }
                }
            }
        } catch {
            Write-Warn "Не удалось откатить $($e.Type) $($e.Path) $($e.Name): $($_.Exception.Message)"
        }
    }
    $archive = Join-Path $Script:DataDir ('changes-undone-{0:yyyy-MM-dd_HH-mm-ss}.json' -f (Get-Date))
    Move-Item -LiteralPath $Script:BackupFile -Destination $archive -Force
    Write-Ok "Откачено изменений: $($entries.Count). Перезагрузи компьютер, чтобы всё применилось."
}

function New-RestorePoint {
    $rpKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $freqName = 'SystemRestorePointCreationFrequency'
    $oldFreq = Get-RegValue $rpKey $freqName
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        # Windows разрешает только одну точку в сутки — на время создания снимаем ограничение
        New-ItemProperty -LiteralPath $rpKey -Name $freqName -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description 'optimize_dota' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Ok 'Точка восстановления создана (Панель управления → Восстановление).'
        return $true
    } catch {
        Write-Warn "Точку восстановления создать не удалось: $($_.Exception.Message)"
        return $false
    } finally {
        if ($null -eq $oldFreq) {
            Remove-ItemProperty -LiteralPath $rpKey -Name $freqName -ErrorAction SilentlyContinue
        } else {
            New-ItemProperty -LiteralPath $rpKey -Name $freqName -Value $oldFreq -PropertyType DWord -Force | Out-Null
        }
    }
}

# ---------- Что чистить ----------

function Get-CleanupTargets {
    $la = $env:LOCALAPPDATA
    $ra = $env:APPDATA
    $win = $env:windir
    $sys = $env:SystemDrive
    $steam = Get-SteamPath

    $chromium = @(
        "$la\Google\Chrome\User Data",
        "$la\Microsoft\Edge\User Data",
        "$la\Yandex\YandexBrowser\User Data",
        "$la\BraveSoftware\Brave-Browser\User Data",
        "$la\Vivaldi\User Data"
    )
    $browserPaths = @()
    foreach ($root in $chromium) {
        foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage')) {
            $browserPaths += "$root\*\$sub"
        }
    }
    $browserPaths += @(
        "$la\Opera Software\Opera Stable\Cache",
        "$la\Opera Software\Opera GX Stable\Cache",
        "$ra\Opera Software\Opera Stable\Code Cache",
        "$ra\Opera Software\Opera GX Stable\Code Cache",
        "$la\Mozilla\Firefox\Profiles\*\cache2"
    )

    $targets = @(
        [pscustomobject]@{
            Name = 'Временные файлы пользователя'; Paths = @($env:TEMP); Files = @()
            Services = @(); Processes = @(); Default = $true; Note = ''
        },
        [pscustomobject]@{
            Name = 'Временные файлы Windows'; Paths = @("$win\Temp"); Files = @()
            Services = @(); Processes = @(); Default = $true; Note = ''
        },
        [pscustomobject]@{
            Name = 'Скачанные файлы обновлений Windows'; Paths = @("$win\SoftwareDistribution\Download"); Files = @()
            Services = @('wuauserv', 'bits'); Processes = @(); Default = $true; Note = 'уже установленные обновления не удаляются'
        },
        [pscustomobject]@{
            Name = 'Кэш оптимизации доставки'; Paths = @("$win\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"); Files = @()
            Services = @('DoSvc'); Processes = @(); Default = $true; Note = ''
        },
        [pscustomobject]@{
            Name = 'Дампы и отчёты об ошибках'
            Paths = @("$la\CrashDumps", "$win\Minidump", "$win\LiveKernelReports",
                "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                "$la\Microsoft\Windows\WER\ReportArchive", "$la\Microsoft\Windows\WER\ReportQueue")
            Files = @("$win\MEMORY.DMP")
            Services = @(); Processes = @(); Default = $true; Note = ''
        },
        [pscustomobject]@{
            Name = 'Кэш браузеров'; Paths = $browserPaths; Files = @()
            Services = @(); Processes = @('chrome', 'msedge', 'browser', 'opera', 'brave', 'vivaldi', 'firefox'); Default = $true
            Note = 'пароли, история, закладки и вкладки НЕ удаляются'
        },
        [pscustomobject]@{
            Name = 'Кэш Discord'; Paths = @("$ra\discord\Cache", "$ra\discord\Code Cache", "$ra\discord\GPUCache"); Files = @()
            Services = @(); Processes = @('Discord'); Default = $true; Note = ''
        },
        [pscustomobject]@{
            Name = 'Остатки установщиков драйверов NVIDIA/AMD'; Paths = @("$sys\NVIDIA", "$sys\AMD"); Files = @()
            Services = @(); Processes = @(); Default = $true; Note = 'распакованные установщики, драйвер не затрагивается'
        }
    )
    if ($steam) {
        $targets += [pscustomobject]@{
            Name = 'Кэш веб-страниц, логи и дампы Steam'
            Paths = @("$steam\appcache\httpcache", "$steam\logs", "$steam\dumps", "$la\Steam\htmlcache"); Files = @()
            Services = @(); Processes = @('steam'); Default = $true; Note = 'игры и кэш шейдеров не трогаем'
        }
    }
    foreach ($t in $targets) {
        $t | Add-Member -NotePropertyName Resolved -NotePropertyValue @(Resolve-ExistingPaths $t.Paths)
    }
    $targets
}

function Get-RecycleBinSize {
    $total = 0.0
    foreach ($v in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
        $total += Get-FolderSize ($v.DeviceID + '\$Recycle.Bin')
    }
    $total
}
