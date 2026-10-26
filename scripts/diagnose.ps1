# Диагностика: проверяет компьютер и сохраняет отчёт на рабочий стол.
# Ничего не меняет и не удаляет.

. (Join-Path $PSScriptRoot 'common.ps1')

$Report = New-Object System.Collections.Generic.List[string]
$Findings = New-Object System.Collections.Generic.List[object]

function Add-Line([string]$Text = '') {
    $Report.Add($Text)
    Write-Host $Text
}

function Add-Section([string]$Title) {
    Add-Line ''
    Add-Line "===== $Title ====="
}

# Level: 1 — критично, 2 — важно, 3 — совет
function Add-Finding([int]$Level, [string]$Text) {
    $Findings.Add([pscustomobject]@{ Level = $Level; Text = $Text })
}

Write-Title 'Диагностика компьютера (ничего не меняется)'
Write-Info 'Для точного результата закрой игры, браузер и другие программы.'
Write-Info 'Проверка займёт 1–3 минуты.'

Add-Line ('Отчёт optimize_dota от {0:dd.MM.yyyy HH:mm}' -f (Get-Date))

# ---------------- Система ----------------
Add-Section 'Система'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
Add-Line "Windows: $($os.Caption) (версия $($os.Version))"
Add-Line "Компьютер: $($cs.Manufacturer) $($cs.Model)"

$uptime = (Get-Date) - $os.LastBootUpTime
Add-Line ('Работает без перезагрузки: {0} д {1} ч' -f $uptime.Days, $uptime.Hours)
if ($uptime.TotalDays -ge 3) {
    Add-Finding 3 "Компьютер не перезагружался $($uptime.Days) дн. Обычное «Завершение работы» при включённом быстром запуске не сбрасывает систему — делай именно «Перезагрузку» хотя бы раз в несколько дней."
}

$pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
if ($pendingReboot) {
    Add-Line 'Ожидается перезагрузка для установки обновлений: да'
    Add-Finding 2 'Windows ждёт перезагрузки, чтобы закончить установку обновлений. Пока она не сделана, обновления могут грузить систему в фоне.'
}

$battery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$isLaptop = $battery.Count -gt 0
if ($isLaptop) {
    $onBattery = ($battery | Where-Object { $_.BatteryStatus -eq 1 }).Count -gt 0
    Add-Line ('Ноутбук, сейчас работает от {0}' -f $(if ($onBattery) { 'батареи' } else { 'сети' }))
    if ($onBattery) {
        Add-Finding 2 'Ноутбук работает от батареи — в этом режиме процессор и видеокарта сильно замедляются. Играй с подключённой зарядкой.'
    }
}

# ---------------- Процессор ----------------
Add-Section 'Процессор'
foreach ($c in @(Get-CimInstance Win32_Processor)) {
    Add-Line ('{0} — ядер: {1}, потоков: {2}' -f $c.Name.Trim(), $c.NumberOfCores, $c.NumberOfLogicalProcessors)
}
$loads = @()
for ($i = 0; $i -lt 3; $i++) {
    $loads += (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue).PercentProcessorTime
    Start-Sleep -Seconds 1
}
$cpuLoad = [math]::Round(($loads | Measure-Object -Average).Average)
Add-Line "Загрузка процессора в простое: $cpuLoad%"
if ($cpuLoad -ge 30) {
    Add-Finding 2 "Процессор загружен на $cpuLoad%, хотя ничего не запущено. Посмотри ниже, какие процессы его грузят. Если там что-то незнакомое — проверь компьютер на вирусы и майнеры (пункт 5 меню)."
}

# ---------------- Память ----------------
Add-Section 'Оперативная память'
$totalRam = [double]$cs.TotalPhysicalMemory
$freeRam = [double]$os.FreePhysicalMemory * 1KB
$usedPct = [math]::Round(100 * (1 - $freeRam / $totalRam))
Add-Line ('Всего: {0}, занято сейчас: {1}%' -f (Format-Size $totalRam), $usedPct)
$modules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
foreach ($m in $modules) {
    $speed = if ($m.ConfiguredClockSpeed) { $m.ConfiguredClockSpeed } else { $m.Speed }
    Add-Line ('  Планка {0}: {1}, {2} МГц' -f $m.DeviceLocator, (Format-Size $m.Capacity), $speed)
}
if ($totalRam -lt 7.5GB) {
    Add-Finding 1 ('Оперативной памяти всего {0}. Для Windows с браузером и играми нужно минимум 8 ГБ, комфортно — 16 ГБ. Это одна из главных причин лагов: добавь память.' -f (Format-Size $totalRam))
} elseif ($totalRam -lt 15GB) {
    Add-Finding 3 'Памяти 8 ГБ — на сегодня впритык. Не держи открытыми много вкладок и программ одновременно; при возможности добавь до 16 ГБ.'
}
if ($usedPct -ge 80) {
    Add-Finding 2 "Память занята на $usedPct% уже сейчас, без игры. Слишком много программ работает в фоне — убери лишнее из автозагрузки (пункт 3 меню)."
}
if ($modules.Count -eq 1) {
    Add-Finding 2 'Стоит одна планка памяти — она работает в одноканальном режиме, это заметно снижает FPS (особенно на встроенной графике). Добавь вторую такую же планку. На ноутбуках с распаянной памятью это может быть неприменимо.'
}

# ---------------- Видеокарта ----------------
Add-Section 'Видеокарта'
$vram = @{}
$gpuClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
foreach ($k in Get-ChildItem -LiteralPath $gpuClass -ErrorAction SilentlyContinue) {
    $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
    if ($p -and $p.DriverDesc -and $p.'HardwareInformation.qwMemorySize') {
        $vram[$p.DriverDesc] = [double]$p.'HardwareInformation.qwMemorySize'
    }
}
foreach ($g in @(Get-CimInstance Win32_VideoController)) {
    if ($g.Name -match 'Virtual|Remote|Parsec|DisplayLink|Citrix|Mirror') { continue }
    $drvDate = $g.DriverDate
    $line = "$($g.Name), драйвер $($g.DriverVersion)"
    if ($drvDate) { $line += (' от {0:dd.MM.yyyy}' -f $drvDate) }
    if ($vram.ContainsKey($g.Name)) { $line += ', видеопамять ' + (Format-Size $vram[$g.Name]) }
    Add-Line $line
    if ($g.Name -match 'Basic Display|Базовый видеоадаптер|Standard VGA|Стандартный VGA') {
        Add-Finding 1 'Драйвер видеокарты не установлен (стоит «Базовый видеоадаптер Майкрософт»). Игры будут ужасно тормозить — установи драйвер с сайта NVIDIA, AMD или Intel.'
    } elseif ($drvDate -and ((Get-Date) - $drvDate).TotalDays -gt 365 -and $g.Name -match 'NVIDIA|AMD|Radeon|Intel|Arc') {
        Add-Finding 2 "Драйвер видеокарты $($g.Name) старше года. Обнови его с сайта производителя (NVIDIA / AMD / Intel)."
    }
}

# ---------------- Диски ----------------
Add-Section 'Диски'
foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
    $type = Get-MediaTypeName $d
    $health = "$($d.HealthStatus)"
    Add-Line ('Диск {0}: {1}, {2}, {3}, состояние: {4}' -f $d.DeviceId, $d.FriendlyName, $type, (Format-Size $d.Size), $health)
    if ($health -notin @('Healthy', '0', '')) {
        Add-Finding 1 "Диск «$($d.FriendlyName)» сообщает о проблемах (состояние: $health). Срочно скопируй важные файлы и проверь диск программой CrystalDiskInfo."
    }
    $rc = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    if ($rc) {
        $parts = @()
        if ($rc.Temperature) { $parts += "температура $($rc.Temperature) °C" }
        if ($null -ne $rc.Wear) { $parts += "износ $($rc.Wear)%" }
        if ($rc.ReadErrorsUncorrected) { $parts += "неисправленных ошибок чтения $($rc.ReadErrorsUncorrected)" }
        if ($parts.Count) { Add-Line ('  ' + ($parts -join ', ')) }
        if ($rc.Wear -ge 80) {
            Add-Finding 1 "SSD «$($d.FriendlyName)» изношен на $($rc.Wear)%. Скоро может отказать — сделай резервную копию и планируй замену."
        }
        if ($rc.ReadErrorsUncorrected -gt 0) {
            Add-Finding 1 "На диске «$($d.FriendlyName)» есть неисправимые ошибки чтения. Скопируй важные данные и проверь диск в CrystalDiskInfo."
        }
        if ($rc.Temperature -ge 70) {
            Add-Finding 2 "Диск «$($d.FriendlyName)» греется до $($rc.Temperature) °C — при перегреве он замедляется. Проверь обдув корпуса."
        }
    }
}

$sysType = Get-DriveMediaType $env:SystemDrive
Add-Line "Windows установлена на диск: $sysType"
if ($sysType -eq 'HDD') {
    Add-Finding 1 'Windows стоит на жёстком диске (HDD). Это главная причина долгой загрузки и подвисаний. Самое эффективное улучшение — поставить SSD и перенести на него систему: загрузка ускорится в 3–5 раз.'
}

foreach ($v in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
    if (-not $v.Size) { continue }
    $freePct = [math]::Round(100 * $v.FreeSpace / $v.Size)
    Add-Line ('Раздел {0} «{1}»: всего {2}, свободно {3} ({4}%)' -f $v.DeviceID, $v.VolumeName, (Format-Size $v.Size), (Format-Size $v.FreeSpace), $freePct)
    if ($v.DeviceID -eq $env:SystemDrive) {
        if ($v.FreeSpace -lt 10GB -or $freePct -lt 10) {
            Add-Finding 1 ('На системном диске {0} осталось всего {1}. Windows без свободного места сильно тормозит. Запусти очистку (пункт 2 меню) и перенеси большие файлы на другой диск.' -f $v.DeviceID, (Format-Size $v.FreeSpace))
        } elseif ($freePct -lt 15) {
            Add-Finding 2 ('На системном диске {0} свободно только {1}%. Желательно держать свободными хотя бы 15–20%.' -f $v.DeviceID, $freePct)
        }
    }
}

$since = (Get-Date).AddDays(-30)
$diskErrors = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = @(7, 11, 51, 52, 55, 153, 154); StartTime = $since } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -in @('disk', 'Ntfs', 'Microsoft-Windows-Ntfs') })
Add-Line "Ошибок диска в журнале за 30 дней: $($diskErrors.Count)"
if ($diskErrors.Count -gt 0) {
    Add-Finding 1 "За последний месяц Windows записала $($diskErrors.Count) ошибок чтения/записи диска. Это даёт сильные подвисания и может означать, что диск умирает. Скопируй важные файлы и проверь диск в CrystalDiskInfo."
}

# ---------------- Загрузка Windows ----------------
Add-Section 'Скорость загрузки Windows'
$perfLog = 'Microsoft-Windows-Diagnostics-Performance/Operational'
$boots = @(Get-WinEvent -FilterHashtable @{ LogName = $perfLog; Id = 100 } -MaxEvents 5 -ErrorAction SilentlyContinue)
if ($boots.Count -eq 0) {
    Add-Line 'Данных о времени загрузки нет (журнал отключён или пуст).'
} else {
    $lastBootSec = $null
    foreach ($e in $boots) {
        $xml = [xml]$e.ToXml()
        $bootMs = $null
        foreach ($n in $xml.Event.EventData.Data) {
            if ($n.GetAttribute('Name') -eq 'BootTime') { $bootMs = [double]$n.InnerText }
        }
        if ($null -eq $bootMs) { continue }
        $sec = [math]::Round($bootMs / 1000)
        if ($null -eq $lastBootSec) { $lastBootSec = $sec }
        Add-Line ('  {0:dd.MM.yyyy HH:mm} — до полной готовности {1} сек' -f $e.TimeCreated, $sec)
    }
    if ($lastBootSec -ge 120) {
        Add-Finding 1 "Последняя загрузка Windows заняла $lastBootSec сек — это очень долго. Нормально — до 30–60 сек."
    } elseif ($lastBootSec -ge 60) {
        Add-Finding 2 "Последняя загрузка Windows заняла $lastBootSec сек. На SSD нормой считается до 30 сек."
    }
}
$slowEvents = @(Get-WinEvent -FilterHashtable @{ LogName = $perfLog; Id = @(101, 102, 103, 106, 109); StartTime = $since } -ErrorAction SilentlyContinue)
if ($slowEvents.Count -gt 0) {
    $culprits = @{}
    foreach ($e in $slowEvents) {
        $xml = [xml]$e.ToXml()
        $data = @{}
        foreach ($n in $xml.Event.EventData.Data) { $data[$n.GetAttribute('Name')] = $n.InnerText }
        $name = if ($data['FriendlyName']) { $data['FriendlyName'] } else { $data['Name'] }
        if (-not $name) { continue }
        $delay = 0.0
        if ($data['DegradationTime']) { $delay = [double]$data['DegradationTime'] }
        if (-not $culprits.ContainsKey($name) -or $culprits[$name] -lt $delay) { $culprits[$name] = $delay }
    }
    $top = $culprits.GetEnumerator() | Where-Object { $_.Value -ge 1000 } | Sort-Object Value -Descending | Select-Object -First 10
    if ($top) {
        Add-Line 'Что замедляет загрузку (по данным Windows за 30 дней):'
        foreach ($t in $top) { Add-Line ('  {0} — +{1:N1} сек' -f $t.Key, ($t.Value / 1000)) }
        Add-Finding 2 'Windows записала программы/службы, которые замедляют загрузку (список в разделе «Скорость загрузки»). Лишние из них убери из автозагрузки или удали.'
    }
}

# ---------------- Автозагрузка ----------------
Add-Section 'Автозагрузка'
$startup = @(Get-StartupItems)
$enabled = @($startup | Where-Object { $_.Enabled })
Add-Line "Программ в автозагрузке: $($enabled.Count) включено, $($startup.Count - $enabled.Count) отключено"
foreach ($s in $enabled) {
    $hint = Get-StartupHint ($s.Name + ' ' + $s.Command)
    $line = "  + $($s.Name)"
    if ($hint) { $line += "  [$hint]" }
    Add-Line $line
}
if ($enabled.Count -ge 8) {
    Add-Finding 2 "В автозагрузке $($enabled.Count) программ — они замедляют включение и едят память во время игры. Отключи лишние (пункт 3 меню)."
}

# ---------------- Процессы ----------------
Add-Section 'Что сейчас грузит компьютер'
$cores = [Environment]::ProcessorCount
$snap1 = @{}
foreach ($p in Get-Process) { if ($null -ne $p.CPU) { $snap1[$p.Id] = $p.CPU } }
Start-Sleep -Seconds 3
$procs = @(Get-Process)
$cpuUse = foreach ($p in $procs) {
    if ($null -ne $p.CPU -and $snap1.ContainsKey($p.Id) -and $p.ProcessName -ne 'Idle') {
        [pscustomobject]@{ Name = $p.ProcessName; Cpu = [math]::Round(($p.CPU - $snap1[$p.Id]) / 3 / $cores * 100, 1) }
    }
}
Add-Line 'Процессор (за 3 секунды):'
foreach ($p in ($cpuUse | Sort-Object Cpu -Descending | Select-Object -First 8)) {
    Add-Line ('  {0,-32} {1,5}%' -f $p.Name, $p.Cpu)
    if ($p.Cpu -ge 20 -and $p.Name -notmatch '^(powershell|System|MsMpEng|TiWorker|TrustedInstaller|svchost|dwm|SearchIndexer|csrss)$') {
        Add-Finding 2 "Процесс «$($p.Name)» грузит процессор на $($p.Cpu)% в простое. Если не знаешь, что это, — поищи название в интернете и проверь компьютер на вирусы (пункт 5 меню)."
    }
}
Add-Line 'Память (суммарно по программам):'
$memTop = $procs | Group-Object ProcessName | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Mem = [double]($_.Group | Measure-Object WorkingSet64 -Sum).Sum }
} | Sort-Object Mem -Descending | Select-Object -First 10
foreach ($p in $memTop) {
    $suffix = if ($p.Count -gt 1) { " ($($p.Count) процессов)" } else { '' }
    Add-Line ('  {0,-32} {1,9}{2}' -f $p.Name, (Format-Size $p.Mem), $suffix)
}

# ---------------- Антивирусы и программы ----------------
Add-Section 'Антивирусы'
$avs = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
$activeAv = @()
foreach ($av in $avs) {
    $hex = '{0:X6}' -f [int]$av.productState
    $on = $hex.Substring(2, 2) -in @('10', '11')
    if ($on) { $activeAv += $av.displayName }
    Add-Line ('{0}: {1}' -f $av.displayName, $(if ($on) { 'включён' } else { 'выключен' }))
}
if ($activeAv.Count -ge 2) {
    Add-Finding 1 ('Одновременно работают несколько антивирусов: {0}. Они мешают друг другу и сильно тормозят систему. Оставь один (встроенного Защитника Windows обычно достаточно).' -f ($activeAv -join ', '))
}

Add-Section 'Программы, которые часто тормозят систему'
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$apps = @(Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
        Select-Object -ExpandProperty DisplayName | Sort-Object -Unique)
Add-Line "Всего установлено программ: $($apps.Count)"
$junkRules = @(
    @{ Re = 'Амиго|\bAmigo\b|Mail\.Ru|Спутник|Guard@Mail|MediaGet|WebCompanion|ByteFence|Segurazo|\bHola\b|\bBaidu\b|Tencent|Conduit|Babylon|Ask Toolbar|Search ?Protect|Яндекс\.Элементы|Yandex Elements'; Why = 'рекламный мусор — удали' },
    @{ Re = 'Driver ?Booster|DriverPack|Advanced SystemCare|IObit|Wise Care|Auslogics|Carambis|Reimage|PC Accelerate|PC Optimizer|Ускоритель компьютера|Razer Cortex|CCleaner|Glary'; Why = '«ускоритель» — вреда больше, чем пользы, удали' },
    @{ Re = 'McAfee|Norton|\bAvast\b|\bAVG\b|360 Total Security'; Why = 'тяжёлый антивирус — Защитника Windows обычно хватает' },
    @{ Re = 'uTorrent|µTorrent|BitTorrent'; Why = 'показывает рекламу в фоне — лучше заменить на qBittorrent' }
)
$found = 0
foreach ($a in $apps) {
    foreach ($r in $junkRules) {
        if ($a -match $r.Re) {
            Add-Line "  $a — $($r.Why)"
            $found++
            break
        }
    }
}
if ($found -eq 0) { Add-Line '  Ничего подозрительного из известного списка не найдено.' }
else { Add-Finding 2 "Найдено программ, которые обычно тормозят систему: $found (список в разделе «Программы»). Удали их через «Параметры → Приложения»." }

# ---------------- Настройки Windows ----------------
Add-Section 'Настройки Windows'
$schemeGuid = Get-ActivePowerScheme
$schemeName = switch ($schemeGuid) {
    $Script:PowerSaverGuid { 'Экономия энергии' }
    $Script:BalancedGuid { 'Сбалансированная' }
    $Script:HighPerfGuid { 'Высокая производительность' }
    $Script:UltimateGuid { 'Максимальная производительность' }
    default { "своя схема ($schemeGuid)" }
}
Add-Line "Схема питания: $schemeName"
if ($schemeGuid -eq $Script:PowerSaverGuid) {
    Add-Finding 1 'Включена схема питания «Экономия энергии» — процессор специально замедлен. Пункт 3 меню включит «Высокую производительность».'
} elseif ($schemeGuid -eq $Script:BalancedGuid -and -not $isLaptop) {
    Add-Finding 3 'Схема питания «Сбалансированная». На настольном ПК лучше «Высокая производительность» (пункт 3 меню).'
}

$autoPf = $cs.AutomaticManagedPagefile
$pageFiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
$pfText = if ($autoPf) { 'автоматически' } elseif ($pageFiles.Count) { 'задан вручную' } else { 'ОТКЛЮЧЁН' }
Add-Line "Файл подкачки: $pfText"
if (-not $autoPf -and $pageFiles.Count -eq 0) {
    Add-Finding 1 'Файл подкачки отключён. Когда памяти не хватает, игры вылетают и тормозят. Пункт 3 меню включит его обратно.'
}

$gameMode = Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
Add-Line ('Игровой режим: {0}' -f $(if ($gameMode -eq 0) { 'выключен' } else { 'включён' }))
if ($gameMode -eq 0) { Add-Finding 3 'Игровой режим Windows выключен. Пункт 3 меню включит его.' }

$bgRecord = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled'
$dvr = Get-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
Add-Line ('Запись игр Xbox Game Bar: {0}, фоновая запись: {1}' -f $(if ($dvr -eq 0) { 'выкл' } else { 'вкл' }), $(if ($bgRecord -eq 1) { 'ВКЛ' } else { 'выкл' }))
if ($bgRecord -eq 1) {
    Add-Finding 2 'Включена фоновая запись игр (Xbox Game Bar) — она постоянно пишет видео и отнимает FPS. Пункт 3 меню её выключит.'
}

$hags = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
Add-Line ('Аппаратное планирование GPU: {0}' -f $(if ($hags -eq 2) { 'вкл' } else { 'выкл или по умолчанию' }))

# ---------------- Сеть ----------------
Add-Section 'Интернет'
$adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and -not $_.Virtual })
foreach ($a in $adapters) { Add-Line "Подключение: $($a.Name) ($($a.InterfaceDescription)), $($a.LinkSpeed)" }
$wifi = @($adapters | Where-Object { $_.PhysicalMediaType -match '802\.11|Native 802' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless' })
if ($wifi.Count -gt 0 -and $wifi.Count -eq $adapters.Count) {
    Add-Finding 3 'Интернет через Wi-Fi. Для онлайн-игр кабель стабильнее: меньше скачков пинга и потерь пакетов.'
}
$pings = @(Test-Connection -ComputerName '8.8.8.8' -Count 10 -ErrorAction SilentlyContinue | Where-Object { $_.StatusCode -eq 0 })
if ($pings.Count -gt 0) {
    $avg = [math]::Round(($pings | Measure-Object ResponseTime -Average).Average)
    $loss = (10 - $pings.Count) * 10
    Add-Line "Пинг до 8.8.8.8: в среднем $avg мс, потери $loss%"
    if ($loss -ge 20) { Add-Finding 2 "Потери пакетов $loss% — в игре это будут рывки и телепорты. Проверь роутер/кабель или позвони провайдеру." }
} else {
    Add-Line 'Пинг до 8.8.8.8 не прошёл.'
}

# ---------------- Сбои оборудования ----------------
Add-Section 'Сбои оборудования'
$whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } -ErrorAction SilentlyContinue)
$crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } -ErrorAction SilentlyContinue)
Add-Line "Аппаратных ошибок (WHEA) за 30 дней: $($whea.Count)"
Add-Line "Внезапных выключений за 30 дней: $($crashes.Count)"
if ($whea.Count -gt 0) {
    Add-Finding 2 "Windows записала $($whea.Count) аппаратных ошибок. Частые причины: разгон, нестабильная память, перегрев. Если включал разгон или XMP — попробуй вернуть настройки BIOS по умолчанию."
}
if ($crashes.Count -ge 2) {
    Add-Finding 2 "Компьютер $($crashes.Count) раз выключался аварийно. Возможные причины: перегрев, блок питания, драйверы. Проверь температуры программой HWiNFO во время игры."
}

# ---------------- Мусор ----------------
Add-Section 'Мусор, который можно удалить'
$junkTotal = 0.0
foreach ($t in Get-CleanupTargets) {
    $size = 0.0
    foreach ($p in $t.Resolved) { $size += Get-FolderSize $p }
    foreach ($f in $t.Files) { $size += Get-FolderSize $f }
    $junkTotal += $size
    if ($size -gt 0) { Add-Line ('  {0,-45} {1}' -f $t.Name, (Format-Size $size)) }
}
$bin = Get-RecycleBinSize
if ($bin -gt 0) { Add-Line ('  {0,-45} {1}' -f 'Корзина', (Format-Size $bin)) }
$winOld = Join-Path $env:SystemDrive 'Windows.old'
if (Test-Path -LiteralPath $winOld) {
    $winOldSize = Get-FolderSize $winOld
    Add-Line ('  {0,-45} {1}' -f 'Windows.old (старая версия Windows)', (Format-Size $winOldSize))
    $junkTotal += $winOldSize
}
Add-Line ('Итого можно освободить примерно: {0} (+ корзина {1})' -f (Format-Size $junkTotal), (Format-Size $bin))
if ($junkTotal -ge 2GB) {
    Add-Finding 3 ('Накопилось {0} мусора. Запусти очистку (пункт 2 меню).' -f (Format-Size $junkTotal))
}

# ---------------- Итог ----------------
$levelNames = @{ 1 = 'КРИТИЧНО'; 2 = 'ВАЖНО'; 3 = 'СОВЕТ' }
Add-Section 'ИТОГ: что нашлось и что делать'
if ($Findings.Count -eq 0) {
    Add-Line 'Серьёзных проблем не найдено.'
} else {
    $n = 1
    foreach ($f in ($Findings | Sort-Object Level)) {
        Add-Line ('{0}. [{1}] {2}' -f $n, $levelNames[$f.Level], $f.Text)
        $n++
    }
}
Add-Line ''
Add-Line 'Не видно из Windows: температуры процессора и видеокарты. Проверь их программой HWiNFO (бесплатно) во время игры: выше 90 °C — пора чистить от пыли и менять термопасту.'

$desktop = [Environment]::GetFolderPath('Desktop')
$reportPath = Join-Path $desktop ('optimize_dota_report_{0:yyyy-MM-dd_HH-mm}.txt' -f (Get-Date))
$Report | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host ''
Write-Ok "Отчёт сохранён: $reportPath"
Write-Info 'Можешь прислать этот файл (или его текст) в чат — разберу подробно.'
