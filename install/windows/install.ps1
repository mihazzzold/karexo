<#
    Установка и обновление karexo на Windows.

    Ставит один файл: приложение внутри него, папки со статикой рядом нет.
    Повторный запуск = обновление: служба останавливается, бинарь подменяется,
    служба запускается снова. Данные и настройки не трогаются.

        .\install.ps1              поставить или обновить
        .\install.ps1 -Uninstall   снять службу (данные остаются)

    Нужны права администратора: служба и каталог в ProgramData иначе не заводятся.

    ⚠️ Windows может показать предупреждение SmartScreen - файл не подписан.
    Как это пройти, написано в README.md рядом.
#>

[CmdletBinding()]
param(
    # Снять службу. Данные и настройки при этом остаются на месте.
    [switch]$Uninstall,
    # Порт, на котором karexo слушает. Меняется и потом - в файле настроек.
    [int]$Port = 8080
)

$ErrorActionPreference = 'Stop'

$ServiceName = 'karexo'
$InstallDir  = Join-Path $env:ProgramFiles 'karexo'
$DataDir     = Join-Path $env:ProgramData 'karexo'
$EnvFile     = Join-Path $DataDir 'karexo.env'
$ExePath     = Join-Path $InstallDir 'karexo-server.exe'

function Assert-Admin {
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Нужны права администратора: запустите PowerShell от имени администратора'
    }
}

Assert-Admin

# ─── Снятие ──────────────────────────────────────────────────────────────────
if ($Uninstall) {
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Host 'Останавливаю службу…'
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        # sc.exe, а не Remove-Service: последний появился только в PowerShell 6,
        # а на свежей Windows из коробки стоит Windows PowerShell 5.1.
        & sc.exe delete $ServiceName | Out-Null
    }
    if (Test-Path $ExePath) { Remove-Item $ExePath -Force }
    Write-Host ''
    Write-Host 'Служба снята. НЕ удалены (это ваши данные):'
    Write-Host "  $DataDir   - база и вложения"
    Write-Host "  $EnvFile   - настройки"
    exit 0
}

# ─── Установка и обновление ──────────────────────────────────────────────────
$source = Join-Path $PSScriptRoot 'karexo-server.exe'
if (-not (Test-Path $source)) {
    throw "не найден $source - запускайте скрипт из распакованного архива"
}

$firstRun = -not (Test-Path $ExePath)

New-Item -ItemType Directory -Force -Path $InstallDir, $DataDir | Out-Null

# Ключ шифрования токенов генерируем САМИ при первой установке. Иначе человек
# либо пропустит шаг (и токены интеграций станут нечитаемыми после перезапуска),
# либо придумает «karexo123».
if (-not (Test-Path $EnvFile)) {
    Write-Host "Создаю $EnvFile…"
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $tokenKey = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''

    @"
# Настройки karexo. После правки: Restart-Service karexo
#
# Внешний адрес инстанса - уходит в письма и публичные ссылки.
KAREXO_BASE_URL=http://localhost:$Port

# Ключ шифрования токенов интеграций. Сгенерирован при установке.
# Смена ключа делает сохранённые токены нечитаемыми.
KAREXO_TOKEN_KEY=$tokenKey

# Адрес прослушивания
KAREXO_ADDR=:$Port

# open | invite | closed - кто может завести аккаунт
KAREXO_REGISTRATION=invite

# Почта: без неё не уходят коды входа и приглашения
#KAREXO_SMTP_HOST=
#KAREXO_SMTP_PORT=587
#KAREXO_SMTP_USER=
#KAREXO_SMTP_PASS=
#KAREXO_SMTP_FROM=

# Полный список настроек - в env.example рядом со скриптом.
"@ | Set-Content -Path $EnvFile -Encoding UTF8

    # Файл читает только система и администраторы: внутри пароль от почты.
    $acl = Get-Acl $EnvFile
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($who in 'SYSTEM', 'Administrators') {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $who, 'FullControl', 'Allow')))
    }
    Set-Acl -Path $EnvFile -AclObject $acl
}

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host 'Останавливаю службу на время замены…'
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    # Windows не даёт заменить файл работающего процесса, а остановка службы
    # возвращает управление раньше, чем процесс действительно завершился.
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Process -Name 'karexo-server' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
}

Write-Host 'Ставлю программу…'
Copy-Item -Path $source -Destination $ExePath -Force

<#
    Настройки службе передаются переменными окружения самой службы.

    В Windows нет EnvironmentFile, как у systemd: служба читает окружение из
    своего ключа реестра. Поэтому файл настроек разбираем здесь и кладём в
    реестр - человек по-прежнему правит понятный текстовый файл, а не regedit.
#>
$envLines = @()
foreach ($line in Get-Content $EnvFile) {
    $trimmed = $line.Trim()
    if ($trimmed -and -not $trimmed.StartsWith('#') -and $trimmed.Contains('=')) {
        $envLines += $trimmed
    }
}
$envLines += "KAREXO_DATA=$DataDir"

if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
    Write-Host 'Завожу службу…'
    # binPath с кавычками: путь содержит пробел («Program Files»), и без них
    # SCM считает частью пути только первое слово.
    & sc.exe create $ServiceName binPath= "`"$ExePath`"" start= auto DisplayName= 'karexo' | Out-Null
    & sc.exe description $ServiceName 'karexo - база знаний на своём сервере' | Out-Null
    # Перезапуск после падения: без этого одна ошибка означает молча
    # неработающий инстанс до тех пор, пока кто-нибудь не заметит.
    & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
}

$key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
Set-ItemProperty -Path $key -Name Environment -Value $envLines -Type MultiString

Write-Host 'Запускаю…'
Start-Service -Name $ServiceName

# Дать службе секунду и проверить, что она правда поднялась: «установлено
# успешно» при упавшем процессе - худший из возможных ответов.
Start-Sleep -Seconds 2
$svc = Get-Service -Name $ServiceName
if ($svc.Status -ne 'Running') {
    Write-Host ''
    Write-Host "Служба не запустилась (состояние: $($svc.Status))." -ForegroundColor Red
    Write-Host 'Последние записи журнала:'
    Get-EventLog -LogName Application -Source $ServiceName -Newest 10 -ErrorAction SilentlyContinue |
        Format-List TimeGenerated, Message
    throw 'разберитесь с журналом и запустите скрипт снова'
}

$version = & $ExePath -version
Write-Host ''
if ($firstRun) {
    Write-Host "karexo установлен и запущен. $version" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Дальше:'
    Write-Host "  1. Впишите свой адрес в $EnvFile (KAREXO_BASE_URL)"
    Write-Host '  2. Restart-Service karexo'
    Write-Host "  3. Откройте http://localhost:$Port - ПЕРВЫЙ аккаунт становится владельцем"
} else {
    Write-Host "karexo обновлён и перезапущен. $version" -ForegroundColor Green
}
Write-Host ''
Write-Host "  данные:    $DataDir"
Write-Host "  настройки: $EnvFile"
Write-Host '  состояние: Get-Service karexo'
