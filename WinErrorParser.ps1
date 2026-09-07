#Requires -Version 5.1
# Encoding: UTF-8 with BOM (обязательно для Windows PowerShell 5.1 + кириллица)
# WinErrorParser 2.1 — диагностика ПК Windows (консоль + TXT + HTML)
# Запуск: от имени администратора через Start-WinErrorParser.bat

[CmdletBinding()]
param(
    [ValidateRange(1, 3650)]
    [int]$DaysBack = 14,

    [string]$ReportPath,

    [switch]$NonInteractive,

    [switch]$FullReport,

    [ValidateSet('ru', 'en')]
    [string]$Language = 'ru',

    [switch]$NoHtml,

    [ValidateSet('Menu', 'Diagnose')]
    [string]$Action = 'Menu'
)

$ErrorActionPreference = 'Continue'
try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue } catch {}

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    chcp 65001 | Out-Null
} catch {}

$Script:Version = '2.1.0'
$Script:DaysBack = $DaysBack
$Script:Lang = $Language.ToLowerInvariant()
$Script:FullReport = [bool]$FullReport
$Script:NonInteractive = [bool]$NonInteractive
if ($Script:NonInteractive) { $Action = 'Diagnose' }
$Script:WriteHtml = -not $NoHtml
$Script:CustomReportPath = $ReportPath
$Script:WindowMinutes = 5
$Script:StartDate = (Get-Date).AddDays(-$Script:DaysBack)
$Script:ReportPath = Join-Path $PSScriptRoot 'WinErrorParser_Report_RU.txt'
$Script:HtmlPath = Join-Path $PSScriptRoot 'WinErrorParser_Report_RU.html'
$Script:StatePath = Join-Path $PSScriptRoot 'WinErrorParser_LastState.json'
$Script:Report = New-Object System.Text.StringBuilder
$Script:ReportHtml = New-Object System.Collections.Generic.List[object]
$Script:IssueTypes = New-Object System.Collections.Generic.HashSet[string]
$Script:CriticalTypes = New-Object System.Collections.Generic.HashSet[string]
$Script:Findings = New-Object System.Collections.ArrayList
$Script:EventCache = @{ System = @(); Application = @(); Setup = @() }
$Script:CacheReady = $false
$Script:ProgressStep = 0
$Script:ProgressTotal = 21
$Script:DiskByNumber = @{}
$Script:LetterToDisk = @{}
$Script:DiskMapReady = $false
$Script:SoftCrashHidden = 0
$Script:LastUpdateInfo = $null
$Script:PreviousState = $null
$Script:CompareLines = @()
$Script:DumpEnabled = $null
$Script:FastStartup = $null
$Script:PendingReboot = $false

# ---------------------------------------------------------------------------
# Язык
# ---------------------------------------------------------------------------
function L {
    param([string]$Ru, [string]$En = '')
    if ($Script:Lang -eq 'en' -and -not [string]::IsNullOrWhiteSpace($En)) { return $En }
    return $Ru
}

# ---------------------------------------------------------------------------
# База пояснений по источникам событий Windows (ProviderName)
# ---------------------------------------------------------------------------
$Script:ErrorExplain = @{
    'disk' = @{
        Title = 'Ошибка диска / контроллера накопителя'; TitleEn = 'Disk / storage controller error'
        Text  = 'Система потеряла связь с физическим диском (SSD/HDD) или его контроллером. Типичные причины: плохой кабель/разъём M.2, перегрев NVMe, сбой прошивки SSD, нестабильное питание. Часто приводит к зависаниям и внезапным перезагрузкам.'
        TextEn = 'Windows lost contact with a physical disk or its controller. Typical causes: bad cable/M.2 seat, NVMe overheating, SSD firmware, unstable power. Often leads to freezes and sudden reboots.'
        Level = 'Critical'
    }
    'ntfs' = @{
        Title = 'Ошибка файловой системы NTFS'; TitleEn = 'NTFS file system error'
        Text  = 'Проблемы чтения/записи тома NTFS: повреждённые метаданные, сбой диска или некорректное отключение. Рекомендуется chkdsk /f и проверка здоровья накопителя.'
        TextEn = 'NTFS read/write issues: damaged metadata, disk failure, or unclean shutdown. Run chkdsk /f and check drive health.'
        Level = 'Warning'
    }
    'volmgr' = @{
        Title = 'Диспетчер томов (сбой дампа памяти)'; TitleEn = 'Volume Manager (crash dump failure)'
        Text  = 'Windows не смогла записать дамп при сбое: том или диск исчезли в момент краша. Часто сопровождает внезапное отключение SSD или Kernel-Power 41.'
        TextEn = 'Windows could not write a crash dump: the volume vanished during the crash. Often accompanies a sudden SSD drop or Kernel-Power 41.'
        Level = 'Critical'
    }
    'iaStor' = @{
        Title = 'Драйвер Intel Rapid Storage (RST)'; TitleEn = 'Intel Rapid Storage (RST) driver'
        Text  = 'Сбой драйвера Intel RST / AHCI. Обновите RST/чипсет, проверьте режим SATA в BIOS и кабели/слоты накопителей.'
        TextEn = 'Intel RST/AHCI driver fault. Update RST/chipset, check SATA mode in BIOS and storage cables/slots.'
        Level = 'Warning'
    }
    'iaStorV' = @{
        Title = 'Драйвер Intel RST (iaStorV)'; TitleEn = 'Intel RST driver (iaStorV)'
        Text  = 'Ошибки виртуального драйвера Intel Storage. Обновите пакет Intel RST и прошивку SSD.'
        TextEn = 'Intel Storage virtual driver errors. Update Intel RST and SSD firmware.'
        Level = 'Warning'
    }
    'stornvme' = @{
        Title = 'Драйвер NVMe (Windows)'; TitleEn = 'Windows NVMe driver'
        Text  = 'Сбой встроенного NVMe-драйвера. Возможны перегрев M.2, несовместимая прошивка SSD или проблемы слота PCIe.'
        TextEn = 'Built-in NVMe driver fault. Possible M.2 overheating, incompatible SSD firmware, or PCIe slot issues.'
        Level = 'Critical'
    }
    'storahci' = @{
        Title = 'Драйвер AHCI'; TitleEn = 'AHCI driver'
        Text  = 'Ошибки AHCI-контроллера. Проверьте кабели SATA, питание и обновите драйвер чипсета.'
        TextEn = 'AHCI controller errors. Check SATA cables/power and update the chipset driver.'
        Level = 'Warning'
    }
    'partmgr' = @{
        Title = 'Диспетчер разделов'; TitleEn = 'Partition Manager'
        Text  = 'Проблемы с таблицей разделов или доступом к разделам. Может указывать на повреждение диска или конфликт инструментов разметки.'
        TextEn = 'Partition table or volume access problems. May indicate a damaged disk or a partitioning tool conflict.'
        Level = 'Warning'
    }
    'Virtual Disk Service' = @{
        Title = 'Служба виртуальных дисков'; TitleEn = 'Virtual Disk Service'
        Text  = 'Сбой VDS при работе с дисками/томами. Проверьте диспетчер дисков и состояние накопителей.'
        TextEn = 'VDS failed while working with disks/volumes. Check Disk Management and drive health.'
        Level = 'Info'
    }
    'Microsoft-Windows-Kernel-Power' = @{
        Title = 'Ядро: питание / внезапная перезагрузка'; TitleEn = 'Kernel: power / unexpected reboot'
        Text  = 'Система выключилась или перезагрузилась без корректного завершения. Event ID 41 — критический признак: питание пропало мгновенно (БП, батарея, отвал SSD, зависание CPU/GPU, перегрев).'
        TextEn = 'The system powered off or rebooted without a clean shutdown. Event ID 41 is critical: instant power loss (PSU, battery, SSD drop, CPU/GPU hang, overheating).'
        Level = 'Critical'
    }
    'Microsoft-Windows-Kernel-Processor-Power' = @{
        Title = 'Питание процессора'; TitleEn = 'Processor power'
        Text  = 'Аномалии C-states / парковки ядер / энергосбережения CPU. Обновите BIOS и драйвер чипсета; отключите агрессивные режимы экономии для проверки.'
        TextEn = 'C-state / core parking / CPU power anomalies. Update BIOS and chipset; disable aggressive power saving for a test.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Kernel-General' = @{
        Title = 'Общие события ядра'; TitleEn = 'Kernel general'
        Text  = 'События запуска/останова и сбоев ядра. Вместе с BugCheck указывают на BSOD или аварийную перезагрузку.'
        TextEn = 'Kernel start/stop and failure events. Together with BugCheck they point to a BSOD or crash reboot.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Kernel-Boot' = @{
        Title = 'Загрузка ядра'; TitleEn = 'Kernel boot'
        Text  = 'Проблемы на этапе загрузки Windows. Проверьте BCD, Secure Boot, повреждения системного раздела.'
        TextEn = 'Problems during Windows boot. Check BCD, Secure Boot, and the system partition.'
        Level = 'Warning'
    }
    'EventLog' = @{
        Title = 'Журнал событий'; TitleEn = 'Event Log service'
        Text  = 'Служба журнала зафиксировала аномалию (часто после жёсткой перезагрузки журнал «грязно» закрыт). Само по себе не причина, а следствие сбоя. ID 6008 — предыдущее завершение работы было неожиданным.'
        TextEn = 'The log service recorded an anomaly (often a dirty close after a hard reboot). Usually a symptom, not the cause. ID 6008 means the previous shutdown was unexpected.'
        Level = 'Info'
    }
    'Microsoft-Windows-WHEA-Logger' = @{
        Title = 'WHEA: аппаратная ошибка'; TitleEn = 'WHEA: hardware error'
        Text  = 'Windows Hardware Error Architecture: сбой CPU, RAM, PCIe или устройства. Event ID 1/2 — исправленные ошибки; 17/18/19 — серьёзные аппаратные. Часто RAM, перегрев CPU, нестабильный разгон, сбой PCIe/NVMe.'
        TextEn = 'Windows Hardware Error Architecture: CPU, RAM, PCIe, or device fault. IDs 1/2 are corrected; 17/18/19 are serious. Often RAM, CPU heat, overclocking, or PCIe/NVMe.'
        Level = 'Critical'
    }
    'Microsoft-Windows-HAL' = @{
        Title = 'HAL (уровень абстракции оборудования)'; TitleEn = 'HAL (hardware abstraction)'
        Text  = 'Проблемы взаимодействия ОС с железом. Проверьте BIOS, совместимость и целостность системных файлов (sfc /scannow).'
        TextEn = 'OS-to-hardware interaction issues. Check BIOS, compatibility, and run sfc /scannow.'
        Level = 'Warning'
    }
    'Microsoft-Windows-WER-SystemErrorReporting' = @{
        Title = 'Отчёт о системной ошибке (BSOD)'; TitleEn = 'System error report (BSOD)'
        Text  = 'Windows Error Reporting зафиксировал критический сбой системы (синий экран). Смотрите код BugCheck, модуль/процесс и минидампы в C:\Windows\Minidump.'
        TextEn = 'Windows Error Reporting recorded a bugcheck (blue screen). Check the STOP code, faulting module/process, and minidumps in C:\Windows\Minidump.'
        Level = 'Critical'
    }
    'BugCheck' = @{
        Title = 'Синий экран (BugCheck)'; TitleEn = 'Blue screen (BugCheck)'
        Text  = 'Зафиксирован код STOP/BugCheck. Ниже скрипт расшифровывает код, типичную причину и модуль/процесс, если они есть в событии или отчёте WER.'
        TextEn = 'A STOP/BugCheck code was recorded. The script decodes the code, typical cause, and module/process when present in the event or WER report.'
        Level = 'Critical'
    }
    'Microsoft-Windows-WindowsUpdateClient' = @{
        Title = 'Клиент Центра обновления Windows'; TitleEn = 'Windows Update client'
        Text  = 'Сбой загрузки/установки обновлений: повреждён кэш SoftwareDistribution, конфликт антивируса, нехватка места, сбой службы wuauserv/BITS, проблемы с сетью или каталогом обновлений.'
        TextEn = 'Update download/install failed: SoftwareDistribution cache, AV conflict, low disk space, wuauserv/BITS, or network/catalog issues.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Application-Experience' = @{
        Title = 'Совместимость приложений'; TitleEn = 'Application Experience'
        Text  = 'Проблемы совместимости ПО с текущей версией Windows. Обновите программу или включите режим совместимости.'
        TextEn = 'Software compatibility issue with this Windows version. Update the app or use compatibility mode.'
        Level = 'Info'
    }
    'Service Control Manager' = @{
        Title = 'Диспетчер управления службами'; TitleEn = 'Service Control Manager'
        Text  = 'Служба не запустилась, зависла или завершилась с ошибкой (зависимости, права, повреждённый исполняемый файл, таймаут). Частые Event ID: 7000/7001/7023/7031/7034.'
        TextEn = 'A service failed to start, hung, or crashed (dependencies, rights, damaged binary, timeout). Common IDs: 7000/7001/7023/7031/7034.'
        Level = 'Warning'
    }
    'Service Control Manager 1' = @{
        Title = 'Диспетчер служб'; TitleEn = 'Service Control Manager'
        Text  = 'Ошибка запуска или остановки службы Windows.'; TextEn = 'A Windows service failed to start or stop.'
        Level = 'Warning'
    }
    'Microsoft-Windows-DriverFrameworks-UserMode' = @{
        Title = 'Пользовательский фреймворк драйверов (UMDF)'; TitleEn = 'User-Mode Driver Framework (UMDF)'
        Text  = 'Сбой user-mode драйвера (часто USB, принтеры, сканеры). Обновите/переустановите драйвер устройства.'
        TextEn = 'User-mode driver fault (often USB, printers, scanners). Update/reinstall the device driver.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Kernel-PnP' = @{
        Title = 'Plug and Play'; TitleEn = 'Plug and Play'
        Text  = 'Ошибка установки/запуска устройства: конфликт ресурсов, повреждённый драйвер, устройство отключилось. Смотрите Диспетчер устройств на жёлтые значки.'
        TextEn = 'Device install/start failed: resource conflict, damaged driver, or the device dropped. Check Device Manager for warning icons.'
        Level = 'Warning'
    }
    'Microsoft-Windows-UserPnp' = @{
        Title = 'Установка устройств (UserPnp)'; TitleEn = 'Device install (UserPnp)'
        Text  = 'Сбой установки драйвера устройства. Загрузите драйвер с сайта производителя (не через случайный «драйвер-пак»).'
        TextEn = 'Device driver setup failed. Download the driver from the vendor (not a random driver pack).'
        Level = 'Warning'
    }
    'Display' = @{
        Title = 'Подсистема дисплея'; TitleEn = 'Display subsystem'
        Text  = 'Сбой видеодрайвера или адаптера. Обновите драйвер GPU (чистая установка), проверьте перегрев и кабель монитора.'
        TextEn = 'Video driver or adapter fault. Clean-install the GPU driver; check heat and the monitor cable.'
        Level = 'Warning'
    }
    'nvlddmkm' = @{
        Title = 'Драйвер NVIDIA'; TitleEn = 'NVIDIA driver'
        Text  = 'Падение драйвера NVIDIA (часто TDR: «видеодрайвер перестал отвечать»). Обновите/откатитесь; при повторе — проверка GPU, питания и перегрева.'
        TextEn = 'NVIDIA driver crash (often TDR: “display driver stopped responding”). Update/rollback; if it repeats, check GPU, power, and heat.'
        Level = 'Critical'
    }
    'amdkmdag' = @{
        Title = 'Драйвер AMD'; TitleEn = 'AMD driver'
        Text  = 'Сбой драйвера AMD Graphics. Чистая переустановка Adrenalin; проверьте температуры и стабильность GPU.'
        TextEn = 'AMD Graphics driver fault. Clean-install Adrenalin; check GPU temperature and stability.'
        Level = 'Critical'
    }
    'igfx' = @{
        Title = 'Драйвер Intel Graphics'; TitleEn = 'Intel Graphics driver'
        Text  = 'Сбой интегрированной графики Intel. Обновите драйвер с сайта Intel/производителя ноутбука.'
        TextEn = 'Intel iGPU driver fault. Update from Intel or the laptop vendor.'
        Level = 'Warning'
    }
    'Tcpip' = @{
        Title = 'Стек TCP/IP'; TitleEn = 'TCP/IP stack'
        Text  = 'Сетевые ошибки IP: дубли адресов, сброс интерфейса, проблемы маршрутизации. Проверьте адаптер, драйвер NIC и netsh winsock reset (осторожно).'
        TextEn = 'IP stack errors: duplicate address, interface reset, routing. Check the NIC driver; netsh winsock reset only if needed.'
        Level = 'Warning'
    }
    'e1dexpress' = @{
        Title = 'Сетевой адаптер Intel Ethernet'; TitleEn = 'Intel Ethernet adapter'
        Text  = 'Сбой драйвера Intel Ethernet. Обновите драйвер NIC; проверьте кабель и энергосбережение адаптера.'
        TextEn = 'Intel Ethernet driver fault. Update the NIC driver; check the cable and adapter power saving.'
        Level = 'Warning'
    }
    'Netwtw' = @{
        Title = 'Беспроводной адаптер Intel Wi-Fi'; TitleEn = 'Intel Wi-Fi adapter'
        Text  = 'Ошибки Intel Wireless. Обновите Wi-Fi драйвер; отключите «разрешить отключение для экономии энергии» в свойствах устройства.'
        TextEn = 'Intel Wireless errors. Update the Wi-Fi driver; disable “allow the computer to turn off this device to save power”.'
        Level = 'Warning'
    }
    'Microsoft-Windows-NDIS' = @{
        Title = 'NDIS (сетевой стек)'; TitleEn = 'NDIS (network stack)'
        Text  = 'Сбой сетевого драйвера на уровне NDIS. Переустановите драйвер сетевой карты.'
        TextEn = 'NDIS-level network driver fault. Reinstall the NIC driver.'
        Level = 'Warning'
    }
    'Microsoft-Windows-DHCP-Client' = @{
        Title = 'Клиент DHCP'; TitleEn = 'DHCP client'
        Text  = 'Не получен IP-адрес от DHCP. Проверьте роутер, кабель/Wi-Fi и службу Dhcp.'
        TextEn = 'No DHCP lease. Check the router, cable/Wi-Fi, and the Dhcp service.'
        Level = 'Warning'
    }
    'Microsoft-Windows-DNS-Client' = @{
        Title = 'Клиент DNS'; TitleEn = 'DNS client'
        Text  = 'Не удалось разрешить имя хоста. Смените DNS (например 1.1.1.1 / 8.8.8.8) или проверьте роутер.'
        TextEn = 'Hostname lookup failed. Try other DNS (1.1.1.1 / 8.8.8.8) or check the router.'
        Level = 'Info'
    }
    'NetBT' = @{
        Title = 'NetBIOS через TCP/IP'; TitleEn = 'NetBIOS over TCP/IP'
        Text  = 'Конфликт имён NetBIOS или проблемы локальной сети. Обычно некритично для домашнего ПК.'
        TextEn = 'NetBIOS name conflict or LAN issue. Usually not critical on a home PC.'
        Level = 'Info'
    }
    'Server' = @{
        Title = 'Служба Server (общий доступ)'; TitleEn = 'Server service (file share)'
        Text  = 'Ошибки файлового/принтерного общего доступа. Проверьте службу LanmanServer и брандмауэр.'
        TextEn = 'File/printer sharing errors. Check LanmanServer and the firewall.'
        Level = 'Info'
    }
    'Microsoft-Windows-MemoryDiagnostics-Results' = @{
        Title = 'Диагностика памяти Windows'; TitleEn = 'Windows Memory Diagnostics'
        Text  = 'Результат проверки ОЗУ. Если найдены ошибки — замените модуль RAM или проверьте слоты/XMP.'
        TextEn = 'RAM test result. If errors were found, replace the module or check slots/XMP.'
        Level = 'Critical'
    }
    '.NET Runtime' = @{
        Title = 'Среда .NET'; TitleEn = '.NET runtime'
        Text  = 'Сбой приложения на .NET. Переустановите .NET Runtime / Visual C++ Redistributable или само приложение.'
        TextEn = '.NET application crash. Reinstall .NET Runtime / VC++ redistributable or the app itself.'
        Level = 'Info'
    }
    'Application Error' = @{
        Title = 'Ошибка приложения'; TitleEn = 'Application Error'
        Text  = 'Программа аварийно завершилась (faulting module). Для системных процессов (csrss, dwm, explorer, svchost) это может быть признаком драйвера, RAM или диска.'
        TextEn = 'A program crashed (faulting module). For system processes (csrss, dwm, explorer, svchost) this can point to a driver, RAM, or disk.'
        Level = 'Warning'
    }
    'Application Hang' = @{
        Title = 'Зависание приложения'; TitleEn = 'Application Hang'
        Text  = 'Программа перестала отвечать. Может быть связано с диском, драйверами или нехваткой памяти.'
        TextEn = 'A program stopped responding. May relate to disk, drivers, or low memory.'
        Level = 'Info'
    }
    'SideBySide' = @{
        Title = 'Side-by-Side (Visual C++)'; TitleEn = 'Side-by-Side (Visual C++)'
        Text  = 'Отсутствует нужный Visual C++ Redistributable. Установите актуальные пакеты VC++ x86/x64 с сайта Microsoft.'
        TextEn = 'A required Visual C++ Redistributable is missing. Install current VC++ x86/x64 packages from Microsoft.'
        Level = 'Warning'
    }
    'Windows Error Reporting' = @{
        Title = 'Отчёты об ошибках Windows'; TitleEn = 'Windows Error Reporting'
        Text  = 'Система собрала отчёт о сбое приложения или компонента. Смотрите связанное событие Application Error.'
        TextEn = 'Windows collected a crash report. See the related Application Error event.'
        Level = 'Info'
    }
    'Microsoft-Windows-Windows Defender' = @{
        Title = 'Защитник Windows'; TitleEn = 'Microsoft Defender'
        Text  = 'События антивируса: угрозы, сбой обновления сигнатур или службы. Проверьте историю защиты в «Безопасность Windows».'
        TextEn = 'Antivirus events: threats, signature update failure, or service issues. Check Windows Security protection history.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Security-SPP' = @{
        Title = 'Лицензирование Windows (SPP)'; TitleEn = 'Windows licensing (SPP)'
        Text  = 'Проблемы активации/лицензии. Проверьте состояние: slmgr /xpr'
        TextEn = 'Activation/license issues. Check with: slmgr /xpr'
        Level = 'Info'
    }
    'Microsoft-Windows-CodeIntegrity' = @{
        Title = 'Целостность кода'; TitleEn = 'Code Integrity'
        Text  = 'Заблокирован неподписанный или повреждённый драйвер/модуль. Удалите сомнительное ПО и обновите драйверы.'
        TextEn = 'An unsigned or damaged driver/module was blocked. Remove shady software and update drivers.'
        Level = 'Warning'
    }
    'Microsoft-Windows-FilterManager' = @{
        Title = 'Диспетчер фильтров'; TitleEn = 'Filter Manager'
        Text  = 'Сбой мини-фильтра ФС (антивирус, шифрование, бэкап). Часто конфликт стороннего фильтра с диском.'
        TextEn = 'File-system minifilter fault (AV, encryption, backup). Often a third-party filter conflicting with storage.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Audio' = @{
        Title = 'Аудиоподсистема'; TitleEn = 'Audio subsystem'
        Text  = 'Сбой звукового стека. Обновите аудиодрайвер Realtek/производителя; перезапустите службу Windows Audio.'
        TextEn = 'Audio stack fault. Update the Realtek/OEM audio driver; restart Windows Audio.'
        Level = 'Info'
    }
    'USB' = @{
        Title = 'Шина USB'; TitleEn = 'USB bus'
        Text  = 'Ошибка устройства USB: отвал порта, нехватка питания, плохой кабель. Отключите энергосбережение USB Root Hub.'
        TextEn = 'USB device error: port drop, not enough power, bad cable. Disable USB Root Hub power saving.'
        Level = 'Warning'
    }
    'Microsoft-Windows-USB-USBXHCI' = @{
        Title = 'Контроллер USB xHCI'; TitleEn = 'USB xHCI controller'
        Text  = 'Сбой USB 3.x контроллера. Обновите чипсет/BIOS; проверьте устройства на портах.'
        TextEn = 'USB 3.x controller fault. Update chipset/BIOS; check devices on the ports.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Time-Service' = @{
        Title = 'Служба времени'; TitleEn = 'Time service'
        Text  = 'Проблемы синхронизации часов. Проверьте интернет и w32tm /resync.'
        TextEn = 'Clock sync problems. Check the internet and run w32tm /resync.'
        Level = 'Info'
    }
    'Microsoft-Windows-DistributedCOM' = @{
        Title = 'DCOM'; TitleEn = 'DCOM'
        Text  = 'Ошибки распределённой COM (часто права доступа к приложению). Обычно шум в журнале; критично только при сбоях конкретной службы.'
        TextEn = 'Distributed COM errors (often app launch permissions). Usually log noise; critical only if a specific service fails.'
        Level = 'Info'
    }
    'Microsoft-Windows-PerfNet' = @{
        Title = 'Счётчики производительности сети'; TitleEn = 'Network performance counters'
        Text  = 'Сбой счётчиков PerfNet. Редко влияет на работу ПК; lodctr /r при необходимости.'
        TextEn = 'PerfNet counter failure. Rarely affects the PC; lodctr /r if needed.'
        Level = 'Info'
    }
    'Microsoft-Windows-Resource-Exhaustion-Detector' = @{
        Title = 'Исчерпание ресурсов'; TitleEn = 'Resource exhaustion'
        Text  = 'Заканчивается ОЗУ или ресурсы системы. Закройте тяжёлые программы; проверьте утечки памяти и объём RAM.'
        TextEn = 'RAM or commit is running out. Close heavy apps; check for leaks and installed memory size.'
        Level = 'Critical'
    }
    'Microsoft-Windows-Resource-Exhaustion-Resolver' = @{
        Title = 'Реакция на нехватку ресурсов'; TitleEn = 'Resource exhaustion resolver'
        Text  = 'Система пыталась освободить память из-за исчерпания ресурсов.'
        TextEn = 'Windows tried to free memory because resources were exhausted.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Wininit' = @{
        Title = 'Инициализация Windows'; TitleEn = 'Windows initialization'
        Text  = 'События автозапуска/инициализации. Вместе с chkdsk может указывать на проверку диска при загрузке.'
        TextEn = 'Startup/init events. Together with chkdsk this may mean a boot-time disk check.'
        Level = 'Info'
    }
    'Microsoft-Windows-Winlogon' = @{
        Title = 'Вход в систему'; TitleEn = 'Winlogon'
        Text  = 'Проблемы оболочки входа. Проверьте автозагрузку и повреждённые профили пользователей.'
        TextEn = 'Logon shell problems. Check startup apps and damaged user profiles.'
        Level = 'Info'
    }
    'Schannel' = @{
        Title = 'Безопасный канал (TLS/SSL)'; TitleEn = 'Secure channel (TLS/SSL)'
        Text  = 'Ошибки TLS при защищённых соединениях. Обновите Windows; проверьте дату/время и корневые сертификаты.'
        TextEn = 'TLS errors on secure connections. Update Windows; check date/time and root certificates.'
        Level = 'Info'
    }
    'Microsoft-Windows-TPM-WMI' = @{
        Title = 'Модуль TPM'; TitleEn = 'TPM module'
        Text  = 'События TPM (BitLocker, Windows Hello). При ошибках проверьте TPM в BIOS и tpm.msc.'
        TextEn = 'TPM events (BitLocker, Windows Hello). On errors, check TPM in BIOS and tpm.msc.'
        Level = 'Info'
    }
    'Microsoft-Windows-Hyper-V-Hypervisor' = @{
        Title = 'Гипервизор Hyper-V'; TitleEn = 'Hyper-V hypervisor'
        Text  = 'Сбой Hyper-V / виртуализации. Конфликт с другими гипервизорами (VMware, VirtualBox, Android-эмуляторы).'
        TextEn = 'Hyper-V / virtualization fault. Conflict with other hypervisors (VMware, VirtualBox, Android emulators).'
        Level = 'Warning'
    }
    'Microsoft-Windows-Kernel-EventTracing' = @{
        Title = 'Трассировка событий ядра'; TitleEn = 'Kernel event tracing'
        Text  = 'Проблемы ETW-сессий. Обычно некритично.'; TextEn = 'ETW session issues. Usually not critical.'
        Level = 'Info'
    }
    'Microsoft-Windows-Diagnostics-Performance' = @{
        Title = 'Диагностика производительности'; TitleEn = 'Performance diagnostics'
        Text  = 'Медленный запуск/завершение работы. Смотрите «Монитор ресурсов» и автозагрузку.'
        TextEn = 'Slow boot/shutdown. Check Resource Monitor and startup apps.'
        Level = 'Info'
    }
}

$Script:EventIdExplain = @{
    'Microsoft-Windows-Kernel-Power|41' = @{
        Ru = 'Критическая внезапная перезагрузка: система не завершилась штатно. Часто SSD/NVMe, БП, перегрев, зависание драйвера.'
        En = 'Critical unexpected reboot: Windows did not shut down cleanly. Often SSD/NVMe, PSU, heat, or a hung driver.'
    }
    'Microsoft-Windows-Kernel-Power|42' = @{
        Ru = 'Система перешла в спящий режим (не всегда ошибка).'
        En = 'The system entered sleep (not always an error).'
    }
    'Microsoft-Windows-Kernel-Power|109' = @{
        Ru = 'Инициировано завершение работы ядром (часто обновление или штатный shutdown).'
        En = 'Kernel initiated shutdown (often an update or a clean shutdown).'
    }
    'Microsoft-Windows-Kernel-Power|172' = @{
        Ru = 'Проблема с батареей/источником питания ноутбука.'
        En = 'Laptop battery / power-source problem.'
    }
    'Microsoft-Windows-WHEA-Logger|1'  = @{ Ru = 'Исправленная аппаратная ошибка (Corrected). При частых повторах — RAM/CPU/перегрев.'; En = 'Corrected hardware error. Frequent repeats point to RAM/CPU/heat.' }
    'Microsoft-Windows-WHEA-Logger|2'  = @{ Ru = 'Исправленная ошибка (часто память или кэш). Запустите mdsched.exe.'; En = 'Corrected error (often memory or cache). Run mdsched.exe.' }
    'Microsoft-Windows-WHEA-Logger|3'  = @{ Ru = 'Неустранимая аппаратная ошибка (PCI Express / устройство). Часто NVMe, GPU, PCIe-устройство.'; En = 'Uncorrectable hardware error (PCIe / device). Often NVMe, GPU, or another PCIe device.' }
    'Microsoft-Windows-WHEA-Logger|17' = @{ Ru = 'WHEA: фатальная ошибка процессора/чипа.'; En = 'WHEA: fatal processor/chip error.' }
    'Microsoft-Windows-WHEA-Logger|18' = @{ Ru = 'WHEA: фатальная ошибка инициализирована ОС.'; En = 'WHEA: fatal error initiated by the OS.' }
    'Microsoft-Windows-WHEA-Logger|19' = @{ Ru = 'WHEA: исправленная ошибка с подробностями устройства.'; En = 'WHEA: corrected error with device details.' }
    'disk|7'   = @{ Ru = 'Устройство не готово / таймаут диска — классический признак отвала HDD/SSD.'; En = 'Device not ready / disk timeout — classic HDD/SSD drop.' }
    'disk|11'  = @{ Ru = 'Контроллер обнаружил ошибку на диске (CRC/сбой чтения).'; En = 'Controller detected a disk error (CRC/read failure).' }
    'disk|15'  = @{ Ru = 'Диск недоступен (устройство не существует).'; En = 'Disk unavailable (device does not exist).' }
    'disk|51'  = @{ Ru = 'Ошибка страничного файла / ввода-вывода на диске.'; En = 'Paging file / disk I/O error.' }
    'disk|153' = @{ Ru = 'Повторная операция ввода-вывода на диске (IO retry) — накопитель отвечает с задержками.'; En = 'Disk I/O retry — the drive is responding late.' }
    'ntfs|55'  = @{ Ru = 'Повреждение структуры NTFS на томе.'; En = 'NTFS structure damage on the volume.' }
    'ntfs|98'  = @{ Ru = 'Том повреждён и требует chkdsk.'; En = 'Volume is dirty and needs chkdsk.' }
    'volmgr|46' = @{ Ru = 'Сбой записи crash dump — том недоступен в момент краша.'; En = 'Crash dump write failed — volume was gone during the crash.' }
    'EventLog|6008' = @{ Ru = 'Предыдущее завершение работы системы было неожиданным (журнал не закрыт штатно).'; En = 'The previous system shutdown was unexpected (log was not closed cleanly).' }
    'BugCheck|1001' = @{ Ru = 'Синий экран: в описании события указан код BugCheck и параметры.'; En = 'Blue screen: the event text contains the BugCheck code and parameters.' }
    'Microsoft-Windows-WER-SystemErrorReporting|1001' = @{ Ru = 'Зарегистрирован отчёт о BugCheck/BSOD. Откройте событие для кода STOP.'; En = 'A BugCheck/BSOD report was registered. Open the event for the STOP code.' }
    'Service Control Manager|7000' = @{ Ru = 'Служба не запустилась (ошибка в параметре запуска или файле).'; En = 'Service failed to start (bad start parameter or file).' }
    'Service Control Manager|7001' = @{ Ru = 'Зависимая служба не запущена — каскадный сбой.'; En = 'A dependent service was not running — cascade failure.' }
    'Service Control Manager|7009' = @{ Ru = 'Таймаут ожидания ответа службы.'; En = 'Timed out waiting for the service.' }
    'Service Control Manager|7023' = @{ Ru = 'Служба завершилась с ошибкой.'; En = 'Service exited with an error.' }
    'Service Control Manager|7024' = @{ Ru = 'Служба завершилась со специфическим кодом ошибки.'; En = 'Service exited with a specific error code.' }
    'Service Control Manager|7031' = @{ Ru = 'Служба неожиданно завершилась и будет перезапущена.'; En = 'Service crashed unexpectedly and will be restarted.' }
    'Service Control Manager|7034' = @{ Ru = 'Служба аварийно завершилась.'; En = 'Service terminated unexpectedly.' }
    'Microsoft-Windows-WindowsUpdateClient|20' = @{ Ru = 'Сбой установки обновления.'; En = 'Update install failed.' }
    'Microsoft-Windows-WindowsUpdateClient|24' = @{ Ru = 'Установка обновления отменена / не завершена.'; En = 'Update install cancelled / incomplete.' }
    'Microsoft-Windows-WindowsUpdateClient|25' = @{ Ru = 'Сбой удаления обновления.'; En = 'Update uninstall failed.' }
    'Microsoft-Windows-WindowsUpdateClient|31' = @{ Ru = 'Сбой загрузки обновления (сеть, кэш, место на диске).'; En = 'Update download failed (network, cache, disk space).' }
    'Microsoft-Windows-WindowsUpdateClient|33' = @{ Ru = 'Не удалось запустить установку обновления.'; En = 'Could not start the update install.' }
    'Microsoft-Windows-WindowsUpdateClient|34' = @{ Ru = 'Ошибка скачивания: проверьте интернет и службы BITS/wuauserv.'; En = 'Download error: check internet and BITS/wuauserv.' }
    'Microsoft-Windows-WindowsUpdateClient|213' = @{ Ru = 'Сбой проверки обновлений (часто временный сбой сервиса Microsoft).'; En = 'Update check failed (often a temporary Microsoft service issue).' }
    'Microsoft-Windows-Kernel-PnP|219' = @{ Ru = 'Драйвер не загрузился вовремя (часто диск/фильтр при старте).'; En = 'Driver did not load in time (often disk/filter at boot).' }
    'Microsoft-Windows-Kernel-PnP|411' = @{ Ru = 'Устройство отключено из-за ошибки.'; En = 'Device disabled because of an error.' }
    'Display|4101' = @{ Ru = 'Timeout Detection and Recovery (TDR): видеодрайвер сброшен.'; En = 'Timeout Detection and Recovery (TDR): the video driver was reset.' }
    'Application Error|1000' = @{ Ru = 'Аварийное завершение процесса — смотрите имя модуля в деталях.'; En = 'Process crash — see the faulting module in the details.' }
    'Microsoft-Windows-Resource-Exhaustion-Detector|2004' = @{ Ru = 'Система испытывает нехватку виртуальной памяти / commit.'; En = 'The system is low on virtual memory / commit.' }
}

# Нормализованные GUID секций WHEA (без дефисов, верхний регистр)
$Script:WheaGuidMap = @{
    'D1A87C46B57E445B8B2E014E73D69D8B' = @{ Ru = 'Шина PCI Express / NVMe / устройство PCIe'; En = 'PCI Express bus / NVMe / PCIe device' }
    'A1EEDFFF1F56483D989B25BD69CB3E09' = @{ Ru = 'Оперативная память (RAM)'; En = 'System memory (RAM)' }
    '9876CCAD47B44BDBB17553E007EF21F2' = @{ Ru = 'Процессор (общий раздел WHEA)'; En = 'Processor (generic WHEA section)' }
    'DC3EA0B0A1444797B95B53FA242B6E1D' = @{ Ru = 'Процессор x86/x64 (конкретный раздел)'; En = 'x86/x64 processor (specific section)' }
    '5B3C8C9A9A0A4F0B8B5B0E0E0E0E0E01' = @{ Ru = 'Процессор (CPU)'; En = 'Processor (CPU)' }
    '81212A9609ED499694718D729C8E69ED' = @{ Ru = 'Прошивка / Firmware Error Record'; En = 'Firmware error record' }
    'E429FAF13CB711D4BCA70080C73C8881' = @{ Ru = 'Процессор (IPF/архитектурный раздел)'; En = 'Processor (architectural section)' }
    'C34832A1448A43DDA5F2A8A7DB8B4C68' = @{ Ru = 'NMI / платформенный сбой'; En = 'NMI / platform error' }
}

# Источники, которые обычно НЕ ломают ПК (шум журнала)
$Script:NoiseProviders = @(
    'Microsoft-Windows-WindowsUpdateClient',
    'Microsoft-Windows-DistributedCOM',
    'Microsoft-Windows-DNS-Client',
    'Microsoft-Windows-DHCP-Client',
    'Microsoft-Windows-Time-Service',
    'Microsoft-Windows-TPM-WMI',
    'Microsoft-Windows-Security-SPP',
    'Microsoft-Windows-Kernel-EventTracing',
    'Microsoft-Windows-PerfNet',
    'Microsoft-Windows-Application-Experience',
    'Microsoft-Windows-Diagnostics-Performance',
    'Microsoft-Windows-Winlogon',
    'Microsoft-Windows-Wininit',
    'Microsoft-Windows-CertificateServicesClient-Lifecycle-System',
    'Microsoft-Windows-Audio',
    'Schannel',
    'ESENT',
    'Software Protection Platform Service',
    '.NET Runtime',
    'SideBySide',
    'Application Hang',
    'Windows Error Reporting',
    'Microsoft-Windows-CAPI2',
    'Microsoft-Windows-Search',
    'Microsoft-Windows-Shell-Core',
    'VSS',
    'Microsoft-Windows-Backup',
    'NetBT',
    'Server',
    'Virtual Disk Service'
)

$Script:CriticalProviders = @(
    'Microsoft-Windows-Kernel-Power',
    'Microsoft-Windows-WHEA-Logger',
    'Microsoft-Windows-WER-SystemErrorReporting',
    'BugCheck',
    'disk', 'ntfs', 'volmgr', 'stornvme', 'storahci', 'iaStor', 'iaStorV', 'partmgr',
    'Display', 'nvlddmkm', 'amdkmdag', 'igfx',
    'Microsoft-Windows-Resource-Exhaustion-Detector',
    'Microsoft-Windows-MemoryDiagnostics-Results',
    'Microsoft-Windows-Kernel-PnP',
    'Microsoft-Windows-HAL',
    'EventLog',
    'Microsoft-Windows-Kernel-General',
    'Microsoft-Windows-USB-USBXHCI',
    'USB'
)

$Script:SystemProcessNames = @(
    'csrss.exe', 'wininit.exe', 'winlogon.exe', 'smss.exe', 'lsass.exe', 'services.exe',
    'svchost.exe', 'dwm.exe', 'explorer.exe', 'ntoskrnl.exe', 'ntoskrnl', 'System',
    'Registry', 'Memory Compression', 'MsMpEng.exe', 'SecurityHealthService.exe'
)

# Игры, браузеры и бытовой софт — не железо, в вердикт не тащим
$Script:SoftNoiseNames = @(
    'steam', 'steamwebhelper', 'gameoverlayui', 'chrome', 'firefox', 'msedge', 'iexplore',
    'discord', 'telegram', 'spotify', 'epicgameslauncher', 'epicwebhelper', 'origin',
    'upc.exe', 'ubisoft', 'battle.net', 'agent.exe', 'riotclient', 'valorant', 'leagueclient',
    'cs2.exe', 'csgo', 'dota2', 'gta5', 'gtav', 'cyberpunk2077', 'wow.exe', 'overwatch',
    'fortnite', 'minecraft', 'javaw', 'obs64', 'obs32', 'vlc', 'winrar', '7zfm',
    'photoshop', 'afterfx', 'code.exe', 'devenv', 'cursor', 'opera', 'brave', 'yandex',
    'skype', 'teams', 'whatsapp', 'slack', 'notion', 'spotify'
)

# Расшифровка STOP / BugCheck: код → имя, типичная причина, вероятный компонент
$Script:BugCheckMap = @{
    0x1   = @{ Name = 'APC_INDEX_MISMATCH'; Likely = 'driver'; Ru = 'Нарушение индекса APC — почти всегда ошибка драйвера (часто антивирус, диск, VPN).'; En = 'APC index mismatch — almost always a driver bug (AV, disk, VPN).' }
    0x3   = @{ Name = 'SPIN_LOCK_ALREADY_OWNED'; Likely = 'driver'; Ru = 'Спинлок уже захвачен. Ошибка драйвера.'; En = 'Spinlock already owned. Driver bug.' }
    0xA   = @{ Name = 'IRQL_NOT_LESS_OR_EQUAL'; Likely = 'driver'; Ru = 'Драйвер обратился к памяти на слишком высоком IRQL. Часто сетевой, антивирус, диск или GPU.'; En = 'A driver touched memory at too high IRQL. Often network, AV, disk, or GPU.' }
    0x1A  = @{ Name = 'MEMORY_MANAGEMENT'; Likely = 'ram'; Ru = 'Сбой диспетчера памяти. Часто ОЗУ, разгон/XMP или повреждённый системный файл.'; En = 'Memory manager failure. Often RAM, XMP/overclock, or a damaged system file.' }
    0x1E  = @{ Name = 'KMODE_EXCEPTION_NOT_HANDLED'; Likely = 'driver'; Ru = 'Необработанное исключение в ядре. Смотрите модуль в параметрах — обычно драйвер.'; En = 'Unhandled kernel exception. Check the module in the parameters — usually a driver.' }
    0x20  = @{ Name = 'KERNEL_APC_PENDING_DURING_EXIT'; Likely = 'driver'; Ru = 'APC завис при выходе потока. Драйвер или антивирус.'; En = 'APC pending during thread exit. Driver or antivirus.' }
    0x23  = @{ Name = 'FAT_FILE_SYSTEM'; Likely = 'disk'; Ru = 'Сбой FAT. Повреждение тома или накопителя.'; En = 'FAT file system crash. Volume or drive damage.' }
    0x24  = @{ Name = 'NTFS_FILE_SYSTEM'; Likely = 'disk'; Ru = 'Сбой NTFS: повреждение тома, отвал диска или фильтр (антивирус/шифрование).'; En = 'NTFS crash: dirty volume, disk drop, or a filter (AV/encryption).' }
    0x2E  = @{ Name = 'DATA_BUS_ERROR'; Likely = 'ram'; Ru = 'Ошибка шины данных. Классика неисправной RAM или разгона памяти.'; En = 'Data bus error. Classic bad RAM or memory overclock.' }
    0x3B  = @{ Name = 'SYSTEM_SERVICE_EXCEPTION'; Likely = 'driver'; Ru = 'Исключение в системном сервисе ядра. Часто графический/чипсетный драйвер или антивирус.'; En = 'Exception in a kernel system service. Often GPU/chipset driver or AV.' }
    0x3F  = @{ Name = 'NO_MORE_SYSTEM_PTES'; Likely = 'driver'; Ru = 'Закончились PTE ядра — драйвер «съел» адресное пространство (часто VPN/антивирус).'; En = 'Kernel PTEs exhausted — a driver leaked address space (often VPN/AV).' }
    0x44  = @{ Name = 'MULTIPLE_IRP_COMPLETE_REQUESTS'; Likely = 'driver'; Ru = 'Драйвер дважды завершил один IRP.'; En = 'A driver completed the same IRP twice.' }
    0x4E  = @{ Name = 'PFN_LIST_CORRUPT'; Likely = 'ram'; Ru = 'Повреждён список страниц PFN. ОЗУ, диск (pagefile) или драйвер.'; En = 'PFN list corrupt. RAM, pagefile/disk, or a driver.' }
    0x50  = @{ Name = 'PAGE_FAULT_IN_NONPAGED_AREA'; Likely = 'ram'; Ru = 'Обращение к несуществующей nonpaged-памяти. RAM, плохой драйвер или отвал диска.'; En = 'Fault in nonpaged area. RAM, a bad driver, or a disk drop.' }
    0x76  = @{ Name = 'PROCESS_HAS_LOCKED_PAGES'; Likely = 'driver'; Ru = 'Процесс завершился, не разблокировав страницы — утечка драйвера.'; En = 'A process exited with locked pages — driver leak.' }
    0x7A  = @{ Name = 'KERNEL_DATA_INPAGE_ERROR'; Likely = 'disk'; Ru = 'Ядро не смогло прочитать страницу с диска. SSD/HDD, кабель, NTFS или нехватка места под pagefile.'; En = 'Kernel could not page-in data. SSD/HDD, cable, NTFS, or pagefile space.' }
    0x7B  = @{ Name = 'INACCESSIBLE_BOOT_DEVICE'; Likely = 'disk'; Ru = 'Загрузочный диск недоступен: контроллер, режим SATA/AHCI/RST, кабель, мёртвый SSD.'; En = 'Boot device inaccessible: controller, SATA/AHCI/RST mode, cable, or dead SSD.' }
    0x7E  = @{ Name = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'; Likely = 'driver'; Ru = 'Исключение в системном потоке. Смотрите .sys в параметрах — драйвер устройства.'; En = 'Exception in a system thread. Check the .sys in parameters — a device driver.' }
    0x7F  = @{ Name = 'UNEXPECTED_KERNEL_MODE_TRAP'; Likely = 'ram'; Ru = 'Неожиданный trap в ядре. Часто RAM, разгон CPU/RAM или перегрев.'; En = 'Unexpected kernel trap. Often RAM, CPU/RAM overclock, or heat.' }
    0x80  = @{ Name = 'NMI_HARDWARE_FAILURE'; Likely = 'hardware'; Ru = 'Немаскируемое прерывание: железо (БП, RAM, PCIe, перегрев).'; En = 'Non-maskable interrupt: hardware (PSU, RAM, PCIe, heat).' }
    0x8E  = @{ Name = 'KERNEL_MODE_EXCEPTION_NOT_HANDLED'; Likely = 'driver'; Ru = 'Необработанное исключение режима ядра (часто драйвер).'; En = 'Unhandled kernel-mode exception (often a driver).' }
    0x9C  = @{ Name = 'MACHINE_CHECK_EXCEPTION'; Likely = 'cpu'; Ru = 'Machine Check: CPU/чипсет/питание/перегрев. Смотрите WHEA рядом.'; En = 'Machine Check: CPU/chipset/power/heat. Check nearby WHEA events.' }
    0x9F  = @{ Name = 'DRIVER_POWER_STATE_FAILURE'; Likely = 'driver'; Ru = 'Драйвер не ответил на переход сна/гибернации. Часто GPU, NIC, USB, NVMe.'; En = 'A driver did not complete a sleep/hibernate transition. Often GPU, NIC, USB, NVMe.' }
    0xA5  = @{ Name = 'ACPI_BIOS_ERROR'; Likely = 'bios'; Ru = 'Ошибка ACPI в прошивке. Обновите BIOS, сбросьте настройки.'; En = 'ACPI BIOS error. Update BIOS and reset settings.' }
    0xBE  = @{ Name = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY'; Likely = 'driver'; Ru = 'Запись в память только для чтения — баг драйвера.'; En = 'Write to read-only memory — driver bug.' }
    0xC2  = @{ Name = 'BAD_POOL_CALLER'; Likely = 'driver'; Ru = 'Драйвер некорректно работал с пулом ядра.'; En = 'A driver corrupted or misused kernel pool.' }
    0xC4  = @{ Name = 'DRIVER_VERIFIER_DETECTED_VIOLATION'; Likely = 'driver'; Ru = 'Driver Verifier поймал нарушителя. Смотрите модуль в дампе.'; En = 'Driver Verifier caught a violating driver. Check the dump module.' }
    0xC5  = @{ Name = 'DRIVER_CORRUPTED_EXPOOL'; Likely = 'driver'; Ru = 'Драйвер повредил пул ядра.'; En = 'A driver corrupted the kernel pool.' }
    0xCE  = @{ Name = 'DRIVER_UNLOADED_WITHOUT_CANCELLING_PENDING_OPERATIONS'; Likely = 'driver'; Ru = 'Драйвер выгрузился, не отменив операции (часто USB).'; En = 'Driver unloaded without cancelling pending I/O (often USB).' }
    0xD1  = @{ Name = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'; Likely = 'driver'; Ru = 'Конкретный драйвер нарушил IRQL. Имя .sys обычно есть в событии/дампе — это виновник.'; En = 'A specific driver violated IRQL. The .sys name in the event/dump is the culprit.' }
    0xD8  = @{ Name = 'DRIVER_USED_EXCESSIVE_PTES'; Likely = 'driver'; Ru = 'Драйвер израсходовал слишком много PTE.'; En = 'A driver used too many PTEs.' }
    0xEA  = @{ Name = 'THREAD_STUCK_IN_DEVICE_DRIVER'; Likely = 'gpu'; Ru = 'Поток завис в драйвере устройства. Классика видеодрайвера (TDR/GPU).'; En = 'A thread stuck in a device driver. Classic video driver (TDR/GPU).' }
    0xED  = @{ Name = 'UNMOUNTABLE_BOOT_VOLUME'; Likely = 'disk'; Ru = 'Не монтируется загрузочный том. Диск, кабель, контроллер, chkdsk.'; En = 'Boot volume cannot be mounted. Disk, cable, controller, chkdsk.' }
    0xEF  = @{ Name = 'CRITICAL_PROCESS_DIED'; Likely = 'process'; Ru = 'Умер критичный процесс Windows (csrss, smss, lsass, svchost). Смотрите имя процесса: диск, RAM, антивирус или повреждение системы.'; En = 'A critical Windows process died (csrss, smss, lsass, svchost). Check the process name: disk, RAM, AV, or system corruption.' }
    0xF4  = @{ Name = 'CRITICAL_OBJECT_TERMINATION'; Likely = 'process'; Ru = 'Завершён критичный системный объект/процесс. Часто диск или RAM.'; En = 'A critical system object/process was terminated. Often disk or RAM.' }
    0xF7  = @{ Name = 'DRIVER_OVERRAN_STACK_BUFFER'; Likely = 'driver'; Ru = 'Драйвер переполнил стек.'; En = 'A driver overran a stack buffer.' }
    0xFC  = @{ Name = 'ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY'; Likely = 'driver'; Ru = 'Попытка выполнить NX-память. Драйвер или повреждение RAM.'; En = 'Execute from NX memory. Driver or RAM corruption.' }
    0x109 = @{ Name = 'CRITICAL_STRUCTURE_CORRUPTION'; Likely = 'ram'; Ru = 'Повреждены критичные структуры ядра. RAM, разгон или rootkit-фильтр.'; En = 'Critical kernel structures corrupted. RAM, overclock, or a filter/rootkit.' }
    0x116 = @{ Name = 'VIDEO_TDR_FAILURE'; Likely = 'gpu'; Ru = 'Видеодрайвер не ответил вовремя (TDR). Виновник — GPU-драйвер (.sys в параметре 1): nvlddmkm, amdkmdag, igdkmd64.'; En = 'Video driver timed out (TDR). Culprit is the GPU driver (.sys in parameter 1): nvlddmkm, amdkmdag, igdkmd64.' }
    0x117 = @{ Name = 'VIDEO_TDR_TIMEOUT_DETECTED'; Likely = 'gpu'; Ru = 'Таймаут видеопланировщика. Перегрев/питание GPU или драйвер.'; En = 'Video scheduler timeout. GPU heat/power or the driver.' }
    0x119 = @{ Name = 'VIDEO_SCHEDULER_INTERNAL_ERROR'; Likely = 'gpu'; Ru = 'Внутренняя ошибка видеопланировщика. Драйвер или GPU.'; En = 'Video scheduler internal error. Driver or GPU.' }
    0x124 = @{ Name = 'WHEA_UNCORRECTABLE_ERROR'; Likely = 'hardware'; Ru = 'Неисправимая аппаратная ошибка WHEA. Смотрите компонент: CPU, RAM, PCIe/NVMe. Отключите XMP/разгон.'; En = 'Uncorrectable WHEA hardware error. Check CPU, RAM, PCIe/NVMe. Disable XMP/overclock.' }
    0x127 = @{ Name = 'WHEA_INTERNAL_ERROR'; Likely = 'hardware'; Ru = 'Внутренняя ошибка WHEA — аппаратный сбой.'; En = 'Internal WHEA error — hardware fault.' }
    0x133 = @{ Name = 'DPC_WATCHDOG_VIOLATION'; Likely = 'driver'; Ru = 'DPC-сторож: драйвер держал процессор слишком долго. Часто NVMe, USB, сеть, антивирус, старый чипсет.'; En = 'DPC watchdog: a driver held the CPU too long. Often NVMe, USB, NIC, AV, old chipset.' }
    0x139 = @{ Name = 'KERNEL_SECURITY_CHECK_FAILURE'; Likely = 'driver'; Ru = 'Сработала проверка безопасности ядра (повреждение стека/cookie). Драйвер, антивирус или RAM.'; En = 'Kernel security cookie/stack check failed. Driver, AV, or RAM.' }
    0x13A = @{ Name = 'KERNEL_MODE_HEAP_CORRUPTION'; Likely = 'driver'; Ru = 'Повреждена куча ядра. Драйвер или RAM.'; En = 'Kernel heap corruption. Driver or RAM.' }
    0x141 = @{ Name = 'VIDEO_ENGINE_TIMEOUT_DETECTED'; Likely = 'gpu'; Ru = 'Таймаут движка GPU. Видеокарта, питание, перегрев, драйвер.'; En = 'GPU engine timeout. Card, power, heat, or driver.' }
    0x144 = @{ Name = 'BUGCODE_USB_DRIVER'; Likely = 'usb'; Ru = 'Сбой USB-драйвера. Отключите устройства/хабы, обновите чипсет.'; En = 'USB driver bugcheck. Unplug hubs/devices, update chipset.' }
    0x145 = @{ Name = 'WDF_VIOLATION'; Likely = 'driver'; Ru = 'Нарушение Windows Driver Framework. Смотрите .sys в дампе.'; En = 'Windows Driver Framework violation. Check the .sys in the dump.' }
    0x154 = @{ Name = 'UNEXPECTED_STORE_EXCEPTION'; Likely = 'disk'; Ru = 'Сбой хранилища сжатия/памяти (store). Диск, место на томе или драйвер накопителя.'; En = 'Memory/compression store exception. Disk, free space, or storage driver.' }
    0x15B = @{ Name = 'WIN32K_CRITICAL_FAILURE'; Likely = 'driver'; Ru = 'Критический сбой win32k (графическая подсистема). Тема, GPU, ПО оверлеев.'; En = 'Critical win32k failure (GUI subsystem). Theme, GPU, overlay software.' }
    0x161 = @{ Name = 'WIN32K_POWER_WATCHDOG_TIMEOUT'; Likely = 'gpu'; Ru = 'win32k не ответил при смене питания. GPU/монитор/драйвер дисплея.'; En = 'win32k power watchdog. GPU/display driver.' }
    0x17A = @{ Name = 'WIN32K_SECURITY_FAILURE'; Likely = 'driver'; Ru = 'Проверка безопасности win32k. Графический стек или сторонние хуки.'; En = 'win32k security failure. Graphics stack or third-party hooks.' }
    0x18B = @{ Name = 'WIN32K_ATOMIC_CHECK_FAILURE'; Likely = 'driver'; Ru = 'Сбой атомарной проверки win32k. Графика/оверлеи.'; En = 'win32k atomic check failure. Graphics/overlays.' }
    0x1CA = @{ Name = 'SYNTHETIC_WATCHDOG_TIMEOUT'; Likely = 'hang'; Ru = 'Сторожевой таймер: система зависла и не отвечала. Питание, диск, перегрев.'; En = 'Watchdog: the system hung and stopped responding. Power, disk, heat.' }
    0x1E4 = @{ Name = 'INVALID_EXTENDED_PROCESSOR_STATE'; Likely = 'cpu'; Ru = 'Некорректное состояние CPU. BIOS, разгон, микрокод.'; En = 'Invalid extended CPU state. BIOS, overclock, microcode.' }
    0x1ED = @{ Name = 'USER_MODE_HEALTH_MONITOR'; Likely = 'process'; Ru = 'Критичный пользовательский процесс не отвечал (часто csrss/winlogon). Диск, GPU, антивирус.'; En = 'A critical user-mode process hung (often csrss/winlogon). Disk, GPU, AV.' }
    0xC000021A = @{ Name = 'STATUS_SYSTEM_PROCESS_TERMINATED'; Likely = 'process'; Ru = 'Завершился системный процесс (winlogon/csrss). Повреждение системы, диск, антивирус.'; En = 'A system process (winlogon/csrss) terminated. System corruption, disk, AV.' }
    0xC0000221 = @{ Name = 'STATUS_IMAGE_CHECKSUM_MISMATCH'; Likely = 'disk'; Ru = 'Контрольная сумма файла не совпала — повреждён системный файл или диск.'; En = 'Image checksum mismatch — damaged system file or disk.' }
}

$Script:LikelyLabel = @{
    driver   = @{ Ru = 'драйвер'; En = 'driver' }
    ram      = @{ Ru = 'оперативная память (RAM)'; En = 'RAM' }
    disk     = @{ Ru = 'накопитель / файловая система'; En = 'storage / file system' }
    gpu      = @{ Ru = 'видеокарта / видеодрайвер'; En = 'GPU / video driver' }
    cpu      = @{ Ru = 'процессор / питание CPU'; En = 'CPU / CPU power' }
    hardware = @{ Ru = 'железо (CPU/RAM/PCIe/БП)'; En = 'hardware (CPU/RAM/PCIe/PSU)' }
    bios     = @{ Ru = 'BIOS / ACPI'; En = 'BIOS / ACPI' }
    process  = @{ Ru = 'системный процесс'; En = 'system process' }
    usb      = @{ Ru = 'USB-контроллер / устройство'; En = 'USB controller / device' }
    hang     = @{ Ru = 'зависание системы'; En = 'system hang' }
}

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------
function Write-ReportLine {
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text = '',

        [Parameter(Position = 1)]
        [ConsoleColor]$Color = [ConsoleColor]::Gray,

        [switch]$NoConsole
    )
    if ($null -eq $Text) { $Text = '' }
    if (-not $NoConsole) {
        Write-Host $Text -ForegroundColor $Color
    }
    [void]$Script:Report.AppendLine($Text)
    [void]$Script:ReportHtml.Add([pscustomobject]@{ Text = $Text; Color = $Color.ToString() })
}

function Write-Header {
    param([string]$Title)
    Write-ReportLine ''
    Write-ReportLine ('=' * 72) Cyan
    Write-ReportLine ("  $Title") Cyan
    Write-ReportLine ('=' * 72) Cyan
}

function Write-Section {
    param([string]$Title)
    Write-ReportLine ''
    Write-ReportLine ("--- $Title ---") Yellow
}

function Step-Progress {
    param([string]$Status)
    $Script:ProgressStep++
    $pct = [math]::Min(99, [int](100 * $Script:ProgressStep / [math]::Max(1, $Script:ProgressTotal)))
    Write-Progress -Activity ("WinErrorParser {0}" -f $Script:Version) -Status $Status -PercentComplete $pct
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-IsNoiseProvider {
    param([string]$Provider)
    if ($Script:FullReport) { return $false }
    if ([string]::IsNullOrWhiteSpace($Provider)) { return $true }
    foreach ($n in $Script:NoiseProviders) {
        if ($Provider -eq $n -or $Provider -like "$n*") { return $true }
    }
    return $false
}

function Test-IsRelevantProvider {
    param([string]$Provider)
    if (Test-IsNoiseProvider $Provider) { return $false }
    foreach ($c in $Script:CriticalProviders) {
        if ($Provider -eq $c -or $Provider -like "$c*") { return $true }
    }
    $info = Get-ProviderExplain -Provider $Provider
    if ($info -and $info.Level -eq 'Critical') { return $true }
    return $false
}

function Get-ProviderExplain {
    param([string]$Provider)
    if ([string]::IsNullOrWhiteSpace($Provider)) { return $null }
    $raw = $null
    if ($Script:ErrorExplain.ContainsKey($Provider)) {
        $raw = $Script:ErrorExplain[$Provider]
    } else {
        foreach ($key in $Script:ErrorExplain.Keys) {
            if ($Provider -like "$key*") { $raw = $Script:ErrorExplain[$key]; break }
        }
    }
    if (-not $raw) { return $null }
    $title = $raw.Title
    $text = $raw.Text
    if ($Script:Lang -eq 'en') {
        if ($raw.TitleEn) { $title = $raw.TitleEn }
        if ($raw.TextEn) { $text = $raw.TextEn }
    }
    return @{ Title = $title; Text = $text; Level = $raw.Level }
}

function Get-EventIdExplain {
    param([string]$Provider, [int]$Id)
    $key = "$Provider|$Id"
    if ($Script:EventIdExplain.ContainsKey($key)) {
        $item = $Script:EventIdExplain[$key]
        return (L $item.Ru $item.En)
    }
    return $null
}

function Mark-Issue {
    param([string]$Key, [switch]$Critical)
    if (-not [string]::IsNullOrWhiteSpace($Key)) {
        [void]$Script:IssueTypes.Add($Key)
        if ($Critical) { [void]$Script:CriticalTypes.Add($Key) }
    }
}

function Write-Explanation {
    param(
        [string]$Provider,
        [int]$EventId = 0,
        [switch]$QuietCount
    )
    $info = Get-ProviderExplain -Provider $Provider
    $idText = Get-EventIdExplain -Provider $Provider -Id $EventId

    if ($info) {
        $color = switch ($info.Level) {
            'Critical' { [ConsoleColor]::Red }
            'Warning'  { [ConsoleColor]::DarkYellow }
            default    { [ConsoleColor]::DarkGray }
        }
        Write-ReportLine ("    {0} [{1}]: {2}" -f (L 'ПОЯСНЕНИЕ' 'NOTE'), $info.Title, $info.Text) $color
        if (-not $QuietCount) {
            $isCrit = $info.Level -eq 'Critical'
            Mark-Issue -Key $Provider -Critical:$isCrit
        }
    }
    elseif ($idText) {
        Write-ReportLine ("    {0}: {1}" -f (L 'ПОЯСНЕНИЕ' 'NOTE'), $idText) DarkYellow
        if (-not $QuietCount) { Mark-Issue -Key "$Provider|$EventId" }
    }
    else {
        Write-ReportLine ("    {0}: {1}" -f (L 'ПОЯСНЕНИЕ' 'NOTE'), (L ("Источник «{0}» связан с неисправностью. Смотрите текст события в eventvwr.msc." -f $Provider) ("Provider «{0}» is fault-related. See the event text in eventvwr.msc." -f $Provider))) DarkGray
        if (-not $QuietCount) { Mark-Issue -Key $Provider }
    }

    if ($idText -and $info) {
        Write-ReportLine ("    {0} {1}: {2}" -f (L 'ПО EVENT ID' 'EVENT ID'), $EventId, $idText) DarkCyan
    }
}

function Add-Finding {
    param(
        [string]$Kind,
        [datetime]$Time,
        [string]$Title,
        [string]$Detail = '',
        $Event = $null,
        [string[]]$Tags = @(),
        [int]$WindowSeconds = 90
    )
    foreach ($existing in @($Script:Findings)) {
        if ($existing.Kind -eq $Kind -and [math]::Abs(($existing.Time - $Time).TotalSeconds) -le $WindowSeconds) {
            if ($Detail -and [string]::IsNullOrWhiteSpace($existing.Detail)) { $existing.Detail = $Detail }
            if ($Tags) {
                $merged = @($existing.Tags + $Tags) | Select-Object -Unique
                $existing.Tags = @($merged)
            }
            return
        }
    }
    $obj = [pscustomobject]@{
        Kind   = $Kind
        Time   = $Time
        Title  = $Title
        Detail = $Detail
        Event  = $Event
        Tags   = $Tags
    }
    [void]$Script:Findings.Add($obj)
}

function Test-IsHardwareFinding {
    param([string]$Kind)
    return @('KernelPower', 'UnexpectedShutdown', 'WHEA', 'BugCheck', 'Minidump', 'DiskEvent', 'DiskHealth', 'GPU', 'MemoryDiag', 'Resource', 'Thermal', 'Battery', 'LowDisk', 'VolumeDirty', 'Bus', 'Sleep') -contains $Kind
}

function Test-IsSystemProcessName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $base = $Name.Trim()
    try { $base = [System.IO.Path]::GetFileName($base) } catch {}
    $base = $base.Trim()
    $stem = $base
    if ($stem -match '(?i)\.exe$') { $stem = $stem.Substring(0, $stem.Length - 4) }
    foreach ($n in $Script:SystemProcessNames) {
        $want = $n.Trim()
        $wantStem = $want
        if ($wantStem -match '(?i)\.exe$') { $wantStem = $wantStem.Substring(0, $wantStem.Length - 4) }
        if ($base -ieq $want -or $stem -ieq $wantStem) { return $true }
    }
    if ($base -match '(?i)\.sys$') { return $true }
    return $false
}

function Test-IsSoftNoiseName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if (Test-IsSystemProcessName $Name) { return $false }
    $n = $Name.ToLowerInvariant()
    foreach ($s in $Script:SoftNoiseNames) {
        if ($n -like ('*{0}*' -f $s.ToLowerInvariant())) { return $true }
    }
    return $true
}

function Get-HardwareFindings {
    return @($Script:Findings | Where-Object { Test-IsHardwareFinding $_.Kind })
}

function Get-FindingStats {
    $list = New-Object System.Collections.Generic.List[object]
    $groups = @(Get-HardwareFindings | Group-Object {
        if ($_.Title) { '{0}|{1}' -f $_.Kind, $_.Title } else { $_.Kind }
    })
    foreach ($g in $groups) {
        $times = @($g.Group | ForEach-Object { $_.Time } | Where-Object { $_ } | Sort-Object)
        $first = $null
        $last = $null
        if ($times.Count -gt 0) {
            $first = $times[0]
            $last = $times[$times.Count - 1]
        }
        $span = 0.0
        if ($first -and $last) { $span = [math]::Max(0, ($last - $first).TotalDays) }
        $weight = 'single'
        if ($g.Count -ge 4 -or $span -ge 2) { $weight = 'repeat' }
        elseif ($g.Count -ge 2) { $weight = 'few' }
        $sample = $g.Group[0]
        [void]$list.Add([pscustomobject]@{
            Kind     = $sample.Kind
            Title    = $sample.Title
            Count    = $g.Count
            First    = $first
            Last     = $last
            SpanDays = [math]::Round($span, 1)
            Weight   = $weight
        })
    }
    return @($list | Sort-Object Count -Descending)
}

function Get-WeightLabel {
    param([string]$Weight)
    switch ($Weight) {
        'repeat' { L 'серия' 'series' }
        'few'    { L 'несколько' 'a few' }
        default  { L 'единичный' 'single' }
    }
}

function ConvertFrom-CimDate {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    try { return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Value) } catch { return $null }
}

function Test-RebootPending {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $true }
    }
    try {
        $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop
        if ($sm.PendingFileRenameOperations) { return $true }
    } catch {}
    return $false
}

function Get-DumpEnabled {
    try {
        $cc = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop
        return [int]$cc.CrashDumpEnabled
    } catch { return $null }
}

function Get-DumpEnabledLabel {
    param($Value)
    switch ([string]$Value) {
        '0' { L 'выключены (BSOD может не сохраниться)' 'disabled (BSOD may not be saved)' }
        '1' { L 'полный дамп' 'complete dump' }
        '2' { L 'дамп ядра' 'kernel dump' }
        '3' { L 'малый дамп (минидамп)' 'small dump (minidump)' }
        '7' { L 'автоматический дамп' 'automatic dump' }
        default { if ($null -eq $Value) { L 'не удалось прочитать' 'could not read' } else { "$Value" } }
    }
}

function Get-LastWindowsUpdateInfo {
    $info = [pscustomobject]@{ Date = $null; Title = ''; Source = '' }
    try {
        $evs = @(Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-WindowsUpdateClient'
            Id           = 19
        } -MaxEvents 3 -ErrorAction Stop)
        if ($evs.Count -gt 0) {
            $info.Date = $evs[0].TimeCreated
            $info.Title = Get-ShortMessage $evs[0] 140
            $info.Source = 'WindowsUpdateClient'
        }
    } catch {}
    if (-not $info.Date) {
        try {
            $hf = @(Get-CimInstance Win32_QuickFixEngineering -ErrorAction SilentlyContinue |
                Where-Object { $_.InstalledOn } |
                Sort-Object { ConvertFrom-CimDate $_.InstalledOn } -Descending)
            if ($hf.Count -gt 0) {
                $when = ConvertFrom-CimDate $hf[0].InstalledOn
                if ($when) {
                    $info.Date = $when
                    $info.Title = [string]$hf[0].HotFixID
                    $info.Source = 'QuickFix'
                }
            }
        } catch {}
    }
    return $info
}

function Import-PreviousState {
    if (-not (Test-Path -LiteralPath $Script:StatePath)) { return $null }
    try {
        return (Get-Content -LiteralPath $Script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch { return $null }
}

function Export-CurrentState {
    $kinds = [ordered]@{}
    foreach ($g in @(Get-HardwareFindings | Group-Object Kind)) {
        $kinds[$g.Name] = [int]$g.Count
    }
    $obj = [ordered]@{
        Version    = $Script:Version
        When       = (Get-Date).ToString('o')
        DaysBack   = $Script:DaysBack
        ReportPath = $Script:ReportPath
        HtmlPath   = $Script:HtmlPath
        Kinds      = $kinds
    }
    try {
        $json = $obj | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($Script:StatePath, $json, [System.Text.UTF8Encoding]::new($true))
    } catch {}
}

function Get-PreviousCompareLines {
    $lines = New-Object System.Collections.Generic.List[object]
    $prev = $Script:PreviousState
    if (-not $prev) {
        [void]$lines.Add([pscustomobject]@{
            Text  = ('  ' + (L 'Предыдущего прогона в этой папке нет — сравнение появится со второго запуска.' 'No previous run in this folder — a comparison will appear after the second run.'))
            Color = [ConsoleColor]::DarkGray
        })
        return $lines.ToArray()
    }

    $prevWhen = $prev.When
    $prevKinds = @{}
    if ($prev.Kinds) {
        foreach ($p in $prev.Kinds.PSObject.Properties) {
            $prevKinds[$p.Name] = [int]$p.Value
        }
    }
    $nowKinds = @{}
    foreach ($g in @(Get-HardwareFindings | Group-Object Kind)) {
        $nowKinds[$g.Name] = [int]$g.Count
    }

    [void]$lines.Add([pscustomobject]@{
        Text  = ("  {0}: {1}" -f (L 'Прошлый отчёт' 'Previous report'), $prevWhen)
        Color = [ConsoleColor]::DarkCyan
    })

    $new = @()
    $gone = @()
    $up = @()
    $down = @()
    $allKeys = New-Object System.Collections.Generic.List[string]
    foreach ($k in $nowKinds.Keys) { [void]$allKeys.Add([string]$k) }
    foreach ($k in $prevKinds.Keys) {
        $ks = [string]$k
        if (-not $allKeys.Contains($ks)) { [void]$allKeys.Add($ks) }
    }
    foreach ($k in $allKeys) {
        $a = 0; $b = 0
        if ($nowKinds.ContainsKey($k)) { $a = [int]$nowKinds[$k] }
        if ($prevKinds.ContainsKey($k)) { $b = [int]$prevKinds[$k] }
        $label = Get-FindingKindLabel $k
        if ($b -eq 0 -and $a -gt 0) { $new += ('{0} ×{1}' -f $label, $a) }
        elseif ($a -eq 0 -and $b -gt 0) { $gone += ('{0} ×{1}' -f $label, $b) }
        elseif ($a -gt $b) { $up += ('{0} {1}→{2}' -f $label, $b, $a) }
        elseif ($a -lt $b) { $down += ('{0} {1}→{2}' -f $label, $b, $a) }
    }

    if ($new.Count -eq 0 -and $gone.Count -eq 0 -and $up.Count -eq 0 -and $down.Count -eq 0) {
        [void]$lines.Add([pscustomobject]@{
            Text  = ('  ' + (L 'Набор аппаратных фактов тот же, что в прошлом отчёте.' 'The hardware findings match the previous report.'))
            Color = [ConsoleColor]::Green
        })
        return $lines.ToArray()
    }
    if ($new.Count -gt 0) {
        [void]$lines.Add([pscustomobject]@{ Text = ('  ' + (L 'Новое' 'New') + ': ' + ($new -join ', ')); Color = [ConsoleColor]::Red })
    }
    if ($up.Count -gt 0) {
        [void]$lines.Add([pscustomobject]@{ Text = ('  ' + (L 'Стало больше' 'Increased') + ': ' + ($up -join ', ')); Color = [ConsoleColor]::Yellow })
    }
    if ($down.Count -gt 0) {
        [void]$lines.Add([pscustomobject]@{ Text = ('  ' + (L 'Стало меньше' 'Decreased') + ': ' + ($down -join ', ')); Color = [ConsoleColor]::Green })
    }
    if ($gone.Count -gt 0) {
        [void]$lines.Add([pscustomobject]@{ Text = ('  ' + (L 'Исчезло' 'Gone') + ': ' + ($gone -join ', ')); Color = [ConsoleColor]::Green })
    }
    return $lines.ToArray()
}

function Get-ExecutiveSummaryRows {
    $rows = New-Object System.Collections.Generic.List[object]
    $v = Get-QuickVerdictText
    [void]$rows.Add([pscustomobject]@{ Text = ''; Color = [ConsoleColor]::Gray })
    [void]$rows.Add([pscustomobject]@{ Text = ('=' * 72); Color = [ConsoleColor]::Cyan })
    [void]$rows.Add([pscustomobject]@{ Text = ('  ' + (L 'КРАТКАЯ ШАПКА' 'EXECUTIVE SUMMARY')); Color = [ConsoleColor]::Cyan })
    [void]$rows.Add([pscustomobject]@{ Text = ('=' * 72); Color = [ConsoleColor]::Cyan })
    [void]$rows.Add([pscustomobject]@{ Text = ("  {0}: {1}" -f (L 'Вердикт' 'Verdict'), $v.Text); Color = $v.Color })

    $hw = @(Get-HardwareFindings)
    $soft = @($Script:Findings | Where-Object { $_.Kind -eq 'AppCrash' })
    [void]$rows.Add([pscustomobject]@{
        Text  = ("  {0}: {1}  |  {2}: {3}  |  {4}: {5}" -f (L 'Железо' 'Hardware'), $hw.Count, (L 'системный софт' 'system software'), $soft.Count, (L 'скрыто игр/браузеров' 'hidden games/browsers'), $Script:SoftCrashHidden)
        Color = [ConsoleColor]::DarkGray
    })

    $stats = @(Get-FindingStats | Select-Object -First 6)
    if ($stats.Count -gt 0) {
        [void]$rows.Add([pscustomobject]@{ Text = ('  ' + (L 'Вес событий' 'Event weight') + ':'); Color = [ConsoleColor]::DarkCyan })
        foreach ($s in $stats) {
            $when = ''
            if ($s.First -and $s.Last) {
                if ($s.Count -eq 1) { $when = ('{0:dd.MM HH:mm}' -f $s.First) }
                else { $when = ('{0:dd.MM HH:mm} → {1:dd.MM HH:mm}' -f $s.First, $s.Last) }
            }
            $line = '    • {0} — {1}× ({2})' -f (Get-FindingKindLabel $s.Kind), $s.Count, (Get-WeightLabel $s.Weight)
            if ($s.Title) { $line = $line + ('; {0}' -f $s.Title) }
            if ($when) { $line = $line + ('; {0}' -f $when) }
            $col = [ConsoleColor]::Gray
            if ($s.Weight -eq 'repeat') { $col = [ConsoleColor]::Red }
            elseif ($s.Weight -eq 'few') { $col = [ConsoleColor]::Yellow }
            [void]$rows.Add([pscustomobject]@{ Text = $line; Color = $col })
        }
    }

    if ($Script:LastUpdateInfo -and $Script:LastUpdateInfo.Date) {
        $u = $Script:LastUpdateInfo
        [void]$rows.Add([pscustomobject]@{
            Text  = ("  {0}: {1:dd.MM.yyyy HH:mm} — {2}" -f (L 'Последнее обновление Windows' 'Last Windows update'), $u.Date, $u.Title)
            Color = [ConsoleColor]::DarkGray
        })
        $firstHw = @($hw | Where-Object Time | Sort-Object Time | Select-Object -First 1)
        if ($firstHw.Count -gt 0 -and $firstHw[0].Time -gt $u.Date) {
            [void]$rows.Add([pscustomobject]@{
                Text  = ('  ' + (L 'Первый аппаратный сбой за период позже этого обновления — возможна связка «сломалось после патча».' 'The first hardware fault in this period is after that update — it may have started after the patch.'))
                Color = [ConsoleColor]::Yellow
            })
        }
    }

    if ($null -ne $Script:CompareLines) {
        foreach ($c in $Script:CompareLines) {
            if ($null -ne $c) { [void]$rows.Add($c) }
        }
    }
    return $rows.ToArray()
}

function Prepend-ExecutiveSummaryToBuffers {
    $rows = @(Get-ExecutiveSummaryRows)
    $newSb = New-Object System.Text.StringBuilder
    $newHtml = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) {
        [void]$newSb.AppendLine([string]$r.Text)
        [void]$newHtml.Add([pscustomobject]@{ Text = [string]$r.Text; Color = $r.Color.ToString() })
    }
    [void]$newSb.Append($Script:Report.ToString())
    foreach ($old in $Script:ReportHtml) { [void]$newHtml.Add($old) }
    $Script:Report = $newSb
    $Script:ReportHtml = $newHtml
}

function Write-ExecutiveSummaryToConsole {
    foreach ($r in @(Get-ExecutiveSummaryRows)) {
        Write-Host $r.Text -ForegroundColor $r.Color
    }
}

function Get-SafeWinEvents {
    param([hashtable]$Filter, [int]$Max = 50)
    try {
        return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Import-EventCache {
    Step-Progress (L 'Чтение журналов событий...' 'Reading event logs...')
    $Script:EventCache = @{
        System      = @(Get-SafeWinEvents -Filter @{ LogName = 'System'; StartTime = $Script:StartDate; Level = @(1, 2, 3) } -Max 4000)
        Application = @(Get-SafeWinEvents -Filter @{ LogName = 'Application'; StartTime = $Script:StartDate; Level = @(1, 2) } -Max 1200)
        Setup       = @(Get-SafeWinEvents -Filter @{ LogName = 'Setup'; StartTime = $Script:StartDate; Level = @(1, 2, 3) } -Max 300)
    }
    # 6008 и Kernel-Power 41 могли не попасть, если фильтр Level на конкретной сборке капризничает
    $extra41 = Get-SafeWinEvents -Filter @{
        LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $Script:StartDate
    } -Max 40
    $extra6008 = Get-SafeWinEvents -Filter @{
        LogName = 'System'; ProviderName = 'EventLog'; Id = 6008; StartTime = $Script:StartDate
    } -Max 40
    $extraSleep = Get-SafeWinEvents -Filter @{
        LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = @(42, 107, 109); StartTime = $Script:StartDate
    } -Max 80
    if ($extra41.Count -gt 0 -or $extra6008.Count -gt 0 -or $extraSleep.Count -gt 0) {
        $merged = @($Script:EventCache.System + $extra41 + $extra6008 + $extraSleep)
        $Script:EventCache.System = @($merged | Sort-Object RecordId -Unique)
    }
    $Script:CacheReady = $true
}

function Find-CachedEvents {
    param(
        [string]$LogName = 'System',
        [string]$Provider = '',
        $Id = $null,
        $Level = $null,
        [datetime]$From = [datetime]::MinValue,
        [datetime]$To = [datetime]::MaxValue,
        [int]$Max = 80
    )
    $set = @()
    if ($Script:CacheReady -and $Script:EventCache.ContainsKey($LogName)) {
        $set = @($Script:EventCache[$LogName])
    }
    if ($set.Count -eq 0 -and -not $Script:CacheReady) {
        $filter = @{ LogName = $LogName; StartTime = $Script:StartDate }
        if ($Provider) { $filter.ProviderName = $Provider }
        if ($null -ne $Id) { $filter.Id = $Id }
        if ($null -ne $Level) { $filter.Level = $Level }
        return @(Get-SafeWinEvents -Filter $filter -Max $Max)
    }

    $result = $set
    if ($Provider) {
        $result = @($result | Where-Object { $_.ProviderName -eq $Provider -or $_.ProviderName -like "$Provider*" })
    }
    if ($null -ne $Id) {
        $ids = @($Id)
        $result = @($result | Where-Object { $ids -contains $_.Id })
    }
    if ($null -ne $Level) {
        $levels = @($Level)
        $result = @($result | Where-Object { $levels -contains $_.Level })
    }
    if ($From -gt [datetime]::MinValue) {
        $result = @($result | Where-Object { $_.TimeCreated -ge $From })
    }
    if ($To -lt [datetime]::MaxValue) {
        $result = @($result | Where-Object { $_.TimeCreated -le $To })
    }
    return @($result | Sort-Object TimeCreated -Descending | Select-Object -First $Max)
}

function Get-ShortMessage {
    param($Event, [int]$MaxLen = 160)
    if (-not $Event -or -not $Event.Message) { return (L '(нет текста)' '(no text)') }
    $msg = ($Event.Message -replace '\s+', ' ').Trim()
    if ($msg.Length -gt $MaxLen) { return $msg.Substring(0, $MaxLen) + '…' }
    return $msg
}

function Get-EventDataMap {
    param($Event)
    $map = @{}
    if (-not $Event) { return $map }
    try {
        $xml = [xml]$Event.ToXml()
        foreach ($d in @($xml.Event.EventData.Data)) {
            $name = $d.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $map[$name] = $d.'#text'
        }
    } catch {}
    return $map
}

function Import-DiskNameMap {
    if ($Script:DiskMapReady) { return }
    $Script:DiskByNumber = @{}
    $Script:LetterToDisk = @{}
    try {
        $drives = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop)
        foreach ($dd in $drives) {
            $letters = New-Object System.Collections.Generic.List[string]
            try {
                $parts = @(Get-CimAssociatedInstance -InputObject $dd -ResultClassName Win32_DiskPartition -ErrorAction Stop)
                foreach ($part in $parts) {
                    $logicals = @(Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)
                    foreach ($ld in $logicals) {
                        if ($ld.DeviceID) { [void]$letters.Add($ld.DeviceID.TrimEnd('\').ToUpperInvariant()) }
                    }
                }
            } catch {}
            try {
                $nTry = [int]$dd.Index
                $gp = @(Get-Partition -DiskNumber $nTry -ErrorAction SilentlyContinue)
                foreach ($g in $gp) {
                    if ($g.DriveLetter) { [void]$letters.Add(($g.DriveLetter.ToString().ToUpperInvariant() + ':')) }
                }
            } catch {}
            $uniq = @($letters | Select-Object -Unique)
            if (-not $dd.Size -or $dd.Size -lt 8MB) { continue }
            $idx = [int]$dd.Index
            $model = ("$($dd.Model)").Trim()
            if ([string]::IsNullOrWhiteSpace($model)) { $model = (L 'Неизвестный диск' 'Unknown disk') }
            $info = [pscustomobject]@{
                Number  = $idx
                Model   = $model
                SizeGB  = $(if ($dd.Size) { [math]::Round($dd.Size / 1GB, 1) } else { 0 })
                Letters = ($uniq -join ', ')
                Media   = "$($dd.InterfaceType)"
            }
            $Script:DiskByNumber[$idx] = $info
            foreach ($let in $uniq) {
                $key = $let.TrimEnd(':')
                $Script:LetterToDisk[$key] = $idx
            }
        }
    } catch {}
    try {
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $n = 0
            if (-not [int]::TryParse("$($pd.DeviceId)", [ref]$n)) { continue }
            if ($Script:DiskByNumber.ContainsKey($n)) {
                if ($pd.FriendlyName -and $Script:DiskByNumber[$n].Model -notlike "*$($pd.FriendlyName)*") {
                    if ($pd.FriendlyName.Length -gt 3) {
                        $Script:DiskByNumber[$n].Model = $pd.FriendlyName
                    }
                }
            } else {
                $Script:DiskByNumber[$n] = [pscustomobject]@{
                    Number  = $n
                    Model   = $pd.FriendlyName
                    SizeGB  = $(if ($pd.Size) { [math]::Round($pd.Size / 1GB, 1) } else { 0 })
                    Letters = ''
                    Media   = "$($pd.MediaType)"
                }
            }
        }
    } catch {}
    $Script:DiskMapReady = $true
}

function Format-DiskInfo {
    param($Info, [int]$Number = -1)
    if (-not $Info) {
        if ($Number -ge 0) { return ("Disk {0}" -f $Number) }
        return $null
    }
    $vol = ''
    if ($Info.Letters) { $vol = (L ' тома ' ' volumes ') + $Info.Letters }
    $size = ''
    if ($Info.SizeGB -gt 0) { $size = ', {0:N1} {1}' -f $Info.SizeGB, (L 'ГБ' 'GB') }
    return ('Disk {0} = {1}{2}{3}' -f $Info.Number, $Info.Model, $vol, $size)
}

function Resolve-EventDiskName {
    param($Event)
    Import-DiskNameMap
    $msg = ''
    if ($Event -and $Event.Message) { $msg = $Event.Message }
    $data = Get-EventDataMap $Event
    $num = $null
    foreach ($key in @('DiskNumber', 'Disk', 'TargetDisk', 'DeviceNumber')) {
        if ($data.ContainsKey($key) -and "$($data[$key])" -match '^\d+$') {
            $num = [int]$data[$key]
            break
        }
    }
    if ($null -eq $num -and $msg -match '(?i)\bDisk\s+(\d+)\b') { $num = [int]$Matches[1] }
    if ($null -eq $num -and $msg -match '(?i)PHYSICALDRIVE(\d+)') { $num = [int]$Matches[1] }
    if ($null -eq $num -and $msg -match '(?i)\\Device\\Harddisk(\d+)') { $num = [int]$Matches[1] }
    try {
        $xml = [xml]$Event.ToXml()
        foreach ($d in @($xml.Event.EventData.Data)) {
            $val = "$($d.'#text')"
            if ($null -eq $num -and $val -match '(?i)^(?:Disk\s*)?(\d+)$') { $num = [int]$Matches[1] }
        }
    } catch {}

    $letter = $null
    if ($msg -match '(?i)(?:том|volume|диск|drive)\s*([A-Z]):') { $letter = $Matches[1].ToUpperInvariant() }
    elseif ($msg -match '(?<![A-Za-z0-9])([A-Z]):(?:\\|\s|$)') { $letter = $Matches[1].ToUpperInvariant() }

    if ($null -eq $num -and $letter -and $Script:LetterToDisk.ContainsKey($letter)) {
        $num = [int]$Script:LetterToDisk[$letter]
    }
    if ($null -ne $num -and $Script:DiskByNumber.ContainsKey($num)) {
        return (Format-DiskInfo -Info $Script:DiskByNumber[$num] -Number $num)
    }
    if ($null -ne $num) {
        return (L ("Диск №{0} (модель сейчас не сопоставлена — диск могли сменить)" -f $num) ("Disk #{0} (model not mapped — the drive may have been replaced)" -f $num))
    }
    if ($letter) { return (L ("том {0}:" -f $letter) ("volume {0}:" -f $letter)) }
    return $null
}

function Write-DiskMapLegend {
    Import-DiskNameMap
    if (-not $Script:DiskByNumber -or $Script:DiskByNumber.Count -eq 0) { return }
    Write-ReportLine ('  ' + (L 'Какой диск какой:' 'Which disk is which:')) DarkCyan
    foreach ($k in ($Script:DiskByNumber.Keys | Sort-Object)) {
        Write-ReportLine ('    ' + (Format-DiskInfo -Info $Script:DiskByNumber[$k] -Number $k)) Gray
    }
}

function ConvertTo-BugCheckInt {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    try {
        if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [uint64]) {
            $n = [int64]$Value
            if ($n -eq 0) { return $null }
            return $n
        }
        $s = "$Value".Trim()
        if ($s -eq '' -or $s -eq '0' -or $s -eq '0x0' -or $s -eq '0x00000000') { return $null }
        if ($s -match '^0x') { return [Convert]::ToInt64($s, 16) }
        $parsed = 0
        if ([int64]::TryParse($s, [ref]$parsed)) {
            if ($parsed -eq 0) { return $null }
            return $parsed
        }
    } catch {}
    return $null
}

function Get-ModuleFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $app = [regex]::Match($Text, '(?i)Faulting application name:\s*([^\s,]+)')
    if ($app.Success) { return $app.Groups[1].Value.Trim() }
    $matches_ = [regex]::Matches($Text, '(?i)\b([a-z0-9_\-]+\.(?:sys|exe|dll))\b')
    foreach ($m in $matches_) {
        $name = $m.Groups[1].Value
        if ($name -notmatch '(?i)^(kernelbase|ntdll|kernel32|dcomp)\.dll$') { return $name }
    }
    return $null
}

function Get-BugCheckInfo {
    param(
        $Code = $null,
        [string]$Text = '',
        [string]$ModuleHint = ''
    )
    $num = ConvertTo-BugCheckInt $Code
    if ($null -eq $num -and $Text) {
        $m = [regex]::Match($Text, '(?i)(?:bugcheck|bug\s*check|stop|код(?:\s+ошибки)?|error\s+code)\s*[:=]?\s*(0x[0-9a-f]{2,16}|\d+)')
        if (-not $m.Success) { $m = [regex]::Match($Text, '(?i)\b(0x[0-9a-f]{8})\b') }
        if ($m.Success) { $num = ConvertTo-BugCheckInt $m.Groups[1].Value }
        if ($null -eq $num) {
            $named = [regex]::Match($Text, '(?i)\b([A-Z][A-Z0-9_]{8,})\b')
            if ($named.Success) {
                foreach ($k in $Script:BugCheckMap.Keys) {
                    if ($Script:BugCheckMap[$k].Name -eq $named.Groups[1].Value) { $num = [int64]$k; break }
                }
            }
        }
    }

    $module = $ModuleHint
    if (-not $module) { $module = Get-ModuleFromText $Text }

    $info = @{
        Code       = $num
        CodeHex    = $null
        Name       = $null
        Cause      = $null
        Likely     = $null
        LikelyText = $null
        Module     = $module
        Known      = $false
    }
    if ($null -eq $num) { return $info }

    $info.CodeHex = ('0x{0:X8}' -f $num)
    $row = $null
    foreach ($k in $Script:BugCheckMap.Keys) {
        try {
            if ([int64]$k -eq [int64]$num) { $row = $Script:BugCheckMap[$k]; break }
        } catch {}
    }
    if ($row) {
        $info.Known = $true
        $info.Name = $row.Name
        $info.Cause = (L $row.Ru $row.En)
        $info.Likely = $row.Likely
        if ($Script:LikelyLabel.ContainsKey($row.Likely)) {
            $lab = $Script:LikelyLabel[$row.Likely]
            $info.LikelyText = (L $lab.Ru $lab.En)
        }
    }
    if (-not $info.Name) { $info.Name = 'UNKNOWN_BUGCHECK' }
    if (-not $info.Cause) {
        $info.Cause = (L 'Код есть в журнале, но нет готовой расшифровки. Разберите минидамп в BlueScreenView/WinDbg.' 'The code is logged but has no built-in decode. Analyze the minidump in BlueScreenView/WinDbg.')
    }
    return $info
}

function Write-BugCheckDecode {
    param($Info)
    if (-not $Info -or $null -eq $Info.Code) { return }
    $head = (L 'РАСШИФРОВКА BSOD' 'BSOD DECODE')
    Write-ReportLine ("    {0}: {1} — {2}" -f $head, $Info.CodeHex, $Info.Name) Red
    if ($Info.LikelyText) {
        Write-ReportLine ("    {0}: {1}" -f (L 'Вероятная область' 'Likely area'), $Info.LikelyText) Yellow
    }
    if ($Info.Module) {
        Write-ReportLine ("    {0}: {1}" -f (L 'Модуль / процесс' 'Module / process'), $Info.Module) Yellow
    }
    Write-ReportLine ("    {0}: {1}" -f (L 'Причина' 'Cause'), $Info.Cause) DarkYellow
}

function Get-WerBlueScreens {
    $reports = New-Object System.Collections.ArrayList
    $roots = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -Filter 'Report.wer' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $Script:StartDate } |
            ForEach-Object {
                try {
                    $raw = [System.IO.File]::ReadAllText($_.FullName)
                    if ($raw -notmatch '(?i)EventType\s*=\s*BlueScreen|EventType\s*=\s*LiveKernelEvent') { return }
                    $code = $null
                    $cm = [regex]::Match($raw, '(?im)^Sig\[0\]\.Value=(0x[0-9A-Fa-f]+|\d+)\s*$')
                    if (-not $cm.Success) { $cm = [regex]::Match($raw, '(?im)^P1=(0x[0-9A-Fa-f]+|\d+)\s*$') }
                    if ($cm.Success) { $code = $cm.Groups[1].Value }
                    $app = $null
                    $am = [regex]::Match($raw, '(?im)^AppPath=(.+)$')
                    if ($am.Success) { $app = [IO.Path]::GetFileName($am.Groups[1].Value.Trim()) }
                    if (-not $app) {
                        $fm = [regex]::Match($raw, '(?im)^FriendlyEventName=(.+)$')
                        if ($fm.Success) { $app = Get-ModuleFromText $fm.Groups[1].Value }
                    }
                    [void]$reports.Add([pscustomobject]@{
                        Time   = $_.LastWriteTime
                        Code   = $code
                        Module = $app
                        Path   = $_.FullName
                        Text   = $raw
                    })
                } catch {}
            }
    }
    return @($reports)
}

function Resolve-WheaComponent {
    param($Event)
    $name = (L 'Неизвестный компонент устройства' 'Unknown device component')
    try {
        if ($Event.Properties -and $Event.Properties.Count -gt 0) {
            foreach ($prop in $Event.Properties) {
                $val = $prop.Value
                if ($val -is [byte[]] -and $val.Length -ge 16) {
                    $hex = (($val | ForEach-Object { '{0:X2}' -f $_ }) -join '').ToUpperInvariant()
                    $hex = $hex -replace '-', ''
                    foreach ($g in $Script:WheaGuidMap.Keys) {
                        $gNorm = ($g -replace '-', '').ToUpperInvariant()
                        if ($hex -like "*$gNorm*") {
                            $row = $Script:WheaGuidMap[$g]
                            return (L $row.Ru $row.En)
                        }
                    }
                }
                if ($val -is [guid]) {
                    $gNorm = $val.ToString('N').ToUpperInvariant()
                    if ($Script:WheaGuidMap.ContainsKey($gNorm)) {
                        $row = $Script:WheaGuidMap[$gNorm]
                        return (L $row.Ru $row.En)
                    }
                }
                if ($val -is [string] -and $val.Length -gt 2 -and $val.Length -lt 120) {
                    if ($val -match 'PCI|NVMe|Memory|Processor|DRAM|SSD|AHCI') {
                        return $val
                    }
                }
            }
        }
        if ($Event.Message -match 'PCI EXPRESS|PCIe|NVMe') { return 'PCI Express / NVMe' }
        if ($Event.Message -match '(?i)memory|памят') { return (L 'Оперативная память (RAM)' 'System memory (RAM)') }
        if ($Event.Message -match '(?i)processor|процесс') { return (L 'Процессор (CPU)' 'Processor (CPU)') }
    } catch {}
    return $name
}

function Show-EventWindow {
    param(
        [Parameter(Mandatory)][datetime]$CenterTime,
        [string]$AnchorLabel = '',
        [int]$Minutes = 5
    )
    if ([string]::IsNullOrWhiteSpace($AnchorLabel)) {
        $AnchorLabel = (L 'критическое событие' 'critical event')
    }
    $from = $CenterTime.AddMinutes(-$Minutes)
    $to = $CenterTime.AddMinutes($Minutes)
    Write-ReportLine ("    ▸ {0} ±{1} {2} {3:dd.MM.yyyy HH:mm:ss} ({4})" -f (L 'Анализ журнала' 'Log window'), $Minutes, (L 'мин вокруг' 'min around'), $CenterTime, $AnchorLabel) Cyan

    $nearby = @()
    foreach ($log in @('System', 'Application', 'Setup')) {
        $nearby += Find-CachedEvents -LogName $log -From $from -To $to -Max 120
    }

    if ($nearby.Count -eq 0) {
        Write-ReportLine ('      ' + (L 'В окне ±5 мин нет записей Error/Warning/Critical (или журнал пуст).' 'No Error/Warning/Critical records in the ±5 min window (or the log is empty).')) DarkGray
        Write-ReportLine ('      ' + (L 'Это бывает, если система обесточилась мгновенно и не успела записать причину.' 'This happens when power vanished instantly and Windows could not record a cause.')) DarkGray
        return @()
    }

    $filtered = @($nearby | Where-Object { -not (Test-IsNoiseProvider $_.ProviderName) } | Sort-Object TimeCreated)
    if ($filtered.Count -eq 0) {
        Write-ReportLine ('      ' + (L 'В окне были только «шумные» события (обновления/DCOM/DNS и т.п.) — они отфильтрованы.' 'The window only had noisy events (Update/DCOM/DNS, etc.) — they were filtered.')) DarkGray
        return @()
    }

    $before = @($filtered | Where-Object { $_.TimeCreated -lt $CenterTime })
    $after  = @($filtered | Where-Object { $_.TimeCreated -gt $CenterTime })

    Write-ReportLine ("      {0}: {1} | {2}: {3} | {4}: {5}" -f (L 'Связанных записей (без шума)' 'Related records (no noise)'), $filtered.Count, (L 'до' 'before'), $before.Count, (L 'после' 'after'), $after.Count) DarkCyan

    if ($before.Count -gt 0) {
        Write-ReportLine ('      —— ' + (L 'ДО события (возможные причины)' 'BEFORE (possible causes)') + ' ——') DarkYellow
        foreach ($ev in ($before | Select-Object -Last 12)) {
            $delta = [int]($CenterTime - $ev.TimeCreated).TotalSeconds
            $line = "      [{0:HH:mm:ss}] (-{1} {2}) {3} ID {4}: {5}" -f $ev.TimeCreated, $delta, (L 'с' 's'), $ev.ProviderName, $ev.Id, (Get-ShortMessage $ev 120)
            $col = if (Test-IsRelevantProvider $ev.ProviderName) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray }
            Write-ReportLine $line $col
        }
    } else {
        Write-ReportLine ('      ' + (L 'ДО события: полезных записей нет (типично для мгновенного отключения питания).' 'BEFORE: no useful records (typical for instant power loss).')) DarkGray
    }

    Write-ReportLine ("      ★ {0}: {1:HH:mm:ss} — {2}" -f (L 'ЯКОРЬ' 'ANCHOR'), $CenterTime, $AnchorLabel) Red

    if ($after.Count -gt 0) {
        Write-ReportLine ('      —— ' + (L 'ПОСЛЕ события (следствие / загрузка)' 'AFTER (aftermath / boot)') + ' ——') DarkYellow
        foreach ($ev in ($after | Select-Object -First 12)) {
            $delta = [int]($ev.TimeCreated - $CenterTime).TotalSeconds
            $line = "      [{0:HH:mm:ss}] (+{1} {2}) {3} ID {4}: {5}" -f $ev.TimeCreated, $delta, (L 'с' 's'), $ev.ProviderName, $ev.Id, (Get-ShortMessage $ev 120)
            Write-ReportLine $line DarkGray
        }
    }

    $hints = New-Object System.Collections.ArrayList
    $provSet = @($filtered | ForEach-Object { $_.ProviderName } | Select-Object -Unique)
    if ($provSet | Where-Object { $_ -match '^(disk|stornvme|storahci|iaStor|volmgr|ntfs)' }) {
        [void]$hints.Add((L 'В окне есть ошибки диска/тома — вероятная причина сбоя: накопитель (SSD/NVMe/кабель/слот).' 'Disk/volume errors in the window — likely cause: storage (SSD/NVMe/cable/slot).'))
    }
    if ($provSet | Where-Object { $_ -like '*WHEA*' }) {
        [void]$hints.Add((L 'В окне есть WHEA — вероятны RAM, CPU, PCIe/NVMe или перегрев.' 'WHEA in the window — likely RAM, CPU, PCIe/NVMe, or heat.'))
    }
    if ($provSet | Where-Object { $_ -match 'BugCheck|WER-SystemErrorReporting' }) {
        [void]$hints.Add((L 'В окне есть BugCheck/WER — был синий экран; смотрите код STOP и модуль.' 'BugCheck/WER in the window — a BSOD occurred; check the STOP code and module.'))
    }
    if ($provSet | Where-Object { $_ -match 'Display|nvlddmkm|amdkmdag|igfx' }) {
        [void]$hints.Add((L 'В окне есть сбой видеодрайвера — возможны TDR/GPU как триггер зависания.' 'A video driver fault is in the window — TDR/GPU may have triggered the hang.'))
    }
    if ($provSet | Where-Object { $_ -eq 'EventLog' }) {
        [void]$hints.Add((L 'EventLog «грязно закрыт» — следствие жёсткой перезагрузки, не первопричина.' 'EventLog dirty close — a result of a hard reboot, not the root cause.'))
    }
    if ($hints.Count -gt 0) {
        Write-ReportLine ('      ' + (L 'ВЫВОД ПО ОКНУ:' 'WINDOW CONCLUSION:')) Cyan
        foreach ($h in $hints) {
            Write-ReportLine ("      • {0}" -f $h) Yellow
        }
    } else {
        Write-ReportLine ('      ' + (L 'ВЫВОД ПО ОКНУ: явной «причины» в журнале рядом нет — чаще БП/питание, перегрев или полный завис без записи.' 'WINDOW CONCLUSION: no clear nearby cause — more often PSU/power, heat, or a hang that left no log.')) Yellow
    }

    return $filtered
}

function Get-QuickVerdictText {
    $findings = @(Get-HardwareFindings)
    $softOnly = @($Script:Findings | Where-Object { $_.Kind -eq 'AppCrash' })
    if ($findings.Count -eq 0) {
        if ($softOnly.Count -gt 0) {
            return @{
                Color = [ConsoleColor]::DarkGray
                Text  = (L 'Железо тихо. Есть краши системных процессов — это софт, не накопитель и не БП.' 'Hardware is quiet. There are system-process crashes — software, not storage or PSU.')
            }
        }
        if ($Script:SoftCrashHidden -gt 0) {
            return @{
                Color = [ConsoleColor]::Green
                Text  = (L 'По железу чисто. Краши игр/браузеров скрыты и в вердикт не входят.' 'Hardware looks clean. Game/browser crashes are hidden and do not affect the verdict.')
            }
        }
        return @{
            Color = [ConsoleColor]::Green
            Text  = (L 'По журналам за период критичных неисправностей не видно.' 'No critical faults are visible in the logs for this period.')
        }
    }
    $hasKP   = @($findings | Where-Object { $_.Kind -eq 'KernelPower' }).Count -gt 0
    $hasWhea = @($findings | Where-Object { $_.Kind -eq 'WHEA' }).Count -gt 0
    $hasBsod = @($findings | Where-Object { $_.Kind -in @('BugCheck', 'Minidump') }).Count -gt 0
    $hasDisk = @($findings | Where-Object { $_.Kind -in @('DiskEvent', 'DiskHealth', 'VolumeDirty') -or ($_.Tags -contains 'disk') }).Count -gt 0
    $hasGpu  = @($findings | Where-Object { $_.Kind -eq 'GPU' }).Count -gt 0
    $hasRam  = @($findings | Where-Object { $_.Kind -in @('MemoryDiag', 'Resource') -or ($_.Tags -contains 'ram') }).Count -gt 0
    $diskRepeat = @($findings | Where-Object { $_.Kind -in @('DiskEvent', 'DiskHealth') }).Count -ge 4
    $bsodInfo = @($findings | Where-Object { $_.Tags -contains 'bsod-decode' } | Select-Object -First 1)

    if ($hasBsod -and $bsodInfo -and $bsodInfo.Detail) {
        return @{ Color = [ConsoleColor]::Red; Text = ((L 'Скорее BSOD:' 'Likely BSOD:') + ' ' + $bsodInfo.Detail) }
    }
    if ($hasKP -and $hasDisk) {
        return @{ Color = [ConsoleColor]::Red; Text = (L 'Скорее накопитель: Kernel-Power 41 вместе с ошибками диска.' 'Likely storage: Kernel-Power 41 together with disk errors.') }
    }
    if ($hasBsod -and $hasDisk) {
        return @{ Color = [ConsoleColor]::Red; Text = (L 'Скорее диск: BSOD рядом с ошибками накопителя.' 'Likely disk: BSOD next to storage errors.') }
    }
    if ($hasKP -and $hasWhea) {
        return @{ Color = [ConsoleColor]::Red; Text = (L 'Скорее железо: Kernel-Power 41 + WHEA (RAM/CPU/PCIe).' 'Likely hardware: Kernel-Power 41 + WHEA (RAM/CPU/PCIe).') }
    }
    if ($hasWhea -or $hasRam) {
        return @{ Color = [ConsoleColor]::Red; Text = (L 'Скорее память/CPU: есть WHEA или ошибки RAM.' 'Likely RAM/CPU: WHEA or memory errors are present.') }
    }
    if ($hasKP -and $hasGpu) {
        return @{ Color = [ConsoleColor]::Yellow; Text = (L 'Скорее GPU: внезапная перезагрузка рядом со сбоем видеодрайвера.' 'Likely GPU: unexpected reboot next to a video driver fault.') }
    }
    if ($hasBsod) {
        return @{ Color = [ConsoleColor]::Red; Text = (L 'Скорее BSOD: есть синий экран — смотрите расшифровку кода и модуль.' 'Likely BSOD: a blue screen is present — see the STOP decode and module.') }
    }
    if ($hasKP) {
        return @{ Color = [ConsoleColor]::Yellow; Text = (L 'Скорее питание/перегрев: Kernel-Power 41 без явной причины рядом.' 'Likely power/heat: Kernel-Power 41 without a nearby cause.') }
    }
    if ($hasDisk -and $diskRepeat) {
        return @{ Color = [ConsoleColor]::Red; Text = (L 'Скорее накопитель: ошибки диска повторяются (серия, не разовый сбой).' 'Likely storage: disk errors repeat (a series, not a one-off).') }
    }
    if ($hasDisk) {
        return @{ Color = [ConsoleColor]::Yellow; Text = (L 'Скорее накопитель: есть ошибки диска/тома (пока единичные или редкие).' 'Likely storage: disk/volume errors are present (still single or rare).') }
    }
    if ($hasGpu) {
        return @{ Color = [ConsoleColor]::Yellow; Text = (L 'Скорее видеодрайвер/GPU.' 'Likely video driver/GPU.') }
    }
    return @{ Color = [ConsoleColor]::Yellow; Text = (L 'Есть замечания, однозначной первопричины нет.' 'There are findings, but no single root cause.') }
}

function Collect-QuickFindings {
    foreach ($ev in (Find-CachedEvents -Provider 'Microsoft-Windows-Kernel-Power' -Id 41 -Max 20)) {
        $data = Get-EventDataMap $ev
        $bc = $null
        if ($data.ContainsKey('BugcheckCode')) { $bc = $data['BugcheckCode'] }
        $info = Get-BugCheckInfo -Code $bc -Text $ev.Message
        Add-Finding -Kind 'KernelPower' -Time $ev.TimeCreated -Title 'Kernel-Power 41' -Tags @('power')
        if ($info.Code) {
            Add-Finding -Kind 'BugCheck' -Time $ev.TimeCreated -Title $info.Name -Detail ("{0} {1}" -f $info.CodeHex, $info.Name) -Tags @('bsod', 'bsod-decode')
        }
    }
    foreach ($ev in (Find-CachedEvents -Provider 'EventLog' -Id 6008 -Max 20)) {
        Add-Finding -Kind 'UnexpectedShutdown' -Time $ev.TimeCreated -Title 'EventLog 6008' -Tags @('power')
    }
    foreach ($ev in (Find-CachedEvents -Provider 'Microsoft-Windows-WHEA-Logger' -Max 15)) {
        Add-Finding -Kind 'WHEA' -Time $ev.TimeCreated -Title 'WHEA' -Tags @('whea')
    }
    foreach ($ev in (Find-CachedEvents -Provider 'Microsoft-Windows-WER-SystemErrorReporting' -Max 10)) {
        $info = Get-BugCheckInfo -Text $ev.Message
        $detail = if ($info.Code) { '{0} {1} {2}' -f $info.CodeHex, $info.Name, $info.Module } else { (Get-ShortMessage $ev 120) }
        Add-Finding -Kind 'BugCheck' -Time $ev.TimeCreated -Title $(if ($info.Name) { $info.Name } else { 'BSOD' }) -Detail $detail.Trim() -Tags @('bsod', $(if ($info.Code) { 'bsod-decode' } else { 'bsod' }))
    }
    foreach ($ev in (Find-CachedEvents -Provider 'BugCheck' -Max 10)) {
        $info = Get-BugCheckInfo -Text $ev.Message
        $detail = if ($info.Code) { '{0} {1}' -f $info.CodeHex, $info.Name } else { (Get-ShortMessage $ev 120) }
        Add-Finding -Kind 'BugCheck' -Time $ev.TimeCreated -Title $(if ($info.Name) { $info.Name } else { 'BugCheck' }) -Detail $detail.Trim() -Tags @('bsod', $(if ($info.Code) { 'bsod-decode' } else { 'bsod' }))
    }
    foreach ($p in @('disk', 'ntfs', 'volmgr', 'stornvme', 'storahci', 'iaStor', 'iaStorV')) {
        $evs = Find-CachedEvents -Provider $p -Level @(1, 2, 3) -Max 3
        foreach ($ev in $evs) {
            Add-Finding -Kind 'DiskEvent' -Time $ev.TimeCreated -Title ("{0} ID {1}" -f $p, $ev.Id) -Tags @('disk')
        }
    }
    foreach ($p in @('Display', 'nvlddmkm', 'amdkmdag', 'igfx')) {
        foreach ($ev in (Find-CachedEvents -Provider $p -Max 5)) {
            Add-Finding -Kind 'GPU' -Time $ev.TimeCreated -Title $p -Tags @('gpu')
        }
    }
}

function Write-QuickVerdict {
    $v = Get-QuickVerdictText
    Write-Header (L 'КРАТКИЙ ВЕРДИКТ' 'QUICK VERDICT')
    Write-ReportLine ("  {0}" -f $v.Text) $v.Color
    $hw = @(Get-HardwareFindings)
    $uniq = @($hw | Select-Object -ExpandProperty Kind -Unique).Count
    Write-ReportLine ("  {0}: {1}  |  {2}: {3}" -f (L 'Аппаратных фактов' 'Hardware findings'), $hw.Count, (L 'уникальных проблем' 'unique issue types'), $uniq) DarkGray
    if ($Script:SoftCrashHidden -gt 0) {
        Write-ReportLine ("  {0}: {1} — {2}" -f (L 'Краши игр/браузеров скрыты' 'Game/browser crashes hidden'), $Script:SoftCrashHidden, (L 'на вердикт не влияют' 'do not affect the verdict')) DarkGray
    }
}

function Get-ClipboardSummary {
    $v = Get-QuickVerdictText
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add(("WinErrorParser {0} | {1:yyyy-MM-dd HH:mm}" -f $Script:Version, (Get-Date)))
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        [void]$lines.Add(("{0}: {1} | {2} {3}" -f (L 'ПК' 'PC'), $cs.Name, $cs.Manufacturer, $cs.Model))
    } catch {}
    [void]$lines.Add(((L 'Вердикт' 'Verdict') + ': ' + $v.Text))
    $kinds = @(Get-HardwareFindings | Group-Object Kind | ForEach-Object { '{0}×{1}' -f (Get-FindingKindLabel $_.Name), $_.Count })
    if ($kinds.Count -gt 0) { [void]$lines.Add(((L 'Железо' 'Hardware') + ': ' + ($kinds -join ', '))) }
    if ($Script:SoftCrashHidden -gt 0) {
        [void]$lines.Add(((L 'Скрыто крашей игр/браузеров' 'Hidden game/browser crashes') + ': ' + $Script:SoftCrashHidden))
    }
    [void]$lines.Add(((L 'Отчёт' 'Report') + ': ' + $Script:ReportPath))
    if ($Script:WriteHtml) { [void]$lines.Add(('HTML: ' + $Script:HtmlPath)) }
    return ($lines -join [Environment]::NewLine)
}

function Copy-SummaryToClipboard {
    $text = Get-ClipboardSummary
    try {
        Set-Clipboard -Value $text -ErrorAction Stop
        return $true
    } catch {
        try {
            $text | & "$env:SystemRoot\System32\clip.exe"
            return $true
        } catch { return $false }
    }
}

function Escape-HtmlText {
    param($Text)
    if ($null -eq $Text) { return '' }
    $t = "$Text"
    $t = $t -replace '[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\u200B-\u200F\u202A-\u202E\uFEFF]', ''
    $t = $t -replace '&', '&amp;'
    $t = $t -replace '<', '&lt;'
    $t = $t -replace '>', '&gt;'
    $t = $t -replace '"', '&quot;'
    return $t
}

function Get-FindingKindLabel {
    param([string]$Kind)
    switch ($Kind) {
        'KernelPower'         { L 'Внезапные перезагрузки' 'Unexpected reboots' }
        'UnexpectedShutdown'  { L 'Неожиданное выключение' 'Unexpected shutdown' }
        'WHEA'                { L 'Железо (WHEA)' 'Hardware (WHEA)' }
        'BugCheck'            { L 'Синий экран' 'Blue screen' }
        'Minidump'            { L 'Минидампы' 'Minidumps' }
        'DiskEvent'           { L 'События диска' 'Disk events' }
        'DiskHealth'          { L 'Здоровье диска' 'Disk health' }
        'GPU'                 { L 'Видео / GPU' 'Video / GPU' }
        'MemoryDiag'          { L 'Ошибки RAM' 'RAM errors' }
        'Resource'            { L 'Нехватка ресурсов' 'Resource exhaustion' }
        'Device'              { L 'Устройства' 'Devices' }
        'Battery'             { L 'Батарея' 'Battery' }
        'Thermal'             { L 'Перегрев' 'Overheating' }
        'AppCrash'            { L 'Краши системных процессов' 'System process crashes' }
        'LowDisk'             { L 'Мало места' 'Low disk space' }
        'VolumeDirty'         { L 'Грязный том / CHKDSK' 'Dirty volume / CHKDSK' }
        'Bus'                 { L 'USB / сеть / PCIe' 'USB / network / PCIe' }
        'Sleep'               { L 'Сон / Fast Startup' 'Sleep / Fast Startup' }
        default               { $Kind }
    }
}

function Get-FindingKindColor {
    param([string]$Kind)
    switch ($Kind) {
        'KernelPower'         { '#f43f5e' }
        'UnexpectedShutdown'  { '#fb7185' }
        'WHEA'                { '#a78bfa' }
        'BugCheck'            { '#ef4444' }
        'Minidump'            { '#f97316' }
        'DiskEvent'           { '#38bdf8' }
        'DiskHealth'          { '#0ea5e9' }
        'GPU'                 { '#eab308' }
        'MemoryDiag'          { '#22c55e' }
        'Resource'            { '#84cc16' }
        'Device'              { '#94a3b8' }
        'Battery'             { '#f59e0b' }
        'Thermal'             { '#fb923c' }
        'AppCrash'            { '#64748b' }
        'LowDisk'             { '#06b6d4' }
        'VolumeDirty'         { '#22d3ee' }
        'Bus'                 { '#818cf8' }
        'Sleep'               { '#a78bfa' }
        default               { '#818cf8' }
    }
}

function ConvertTo-InvNum {
    param([double]$Value, [string]$Format = '0.##')
    return $Value.ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}

function New-SvgDonut {
    param($Groups, [int]$Size = 200)
    $total = 0
    foreach ($g in $Groups) { $total += [int]$g.Count }
    $cx = $Size / 2.0
    $cy = $Size / 2.0
    $r = $Size * 0.36
    $stroke = $Size * 0.16
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('<svg viewBox="0 0 {0} {0}" class="chart-svg" role="img">' -f $Size))
    if ($total -le 0) {
        [void]$sb.Append(('<circle cx="{0}" cy="{0}" r="{1}" fill="none" stroke="#243044" stroke-width="{2}"/>' -f (ConvertTo-InvNum $cx), (ConvertTo-InvNum $r), (ConvertTo-InvNum $stroke)))
        [void]$sb.Append(('<text x="{0}" y="{1}" text-anchor="middle" fill="#8b98a5" font-size="13">{2}</text>' -f (ConvertTo-InvNum $cx), (ConvertTo-InvNum ($cy + 4)), (Escape-HtmlText (L 'нет данных' 'no data'))))
        [void]$sb.Append('</svg>')
        return $sb.ToString()
    }
    $angle = -90.0
    $i = 0
    foreach ($g in $Groups) {
        $slice = 360.0 * $g.Count / $total
        $color = Get-FindingKindColor $g.Name
        if ($slice -ge 359.9) {
            [void]$sb.Append(('<circle cx="{0}" cy="{1}" r="{2}" fill="none" stroke="{3}" stroke-width="{4}"/>' -f (ConvertTo-InvNum $cx), (ConvertTo-InvNum $cy), (ConvertTo-InvNum $r), $color, (ConvertTo-InvNum $stroke)))
        } else {
            $a1 = $angle * [math]::PI / 180.0
            $a2 = ($angle + $slice) * [math]::PI / 180.0
            $x1 = $cx + $r * [math]::Cos($a1)
            $y1 = $cy + $r * [math]::Sin($a1)
            $x2 = $cx + $r * [math]::Cos($a2)
            $y2 = $cy + $r * [math]::Sin($a2)
            $large = 0
            if ($slice -gt 180) { $large = 1 }
            $d = 'M {0} {1} A {2} {2} 0 {3} 1 {4} {5}' -f (ConvertTo-InvNum $x1), (ConvertTo-InvNum $y1), (ConvertTo-InvNum $r), $large, (ConvertTo-InvNum $x2), (ConvertTo-InvNum $y2)
            $title = '{0}: {1}' -f (Get-FindingKindLabel $g.Name), $g.Count
            [void]$sb.Append(('<path d="{0}" fill="none" stroke="{1}" stroke-width="{2}" stroke-linecap="butt"><title>{3}</title></path>' -f $d, $color, (ConvertTo-InvNum $stroke), (Escape-HtmlText $title)))
        }
        $angle += $slice
        $i++
    }
    [void]$sb.Append(('<circle cx="{0}" cy="{1}" r="{2}" fill="#121826"/>' -f (ConvertTo-InvNum $cx), (ConvertTo-InvNum $cy), (ConvertTo-InvNum ($r - $stroke * 0.62))))
    [void]$sb.Append(('<text x="{0}" y="{1}" text-anchor="middle" fill="#f8fafc" font-size="22" font-weight="700">{2}</text>' -f (ConvertTo-InvNum $cx), (ConvertTo-InvNum ($cy - 2)), $total))
    [void]$sb.Append(('<text x="{0}" y="{1}" text-anchor="middle" fill="#8b98a5" font-size="11">{2}</text>' -f (ConvertTo-InvNum $cx), (ConvertTo-InvNum ($cy + 16)), (Escape-HtmlText (L 'фактов' 'facts'))))
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function New-SvgBars {
    param($Labels, $Values, $Colors, [int]$Width = 640, [int]$Height = 220)
    $n = @($Values).Count
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('<svg viewBox="0 0 {0} {1}" class="chart-svg" role="img">' -f $Width, $Height))
    if ($n -eq 0) {
        [void]$sb.Append(('<text x="20" y="110" fill="#8b98a5">{0}</text></svg>' -f (Escape-HtmlText (L 'нет данных' 'no data'))))
        return $sb.ToString()
    }
    $max = 1
    foreach ($v in $Values) { if ([int]$v -gt $max) { $max = [int]$v } }
    $padL = 28; $padB = 36; $padT = 12; $padR = 10
    $plotW = $Width - $padL - $padR
    $plotH = $Height - $padT - $padB
    $gap = [math]::Max(2.0, $plotW / $n * 0.18)
    $barW = [math]::Max(3.0, ($plotW / $n) - $gap)
    [void]$sb.Append(('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#243044"/>' -f $padL, ($padT + $plotH), ($Width - $padR)))
    for ($i = 0; $i -lt $n; $i++) {
        $val = [int]$Values[$i]
        $h = $plotH * $val / $max
        $x = $padL + $i * ($barW + $gap)
        $y = $padT + $plotH - $h
        $col = '#38bdf8'
        if ($Colors -and $i -lt @($Colors).Count -and $Colors[$i]) { $col = $Colors[$i] }
        if ($val -eq 0) { $col = '#1e293b' }
        $label = ''
        if ($Labels -and $i -lt @($Labels).Count) { $label = [string]$Labels[$i] }
        [void]$sb.Append(('<rect x="{0}" y="{1}" width="{2}" height="{3}" rx="3" fill="{4}"><title>{5}: {6}</title></rect>' -f (ConvertTo-InvNum $x), (ConvertTo-InvNum $y), (ConvertTo-InvNum $barW), (ConvertTo-InvNum ([math]::Max($h, 1))), $col, (Escape-HtmlText $label), $val))
        $showLabel = ($n -le 16) -or ($i % [math]::Max(1, [int][math]::Ceiling($n / 12.0)) -eq 0)
        if ($showLabel -and $label) {
            [void]$sb.Append(('<text x="{0}" y="{1}" text-anchor="middle" fill="#64748b" font-size="9">{2}</text>' -f (ConvertTo-InvNum ($x + $barW / 2)), ($Height - 8), (Escape-HtmlText $label)))
        }
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function New-SvgHBars {
    param($Labels, $Values, $Colors, [int]$Width = 520)
    $n = @($Values).Count
    $rowH = 28
    $height = [math]::Max(80, 16 + $n * $rowH)
    $max = 1
    foreach ($v in $Values) { if ([int]$v -gt $max) { $max = [int]$v } }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('<svg viewBox="0 0 {0} {1}" class="chart-svg" role="img">' -f $Width, $height))
    $padL = 150; $padR = 40
    $plotW = $Width - $padL - $padR
    for ($i = 0; $i -lt $n; $i++) {
        $val = [int]$Values[$i]
        $y = 10 + $i * $rowH
        $w = $plotW * $val / $max
        $col = '#818cf8'
        if ($Colors -and $i -lt @($Colors).Count) { $col = $Colors[$i] }
        $lab = ''
        if ($Labels -and $i -lt @($Labels).Count) { $lab = [string]$Labels[$i] }
        [void]$sb.Append(('<text x="8" y="{0}" fill="#cbd5e1" font-size="12">{1}</text>' -f ($y + 14), (Escape-HtmlText $lab)))
        [void]$sb.Append(('<rect x="{0}" y="{1}" width="{2}" height="16" rx="4" fill="{3}"/>' -f $padL, $y, (ConvertTo-InvNum ([math]::Max($w, 4))), $col))
        [void]$sb.Append(('<text x="{0}" y="{1}" fill="#f8fafc" font-size="12">{2}</text>' -f (ConvertTo-InvNum ($padL + $w + 8)), ($y + 13), $val))
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function Get-InventoryForHtml {
    $sys = [ordered]@{}
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        $sys.Computer = $cs.Name
        $sys.OS = '{0} ({1})' -f $os.Caption, $os.OSArchitecture
        $sys.Build = '{0}.{1}' -f $os.Version, $os.BuildNumber
        $sys.Model = '{0} | {1}' -f $cs.Manufacturer, $cs.Model
        if ($cpu) {
            $sys.CPU = '{0} ({1} {2}, {3} {4})' -f $cpu.Name.Trim(), $cpu.NumberOfCores, (L 'ядер' 'cores'), $cpu.NumberOfLogicalProcessors, (L 'потоков' 'threads')
        }
        $sys.RamTotal = ('{0:N1} {1}' -f ($cs.TotalPhysicalMemory / 1GB), (L 'ГБ' 'GB'))
        $sys.RamFree = ('{0:N1} {1}' -f ($os.FreePhysicalMemory / 1MB), (L 'ГБ' 'GB'))
        $sys.RamTotalGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $sys.RamFreeGb = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        if ($bios) {
            $biosDate = ConvertFrom-CimDate $bios.ReleaseDate
            if ($biosDate) {
                $sys.BIOS = '{0} | {1} | {2}' -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion, $biosDate.ToString('dd.MM.yyyy')
            } else {
                $sys.BIOS = '{0} | {1}' -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion
            }
        }
        $boot = $os.LastBootUpTime
        if ($boot -is [string]) {
            try { $boot = [Management.ManagementDateTimeConverter]::ToDateTime($boot) } catch {}
        }
        if ($boot -is [datetime]) {
            $sys.Uptime = ('{0:N1} {1}' -f ((Get-Date) - $boot).TotalHours, (L 'ч' 'h'))
            $sys.LastBoot = "$boot"
        }
    } catch {}

    $volumes = New-Object System.Collections.Generic.List[object]
    try {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | ForEach-Object {
            $total = 0.0
            $free = 0.0
            if ($_.Size) { $total = [math]::Round($_.Size / 1GB, 1) }
            if ($_.FreeSpace) { $free = [math]::Round($_.FreeSpace / 1GB, 1) }
            $pct = 0
            if ($_.Size -gt 0) { $pct = [int][math]::Round(100 * $_.FreeSpace / $_.Size, 0) }
            [void]$volumes.Add([pscustomobject]@{
                Letter = $_.DeviceID
                Fs     = $_.FileSystem
                Free   = $free
                Total  = $total
                Pct    = $pct
            })
        }
    } catch {}

    $disks = New-Object System.Collections.Generic.List[object]
    Import-DiskNameMap
    try {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $temp = $null; $wear = $null
            try {
                $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop
                if ($c) {
                    if ($null -ne $c.Temperature) { $temp = $c.Temperature }
                    if ($null -ne $c.Wear) { $wear = $c.Wear }
                }
            } catch {}
            [void]$disks.Add([pscustomobject]@{
                Name   = $d.FriendlyName
                Bus    = "$($d.BusType)"
                Media  = "$($d.MediaType)"
                SizeGB = $(if ($d.Size) { [math]::Round($d.Size / 1GB, 1) } else { 0 })
                Health = "$($d.HealthStatus)"
                Temp   = $temp
                Wear   = $wear
            })
        }
    } catch {}

    $bats = New-Object System.Collections.Generic.List[object]
    $winBat = @(); try { $winBat = @(Get-CimInstance Win32_Battery -ErrorAction Stop) } catch {}
    $static = Get-CimByNs 'BatteryStaticData'
    $full = Get-CimByNs 'BatteryFullChargedCapacity'
    $cycles = Get-CimByNs 'BatteryCycleCount'
    $st = Get-CimByNs 'BatteryStatus'
    $planName = $null
    try {
        $plan = Get-CimInstance -Namespace root/cimv2/power -ClassName Win32_PowerPlan -ErrorAction SilentlyContinue |
            Where-Object { $_.IsActive } | Select-Object -First 1
        if ($plan) { $planName = $plan.ElementName }
    } catch {}
    $count = [math]::Max($winBat.Count, [math]::Max($static.Count, $st.Count))
    for ($i = 0; $i -lt $count; $i++) {
        $name = (L 'Батарея' 'Battery')
        $chargePct = $null; $design = $null; $fullCap = $null; $remain = $null; $cycle = $null; $volt = $null; $mfr = $null; $status = $null
        if ($i -lt $winBat.Count -and $winBat[$i].Name) { $name = $winBat[$i].Name }
        if ($i -lt $winBat.Count -and $null -ne $winBat[$i].EstimatedChargeRemaining) { $chargePct = [int]$winBat[$i].EstimatedChargeRemaining }
        if ($i -lt $static.Count) {
            if ($static[$i].DesignedCapacity) { $design = [double]$static[$i].DesignedCapacity }
            if ($static[$i].ManufactureName) { $mfr = $static[$i].ManufactureName }
            if ($static[$i].DeviceName) { $name = $static[$i].DeviceName }
        }
        if ($i -lt $full.Count -and $full[$i].FullChargedCapacity) { $fullCap = [double]$full[$i].FullChargedCapacity }
        if ($i -lt $cycles.Count -and $null -ne $cycles[$i].CycleCount) { $cycle = [int]$cycles[$i].CycleCount }
        if ($i -lt $st.Count) {
            if ($st[$i].RemainingCapacity) { $remain = [double]$st[$i].RemainingCapacity }
            if ($st[$i].Voltage) { $volt = [math]::Round($st[$i].Voltage / 1000.0, 2) }
        }
        if ($null -eq $design -and $i -lt $winBat.Count -and $winBat[$i].DesignCapacity) { $design = [double]$winBat[$i].DesignCapacity }
        if ($null -eq $fullCap -and $i -lt $winBat.Count -and $winBat[$i].FullChargeCapacity) { $fullCap = [double]$winBat[$i].FullChargeCapacity }
        if ($null -eq $chargePct -and $remain -and $fullCap -and $fullCap -gt 0) { $chargePct = [int][math]::Round(100.0 * $remain / $fullCap, 0) }
        $health = $null
        if ($design -and $fullCap -and $design -gt 0) { $health = [int][math]::Round(100.0 * $fullCap / $design, 0) }
        if ($i -lt $winBat.Count) {
            $code = [int]$winBat[$i].BatteryStatus
            $statusMap = @{
                1 = (L 'разряд' 'discharging'); 2 = (L 'от сети, заряжена' 'AC, charged')
                3 = (L 'полная зарядка' 'fully charged'); 4 = (L 'низкий заряд' 'low')
                5 = (L 'критично низкий' 'critical'); 6 = (L 'заряжается' 'charging')
                7 = (L 'заряжается' 'charging'); 8 = (L 'заряжается' 'charging')
                9 = (L 'заряжается' 'charging'); 10 = (L 'не определено' 'undefined')
                11 = (L 'частично заряжена' 'partially charged')
            }
            if ($statusMap.ContainsKey($code)) { $status = $statusMap[$code] }
        }
        [void]$bats.Add([pscustomobject]@{
            Name = $name; Mfr = $mfr; Charge = $chargePct; Design = $design
            Full = $fullCap; Remain = $remain; Health = $health; Cycles = $cycle
            Volt = $volt; Status = $status
        })
    }

    return [pscustomobject]@{
        Sys     = $sys
        Volumes = @($volumes.ToArray())
        Disks   = @($disks.ToArray())
        Battery = @($bats.ToArray())
        Plan    = $planName
    }
}

function Export-HtmlReport {
    if (-not $Script:WriteHtml) { return }
    $allFindings = @($Script:Findings)
    $findings = @(Get-HardwareFindings)
    $v = Get-QuickVerdictText
    $inv = Get-InventoryForHtml
    $pcName = ''
    $pcModel = ''
    if ($inv.Sys.Computer) { $pcName = [string]$inv.Sys.Computer }
    if ($inv.Sys.Model) { $pcModel = [string]$inv.Sys.Model }

    $kindGroups = @($findings | Group-Object Kind | Sort-Object Count -Descending)
    $kindLabels = @($kindGroups | ForEach-Object { Get-FindingKindLabel $_.Name })
    $kindValues = @($kindGroups | ForEach-Object { [int]$_.Count })
    $kindColors = @($kindGroups | ForEach-Object { Get-FindingKindColor $_.Name })

    $dayMap = @{}
    $from = $Script:StartDate.Date
    $to = (Get-Date).Date
    if ($to -lt $from) { $to = $from }
    for ($d = $from; $d -le $to; $d = $d.AddDays(1)) {
        $dayMap[$d.ToString('yyyy-MM-dd')] = 0
    }
    foreach ($f in $findings) {
        if (-not $f.Time) { continue }
        $key = ([datetime]$f.Time).ToString('yyyy-MM-dd')
        if ($dayMap.ContainsKey($key)) { $dayMap[$key] = [int]$dayMap[$key] + 1 }
        else { $dayMap[$key] = 1 }
    }
    $dayKeys = @($dayMap.Keys | Sort-Object)
    if ($dayKeys.Count -gt 45) {
        $weekMap = [ordered]@{}
        foreach ($k in $dayKeys) {
            $dt = [datetime]::ParseExact($k, 'yyyy-MM-dd', $null)
            $offset = ([int]$dt.DayOfWeek + 6) % 7
            $wk = $dt.AddDays(-$offset).ToString('dd.MM')
            if (-not $weekMap.Contains($wk)) { $weekMap[$wk] = 0 }
            $weekMap[$wk] += [int]$dayMap[$k]
        }
        $barLabels = @($weekMap.Keys)
        $barValues = @($weekMap.Values)
        $barTitle = (L 'Факты по неделям' 'Facts by week')
    } else {
        $barLabels = @($dayKeys | ForEach-Object { ([datetime]::ParseExact($_, 'yyyy-MM-dd', $null)).ToString('dd.MM') })
        $barValues = @($dayKeys | ForEach-Object { [int]$dayMap[$_] })
        $barTitle = (L 'Факты по дням' 'Facts by day')
    }
    $barColors = @($barValues | ForEach-Object { if ($_ -gt 0) { '#38bdf8' } else { '#1e293b' } })

    $kp = @($findings | Where-Object Kind -eq 'KernelPower').Count
    $bsod = @($findings | Where-Object { $_.Kind -in @('BugCheck', 'Minidump') }).Count
    $disk = @($findings | Where-Object { $_.Kind -in @('DiskEvent', 'DiskHealth') -or ($_.Tags -contains 'disk') }).Count
    $whea = @($findings | Where-Object Kind -eq 'WHEA').Count
    $repeatBonus = 0
    foreach ($st in @(Get-FindingStats)) {
        if ($st.Weight -eq 'repeat') { $repeatBonus += 8 }
    }
    $score = [math]::Min(100, ($kp * 18) + ($bsod * 22) + ($whea * 18) + ($disk * 12) + $findings.Count + $repeatBonus)
    $scoreColor = '#22c55e'
    $scoreLabel = (L 'спокойно' 'calm')
    if ($score -ge 70) { $scoreColor = '#ef4444'; $scoreLabel = (L 'критично' 'critical') }
    elseif ($score -ge 35) { $scoreColor = '#f59e0b'; $scoreLabel = (L 'внимание' 'warning') }

    $verdictTone = 'ok'
    if ($v.Color -eq [ConsoleColor]::Red) { $verdictTone = 'bad' }
    elseif ($v.Color -eq [ConsoleColor]::Yellow) { $verdictTone = 'warn' }

    $colorMap = @{
        Red = '#fb7185'; DarkRed = '#ef4444'; Yellow = '#fbbf24'; DarkYellow = '#f59e0b'
        Green = '#34d399'; Cyan = '#22d3ee'; DarkCyan = '#2dd4bf'; DarkGray = '#7c8a9a'
        Gray = '#cbd5e1'; White = '#f8fafc'; Blue = '#60a5fa'; Magenta = '#c084fc'
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine(('<html lang="{0}"><head><meta charset="utf-8">' -f $Script:Lang))
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1"/>')
    [void]$sb.AppendLine(('<title>WinErrorParser {0}</title>' -f $Script:Version))
    [void]$sb.AppendLine(@'
<style>
:root{--bg:#0b1020;--card:#121826;--line:#1e293b;--text:#e8eef7;--muted:#8b98a5;--accent:#38bdf8}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(1100px 480px at 8% -12%,rgba(29,78,216,.28),transparent),var(--bg);color:var(--text);font-family:"Segoe UI",Calibri,system-ui,sans-serif}
header{padding:26px 32px 18px;border-bottom:1px solid var(--line);background:linear-gradient(90deg,rgba(15,23,42,.88),rgba(30,27,75,.35))}
header h1{margin:0 0 6px;font-size:30px;letter-spacing:.2px;font-weight:750}
.meta{color:var(--muted);font-size:13px}
nav{display:flex;gap:8px;padding:12px 32px;position:sticky;top:0;background:rgba(11,16,32,.94);z-index:5;border-bottom:1px solid var(--line)}
nav button{background:#1e293b;color:#e2e8f0;border:0;border-radius:999px;padding:8px 16px;cursor:pointer;font-weight:700}
nav button.active{background:#2563eb;color:#fff}
main{padding:22px 32px 56px;max-width:1120px}
.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:0 0 18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:16px 18px;display:flex;align-items:center;justify-content:space-between;gap:12px;min-height:92px;width:100%;color:inherit;font:inherit;text-align:left}
button.card.click{cursor:pointer}
button.card.click:hover{border-color:#38bdf8;transform:translateY(-1px);background:#162033}
.card.dead{opacity:.72;cursor:default}
.card .k{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.7px;font-weight:700}
.card .n{font-size:32px;font-weight:800;margin-top:4px;line-height:1}
.ico{width:42px;height:42px;border-radius:12px;display:grid;place-items:center;flex:0 0 42px}
.ico svg{width:22px;height:22px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.ico-blue{background:rgba(37,99,235,.18);color:#60a5fa}
.ico-red{background:rgba(244,63,94,.16);color:#fb7185}
.ico-cyan{background:rgba(14,165,233,.16);color:#38bdf8}
.ico-violet{background:rgba(167,139,250,.16);color:#a78bfa}
.verdict{border-radius:18px;padding:18px 20px;margin:0 0 18px;border:1px solid var(--line);display:flex;gap:14px;align-items:flex-start}
.verdict .v-ico{width:40px;height:40px;border-radius:12px;display:grid;place-items:center;flex:0 0 40px}
.verdict .v-ico svg{width:22px;height:22px}
.verdict.ok{background:#052e1a;border-color:#14532d}
.verdict.ok .v-ico{background:rgba(34,197,94,.18);color:#4ade80}
.verdict.warn{background:#3b2a08;border-color:#b45309}
.verdict.warn .v-ico{background:rgba(245,158,11,.2);color:#fbbf24}
.verdict.bad{background:#3f1219;border-color:#9f1239}
.verdict.bad .v-ico{background:rgba(244,63,94,.2);color:#fb7185}
.verdict h2{margin:0 0 6px;font-size:13px;color:#fbbf24;font-weight:700}
.verdict.ok h2{color:#86efac}
.verdict.bad h2{color:#fda4af}
.verdict p{margin:0;font-size:18px;line-height:1.4;font-weight:600}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin:0 0 18px}
.panel{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:18px}
.panel h3{margin:0 0 14px;font-size:16px}
.chart-svg{width:100%;height:auto;display:block}
.legend{display:flex;flex-wrap:wrap;gap:8px 14px;margin-top:10px;font-size:13px;color:#cbd5e1}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px}
.timeline{list-style:none;margin:0;padding:0}
.timeline li{display:grid;grid-template-columns:140px 12px 1fr;gap:10px;padding:8px 0}
.timeline .t{color:#94a3b8;font-size:13px}
.timeline .mark{width:10px;height:10px;border-radius:50%;margin-top:5px}
.disks{display:flex;flex-direction:column;gap:10px}
.chip{background:#0f172a;border:1px solid #334155;border-radius:14px;padding:12px 14px}
.chip-top{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:4px}
.chip-top b{font-size:14px}
.tag{background:#2563eb;color:#fff;border-radius:999px;padding:2px 9px;font-size:12px;font-weight:700}
.chip-name{font-size:14px;color:#e2e8f0}
.chip-sub{color:#94a3b8;font-size:12px;margin-top:3px}
.score{display:flex;align-items:center;gap:16px}
.score-ring{width:88px;height:88px;border-radius:50%;display:grid;place-items:center;background:conic-gradient(var(--sc) calc(var(--p)*1%),#1e293b 0);position:relative}
.score-ring:after{content:"";position:absolute;inset:10px;border-radius:50%;background:#121826}
.score-ring span{position:relative;z-index:1;font-weight:800;font-size:20px}
.log{background:#0a0f18;border:1px solid var(--line);border-radius:16px;padding:14px;max-height:70vh;overflow:auto}
.line{white-space:pre-wrap;word-break:break-word;line-height:1.45;font-family:Consolas,"Cascadia Mono",monospace;font-size:12.5px}
.search{width:100%;margin:0 0 10px;padding:10px 12px;border-radius:10px;border:1px solid #334155;background:#0f172a;color:#fff}
.kv{width:100%;border-collapse:collapse;font-size:14px}
.kv th{text-align:left;color:#94a3b8;font-weight:600;padding:8px 12px 8px 0;width:34%;vertical-align:top}
.kv td{padding:8px 0;color:#f1f5f9}
.bar{height:8px;background:#1e293b;border-radius:99px;overflow:hidden;margin-top:6px}
.bar>i{display:block;height:100%;border-radius:99px}
.hw-grid{display:grid;grid-template-columns:1.15fr .85fr;gap:16px;margin:0 0 18px}
.hidden{display:none}
footer{color:#64748b;padding:8px 32px 28px;font-size:12px}
.jumps{display:flex;flex-wrap:wrap;gap:8px;margin:0 0 16px}
.jumps a{color:#93c5fd;text-decoration:none;background:#0f172a;border:1px solid #334155;border-radius:999px;padding:6px 12px;font-size:12px;font-weight:600}
.jumps a:hover{border-color:#38bdf8}
@media(max-width:860px){.grid,.hw-grid,.cards{grid-template-columns:1fr 1fr}header,main,nav,footer{padding-left:16px;padding-right:16px}}
@media(max-width:560px){.cards,.grid,.hw-grid{grid-template-columns:1fr}}
</style></head><body>
'@)
    $icoWarn = '<svg viewBox="0 0 24 24"><path d="M12 3l10 18H2L12 3z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="M12 9v5M12 17.5h.01" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>'
    $icoOk = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" /><path d="M8 12.5l2.5 2.5L16 9"/></svg>'
    $icoSearch = '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="M16 16l5 5"/></svg>'
    $icoZap = '<svg viewBox="0 0 24 24"><path d="M13 3L4 14h7l-1 7 10-12h-7l0-6z" fill="currentColor" stroke="none"/></svg>'
    $icoDisk = '<svg viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="2"/><path d="M8 4v6h8V4M9 16h6"/></svg>'
    $icoChip = '<svg viewBox="0 0 24 24"><rect x="7" y="7" width="10" height="10" rx="1.5"/><path d="M9 3v4M15 3v4M9 17v4M15 17v4M3 9h4M3 15h4M17 9h4M17 15h4"/></svg>'
    $vIco = $icoWarn
    if ($verdictTone -eq 'ok') { $vIco = $icoOk }

    [void]$sb.AppendLine(('<header><h1>WinErrorParser {0}</h1><div class="meta">{1} · {2} · {3} {4} {5}</div></header>' -f $Script:Version, (Escape-HtmlText $pcName), (Escape-HtmlText $pcModel), (L 'период' 'period'), $Script:DaysBack, (L 'дн.' 'days')))
    [void]$sb.AppendLine(('<nav><button class="active" data-tab="dash">{0}</button><button data-tab="log">{1}</button></nav>' -f (Escape-HtmlText (L 'Обзор' 'Overview')), (Escape-HtmlText (L 'Полный лог' 'Full log'))))
    [void]$sb.AppendLine('<main>')
    [void]$sb.AppendLine('<section id="tab-dash">')
    [void]$sb.AppendLine(('<div class="verdict {0}" id="verdict"><div class="v-ico">{1}</div><div><h2>{2}</h2><p>{3}</p></div></div>' -f $verdictTone, $vIco, (Escape-HtmlText (L 'Краткий вердикт' 'Quick verdict')), (Escape-HtmlText $v.Text)))
    [void]$sb.AppendLine(('<div class="jumps"><a href="#verdict">{0}</a><a href="#sys">{1}</a><a href="#disks">{2}</a><a href="#freq">{3}</a><a href="#compare">{4}</a><a href="#timeline">{5}</a></div>' -f (Escape-HtmlText (L 'Вердикт' 'Verdict')), (Escape-HtmlText (L 'Система' 'System')), (Escape-HtmlText (L 'Диски' 'Disks')), (Escape-HtmlText (L 'Частота' 'Frequency')), (Escape-HtmlText (L 'Сравнение' 'Compare')), (Escape-HtmlText (L 'Лента' 'Timeline'))))

    $cardFacts = if ($findings.Count -gt 0) { 'click' } else { 'dead' }
    $cardKp    = if ($kp -gt 0) { 'click' } else { 'dead' }
    $cardDisk  = if ($disk -gt 0) { 'click' } else { 'dead' }
    $cardWhea  = if ($whea -gt 0) { 'click' } else { 'dead' }
    $filterFacts = 'Kernel-Power|WHEA|BugCheck|BSOD|диск|disk |NTFS|volmgr|stornvme|6008|внезапн'
    $filterKp    = 'Kernel-Power'
    $filterDisk  = 'диск|disk |NTFS|volmgr|stornvme|SMART|накопител|тома'
    $filterWhea  = 'WHEA'
    [void]$sb.AppendLine('<div class="cards">')
    [void]$sb.AppendLine(('<button type="button" class="card {0}" data-count="{1}" data-filter="{2}" title="{3}"><div><div class="k">{4}</div><div class="n">{1}</div></div><div class="ico ico-blue">{5}</div></button>' -f $cardFacts, $findings.Count, (Escape-HtmlText $filterFacts), (Escape-HtmlText (L 'Открыть факты в полном логе' 'Open findings in the full log')), (Escape-HtmlText (L 'Фактов' 'Findings')), $icoSearch))
    [void]$sb.AppendLine(('<button type="button" class="card {0}" data-count="{1}" data-filter="{2}" title="{3}"><div><div class="k">Kernel-Power 41</div><div class="n">{1}</div></div><div class="ico ico-red">{4}</div></button>' -f $cardKp, $kp, (Escape-HtmlText $filterKp), (Escape-HtmlText (L 'Показать Kernel-Power 41 в логе' 'Show Kernel-Power 41 in the log')), $icoZap))
    [void]$sb.AppendLine(('<button type="button" class="card {0}" data-count="{1}" data-filter="{2}" title="{3}"><div><div class="k">{4}</div><div class="n">{1}</div></div><div class="ico ico-cyan">{5}</div></button>' -f $cardDisk, $disk, (Escape-HtmlText $filterDisk), (Escape-HtmlText (L 'Показать ошибки диска в логе' 'Show disk errors in the log')), (Escape-HtmlText (L 'Диск' 'Disk')), $icoDisk))
    [void]$sb.AppendLine(('<button type="button" class="card {0}" data-count="{1}" data-filter="{2}" title="{3}"><div><div class="k">WHEA</div><div class="n">{1}</div></div><div class="ico ico-violet">{4}</div></button>' -f $cardWhea, $whea, (Escape-HtmlText $filterWhea), (Escape-HtmlText (L 'Показать WHEA в логе' 'Show WHEA in the log')), $icoChip))
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<div class="hw-grid">')
    [void]$sb.AppendLine(('<div class="panel" id="sys"><h3>{0}</h3><table class="kv">' -f (Escape-HtmlText (L 'Сведения о системе' 'System information'))))
    $sysRows = @(
        @{ K = (L 'ОС' 'OS'); V = $inv.Sys.OS }
        @{ K = (L 'Процессор' 'CPU'); V = $inv.Sys.CPU }
        @{ K = (L 'ОЗУ' 'RAM'); V = $(if ($inv.Sys.RamTotal -and $inv.Sys.RamFree) { '{0} · {1} {2}' -f $inv.Sys.RamTotal, $inv.Sys.RamFree, (L 'свободно' 'free') } else { $inv.Sys.RamTotal }) }
        @{ K = 'BIOS'; V = $inv.Sys.BIOS }
        @{ K = (L 'Версия / сборка' 'Version / build'); V = $inv.Sys.Build }
        @{ K = (L 'Время работы' 'Uptime'); V = $inv.Sys.Uptime }
    )
    foreach ($row in $sysRows) {
        if ([string]::IsNullOrWhiteSpace([string]$row.V)) { continue }
        [void]$sb.AppendLine(('<tr><th>{0}</th><td>{1}</td></tr>' -f (Escape-HtmlText $row.K), (Escape-HtmlText $row.V)))
    }
    if ($inv.Sys.RamTotalGb) {
        $usedPct = 0
        if ($inv.Sys.RamTotalGb -gt 0) {
            $usedPct = [int][math]::Round(100 * (1 - ($inv.Sys.RamFreeGb / $inv.Sys.RamTotalGb)), 0)
        }
        $usedCol = '#22c55e'
        if ($usedPct -ge 90) { $usedCol = '#ef4444' } elseif ($usedPct -ge 75) { $usedCol = '#f59e0b' }
        [void]$sb.AppendLine(('<tr><th>{0}</th><td>{1}%<div class="bar"><i style="width:{1}%;background:{2}"></i></div></td></tr>' -f (Escape-HtmlText (L 'Занято ОЗУ' 'RAM used')), $usedPct, $usedCol))
    }
    [void]$sb.AppendLine('</table></div>')

    [void]$sb.AppendLine(('<div class="panel" id="disks"><h3>{0}</h3><div class="disks">' -f (Escape-HtmlText (L 'Диски и тома' 'Disks and volumes'))))
    $diskChips = 0
    if ($Script:DiskByNumber -and $Script:DiskByNumber.Count -gt 0) {
        foreach ($k in ($Script:DiskByNumber.Keys | Sort-Object)) {
            $info = $Script:DiskByNumber[$k]
            $tagsHtml = ''
            if ($info.Letters) {
                foreach ($let in @(($info.Letters -split '[,; ]+') | Where-Object { $_ })) {
                    $tagsHtml += ('<span class="tag">{0}</span>' -f (Escape-HtmlText $let))
                }
            }
            $sub = ('{0:N1} {1}' -f $info.SizeGB, (L 'ГБ' 'GB'))
            [void]$sb.AppendLine(('<div class="chip"><div class="chip-top"><b>Disk {0}</b><span>{1}</span></div><div class="chip-name">{2}</div><div class="chip-sub">{3}</div></div>' -f $info.Number, $tagsHtml, (Escape-HtmlText $info.Model), (Escape-HtmlText $sub)))
            $diskChips++
        }
    }
    if ($diskChips -eq 0) {
        [void]$sb.AppendLine(('<p style="color:#8b98a5;margin:0">{0}</p>' -f (Escape-HtmlText (L 'Карта дисков пуста.' 'Disk map is empty.'))))
    }
    $htmlDisks = @()
    if ($null -ne $inv.Disks) { $htmlDisks = $inv.Disks }
    if ($htmlDisks.Count -gt 0) {
        [void]$sb.AppendLine('<table class="kv" style="margin-top:12px">')
        foreach ($d in $htmlDisks) {
            $health = switch ($d.Health) {
                'Healthy'   { L 'норма' 'healthy' }
                'Warning'   { L 'предупреждение' 'warning' }
                'Unhealthy' { L 'неисправен' 'unhealthy' }
                default     { $d.Health }
            }
            $extra = @()
            if ($null -ne $d.Temp) { $extra += ('{0} {1}°C' -f (L 'темп.' 'temp'), $d.Temp) }
            if ($null -ne $d.Wear) { $extra += ('{0} {1}%' -f (L 'износ' 'wear'), $d.Wear) }
            $tail = ''
            if ($extra.Count -gt 0) { $tail = ' · ' + ($extra -join ' · ') }
            [void]$sb.AppendLine(('<tr><th>{0}</th><td>{1} · {2}{3}</td></tr>' -f (Escape-HtmlText $d.Name), (Escape-HtmlText $health), ('{0:N1} {1}' -f $d.SizeGB, (L 'ГБ' 'GB')), (Escape-HtmlText $tail)))
        }
        [void]$sb.AppendLine('</table>')
    }
    [void]$sb.AppendLine('</div></div></div>')

    [void]$sb.AppendLine(('<div class="panel" id="bat" style="margin-bottom:18px"><h3>{0}</h3>' -f (Escape-HtmlText (L 'Батарея' 'Battery'))))
    if ($inv.Plan) {
        [void]$sb.AppendLine(('<p style="color:#94a3b8;margin:0 0 10px">{0}: {1}</p>' -f (Escape-HtmlText (L 'План питания' 'Power plan')), (Escape-HtmlText $inv.Plan)))
    }
    $htmlBats = @()
    if ($null -ne $inv.Battery) { $htmlBats = $inv.Battery }
    if ($htmlBats.Count -eq 0) {
        [void]$sb.AppendLine(('<p style="color:#8b98a5;margin:0">{0}</p>' -f (Escape-HtmlText (L 'Батарея не обнаружена (настольный ПК).' 'No battery found (desktop PC).'))))
    } else {
        foreach ($b in $htmlBats) {
            [void]$sb.AppendLine('<table class="kv">')
            [void]$sb.AppendLine(('<tr><th>{0}</th><td>{1}{2}</td></tr>' -f (Escape-HtmlText (L 'Имя' 'Name')), (Escape-HtmlText $b.Name), $(if ($b.Mfr) { ' · ' + (Escape-HtmlText $b.Mfr) } else { '' })))
            if ($null -ne $b.Charge) {
                $cc = '#22c55e'; if ($b.Charge -le 20) { $cc = '#ef4444' } elseif ($b.Charge -le 40) { $cc = '#f59e0b' }
                [void]$sb.AppendLine(('<tr><th>{0}</th><td>{1}%<div class="bar"><i style="width:{1}%;background:{2}"></i></div></td></tr>' -f (Escape-HtmlText (L 'Текущий заряд' 'Charge now')), $b.Charge, $cc))
            }
            if ($null -ne $b.Health) {
                $hc = '#22c55e'; if ($b.Health -lt 60) { $hc = '#ef4444' } elseif ($b.Health -lt 80) { $hc = '#f59e0b' }
                [void]$sb.AppendLine(('<tr><th>{0}</th><td>{1}%<div class="bar"><i style="width:{1}%;background:{2}"></i></div></td></tr>' -f (Escape-HtmlText (L 'Здоровье АКБ' 'Battery health')), $b.Health, $hc))
            }
            if ($null -ne $b.Cycles) {
                [void]$sb.AppendLine(('<tr><th>{0}</th><td>{1}</td></tr>' -f (Escape-HtmlText (L 'Циклы зарядки' 'Charge cycles')), $b.Cycles))
            }
            [void]$sb.AppendLine('</table>')
        }
    }
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<div class="grid">')
    [void]$sb.AppendLine(('<div class="panel"><h3>{0}</h3><div class="score" style="--sc:{1};--p:{2}"><div class="score-ring"><span>{2}</span></div><div><div class="k">{3}</div><p>{4}</p></div></div></div>' -f (Escape-HtmlText (L 'Индекс проблемности' 'Problem score')), $scoreColor, $score, (Escape-HtmlText $scoreLabel), (Escape-HtmlText (L '0 — чисто, 100 — много критичных фактов за период.' '0 is clean, 100 means many critical facts in the period.'))))
    [void]$sb.AppendLine(('<div class="panel"><h3>{0}</h3>{1}' -f (Escape-HtmlText (L 'Из чего складывается отчёт' 'What the report is made of')), (New-SvgDonut -Groups $kindGroups)))
    if ($kindGroups.Count -gt 0) {
        [void]$sb.Append('<div class="legend">')
        foreach ($g in $kindGroups) {
            [void]$sb.Append(('<span><i class="dot" style="background:{0}"></i>{1} ×{2}</span>' -f (Get-FindingKindColor $g.Name), (Escape-HtmlText (Get-FindingKindLabel $g.Name)), $g.Count))
        }
        [void]$sb.Append('</div>')
    }
    [void]$sb.AppendLine('</div></div>')

    [void]$sb.AppendLine('<div class="grid">')
    [void]$sb.AppendLine(('<div class="panel"><h3>{0}</h3>{1}</div>' -f (Escape-HtmlText $barTitle), (New-SvgBars -Labels $barLabels -Values $barValues -Colors $barColors)))
    if ($kindGroups.Count -gt 0) {
        [void]$sb.AppendLine(('<div class="panel"><h3>{0}</h3>{1}</div>' -f (Escape-HtmlText (L 'Топ типов' 'Top types')), (New-SvgHBars -Labels $kindLabels -Values $kindValues -Colors $kindColors)))
    } else {
        [void]$sb.AppendLine(('<div class="panel"><h3>{0}</h3><p style="color:#8b98a5">{1}</p></div>' -f (Escape-HtmlText (L 'Топ типов' 'Top types')), (Escape-HtmlText (L 'Критических типов нет.' 'No critical types.'))))
    }
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<div class="grid">')
    [void]$sb.AppendLine(('<div class="panel" id="freq"><h3>{0}</h3>' -f (Escape-HtmlText (L 'Частота и вес' 'Frequency and weight'))))
    $freqStats = @(Get-FindingStats | Select-Object -First 8)
    if ($freqStats.Count -eq 0) {
        [void]$sb.AppendLine(('<p style="color:#8b98a5">{0}</p>' -f (Escape-HtmlText (L 'Аппаратных фактов нет.' 'No hardware findings.'))))
    } else {
        [void]$sb.AppendLine('<table class="kv">')
        foreach ($s in $freqStats) {
            $range = ''
            if ($s.First -and $s.Last) {
                if ($s.Count -eq 1) { $range = $s.First.ToString('dd.MM HH:mm') }
                else { $range = ('{0:dd.MM HH:mm} → {1:dd.MM HH:mm}' -f $s.First, $s.Last) }
            }
            $title = $s.Title
            if (-not $title) { $title = Get-FindingKindLabel $s.Kind }
            [void]$sb.AppendLine(('<tr><th>{0}</th><td>{1}× · {2} · {3}</td></tr>' -f (Escape-HtmlText $title), $s.Count, (Escape-HtmlText (Get-WeightLabel $s.Weight)), (Escape-HtmlText $range)))
        }
        [void]$sb.AppendLine('</table>')
    }
    if ($Script:SoftCrashHidden -gt 0) {
        [void]$sb.AppendLine(('<p style="color:#94a3b8;margin:12px 0 0">{0}: {1}</p>' -f (Escape-HtmlText (L 'Скрыто крашей игр/браузеров' 'Hidden game/browser crashes')), $Script:SoftCrashHidden))
    }
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine(('<div class="panel" id="compare"><h3>{0}</h3>' -f (Escape-HtmlText (L 'Сравнение с прошлым отчётом' 'Comparison with previous report'))))
    $cmp = @()
    if ($null -ne $Script:CompareLines) {
        foreach ($c in $Script:CompareLines) { $cmp += $c }
    }
    if ($cmp.Count -eq 0) {
        [void]$sb.AppendLine(('<p style="color:#8b98a5">{0}</p>' -f (Escape-HtmlText (L 'Нет данных для сравнения.' 'No comparison data.'))))
    } else {
        foreach ($c in $cmp) {
            [void]$sb.AppendLine(('<p style="margin:6px 0">{0}</p>' -f (Escape-HtmlText $c.Text)))
        }
    }
    if ($Script:LastUpdateInfo -and $Script:LastUpdateInfo.Date) {
        [void]$sb.AppendLine(('<p style="color:#94a3b8;margin:12px 0 0">{0}: {1:dd.MM.yyyy HH:mm}</p>' -f (Escape-HtmlText (L 'Последнее обновление Windows' 'Last Windows update')), $Script:LastUpdateInfo.Date))
    }
    [void]$sb.AppendLine('</div></div>')

    $recent = @($allFindings | Where-Object { Test-IsHardwareFinding $_.Kind } | Sort-Object Time -Descending | Select-Object -First 16)
    [void]$sb.AppendLine(('<div class="panel" id="timeline"><h3>{0}</h3><ul class="timeline">' -f (Escape-HtmlText (L 'Лента событий' 'Event timeline'))))
    if ($recent.Count -eq 0) {
        [void]$sb.AppendLine(('<li><span class="t"></span><span></span><div>{0}</div></li>' -f (Escape-HtmlText (L 'За период пусто — это хорошо.' 'Nothing in this period — that is good.'))))
    } else {
        foreach ($f in $recent) {
            $col = Get-FindingKindColor $f.Kind
            $when = ''
            if ($f.Time) { $when = ([datetime]$f.Time).ToString('dd.MM.yyyy HH:mm') }
            $detail = $f.Title
            if ($f.Detail) { $detail = $f.Title + ' — ' + $f.Detail }
            [void]$sb.AppendLine(('<li><span class="t">{0}</span><span class="mark" style="background:{1}"></span><div>{2}</div></li>' -f (Escape-HtmlText $when), $col, (Escape-HtmlText $detail)))
        }
    }
    [void]$sb.AppendLine('</ul></div>')
    [void]$sb.AppendLine('</section>')

    [void]$sb.AppendLine('<section id="tab-log" class="hidden">')
    [void]$sb.AppendLine(('<input class="search" id="logFilter" placeholder="{0}"/>' -f (Escape-HtmlText (L 'Поиск по логу…' 'Search the log…'))))
    [void]$sb.AppendLine('<div class="log" id="logBox">')
    foreach ($row in $Script:ReportHtml) {
        $hex = '#cbd5e1'
        if ($colorMap.ContainsKey($row.Color)) { $hex = $colorMap[$row.Color] }
        [void]$sb.AppendLine(('<div class="line" style="color:{0}">{1}</div>' -f $hex, (Escape-HtmlText $row.Text)))
    }
    [void]$sb.AppendLine('</div></section></main>')
    [void]$sb.AppendLine(('<footer>{0} · {1}</footer>' -f (Escape-HtmlText $Script:HtmlPath), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    [void]$sb.AppendLine(@'
<script>
(function(){
  var buttons=document.querySelectorAll("nav button");
  var q=document.getElementById("logFilter");
  function show(id){
    document.getElementById("tab-dash").classList.toggle("hidden", id!=="dash");
    document.getElementById("tab-log").classList.toggle("hidden", id!=="log");
    buttons.forEach(function(b){b.classList.toggle("active", b.getAttribute("data-tab")===id);});
  }
  function applyFilter(raw){
    var s=(raw||"").trim();
    if(q) q.value=s.indexOf("|")>=0 ? s.split("|")[0] : s;
    var terms=s.toLowerCase().split("|").map(function(x){return x.trim();}).filter(Boolean);
    document.querySelectorAll("#logBox .line").forEach(function(el){
      var t=el.textContent.toLowerCase();
      var ok=!terms.length;
      for(var i=0;i<terms.length && !ok;i++){ if(t.indexOf(terms[i])>=0) ok=true; }
      el.style.display=ok?"":"none";
    });
  }
  buttons.forEach(function(b){b.addEventListener("click", function(){show(b.getAttribute("data-tab"));});});
  if(q){ q.addEventListener("input", function(){ applyFilter(q.value); }); }
  document.querySelectorAll(".card.click").forEach(function(card){
    card.addEventListener("click", function(){
      var n=parseInt(card.getAttribute("data-count")||"0",10);
      if(!n) return;
      show("log");
      applyFilter(card.getAttribute("data-filter")||"");
      var box=document.getElementById("logBox");
      if(box) box.scrollTop=0;
    });
  });
})();
</script></body></html>
'@)

    try {
        [System.IO.File]::WriteAllText($Script:HtmlPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Host ((L 'Не удалось сохранить HTML: ' 'Could not save HTML: ') + $_.Exception.Message) -ForegroundColor Red
    }
}

function Save-TextReport {
    try {
        [System.IO.File]::WriteAllText($Script:ReportPath, $Script:Report.ToString(), [System.Text.UTF8Encoding]::new($true))
    } catch {
        Write-Host ((L 'Не удалось сохранить отчёт: ' 'Could not save the report: ') + $_.Exception.Message) -ForegroundColor Red
    }
}

function Get-ThermalZoneLabel {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return (L 'Системная зона ACPI (плата / область CPU)' 'ACPI system zone (board / CPU area)')
    }
    $n = $Name.ToUpperInvariant()
    if ($n -match 'GPU|GFX|VID') {
        return (L 'Зона видеокарты (ACPI)' 'GPU ACPI zone')
    }
    if ($n -match 'CPU|PROC|CORE|THM0|THRM') {
        return (L 'Зона процессора (ACPI)' 'CPU ACPI zone')
    }
    if ($n -match 'TZ0|THERMALZONE') {
        return (L 'Системная зона ACPI (плата / чипсет / область CPU, не GPU и не SSD)' 'ACPI system zone (board / chipset / CPU area — not GPU or SSD)')
    }
    return (L ('Системная термозона ACPI ({0})' -f $Name) ('ACPI thermal zone ({0})' -f $Name))
}

function ConvertTo-CelsiusFromAcpi {
    param($Value, $HighPrecision = $null)
    if ($null -ne $HighPrecision) {
        $hp = [double]$HighPrecision
        if ($hp -gt 200) { return [math]::Round(($hp / 10.0) - 273.15, 1) }
    }
    if ($null -eq $Value) { return $null }
    $v = [double]$Value
    if ($v -le 0) { return $null }
    if ($v -gt 400) { return [math]::Round(($v / 10.0) - 273.15, 1) } # tenths of Kelvin
    if ($v -gt 200) { return [math]::Round($v - 273.15, 1) }          # Kelvin
    return [math]::Round($v, 1)                                      # already Celsius
}

function Get-AtaSmartMap {
    $map = @{}
    try {
        $rows = @(Get-CimInstance -Namespace root/wmi -ClassName MSStorageDriver_FailurePredictData -ErrorAction Stop)
        foreach ($row in $rows) {
            $bytes = $row.VendorSpecific
            if (-not $bytes -or $bytes.Length -lt 14) { continue }
            $attrs = @{}
            for ($i = 2; $i -le 362 -and ($i + 11) -lt $bytes.Length; $i += 12) {
                $id = [int]$bytes[$i]
                if ($id -eq 0) { continue }
                $raw = [int64]$bytes[$i + 5] + ([int64]$bytes[$i + 6] -shl 8) + ([int64]$bytes[$i + 7] -shl 16) + ([int64]$bytes[$i + 8] -shl 24)
                $attrs[$id] = @{
                    Id      = $id
                    Current = [int]$bytes[$i + 3]
                    Worst   = [int]$bytes[$i + 4]
                    Raw     = $raw
                }
            }
            $known = @(5, 9, 10, 12, 184, 187, 188, 190, 194, 197, 198, 199, 173, 202, 231, 233) | Where-Object { $attrs.ContainsKey($_) }
            if ($known.Count -lt 1) { continue }
            $map[$row.InstanceName] = $attrs
        }
    } catch {}
    return $map
}

function Resolve-SmartInstance {
    param([string]$DiskName, $SmartMap)
    if (-not $SmartMap -or $SmartMap.Count -eq 0 -or [string]::IsNullOrWhiteSpace($DiskName)) { return $null }
    $tokens = @($DiskName -split '\s+' | Where-Object { $_.Length -ge 4 })
    foreach ($key in $SmartMap.Keys) {
        $hit = $false
        foreach ($t in $tokens) {
            if ($key -like "*$t*") { $hit = $true; break }
        }
        if ($hit) { return $SmartMap[$key] }
    }
    return $null
}

function Format-SmartAttrLine {
    param($Attrs)
    if (-not $Attrs) { return $null }
    $parts = New-Object System.Collections.Generic.List[string]
    $labels = @{
        5   = @{ Ru = 'переназначено'; En = 'reallocated' }
        9   = @{ Ru = 'моточасы'; En = 'power-on hours' }
        10  = @{ Ru = 'повтор раскрутки'; En = 'spin retries' }
        12  = @{ Ru = 'циклов включения'; En = 'power cycles' }
        187 = @{ Ru = 'неисправимых'; En = 'uncorrectable' }
        188 = @{ Ru = 'таймауты'; En = 'timeouts' }
        194 = @{ Ru = 'темп. SMART'; En = 'SMART temp' }
        190 = @{ Ru = 'темп. SMART'; En = 'SMART temp' }
        197 = @{ Ru = 'нестабильных'; En = 'pending sectors' }
        198 = @{ Ru = 'офлайн-сбои'; En = 'offline uncorrectable' }
        199 = @{ Ru = 'ошибки CRC'; En = 'CRC errors' }
        173 = @{ Ru = 'износ SSD'; En = 'SSD wear' }
        202 = @{ Ru = 'остаток жизни %'; En = 'life left %' }
        231 = @{ Ru = 'остаток жизни %'; En = 'life left %' }
        233 = @{ Ru = 'износ носителя'; En = 'media wear' }
    }
    foreach ($id in @(5, 197, 198, 187, 188, 199, 9, 12, 173, 202, 231, 194, 190)) {
        if (-not $Attrs.ContainsKey($id)) { continue }
        $lab = $labels[$id]
        [void]$parts.Add(('{0}={1}' -f (L $lab.Ru $lab.En), $Attrs[$id].Raw))
    }
    if ($parts.Count -eq 0) { return $null }
    return ($parts -join ' | ')
}

# ---------------------------------------------------------------------------
# Разделы диагностики
# ---------------------------------------------------------------------------
function Show-SystemInfo {
    Write-Section (L 'Сведения о системе' 'System information')
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

        Write-ReportLine ("  {0}:     {1}" -f (L 'Компьютер' 'Computer'), $cs.Name)
        Write-ReportLine ("  {0}:            {1} ({2})" -f (L 'ОС' 'OS'), $os.Caption, $os.OSArchitecture)
        Write-ReportLine ("  {0}: {1}.{2}" -f (L 'Версия / сборка' 'Version / build'), $os.Version, $os.BuildNumber)
        Write-ReportLine ("  {0}: {1} | {2}: {3}" -f (L 'Производитель' 'Manufacturer'), $cs.Manufacturer, (L 'Модель' 'Model'), $cs.Model)
        if ($cpu) {
            $cores = $cpu.NumberOfCores
            $logical = $cpu.NumberOfLogicalProcessors
            Write-ReportLine ("  {0}:     {1} ({2} {3}, {4} {5})" -f (L 'Процессор' 'CPU'), $cpu.Name.Trim(), $cores, (L 'ядер' 'cores'), $logical, (L 'потоков' 'threads'))
        }
        Write-ReportLine ("  {0}: {1:N1} {2}" -f (L 'ОЗУ (установлено)' 'RAM installed'), ($cs.TotalPhysicalMemory / 1GB), (L 'ГБ' 'GB'))
        # FreePhysicalMemory — в КБ; деление на 1MB даёт ГБ
        $freeGb = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        Write-ReportLine ("  {0}:  {1:N1} {2}" -f (L 'ОЗУ свободно' 'RAM free'), $freeGb, (L 'ГБ' 'GB'))
        if ($bios) {
            $biosDate = ConvertFrom-CimDate $bios.ReleaseDate
            if ($biosDate) {
                Write-ReportLine ("  BIOS:          {0} | {1} | {2}: {3:dd.MM.yyyy}" -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion, (L 'дата' 'date'), $biosDate)
            } else {
                Write-ReportLine ("  BIOS:          {0} | {1}" -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion)
            }
        }
        $boot = $os.LastBootUpTime
        if ($boot -is [string]) {
            try { $boot = [Management.ManagementDateTimeConverter]::ToDateTime($boot) } catch {}
        }
        if ($boot -is [datetime]) {
            Write-ReportLine ("  {0}: {1:N1} {2}" -f (L 'Время работы (uptime)' 'Uptime'), ((Get-Date) - $boot).TotalHours, (L 'ч' 'h'))
            Write-ReportLine ("  {0}: {1}" -f (L 'Последняя загрузка' 'Last boot'), $boot)
        }
    } catch {
        Write-ReportLine ("  {0}: {1}" -f (L 'Не удалось получить сведения о системе' 'Could not read system information'), $_.Exception.Message) DarkYellow
    }
}

function Show-DiskHealth {
    Write-Section (L 'Диски и тома' 'Disks and volumes')
    try {
        Get-CimInstance Win32_DiskDrive -ErrorAction Stop | ForEach-Object {
            if (-not $_.Size -or $_.Size -lt 8MB) { return }
            $sizeGb = [math]::Round($_.Size / 1GB, 1)
            $status = $_.Status
            $color = if ($status -ne 'OK') { [ConsoleColor]::Red } else { [ConsoleColor]::Gray }
            Write-ReportLine ("  {0}: {1} | {2} {3} | {4}: {5} | {6}: {7}" -f (L 'Диск' 'Disk'), $_.Model, $sizeGb, (L 'ГБ' 'GB'), (L 'Интерфейс' 'Interface'), $_.InterfaceType, (L 'Состояние' 'Status'), $status) $color
            if ($status -ne 'OK') {
                Write-ReportLine ('    ' + (L 'ПОЯСНЕНИЕ: Состояние диска не OK — возможны сбои накопителя. Сделайте бэкап.' 'NOTE: Disk status is not OK — the drive may be failing. Back up now.')) Red
                Add-Finding -Kind 'DiskHealth' -Time (Get-Date) -Title ("{0}: {1}" -f (L 'Диск не OK' 'Disk not OK'), $_.Model) -Detail $status -Tags @('disk')
                Mark-Issue -Key 'DiskHealth' -Critical
            }
        }
    } catch {
        Write-ReportLine ('  ' + (L 'Не удалось опросить Win32_DiskDrive.' 'Could not query Win32_DiskDrive.')) DarkYellow
    }

    try {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | ForEach-Object {
            $free = [math]::Round($_.FreeSpace / 1GB, 1)
            $total = [math]::Round($_.Size / 1GB, 1)
            $pct = if ($_.Size -gt 0) { [math]::Round(100 * $_.FreeSpace / $_.Size, 0) } else { 0 }
            $color = if ($pct -lt 5) { [ConsoleColor]::Red } elseif ($pct -lt 10) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Gray }
            Write-ReportLine ("  {0} {1} [{2}]: {3} {4} {5} {6} {7} ({8}%)" -f (L 'Том' 'Volume'), $_.DeviceID, $_.FileSystem, (L 'свободно' 'free'), $free, (L 'из' 'of'), $total, (L 'ГБ' 'GB'), $pct) $color
            if ($pct -lt 5) {
                Write-ReportLine ('    ' + (L 'ПОЯСНЕНИЕ: Критически мало места — возможны сбои подкачки и дампов.' 'NOTE: Critically low space — paging and dumps may fail.')) Red
                Add-Finding -Kind 'LowDisk' -Time (Get-Date) -Title ("{0} {1}" -f (L 'Мало места на' 'Low space on'), $_.DeviceID) -Tags @('disk')
                Mark-Issue -Key 'LowDisk'
            }
        }
    } catch {}

    try {
        $pd = @(Get-PhysicalDisk -ErrorAction Stop)
        $smartMap = Get-AtaSmartMap
        $showedNvmeLimit = $false
        Write-ReportLine ('  ' + (L 'Здоровье накопителей:' 'Drive health:')) DarkCyan
        foreach ($d in $pd) {
            $h = "$($d.HealthStatus)"
            $bus = "$($d.BusType)"
            $media = "$($d.MediaType)"
            $color = switch ($h) {
                'Healthy'   { [ConsoleColor]::Green }
                'Warning'   { [ConsoleColor]::Yellow }
                'Unhealthy' { [ConsoleColor]::Red }
                default     { [ConsoleColor]::Gray }
            }
            $healthText = switch ($h) {
                'Healthy'   { L 'норма' 'healthy' }
                'Warning'   { L 'предупреждение' 'warning' }
                'Unhealthy' { L 'неисправен' 'unhealthy' }
                default     { $h }
            }
            Write-ReportLine ("  {0} ({1} {2}, {3:N1} {4})" -f $d.FriendlyName, $bus, $media, ($d.Size / 1GB), (L 'ГБ' 'GB')) $color
            Write-ReportLine ("    {0}: {1}" -f (L 'Оценка Windows' 'Windows health'), $healthText) $color

            $c = $null
            try { $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
            $parts = New-Object System.Collections.Generic.List[string]
            if ($c -and $null -ne $c.Temperature) {
                [void]$parts.Add(('{0} {1}°C' -f (L 'температура диска' 'drive temperature'), $c.Temperature))
            }
            if ($c -and $null -ne $c.Wear) {
                $left = [math]::Max(0, 100 - [int]$c.Wear)
                [void]$parts.Add(('{0} {1}% ({2} ~{3}%)' -f (L 'износ' 'wear'), $c.Wear, (L 'остаток' 'remaining'), $left))
            }
            if ($c -and $null -ne $c.PowerOnHours) {
                [void]$parts.Add(('{0} {1}' -f (L 'моточасы' 'power-on hours'), $c.PowerOnHours))
            }
            if ($c -and $null -ne $c.ReadErrorsTotal) {
                [void]$parts.Add(('{0} {1}' -f (L 'ошибки чтения' 'read errors'), $c.ReadErrorsTotal))
            }
            if ($c -and $null -ne $c.WriteErrorsTotal) {
                [void]$parts.Add(('{0} {1}' -f (L 'ошибки записи' 'write errors'), $c.WriteErrorsTotal))
            }
            if ($parts.Count -gt 0) {
                Write-ReportLine ('    ' + ($parts -join ' | ')) Gray
            }

            $ata = Resolve-SmartInstance -DiskName $d.FriendlyName -SmartMap $smartMap
            $ataLine = Format-SmartAttrLine -Attrs $ata
            if ($ataLine) {
                Write-ReportLine ("    SMART: {0}" -f $ataLine) Gray
            } elseif ($bus -eq 'NVMe') {
                $showedNvmeLimit = $true
            }

            if ($h -ne 'Healthy') {
                Write-ReportLine ('    ' + (L 'ПОЯСНЕНИЕ: Windows считает накопитель проблемным. Сделайте бэкап.' 'NOTE: Windows reports this drive as unhealthy. Back up now.')) Red
                Add-Finding -Kind 'DiskHealth' -Time (Get-Date) -Title ("{0}: {1}" -f $d.FriendlyName, $h) -Tags @('disk')
                Mark-Issue -Key 'PhysicalDisk' -Critical
            }
            $wearVal = $null
            if ($c) { $wearVal = $c.Wear }
            $tempVal = $null
            if ($c) { $tempVal = $c.Temperature }
            $badWear = ($null -ne $wearVal -and $wearVal -ge 80)
            $hot = ($null -ne $tempVal -and $tempVal -ge 70)
            $badSmart = $false
            if ($ata) {
                foreach ($id in @(5, 187, 197, 198)) {
                    if ($ata.ContainsKey($id) -and $ata[$id].Raw -gt 0) { $badSmart = $true }
                }
            }
            if ($badWear -or $hot -or $badSmart) {
                Write-ReportLine ('    ' + (L 'ПОЯСНЕНИЕ: температура, износ или SMART-атрибуты вне нормы.' 'NOTE: temperature, wear, or SMART attributes are out of range.')) Red
                Add-Finding -Kind 'DiskHealth' -Time (Get-Date) -Title $d.FriendlyName -Tags @('disk')
                Mark-Issue -Key 'SMART' -Critical
            }
        }
        if ($showedNvmeLimit) {
            Write-ReportLine ('  ' + (L 'Полные атрибуты SMART для NVMe Windows не отдаёт (нет моточасов/секторов). Для них — утилита производителя или CrystalDiskInfo.' 'Windows does not expose full NVMe SMART (no hours/sector counts). Use the vendor tool or CrystalDiskInfo.')) DarkGray
        }
    } catch {
        Write-ReportLine ('  ' + (L 'Get-PhysicalDisk недоступен (нормально на старых редакциях Windows).' 'Get-PhysicalDisk is unavailable (normal on older Windows editions).')) DarkGray
    }
}

function Get-RamBrand {
    param($Module)
    $mfr = ''
    if ($Module.Manufacturer) { $mfr = ("$($Module.Manufacturer)").Trim() }
    $part = ''
    if ($Module.PartNumber) {
        $part = ("$($Module.PartNumber)") -replace '[^\x21-\x7E]', ''
        $part = ($part -replace '[<>]+', '').Trim()
        $part = ($part -replace '\s+', '').Trim()
        if ($part.Length -lt 6 -or $part -notmatch '[A-Za-z]' -or $part -notmatch '\d') { $part = '' }
    }

    $looksHex = $mfr -match '(?i)^0x[0-9a-f]+$' -or $mfr -match '^[0-9a-f]{4}$'
    $emptyId = $mfr -match '(?i)^0x0+$' -or $mfr -eq '0' -or $mfr -eq ''
    if ($mfr -and -not $looksHex -and -not $emptyId -and $mfr -notmatch '^[0-9]+$') {
        return @{ Brand = $mfr; Part = $part }
    }

    $p = $part.ToUpperInvariant()
    $guess = $null
    if ($p -match '^F[45]-|^F5[-_]') { $guess = 'G.Skill' }
    elseif ($p -match '^CM[KWDVTZ]|^CMH') { $guess = 'Corsair' }
    elseif ($p -match '^KF[BFN]|^HX[A-Z0-9]') { $guess = 'Kingston / Fury' }
    elseif ($p -match '^CT\d|^BLS|^BLMK|^MTC') { $guess = 'Crucial / Micron' }
    elseif ($p -match '^MT' -and $p.Length -gt 6) { $guess = 'Micron' }
    elseif ($p -match '^M3[289]|^K4A|^K4B') { $guess = 'Samsung' }
    elseif ($p -match '^HMA|^HMC|^HMS|^HMT') { $guess = 'SK Hynix' }
    elseif ($p -match '^AX4U|^AX5U|^AD4U|^AXER') { $guess = 'ADATA' }
    elseif ($p -match '^TF[F1]|T-FORCE|^TT') { $guess = 'TeamGroup' }
    elseif ($p -match '^PVB|^PVE|^PSD|^PST') { $guess = 'Patriot' }
    elseif ($p -match '^OL[O0Y]|^Vengeance') { $guess = 'Corsair' }
    elseif ($p -match '^JM|^JLD') { $guess = 'Kingston' }
    elseif ($p -match '^F4-|^F5-') { $guess = 'G.Skill' }

    return @{ Brand = $guess; Part = $part }
}

function Show-MemoryStatus {
    Write-Section (L 'Память (RAM)' 'Memory (RAM)')
    try {
        $rams = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $i = 0
        foreach ($r in $rams) {
            $i++
            $gb = [math]::Round($r.Capacity / 1GB, 1)
            $info = Get-RamBrand $r
            $bits = New-Object System.Collections.Generic.List[string]
            [void]$bits.Add(('{0} {1}' -f $gb, (L 'ГБ' 'GB')))
            if ($r.Speed) { [void]$bits.Add(('{0} {1}' -f $r.Speed, (L 'МГц' 'MHz'))) }
            if ($r.DeviceLocator) { [void]$bits.Add(('{0} {1}' -f (L 'слот' 'slot'), $r.DeviceLocator)) }
            if ($info.Brand) { [void]$bits.Add(('{0}: {1}' -f (L 'производитель' 'manufacturer'), $info.Brand)) }
            Write-ReportLine ("  {0} {1}: {2}" -f (L 'Модуль' 'Module'), $i, ($bits -join ' | '))
            if ($info.Part) {
                Write-ReportLine ("    {0}: {1}" -f (L 'Артикул модуля' 'Part number'), $info.Part) DarkGray
            }
        }
        if ($rams.Count -eq 0) { Write-ReportLine ('  ' + (L 'Модули RAM не обнаружены через WMI.' 'No RAM modules were found via WMI.')) DarkYellow }
    } catch {
        Write-ReportLine ('  ' + (L 'Не удалось прочитать сведения о RAM.' 'Could not read RAM information.')) DarkYellow
    }

    $memDiag = Find-CachedEvents -Provider 'Microsoft-Windows-MemoryDiagnostics-Results' -Max 5
    if ($memDiag.Count -gt 0) {
        foreach ($ev in $memDiag) {
            Write-ReportLine ("  {0}: {1} | {2}" -f (L 'Результат диагностики памяти' 'Memory diagnostics result'), $ev.TimeCreated, (Get-ShortMessage $ev 160)) Yellow
            Write-Explanation -Provider 'Microsoft-Windows-MemoryDiagnostics-Results' -EventId $ev.Id
            Add-Finding -Kind 'MemoryDiag' -Time $ev.TimeCreated -Title 'Memory Diagnostics' -Detail (Get-ShortMessage $ev 200) -Event $ev -Tags @('ram')
        }
    } else {
        Write-ReportLine ('  ' + (L 'Записей Memory Diagnostics за период нет.' 'No Memory Diagnostics records in this period.')) Green
    }
}

function Show-Temperatures {
    Write-Section (L 'Температуры' 'Temperatures')
    $any = $false
    $seen = New-Object System.Collections.Generic.HashSet[string]
    try {
        $zones = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
        foreach ($z in $zones) {
            $c = ConvertTo-CelsiusFromAcpi -Value $z.CurrentTemperature
            if ($null -eq $c -or $c -lt -20 -or $c -gt 150) { continue }
            $any = $true
            $color = if ($c -ge 90) { [ConsoleColor]::Red } elseif ($c -ge 80) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Gray }
            $label = Get-ThermalZoneLabel $z.InstanceName
            [void]$seen.Add(($label + '|' + [int]$c))
            Write-ReportLine ("  {0}: {1}°C" -f $label, $c) $color
            if ($c -ge 90) {
                Add-Finding -Kind 'Thermal' -Time (Get-Date) -Title ((L 'Перегрев' 'Overheating') + ": $c°C") -Tags @('thermal')
                Mark-Issue -Key 'Thermal' -Critical
            }
        }
    } catch {}

    try {
        $perf = @(Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop)
        foreach ($p in $perf) {
            $c = ConvertTo-CelsiusFromAcpi -Value $p.Temperature -HighPrecision $p.HighPrecisionTemperature
            if ($null -eq $c -or $c -lt -20 -or $c -gt 150) { continue }
            $label = Get-ThermalZoneLabel $p.Name
            $key = $label + '|' + [int]$c
            if ($seen.Contains($key)) { continue }
            $any = $true
            $color = if ($c -ge 90) { [ConsoleColor]::Red } elseif ($c -ge 80) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Gray }
            Write-ReportLine ("  {0}: {1}°C" -f $label, $c) $color
        }
    } catch {}

    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu -and $cpu.MaxClockSpeed -gt 0) {
            $cur = [int]$cpu.CurrentClockSpeed
            $max = [int]$cpu.MaxClockSpeed
            $pct = [int][math]::Round(100.0 * $cur / $max, 0)
            $color = [ConsoleColor]::Gray
            if ($pct -le 55 -and $cur -gt 0) { $color = [ConsoleColor]::Yellow }
            Write-ReportLine ("  {0}: {1} / {2} МГц ({3}%)" -f (L 'Частота CPU сейчас / база' 'CPU clock now / base'), $cur, $max, $pct) $color
            if ($pct -le 55 -and $cur -gt 0) {
                Write-ReportLine ('    ' + (L 'Частота заметно ниже базовой — возможен троттлинг, энергосбережение или перегрев.' 'Clock is well below base — possible throttling, power saving, or heat.')) Yellow
            }
        }
    } catch {}

    if ($any) {
        Write-ReportLine ('  ' + (L 'Это не температура SSD и не GPU: Windows отдаёт ACPI-зоны платы. Температуру дисков см. в разделе «Диски».' 'This is not SSD or GPU temperature: Windows exposes ACPI board zones. Drive temps are in the Disks section.')) DarkGray
    } else {
        Write-ReportLine ('  ' + (L 'Датчики температуры через WMI недоступны (часто на десктопах без ACPI thermal).' 'WMI temperature sensors are unavailable (common on desktops without ACPI thermal).')) DarkGray
    }
}

function Get-CimByNs {
    param([string]$ClassName)
    try { return @(Get-CimInstance -Namespace root/wmi -ClassName $ClassName -ErrorAction Stop) } catch { return @() }
}

function Show-BatteryPower {
    Write-Section (L 'Питание / батарея' 'Power / battery')
    try {
        $plan = Get-CimInstance -Namespace root/cimv2/power -ClassName Win32_PowerPlan -ErrorAction SilentlyContinue |
            Where-Object { $_.IsActive } | Select-Object -First 1
        if ($plan) {
            Write-ReportLine ("  {0}: {1}" -f (L 'Активный план питания' 'Active power plan'), $plan.ElementName)
        }
    } catch {}

    $winBat = @()
    try { $winBat = @(Get-CimInstance Win32_Battery -ErrorAction Stop) } catch {}
    $static = Get-CimByNs 'BatteryStaticData'
    $full = Get-CimByNs 'BatteryFullChargedCapacity'
    $cycles = Get-CimByNs 'BatteryCycleCount'
    $st = Get-CimByNs 'BatteryStatus'

    if ($winBat.Count -eq 0 -and $static.Count -eq 0 -and $st.Count -eq 0) {
        Write-ReportLine ('  ' + (L 'Батарея не обнаружена (настольный ПК или нет аккумулятора).' 'No battery found (desktop PC or no accumulator).')) DarkGray
        return
    }

    $count = [math]::Max($winBat.Count, [math]::Max($static.Count, $st.Count))
    if ($count -lt 1) { $count = 1 }
    for ($i = 0; $i -lt $count; $i++) {
        $name = (L 'Батарея' 'Battery')
        $chargePct = $null
        if ($i -lt $winBat.Count -and $winBat[$i].Name) { $name = $winBat[$i].Name }
        if ($i -lt $winBat.Count -and $null -ne $winBat[$i].EstimatedChargeRemaining) { $chargePct = $winBat[$i].EstimatedChargeRemaining }

        $design = $null
        $fullCap = $null
        $remain = $null
        $cycle = $null
        $volt = $null
        $mfr = $null
        if ($i -lt $static.Count) {
            if ($static[$i].DesignedCapacity) { $design = [double]$static[$i].DesignedCapacity }
            if ($static[$i].ManufactureName) { $mfr = $static[$i].ManufactureName }
            if ($static[$i].DeviceName) { $name = $static[$i].DeviceName }
        }
        if ($i -lt $full.Count -and $full[$i].FullChargedCapacity) { $fullCap = [double]$full[$i].FullChargedCapacity }
        if ($i -lt $cycles.Count -and $null -ne $cycles[$i].CycleCount) { $cycle = [int]$cycles[$i].CycleCount }
        if ($i -lt $st.Count) {
            if ($st[$i].RemainingCapacity) { $remain = [double]$st[$i].RemainingCapacity }
            if ($st[$i].Voltage) { $volt = [math]::Round($st[$i].Voltage / 1000.0, 2) }
        }
        if ($null -eq $design -and $i -lt $winBat.Count -and $winBat[$i].DesignCapacity) { $design = [double]$winBat[$i].DesignCapacity }
        if ($null -eq $fullCap -and $i -lt $winBat.Count -and $winBat[$i].FullChargeCapacity) { $fullCap = [double]$winBat[$i].FullChargeCapacity }

        Write-ReportLine ("  {0}{1}" -f $name, $(if ($mfr) { " ($mfr)" } else { '' }))
        if ($null -ne $chargePct) {
            Write-ReportLine ("    {0}: {1}%" -f (L 'Текущий заряд' 'Charge'), $chargePct)
        } elseif ($remain -and $fullCap -and $fullCap -gt 0) {
            Write-ReportLine ("    {0}: {1}%" -f (L 'Текущий заряд' 'Charge'), [math]::Round(100.0 * $remain / $fullCap, 0))
        }
        if ($design) { Write-ReportLine ("    {0}: {1} {2}" -f (L 'Проектная ёмкость' 'Design capacity'), [int]$design, 'mWh') }
        if ($fullCap) { Write-ReportLine ("    {0}: {1} {2}" -f (L 'Фактическая ёмкость (полная зарядка)' 'Full-charge capacity'), [int]$fullCap, 'mWh') }
        if ($remain) { Write-ReportLine ("    {0}: {1} {2}" -f (L 'Остаток сейчас' 'Remaining now'), [int]$remain, 'mWh') }
        if ($design -and $fullCap -and $design -gt 0) {
            $wearPct = [math]::Round(100.0 * $fullCap / $design, 0)
            $lost = [math]::Max(0, 100 - [int]$wearPct)
            $color = if ($wearPct -lt 60) { [ConsoleColor]::Red } elseif ($wearPct -lt 80) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green }
            Write-ReportLine ("    {0}: {1}% ({2} {3}%)" -f (L 'Износ / остаток здоровья' 'Wear / health left'), $lost, (L 'ёмкость от новой' 'capacity vs new'), $wearPct) $color
            if ($wearPct -lt 70) {
                Add-Finding -Kind 'Battery' -Time (Get-Date) -Title ((L 'Износ АКБ' 'Battery wear') + " $lost%") -Tags @('power')
                Mark-Issue -Key 'Battery'
            }
        }
        if ($null -ne $cycle) {
            $ccolor = if ($cycle -ge 800) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Gray }
            Write-ReportLine ("    {0}: {1}" -f (L 'Циклы зарядки' 'Charge cycles'), $cycle) $ccolor
        }
        if ($volt) { Write-ReportLine ("    {0}: {1} {2}" -f (L 'Напряжение' 'Voltage'), $volt, 'V') }

        if ($i -lt $winBat.Count) {
            $code = [int]$winBat[$i].BatteryStatus
            $statusMap = @{
                1 = (L 'разряд' 'discharging')
                2 = (L 'от сети, заряжена' 'AC, charged')
                3 = (L 'полная зарядка' 'fully charged')
                4 = (L 'низкий заряд' 'low')
                5 = (L 'критично низкий' 'critical')
                6 = (L 'заряжается' 'charging')
                7 = (L 'заряжается (высокий)' 'charging high')
                8 = (L 'заряжается (низкий)' 'charging low')
                9 = (L 'заряжается (критичный)' 'charging critical')
                10 = (L 'не определено' 'undefined')
                11 = (L 'частично заряжена' 'partially charged')
            }
            $stText = if ($statusMap.ContainsKey($code)) { $statusMap[$code] } else { "$code" }
            Write-ReportLine ("    {0}: {1}" -f (L 'Состояние' 'Status'), $stText)
        }
    }

    $kp172 = Find-CachedEvents -Provider 'Microsoft-Windows-Kernel-Power' -Id 172 -Max 5
    foreach ($ev in $kp172) {
        Write-ReportLine ("  {0}: {1}" -f (L 'Kernel-Power 172' 'Kernel-Power 172'), $ev.TimeCreated) Yellow
        Write-Explanation -Provider 'Microsoft-Windows-Kernel-Power' -EventId 172
        Add-Finding -Kind 'Battery' -Time $ev.TimeCreated -Title 'Kernel-Power 172' -Event $ev -Tags @('power')
    }
}

function Show-Whea {
    Write-Section ("{0} WHEA ({1} {2} {3})" -f (L 'Аппаратные ошибки' 'Hardware errors'), (L 'за' 'last'), $Script:DaysBack, (L 'дн.' 'days'))
    $whea = Find-CachedEvents -Provider 'Microsoft-Windows-WHEA-Logger' -Max 30

    if ($whea.Count -eq 0) {
        Write-ReportLine ('  ' + (L 'Критических записей WHEA за период не найдено.' 'No critical WHEA records in this period.')) Green
        return
    }

    foreach ($ev in ($whea | Sort-Object TimeCreated -Descending)) {
        $comp = Resolve-WheaComponent -Event $ev
        Write-ReportLine ("  → WHEA Event ID {0} | {1} | {2}: {3}" -f $ev.Id, $ev.TimeCreated, (L 'Устройство' 'Device'), $comp) Yellow
        Write-Explanation -Provider 'Microsoft-Windows-WHEA-Logger' -EventId $ev.Id
        Add-Finding -Kind 'WHEA' -Time $ev.TimeCreated -Title ("WHEA ID {0}: {1}" -f $ev.Id, $comp) -Detail (Get-ShortMessage $ev 200) -Event $ev -Tags @('whea', $comp)
        [void](Show-EventWindow -CenterTime $ev.TimeCreated -AnchorLabel ("WHEA ID {0} / {1}" -f $ev.Id, $comp) -Minutes $Script:WindowMinutes)
        Write-ReportLine ''
    }
}

function Show-KernelPower {
    Write-Section ("{0} Kernel-Power 41 / 6008 ({1} {2} {3})" -f (L 'Внезапные перезагрузки' 'Unexpected reboots'), (L 'за' 'last'), $Script:DaysBack, (L 'дн.' 'days'))
    $kp = Find-CachedEvents -Provider 'Microsoft-Windows-Kernel-Power' -Id 41 -Max 20
    $e6008 = Find-CachedEvents -Provider 'EventLog' -Id 6008 -Max 20

    if ($kp.Count -eq 0 -and $e6008.Count -eq 0) {
        Write-ReportLine ('  ' + (L 'Неожиданных отключений Kernel-Power 41 и EventLog 6008 не обнаружено.' 'No unexpected Kernel-Power 41 or EventLog 6008 shutdowns found.')) Green
        return
    }

    if ($kp.Count -gt 0) {
        Write-ReportLine ("  {0} Kernel-Power 41: {1}" -f (L 'Найдено событий' 'Events found'), $kp.Count) Red
        foreach ($ev in ($kp | Sort-Object TimeCreated -Descending)) {
            Write-ReportLine ("  → {0} (Kernel-Power 41): {1}" -f (L 'КРИТИЧЕСКАЯ ПЕРЕЗАГРУЗКА' 'CRITICAL REBOOT'), $ev.TimeCreated) Red
            $data = Get-EventDataMap $ev
            $bc = $null
            if ($data.ContainsKey('BugcheckCode')) { $bc = $data['BugcheckCode'] }
            $info = Get-BugCheckInfo -Code $bc -Text $ev.Message
            if ($info.Code) {
                Write-ReportLine ('    ' + (L 'В событии 41 указан код BugCheck — это был краш, а не просто отвал питания.' 'Event 41 contains a BugCheck code — this was a crash, not just power loss.')) Yellow
                Write-BugCheckDecode -Info $info
                Add-Finding -Kind 'BugCheck' -Time $ev.TimeCreated -Title $info.Name -Detail ("{0} {1}" -f $info.CodeHex, $info.Name) -Event $ev -Tags @('bsod', 'bsod-decode', $(if ($info.Likely) { $info.Likely } else { 'power' }))
            } else {
                $pbt = $null
                if ($data.ContainsKey('PowerButtonTimestamp')) { $pbt = $data['PowerButtonTimestamp'] }
                if ($pbt -and $pbt -ne '0') {
                    Write-ReportLine ('    ' + (L 'PowerButtonTimestamp заполнен — возможно, удерживали кнопку питания.' 'PowerButtonTimestamp is set — the power button may have been held.')) DarkYellow
                } else {
                    Write-ReportLine ('    ' + (L 'BugcheckCode = 0 — система обесточилась без записи STOP-кода (БП, питание, мгновенный завис).' 'BugcheckCode = 0 — power vanished without a STOP code (PSU, power, instant hang).')) DarkYellow
                }
            }
            Write-Explanation -Provider 'Microsoft-Windows-Kernel-Power' -EventId 41
            Add-Finding -Kind 'KernelPower' -Time $ev.TimeCreated -Title 'Kernel-Power 41' -Detail (L 'Внезапная перезагрузка без корректного завершения' 'Unexpected reboot without a clean shutdown') -Event $ev -Tags @('power')
            [void](Show-EventWindow -CenterTime $ev.TimeCreated -AnchorLabel (L 'Kernel-Power 41 (внезапная перезагрузка)' 'Kernel-Power 41 (unexpected reboot)') -Minutes $Script:WindowMinutes)
            Write-ReportLine ''
        }
    }

    if ($e6008.Count -gt 0) {
        Write-ReportLine ("  {0} EventLog 6008: {1}" -f (L 'Найдено событий' 'Events found'), $e6008.Count) Yellow
        foreach ($ev in ($e6008 | Sort-Object TimeCreated -Descending | Select-Object -First 8)) {
            Write-ReportLine ("  → {0} (6008): {1} | {2}" -f (L 'Неожиданное завершение' 'Unexpected shutdown'), $ev.TimeCreated, (Get-ShortMessage $ev 140)) Yellow
            Write-Explanation -Provider 'EventLog' -EventId 6008
            Add-Finding -Kind 'UnexpectedShutdown' -Time $ev.TimeCreated -Title 'EventLog 6008' -Detail (Get-ShortMessage $ev 180) -Event $ev -Tags @('power')
            [void](Show-EventWindow -CenterTime $ev.TimeCreated -AnchorLabel 'EventLog 6008' -Minutes $Script:WindowMinutes)
            Write-ReportLine ''
        }
    }
}

function Show-BugChecks {
    Write-Section ("{0} / BugCheck ({1} {2} {3})" -f (L 'Синие экраны' 'Blue screens'), (L 'за' 'last'), $Script:DaysBack, (L 'дн.' 'days'))
    $found = $false
    $werFiles = @(Get-WerBlueScreens)

    $wer = Find-CachedEvents -Provider 'Microsoft-Windows-WER-SystemErrorReporting' -Max 15
    foreach ($ev in ($wer | Sort-Object TimeCreated -Descending)) {
        $found = $true
        $msg = Get-ShortMessage $ev 220
        $nearWer = @($werFiles | Where-Object { [math]::Abs(($_.Time - $ev.TimeCreated).TotalMinutes) -lt 30 } | Select-Object -First 1)
        $module = $null
        if ($nearWer) { $module = $nearWer.Module }
        $info = Get-BugCheckInfo -Text ($ev.Message + ' ' + $msg) -ModuleHint $module
        if ($null -eq $info.Code -and $nearWer) { $info = Get-BugCheckInfo -Code $nearWer.Code -Text $nearWer.Text -ModuleHint $nearWer.Module }
        Write-ReportLine ("  → WER SystemErrorReporting ID {0} | {1}" -f $ev.Id, $ev.TimeCreated) Red
        Write-ReportLine ("    {0}: {1}" -f (L 'Сообщение' 'Message'), $msg) DarkGray
        Write-BugCheckDecode -Info $info
        Write-Explanation -Provider 'Microsoft-Windows-WER-SystemErrorReporting' -EventId $ev.Id
        $detail = if ($info.Code) { '{0} {1} {2}' -f $info.CodeHex, $info.Name, $info.Module } else { $msg }
        Add-Finding -Kind 'BugCheck' -Time $ev.TimeCreated -Title $(if ($info.Name) { $info.Name } else { 'BSOD / WER' }) -Detail $detail.Trim() -Event $ev -Tags @('bsod', $(if ($info.Code) { 'bsod-decode' } else { 'bsod' }), $(if ($info.Likely) { $info.Likely } else { 'bsod' }))
        [void](Show-EventWindow -CenterTime $ev.TimeCreated -AnchorLabel 'BSOD (WER SystemErrorReporting)' -Minutes $Script:WindowMinutes)
        Write-ReportLine ''
    }

    $bc = Find-CachedEvents -Provider 'BugCheck' -Max 10
    foreach ($ev in ($bc | Sort-Object TimeCreated -Descending)) {
        $found = $true
        $msg = Get-ShortMessage $ev 220
        $data = Get-EventDataMap $ev
        $codeHint = $null
        foreach ($k in @('BugcheckCode', 'BugCheckCode', 'StopCode')) {
            if ($data.ContainsKey($k)) { $codeHint = $data[$k]; break }
        }
        $info = Get-BugCheckInfo -Code $codeHint -Text ($ev.Message + ' ' + $msg)
        Write-ReportLine ("  → BugCheck ID {0} | {1}" -f $ev.Id, $ev.TimeCreated) Red
        Write-ReportLine ("    {0}: {1}" -f (L 'Сообщение' 'Message'), $msg) DarkGray
        Write-BugCheckDecode -Info $info
        Write-Explanation -Provider 'BugCheck' -EventId $ev.Id
        $detail = if ($info.Code) { '{0} {1} {2}' -f $info.CodeHex, $info.Name, $info.Module } else { $msg }
        Add-Finding -Kind 'BugCheck' -Time $ev.TimeCreated -Title $(if ($info.Name) { $info.Name } else { 'BugCheck' }) -Detail $detail.Trim() -Event $ev -Tags @('bsod', $(if ($info.Code) { 'bsod-decode' } else { 'bsod' }))
        [void](Show-EventWindow -CenterTime $ev.TimeCreated -AnchorLabel 'BugCheck / BSOD' -Minutes $Script:WindowMinutes)
        Write-ReportLine ''
    }

    if ($werFiles.Count -gt 0) {
        $found = $true
        Write-ReportLine ('  ' + (L 'Отчёты WER о синем экране:' 'WER blue-screen reports:')) Yellow
        foreach ($w in ($werFiles | Sort-Object Time -Descending | Select-Object -First 8)) {
            $info = Get-BugCheckInfo -Code $w.Code -Text $w.Text -ModuleHint $w.Module
            Write-ReportLine ("    {0:dd.MM HH:mm} | {1} {2} | {3}" -f $w.Time, $info.CodeHex, $info.Name, $info.Module) Gray
            Write-BugCheckDecode -Info $info
            if ($info.Code) {
                Add-Finding -Kind 'BugCheck' -Time $w.Time -Title $info.Name -Detail ("{0} {1}" -f $info.CodeHex, $info.Module) -Tags @('bsod', 'bsod-decode')
            }
        }
        Write-ReportLine ''
    }

    $dumpDir = 'C:\Windows\Minidump'
    if (Test-Path $dumpDir) {
        $dumps = Get-ChildItem $dumpDir -Filter '*.dmp' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5
        if ($dumps) {
            $found = $true
            Write-ReportLine ('  ' + (L 'Найдены минидампы:' 'Minidumps found:')) Yellow
            foreach ($d in $dumps) {
                $near = @($Script:Findings | Where-Object { $_.Kind -eq 'BugCheck' -and [math]::Abs(($_.Time - $d.LastWriteTime).TotalMinutes) -lt 20 } | Select-Object -First 1)
                $extra = ''
                if ($near) { $extra = ' ← ' + $near.Title }
                Write-ReportLine ("    {0} ({1:N1} {2}, {3}){4}" -f $d.Name, ($d.Length / 1KB), (L 'КБ' 'KB'), $d.LastWriteTime, $extra)
                Add-Finding -Kind 'Minidump' -Time $d.LastWriteTime -Title ("{0} {1}" -f (L 'Минидамп' 'Minidump'), $d.Name) -Tags @('bsod')
            }
            Write-ReportLine ('    ' + (L 'Для полного стека .dmp: WinDbg или BlueScreenView.' 'For a full .dmp stack: WinDbg or BlueScreenView.')) DarkCyan
        }
    }

    if (-not $found) {
        Write-ReportLine ('  ' + (L 'Признаков BSOD за период не найдено.' 'No BSOD signs in this period.')) Green
    }
}

function Show-DiskEvents {
    Write-Section ("{0} / NTFS / volmgr ({1} {2} {3})" -f (L 'События диска' 'Disk events'), (L 'за' 'last'), $Script:DaysBack, (L 'дн.' 'days'))
    Write-DiskMapLegend
    $providers = @('disk', 'ntfs', 'volmgr', 'stornvme', 'storahci', 'iaStor', 'iaStorV', 'partmgr')
    $any = $false
    foreach ($p in $providers) {
        $evs = Find-CachedEvents -Provider $p -Level @(1, 2, 3) -Max 15
        if ($evs.Count -eq 0) { continue }
        $any = $true
        Write-ReportLine ("  {0} [{1}] — {2}:" -f (L 'Источник' 'Source'), $p, $evs.Count) Yellow
        foreach ($ev in ($evs | Sort-Object TimeCreated -Descending | Select-Object -First 5)) {
            Write-ReportLine ("    → ID {0} | {1} | {2}" -f $ev.Id, $ev.TimeCreated, (Get-ShortMessage $ev 100)) Gray
            $diskName = Resolve-EventDiskName -Event $ev
            if ($diskName) {
                Write-ReportLine ("      {0}: {1}" -f (L 'Это диск' 'This is'), $diskName) Yellow
            }
            $idExplain = Get-EventIdExplain -Provider $p -Id $ev.Id
            if ($idExplain) {
                Write-ReportLine ("      {0}" -f $idExplain) DarkCyan
            }
            $findTitle = "{0} ID {1}" -f $p, $ev.Id
            if ($diskName) { $findTitle = "$findTitle / $diskName" }
            Add-Finding -Kind 'DiskEvent' -Time $ev.TimeCreated -Title $findTitle -Detail (Get-ShortMessage $ev 160) -Event $ev -Tags @('disk', $p)
        }
        Write-Explanation -Provider $p -EventId $evs[0].Id
        $latest = $evs | Sort-Object TimeCreated -Descending | Select-Object -First 1
        [void](Show-EventWindow -CenterTime $latest.TimeCreated -AnchorLabel ("{0} ID {1}" -f $p, $latest.Id) -Minutes $Script:WindowMinutes)
        Write-ReportLine ''
    }
    if (-not $any) {
        Write-ReportLine ('  ' + (L 'Ошибок дисковой подсистемы за период не найдено.' 'No storage-stack errors in this period.')) Green
    }
}

function Show-GpuAndResource {
    Write-Section (L 'Видеодрайвер / нехватка ресурсов' 'Video driver / resource exhaustion')
    $any = $false
    foreach ($prov in @('Display', 'nvlddmkm', 'amdkmdag', 'igfx')) {
        $display = Find-CachedEvents -Provider $prov -Max 10
        foreach ($ev in $display) {
            $any = $true
            Write-ReportLine ("  → {0} ID {1} | {2} | {3}" -f $prov, $ev.Id, $ev.TimeCreated, (Get-ShortMessage $ev 120)) Yellow
            Write-Explanation -Provider $prov -EventId $ev.Id
            Add-Finding -Kind 'GPU' -Time $ev.TimeCreated -Title ("{0} ID {1}" -f $prov, $ev.Id) -Detail (Get-ShortMessage $ev 160) -Event $ev -Tags @('gpu')
            [void](Show-EventWindow -CenterTime $ev.TimeCreated -AnchorLabel ("{0} ID {1}" -f $prov, $ev.Id) -Minutes $Script:WindowMinutes)
        }
    }

    $res = Find-CachedEvents -Provider 'Microsoft-Windows-Resource-Exhaustion-Detector' -Max 5
    foreach ($ev in $res) {
        $any = $true
        Write-ReportLine ("  → {0} ID {1} | {2}" -f (L 'Нехватка ресурсов' 'Resource exhaustion'), $ev.Id, $ev.TimeCreated) Red
        Write-Explanation -Provider 'Microsoft-Windows-Resource-Exhaustion-Detector' -EventId $ev.Id
        Add-Finding -Kind 'Resource' -Time $ev.TimeCreated -Title (L 'Исчерпание ресурсов' 'Resource exhaustion') -Event $ev -Tags @('ram')
    }

    if (-not $any) {
        Write-ReportLine ('  ' + (L 'Сбоев видеодрайвера и детектора нехватки ресурсов за период нет.' 'No video-driver faults or resource-exhaustion events in this period.')) Green
    }
}

function Show-ApplicationCrashes {
    Write-Section (L 'Краши системных процессов (Application)' 'System process crashes (Application)')
    $evs = Find-CachedEvents -LogName 'Application' -Provider 'Application Error' -Max 40
    $interesting = @()
    $softN = 0
    foreach ($ev in $evs) {
        $msg = ''
        if ($ev.Message) { $msg = $ev.Message }
        $mod = Get-ModuleFromText $msg
        if (Test-IsSystemProcessName $mod) {
            $interesting += [pscustomobject]@{ Event = $ev; Module = $mod; Message = (Get-ShortMessage $ev 160) }
        } else {
            $softN++
        }
    }
    $Script:SoftCrashHidden += $softN
    if ($softN -gt 0) {
        Write-ReportLine ("  {0}: {1} — {2}" -f (L 'Краши игр/браузеров/бытового софта скрыты' 'Game/browser/consumer-app crashes hidden'), $softN, (L 'это не неисправность железа' 'this is not a hardware fault')) DarkGray
    }
    if ($interesting.Count -eq 0) {
        Write-ReportLine ('  ' + (L 'Крашей csrss/dwm/explorer/системных модулей за период нет.' 'No csrss/dwm/explorer/system-module crashes in this period.')) Green
        return
    }
    foreach ($row in ($interesting | Select-Object -First 12)) {
        Write-ReportLine ("  → {0} | {1} | {2}" -f $row.Event.TimeCreated, $row.Module, $row.Message) Yellow
        Write-Explanation -Provider 'Application Error' -EventId $row.Event.Id
        Add-Finding -Kind 'AppCrash' -Time $row.Event.TimeCreated -Title ("Application Error {0}" -f $row.Module) -Detail $row.Message -Event $row.Event -Tags @('process')
    }
}

function Show-RecentDrivers {
    Write-Section (L 'Недавно установленные / обновлённые драйверы' 'Recently installed / updated drivers')
    try {
        $drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
            $_.DriverDate -and ([datetime]$_.DriverDate) -ge $Script:StartDate
        } | Sort-Object DriverDate -Descending)
        if ($drivers.Count -eq 0) {
            Write-ReportLine ('  ' + (L 'За период новых дат драйверов через WMI нет.' 'No driver dates in this period via WMI.')) Green
            return
        }
        foreach ($d in ($drivers | Select-Object -First 20)) {
            Write-ReportLine ("  {0:dd.MM.yyyy} | {1} | {2} | {3}" -f ([datetime]$d.DriverDate), $d.DeviceName, $d.DriverVersion, $d.Manufacturer)
        }
        Write-ReportLine ('  ' + (L 'Если сбои начались после одной из этих дат — откатите этот драйвер.' 'If faults started after one of these dates, roll that driver back.')) DarkCyan
    } catch {
        Write-ReportLine ('  ' + (L 'Не удалось прочитать Win32_PnPSignedDriver.' 'Could not read Win32_PnPSignedDriver.')) DarkYellow
    }
}

function Show-Reliability {
    Write-Section (L 'Reliability Monitor (сбои приложений)' 'Reliability Monitor (app failures)')
    try {
        $recs = @(Get-CimInstance Win32_ReliabilityRecords -ErrorAction Stop | Where-Object {
            $_.TimeGenerated -and ([datetime]$_.TimeGenerated) -ge $Script:StartDate -and
            $_.EventIdentifier -in @(1000, 1001, 1002)
        } | Sort-Object TimeGenerated -Descending)
        if ($recs.Count -eq 0) {
            Write-ReportLine ('  ' + (L 'Записей RAC о крашах за период нет (или Reliability отключён).' 'No RAC crash records in this period (or Reliability is disabled).')) DarkGray
            return
        }
        $softN = 0
        $kept = @()
        foreach ($r in $recs) {
            $name = ''
            if ($r.ProductName) { $name = [string]$r.ProductName }
            if (-not (Test-IsSystemProcessName $name)) { $softN++; continue }
            $kept += $r
        }
        $Script:SoftCrashHidden += $softN
        if ($softN -gt 0) {
            Write-ReportLine ("  {0}: {1} — {2}" -f (L 'Игры/браузеры в Reliability скрыты' 'Games/browsers in Reliability hidden'), $softN, (L 'на вердикт не влияют' 'do not affect the verdict')) DarkGray
        }
        if ($kept.Count -eq 0) {
            Write-ReportLine ('  ' + (L 'Оставшихся системных крашей в Reliability нет.' 'No remaining system crashes in Reliability.')) Green
            return
        }
        foreach ($r in ($kept | Select-Object -First 15)) {
            Write-ReportLine ("  {0} | {1} | {2}" -f $r.TimeGenerated, $r.ProductName, $r.SourceName) Gray
        }
    } catch {
        Write-ReportLine ('  ' + (L 'Win32_ReliabilityRecords недоступен.' 'Win32_ReliabilityRecords is unavailable.')) DarkGray
    }
}

function Show-TopSystemErrors {
    Write-Section ("{0} ({1}, {2} {3})" -f (L 'Топ источников неисправностей' 'Top fault sources'), (L 'журнал Система' 'System log'), $Script:DaysBack, (L 'дн.' 'days'))
    if (-not $Script:FullReport) {
        Write-ReportLine ('  ' + (L '(Обновления Windows, DCOM, DNS, время и прочий шум скрыты. Режим «полный отчёт» покажет их.)' '(Windows Update, DCOM, DNS, time and other noise are hidden. Full-report mode will show them.)')) DarkGray
    }

    $all = Find-CachedEvents -LogName 'System' -Level @(1, 2) -Max 800
    if ($all.Count -eq 0) {
        Write-ReportLine ('  ' + (L 'Критических/ошибочных событий за период нет.' 'No critical/error events in this period.')) Green
        return
    }

    $relevant = @($all | Where-Object {
        (Test-IsRelevantProvider $_.ProviderName) -or
        ((Get-ProviderExplain $_.ProviderName) -and ((Get-ProviderExplain $_.ProviderName).Level -in @('Critical', 'Warning')))
    })
    $relevant = @($relevant | Where-Object { -not (Test-IsNoiseProvider $_.ProviderName) })

    # SCM: только если одна и та же служба сыпется часто
    $scm = @($all | Where-Object { $_.ProviderName -eq 'Service Control Manager' })
    $scmKeep = @()
    if ($scm.Count -gt 0) {
        $byMsg = $scm | Group-Object { Get-ShortMessage $_ 80 } | Where-Object { $_.Count -ge 5 }
        if ($byMsg) {
            $scmKeep = @($byMsg | ForEach-Object { $_.Group } )
            Write-ReportLine ('  ' + (L 'SCM показан только для служб с ≥5 одинаковыми сбоями.' 'SCM is shown only for services with ≥5 identical failures.')) DarkGray
        }
    }
    $relevant = @($relevant | Where-Object { $_.ProviderName -ne 'Service Control Manager' }) + $scmKeep

    if ($relevant.Count -eq 0) {
        Write-ReportLine ('  ' + (L 'Релевантных ошибок неисправности в топе нет (шум отфильтрован).' 'No relevant fault errors in the top list (noise filtered).')) Green
        return
    }

    $groups = $relevant | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 10
    foreach ($g in $groups) {
        $info = Get-ProviderExplain -Provider $g.Name
        $color = [ConsoleColor]::Gray
        $mark = ''
        if ($info) {
            switch ($info.Level) {
                'Critical' { $color = [ConsoleColor]::Red; $mark = (L ' !!! КРИТИЧНО !!!' ' !!! CRITICAL !!!') }
                'Warning'  { $color = [ConsoleColor]::Yellow; $mark = (L ' (внимание)' ' (warning)') }
            }
        }
        Write-ReportLine ("  • {0} [{1}]: {2}.{3}" -f (L 'Источник' 'Source'), $g.Name, $g.Count, $mark) $color

        $sampleIds = @($g.Group | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 3)
        $idSummary = ($sampleIds | ForEach-Object { "ID $($_.Name)×$($_.Count)" }) -join ', '
        Write-ReportLine ("    {0}: {1}" -f (L 'Частые коды' 'Frequent codes'), $idSummary) DarkGray

        $topId = 0
        if ($sampleIds.Count -gt 0) { $topId = [int]$sampleIds[0].Name }
        Write-Explanation -Provider $g.Name -EventId $topId
    }
}

function Show-DeviceProblems {
    Write-Section (L 'Проблемные устройства (Device Manager)' 'Problem devices (Device Manager)')
    try {
        $problem = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object {
            $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 -and $_.ConfigManagerErrorCode -ne 45 -and $_.ConfigManagerErrorCode -ne 47
        })
        if ($problem.Count -eq 0) {
            Write-ReportLine ('  ' + (L 'Устройств с кодом ошибки (кроме отключённых/извлечённых) не найдено.' 'No devices with an error code (except disabled/removed) were found.')) Green
            return
        }
        $codeMap = @{
            1  = (L 'Устройство настроено неверно' 'Device is not configured correctly')
            3  = (L 'Драйвер повреждён или переполнение' 'Driver is corrupted or the system is out of memory')
            10 = (L 'Устройство не запускается' 'Device cannot start')
            12 = (L 'Недостаточно свободных ресурсов' 'This device cannot find enough free resources')
            14 = (L 'Нужна перезагрузка' 'Restart required')
            18 = (L 'Переустановите драйверы' 'Reinstall the drivers')
            21 = (L 'Удаляется' 'Removing')
            28 = (L 'Нет драйверов' 'Drivers are not installed')
            31 = (L 'Windows не удалось настроить устройство' 'Windows cannot load the device drivers')
            43 = (L 'Остановлено из-за ошибки (часто GPU/USB)' 'Stopped due to an error (often GPU/USB)')
            48 = (L 'Программное обеспечение заблокировано' 'Software blocked')
        }
        foreach ($dev in ($problem | Select-Object -First 20)) {
            $code = [int]$dev.ConfigManagerErrorCode
            $hint = if ($codeMap.ContainsKey($code)) { $codeMap[$code] } else { (L 'См. код в справке Microsoft' 'See the code in Microsoft docs') }
            Write-ReportLine ("  • {0}" -f $dev.Name) Yellow
            Write-ReportLine ("    {0}: {1} — {2}" -f (L 'Код ошибки' 'Error code'), $code, $hint) DarkYellow
            $ignoreDev = ($code -eq 28) -or ("$($dev.Name)" -match '(?i)\bDFU\b|virtual|root enumerator')
            if (-not $ignoreDev) {
                Add-Finding -Kind 'Device' -Time (Get-Date) -Title $dev.Name -Detail ("{0} {1}: {2}" -f (L 'Код' 'Code'), $code, $hint) -Tags @('device')
                Mark-Issue -Key 'Device'
            } else {
                Write-ReportLine ('    ' + (L 'В вердикт не входит: нет драйвера у периферии / DFU, это не неисправность ПК.' 'Not in the verdict: a peripheral without a driver / DFU is not a PC fault.')) DarkGray
            }
        }
    } catch {
        Write-ReportLine ('  ' + (L 'Не удалось опросить PnP-устройства (нужны права администратора).' 'Could not query PnP devices (administrator rights required).')) DarkYellow
    }
}

function Show-SelfCheck {
    Write-Section (L 'Самопроверка среды' 'Environment self-check')
    Write-ReportLine ("  PowerShell: {0}" -f $PSVersionTable.PSVersion)
    if (Test-IsAdmin) {
        Write-ReportLine ('  ' + (L 'Права администратора: да' 'Administrator rights: yes')) Green
    } else {
        Write-ReportLine ('  ' + (L 'Права администратора: нет — часть журналов и устройств недоступна.' 'Administrator rights: no — some logs and devices are unavailable.')) Yellow
    }

    $Script:DumpEnabled = Get-DumpEnabled
    $dumpText = Get-DumpEnabledLabel $Script:DumpEnabled
    $dumpColor = [ConsoleColor]::Gray
    if ("$($Script:DumpEnabled)" -eq '0') { $dumpColor = [ConsoleColor]::Yellow }
    Write-ReportLine ("  {0}: {1}" -f (L 'Дампы памяти при BSOD' 'BSOD memory dumps'), $dumpText) $dumpColor

    $Script:PendingReboot = Test-RebootPending
    if ($Script:PendingReboot) {
        Write-ReportLine ('  ' + (L 'Ожидается перезагрузка (обновление / CBS / PendingFileRename).' 'A reboot is pending (update / CBS / PendingFileRename).')) Yellow
    } else {
        Write-ReportLine ('  ' + (L 'Ожидания перезагрузки нет.' 'No pending reboot.')) DarkGray
    }

    $Script:FastStartup = $null
    try {
        $pw = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -ErrorAction Stop
        $Script:FastStartup = [int]$pw.HiberbootEnabled
    } catch {}
    if ($null -ne $Script:FastStartup) {
        if ($Script:FastStartup -eq 1) {
            Write-ReportLine ('  ' + (L 'Быстрый запуск (Fast Startup) включён — иногда маскирует Kernel-Power 41 после «выключения».' 'Fast Startup is on — it can mask Kernel-Power 41 after a “shutdown”.')) DarkYellow
        } else {
            Write-ReportLine ('  ' + (L 'Быстрый запуск (Fast Startup) выключен.' 'Fast Startup is off.')) DarkGray
        }
    }
}

function Show-SleepAndBoot {
    Write-Section (L 'Сон, гибернация, выключение' 'Sleep, hibernation, shutdown')
    $sleep = @(Find-CachedEvents -Provider 'Microsoft-Windows-Kernel-Power' -Id 42 -Max 8)
    $resume = @(Find-CachedEvents -Provider 'Microsoft-Windows-Kernel-Power' -Id 107 -Max 8)
    $down = @(Find-CachedEvents -Provider 'Microsoft-Windows-Kernel-Power' -Id 109 -Max 8)
    Write-ReportLine ("  {0}: {1}  |  {2}: {3}  |  {4}: {5}" -f (L 'Уход в сон (42)' 'Sleep enter (42)'), $sleep.Count, (L 'выход из сна (107)' 'resume (107)'), $resume.Count, (L 'выключение (109)' 'shutdown (109)'), $down.Count)

    $kp = @(Find-CachedEvents -Provider 'Microsoft-Windows-Kernel-Power' -Id 41 -Max 20)
    $afterSleep = 0
    foreach ($k in $kp) {
        foreach ($r in $resume) {
            $delta = ($k.TimeCreated - $r.TimeCreated).TotalMinutes
            if ($delta -ge 0 -and $delta -le 15) { $afterSleep++; break }
        }
    }
    if ($afterSleep -gt 0) {
        Write-ReportLine ("  {0}: {1}" -f (L 'Kernel-Power 41 в течение 15 мин после выхода из сна' 'Kernel-Power 41 within 15 min after resume'), $afterSleep) Yellow
        Add-Finding -Kind 'Sleep' -Time $kp[0].TimeCreated -Title (L '41 после сна' '41 after sleep') -Tags @('power')
        Mark-Issue -Key 'Sleep'
    } elseif ($kp.Count -eq 0) {
        Write-ReportLine ('  ' + (L 'Связки «сон → внезапная перезагрузка» нет.' 'No sleep → unexpected reboot link.')) Green
    }

    if ($Script:FastStartup -eq 1 -and $kp.Count -gt 0) {
        Write-ReportLine ('  ' + (L 'Fast Startup включён и есть 41: для проверки выключите «быстрый запуск» в панели электропитания.' 'Fast Startup is on and 41 is present: turn off Fast Startup in power options to test.')) Yellow
    }
}

function Show-VolumeDirty {
    Write-Section (L 'Грязные тома и CHKDSK' 'Dirty volumes and CHKDSK')
    $any = $false
    try {
        $vols = @(Get-CimInstance Win32_Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 3 })
        foreach ($v in $vols) {
            if (-not $v.DirtyBitSet) { continue }
            $any = $true
            $letter = $v.DriveLetter
            if (-not $letter) { $letter = $v.DeviceID }
            Write-ReportLine ("  {0}: {1} — {2}" -f (L 'Том' 'Volume'), $letter, (L 'установлен dirty bit, нужна проверка' 'dirty bit is set, a check is needed')) Red
            Add-Finding -Kind 'VolumeDirty' -Time (Get-Date) -Title ("{0} {1}" -f (L 'Грязный том' 'Dirty volume'), $letter) -Tags @('disk')
            Mark-Issue -Key 'VolumeDirty' -Critical
        }
    } catch {
        Write-ReportLine ('  ' + (L 'Win32_Volume недоступен.' 'Win32_Volume is unavailable.')) DarkGray
    }

    $chk = @()
    try {
        $chk = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Application'; ProviderName = 'Wininit'; Id = 1001; StartTime = $Script:StartDate
        } -MaxEvents 8 -ErrorAction Stop)
    } catch {}
    foreach ($ev in $chk) {
        $any = $true
        Write-ReportLine ("  CHKDSK / Wininit 1001 | {0} | {1}" -f $ev.TimeCreated, (Get-ShortMessage $ev 140)) Yellow
        Add-Finding -Kind 'VolumeDirty' -Time $ev.TimeCreated -Title 'CHKDSK' -Detail (Get-ShortMessage $ev 120) -Tags @('disk')
        Mark-Issue -Key 'Chkdsk'
    }
    if (-not $any) {
        Write-ReportLine ('  ' + (L 'Dirty bit не установлен, автопроверок CHKDSK за период нет.' 'No dirty bit and no CHKDSK auto-checks in this period.')) Green
    }
}

function Show-BusEvents {
    Write-Section (L 'USB, сеть, PCIe (отвалы)' 'USB, network, PCIe (dropouts)')
    $any = $false
    $providers = @(
        'USB', 'USBHUB3', 'USBSTOR', 'Microsoft-Windows-USB-USBXHCI',
        'Microsoft-Windows-Kernel-PnP', 'ndis', 'pci', 'Microsoft-Windows-NDIS'
    )
    foreach ($p in $providers) {
        $evs = @(Find-CachedEvents -Provider $p -Level @(1, 2) -Max 6)
        if ($p -eq 'Microsoft-Windows-Kernel-PnP') {
            $evs = @($evs | Where-Object { $_.Id -in @(219, 400, 410, 411) })
        }
        foreach ($ev in $evs) {
            $any = $true
            Write-ReportLine ("  → {0} ID {1} | {2} | {3}" -f $p, $ev.Id, $ev.TimeCreated, (Get-ShortMessage $ev 120)) Yellow
            Add-Finding -Kind 'Bus' -Time $ev.TimeCreated -Title ("{0} ID {1}" -f $p, $ev.Id) -Detail (Get-ShortMessage $ev 140) -Tags @('bus')
            Mark-Issue -Key 'Bus'
        }
    }
    if (-not $any) {
        Write-ReportLine ('  ' + (L 'Критических отвалов USB/сети/PCIe в журнале Система за период нет.' 'No critical USB/network/PCIe dropouts in the System log for this period.')) Green
    }
}

function Show-UpdateContext {
    Write-Section (L 'Контекст обновлений Windows' 'Windows update context')
    $Script:LastUpdateInfo = Get-LastWindowsUpdateInfo
    $u = $Script:LastUpdateInfo
    if ($u -and $u.Date) {
        Write-ReportLine ("  {0}: {1:dd.MM.yyyy HH:mm}" -f (L 'Последняя успешная установка' 'Last successful install'), $u.Date)
        if ($u.Title) { Write-ReportLine ("  {0}: {1}" -f (L 'Что поставили' 'What was installed'), $u.Title) DarkGray }
        $first = @(Get-HardwareFindings | Where-Object Time | Sort-Object Time | Select-Object -First 1)
        if ($first.Count -gt 0 -and $first[0].Time -gt $u.Date) {
            Write-ReportLine ("  {0}: {1:dd.MM.yyyy HH:mm} ({2})" -f (L 'Первый аппаратный сбой после этого' 'First hardware fault after that'), $first[0].Time, $first[0].Title) Yellow
            Write-ReportLine ('  ' + (L 'Это не доказательство вины патча, но совпадение по времени стоит проверить (откат KB / драйвер).' 'This does not prove the patch is at fault, but the timing is worth checking (rollback KB / driver).')) DarkCyan
        } else {
            Write-ReportLine ('  ' + (L 'Аппаратные сбои не выглядят как «сразу после этого обновления».' 'Hardware faults do not look like they started right after this update.')) Green
        }
    } else {
        Write-ReportLine ('  ' + (L 'Дату последнего обновления Windows прочитать не удалось.' 'Could not read the last Windows update date.')) DarkGray
    }
}

function Show-FindingFrequency {
    Write-Section (L 'Частота и вес событий' 'Event frequency and weight')
    $stats = @(Get-FindingStats)
    if ($stats.Count -eq 0) {
        Write-ReportLine ('  ' + (L 'Аппаратных фактов нет — считать частоту нечего.' 'No hardware findings — nothing to count.')) Green
        return
    }
    foreach ($s in $stats) {
        $label = Get-FindingKindLabel $s.Kind
        $w = Get-WeightLabel $s.Weight
        $range = ''
        if ($s.First -and $s.Last) {
            if ($s.Count -eq 1) { $range = ('{0:dd.MM HH:mm}' -f $s.First) }
            else { $range = ('{0:dd.MM HH:mm} → {1:dd.MM HH:mm} ({2} {3})' -f $s.First, $s.Last, $s.SpanDays, (L 'дн.' 'days')) }
        }
        $col = [ConsoleColor]::Gray
        if ($s.Weight -eq 'repeat') { $col = [ConsoleColor]::Red }
        elseif ($s.Weight -eq 'few') { $col = [ConsoleColor]::Yellow }
        $title = $s.Title
        if (-not $title) { $title = $label }
        Write-ReportLine ("  • {0}: {1}× — {2} — {3}" -f $title, $s.Count, $w, $range) $col
        if ($s.Weight -eq 'single') {
            Write-ReportLine ('    ' + (L 'Единичный случай: само по себе слабее серии. Смотрите, повторится ли.' 'A single case is weaker evidence than a series. See if it repeats.')) DarkGray
        } elseif ($s.Weight -eq 'repeat') {
            Write-ReportLine ('    ' + (L 'Серия: проблема повторяется, это уже не случайный разовый сбой.' 'A series: the problem repeats, this is no longer a one-off.')) Red
        }
    }
}

function Show-PreviousCompare {
    Write-Section (L 'Сравнение с прошлым отчётом' 'Comparison with the previous report')
    $Script:CompareLines = @(Get-PreviousCompareLines)
    foreach ($row in $Script:CompareLines) {
        Write-ReportLine $row.Text $row.Color
    }
}

function Show-AnalysisAndRecommendations {
    Write-Header (L 'АНАЛИЗ И РЕКОМЕНДАЦИИ ПО ФАКТАМ' 'FACT-BASED ANALYSIS AND RECOMMENDATIONS')
    $findings = @($Script:Findings)

    if ($findings.Count -eq 0) {
        Write-ReportLine ('  ' + (L 'Критичных неисправностей за период не зафиксировано.' 'No critical faults were recorded in this period.')) Green
        Write-ReportLine ('  ' + (L 'Дополнительных действий не требуется по результатам этого отчёта.' 'No extra actions are required from this report.')) Green
        return
    }

    $hasKP   = @($findings | Where-Object { $_.Kind -eq 'KernelPower' }).Count -gt 0
    $hasWhea = @($findings | Where-Object { $_.Kind -eq 'WHEA' }).Count -gt 0
    $hasBsod = @($findings | Where-Object { $_.Kind -in @('BugCheck', 'Minidump') }).Count -gt 0
    $hasDisk = @($findings | Where-Object { $_.Kind -in @('DiskEvent', 'DiskHealth') -or ($_.Tags -contains 'disk') }).Count -gt 0
    $hasGpu  = @($findings | Where-Object { $_.Kind -eq 'GPU' }).Count -gt 0
    $hasRam  = @($findings | Where-Object { $_.Kind -in @('MemoryDiag', 'Resource') -or ($_.Tags -contains 'ram') }).Count -gt 0
    $hasDev  = @($findings | Where-Object { $_.Kind -eq 'Device' }).Count -gt 0
    $hasLow  = @($findings | Where-Object { $_.Kind -eq 'LowDisk' }).Count -gt 0
    $hasTherm = @($findings | Where-Object { $_.Kind -eq 'Thermal' }).Count -gt 0
    $hasDirty = @($findings | Where-Object { $_.Kind -eq 'VolumeDirty' }).Count -gt 0
    $hasBus = @($findings | Where-Object { $_.Kind -eq 'Bus' }).Count -gt 0
    $hasSleep = @($findings | Where-Object { $_.Kind -eq 'Sleep' }).Count -gt 0
    $hwN = @(Get-HardwareFindings).Count

    Write-Section (L 'Краткий разбор' 'Short breakdown')
    Write-ReportLine ("  {0}: {1}  |  {2}: {3}" -f (L 'Всего фактов' 'Total facts'), $findings.Count, (L 'из них железо' 'hardware among them'), $hwN)
    if ($hasKP)   { Write-ReportLine ("  • Kernel-Power 41: {0} — {1}" -f @($findings | Where-Object Kind -eq 'KernelPower').Count, (L 'внезапные перезагрузки' 'unexpected reboots')) Red }
    if ($hasBsod) { Write-ReportLine ('  • BSOD / ' + (L 'минидампы: есть' 'minidumps: present')) Red }
    if ($hasWhea) { Write-ReportLine ("  • WHEA: {0}" -f @($findings | Where-Object Kind -eq 'WHEA').Count) Red }
    if ($hasDisk) { Write-ReportLine ('  • ' + (L 'Ошибки накопителя / тома: есть' 'Storage / volume errors: present')) Red }
    if ($hasGpu)  { Write-ReportLine ('  • ' + (L 'Сбои видеодрайвера: есть' 'Video driver faults: present')) Yellow }
    if ($hasRam)  { Write-ReportLine ('  • ' + (L 'Память / нехватка ресурсов: есть' 'Memory / resource exhaustion: present')) Yellow }
    if ($hasDev)  { Write-ReportLine ('  • ' + (L 'Проблемные устройства PnP: есть' 'Problem PnP devices: present')) Yellow }
    if ($hasLow)  { Write-ReportLine ('  • ' + (L 'Критически мало места на томе: есть' 'Critically low volume space: present')) Yellow }
    if ($hasTherm) { Write-ReportLine ('  • ' + (L 'Перегрев по датчикам: есть' 'Sensor overheating: present')) Yellow }
    if ($hasDirty) { Write-ReportLine ('  • ' + (L 'Грязный том / CHKDSK: есть' 'Dirty volume / CHKDSK: present')) Red }
    if ($hasBus) { Write-ReportLine ('  • ' + (L 'Отвалы USB/сети/PCIe: есть' 'USB/network/PCIe dropouts: present')) Yellow }
    if ($hasSleep) { Write-ReportLine ('  • ' + (L 'Связка сон → Kernel-Power 41: есть' 'Sleep → Kernel-Power 41 link: present')) Yellow }
    if ($Script:SoftCrashHidden -gt 0) {
        Write-ReportLine ("  • {0}: {1} — {2}" -f (L 'Краши игр/браузеров скрыты' 'Game/browser crashes hidden'), $Script:SoftCrashHidden, (L 'не железо' 'not hardware')) DarkGray
    }

    $bsodDecoded = @($findings | Where-Object { $_.Kind -eq 'BugCheck' -and $_.Detail })
    if ($bsodDecoded.Count -gt 0) {
        Write-Section (L 'Расшифрованные BSOD' 'Decoded BSODs')
        foreach ($b in ($bsodDecoded | Select-Object -First 6)) {
            Write-ReportLine ("  • {0:dd.MM HH:mm} — {1}: {2}" -f $b.Time, $b.Title, $b.Detail) Red
        }
    }

    Write-Section (L 'Связки симптомов' 'Symptom links')
    if ($hasKP -and $hasDisk) {
        Write-ReportLine ('  ' + (L 'Kernel-Power 41 + ошибки диска → с высокой вероятностью виноват SSD/NVMe (отвал под нагрузкой, слот M.2, кабель, питание, перегрев).' 'Kernel-Power 41 + disk errors → SSD/NVMe is the likely cause (drop under load, M.2 seat, cable, power, heat).')) Red
    } elseif ($hasKP -and $hasWhea) {
        Write-ReportLine ('  ' + (L 'Kernel-Power 41 + WHEA → смотрите компонент WHEA (RAM/CPU/PCIe). Отключите XMP/разгон, проверьте температуры.' 'Kernel-Power 41 + WHEA → check the WHEA component (RAM/CPU/PCIe). Disable XMP/overclock and check temperatures.')) Red
    } elseif ($hasKP -and $hasGpu) {
        Write-ReportLine ('  ' + (L 'Kernel-Power 41 + сбой GPU → возможны зависание видеодрайвера и жёсткий reset. Обновите/откатите драйвер GPU, проверьте питание GPU.' 'Kernel-Power 41 + GPU fault → the video driver may have hung and forced a reset. Update/rollback the GPU driver and check GPU power.')) Yellow
    } elseif ($hasKP) {
        Write-ReportLine ('  ' + (L 'Есть Kernel-Power 41 без явной «причины» рядом в журнале → чаще блок питания, перегрев, кратковременный отвал питания CPU/RAM.' 'Kernel-Power 41 without a nearby cause → more often PSU, heat, or a brief CPU/RAM power drop.')) Yellow
        Write-ReportLine ('  ' + (L 'Смотрите блоки «Анализ журнала ±5 мин» выше по каждому событию 41.' 'See the ±5 min log windows above for each event 41.')) DarkCyan
    } else {
        Write-ReportLine ('  ' + (L 'Внезапных Kernel-Power 41 за период нет.' 'No Kernel-Power 41 events in this period.')) Green
    }

    if ($hasBsod -and $hasDisk) {
        Write-ReportLine ('  ' + (L 'BSOD + диск → сохраните минидампы, но параллельно проверьте SMART/прошивку SSD — краш мог быть из-за потери тома.' 'BSOD + disk → keep the minidumps, but also check SSD SMART/firmware — the crash may be a lost volume.')) Red
    } elseif ($hasBsod) {
        Write-ReportLine ('  ' + (L 'Есть BSOD — ориентируйтесь на расшифровку STOP-кода, модуль/процесс и разбор .dmp (WinDbg / BlueScreenView).' 'A BSOD is present — use the STOP decode, module/process, and .dmp analysis (WinDbg / BlueScreenView).')) Red
    }

    Write-Section (L 'Что сделать именно по вашим находкам' 'What to do for your findings')
    $n = 0
    if ($hasDisk -or ($hasKP -and $hasDisk)) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'НАКОПИТЕЛЬ: сделайте резервную копию данных немедленно.' 'STORAGE: back up your data immediately.')) Red
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'Проверьте SSD утилитой производителя (SMART/прошивка). Для NVMe — посадка в слоте M.2 и термопрокладка.' 'Check the SSD with the vendor tool (SMART/firmware). For NVMe — reseat M.2 and check the thermal pad.'))
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'При HDD/SATA — кабели и питание; смените кабель/порт для проверки.' 'For HDD/SATA — cables and power; swap the cable/port to test.'))
    }
    if ($hasBsod) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'BSOD: скопируйте файлы из C:\Windows\Minidump, сверьте STOP-код выше и драйвер/процесс из расшифровки.' 'BSOD: copy C:\Windows\Minidump, match the STOP code above and the driver/process from the decode.')) Red
        foreach ($b in ($bsodDecoded | Select-Object -First 3)) {
            Write-ReportLine ("      {0:dd.MM HH:mm}: {1}" -f $b.Time, $b.Detail) DarkGray
        }
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'Обновите чипсет и драйвер устройства из стека BSOD с сайта производителя платы/ноутбука.' 'Update chipset and the device driver from the BSOD stack using the board/laptop vendor site.'))
    }
    if ($hasWhea -or $hasRam) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'ПАМЯТЬ/WHEA: Win+R → mdsched.exe (проверка RAM). Отключите XMP/DOCP/разгон для теста.' 'RAM/WHEA: Win+R → mdsched.exe. Disable XMP/DOCP/overclock for a test.')) Yellow
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'Обновите BIOS; проверьте охлаждение CPU.' 'Update BIOS; check CPU cooling.'))
    }
    if ($hasGpu) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'GPU: чистая переустановка драйвера (DDU в безопасном режиме при повторах), проверка температур и питания видеокарты.' 'GPU: clean driver reinstall (DDU in Safe Mode if it repeats); check GPU temperature and power.')) Yellow
    }
    if ($hasTherm) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'Перегрев: очистите пыль, проверьте термопасту и обороты вентиляторов.' 'Overheating: clean dust, check thermal paste and fan speeds.')) Yellow
    }
    if ($hasKP -and -not $hasDisk -and -not $hasWhea -and -not $hasGpu) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'Питание: проверьте БП/розетку/батарею; для ПК — нагрузка GPU+CPU (стресс) и хватает ли ватт.' 'Power: check PSU/outlet/battery; on a desktop, stress GPU+CPU and confirm wattage.')) Yellow
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'Перегрев: посмотрите температуры в простое и под нагрузкой.' 'Heat: check idle and load temperatures.'))
    }
    if ($hasDev) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'Диспетчер устройств: устраните жёлтые значки (драйвер с сайта OEM, не «драйвер-пак»).' 'Device Manager: fix warning icons (OEM driver, not a driver pack).'))
    }
    if ($hasLow) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'Освободите место на системном томе (желательно >15% свободно).' 'Free space on the system volume (preferably >15% free).'))
    }
    if ($hasDirty) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'ТОМ: сделайте бэкап и проверьте диск (chkdsk / сканер SSD). Dirty bit значит том закрыли нечисто.' 'VOLUME: back up and check the disk (chkdsk / SSD tool). A dirty bit means the volume was not closed cleanly.')) Red
    }
    if ($hasSleep -or ($hasKP -and $Script:FastStartup -eq 1)) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'Питание/сон: выключите Fast Startup и проверьте, повторится ли 41 после полного выключения.' 'Power/sleep: turn off Fast Startup and see if 41 still happens after a full shutdown.')) Yellow
    }
    if ($hasBus) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'USB/PCIe: смените порт/хаб, проверьте кабель и слот. Отвал шины может выглядеть как диск или GPU.' 'USB/PCIe: change port/hub, check the cable and slot. A bus dropout can look like a disk or GPU fault.')) Yellow
    }
    if ($Script:DumpEnabled -eq 0) {
        $n++; Write-ReportLine ("  {0}. {1}" -f $n, (L 'Включите минидампы (Панель управления → Система → Дополнительно → Загрузка и восстановление), иначе следующий BSOD не сохранится.' 'Enable minidumps (Control Panel → System → Advanced → Startup and Recovery), or the next BSOD will not be saved.')) Yellow
    }
    if ($n -eq 0) {
        Write-ReportLine ('  ' + (L 'Специфичных действий не сформировано — смотрите пояснения к событиям выше.' 'No specific actions were formed — see the event notes above.')) DarkGray
    }

    Write-ReportLine ''
    if (-not $Script:FullReport) {
        Write-ReportLine ('  ' + (L 'Примечание: ошибки Центра обновления Windows, DCOM, DNS и т.п. скрыты. Включите «полный отчёт» в меню, если они нужны.' 'Note: Windows Update, DCOM, DNS and similar noise are hidden. Enable Full report in the menu if you need them.')) DarkGray
    }
}

function Show-Summary {
    Write-Header (L 'СВОДКА' 'SUMMARY')
    Write-ReportLine ("  {0}: {1} {2} {3} ({4} {5:dd.MM.yyyy})" -f (L 'Период анализа' 'Analysis period'), (L 'последние' 'last'), $Script:DaysBack, (L 'дн.' 'days'), (L 'с' 'from'), $Script:StartDate)
    Write-ReportLine ("  {0}: {1}" -f (L 'Аппаратных фактов' 'Hardware findings'), @(Get-HardwareFindings).Count)
    Write-ReportLine ("  {0}: {1}" -f (L 'Уникальных типов проблем' 'Unique issue types'), $Script:IssueTypes.Count)
    if ($Script:SoftCrashHidden -gt 0) {
        Write-ReportLine ("  {0}: {1}" -f (L 'Скрыто крашей игр/браузеров' 'Hidden game/browser crashes'), $Script:SoftCrashHidden) DarkGray
    }
    $critN = $Script:CriticalTypes.Count
    $serious = @($Script:Findings | Where-Object { $_.Kind -in @('KernelPower', 'WHEA', 'BugCheck', 'DiskEvent', 'DiskHealth') }).Count -gt 0
    if ($critN -gt 0 -or $serious) {
        Write-ReportLine ("  {0}: {1}" -f (L 'Критических типов' 'Critical types'), $critN) Red
        Write-ReportLine ('  ' + (L 'Вердикт: обнаружены признаки неисправности — смотрите раздел «Анализ и рекомендации».' 'Verdict: fault signs were found — see Analysis and recommendations.')) Red
    } elseif ($Script:Findings.Count -gt 0) {
        Write-ReportLine ('  ' + (L 'Вердикт: есть замечания, критичных крашей может не быть.' 'Verdict: there are notes; there may be no critical crashes.')) Yellow
    } else {
        Write-ReportLine ('  ' + (L 'Вердикт: по проверкам неисправностей серьёзных проблем не видно.' 'Verdict: the fault checks do not show serious problems.')) Green
    }
}

function Reset-DiagnosticsState {
    $Script:Report = New-Object System.Text.StringBuilder
    $Script:ReportHtml = New-Object System.Collections.Generic.List[object]
    $Script:IssueTypes = New-Object System.Collections.Generic.HashSet[string]
    $Script:CriticalTypes = New-Object System.Collections.Generic.HashSet[string]
    $Script:Findings = New-Object System.Collections.ArrayList
    $Script:StartDate = (Get-Date).AddDays(-$Script:DaysBack)
    $Script:CacheReady = $false
    $Script:EventCache = @{ System = @(); Application = @(); Setup = @() }
    $Script:ProgressStep = 0
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $tag = $Script:Lang.ToUpperInvariant()
    if ($Script:CustomReportPath) {
        $Script:ReportPath = $Script:CustomReportPath
    } else {
        $Script:ReportPath = Join-Path $PSScriptRoot ("WinErrorParser_Report_{0}_{1}.txt" -f $tag, $stamp)
    }
    $Script:HtmlPath = [System.IO.Path]::ChangeExtension($Script:ReportPath, 'html')
    $Script:DiskByNumber = @{}
    $Script:LetterToDisk = @{}
    $Script:DiskMapReady = $false
    $Script:SoftCrashHidden = 0
    $Script:LastUpdateInfo = $null
    $Script:PreviousState = Import-PreviousState
    $Script:CompareLines = @()
    $Script:DumpEnabled = $null
    $Script:FastStartup = $null
    $Script:PendingReboot = $false
}

function Clear-OneEventLog {
    param([Parameter(Mandatory)][string]$LogName)
    try {
        $p = Start-Process -FilePath "$env:SystemRoot\System32\wevtutil.exe" `
            -ArgumentList @('cl', $LogName) `
            -Wait -PassThru -NoNewWindow -WindowStyle Hidden -ErrorAction Stop
        if ($p.ExitCode -eq 0) {
            Write-Host ("  [OK] {0}: {1}" -f (L 'Очищен' 'Cleared'), $LogName) -ForegroundColor Green
            return $true
        }
    } catch {}

    try {
        $session = [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession
        $session.ClearLog($LogName)
        Write-Host ("  [OK] {0}: {1}" -f (L 'Очищен' 'Cleared'), $LogName) -ForegroundColor Green
        return $true
    } catch {
        Write-Host ("  [{0}] {1}: {2}" -f (L 'ОШИБКА' 'ERROR'), $LogName, $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Backup-EventLogs {
    param([string[]]$LogNames)
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $dir = Join-Path $PSScriptRoot ("logs_backup_{0}" -f $stamp)
    try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { return $null }
    $ok = 0
    foreach ($l in $LogNames) {
        $safe = ($l -replace '[\\/:*?"<>|]', '_')
        $dest = Join-Path $dir ($safe + '.evtx')
        try {
            $p = Start-Process -FilePath "$env:SystemRoot\System32\wevtutil.exe" `
                -ArgumentList @('epl', $l, $dest) `
                -Wait -PassThru -NoNewWindow -WindowStyle Hidden -ErrorAction Stop
            if ($p.ExitCode -eq 0) { $ok++ }
        } catch {}
    }
    Write-Host ("  {0}: {1} ({2} {3})" -f (L 'Резервная копия журналов' 'Event log backup'), $dir, $ok, (L 'файлов' 'files')) -ForegroundColor DarkCyan
    return $dir
}

function Test-YesAnswer {
    param([string]$Value)
    $v = ("$Value").Trim()
    return @('ДА', 'да', 'Да', 'YES', 'Yes', 'yes', 'Y', 'y') -contains $v
}

function Invoke-ClearEventLogs {
    Clear-Host
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host ('  ' + (L 'ОЧИСТКА ЖУРНАЛОВ СОБЫТИЙ WINDOWS' 'CLEAR WINDOWS EVENT LOGS')) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-IsAdmin)) {
        Write-Host ('  ' + (L 'Нужны права администратора. Запустите Start-WinErrorParser.bat от администратора.' 'Administrator rights are required. Run Start-WinErrorParser.bat as administrator.')) -ForegroundColor Red
        Write-Host ''
        if (-not $Script:NonInteractive) { Read-Host (L 'Нажмите ENTER для возврата в меню' 'Press ENTER to return to the menu') | Out-Null }
        return
    }

    Write-Host ('  ' + (L 'Внимание: очистка необратима. Перед ней журналы будут экспортированы в .evtx.' 'Warning: clearing is irreversible. Logs will be exported to .evtx first.')) -ForegroundColor Yellow
    Write-Host ('  ' + (L 'Имеет смысл после диагностики и сохранения отчёта.' 'Do this after diagnostics and saving the report.')) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('  1. ' + (L 'Основные журналы (System, Application, Setup)' 'Main logs (System, Application, Setup)'))
    Write-Host ('  2. ' + (L 'Основные + Security' 'Main + Security'))
    Write-Host ('  9. ' + (L 'Все включённые журналы (долго, агрессивно)' 'All enabled logs (slow, aggressive)'))
    Write-Host ('  0. ' + (L 'Назад в меню' 'Back to menu'))
    Write-Host ''
    $mode = '0'
    if ($Script:NonInteractive) {
        Write-Host ('  ' + (L 'Очистка недоступна в -NonInteractive.' 'Log clear is disabled in -NonInteractive.')) -ForegroundColor Yellow
        return
    }
    $mode = Read-Host (L 'Выберите режим очистки' 'Choose a clear mode')

    $logs = @()
    switch ($mode) {
        '1' { $logs = @('System', 'Application', 'Setup') }
        '2' { $logs = @('System', 'Application', 'Setup', 'Security') }
        '9' {
            Write-Host ''
            Write-Host ('  ' + (L 'Это удалит ВСЕ журналы с записями. Для подтверждения введите: ОЧИСТИТЬ ВСЁ' 'This deletes ALL logs that contain records. Type: CLEAR ALL')) -ForegroundColor Red
            $hard = Read-Host (L 'Подтверждение' 'Confirmation')
            $hardOk = @('ОЧИСТИТЬ ВСЁ', 'очистить всё', 'CLEAR ALL', 'clear all') -contains $hard.Trim()
            if (-not $hardOk) {
                Write-Host ('  ' + (L 'Отменено.' 'Cancelled.')) -ForegroundColor DarkYellow
                Start-Sleep -Seconds 2
                return
            }
            try {
                $logs = @(Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
                    Where-Object { $_.IsEnabled -and $_.RecordCount -gt 0 } |
                    Select-Object -ExpandProperty LogName)
            } catch {
                $logs = @('System', 'Application', 'Setup')
            }
        }
        '0' { return }
        default {
            Write-Host ('  ' + (L 'Неверный выбор.' 'Invalid choice.')) -ForegroundColor Red
            Start-Sleep -Seconds 2
            return
        }
    }

    if ($logs.Count -eq 0) {
        Write-Host ('  ' + (L 'Нет журналов для очистки.' 'No logs to clear.')) -ForegroundColor Yellow
        Read-Host (L 'Нажмите ENTER для возврата в меню' 'Press ENTER to return to the menu') | Out-Null
        return
    }

    Write-Host ''
    Write-Host ("  {0}: {1}" -f (L 'Будет очищено журналов' 'Logs to clear'), $logs.Count) -ForegroundColor Yellow
    if ($mode -eq '2') {
        Write-Host ('  ' + (L 'Security: очистка журнала аудита может нарушать политики организации.' 'Security: clearing the audit log may violate organization policy.')) -ForegroundColor Red
    }
    if ($logs.Count -le 15) {
        foreach ($l in $logs) { Write-Host ("    - {0}" -f $l) -ForegroundColor DarkGray }
    } else {
        foreach ($l in ($logs | Select-Object -First 10)) { Write-Host ("    - {0}" -f $l) -ForegroundColor DarkGray }
        Write-Host ("    ... {0} {1}" -f (L 'и ещё' 'and'), ($logs.Count - 10)) -ForegroundColor DarkGray
    }
    Write-Host ''
    $confirm = Read-Host (L 'Для подтверждения введите ДА или YES' 'Type YES or ДА to confirm')

    if (-not (Test-YesAnswer $confirm)) {
        Write-Host ('  ' + (L 'Отменено.' 'Cancelled.')) -ForegroundColor DarkYellow
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ''
    Write-Host ('  ' + (L 'Экспорт .evtx...' 'Exporting .evtx...')) -ForegroundColor Cyan
    [void](Backup-EventLogs -LogNames $logs)
    Write-Host ('  ' + (L 'Очистка...' 'Clearing...')) -ForegroundColor Cyan
    $ok = 0
    $fail = 0
    foreach ($l in $logs) {
        if (Clear-OneEventLog -LogName $l) { $ok++ } else { $fail++ }
    }

    Write-Host ''
    Write-Host ("  {0}. {1}: {2}, {3}: {4}" -f (L 'Готово' 'Done'), (L 'успешно' 'ok'), $ok, (L 'ошибок' 'errors'), $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host ('  ' + (L 'Можно снова запустить диагностику — журнал будет «с чистого листа».' 'You can run diagnostics again — the log will be a clean slate.')) -ForegroundColor DarkGray
    Write-Host ''
    Read-Host (L 'Нажмите ENTER для возврата в меню' 'Press ENTER to return to the menu') | Out-Null
}

function Invoke-Diagnostics {
    Reset-DiagnosticsState
    if (-not $Script:NonInteractive) { Clear-Host }
    Write-Header (L 'АВТОМАТИЧЕСКИЙ АНАЛИЗАТОР ЖЕЛЕЗА И СБОЕВ WINDOWS' 'AUTOMATIC WINDOWS HARDWARE AND CRASH ANALYZER')
    Write-ReportLine ("  WinErrorParser {0}" -f $Script:Version) DarkGray
    Write-ReportLine ("  {0}: {1:dd.MM.yyyy HH:mm:ss}" -f (L 'Дата анализа' 'Analysis date'), (Get-Date)) DarkGray
    Write-ReportLine ("  {0}: {1}" -f (L 'Каталог скрипта' 'Script folder'), $PSScriptRoot) DarkGray
    Write-ReportLine ("  {0}: {1}" -f (L 'Файл отчёта' 'Report file'), $Script:ReportPath) DarkGray
    if ($Script:WriteHtml) {
        Write-ReportLine ("  HTML: {0}" -f $Script:HtmlPath) DarkGray
    }
    Write-ReportLine ("  {0}: ±{1} {2}" -f (L 'Окно корреляции событий' 'Event correlation window'), $Script:WindowMinutes, (L 'мин вокруг критичных' 'min around critical events')) DarkGray
    $modeText = if ($Script:FullReport) { (L 'полный (шум не скрыт)' 'full (noise visible)') } else { (L 'только неисправности (шум скрыт)' 'faults only (noise hidden)') }
    Write-ReportLine ("  {0}: {1}" -f (L 'Режим' 'Mode'), $modeText) DarkGray
    Write-ReportLine ("  {0}: {1}" -f (L 'Язык отчёта' 'Report language'), $Script:Lang) DarkGray

    if (-not (Test-IsAdmin)) {
        Write-ReportLine ''
        Write-ReportLine ('  ' + (L 'ВНИМАНИЕ: скрипт запущен без прав администратора.' 'WARNING: the script is not running as administrator.')) Red
        Write-ReportLine ('  ' + (L 'Часть журналов и устройств может быть недоступна. Запустите Start-WinErrorParser.bat от имени администратора.' 'Some logs and devices may be unavailable. Run Start-WinErrorParser.bat as administrator.')) DarkYellow
    } else {
        Write-ReportLine ('  ' + (L 'Права: администратор — OK' 'Rights: administrator — OK')) Green
    }

    Show-SelfCheck
    Import-EventCache
    Collect-QuickFindings
    Write-QuickVerdict
    Show-SystemInfo
    Step-Progress (L 'Диски' 'Disks')
    Show-DiskHealth
    Step-Progress (L 'Память' 'Memory')
    Show-MemoryStatus
    Step-Progress (L 'Температуры' 'Temperatures')
    Show-Temperatures
    Step-Progress (L 'Питание' 'Power')
    Show-BatteryPower
    Step-Progress (L 'Сон' 'Sleep')
    Show-SleepAndBoot
    Step-Progress 'WHEA'
    Show-Whea
    Step-Progress 'Kernel-Power'
    Show-KernelPower
    Step-Progress 'BSOD'
    Show-BugChecks
    Step-Progress (L 'Диск (события)' 'Disk events')
    Show-DiskEvents
    Step-Progress (L 'Тома / CHKDSK' 'Volumes / CHKDSK')
    Show-VolumeDirty
    Step-Progress 'GPU'
    Show-GpuAndResource
    Step-Progress (L 'Шина USB/PCIe' 'USB/PCIe bus')
    Show-BusEvents
    Step-Progress (L 'Краши приложений' 'App crashes')
    Show-ApplicationCrashes
    Step-Progress (L 'Драйверы' 'Drivers')
    Show-RecentDrivers
    Step-Progress (L 'Обновления' 'Updates')
    Show-UpdateContext
    Step-Progress 'Reliability'
    Show-Reliability
    Step-Progress (L 'Топ ошибок' 'Top errors')
    Show-TopSystemErrors
    Step-Progress (L 'Устройства' 'Devices')
    Show-DeviceProblems
    Step-Progress (L 'Частота' 'Frequency')
    Show-FindingFrequency
    Show-PreviousCompare
    Step-Progress (L 'Анализ' 'Analysis')
    Show-AnalysisAndRecommendations
    Show-Summary

    Write-ReportLine ''
    Write-ReportLine ('=' * 72) Cyan
    Write-ReportLine ('  ' + (L 'Готово. Отчёт выведен на экран и сохранён.' 'Done. The report was printed and saved.')) Cyan
    Write-ReportLine ("  TXT:  {0}" -f $Script:ReportPath) Cyan
    if ($Script:WriteHtml) { Write-ReportLine ("  HTML: {0}" -f $Script:HtmlPath) Cyan }
    Write-ReportLine ('=' * 72) Cyan

    Write-Host ''
    Write-ExecutiveSummaryToConsole
    Prepend-ExecutiveSummaryToBuffers
    Export-CurrentState
    Save-TextReport
    Export-HtmlReport
    if (Copy-SummaryToClipboard) {
        Write-Host ('  ' + (L 'Краткая сводка скопирована в буфер обмена.' 'A short summary was copied to the clipboard.')) -ForegroundColor DarkCyan
    }
    Write-Progress -Activity ("WinErrorParser {0}" -f $Script:Version) -Completed

    Write-Host ''
    if (-not $Script:NonInteractive) {
        try { Read-Host (L 'Нажмите ENTER для возврата в меню' 'Press ENTER to return to the menu') | Out-Null } catch { Start-Sleep -Seconds 3 }
    }
}

function Get-ReportFiles {
    param([string]$Extension = 'txt')
    $filter = 'WinErrorParser_Report_*.' + $Extension
    return @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter $filter -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
}

function Show-RecentReports {
    Clear-Host
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host ('  ' + (L 'Последние отчёты в папке скрипта' 'Recent reports in the script folder')) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
    $txts = @(Get-ReportFiles 'txt' | Select-Object -First 8)
    if ($txts.Count -eq 0) {
        Write-Host ('  ' + (L 'Отчётов ещё нет — сначала запустите диагностику.' 'No reports yet — run diagnostics first.')) -ForegroundColor Yellow
    } else {
        $i = 1
        foreach ($f in $txts) {
            $html = [System.IO.Path]::ChangeExtension($f.FullName, 'html')
            $mark = ''
            if (Test-Path -LiteralPath $html) { $mark = ' + HTML' }
            Write-Host ("  {0}. {1:dd.MM HH:mm}  {2}{3}" -f $i, $f.LastWriteTime, $f.Name, $mark)
            $i++
        }
        Write-Host ''
        $raw = Read-Host (L 'Номер отчёта, чтобы открыть HTML (Enter — назад)' 'Report number to open HTML (Enter — back)')
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $txts.Count) {
            $html = [System.IO.Path]::ChangeExtension($txts[$n - 1].FullName, 'html')
            if (Test-Path -LiteralPath $html) {
                Start-Process -FilePath $html
            } else {
                Start-Process -FilePath $txts[$n - 1].FullName
            }
            return
        }
    }
    try { Read-Host (L 'Нажмите ENTER' 'Press ENTER') | Out-Null } catch {}
}

function Open-LastHtmlReport {
    $htmls = @(Get-ReportFiles 'html')
    if ($htmls.Count -eq 0) {
        Write-Host ('  ' + (L 'HTML-отчётов нет — сначала диагностика.' 'No HTML reports — run diagnostics first.')) -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }
    Start-Process -FilePath $htmls[0].FullName
}

function Export-LastReportZip {
    $txts = @(Get-ReportFiles 'txt')
    if ($txts.Count -eq 0) {
        Write-Host ('  ' + (L 'Нечего упаковывать — отчётов нет.' 'Nothing to pack — no reports.')) -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }
    $txt = $txts[0]
    $html = [System.IO.Path]::ChangeExtension($txt.FullName, 'html')
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $zip = Join-Path $PSScriptRoot ("WinErrorParser_Pack_{0}.zip" -f $stamp)
    $items = @($txt.FullName)
    if (Test-Path -LiteralPath $html) { $items += $html }
    try {
        Compress-Archive -Path $items -DestinationPath $zip -Force
        Write-Host ("  {0}: {1}" -f (L 'Готово, архив' 'Done, archive'), $zip) -ForegroundColor Green
    } catch {
        Write-Host ("  {0}: {1}" -f (L 'Не удалось упаковать' 'Could not pack'), $_.Exception.Message) -ForegroundColor Red
    }
    Start-Sleep -Seconds 2
}

function Show-SettingsHint {
    Write-Host ("    {0}: {1} {2}  |  {3}: {4}  |  {5}: {6}" -f (L 'Период' 'Period'), $Script:DaysBack, (L 'дн.' 'days'), (L 'режим' 'mode'), $(if ($Script:FullReport) { (L 'полный' 'full') } else { (L 'неисправности' 'faults') }), (L 'язык' 'language'), $Script:Lang) -ForegroundColor DarkGray
}

function Invoke-PeriodMenu {
    Clear-Host
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host ('  ' + (L 'За какой срок искать ошибки?' 'How far back should we look?')) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('  ' + (L 'Скрипт просматривает журналы Windows за выбранное время.' 'The script reads Windows logs for the time you pick.')) -ForegroundColor DarkGray
    Write-Host ("  {0}: {1} {2}" -f (L 'Сейчас выбрано' 'Currently selected'), $Script:DaysBack, (L 'дн.' 'days')) -ForegroundColor Yellow
    Write-Host ''
    Write-Host ('  1. ' + (L 'Последние 3 дня' 'Last 3 days'))
    Write-Host ('  2. ' + (L 'Последняя неделя (7 дней)' 'Last week (7 days)'))
    Write-Host ('  3. ' + (L 'Последние 2 недели (14 дней)' 'Last 2 weeks (14 days)'))
    Write-Host ('  4. ' + (L 'Последний месяц (30 дней)' 'Last month (30 days)'))
    Write-Host ('  5. ' + (L 'Последние 3 месяца (90 дней)' 'Last 3 months (90 days)'))
    Write-Host ('  6. ' + (L 'Указать своё число дней' 'Enter a custom number of days'))
    Write-Host ('  0. ' + (L 'Назад, ничего не менять' 'Back, keep current setting'))
    Write-Host ''
    $c = Read-Host (L 'Введите номер пункта (1-6)' 'Enter an item number (1-6)')
    switch ($c) {
        '1' { $Script:DaysBack = 3 }
        '2' { $Script:DaysBack = 7 }
        '3' { $Script:DaysBack = 14 }
        '4' { $Script:DaysBack = 30 }
        '5' { $Script:DaysBack = 90 }
        '6' {
            $raw = Read-Host (L 'Сколько дней смотреть? Число от 1 до 3650' 'How many days? Number from 1 to 3650')
            $n = 0
            if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le 3650) {
                $Script:DaysBack = $n
            } else {
                Write-Host ('  ' + (L 'Неверное число, период не изменён.' 'Invalid number, period unchanged.')) -ForegroundColor Red
                Start-Sleep -Seconds 2
                return
            }
        }
        '0' { return }
        default {
            Write-Host ('  ' + (L 'Нет такого пункта.' 'No such item.')) -ForegroundColor Red
            Start-Sleep -Seconds 2
            return
        }
    }
    $Script:StartDate = (Get-Date).AddDays(-$Script:DaysBack)
    Write-Host ''
    Write-Host ("  {0}: {1} {2}." -f (L 'Готово. Будем смотреть журналы за' 'Done. Logs will be checked for'), $Script:DaysBack, (L 'дн.' 'days')) -ForegroundColor Green
    Start-Sleep -Seconds 1
}

function Show-MainMenu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 72) -ForegroundColor Cyan
        Write-Host ("  WinErrorParser {0} — {1}" -f $Script:Version, (L 'меню' 'menu')) -ForegroundColor Cyan
        Write-Host ('=' * 72) -ForegroundColor Cyan
        Write-Host ''
        if (Test-IsAdmin) {
            Write-Host ('  ' + (L 'Права: администратор — OK' 'Rights: administrator — OK')) -ForegroundColor Green
        } else {
            Write-Host ('  ' + (L 'Права: нет администратора (очистка журналов и часть диагностики недоступны)' 'Rights: not administrator (log clear and some diagnostics are unavailable)')) -ForegroundColor Yellow
        }
        Show-SettingsHint
        Write-Host ''
        Write-Host ('  1. ' + (L 'Диагностика ПК (журнал + железо)' 'PC diagnostics (logs + hardware)'))
        Write-Host ('  2. ' + (L 'Очистка журналов событий' 'Clear event logs'))
        Write-Host ('  3. ' + (L 'За какой срок искать ошибки' 'How far back to look') + (" ({0} {1})" -f $Script:DaysBack, (L 'дн.' 'days')))
        Write-Host ('  4. ' + (L 'Режим отчёта' 'Report mode') + ': ' + $(if ($Script:FullReport) { (L 'полный' 'full') } else { (L 'только неисправности' 'faults only') }))
        Write-Host ('  5. ' + (L 'Язык отчёта' 'Report language') + ': ' + $Script:Lang)
        Write-Host ('  6. ' + (L 'Открыть последний HTML-отчёт' 'Open the last HTML report'))
        Write-Host ('  7. ' + (L 'Последние отчёты' 'Recent reports'))
        Write-Host ('  8. ' + (L 'Упаковать последний отчёт в ZIP' 'Pack the last report into a ZIP'))
        Write-Host ('  0. ' + (L 'Выход' 'Exit'))
        Write-Host ''
        $choice = Read-Host (L 'Выберите пункт' 'Choose an item')

        switch ($choice) {
            '1' { Invoke-Diagnostics }
            '2' { Invoke-ClearEventLogs }
            '3' { Invoke-PeriodMenu }
            '4' { $Script:FullReport = -not $Script:FullReport }
            '5' { $Script:Lang = $(if ($Script:Lang -eq 'ru') { 'en' } else { 'ru' }) }
            '6' { Open-LastHtmlReport }
            '7' { Show-RecentReports }
            '8' { Export-LastReportZip }
            '0' { return }
            default {
                Write-Host ('  ' + (L 'Неверный выбор.' 'Invalid choice.')) -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Главный поток
# ---------------------------------------------------------------------------
if ($Action -eq 'Diagnose' -or $Script:NonInteractive) {
    Invoke-Diagnostics
} else {
    Show-MainMenu
}
