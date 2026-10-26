# Очистка мусора. Сначала показывает, что и сколько удалится, и спрашивает подтверждение.

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Title 'Очистка мусора'
Write-Info 'Удаляются только временные файлы и кэши — личные файлы, пароли и игры не трогаются.'
Write-Info 'Prefetch и кэш шейдеров специально НЕ чистим: без них программы и игры запускаются дольше.'
Write-Host ''
Write-Info 'Считаю, сколько можно освободить...'

$sysDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
$freeBefore = [double]$sysDrive.FreeSpace

$targets = @(Get-CleanupTargets)
$sizes = @{}
$i = 1
Write-Host ''
foreach ($t in $targets) {
    $size = 0.0
    foreach ($p in $t.Resolved) { $size += Get-FolderSize $p }
    foreach ($f in $t.Files) { $size += Get-FolderSize $f }
    $sizes[$t.Name] = $size
    $note = if ($t.Note) { "  ($($t.Note))" } else { '' }
    Write-Host ('  {0,2}. {1,-45} {2,10}{3}' -f $i, $t.Name, (Format-Size $size), $note)
    $i++
}
$total = ($sizes.Values | Measure-Object -Sum).Sum
Write-Host ''
Write-Host ('  Всего: {0}' -f (Format-Size $total)) -ForegroundColor Cyan
Write-Host ''

# Закрытые программы чистятся полностью, открытые — частично (занятые файлы пропускаются)
$running = @()
foreach ($t in $targets) {
    foreach ($name in $t.Processes) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { $running += $name }
    }
}
if ($running.Count) {
    Write-Warn ('Сейчас запущены: {0}. Закрой их, чтобы кэш очистился полностью.' -f (($running | Sort-Object -Unique) -join ', '))
    Read-Host '  Закрой программы и нажми Enter (или просто Enter, чтобы продолжить так)' | Out-Null
}

$freedTotal = 0.0
if (Confirm-Action 'Удалить всё из списка выше?' $true) {
    foreach ($t in $targets) {
        if ($sizes[$t.Name] -le 0) { continue }
        foreach ($svc in $t.Services) { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
        $freed = 0.0
        foreach ($p in $t.Resolved) {
            if (Test-SafeToClean $p) { $freed += Remove-DirContents $p }
            else { Write-Warn "Пропущено (защищённая папка): $p" }
        }
        foreach ($f in $t.Files) { $freed += Remove-FileSafe $f }
        foreach ($svc in $t.Services) { Start-Service -Name $svc -ErrorAction SilentlyContinue }
        $freedTotal += $freed
        Write-Ok ('{0}: освобождено {1}' -f $t.Name, (Format-Size $freed))
    }
} else {
    Write-Info 'Пропущено.'
}

# Корзина — отдельно, вдруг там что-то нужное
$bin = Get-RecycleBinSize
if ($bin -gt 0) {
    Write-Host ''
    if (Confirm-Action ('Очистить корзину ({0})? Проверь, что там нет нужного.' -f (Format-Size $bin)) $false) {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        $freedTotal += $bin
        Write-Ok 'Корзина очищена.'
    }
}

# Глубокая очистка средствами самой Windows
Write-Host ''
Write-Host '  Глубокая очистка Windows (10–40 минут):' -ForegroundColor Cyan
Write-Info '- старые версии обновлений Windows и драйверов;'
Write-Info '- папка Windows.old (после неё откатиться на прошлую версию Windows будет нельзя);'
Write-Info '- журналы установки, файлы отчётов об ошибках и т. п.'
$winOld = Join-Path $env:SystemDrive 'Windows.old'
if (Test-Path -LiteralPath $winOld) {
    Write-Info ('Windows.old сейчас занимает примерно {0}.' -f (Format-Size (Get-FolderSize $winOld)))
}
if (Confirm-Action 'Запустить глубокую очистку?' $true) {
    $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    # Только безопасные пункты «Очистки диска». Папку «Загрузки» и корзину сюда специально не включаем.
    $handlers = @(
        'Active Setup Temp Folders', 'Delivery Optimization Files', 'Device Driver Packages',
        'Diagnostic Data Viewer database files', 'Downloaded Program Files', 'Feedback Hub Archive log files',
        'Internet Cache Files', 'Old ChkDsk Files', 'Previous Installations', 'RetailDemo Offline Content',
        'Setup Log Files', 'System error memory dump files', 'System error minidump files',
        'Temporary Files', 'Temporary Setup Files', 'Update Cleanup', 'Upgrade Discarded Files',
        'Windows Defender', 'Windows Error Reporting Files', 'Windows Upgrade Log Files'
    )
    $flag = 'StateFlags0777'
    foreach ($h in $handlers) {
        $p = Join-Path $vc $h
        if (Test-Path -LiteralPath $p) {
            New-ItemProperty -LiteralPath $p -Name $flag -Value 2 -PropertyType DWord -Force | Out-Null
        }
    }
    Write-Info 'Шаг 1 из 2: «Очистка диска» Windows (откроется окно с прогрессом)...'
    Start-Process -FilePath "$env:windir\System32\cleanmgr.exe" -ArgumentList '/sagerun:777' -Wait
    foreach ($h in $handlers) {
        $p = Join-Path $vc $h
        if (Test-Path -LiteralPath $p) { Remove-ItemProperty -LiteralPath $p -Name $flag -ErrorAction SilentlyContinue }
    }
    Write-Info 'Шаг 2 из 2: сжатие хранилища компонентов (DISM). Может долго стоять на одном проценте — это нормально.'
    & "$env:windir\System32\Dism.exe" /Online /Cleanup-Image /StartComponentCleanup
    Write-Ok 'Глубокая очистка завершена.'
}

$sysDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
$gained = [double]$sysDrive.FreeSpace - $freeBefore
Write-Host ''
Write-Ok ('Готово. На диске {0} теперь свободно {1} (было {2}, +{3}).' -f $env:SystemDrive, (Format-Size $sysDrive.FreeSpace), (Format-Size $freeBefore), (Format-Size ([math]::Max(0, $gained))))
if ($freedTotal -gt [math]::Max(0, $gained) + 100MB) {
    Write-Info ('Всего удалено {0} — часть была на других дисках.' -f (Format-Size $freedTotal))
}
