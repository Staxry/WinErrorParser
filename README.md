# WinErrorParser

<p align="center">
  <a href="#-русская-версия"><img src="https://img.shields.io/badge/lang-Русский-blue?style=for-the-badge" alt="Русский" /></a>
  &nbsp;
  <a href="#-english-version"><img src="https://img.shields.io/badge/lang-English-green?style=for-the-badge" alt="English" /></a>
</p>

<p align="center">
  <b><a href="#-русская-версия">Русский</a></b>
  ·
  <b><a href="#-english-version">English</a></b>
</p>

---

# 🇷🇺 Русская версия

**WinErrorParser** — автономный набор скриптов для диагностики ПК под Windows. Он читает журналы событий, сведения о железе и проблемные устройства, затем выводит **понятный отчёт на русском** в терминал и в текстовый файл.

Скрипт не «лечит» компьютер сам и не требует интернета. Он собирает факты за последние **14 дней**, сопоставляет источники ошибок с встроенной базой пояснений и подсказывает, **что означает запись** и **куда смотреть дальше**.

Типичная задача: ноутбук внезапно перезагружается, Windows пишет непонятные имена вроде `Microsoft-Windows-WindowsUpdateClient` или `WHEA-Logger`, а в журнале нет человеческого описания. WinErrorParser как раз закрывает этот пробел.

### Быстрый старт (RU)

1. Скачайте `Start-WinErrorParser.bat` и `WinErrorParser.ps1` в **одну** папку.
2. ПКМ по `Start-WinErrorParser.bat` → **Запуск от имени администратора**.
3. Откройте `WinErrorParser_Report_RU.txt` рядом со скриптом.

> **Важно про кодировку:**
> - `WinErrorParser.ps1` — **UTF-8 с BOM** (иначе ParserError на кириллице).
> - `Start-WinErrorParser.bat` — **без BOM**, только латиница (BOM в `.bat` заставляет cmd мгновенно закрыть окно). Без BOM Windows PowerShell 5.1 ломает кириллицу (`ParserError`, `Unexpected token`, `hash literal was incomplete`). В репозитории файлы уже сохранены правильно — скачивайте их целиком, не копируйте текст скрипта вручную в Блокнот без BOM.

---

## Содержание (RU)

1. [Что умеет скрипт](#что-умеет-скрипт)
2. [Состав проекта](#состав-проекта)
3. [Требования](#требования)
4. [Запуск](#запуск)
5. [Ошибка ParserError / кракозябры](#ошибка-parsererror--кракозябры)
6. [Как устроен отчёт](#как-устроен-отчёт)
7. [Разделы диагностики](#разделы-диагностики)
8. [Как читать пояснения](#как-читать-пояснения)
9. [База источников ошибок](#база-источников-ошибок)
10. [Типичные связки симптомов](#типичные-связки-симптомов)
11. [Что делать после отчёта](#что-делать-после-отчёта)
12. [Ограничения](#ограничения)
13. [Частые вопросы](#частые-вопросы)
14. [English version](#-english-version)

---

## Что умеет скрипт

| Возможность | Зачем это нужно |
|-------------|-----------------|
| Отчёт на русском в консоли и в `.txt` | Не нужно расшифровывать английские имена провайдеров вручную |
| База пояснений по десяткам источников | Для `disk`, `Kernel-Power`, `WindowsUpdateClient`, WER и других есть текст «что это и что проверить» |
| Расшифровка типичных Event ID | Например: Kernel-Power **41**, disk **153**, SCM **7031**, WU **20/31** |
| Снимок системы | Модель ПК, CPU, RAM, BIOS, uptime, свободное место |
| Здоровье накопителей | WMI-диски, тома, `Get-PhysicalDisk` (если доступен) |
| Аппаратные ошибки WHEA | CPU / RAM / PCIe / NVMe |
| Внезапные перезагрузки | Kernel-Power 41 |
| Синие экраны | WER, BugCheck, список минидампов в `C:\Windows\Minidump` |
| Дисковая подсистема | `disk`, NTFS, volmgr, NVMe, AHCI, Intel RST |
| Центр обновления | Ошибки `WindowsUpdateClient` с пояснением, а не только счётчиком |
| Службы | Топ Event ID диспетчера служб и фрагменты сообщений |
| Диспетчер устройств | Устройства с ненулевым кодом ошибки (10, 28, 43 и т.д.) |
| Сводка | Сколько замечаний, сколько критичных отметок, краткий вердикт |

Цвета в терминале:

- **зелёный** — по разделу проблем не найдено;
- **жёлтый** — внимание (обновления, службы, предупреждения);
- **красный** — критично (диск, питание, BSOD, WHEA, нехватка ресурсов).

Тот же текст без цветов пишется в `WinErrorParser_Report_RU.txt` (UTF-8 с BOM, удобно открывать в Блокноте).

---

## Состав проекта

| Файл | Роль |
|------|------|
| `Start-WinErrorParser.bat` | Точка входа (ASCII, **без BOM**): проверка PowerShell, UAC, запуск `.ps1` |
| `WinErrorParser.ps1` | Основная логика диагностики и база пояснений (**UTF-8 с BOM**) |
| `WinErrorParser_Report_RU.txt` | Последний (или примерный) текстовый отчёт рядом со скриптом |
| `README.md` | Руководство (RU + EN) |

Оба исполняемых файла должны лежать **в одной папке**. Отчёт создаётся в той же папке при каждом успешном прогоне.

---

## Требования

- Windows 10 / 11 (PowerShell 5.1 — стандартный Windows PowerShell).
- Права **администратора** — иначе часть журналов и устройств будет недоступна.
- Журналы Windows не очищены за период анализа (по умолчанию 14 дней).
- Интернет **не нужен**.

Скрипт только читает WMI/CIM и журналы. Он не меняет службы, реестр и драйверы.

---

## Запуск

### Способ 1. Через bat (рекомендуется)

1. Положите `Start-WinErrorParser.bat` и `WinErrorParser.ps1` в одну папку.
2. ПКМ → **Запуск от имени администратора** (или согласитесь на UAC, если bat сам запросит права).
3. Дождитесь окончания и нажмите Enter.
4. Откройте `WinErrorParser_Report_RU.txt`.

### Способ 2. Из PowerShell

```powershell
Set-Location "C:\путь\к\папке"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\WinErrorParser.ps1"
```

### Что делает bat-файл

1. Включает UTF-8 (`chcp 65001`).
2. Переходит в свой каталог (`cd /d "%~dp0"`).
3. Проверяет наличие PowerShell и `WinErrorParser.ps1`.
4. При отсутствии прав — повторный запуск с `-Verb RunAs`.
5. Запускает Windows PowerShell через полный путь `...\WindowsPowerShell\v1.0\powershell.exe`.

---

## Ошибка ParserError / кракозябры

Если при запуске красный текст вроде:

- `Unexpected token`
- `The hash literal was incomplete`
- `ParserError`
- кириллица в ошибках выглядит как `P?P?` / `C?`

причина почти всегда одна: **`.ps1` открыт PowerShell 5.1 не как UTF-8**.

| Правильно | Неправильно |
|-----------|-------------|
| UTF-8 **с BOM** (EF BB BF в начале файла) | UTF-8 без BOM, «UTF-8» после ручного копирования в Блокнот |
| Файлы из этого репозитория / Release | Вставка кода с GitHub в новый `.ps1` без сохранения с BOM |

Как проверить в редакторе: в VS Code в статус-баре должно быть `UTF-8 with BOM`.  
Как пересохранить: VS Code → «Save with Encoding» → **UTF-8 with BOM**.

Папка с кириллицей в пути (например `F:\Журнал ошибок\`) допустима; на ошибку парсера это обычно не влияет, если BOM на месте.

---

## Как устроен отчёт

```
========================================================================
  АВТОМАТИЧЕСКИЙ АНАЛИЗАТОР ЖЕЛЕЗА И СБОЕВ WINDOWS
========================================================================
  Дата анализа, каталог, путь к файлу отчёта
  Права: администратор — OK

--- Сведения о системе ---
--- Диски и тома ---
--- Память (RAM) ---
--- Аппаратные ошибки WHEA ---
--- Внезапные перезагрузки Kernel-Power ---
--- Синие экраны / BugCheck ---
--- События диска / NTFS / volmgr ---
--- Ошибки Центра обновления Windows ---
--- Сбои служб — Service Control Manager ---
--- Топ источников ошибок журнала Система ---
--- Проблемные устройства (Device Manager) ---
--- Дополнительные признаки нестабильности ---
--- Итоговые рекомендации ---
--- СВОДКА ---
```

Пример пояснения вместо «голого» счётчика:

```
• Источник [Microsoft-Windows-WindowsUpdateClient]: 2 ошибк(и). (внимание)
  Частые коды: ID 20×1, ID 31×1
  ПОЯСНЕНИЕ [Клиент Центра обновления Windows]: сбой загрузки/установки
  обновлений, кэш SoftwareDistribution, BITS/wuauserv…
  ПО EVENT ID 20: Сбой установки обновления.
```

---

## Разделы диагностики

Период по умолчанию: **последние 14 дней** (`$Script:DaysBack` в начале `WinErrorParser.ps1`).

1. **Сведения о системе** — ОС, модель, CPU, RAM, BIOS, uptime.  
2. **Диски и тома** — статус дисков, свободное место, `Get-PhysicalDisk`.  
3. **Память (RAM)** — модули + Memory Diagnostics.  
4. **WHEA** — аппаратные ошибки CPU/RAM/PCIe/NVMe.  
5. **Kernel-Power 41** — внезапные перезагрузки.  
6. **BSOD / BugCheck** — WER, BugCheck, минидампы.  
7. **Диск / NTFS / volmgr / NVMe / AHCI / RST**.  
8. **Центр обновления** — `WindowsUpdateClient` с пояснениями.  
9. **Service Control Manager** — сбои служб.  
10. **Топ источников** журнала «Система».  
11. **Проблемные устройства** — коды диспетчера устройств.  
12. **Application + Display** — краши программ и TDR видеодрайвера.  
13. **Рекомендации и сводка**.

---

## Как читать пояснения

| Уровень | Вид | Смысл |
|---------|-----|--------|
| Critical | красный, «!!! КРИТИЧНО !!!» | Диск, питание, BSOD, WHEA — приоритет №1 |
| Warning | жёлтый, «(внимание)» | Обновления, службы, драйверы |
| Info | серый | Часто шум журнала |

1. **ПОЯСНЕНИЕ [название]** — что за источник.  
2. **ПО EVENT ID N** — что означает конкретный код.

---

## База источников ошибок

Краткий обзор (полные тексты в `$Script:ErrorExplain` / `$Script:EventIdExplain`):

- **Накопители:** `disk`, `ntfs`, `volmgr`, `stornvme`, `storahci`, `iaStor`, `iaStorV`, `partmgr`
- **Питание/ядро:** `Kernel-Power`, Kernel-Processor-Power, Kernel-General, Kernel-Boot
- **Железо:** `WHEA-Logger`, HAL
- **Краши/обновления:** WER-SystemErrorReporting, BugCheck, WindowsUpdateClient
- **Службы/PnP:** Service Control Manager, Kernel-PnP, UMDF
- **Видео:** Display, `nvlddmkm`, `amdkmdag`, `igfx`
- **Сеть:** Tcpip, NDIS, DHCP, DNS, Intel Ethernet/Wi-Fi (`Netwtw*`)
- **Память/ПО:** MemoryDiagnostics, .NET, Application Error, SideBySide
- **Прочее:** Defender, USB, TPM, Hyper-V, Resource-Exhaustion-Detector

Имена вроде `Netwtw08` ловятся по префиксу.

---

## Типичные связки симптомов

### Компьютер гаснет / мгновенно перезагружается

**Kernel-Power 41** + рядом `disk` / `volmgr` / `stornvme` / WHEA PCI → сначала накопитель и питание, не «переустановка Windows».

### Синий экран

WER / BugCheck + файлы в Minidump → код STOP, драйвер, RAM (`mdsched`), диск, перегрев.

### В топе WindowsUpdateClient без описания

Это про **патчи**, не про смерть SSD. Место на диске, BITS, кэш `SoftwareDistribution`.

### Много ошибок Service Control Manager

Смотрите имя службы в примерах (7000/7001/7031). Лечится конкретной службой.

### WHEA Event ID 3, неизвестное устройство

Проверьте GPU, NVMe, разгон RAM/CPU; откройте детали события в `eventvwr.msc`.

---

## Что делать после отчёта

Ручной чеклист (скрипт сам это **не** выполняет):

1. Бэкап данных при disk / Unhealthy / Kernel-Power 41.  
2. RAM: `Win + R` → `mdsched.exe`.  
3. Целостность ОС:

```bat
sfc /scannow
DISM /Online /Cleanup-Image /RestoreHealth
```

4. Том: `chkdsk C: /f`  
5. При явных ошибках Update — очистка кэша `SoftwareDistribution\Download` (осторожно, от администратора).  
6. Драйверы — с сайта производителя ноутбука/платы.  
7. Дампы — WinDbg / BlueScreenView.

`WinErrorParser_Report_RU.txt` **перезаписывается** при каждом запуске — сохраните копию, если нужен архив.

---

## Ограничения

- Не заменяет Memtest86, SMART-утилиты производителя SSD и осциллограф по питанию.
- Очищенный журнал → «всё зелёное» не значит, что проблем не было.
- DCOM/DNS часто шум; смотрите по реальной жалобе.
- Без администратора отчёт неполный.
- Только Windows; интерактивный запуск (`Read-Host` в конце).

---

## Частые вопросы

**Кириллица кривая в консоли, в файле нормально?**  
Файл — UTF-8 BOM. Консоль: шрифт Consolas/Cascadia + `chcp 65001`.

**Можно с флешки?**  
Да, `.bat` и `.ps1` в одной папке.

**Как расширить период?**  
`$Script:DaysBack = 14` в начале `.ps1`.

**Как добавить своё пояснение?**  
Ключ `ProviderName` в `$Script:ErrorExplain`; для кода — `"Provider|Id"` в `$Script:EventIdExplain`. Сохраняйте файл снова как **UTF-8 with BOM**.

---

## Краткая шпаргалка (RU)

```text
Запуск:     Start-WinErrorParser.bat  (от администратора)
Скрипт:     WinErrorParser.ps1        (UTF-8 с BOM!)
Отчёт:      WinErrorParser_Report_RU.txt
Период:     последние 14 дней
Главное:    красные блоки и связка 41 + disk/volmgr/WHEA
```

<p align="right"><a href="#winerrorparser">⬆ К переключателю языка</a></p>

---

# 🇬🇧 English version

**WinErrorParser** is a standalone Windows PC diagnostics toolkit. It reads Event Logs, hardware inventory, and problem devices, then prints a **human-readable report in Russian** to the console and to a text file (the on-screen/log explanations are localized for Russian-speaking support workflows).

It does **not** “repair” the PC by itself and does **not** need the Internet. It collects facts for the last **14 days**, matches error providers to a built-in explanation database, and tells you **what a log entry means** and **what to check next**.

Typical case: a laptop reboots suddenly, Windows shows opaque names like `Microsoft-Windows-WindowsUpdateClient` or `WHEA-Logger`, and the log has no plain-language guidance. WinErrorParser fills that gap.

### Quick start (EN)

1. Put `Start-WinErrorParser.bat` and `WinErrorParser.ps1` in the **same** folder.
2. Right-click `Start-WinErrorParser.bat` → **Run as administrator**.
3. Open `WinErrorParser_Report_RU.txt` next to the script.

> **Encoding matters:**
> - `WinErrorParser.ps1` — **UTF-8 with BOM** (otherwise Cyrillic ParserError).
> - `Start-WinErrorParser.bat` — **no BOM**, ASCII only (a UTF-8 BOM makes cmd.exe close instantly). Without BOM, Windows PowerShell 5.1 misreads Cyrillic and fails with `ParserError` / `Unexpected token` / `hash literal was incomplete`. Download the repo files as-is; do not paste the script into Notepad and save as plain UTF-8.

---

## Table of contents (EN)

1. [Features](#features)
2. [Project files](#project-files)
3. [Requirements](#requirements)
4. [How to run](#how-to-run)
5. [ParserError / mojibake](#parsererror--mojibake)
6. [Report layout](#report-layout)
7. [Diagnostic sections](#diagnostic-sections)
8. [How to read explanations](#how-to-read-explanations)
9. [Error provider coverage](#error-provider-coverage)
10. [Common symptom patterns](#common-symptom-patterns)
11. [After you get a report](#after-you-get-a-report)
12. [Limitations](#limitations)
13. [FAQ](#faq)
14. [Russian version](#-русская-версия)

---

## Features

| Feature | Why it helps |
|---------|----------------|
| Console + `.txt` report | Less guessing about English provider names |
| Dozens of explanation entries | `disk`, `Kernel-Power`, `WindowsUpdateClient`, WER, and more get plain-language guidance |
| Common Event ID hints | e.g. Kernel-Power **41**, disk **153**, SCM **7031**, WU **20/31** |
| System snapshot | PC model, CPU, RAM, BIOS, uptime, free space |
| Storage health | WMI disks, volumes, `Get-PhysicalDisk` when available |
| WHEA hardware errors | CPU / RAM / PCIe / NVMe |
| Sudden reboots | Kernel-Power 41 |
| Bugchecks | WER, BugCheck, minidumps under `C:\Windows\Minidump` |
| Storage stack | `disk`, NTFS, volmgr, NVMe, AHCI, Intel RST |
| Windows Update | `WindowsUpdateClient` with explanation, not only a counter |
| Services | Top SCM Event IDs and sample messages |
| Device Manager problems | Non-zero Config Manager error codes |
| Summary | Issue counts, critical marks, short verdict |

Console colors: **green** = clean section, **yellow** = attention, **red** = critical.  
The same text is written to `WinErrorParser_Report_RU.txt` (UTF-8 with BOM).

---

## Project files

| File | Role |
|------|------|
| `Start-WinErrorParser.bat` | Launcher (ASCII, **no BOM**): PowerShell check, UAC, run `.ps1` |
| `WinErrorParser.ps1` | Diagnostics engine + explanation DB (**UTF-8 with BOM**) |
| `WinErrorParser_Report_RU.txt` | Last/sample text report |
| `README.md` | This guide (RU + EN) |

Keep the `.bat` and `.ps1` in the **same directory**. The report is written there on each successful run.

---

## Requirements

- Windows 10 / 11 (Windows PowerShell 5.1).
- **Administrator** rights for full Event Log / PnP / disk visibility.
- Event Logs retained for the analysis window (default 14 days).
- No Internet required.

The script is read-only regarding system configuration (no service/registry/driver changes).

---

## How to run

### Option 1 — BAT (recommended)

1. Place both files in one folder.  
2. Right-click → **Run as administrator** (or accept UAC if the bat re-launches elevated).  
3. Wait for completion, press Enter.  
4. Open `WinErrorParser_Report_RU.txt`.

### Option 2 — PowerShell

```powershell
Set-Location "C:\path\to\folder"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\WinErrorParser.ps1"
```

### What the BAT does

1. Sets UTF-8 code page (`chcp 65001`).  
2. `cd`s to its own folder.  
3. Checks for PowerShell and `WinErrorParser.ps1`.  
4. Elevates with `Start-Process -Verb RunAs` when needed.  
5. Starts the built-in Windows PowerShell host via full path.

---

## ParserError / mojibake

If you see red errors such as:

- `Unexpected token`
- `The hash literal was incomplete`
- `ParserError`
- Cyrillic shown as `P?P?` / `C?`

Windows PowerShell 5.1 did **not** load the script as UTF-8.

| Correct | Incorrect |
|---------|-----------|
| UTF-8 **with BOM** (file starts with EF BB BF) | UTF-8 without BOM / paste into Notepad |
| Files from this repository | Hand-copied script body without BOM |

In VS Code the status bar should say **UTF-8 with BOM**.  
To fix: **Save with Encoding** → **UTF-8 with BOM**.

A Cyrillic folder name (e.g. `F:\Журнал ошибок\`) is fine when BOM is present.

---

## Report layout

Sections run in a fixed order: system info → disks → RAM → WHEA → Kernel-Power → BugCheck → storage events → Windows Update → SCM → top System errors → Device Manager → Application/Display hints → recommendations → summary.

Instead of a bare counter you get:

```
• Source [Microsoft-Windows-WindowsUpdateClient]: 2 error(s). (attention)
  Frequent IDs: ID 20×1, ID 31×1
  EXPLANATION [Windows Update Client]: download/install failure,
  SoftwareDistribution cache, BITS/wuauserv…
  BY EVENT ID 20: Update install failure.
```

*(On-screen strings are in Russian; the structure matches the table above.)*

---

## Diagnostic sections

Default window: **last 14 days** (`$Script:DaysBack` at the top of `WinErrorParser.ps1`).

1. System info  
2. Disks & volumes  
3. RAM modules + Memory Diagnostics  
4. WHEA hardware errors  
5. Kernel-Power 41 unexpected reboots  
6. BSOD / BugCheck / minidumps  
7. disk / NTFS / volmgr / NVMe / AHCI / RST  
8. Windows Update Client  
9. Service Control Manager  
10. Top System log providers  
11. Problem PnP devices  
12. Application errors + Display/TDR  
13. Recommendations & summary  

---

## How to read explanations

| Level | Appearance | Meaning |
|-------|------------|---------|
| Critical | red | Storage, power, BSOD, WHEA — fix first |
| Warning | yellow | Updates, services, drivers |
| Info | gray | Often log noise |

1. **EXPLANATION [title]** — what the provider is.  
2. **BY EVENT ID N** — what that specific ID usually means.

---

## Error provider coverage

High-level groups encoded in the script:

- Storage: `disk`, `ntfs`, `volmgr`, NVMe/AHCI/RST, `partmgr`  
- Power/kernel: `Kernel-Power` and related  
- Hardware: `WHEA-Logger`, HAL  
- Crashes/updates: WER, BugCheck, WindowsUpdateClient  
- Services/PnP: SCM, Kernel-PnP, UMDF  
- GPU: Display, NVIDIA/AMD/Intel driver names  
- Network: Tcpip, NDIS, DHCP, DNS, Intel NIC/Wi-Fi prefixes  
- Memory/apps: MemoryDiagnostics, .NET, Application Error, SideBySide  
- Other: Defender, USB, TPM, Hyper-V, resource exhaustion  

Prefix matching covers names like `Netwtw08`.

---

## Common symptom patterns

### Instant power-off / reboot

**Kernel-Power 41** plus `disk` / `volmgr` / `stornvme` / PCIe WHEA → check SSD/NVMe slot, cables, PSU/thermals before reinstalling Windows.

### Blue screen

WER / BugCheck + `Minidump` → note the STOP code; check driver, RAM (`mdsched`), disk, GPU/CPU thermals.

### Top hit is WindowsUpdateClient

Usually **patch download/install**, not a dying SSD. Free space, BITS, `SoftwareDistribution` cache.

### Many Service Control Manager errors

Read the service name in the sample messages (7000/7001/7031). Fix that service, not “the registry”.

### WHEA Event ID 3, unknown device

Inspect PCI/NVMe/GPU and memory overclock/XMP; open the event details in Event Viewer.

---

## After you get a report

Manual checklist (the script does **not** run these for you):

1. Back up data if storage/Kernel-Power critical marks appear.  
2. RAM: `mdsched.exe`.  
3. OS integrity: `sfc /scannow` and `DISM /Online /Cleanup-Image /RestoreHealth`.  
4. Volume check: `chkdsk C: /f`.  
5. For clear Update failures — carefully clear `SoftwareDistribution\Download`.  
6. Drivers from the OEM/motherboard vendor site.  
7. Dump analysis with WinDbg / BlueScreenView.

`WinErrorParser_Report_RU.txt` is **overwritten** each run — copy it if you need an archive.

---

## Limitations

- Not a substitute for Memtest86, vendor SSD tools, or power hardware testing.  
- Cleared logs can produce a false “all green”.  
- Some DCOM/DNS noise is expected.  
- Non-admin runs are incomplete.  
- Windows only; interactive (`Read-Host` at the end).

---

## FAQ

**Console mojibake but the TXT file looks fine?**  
Report file is UTF-8 BOM. Use Consolas/Cascadia and `chcp 65001` for the console.

**USB flash drive OK?**  
Yes — keep `.bat` and `.ps1` together.

**Longer analysis window?**  
Change `$Script:DaysBack` near the top of the `.ps1`.

**Add my own explanation?**  
Add a `ProviderName` entry to `$Script:ErrorExplain`, or `"Provider|Id"` to `$Script:EventIdExplain`, then save again as **UTF-8 with BOM**.

---

## Cheat sheet (EN)

```text
Launch:   Start-WinErrorParser.bat  (as Administrator)
Script:   WinErrorParser.ps1        (UTF-8 with BOM!)
Report:   WinErrorParser_Report_RU.txt
Window:   last 14 days
Focus:    red sections; combo of 41 + disk/volmgr/WHEA
```

<p align="right"><a href="#winerrorparser">⬆ Back to language switcher</a></p>
