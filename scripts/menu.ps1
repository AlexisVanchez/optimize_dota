# Главное меню. Запускается из start.bat с правами администратора.

. (Join-Path $PSScriptRoot 'common.ps1')

$Host.UI.RawUI.WindowTitle = 'Оптимизация и очистка компьютера'

if (-not (Test-IsAdmin)) {
    Write-Bad 'Нужны права администратора. Запусти start.bat двойным щелчком и нажми «Да» в окне Windows.'
    Read-Host '  Нажми Enter, чтобы закрыть' | Out-Null
    exit 1
}

function Invoke-SystemRepair {
    Write-Title 'Проверка и восстановление системных файлов'
    Write-Info 'Исправляет повреждённые файлы Windows — частая причина зависаний и ошибок.'
    Write-Info 'Займёт 15–40 минут, нужен интернет. Компьютер в это время можно использовать.'
    if (-not (Confirm-Action 'Начать?' $true)) { return }
    Write-Info 'Шаг 1 из 2: DISM восстанавливает хранилище компонентов...'
    & "$env:windir\System32\Dism.exe" /Online /Cleanup-Image /RestoreHealth
    Write-Info 'Шаг 2 из 2: SFC проверяет системные файлы...'
    & "$env:windir\System32\sfc.exe" /scannow
    Write-Ok 'Готово. Если что-то было исправлено — перезагрузи компьютер.'
}

function Invoke-VirusScan {
    Write-Title 'Проверка на вирусы и скрытые майнеры'
    Write-Info 'Майнеры тайно грузят процессор и видеокарту — компьютер тормозит без видимой причины.'
    $mp = $null
    try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { }
    if (-not $mp -or -not $mp.AntivirusEnabled) {
        Write-Warn 'Защитник Windows выключен — значит, стоит другой антивирус. Запусти полную проверку в нём.'
        Write-Info 'Дополнительно можно проверить бесплатными одноразовыми сканерами: Dr.Web CureIt! или Kaspersky Virus Removal Tool.'
        return
    }
    $quick = Confirm-Action 'Быстрая проверка (5–15 минут)? «н» — полная (может идти несколько часов)' $true
    Write-Info 'Обновляю антивирусные базы...'
    try { Update-MpSignature -ErrorAction Stop } catch { Write-Warn 'Базы обновить не удалось, проверяю со старыми.' }
    Write-Info 'Идёт проверка, окно может не меняться долгое время — это нормально...'
    try {
        if ($quick) { Start-MpScan -ScanType QuickScan -ErrorAction Stop } else { Start-MpScan -ScanType FullScan -ErrorAction Stop }
    } catch {
        Write-Warn "Проверка не запустилась: $($_.Exception.Message)"
        return
    }
    $threats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddDays(-1) })
    if ($threats.Count -eq 0) {
        Write-Ok 'Угроз не найдено.'
    } else {
        Write-Bad "Найдено угроз: $($threats.Count). Защитник их обезвредил или поместил в карантин:"
        foreach ($t in Get-MpThreat -ErrorAction SilentlyContinue) { Write-Info "• $($t.ThreatName)" }
        Write-Info 'Подробности: Безопасность Windows → Защита от вирусов и угроз → Журнал защиты.'
    }
}

while ($true) {
    Clear-Host
    Write-Title 'Оптимизация и очистка компьютера'
    Write-Host ''
    Write-Host '   1  Диагностика — проверить всё и сохранить отчёт (ничего не меняет)'
    Write-Host '   2  Очистка мусора'
    Write-Host '   3  Оптимизация Windows (питание, автозагрузка, эффекты)'
    Write-Host '   4  Проверка и восстановление системных файлов (15–40 мин)'
    Write-Host '   5  Проверка на вирусы и майнеры'
    Write-Host '   6  Откат — отменить изменения пункта 3'
    Write-Host '   0  Выход'
    Write-Host ''
    Write-Info 'Советуем порядок: 1 → 2 → 3 → перезагрузка.'
    $choice = Read-Host '  Выбери пункт'
    switch ("$choice".Trim()) {
        '1' { & (Join-Path $PSScriptRoot 'diagnose.ps1') }
        '2' { & (Join-Path $PSScriptRoot 'cleanup.ps1') }
        '3' { & (Join-Path $PSScriptRoot 'optimize.ps1') }
        '4' { Invoke-SystemRepair }
        '5' { Invoke-VirusScan }
        '6' {
            Write-Title 'Откат изменений'
            if (Confirm-Action 'Вернуть все настройки, изменённые пунктом 3?' $false) { Undo-Changes }
        }
        '0' { exit 0 }
        default { Write-Warn 'Нет такого пункта.' }
    }
    Write-Host ''
    Read-Host '  Нажми Enter, чтобы вернуться в меню' | Out-Null
}
