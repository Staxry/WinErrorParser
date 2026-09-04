#Requires -Version 5.1
# Encoding: UTF-8 with BOM (обязательно для Windows PowerShell 5.1 + кириллица)
# Диагностика ПК Windows — отчёт на русском (терминал + файл)
# Запуск: от имени администратора через Start-WinErrorParser.bat

$ErrorActionPreference = 'Continue'
try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue } catch {}

# UTF-8 в консоли и для файла отчёта
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    chcp 65001 | Out-Null
} catch {}

$Script:DaysBack = 14
$Script:StartDate = (Get-Date).AddDays(-$Script:DaysBack)
$Script:ReportPath = Join-Path $PSScriptRoot 'WinErrorParser_Report_RU.txt'
$Script:Report = New-Object System.Text.StringBuilder
$Script:IssueCount = 0
$Script:CriticalCount = 0

# ---------------------------------------------------------------------------
# База пояснений по источникам событий Windows (ProviderName)
# ---------------------------------------------------------------------------
$Script:ErrorExplain = @{
    # --- Диск / хранилище ---
    'disk' = @{
        Title = 'Ошибка диска / контроллера накопителя'
        Text  = 'Система потеряла связь с физическим диском (SSD/HDD) или его контроллером. Типичные причины: плохой кабель/разъём M.2, перегрев NVMe, сбой прошивки SSD, нестабильное питание. Часто приводит к зависаниям и внезапным перезагрузкам.'
        Level = 'Critical'
    }
    'ntfs' = @{
        Title = 'Ошибка файловой системы NTFS'
        Text  = 'Проблемы чтения/записи тома NTFS: повреждённые метаданные, сбой диска или некорректное отключение. Рекомендуется chkdsk /f и проверка здоровья накопителя.'
        Level = 'Warning'
    }
    'volmgr' = @{
        Title = 'Диспетчер томов (сбой дампа памяти)'
        Text  = 'Windows не смогла записать дамп при сбое: том или диск исчезли в момент краша. Часто сопровождает внезапное отключение SSD или Kernel-Power 41.'
        Level = 'Critical'
    }
    'iaStor' = @{
        Title = 'Драйвер Intel Rapid Storage (RST)'
        Text  = 'Сбой драйвера Intel RST / AHCI. Обновите RST/чипсет, проверьте режим SATA в BIOS и кабели/слоты накопителей.'
        Level = 'Warning'
    }
    'iaStorV' = @{
        Title = 'Драйвер Intel RST (iaStorV)'
        Text  = 'Ошибки виртуального драйвера Intel Storage. Обновите пакет Intel RST и прошивку SSD.'
        Level = 'Warning'
    }
    'stornvme' = @{
        Title = 'Драйвер NVMe (Windows)'
        Text  = 'Сбой встроенного NVMe-драйвера. Возможны перегрев M.2, несовместимая прошивка SSD или проблемы слота PCIe.'
        Level = 'Critical'
    }
    'storahci' = @{
        Title = 'Драйвер AHCI'
        Text  = 'Ошибки AHCI-контроллера. Проверьте кабели SATA, питание и обновите драйвер чипсета.'
        Level = 'Warning'
    }
    'partmgr' = @{
        Title = 'Диспетчер разделов'
        Text  = 'Проблемы с таблицей разделов или доступом к разделам. Может указывать на повреждение диска или конфликт инструментов разметки.'
        Level = 'Warning'
    }
    'Virtual Disk Service' = @{
        Title = 'Служба виртуальных дисков'
        Text  = 'Сбой VDS при работе с дисками/томами. Проверьте диспетчер дисков и состояние накопителей.'
        Level = 'Info'
    }

    # --- Питание / ядро ---
    'Microsoft-Windows-Kernel-Power' = @{
        Title = 'Ядро: питание / внезапная перезагрузка'
        Text  = 'Система выключилась или перезагрузилась без корректного завершения. Event ID 41 — критический признак: питание пропало мгновенно (БП, батарея, отвал SSD, зависание CPU/GPU, перегрев).'
        Level = 'Critical'
    }
    'Microsoft-Windows-Kernel-Processor-Power' = @{
        Title = 'Питание процессора'
        Text  = 'Аномалии C-states / парковки ядер / энергосбережения CPU. Обновите BIOS и драйвер чипсета; отключите агрессивные режимы экономии для проверки.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Kernel-General' = @{
        Title = 'Общие события ядра'
        Text  = 'События запуска/останова и сбоев ядра. Вместе с BugCheck указывают на BSOD или аварийную перезагрузку.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Kernel-Boot' = @{
        Title = 'Загрузка ядра'
        Text  = 'Проблемы на этапе загрузки Windows. Проверьте BCD, Secure Boot, повреждения системного раздела.'
        Level = 'Warning'
    }
    'EventLog' = @{
        Title = 'Журнал событий'
        Text  = 'Служба журнала зафиксировала аномалию (часто после жёсткой перезагрузки журнал «грязно» закрыт). Само по себе не причина, а следствие сбоя.'
        Level = 'Info'
    }

    # --- WHEA / железо ---
    'Microsoft-Windows-WHEA-Logger' = @{
        Title = 'WHEA: аппаратная ошибка'
        Text  = 'Windows Hardware Error Architecture: сбой CPU, RAM, PCIe или устройства. Event ID 1/2 — исправленные ошибки; 17/18/19 — серьёзные аппаратные. Часто RAM, перегрев CPU, нестабильный разгон, сбой PCIe/NVMe.'
        Level = 'Critical'
    }
    'Microsoft-Windows-HAL' = @{
        Title = 'HAL (уровень абстракции оборудования)'
        Text  = 'Проблемы взаимодействия ОС с железом. Проверьте BIOS, совместимость и целостность системных файлов (sfc /scannow).'
        Level = 'Warning'
    }

    # --- BSOD / отчёты ---
    'Microsoft-Windows-WER-SystemErrorReporting' = @{
        Title = 'Отчёт о системной ошибке (BSOD)'
        Text  = 'Windows Error Reporting зафиксировал критический сбой системы (синий экран). Смотрите код BugCheck и минидампы в C:\Windows\Minidump. Частые причины: драйверы, RAM, диск, перегрев.'
        Level = 'Critical'
    }
    'BugCheck' = @{
        Title = 'Синий экран (BugCheck)'
        Text  = 'Зафиксирован код STOP/BugCheck. Анализ: WinDbg или BlueScreenView по файлам в Minidump. Запишите код ошибки из описания события.'
        Level = 'Critical'
    }
    'Microsoft-Windows-WindowsUpdateClient' = @{
        Title = 'Клиент Центра обновления Windows'
        Text  = 'Сбой загрузки/установки обновлений: повреждён кэш SoftwareDistribution, конфликт антивируса, нехватка места, сбой службы wuauserv/BITS, проблемы с сетью или каталогом обновлений. Диагностика: net stop wuauserv → очистка C:\Windows\SoftwareDistribution\Download → net start wuauserv; либо средство устранения неполадок «Центр обновления».'
        Level = 'Warning'
    }
    'Microsoft-Windows-Application-Experience' = @{
        Title = 'Совместимость приложений'
        Text  = 'Проблемы совместимости ПО с текущей версией Windows. Обновите программу или включите режим совместимости.'
        Level = 'Info'
    }

    # --- Службы ---
    'Service Control Manager' = @{
        Title = 'Диспетчер управления службами'
        Text  = 'Служба не запустилась, зависла или завершилась с ошибкой (зависимости, права, повреждённый исполняемый файл, таймаут). Частые Event ID: 7000/7001/7023/7031/7034. Проверьте службы.msc и журнал Application.'
        Level = 'Warning'
    }
    'Service Control Manager 1' = @{
        Title = 'Диспетчер служб'
        Text  = 'Ошибка запуска или остановки службы Windows.'
        Level = 'Warning'
    }

    # --- Драйверы / PnP ---
    'Microsoft-Windows-DriverFrameworks-UserMode' = @{
        Title = 'Пользовательский фреймворк драйверов (UMDF)'
        Text  = 'Сбой user-mode драйвера (часто USB, принтеры, сканеры). Обновите/переустановите драйвер устройства.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Kernel-PnP' = @{
        Title = 'Plug and Play'
        Text  = 'Ошибка установки/запуска устройства: конфликт ресурсов, повреждённый драйвер, устройство отключилось. Смотрите Диспетчер устройств на жёлтые значки.'
        Level = 'Warning'
    }
    'Microsoft-Windows-UserPnp' = @{
        Title = 'Установка устройств (UserPnp)'
        Text  = 'Сбой установки драйвера устройства. Загрузите драйвер с сайта производителя (не через случайный «драйвер-пак»).'
        Level = 'Warning'
    }
    'Display' = @{
        Title = 'Подсистема дисплея'
        Text  = 'Сбой видеодрайвера или адаптера. Обновите драйвер GPU (чистая установка), проверьте перегрев и кабель монитора.'
        Level = 'Warning'
    }
    'nvlddmkm' = @{
        Title = 'Драйвер NVIDIA'
        Text  = 'Падение драйвера NVIDIA (часто TDR: «видеодрайвер перестал отвечать»). Обновите/откатитесь; при повторе — проверка GPU, питания и перегрева.'
        Level = 'Critical'
    }
    'amdkmdag' = @{
        Title = 'Драйвер AMD'
        Text  = 'Сбой драйвера AMD Graphics. Чистая переустановка Adrenalin; проверьте температуры и стабильность GPU.'
        Level = 'Critical'
    }
    'igfx' = @{
        Title = 'Драйвер Intel Graphics'
        Text  = 'Сбой интегрированной графики Intel. Обновите драйвер с сайта Intel/производителя ноутбука.'
        Level = 'Warning'
    }

    # --- Сеть ---
    'Tcpip' = @{
        Title = 'Стек TCP/IP'
        Text  = 'Сетевые ошибки IP: дубли адресов, сброс интерфейса, проблемы маршрутизации. Проверьте адаптер, драйвер NIC и netsh winsock reset (осторожно).'
        Level = 'Warning'
    }
    'e1dexpress' = @{
        Title = 'Сетевой адаптер Intel Ethernet'
        Text  = 'Сбой драйвера Intel Ethernet. Обновите драйвер NIC; проверьте кабель и энергосбережение адаптера.'
        Level = 'Warning'
    }
    'Netwtw' = @{
        Title = 'Беспроводной адаптер Intel Wi-Fi'
        Text  = 'Ошибки Intel Wireless. Обновите Wi-Fi драйвер; отключите «разрешить отключение для экономии энергии» в свойствах устройства.'
        Level = 'Warning'
    }
    'Microsoft-Windows-NDIS' = @{
        Title = 'NDIS (сетевой стек)'
        Text  = 'Сбой сетевого драйвера на уровне NDIS. Переустановите драйвер сетевой карты.'
        Level = 'Warning'
    }
    'Microsoft-Windows-DHCP-Client' = @{
        Title = 'Клиент DHCP'
        Text  = 'Не получен IP-адрес от DHCP. Проверьте роутер, кабель/Wi-Fi и службу Dhcp.'
        Level = 'Warning'
    }
    'Microsoft-Windows-DNS-Client' = @{
        Title = 'Клиент DNS'
        Text  = 'Не удалось разрешить имя хоста. Смените DNS (например 1.1.1.1 / 8.8.8.8) или проверьте роутер.'
        Level = 'Info'
    }
    'NetBT' = @{
        Title = 'NetBIOS через TCP/IP'
        Text  = 'Конфликт имён NetBIOS или проблемы локальной сети. Обычно некритично для домашнего ПК.'
        Level = 'Info'
    }
    'Server' = @{
        Title = 'Служба Server (общий доступ)'
        Text  = 'Ошибки файлового/принтерного общего доступа. Проверьте службу LanmanServer и брандмауэр.'
        Level = 'Info'
    }

    # --- Память / .NET / приложения ---
    'Microsoft-Windows-MemoryDiagnostics-Results' = @{
        Title = 'Диагностика памяти Windows'
        Text  = 'Результат проверки ОЗУ. Если найдены ошибки — замените модуль RAM или проверьте слоты/XMP.'
        Level = 'Critical'
    }
    '.NET Runtime' = @{
        Title = 'Среда .NET'
        Text  = 'Сбой приложения на .NET. Переустановите .NET Runtime / Visual C++ Redistributable или само приложение.'
        Level = 'Info'
    }
    'Application Error' = @{
        Title = 'Ошибка приложения'
        Text  = 'Программа аварийно завершилась (faulting module). Обновите ПО; при system-модулях — sfc /scannow и проверка RAM.'
        Level = 'Warning'
    }
    'Application Hang' = @{
        Title = 'Зависание приложения'
        Text  = 'Программа перестала отвечать. Может быть связано с диском, драйверами или нехваткой памяти.'
        Level = 'Info'
    }
    'SideBySide' = @{
        Title = 'Side-by-Side (Visual C++)'
        Text  = 'Отсутствует нужный Visual C++ Redistributable. Установите актуальные пакеты VC++ x86/x64 с сайта Microsoft.'
        Level = 'Warning'
    }
    'Windows Error Reporting' = @{
        Title = 'Отчёты об ошибках Windows'
        Text  = 'Система собрала отчёт о сбое приложения или компонента. Смотрите связанное событие Application Error.'
        Level = 'Info'
    }

    # --- Безопасность / защита ---
    'Microsoft-Windows-Windows Defender' = @{
        Title = 'Защитник Windows'
        Text  = 'События антивируса: угрозы, сбой обновления сигнатур или службы. Проверьте историю защиты в «Безопасность Windows».'
        Level = 'Warning'
    }
    'Microsoft-Windows-Security-SPP' = @{
        Title = 'Лицензирование Windows (SPP)'
        Text  = 'Проблемы активации/лицензии. Проверьте состояние: slmgr /xpr'
        Level = 'Info'
    }
    'Microsoft-Windows-CodeIntegrity' = @{
        Title = 'Целостность кода'
        Text  = 'Заблокирован неподписанный или повреждённый драйвер/модуль. Удалите сомнительное ПО и обновите драйверы.'
        Level = 'Warning'
    }
    'Microsoft-Windows-FilterManager' = @{
        Title = 'Диспетчер фильтров'
        Text  = 'Сбой мини-фильтра ФС (антивирус, шифрование, бэкап). Часто конфликт стороннего фильтра с диском.'
        Level = 'Warning'
    }

    # --- Аудио / USB / прочее ---
    'Microsoft-Windows-Audio' = @{
        Title = 'Аудиоподсистема'
        Text  = 'Сбой звукового стека. Обновите аудиодрайвер Realtek/производителя; перезапустите службу Windows Audio.'
        Level = 'Info'
    }
    'USB' = @{
        Title = 'Шина USB'
        Text  = 'Ошибка устройства USB: отвал порта, нехватка питания, плохой кабель. Отключите энергосбережение USB Root Hub.'
        Level = 'Warning'
    }
    'Microsoft-Windows-USB-USBXHCI' = @{
        Title = 'Контроллер USB xHCI'
        Text  = 'Сбой USB 3.x контроллера. Обновите чипсет/BIOS; проверьте устройства на портах.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Time-Service' = @{
        Title = 'Служба времени'
        Text  = 'Проблемы синхронизации часов. Проверьте интернет и w32tm /resync.'
        Level = 'Info'
    }
    'Microsoft-Windows-DistributedCOM' = @{
        Title = 'DCOM'
        Text  = 'Ошибки распределённой COM (часто права доступа к приложению). Обычно шум в журнале; критично только при сбоях конкретной службы.'
        Level = 'Info'
    }
    'Microsoft-Windows-PerfNet' = @{
        Title = 'Счётчики производительности сети'
        Text  = 'Сбой счётчиков PerfNet. Редко влияет на работу ПК; lodctr /r при необходимости.'
        Level = 'Info'
    }
    'Microsoft-Windows-Resource-Exhaustion-Detector' = @{
        Title = 'Исчерпание ресурсов'
        Text  = 'Заканчивается ОЗУ или ресурсы системы. Закройте тяжёлые программы; проверьте утечки памяти и объём RAM.'
        Level = 'Critical'
    }
    'Microsoft-Windows-Resource-Exhaustion-Resolver' = @{
        Title = 'Реакция на нехватку ресурсов'
        Text  = 'Система пыталась освободить память из-за исчерпания ресурсов.'
        Level = 'Warning'
    }
    'Microsoft-Windows-Wininit' = @{
        Title = 'Инициализация Windows'
        Text  = 'События автозапуска/инициализации. Вместе с chkdsk может указывать на проверку диска при загрузке.'
        Level = 'Info'
    }
    'Microsoft-Windows-Winlogon' = @{
        Title = 'Вход в систему'
        Text  = 'Проблемы оболочки входа. Проверьте автозагрузку и повреждённые профили пользователей.'
        Level = 'Info'
    }
    'Schannel' = @{
        Title = 'Безопасный канал (TLS/SSL)'
        Text  = 'Ошибки TLS при защищённых соединениях. Обновите Windows; проверьте дату/время и корневые сертификаты.'
        Level = 'Info'
    }
    'Microsoft-Windows-TPM-WMI' = @{
        Title = 'Модуль TPM'
        Text  = 'События TPM (BitLocker, Windows Hello). При ошибках проверьте TPM в BIOS и tpm.msc.'
        Level = 'Info'
    }
    'Microsoft-Windows-Hyper-V-Hypervisor' = @{
        Title = 'Гипервизор Hyper-V'
        Text  = 'Сбой Hyper-V / виртуализации. Конфликт с другими гипервизорами (VMware, VirtualBox, Android-эмуляторы).'
        Level = 'Warning'
    }
    'Microsoft-Windows-Kernel-EventTracing' = @{
        Title = 'Трассировка событий ядра'
        Text  = 'Проблемы ETW-сессий. Обычно некритично.'
        Level = 'Info'
    }
    'Microsoft-Windows-Diagnostics-Performance' = @{
        Title = 'Диагностика производительности'
        Text  = 'Медленный запуск/завершение работы. Смотрите «Монитор ресурсов» и автозагрузку.'
        Level = 'Info'
    }
}

# Пояснения по конкретным Event ID (ключ: "Provider|Id")
$Script:EventIdExplain = @{
    'Microsoft-Windows-Kernel-Power|41' = 'Критическая внезапная перезагрузка: система не завершилась штатно. Часто SSD/NVMe, БП, перегрев, зависание драйвера.'
    'Microsoft-Windows-Kernel-Power|42' = 'Система перешла в спящий режим (не всегда ошибка).'
    'Microsoft-Windows-Kernel-Power|109' = 'Инициировано завершение работы ядром (часто обновление или штатный shutdown).'
    'Microsoft-Windows-Kernel-Power|172' = 'Проблема с батареей/источником питания ноутбука.'
    'Microsoft-Windows-WHEA-Logger|1'  = 'Исправленная аппаратная ошибка (Corrected). При частых повторах — RAM/CPU/перегрев.'
    'Microsoft-Windows-WHEA-Logger|2'  = 'Исправленная ошибка (часто память или кэш). Запустите mdsched.exe.'
    'Microsoft-Windows-WHEA-Logger|3'  = 'Неустранимая аппаратная ошибка (PCI Express / устройство). Часто NVMe, GPU, PCIe-устройство.'
    'Microsoft-Windows-WHEA-Logger|17' = 'WHEA: фатальная ошибка процессора/чипа.'
    'Microsoft-Windows-WHEA-Logger|18' = 'WHEA: фатальная ошибка инициализирована ОС.'
    'Microsoft-Windows-WHEA-Logger|19' = 'WHEA: исправленная ошибка с подробностями устройства.'
    'disk|7'  = 'Устройство не готово / таймаут диска — классический признак отвала HDD/SSD.'
    'disk|11' = 'Контроллер обнаружил ошибку на диске (CRC/сбой чтения).'
    'disk|15' = 'Диск недоступен (устройство не существует).'
    'disk|51' = 'Ошибка страничного файла / ввода-вывода на диске.'
    'disk|153' = 'Повторная операция ввода-вывода на диске (IO retry) — накопитель отвечает с задержками.'
    'ntfs|55' = 'Повреждение структуры NTFS на томе.'
    'ntfs|98' = 'Том повреждён и требует chkdsk.'
    'volmgr|46' = 'Сбой записи crash dump — том недоступен в момент краша.'
    'BugCheck|1001' = 'Синий экран: в описании события указан код BugCheck и параметры.'
    'Microsoft-Windows-WER-SystemErrorReporting|1001' = 'Зарегистрирован отчёт о BugCheck/BSOD. Откройте событие для кода STOP.'
    'Service Control Manager|7000' = 'Служба не запустилась (ошибка в параметре запуска или файле).'
    'Service Control Manager|7001' = 'Зависимая служба не запущена — каскадный сбой.'
    'Service Control Manager|7009' = 'Таймаут ожидания ответа службы.'
    'Service Control Manager|7023' = 'Служба завершилась с ошибкой.'
    'Service Control Manager|7024' = 'Служба завершилась со специфическим кодом ошибки.'
    'Service Control Manager|7031' = 'Служба неожиданно завершилась и будет перезапущена.'
    'Service Control Manager|7034' = 'Служба аварийно завершилась.'
    'Microsoft-Windows-WindowsUpdateClient|20' = 'Сбой установки обновления.'
    'Microsoft-Windows-WindowsUpdateClient|24' = 'Установка обновления отменена / не завершена.'
    'Microsoft-Windows-WindowsUpdateClient|25' = 'Сбой удаления обновления.'
    'Microsoft-Windows-WindowsUpdateClient|31' = 'Сбой загрузки обновления (сеть, кэш, место на диске).'
    'Microsoft-Windows-WindowsUpdateClient|33' = 'Не удалось запустить установку обновления.'
    'Microsoft-Windows-WindowsUpdateClient|34' = 'Ошибка скачивания: проверьте интернет и службы BITS/wuauserv.'
    'Microsoft-Windows-WindowsUpdateClient|213' = 'Сбой проверки обновлений (часто временный сбой сервиса Microsoft).'
    'Microsoft-Windows-Kernel-PnP|219' = 'Драйвер не загрузился вовремя (часто диск/фильтр при старте).'
    'Microsoft-Windows-Kernel-PnP|411' = 'Устройство отключено из-за ошибки.'
    'Display|4101' = 'Timeout Detection and Recovery (TDR): видеодрайвер сброшен.'
    'Application Error|1000' = 'Аварийное завершение процесса — смотрите имя модуля в деталях.'
    'Microsoft-Windows-Resource-Exhaustion-Detector|2004' = 'Система испытывает нехватку виртуальной памяти / commit.'
}

# GUID компонентов WHEA → понятное имя
$Script:WheaGuidMap = @{
    'D1A87C46B57E445B8B2E014E73D69D8B' = 'Шина PCI Express / NVMe M.2 SSD'
    'CBA52B40-73AE-4BFE-8A6D-8F5C4C5A5B5A' = 'Процессор (CPU)'
    '5C583C0D-A2A3-4F0B-8A5B-0E0E0E0E0E0E' = 'Память (RAM)'
}


# Источники, которые обычно НЕ ломают ПК (шум журнала) — в отчёт не выводим
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

# Провайдеры, важные для неисправностей (для топа и корреляции)
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

$Script:Findings = New-Object System.Collections.ArrayList
$Script:WindowMinutes = 5

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

function Test-IsNoiseProvider {
    param([string]$Provider)
    if ([string]::IsNullOrWhiteSpace($Provider)) { return $true }
    foreach ($n in $Script:NoiseProviders) {
        if ($Provider -eq $n -or $Provider -like "$n*") { return $true }
    }
    # Службы обновления / телеметрии в SCM-сообщениях отсекаем на уровне топа целиком для SCM
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
    if ($Script:ErrorExplain.ContainsKey($Provider)) {
        return $Script:ErrorExplain[$Provider]
    }
    foreach ($key in $Script:ErrorExplain.Keys) {
        if ($Provider -like "$key*") {
            return $Script:ErrorExplain[$key]
        }
    }
    return $null
}

function Get-EventIdExplain {
    param([string]$Provider, [int]$Id)
    $key = "$Provider|$Id"
    if ($Script:EventIdExplain.ContainsKey($key)) {
        return $Script:EventIdExplain[$key]
    }
    return $null
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
        Write-ReportLine ("    ПОЯСНЕНИЕ [{0}]: {1}" -f $info.Title, $info.Text) $color
        if (-not $QuietCount) {
            if ($info.Level -eq 'Critical') { $Script:CriticalCount++ }
            $Script:IssueCount++
        }
    }
    elseif ($idText) {
        Write-ReportLine ("    ПОЯСНЕНИЕ: {0}" -f $idText) DarkYellow
        if (-not $QuietCount) { $Script:IssueCount++ }
    }
    else {
        Write-ReportLine ("    ПОЯСНЕНИЕ: Источник «{0}» связан с неисправностью. Смотрите текст события в eventvwr.msc." -f $Provider) DarkGray
        if (-not $QuietCount) { $Script:IssueCount++ }
    }

    if ($idText -and $info) {
        Write-ReportLine ("    ПО EVENT ID {0}: {1}" -f $EventId, $idText) DarkCyan
    }
}

function Add-Finding {
    param(
        [string]$Kind,
        [datetime]$Time,
        [string]$Title,
        [string]$Detail = '',
        $Event = $null,
        [string[]]$Tags = @()
    )
    [void]$Script:Findings.Add([pscustomobject]@{
        Kind   = $Kind
        Time   = $Time
        Title  = $Title
        Detail = $Detail
        Event  = $Event
        Tags   = $Tags
    })
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-SafeWinEvents {
    param([hashtable]$Filter, [int]$Max = 50)
    try {
        return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Get-ShortMessage {
    param($Event, [int]$MaxLen = 160)
    if (-not $Event -or -not $Event.Message) { return '(нет текста)' }
    $msg = ($Event.Message -replace '\s+', ' ').Trim()
    if ($msg.Length -gt $MaxLen) { return $msg.Substring(0, $MaxLen) + '…' }
    return $msg
}

function Resolve-WheaComponent {
    param($Event)
    $name = 'Неизвестный компонент устройства'
    try {
        if ($Event.Properties -and $Event.Properties.Count -gt 0) {
            foreach ($prop in $Event.Properties) {
                $val = $prop.Value
                if ($val -is [byte[]] -and $val.Length -ge 16) {
                    $hex = ($val | ForEach-Object { '{0:X2}' -f $_ }) -join ''
                    foreach ($g in $Script:WheaGuidMap.Keys) {
                        if ($hex -match $g) { return $Script:WheaGuidMap[$g] }
                    }
                    if ($hex -match 'D1A87C46B57E445B8B2E014E73D69D8B') {
                        return 'Шина PCI Express / NVMe M.2 SSD'
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
        if ($Event.Message -match 'memory|памят') { return 'Оперативная память (RAM)' }
        if ($Event.Message -match 'processor|процесс') { return 'Процессор (CPU)' }
    } catch {}
    return $name
}

function Show-EventWindow {
    param(
        [Parameter(Mandatory)][datetime]$CenterTime,
        [string]$AnchorLabel = 'критическое событие',
        [int]$Minutes = 5
    )
    $from = $CenterTime.AddMinutes(-$Minutes)
    $to = $CenterTime.AddMinutes($Minutes)
    Write-ReportLine ("    ▸ Анализ журнала ±{0} мин вокруг {1:dd.MM.yyyy HH:mm:ss} ({2})" -f $Minutes, $CenterTime, $AnchorLabel) Cyan

    $nearby = Get-SafeWinEvents -Filter @{
        LogName   = 'System'
        StartTime = $from
        EndTime   = $to
        Level     = @(1, 2, 3)
    } -Max 120

    if ($nearby.Count -eq 0) {
        Write-ReportLine '      В окне ±5 мин нет записей Error/Warning/Critical (или журнал пуст).' DarkGray
        Write-ReportLine '      Это бывает, если система обесточилась мгновенно и не успела записать причину.' DarkGray
        return @()
    }

    $filtered = @($nearby | Where-Object { -not (Test-IsNoiseProvider $_.ProviderName) } | Sort-Object TimeCreated)
    if ($filtered.Count -eq 0) {
        Write-ReportLine '      В окне были только «шумные» события (обновления/DCOM/DNS и т.п.) — они отфильтрованы.' DarkGray
        return @()
    }

    $before = @($filtered | Where-Object { $_.TimeCreated -lt $CenterTime })
    $after  = @($filtered | Where-Object { $_.TimeCreated -gt $CenterTime })
    $same   = @($filtered | Where-Object { [math]::Abs(($_.TimeCreated - $CenterTime).TotalSeconds) -lt 2 })

    Write-ReportLine ("      Найдено связанных записей (без шума): {0} | до: {1} | после: {2}" -f $filtered.Count, $before.Count, $after.Count) DarkCyan

    if ($before.Count -gt 0) {
        Write-ReportLine '      —— ДО события (возможные причины) ——' DarkYellow
        foreach ($ev in ($before | Select-Object -Last 12)) {
            $delta = [int]($CenterTime - $ev.TimeCreated).TotalSeconds
            $line = "      [{0:HH:mm:ss}] (-{1} с) {2} ID {3}: {4}" -f $ev.TimeCreated, $delta, $ev.ProviderName, $ev.Id, (Get-ShortMessage $ev 120)
            $col = if (Test-IsRelevantProvider $ev.ProviderName) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray }
            Write-ReportLine $line $col
        }
    } else {
        Write-ReportLine '      ДО события: полезных записей нет (типично для мгновенного отключения питания).' DarkGray
    }

    Write-ReportLine ("      ★ ЯКОРЬ: {0:HH:mm:ss} — {1}" -f $CenterTime, $AnchorLabel) Red

    if ($after.Count -gt 0) {
        Write-ReportLine '      —— ПОСЛЕ события (следствие / загрузка) ——' DarkYellow
        foreach ($ev in ($after | Select-Object -First 12)) {
            $delta = [int]($ev.TimeCreated - $CenterTime).TotalSeconds
            $line = "      [{0:HH:mm:ss}] (+{1} с) {2} ID {3}: {4}" -f $ev.TimeCreated, $delta, $ev.ProviderName, $ev.Id, (Get-ShortMessage $ev 120)
            Write-ReportLine $line DarkGray
        }
    }

    # Краткая интерпретация окна
    $hints = New-Object System.Collections.ArrayList
    $provSet = @($filtered | ForEach-Object { $_.ProviderName } | Select-Object -Unique)
    if ($provSet | Where-Object { $_ -match '^(disk|stornvme|storahci|iaStor|volmgr|ntfs)' }) {
        [void]$hints.Add('В окне есть ошибки диска/тома — вероятная причина сбоя: накопитель (SSD/NVMe/кабель/слот).')
    }
    if ($provSet | Where-Object { $_ -like '*WHEA*' }) {
        [void]$hints.Add('В окне есть WHEA — вероятны RAM, CPU, PCIe/NVMe или перегрев.')
    }
    if ($provSet | Where-Object { $_ -match 'BugCheck|WER-SystemErrorReporting' }) {
        [void]$hints.Add('В окне есть BugCheck/WER — был синий экран; смотрите код STOP и минидамп.')
    }
    if ($provSet | Where-Object { $_ -match 'Display|nvlddmkm|amdkmdag|igfx' }) {
        [void]$hints.Add('В окне есть сбой видеодрайвера — возможны TDR/GPU как триггер зависания.')
    }
    if ($provSet | Where-Object { $_ -eq 'EventLog' }) {
        [void]$hints.Add('EventLog «грязно закрыт» — следствие жёсткой перезагрузки, не первопричина.')
    }
    if ($hints.Count -gt 0) {
        Write-ReportLine '      ВЫВОД ПО ОКНУ:' Cyan
        foreach ($h in $hints) {
            Write-ReportLine ("      • {0}" -f $h) Yellow
        }
    } else {
        Write-ReportLine '      ВЫВОД ПО ОКНУ: явной «причины» в журнале рядом нет — чаще БП/питание, перегрев или полный завис без записи.' Yellow
    }

    return $filtered
}

# ---------------------------------------------------------------------------
# Разделы диагностики
# ---------------------------------------------------------------------------
function Show-SystemInfo {
    Write-Section 'Сведения о системе'
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

        Write-ReportLine ("  Компьютер:     {0}" -f $cs.Name)
        Write-ReportLine ("  ОС:            {0} ({1})" -f $os.Caption, $os.OSArchitecture)
        Write-ReportLine ("  Версия / сборка: {0}.{1}" -f $os.Version, $os.BuildNumber)
        Write-ReportLine ("  Производитель: {0} | Модель: {1}" -f $cs.Manufacturer, $cs.Model)
        if ($cpu) { Write-ReportLine ("  Процессор:     {0} ({1} ядер)" -f $cpu.Name.Trim(), $cpu.NumberOfLogicalProcessors) }
        Write-ReportLine ("  ОЗУ (установлено): {0:N1} ГБ" -f ($cs.TotalPhysicalMemory / 1GB))
        Write-ReportLine ("  ОЗУ свободно:  {0:N1} ГБ" -f ($os.FreePhysicalMemory / 1MB / 1024))
        if ($bios) { Write-ReportLine ("  BIOS:          {0} | {1}" -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion) }
        $boot = $os.LastBootUpTime
        if ($boot -is [string]) {
            try { $boot = [Management.ManagementDateTimeConverter]::ToDateTime($boot) } catch {}
        }
        if ($boot -is [datetime]) {
            Write-ReportLine ("  Время работы (uptime): {0:N1} ч" -f ((Get-Date) - $boot).TotalHours)
            Write-ReportLine ("  Последняя загрузка: {0}" -f $boot)
        }
    } catch {
        Write-ReportLine ("  Не удалось получить сведения о системе: {0}" -f $_.Exception.Message) DarkYellow
    }
}

function Show-DiskHealth {
    Write-Section 'Диски и тома'
    try {
        Get-CimInstance Win32_DiskDrive -ErrorAction Stop | ForEach-Object {
            $sizeGb = [math]::Round($_.Size / 1GB, 1)
            $status = $_.Status
            $color = if ($status -ne 'OK') { [ConsoleColor]::Red } else { [ConsoleColor]::Gray }
            Write-ReportLine ("  Диск: {0} | {1} ГБ | Интерфейс: {2} | Состояние: {3}" -f $_.Model, $sizeGb, $_.InterfaceType, $status) $color
            if ($status -ne 'OK') {
                Write-ReportLine '    ПОЯСНЕНИЕ: Состояние диска не OK — возможны сбои накопителя. Сделайте бэкап.' Red
                Add-Finding -Kind 'DiskHealth' -Time (Get-Date) -Title ("Диск не OK: {0}" -f $_.Model) -Detail $status -Tags @('disk')
                $Script:CriticalCount++
            }
        }
    } catch {
        Write-ReportLine '  Не удалось опросить Win32_DiskDrive.' DarkYellow
    }

    try {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | ForEach-Object {
            $free = [math]::Round($_.FreeSpace / 1GB, 1)
            $total = [math]::Round($_.Size / 1GB, 1)
            $pct = if ($_.Size -gt 0) { [math]::Round(100 * $_.FreeSpace / $_.Size, 0) } else { 0 }
            $color = if ($pct -lt 5) { [ConsoleColor]::Red } elseif ($pct -lt 10) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Gray }
            Write-ReportLine ("  Том {0} [{1}]: свободно {2} из {3} ГБ ({4}%)" -f $_.DeviceID, $_.FileSystem, $free, $total, $pct) $color
            if ($pct -lt 5) {
                Write-ReportLine '    ПОЯСНЕНИЕ: Критически мало места — возможны сбои подкачки и дампов.' Red
                Add-Finding -Kind 'LowDisk' -Time (Get-Date) -Title ("Мало места на {0}" -f $_.DeviceID) -Tags @('disk')
                $Script:IssueCount++
            }
        }
    } catch {}

    try {
        $pd = Get-PhysicalDisk -ErrorAction Stop
        foreach ($d in $pd) {
            $h = $d.HealthStatus
            $color = switch ($h) {
                'Healthy'   { [ConsoleColor]::Green }
                'Warning'   { [ConsoleColor]::Yellow }
                'Unhealthy' { [ConsoleColor]::Red }
                default     { [ConsoleColor]::Gray }
            }
            Write-ReportLine ("  PhysicalDisk «{0}»: здоровье={1}, носитель={2}, размер={3:N1} ГБ" -f $d.FriendlyName, $h, $d.MediaType, ($d.Size/1GB)) $color
            if ($h -ne 'Healthy') {
                Write-ReportLine '    ПОЯСНЕНИЕ: Storage сообщил о проблеме накопителя. Срочно скопируйте данные.' Red
                Add-Finding -Kind 'DiskHealth' -Time (Get-Date) -Title ("PhysicalDisk {0}: {1}" -f $d.FriendlyName, $h) -Tags @('disk')
                $Script:CriticalCount++
            }
        }
    } catch {
        Write-ReportLine '  Get-PhysicalDisk недоступен (нормально на старых редакциях Windows).' DarkGray
    }
}

function Show-MemoryStatus {
    Write-Section 'Память (RAM)'
    try {
        $rams = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $i = 0
        foreach ($r in $rams) {
            $i++
            $gb = [math]::Round($r.Capacity / 1GB, 1)
            Write-ReportLine ("  Модуль {0}: {1} ГБ | {2} МГц | слот: {3} | произв.: {4}" -f $i, $gb, $r.Speed, $r.DeviceLocator, $r.Manufacturer)
        }
        if ($rams.Count -eq 0) { Write-ReportLine '  Модули RAM не обнаружены через WMI.' DarkYellow }
    } catch {
        Write-ReportLine '  Не удалось прочитать сведения о RAM.' DarkYellow
    }

    $memDiag = Get-SafeWinEvents -Filter @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results'; StartTime = $Script:StartDate } -Max 5
    if ($memDiag.Count -gt 0) {
        foreach ($ev in $memDiag) {
            Write-ReportLine ("  Результат диагностики памяти: {0} | {1}" -f $ev.TimeCreated, (Get-ShortMessage $ev 160)) Yellow
            Write-Explanation -Provider 'Microsoft-Windows-MemoryDiagnostics-Results' -EventId $ev.Id
            Add-Finding -Kind 'MemoryDiag' -Time $ev.TimeCreated -Title 'Memory Diagnostics' -Detail (Get-ShortMessage $ev 200) -Event $ev -Tags @('ram')
        }
    } else {
        Write-ReportLine '  Записей Memory Diagnostics за период нет.' Green
    }
}

function Show-Whea {
    Write-Section ("Аппаратные ошибки WHEA (за {0} дн.)" -f $Script:DaysBack)
    $whea = Get-SafeWinEvents -Filter @{
        LogName = 'System'
        ProviderName = 'Microsoft-Windows-WHEA-Logger'
        StartTime = $Script:StartDate
    } -Max 30

    if ($whea.Count -eq 0) {
        Write-ReportLine '  Критических записей WHEA за период не найдено.' Green
        return
    }

    foreach ($ev in ($whea | Sort-Object TimeCreated -Descending)) {
        $comp = Resolve-WheaComponent -Event $ev
        Write-ReportLine ("  → WHEA Event ID {0} | {1} | Устройство: {2}" -f $ev.Id, $ev.TimeCreated, $comp) Yellow
        Write-Explanation -Provider 'Microsoft-Windows-WHEA-Logger' -EventId $ev.Id
        Add-Finding -Kind 'WHEA' -Time $ev.TimeCreated -Title ("WHEA ID {0}: {1}" -f $ev.Id, $comp) -Detail (Get-ShortMessage $ev 200) -Event $ev -Tags @('whea', $comp)
        [void](Show-EventWindow -CenterTime $ev.TimeCreated -AnchorLabel ("WHEA ID {0} / {1}" -f $ev.Id, $comp) -Minutes $Script:WindowMinutes)
        Write-ReportLine ''
    }
}

function Show-KernelPower {
    Write-Section ("Внезапные перезагрузки Kernel-Power 41 (за {0} дн.)" -f $Script:DaysBack)
    $kp = Get-SafeWinEvents -Filter @{
        LogName = 'System'
        ProviderName = 'Microsoft-Windows-Kernel-Power'
        Id = 41
        StartTime = $Script:StartDate
    } -Max 20

    if ($kp.Count -eq 0) {
        Write-ReportLine '  Неожиданных отключений Kernel-Power 41 не обнаружено.' Green
        return
    }

    Write-ReportLine ("  Найдено событий Kernel-Power 41: {0}" -f $kp.Count) Red
    foreach ($ev in ($kp | Sort-Object TimeCreated -Descending)) {
        Write-ReportLine ("  → КРИТИЧЕСКАЯ ПЕРЕЗАГРУЗКА (Kernel-Power 41): {0}" -f $ev.TimeCreated) Red
        Write-Explanation -Provider 'Microsoft-Windows-Kernel-Power' -EventId 41
        Add-Finding -Kind 'KernelPower' -Time $ev.TimeCreated -Title 'Kernel-Power 41' -Detail 'Внезапная перезагрузка без корректного завершения' -Event $ev -Tags @('power')
        [void](Show-EventWindow -CenterTime $ev.TimeCreated -AnchorLabel 'Kernel-Power 41 (внезапная перезагрузка)' -Minutes $Script:WindowMinutes)
        Write-ReportLine ''
    }
}

function Show-BugChecks {
    Write-Section ("Синие экраны / BugCheck (за {0} дн.)" -f $Script:DaysBack)
    $found = $false

    $wer = Get-SafeWinEvents -Filter @{
        LogName = 'System'
        ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
        StartTime = $Script:StartDate
    } -Max 15
    foreach ($ev in ($wer | Sort-Object TimeCreated -Descending)) {
        $found = $true
        $msg = Get-ShortMessage $ev 220
        Write-ReportLine ("  → WER SystemErrorReporting ID {0} | {1}" -f $ev.Id, $ev.TimeCreated) Red
        Write-ReportLine ("    Сообщение: {0}" -f $msg) DarkGray
        Write-Explanation -Provider 'Microsoft-Windows-WER-SystemErrorReporting' -EventId $ev.Id
        Add-Finding -Kind 'BugCheck' -Time $ev.TimeCreated -Title 'BSOD / WER SystemErrorReporting' -Detail $msg -Event $ev -Tags @('bsod')
        [void](Show-EventWindow -CenterTime $ev.TimeCreated -AnchorLabel 'BSOD (WER SystemErrorReporting)' -Minutes $Script:WindowMinutes)
        Write-ReportLine ''
    }

    $bc = Get-SafeWinEvents -Filter @{
        LogName = 'System'
        ProviderName = 'BugCheck'
        StartTime = $Script:StartDate
    } -Max 10
    foreach ($ev in ($bc | Sort-Object TimeCreated -Descending)) {
        $found = $true
        $msg = Get-ShortMessage $ev 220
        Write-ReportLine ("  → BugCheck ID {0} | {1}" -f $ev.Id, $ev.TimeCreated) Red
        Write-ReportLine ("    Сообщение: {0}" -f $msg) DarkGray
        Write-Explanation -Provider 'BugCheck' -EventId $ev.Id
        Add-Finding -Kind 'BugCheck' -Time $ev.TimeCreated -Title 'BugCheck' -Detail $msg -Event $ev -Tags @('bsod')
        [void](Show-EventWindow -CenterTime $ev.TimeCreated -AnchorLabel 'BugCheck / BSOD' -Minutes $Script:WindowMinutes)
        Write-ReportLine ''
    }

    $dumpDir = 'C:\Windows\Minidump'
    if (Test-Path $dumpDir) {
        $dumps = Get-ChildItem $dumpDir -Filter '*.dmp' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5
        if ($dumps) {
            $found = $true
            Write-ReportLine '  Найдены минидампы:' Yellow
            foreach ($d in $dumps) {
                Write-ReportLine ("    {0} ({1:N1} КБ, {2})" -f $d.Name, ($d.Length/1KB), $d.LastWriteTime)
                Add-Finding -Kind 'Minidump' -Time $d.LastWriteTime -Title ("Минидамп {0}" -f $d.Name) -Tags @('bsod')
            }
            Write-ReportLine '    Для разбора .dmp: WinDbg или BlueScreenView.' DarkCyan
        }
    }

    if (-not $found) {
        Write-ReportLine '  Признаков BSOD за период не найдено.' Green
    }
}

function Show-DiskEvents {
    Write-Section ("События диска / NTFS / volmgr (за {0} дн.)" -f $Script:DaysBack)
    $providers = @('disk', 'ntfs', 'volmgr', 'stornvme', 'storahci', 'iaStor', 'iaStorV', 'partmgr')
    $any = $false
    foreach ($p in $providers) {
        $evs = Get-SafeWinEvents -Filter @{
            LogName = 'System'
            ProviderName = $p
            Level = @(1, 2, 3)
            StartTime = $Script:StartDate
        } -Max 15
        if ($evs.Count -eq 0) { continue }
        $any = $true
        Write-ReportLine ("  Источник [{0}] — {1} событий:" -f $p, $evs.Count) Yellow
        foreach ($ev in ($evs | Sort-Object TimeCreated -Descending | Select-Object -First 5)) {
            Write-ReportLine ("    → ID {0} | {1} | {2}" -f $ev.Id, $ev.TimeCreated, (Get-ShortMessage $ev 100)) Gray
            $idExplain = Get-EventIdExplain -Provider $p -Id $ev.Id
            if ($idExplain) {
                Write-ReportLine ("      {0}" -f $idExplain) DarkCyan
            }
            Add-Finding -Kind 'DiskEvent' -Time $ev.TimeCreated -Title ("{0} ID {1}" -f $p, $ev.Id) -Detail (Get-ShortMessage $ev 160) -Event $ev -Tags @('disk', $p)
        }
        Write-Explanation -Provider $p -EventId $evs[0].Id
        # Корреляция только для самого свежего события источника
        $latest = $evs | Sort-Object TimeCreated -Descending | Select-Object -First 1
        [void](Show-EventWindow -CenterTime $latest.TimeCreated -AnchorLabel ("{0} ID {1}" -f $p, $latest.Id) -Minutes $Script:WindowMinutes)
        Write-ReportLine ''
    }
    if (-not $any) {
        Write-ReportLine '  Ошибок дисковой подсистемы за период не найдено.' Green
    }
}

function Show-TopSystemErrors {
    Write-Section ("Топ источников неисправностей (журнал Система, {0} дн.)" -f $Script:DaysBack)
    Write-ReportLine '  (Обновления Windows, DCOM, DNS, время и прочий шум скрыты.)' DarkGray

    $all = Get-SafeWinEvents -Filter @{
        LogName = 'System'
        Level = @(1, 2)
        StartTime = $Script:StartDate
    } -Max 500

    if ($all.Count -eq 0) {
        Write-ReportLine '  Критических/ошибочных событий за период нет.' Green
        return
    }

    $relevant = @($all | Where-Object { Test-IsRelevantProvider $_.ProviderName -or (Get-ProviderExplain $_.ProviderName).Level -in @('Critical','Warning') })
    $relevant = @($relevant | Where-Object { -not (Test-IsNoiseProvider $_.ProviderName) })
    # Убрать SCM из топа как самостоятельный «шум», если нет критичных рядом — SCM оставляем только если много и не update
    $relevant = @($relevant | Where-Object {
        if ($_.ProviderName -eq 'Service Control Manager') { return $false }
        return $true
    })

    if ($relevant.Count -eq 0) {
        Write-ReportLine '  Релевантных ошибок неисправности в топе нет (шум отфильтрован).' Green
        return
    }

    $groups = $relevant | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 10
    foreach ($g in $groups) {
        $info = Get-ProviderExplain -Provider $g.Name
        $color = [ConsoleColor]::Gray
        $mark = ''
        if ($info) {
            switch ($info.Level) {
                'Critical' { $color = [ConsoleColor]::Red; $mark = ' !!! КРИТИЧНО !!!' }
                'Warning'  { $color = [ConsoleColor]::Yellow; $mark = ' (внимание)' }
            }
        }
        Write-ReportLine ("  • Источник [{0}]: {1} ошибк(и).{2}" -f $g.Name, $g.Count, $mark) $color

        $sampleIds = @($g.Group | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 3)
        $idSummary = ($sampleIds | ForEach-Object { "ID $($_.Name)×$($_.Count)" }) -join ', '
        Write-ReportLine ("    Частые коды: {0}" -f $idSummary) DarkGray

        $topId = 0
        if ($sampleIds.Count -gt 0) { $topId = [int]$sampleIds[0].Name }
        Write-Explanation -Provider $g.Name -EventId $topId
    }
}

function Show-DeviceProblems {
    Write-Section 'Проблемные устройства (Device Manager)'
    try {
        $problem = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object {
            $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 -and $_.ConfigManagerErrorCode -ne 45 -and $_.ConfigManagerErrorCode -ne 47
        })
        if ($problem.Count -eq 0) {
            Write-ReportLine '  Устройств с кодом ошибки (кроме отключённых/извлечённых) не найдено.' Green
            return
        }
        $codeMap = @{
            1  = 'Устройство настроено неверно'
            3  = 'Драйвер повреждён или переполнение'
            10 = 'Устройство не запускается'
            12 = 'Недостаточно свободных ресурсов'
            14 = 'Нужна перезагрузка'
            18 = 'Переустановите драйверы'
            21 = 'Удаляется'
            28 = 'Нет драйверов'
            31 = 'Windows не удалось настроить устройство'
            43 = 'Остановлено из-за ошибки (часто GPU/USB)'
            48 = 'Программное обеспечение заблокировано'
        }
        foreach ($dev in ($problem | Select-Object -First 20)) {
            $code = [int]$dev.ConfigManagerErrorCode
            $hint = if ($codeMap.ContainsKey($code)) { $codeMap[$code] } else { 'См. код в справке Microsoft' }
            Write-ReportLine ("  • {0}" -f $dev.Name) Yellow
            Write-ReportLine ("    Код ошибки: {0} — {1}" -f $code, $hint) DarkYellow
            Add-Finding -Kind 'Device' -Time (Get-Date) -Title $dev.Name -Detail ("Код {0}: {1}" -f $code, $hint) -Tags @('device')
            $Script:IssueCount++
        }
    } catch {
        Write-ReportLine '  Не удалось опросить PnP-устройства (нужны права администратора).' DarkYellow
    }
}

function Show-GpuAndResource {
    Write-Section 'Видеодрайвер / нехватка ресурсов'
    $any = $false
    $display = Get-SafeWinEvents -Filter @{
        LogName = 'System'
        ProviderName = 'Display'
        StartTime = $Script:StartDate
    } -Max 10
    foreach ($ev in $display) {
        $any = $true
        Write-ReportLine ("  → Display ID {0} | {1} | {2}" -f $ev.Id, $ev.TimeCreated, (Get-ShortMessage $ev 120)) Yellow
        Write-Explanation -Provider 'Display' -EventId $ev.Id
        Add-Finding -Kind 'GPU' -Time $ev.TimeCreated -Title ("Display ID {0}" -f $ev.Id) -Detail (Get-ShortMessage $ev 160) -Event $ev -Tags @('gpu')
        [void](Show-EventWindow -CenterTime $ev.TimeCreated -AnchorLabel ("Display ID {0}" -f $ev.Id) -Minutes $Script:WindowMinutes)
    }

    $res = Get-SafeWinEvents -Filter @{
        LogName = 'System'
        ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'
        StartTime = $Script:StartDate
    } -Max 5
    foreach ($ev in $res) {
        $any = $true
        Write-ReportLine ("  → Нехватка ресурсов ID {0} | {1}" -f $ev.Id, $ev.TimeCreated) Red
        Write-Explanation -Provider 'Microsoft-Windows-Resource-Exhaustion-Detector' -EventId $ev.Id
        Add-Finding -Kind 'Resource' -Time $ev.TimeCreated -Title 'Исчерпание ресурсов' -Event $ev -Tags @('ram')
    }

    if (-not $any) {
        Write-ReportLine '  Сбоев видеодрайвера и детектора нехватки ресурсов за период нет.' Green
    }
}

function Show-AnalysisAndRecommendations {
    Write-Header 'АНАЛИЗ И РЕКОМЕНДАЦИИ ПО ФАКТАМ'
    $findings = @($Script:Findings)

    if ($findings.Count -eq 0) {
        Write-ReportLine '  Критичных неисправностей за период не зафиксировано.' Green
        Write-ReportLine '  Дополнительных действий не требуется по результатам этого отчёта.' Green
        return
    }

    $hasKP   = @($findings | Where-Object { $_.Kind -eq 'KernelPower' }).Count -gt 0
    $hasWhea = @($findings | Where-Object { $_.Kind -eq 'WHEA' }).Count -gt 0
    $hasBsod = @($findings | Where-Object { $_.Kind -in @('BugCheck','Minidump') }).Count -gt 0
    $hasDisk = @($findings | Where-Object { $_.Kind -in @('DiskEvent','DiskHealth') -or ($_.Tags -contains 'disk') }).Count -gt 0
    $hasGpu  = @($findings | Where-Object { $_.Kind -eq 'GPU' }).Count -gt 0
    $hasRam  = @($findings | Where-Object { $_.Kind -in @('MemoryDiag','Resource') -or ($_.Tags -contains 'ram') }).Count -gt 0
    $hasDev  = @($findings | Where-Object { $_.Kind -eq 'Device' }).Count -gt 0
    $hasLow  = @($findings | Where-Object { $_.Kind -eq 'LowDisk' }).Count -gt 0

    Write-Section 'Краткий разбор'
    Write-ReportLine ("  Всего зафиксированных фактов неисправности: {0}" -f $findings.Count)
    if ($hasKP)   { Write-ReportLine ("  • Kernel-Power 41: {0} раз(а) — внезапные перезагрузки" -f @($findings | Where-Object Kind -eq 'KernelPower').Count) Red }
    if ($hasBsod) { Write-ReportLine ("  • BSOD / минидампы: есть" ) Red }
    if ($hasWhea) { Write-ReportLine ("  • WHEA (железо): {0}" -f @($findings | Where-Object Kind -eq 'WHEA').Count) Red }
    if ($hasDisk) { Write-ReportLine '  • Ошибки накопителя / тома: есть' Red }
    if ($hasGpu)  { Write-ReportLine '  • Сбои видеодрайвера: есть' Yellow }
    if ($hasRam)  { Write-ReportLine '  • Память / нехватка ресурсов: есть' Yellow }
    if ($hasDev)  { Write-ReportLine '  • Проблемные устройства PnP: есть' Yellow }
    if ($hasLow)  { Write-ReportLine '  • Критически мало места на томе: есть' Yellow }

    # Связки
    Write-Section 'Связки симптомов'
    if ($hasKP -and $hasDisk) {
        Write-ReportLine '  Kernel-Power 41 + ошибки диска → с высокой вероятностью виноват SSD/NVMe (отвал под нагрузкой, слот M.2, кабель, питание, перегрев).' Red
    } elseif ($hasKP -and $hasWhea) {
        Write-ReportLine '  Kernel-Power 41 + WHEA → смотрите компонент WHEA (RAM/CPU/PCIe). Отключите XMP/разгон, проверьте температуры.' Red
    } elseif ($hasKP -and $hasGpu) {
        Write-ReportLine '  Kernel-Power 41 + сбой GPU → возможны зависание видеодрайвера и жёсткий reset. Обновите/откатите драйвер GPU, проверьте питание GPU.' Yellow
    } elseif ($hasKP) {
        Write-ReportLine '  Есть Kernel-Power 41 без явной «причины» рядом в журнале → чаще блок питания, перегрев, кратковременный отвал питания CPU/RAM.' Yellow
        Write-ReportLine '  Смотрите блоки «Анализ журнала ±5 мин» выше по каждому событию 41.' DarkCyan
    } else {
        Write-ReportLine '  Внезапных Kernel-Power 41 за период нет.' Green
    }

    if ($hasBsod -and $hasDisk) {
        Write-ReportLine '  BSOD + диск → сохраните минидампы, но параллельно проверьте SMART/прошивку SSD — краш мог быть из-за потери тома.' Red
    } elseif ($hasBsod) {
        Write-ReportLine '  Есть BSOD — ориентируйтесь на код STOP в сообщении WER/BugCheck и разбор .dmp (WinDbg / BlueScreenView).' Red
    }

    Write-Section 'Что сделать именно по вашим находкам'
    $n = 0
    if ($hasDisk -or ($hasKP -and $hasDisk)) {
        $n++; Write-ReportLine ("  {0}. НАКОПИТЕЛЬ: сделайте резервную копию данных немедленно." -f $n) Red
        $n++; Write-ReportLine ("  {0}. Проверьте SSD утилитой производителя (SMART/прошивка). Для NVMe — посадка в слоте M.2 и термопрокладка." -f $n)
        $n++; Write-ReportLine ("  {0}. При HDD/SATA — кабели и питание; смените кабель/порт для проверки." -f $n)
    }
    if ($hasBsod) {
        $n++; Write-ReportLine ("  {0}. BSOD: скопируйте файлы из C:\Windows\Minidump, откройте в BlueScreenView/WinDbg и запишите драйвер/модуль из стека." -f $n) Red
        $bsodDetails = @($findings | Where-Object { $_.Kind -eq 'BugCheck' -and $_.Detail } | Select-Object -First 3)
        foreach ($b in $bsodDetails) {
            Write-ReportLine ("      Фрагмент из журнала ({0:dd.MM HH:mm}): {1}" -f $b.Time, $b.Detail) DarkGray
        }
        $n++; Write-ReportLine ("  {0}. Обновите чипсет и драйвер устройства из стека BSOD с сайта производителя платы/ноутбука." -f $n)
    }
    if ($hasWhea -or $hasRam) {
        $n++; Write-ReportLine ("  {0}. ПАМЯТЬ/WHEA: Win+R → mdsched.exe (проверка RAM). Отключите XMP/DOCP/разгон для теста." -f $n) Yellow
        $n++; Write-ReportLine ("  {0}. Обновите BIOS; проверьте охлаждение CPU." -f $n)
    }
    if ($hasGpu) {
        $n++; Write-ReportLine ("  {0}. GPU: чистая переустановка драйвера (DDU в безопасном режиме при повторах), проверка температур и питания видеокарты." -f $n) Yellow
    }
    if ($hasKP -and -not $hasDisk -and -not $hasWhea -and -not $hasGpu) {
        $n++; Write-ReportLine ("  {0}. Питание: проверьте БП/розетку/батарею; для ПК — нагрузка GPU+CPU (стресс) и хватает ли ватт." -f $n) Yellow
        $n++; Write-ReportLine ("  {0}. Перегрев: посмотрите температуры в простое и под нагрузкой; при необходимости замените термопасту/очистите пыль." -f $n)
    }
    if ($hasDev) {
        $n++; Write-ReportLine ("  {0}. Диспетчер устройств: устраните жёлтые значки (драйвер с сайта OEM, не «драйвер-пак»)." -f $n)
    }
    if ($hasLow) {
        $n++; Write-ReportLine ("  {0}. Освободите место на системном томе (желательно >15% свободно)." -f $n)
    }
    if ($n -eq 0) {
        Write-ReportLine '  Специфичных действий не сформировано — смотрите пояснения к событиям выше.' DarkGray
    }

    Write-ReportLine ''
    Write-ReportLine '  Примечание: ошибки Центра обновления Windows, DCOM, DNS и т.п. в этот отчёт намеренно не включены —' DarkGray
    Write-ReportLine '  они редко вызывают зависания/перезагрузки и засоряют диагностику неисправностей.' DarkGray
}

function Show-Summary {
    Write-Header 'СВОДКА'
    Write-ReportLine ("  Период анализа: последние {0} дней (с {1:dd.MM.yyyy})" -f $Script:DaysBack, $Script:StartDate)
    Write-ReportLine ("  Фактов неисправности: {0}" -f $Script:Findings.Count)
    Write-ReportLine ("  Пояснений выведено: {0}" -f $Script:IssueCount)
    if ($Script:CriticalCount -gt 0 -or @($Script:Findings | Where-Object { $_.Kind -in @('KernelPower','WHEA','BugCheck','DiskEvent','DiskHealth') }).Count -gt 0) {
        Write-ReportLine ("  Критических отметок: {0}" -f $Script:CriticalCount) Red
        Write-ReportLine '  Вердикт: обнаружены признаки неисправности — смотрите раздел «Анализ и рекомендации».' Red
    } elseif ($Script:Findings.Count -gt 0) {
        Write-ReportLine '  Вердикт: есть замечания, критичных крашей может не быть.' Yellow
    } else {
        Write-ReportLine '  Вердикт: по проверкам неисправностей серьёзных проблем не видно.' Green
    }
}

function Reset-DiagnosticsState {
    $Script:Report = New-Object System.Text.StringBuilder
    $Script:IssueCount = 0
    $Script:CriticalCount = 0
    $Script:Findings = New-Object System.Collections.ArrayList
    $Script:StartDate = (Get-Date).AddDays(-$Script:DaysBack)
}

function Clear-OneEventLog {
    param([Parameter(Mandatory)][string]$LogName)
    try {
        wevtutil.exe cl "$LogName" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host ("  [OK] Очищен: {0}" -f $LogName) -ForegroundColor Green
            return $true
        }
        # Fallback
        $session = [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession
        $session.ClearLog($LogName)
        Write-Host ("  [OK] Очищен: {0}" -f $LogName) -ForegroundColor Green
        return $true
    } catch {
        Write-Host ("  [ОШИБКА] {0}: {1}" -f $LogName, $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Invoke-ClearEventLogs {
    Clear-Host
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host '  ОЧИСТКА ЖУРНАЛОВ СОБЫТИЙ WINDOWS' -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-IsAdmin)) {
        Write-Host '  Нужны права администратора. Запустите Start-WinErrorParser.bat от администратора.' -ForegroundColor Red
        Write-Host ''
        Read-Host 'Нажмите ENTER для возврата в меню'
        return
    }

    Write-Host '  Внимание: очистка необратима. Старые записи ошибок исчезнут.' -ForegroundColor Yellow
    Write-Host '  Имеет смысл после диагностики и сохранения отчёта.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  1. Основные журналы (System, Application, Setup)'
    Write-Host '  2. Основные + Security'
    Write-Host '  3. Все включённые журналы (долго, агрессивно)'
    Write-Host '  0. Назад в меню'
    Write-Host ''
    $mode = Read-Host 'Выберите режим очистки'

    $logs = @()
    switch ($mode) {
        '1' { $logs = @('System', 'Application', 'Setup') }
        '2' { $logs = @('System', 'Application', 'Setup', 'Security') }
        '3' {
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
            Write-Host '  Неверный выбор.' -ForegroundColor Red
            Start-Sleep -Seconds 2
            return
        }
    }

    if ($logs.Count -eq 0) {
        Write-Host '  Нет журналов для очистки.' -ForegroundColor Yellow
        Read-Host 'Нажмите ENTER для возврата в меню'
        return
    }

    Write-Host ''
    Write-Host ("  Будет очищено журналов: {0}" -f $logs.Count) -ForegroundColor Yellow
    if ($logs.Count -le 15) {
        foreach ($l in $logs) { Write-Host ("    - {0}" -f $l) -ForegroundColor DarkGray }
    } else {
        foreach ($l in ($logs | Select-Object -First 10)) { Write-Host ("    - {0}" -f $l) -ForegroundColor DarkGray }
        Write-Host ("    ... и ещё {0}" -f ($logs.Count - 10)) -ForegroundColor DarkGray
    }
    Write-Host ''
    $confirm = Read-Host 'Для подтверждения введите ДА'

    if ($confirm -ne 'ДА' -and $confirm -ne 'да' -and $confirm -ne 'Да') {
        Write-Host '  Отменено.' -ForegroundColor DarkYellow
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ''
    Write-Host '  Очистка...' -ForegroundColor Cyan
    $ok = 0
    $fail = 0
    foreach ($l in $logs) {
        if (Clear-OneEventLog -LogName $l) { $ok++ } else { $fail++ }
    }

    Write-Host ''
    Write-Host ("  Готово. Успешно: {0}, ошибок: {1}" -f $ok, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host '  Можно снова запустить диагностику — журнал будет «с чистого листа».' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host 'Нажмите ENTER для возврата в меню'
}

function Invoke-Diagnostics {
    Reset-DiagnosticsState
    Clear-Host
    Write-Header 'АВТОМАТИЧЕСКИЙ АНАЛИЗАТОР ЖЕЛЕЗА И СБОЕВ WINDOWS'
    Write-ReportLine ("  Дата анализа: {0:dd.MM.yyyy HH:mm:ss}" -f (Get-Date)) DarkGray
    Write-ReportLine ("  Каталог скрипта: {0}" -f $PSScriptRoot) DarkGray
    Write-ReportLine ("  Файл отчёта: {0}" -f $Script:ReportPath) DarkGray
    Write-ReportLine ("  Окно корреляции событий: ±{0} мин вокруг критичных" -f $Script:WindowMinutes) DarkGray
    Write-ReportLine '  Режим: только неисправности (обновления/DCOM/DNS и шум скрыты)' DarkGray

    if (-not (Test-IsAdmin)) {
        Write-ReportLine ''
        Write-ReportLine '  ВНИМАНИЕ: скрипт запущен без прав администратора.' Red
        Write-ReportLine '  Часть журналов и устройств может быть недоступна. Запустите Start-WinErrorParser.bat от имени администратора.' DarkYellow
    } else {
        Write-ReportLine '  Права: администратор — OK' Green
    }

    Show-SystemInfo
    Show-DiskHealth
    Show-MemoryStatus
    Show-Whea
    Show-KernelPower
    Show-BugChecks
    Show-DiskEvents
    Show-GpuAndResource
    Show-TopSystemErrors
    Show-DeviceProblems
    Show-AnalysisAndRecommendations
    Show-Summary

    Write-ReportLine ''
    Write-ReportLine ('=' * 72) Cyan
    Write-ReportLine '  Готово. Отчёт выведен на экран и сохранён в WinErrorParser_Report_RU.txt' Cyan
    Write-ReportLine ('=' * 72) Cyan

    try {
        [System.IO.File]::WriteAllText($Script:ReportPath, $Script:Report.ToString(), [System.Text.UTF8Encoding]::new($true))
    } catch {
        Write-Host ("Не удалось сохранить отчёт: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }

    Write-Host ''
    try {
        Read-Host 'Нажмите ENTER для возврата в меню'
    } catch {
        Start-Sleep -Seconds 3
    }
}

function Show-MainMenu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 72) -ForegroundColor Cyan
        Write-Host '  WinErrorParser — меню' -ForegroundColor Cyan
        Write-Host ('=' * 72) -ForegroundColor Cyan
        Write-Host ''
        if (Test-IsAdmin) {
            Write-Host '  Права: администратор — OK' -ForegroundColor Green
        } else {
            Write-Host '  Права: нет администратора (очистка журналов и часть диагностики недоступны)' -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '  1. Диагностика ПК (журнал + железо)'
        Write-Host '  2. Очистка журналов событий'
        Write-Host '  0. Выход'
        Write-Host ''
        $choice = Read-Host 'Выберите пункт'

        switch ($choice) {
            '1' { Invoke-Diagnostics }
            '2' { Invoke-ClearEventLogs }
            '0' { return }
            default {
                Write-Host '  Неверный выбор.' -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Главный поток
# ---------------------------------------------------------------------------
Show-MainMenu
