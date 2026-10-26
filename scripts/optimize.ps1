# Оптимизация Windows. Перед изменениями создаёт точку восстановления,
# а все изменённые настройки запоминает — их можно откатить пунктом меню «Откат».

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Title 'Оптимизация Windows'
Write-Info 'Каждый шаг спрашивает подтверждение. Всё можно откатить пунктом 6 меню.'
Write-Host ''

if (Confirm-Action 'Создать точку восстановления системы (рекомендуется)?' $true) {
    New-RestorePoint | Out-Null
}

$battery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$isLaptop = $battery.Count -gt 0

# ---------- 1. Схема питания ----------
Write-Host ''
Write-Host '  1. Схема питания «Высокая производительность»' -ForegroundColor Cyan
Write-Info 'Процессор не будет сбрасывать частоту — меньше микрофризов в игре.'
if ($isLaptop) { Write-Info 'Это ноутбук: от батареи он будет работать меньше. В играх держи его на зарядке.' }
$current = Get-ActivePowerScheme
$savedGuidFile = Join-Path $Script:DataDir 'powerplan.txt'
if ($current -in @($Script:HighPerfGuid, $Script:UltimateGuid)) {
    Write-Ok 'Уже включена.'
} elseif (Confirm-Action 'Включить?' $true) {
    $list = (powercfg /list) -join "`n"
    $target = $null
    if ($list -match $Script:HighPerfGuid) {
        $target = $Script:HighPerfGuid
    } elseif ((Test-Path -LiteralPath $savedGuidFile) -and ($list -match (Get-Content -LiteralPath $savedGuidFile -Raw).Trim())) {
        $target = (Get-Content -LiteralPath $savedGuidFile -Raw).Trim()
    } else {
        # На многих ноутбуках схема скрыта — создаём её копию
        $target = Get-GuidFromText ((powercfg /duplicatescheme $Script:HighPerfGuid) -join ' ')
        if ($target) {
            if (-not (Test-Path -LiteralPath $Script:DataDir)) { New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null }
            Set-Content -LiteralPath $savedGuidFile -Value $target
        }
    }
    if ($target -and $target -ne $current) {
        powercfg /setactive $target | Out-Null
        if ((Get-ActivePowerScheme) -eq $target) {
            Add-BackupEntry @{ Type = 'PowerPlan'; OldGuid = $current }
            Write-Ok 'Включена «Высокая производительность».'
        } else {
            $target = $null
        }
    }
    if (-not $target) {
        Write-Warn 'Эта Windows не даёт сменить схему (так бывает на современных ноутбуках).'
        Write-Info 'Сделай вручную: Параметры → Система → Питание → Режим питания → «Максимальная производительность».'
    }
}

# ---------- 2. Игровой режим и запись Xbox ----------
Write-Host ''
Write-Host '  2. Игровой режим Windows + отключение фоновой записи Xbox Game Bar' -ForegroundColor Cyan
Write-Info 'Игровой режим отдаёт игре приоритет. Фоновая запись постоянно пишет видео и съедает FPS.'
Write-Info 'Запись через Win+Alt+R перестанет работать (если пользуешься — ответь «н»).'
if (Confirm-Action 'Применить?' $true) {
    Set-RegValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AllowAutoGameMode' -Value 1
    Set-RegValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -Value 1
    Set-RegValue -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0
    Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0
    Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'HistoricalCaptureEnabled' -Value 0
    Write-Ok 'Готово.'
}

# ---------- 3. Визуальные эффекты ----------
Write-Host ''
Write-Host '  3. Облегчить интерфейс Windows' -ForegroundColor Cyan
Write-Info 'Выключить прозрачность и анимации окон и панели задач. Помогает на слабых ПК и встроенной графике.'
Write-Info 'Шрифты и миниатюры остаются как были. Применится после перезагрузки.'
if (Confirm-Action 'Применить?' $true) {
    Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Value 0
    Set-RegValue -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '0' -Kind String
    Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAnimations' -Value 0
    Write-Ok 'Готово.'
}

# ---------- 4. Файл подкачки ----------
$cs = Get-CimInstance Win32_ComputerSystem
$pageFiles = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
if (-not $cs.AutomaticManagedPagefile -and $pageFiles.Count -eq 0) {
    Write-Host ''
    Write-Host '  4. Файл подкачки ОТКЛЮЧЁН' -ForegroundColor Cyan
    Write-Info 'Без него при нехватке памяти игры вылетают и тормозят. Советы «отключи подкачку для скорости» — вредный миф.'
    if (Confirm-Action 'Включить автоматический размер файла подкачки?' $true) {
        try {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
            Add-BackupEntry @{ Type = 'Pagefile'; OldValue = $false }
            Write-Ok 'Включён. Заработает после перезагрузки.'
        } catch {
            Write-Warn "Не получилось: $($_.Exception.Message)"
        }
    }
}

# ---------- 5. Автозагрузка ----------
Write-Host ''
Write-Host '  5. Автозагрузка' -ForegroundColor Cyan
Write-Info 'Каждая программа здесь замедляет включение компьютера и ест память во время игры.'
Write-Info 'Отключение работает так же, как в Диспетчере задач: программа остаётся установленной, просто не запускается сама.'
$items = @(Get-StartupItems | Where-Object { $_.Enabled })
if ($items.Count -eq 0) {
    Write-Ok 'В автозагрузке ничего нет.'
} else {
    $n = 1
    foreach ($it in $items) {
        $hint = Get-StartupHint ($it.Name + ' ' + $it.Command)
        $color = if ($hint -like 'можно*') { 'Yellow' } elseif ($hint) { 'Green' } else { 'White' }
        Write-Host ('  {0,2}. {1}' -f $n, $it.Name) -ForegroundColor $color -NoNewline
        if ($hint) { Write-Host "  — $hint" -ForegroundColor $color } else { Write-Host '' }
        $cmd = $it.Command
        if ($cmd.Length -gt 90) { $cmd = $cmd.Substring(0, 87) + '...' }
        Write-Host "      $cmd" -ForegroundColor DarkGray
        $n++
    }
    Write-Host ''
    Write-Info 'Введи номера программ, которые отключить, через пробел или запятую (например: 1 3 5).'
    Write-Info 'Напиши «все жёлтые», чтобы отключить всё, что помечено «можно отключить». Enter — ничего не трогать.'
    $answer = Read-Host '  Номера'
    $chosen = @()
    if ($answer -match 'ж[её]лт') {
        $chosen = @($items | Where-Object { (Get-StartupHint ($_.Name + ' ' + $_.Command)) -like 'можно*' })
    } else {
        foreach ($tok in ($answer -split '[\s,;]+')) {
            $num = 0
            if ([int]::TryParse($tok, [ref]$num) -and $num -ge 1 -and $num -le $items.Count) {
                $chosen += $items[$num - 1]
            }
        }
    }
    foreach ($it in ($chosen | Sort-Object Name -Unique)) {
        try {
            Disable-StartupItem $it
            Write-Ok "Отключено: $($it.Name)"
        } catch {
            Write-Warn "Не удалось отключить $($it.Name): $($_.Exception.Message)"
        }
    }
    if ($chosen.Count -eq 0) { Write-Info 'Автозагрузка не изменена.' }
}

Write-Host ''
Write-Ok 'Оптимизация Windows завершена. Перезагрузи компьютер, чтобы всё применилось.'
