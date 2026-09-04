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

**WinErrorParser** — автономный инструмент диагностики ПК под Windows. Читает журналы событий и сведения о железе, отфильтровывает «шум», разбирает критичные сбои (в том числе окно **±5 минут** вокруг Kernel-Power / BSOD / WHEA / диска) и пишет **отчёт на русском** в терминал и в файл.

Скрипт **не требует интернета**. Диагностика только читает журналы и WMI; очистка журналов (пункт меню) меняет только Event Log и только после явного подтверждения.

### Быстрый старт (RU)

1. Скачайте `Start-WinErrorParser.bat` и `WinErrorParser.ps1` в **одну** папку.
2. ПКМ по `Start-WinErrorParser.bat` → **Запуск от имени администратора**.
3. В меню выберите:
   - **1** — диагностика ПК;
   - **2** — очистка журналов событий;
   - **0** — выход.
4. После диагностики откройте `WinErrorParser_Report_RU.txt`.

> **Кодировка файлов (важно):**
> - `WinErrorParser.ps1` — **UTF-8 с BOM** (иначе ParserError на кириллице).
> - `Start-WinErrorParser.bat` — **ASCII без BOM** (BOM в `.bat` закрывает окно cmd сразу).
> Скачивайте файлы из репозитория целиком, не копируйте код в Блокнот вручную.

---

## Содержание (RU)

1. [Меню](#меню)
2. [Что умеет скрипт](#что-умеет-скрипт)
3. [Состав проекта](#состав-проекта)
4. [Требования](#требования)
5. [Запуск](#запуск)
6. [Очистка журналов](#очистка-журналов)
7. [Как устроен отчёт](#как-устроен-отчёт)
8. [Разделы диагностики](#разделы-диагностики)
9. [Анализ ±5 минут](#анализ-5-минут)
10. [Рекомендации по фактам](#рекомендации-по-фактам)
11. [Что скрывается как шум](#что-скрывается-как-шум)
12. [Типичные связки симптомов](#типичные-связки-симптомов)
13. [Ошибка ParserError](#ошибка-parsererror--кракозябры)
14. [Ограничения и FAQ](#ограничения-и-faq)
15. [English version](#-english-version)

---

## Меню

После запуска появляется меню:

```text
1. Диагностика ПК (журнал + железо)
2. Очистка журналов событий
0. Выход
```

После диагностики или очистки скрипт возвращает в меню (можно сразу прогнать анализ «с чистого листа»).

---

## Что умеет скрипт

| Возможность | Зачем |
|-------------|--------|
| Меню диагностики / очистки | Один bat на обе задачи |
| Отчёт на русском (консоль + `.txt`) | Понятные пояснения вместо сырых ProviderName |
| Фильтр шума | Update / DCOM / DNS / SCM и подобное не засоряют отчёт |
| Корреляция ±5 мин | Вокруг Kernel-Power 41, WHEA, BSOD, диска, GPU — что было до/после |
| Рекомендации по фактам | Если BSOD — шаги по BSOD; если 41+диск — про SSD и т.д. |
| Система / диски / RAM | Модель, тома, SMART/`PhysicalDisk`, модули памяти |
| WHEA, Kernel-Power 41, BugCheck | Аппаратные сбои, внезапные перезагрузки, синие экраны |
| Диск / NTFS / volmgr / NVMe | Ошибки накопителя |
| GPU / нехватка ресурсов | TDR Display, Resource-Exhaustion |
| Диспетчер устройств | Реальные коды ошибок (отключённые/извлечённые устройства пропускаются) |
| Очистка Event Log | System / Application / Setup / Security или все включённые журналы |

Цвета: **зелёный** — чисто; **жёлтый** — внимание; **красный** — критично.

---

## Состав проекта

| Файл | Роль |
|------|------|
| `Start-WinErrorParser.bat` | Запуск (ASCII, **без BOM**), UAC, проверка BOM у `.ps1` |
| `WinErrorParser.ps1` | Меню, диагностика, очистка журналов (**UTF-8 с BOM**) |
| `WinErrorParser_Report_RU.txt` | Отчёт (создаётся/перезаписывается при диагностике) |
| `README.md` | Это руководство (RU + EN) |

---

## Требования

- Windows 10 / 11 (Windows PowerShell 5.1).
- Права **администратора** (обязательны для полной диагностики и для очистки журналов).
- Интернет не нужен.

Диагностика **не** меняет службы, реестр и драйверы. Очистка журналов меняет только Event Log после ввода `ДА`.

---

## Запуск

### Через bat (рекомендуется)

1. `Start-WinErrorParser.bat` и `WinErrorParser.ps1` в одной папке.
2. ПКМ → **Запуск от имени администратора** (или UAC из bat).
3. Выберите пункт меню.

### Из PowerShell

```powershell
Set-Location "C:\путь\к\папке"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\WinErrorParser.ps1"
```

---

## Очистка журналов

Пункт меню **2**. Нужны права администратора.

Режимы:

| Режим | Что очищается |
|-------|----------------|
| 1 | System, Application, Setup |
| 2 | То же + Security |
| 3 | Все включённые журналы с записями (дольше) |

Подтверждение: введите **`ДА`**. Без этого очистка не выполняется.

Имеет смысл **сначала** сохранить отчёт диагностики, **потом** чистить журналы. После очистки диагностика увидит только новые события.

---

## Как устроен отчёт

```text
Сведения о системе
Диски и тома
Память (RAM)
WHEA
Kernel-Power 41   ← для каждого события: окно ±5 мин + вывод
BSOD / BugCheck   ← то же
События диска     ← то же
GPU / ресурсы
Топ источников неисправностей (без шума)
Проблемные устройства
АНАЛИЗ И РЕКОМЕНДАЦИИ ПО ФАКТАМ
СВОДКА
```

Файл: `WinErrorParser_Report_RU.txt` (UTF-8 с BOM), **перезаписывается** при каждом запуске диагностики.

---

## Разделы диагностики

Период по умолчанию: **14 дней** (`$Script:DaysBack` в начале `.ps1`).

1. Система — ОС, модель, CPU, RAM, BIOS, uptime.  
2. Диски/тома — статус, место, `Get-PhysicalDisk`.  
3. RAM — модули + Memory Diagnostics.  
4. WHEA — аппаратные ошибки + корреляция.  
5. Kernel-Power **41** — внезапные перезагрузки + корреляция.  
6. BSOD — WER, BugCheck, минидампы + корреляция.  
7. disk / NTFS / volmgr / NVMe / AHCI / RST.  
8. Display (TDR) и нехватка ресурсов.  
9. Топ релевантных ошибок журнала «Система».  
10. PnP с кодами ошибок (без «просто отключено»).  
11. Анализ и рекомендации только по найденным фактам.

---

## Анализ ±5 минут

Для каждого критичного события скрипт показывает:

- записи **до** события (возможные причины);
- якорь (само событие);
- записи **после** (следствие / загрузка);
- краткий **вывод по окну** (диск / WHEA / BSOD / GPU или «явной причины нет»).

Шумные источники в этом окне тоже отфильтровываются.

---

## Рекомендации по фактам

Блок строится из того, что реально найдено:

- Kernel-Power 41 + disk → бэкап, SSD/NVMe, слот M.2, питание;  
- BSOD → минидампы, код STOP, драйвер из стека;  
- WHEA / RAM → `mdsched`, XMP/разгон, BIOS, температуры;  
- GPU → чистая переустановка драйвера, перегрев/питание;  
- 41 без соседей в журнале → БП, перегрев, мгновенный отвал питания.

Общих шаблонов вроде «почините Windows Update» больше нет.

---

## Что скрывается как шум

В отчёт **намеренно не попадают** (обычно не ломают ПК):

- Windows Update Client  
- DCOM, DNS, DHCP, служба времени  
- Service Control Manager (как отдельный топ)  
- TPM / SPP / PerfNet / ETW и похожий фон  

Их всё ещё можно смотреть вручную в `eventvwr.msc`, если нужно.

---

## Типичные связки симптомов

| Симптом | Куда смотреть в отчёте |
|---------|-------------------------|
| Внезапная перезагрузка | Kernel-Power 41 + блок ±5 мин |
| Синий экран | BSOD / Minidump + рекомендации по BSOD |
| Зависания, отвал диска | disk / volmgr / stornvme |
| Артефакты / «драйвер видеоперестал отвечать» | Display / GPU |
| WHEA ID 3 | PCIe / NVMe / RAM / CPU |

---

## Ошибка ParserError / кракозябры

Если видите `Unexpected token`, `hash literal was incomplete`, кириллица как `P?P?`:

→ `WinErrorParser.ps1` сохранён **не** как UTF-8 with BOM.

В VS Code: **Save with Encoding → UTF-8 with BOM**.  
Bat-файл должен быть **без BOM**.

---

## Ограничения и FAQ

- Не заменяет Memtest86 и SMART-утилиты производителя SSD.  
- Очищенный журнал → «всё зелёное» не значит, что проблем не было раньше.  
- Без администратора диагностика неполная, очистка недоступна.  
- Только Windows.

**Как изменить период анализа?**  
`$Script:DaysBack = 14` в начале `WinErrorParser.ps1`.

**Отчёт пропал после повторного запуска?**  
Файл перезаписывается — скопируйте `WinErrorParser_Report_RU.txt`, если нужен архив.

**Очистка удаляет отчёт?**  
Нет. Чистятся только журналы Windows; `.txt` отчёта остаётся, пока не запустите диагностику снова.

---

## Краткая шпаргалка (RU)

```text
Запуск:     Start-WinErrorParser.bat  (администратор)
Меню:       1 = диагностика | 2 = очистка журналов | 0 = выход
Скрипт:     WinErrorParser.ps1        (UTF-8 с BOM)
Отчёт:      WinErrorParser_Report_RU.txt
Период:     14 дней, корреляция ±5 мин
Фокус:      неисправности; Update/DCOM/DNS скрыты
```

<p align="right"><a href="#winerrorparser">⬆ К переключателю языка</a></p>

---

# 🇬🇧 English version

**WinErrorParser** is a standalone Windows PC diagnostics tool. It reads Event Logs and hardware inventory, filters noise, analyzes critical failures (including a **±5 minute** window around Kernel-Power / BSOD / WHEA / disk), and writes a **Russian-language report** to the console and a text file (localized for Russian-speaking support workflows).

No Internet required. Diagnostics are read-only for the OS; log clearing (menu item) changes Event Log only after explicit confirmation.

### Quick start (EN)

1. Put `Start-WinErrorParser.bat` and `WinErrorParser.ps1` in the **same** folder.
2. Right-click the bat → **Run as administrator**.
3. Menu:
   - **1** — PC diagnostics  
   - **2** — clear Event Logs  
   - **0** — exit  
4. After diagnostics, open `WinErrorParser_Report_RU.txt`.

> **Encoding:**
> - `WinErrorParser.ps1` — **UTF-8 with BOM**  
> - `Start-WinErrorParser.bat` — **ASCII, no BOM**  
> Download repo files as-is; do not paste into Notepad without BOM.

---

## Table of contents (EN)

1. [Menu](#menu)
2. [Features](#features)
3. [Project files](#project-files)
4. [Requirements](#requirements)
5. [How to run](#how-to-run)
6. [Clearing Event Logs](#clearing-event-logs)
7. [Report layout](#report-layout)
8. [Diagnostic sections](#diagnostic-sections)
9. [±5 minute analysis](#5-minute-analysis)
10. [Fact-based recommendations](#fact-based-recommendations)
11. [Noise filtering](#noise-filtering)
12. [ParserError](#parsererror)
13. [Limits & FAQ](#limits--faq)
14. [Russian version](#-русская-версия)

---

## Menu

```text
1. PC diagnostics (logs + hardware)
2. Clear Event Logs
0. Exit
```

After diagnostics or cleanup you return to the menu.

---

## Features

| Feature | Purpose |
|---------|---------|
| Menu: diagnose / clear logs | One launcher for both tasks |
| Russian report (console + `.txt`) | Plain-language explanations |
| Noise filter | Update / DCOM / DNS / SCM etc. hidden |
| ±5 min correlation | Context around Kernel-Power 41, WHEA, BSOD, disk, GPU |
| Fact-based recommendations | BSOD → BSOD steps; 41+disk → SSD focus |
| System / disks / RAM snapshot | Model, volumes, PhysicalDisk, modules |
| WHEA, Kernel-Power 41, BugCheck | Hardware faults, sudden reboots, bluescreens |
| Storage stack | disk / NTFS / volmgr / NVMe / AHCI / RST |
| GPU / resource exhaustion | Display TDR, low commit |
| Device Manager problems | Real error codes (skips merely disabled devices) |
| Event Log cleanup | Main logs, +Security, or all enabled logs |

---

## Project files

| File | Role |
|------|------|
| `Start-WinErrorParser.bat` | Launcher (ASCII, **no BOM**), UAC, `.ps1` BOM check |
| `WinErrorParser.ps1` | Menu, diagnostics, log clear (**UTF-8 with BOM**) |
| `WinErrorParser_Report_RU.txt` | Report (overwritten on each diagnostics run) |
| `README.md` | This guide (RU + EN) |

---

## Requirements

- Windows 10 / 11 (Windows PowerShell 5.1).
- **Administrator** rights for full diagnostics and log clearing.
- No Internet.

Diagnostics do not change services/registry/drivers. Log clear only touches Event Log after typing `ДА` (Russian “YES”).

---

## How to run

1. Place both files in one folder.  
2. Run the bat as administrator.  
3. Pick a menu item.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\WinErrorParser.ps1"
```

---

## Clearing Event Logs

Menu item **2** (admin required).

| Mode | Clears |
|------|--------|
| 1 | System, Application, Setup |
| 2 | Same + Security |
| 3 | All enabled logs that contain records |

Confirm by typing **`ДА`**. Save the diagnostics report first if you need the old evidence.

---

## Report layout

System → Disks → RAM → WHEA → Kernel-Power 41 (±5 min) → BSOD (±5 min) → Disk events → GPU/resources → Top relevant System errors → Devices → **Fact-based analysis** → Summary.

Report file: `WinErrorParser_Report_RU.txt` (UTF-8 with BOM), overwritten each diagnostics run.

Default window: **14 days** (`$Script:DaysBack`).

---

## ±5 minute analysis

For each critical event the script shows before/anchor/after entries and a short window conclusion (storage / WHEA / BSOD / GPU / no clear cause). Noise providers are filtered here too.

---

## Fact-based recommendations

Built only from findings: 41+disk → backup & SSD; BSOD → dumps & STOP code; WHEA/RAM → `mdsched` & XMP off; GPU → clean driver reinstall; lone 41 → PSU/thermals. No generic “fix Windows Update” checklist.

---

## Noise filtering

Intentionally hidden from the report: Windows Update Client, DCOM, DNS/DHCP, Time service, SCM as a top noise source, TPM/SPP/PerfNet-like background. Use Event Viewer manually if you need them.

---

## ParserError

`Unexpected token` / `hash literal was incomplete` → save `WinErrorParser.ps1` as **UTF-8 with BOM**. Keep the `.bat` **without** BOM.

---

## Limits & FAQ

- Not a replacement for Memtest86 or vendor SSD tools.  
- Cleared logs can look “all green”.  
- Non-admin = incomplete diagnostics; log clear disabled.  
- Windows only.

**Change analysis period:** edit `$Script:DaysBack` in the `.ps1`.  
**Report overwritten?** Copy `WinErrorParser_Report_RU.txt` before the next run.  
**Does log clear delete the report file?** No — only Windows Event Logs.

---

## Cheat sheet (EN)

```text
Launch:   Start-WinErrorParser.bat  (Administrator)
Menu:     1 = diagnostics | 2 = clear logs | 0 = exit
Script:   WinErrorParser.ps1        (UTF-8 with BOM)
Report:   WinErrorParser_Report_RU.txt
Window:   14 days, ±5 min correlation
Focus:    real faults; Update/DCOM/DNS hidden
```

<p align="right"><a href="#winerrorparser">⬆ Back to language switcher</a></p>
