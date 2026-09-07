# WinErrorParser

<p align="center">
  <a href="#-русская-версия"><img src="https://img.shields.io/badge/lang-Русский-blue?style=for-the-badge" alt="Русский" /></a>
  &nbsp;
  <a href="#-english-version"><img src="https://img.shields.io/badge/lang-English-green?style=for-the-badge" alt="English" /></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Windows-10%20%2F%2011-0078D6?style=flat-square&logo=windows&logoColor=white" alt="Windows" />
  <img src="https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell 5.1" />
  <img src="https://img.shields.io/badge/offline-no%20internet-22c55e?style=flat-square" alt="Offline" />
  <img src="https://img.shields.io/badge/license-MIT-yellow?style=flat-square" alt="MIT" />
  <img src="https://img.shields.io/badge/version-2.1.0-38bdf8?style=flat-square" alt="2.1.0" />
</p>

<p align="center">
    <b><a href="#-русская-версия">Русский</a></b>
    ·
    <b><a href="#-english-version">English</a></b>
</p>

<p align="center">
  <img src="docs/preview.svg" alt="WinErrorParser HTML overview preview" width="920" />
</p>

---

# 🇷🇺 Русская версия

**WinErrorParser 2.1** — автономный инструмент диагностики ПК под Windows. Читает журналы событий и сведения о железе, отфильтровывает «шум», **расшифровывает BSOD** (STOP-код, модуль/процесс, типичная причина), разбирает критичные сбои (окно **±5 минут** вокруг Kernel-Power / BSOD / WHEA / диска) и пишет отчёт **на русском или английском** в терминал, `.txt` и HTML.

Скрипт **не требует интернета**. Диагностика только читает журналы и WMI; очистка журналов (пункт меню) меняет только Event Log и только после явного подтверждения.

### Что нового в 2.1

- Краткая **шапка** в начале TXT и якоря в HTML (вердикт → частота → сравнение → система / диски).
- **Вес событий**: единичный сбой vs серия, первая/последняя дата.
- **Сравнение с прошлым отчётом** в той же папке (новое / стало больше / исчезло).
- Краши **игр и браузеров** скрыты и **не тянут вердикт** в «железо».
- Контекст **«сломалось после обновления Windows»**.
- Сон / Fast Startup, dirty bit / CHKDSK, отвалы USB-сети-PCIe, настройки дампа, ожидание перезагрузки, дата BIOS.
- Меню: открыть последний HTML, список отчётов, упаковать TXT+HTML в ZIP.

### Быстрый старт (RU)

1. Скачайте `Start-WinErrorParser.bat` и `WinErrorParser.ps1` в **одну** папку.
2. ПКМ по `Start-WinErrorParser.bat` → **Запуск от имени администратора**.
3. В меню выберите:
   - **1** — диагностика ПК;
   - **2** — очистка журналов событий;
   - **3** — период анализа (3 / 7 / 14 / 30 / 90 дней);
   - **4** — режим: только неисправности / полный отчёт;
   - **5** — язык отчёта RU/EN;
   - **6** — открыть последний HTML;
   - **7** — последние отчёты;
   - **8** — упаковать последний отчёт в ZIP;
   - **0** — выход.
4. После диагностики откройте свежий `WinErrorParser_Report_RU_YYYY-MM-DD_HHMMSS.txt` или `.html` (краткая сводка также копируется в буфер обмена).

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
9. [Расшифровка BSOD](#расшифровка-bsod)
10. [Анализ ±5 минут](#анализ-5-минут)
11. [Рекомендации по фактам](#рекомендации-по-фактам)
12. [Что скрывается как шум](#что-скрывается-как-шум)
13. [Типичные связки симптомов](#типичные-связки-симптомов)
14. [Ошибка ParserError](#ошибка-parsererror--кракозябры)
15. [Проверка файлов (SHA256)](#проверка-файлов-sha256)
16. [Ограничения и FAQ](#ограничения-и-faq)
17. [English version](#-english-version)

---

## Меню

После запуска появляется меню:

```text
1. Диагностика ПК (журнал + железо)
2. Очистка журналов событий
3. Период анализа (3 / 7 / 14 / 30 / 90)
4. Режим отчёта: неисправности / полный
5. Язык отчёта: ru / en
6. Открыть последний HTML
7. Последние отчёты
8. Упаковать последний отчёт в ZIP
0. Выход
```

После диагностики или очистки скрипт возвращает в меню (можно сразу прогнать анализ «с чистого листа»).

---

## Что умеет скрипт

| Возможность | Зачем |
|-------------|--------|
| Меню диагностики / очистки / настроек | Один bat: период, язык, полный отчёт, архив |
| Отчёт RU/EN (консоль + `.txt` + HTML) | Понятные пояснения; архив с датой в имени |
| Краткая шапка + якоря HTML | Вердикт и вес событий сразу наверху |
| Частота событий | Единичный vs серия, первое/последнее |
| Сравнение с прошлым прогоном | Что появилось, усилилось или исчезло |
| Расшифровка BSOD | STOP-код, имя, модуль/процесс, вероятная область |
| Фильтр шума или полный режим | Update / DCOM / DNS скрыты; SCM только при частых падениях |
| Краши игр/браузеров | Скрыты, **не** влияют на вердикт железа |
| Корреляция ±5 мин | System + Application + Setup вокруг критичных событий |
| Система / диски / SMART / RAM | Модель, тома, `PhysicalDisk`, счётчики надёжности |
| WHEA, Kernel-Power 41, EventLog 6008 | Железо, внезапные перезагрузки, неожиданный shutdown |
| Сон / Fast Startup / дампы | 41 после сна, быстрый запуск, включены ли минидампы |
| Dirty bit / CHKDSK | Том закрыли нечисто |
| USB / сеть / PCIe | Отвалы шины, не только диск |
| Контекст обновления Windows | «Сломалось после патча?» |
| Очистка Event Log | Сначала экспорт `.evtx`; «все журналы» спрятаны |

Цвета: **зелёный** — чисто; **жёлтый** — внимание; **красный** — критично.

---

## Состав проекта

| Файл | Роль |
|------|------|
| `Start-WinErrorParser.bat` | Запуск (ASCII, **без BOM**), UAC, проверка BOM у `.ps1` |
| `WinErrorParser.ps1` | Меню, диагностика, очистка журналов (**UTF-8 с BOM**), версия 2.1 |
| `LICENSE` | MIT |
| `docs/preview.svg` | Превью HTML-дашборда для GitHub |
| `WinErrorParser_Report_RU_дата.txt` + `.html` | Два файла на запуск (не коммитятся) |
| `examples/sample_report.txt` | Синтетический пример отчёта |
| `README.md` | Это руководство (RU + EN) |

Живые отчёты, `WinErrorParser_LastState.json` и ZIP-архивы в git не входят.

---

## Требования

- Windows 10 / 11 (Windows PowerShell 5.1).
- Права **администратора** (обязательны для полной диагностики и для очистки журналов).
- Интернет не нужен.

Диагностика **не** меняет службы, реестр и драйверы. Очистка журналов меняет только Event Log после ввода `ДА` или `YES` (перед этим журналы сохраняются в `logs_backup_*\*.evtx`).

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
# Без меню, 30 дней, английский отчёт:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\WinErrorParser.ps1" -NonInteractive -DaysBack 30 -Language en -Action Diagnose
# Полный отчёт (шум не скрыт):
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\WinErrorParser.ps1" -FullReport
```

Параметры: `-DaysBack`, `-Language ru|en`, `-FullReport`, `-NonInteractive`, `-Action Menu|Diagnose`, `-ReportPath`, `-NoHtml`.

---

## Очистка журналов

Пункт меню **2**. Нужны права администратора.

Режимы:

| Режим | Что очищается |
|-------|----------------|
| 1 | System, Application, Setup |
| 2 | То же + Security |
| 3 | Все включённые журналы с записями (дольше) |

Подтверждение: введите **`ДА`** или **`YES`**. Режим 9 (все журналы) дополнительно требует фразу **`ОЧИСТИТЬ ВСЁ`** / **`CLEAR ALL`**. Перед очисткой журналы экспортируются в `logs_backup_*`.

Имеет смысл **сначала** сохранить отчёт диагностики, **потом** чистить журналы. После очистки диагностика увидит только новые события.

---

## Как устроен отчёт

```text
КРАТКАЯ ШАПКА            ← вердикт, вес событий, сравнение, «после обновления»
КРАТКИЙ ВЕРДИКТ
Самопроверка             ← дампы, Fast Startup, ожидание reboot
Сведения о системе       ← в т.ч. дата BIOS
Диски и тома + SMART
Память / температуры / батарея
Сон / Fast Startup
WHEA
Kernel-Power 41 / 6008   ← ±5 мин
BSOD                     ← STOP + модуль
События диска, dirty bit / CHKDSK
GPU / USB / PCIe
Краши системных процессов (игры скрыты)
Драйверы / обновления Windows / Reliability
Топ источников / устройства
Частота и вес / сравнение с прошлым
АНАЛИЗ И РЕКОМЕНДАЦИИ
СВОДКА
```

Файлы: `WinErrorParser_Report_RU_гггг-ММ-дд_ЧЧммсс.txt` и одноимённый `.html` (UTF-8 с BOM). Третьего дубля без даты нет.

---

## Разделы диагностики

Период по умолчанию: **14 дней** (меню **3** или параметр `-DaysBack`).

1. Самопроверка — админ, дампы BSOD, Fast Startup, ожидание перезагрузки.  
2. Система — ОС, модель, CPU, RAM, BIOS **с датой**, uptime.  
3. Диски/тома — статус, место, `Get-PhysicalDisk`, SMART.  
4. RAM — модули + Memory Diagnostics.  
5. Температуры ACPI, частота CPU (троттлинг), батарея.  
6. Сон / 41 после resume / Fast Startup.  
7. WHEA, Kernel-Power **41**, EventLog **6008**, BSOD.  
8. disk / NTFS / volmgr / NVMe, dirty bit, CHKDSK.  
9. GPU и отвалы USB / сети / PCIe.  
10. Краши только системных процессов; игры и браузеры скрыты.  
11. Свежие драйверы и дата последнего обновления Windows.  
12. Частота событий и сравнение с прошлым отчётом.  
13. Анализ и рекомендации только по найденным фактам.

---

## Расшифровка BSOD

Для каждого синего экрана скрипт старается показать:

- **код** (`0x000000D1`) и **имя** (`DRIVER_IRQL_NOT_LESS_OR_EQUAL`);
- **вероятную область** (драйвер, RAM, диск, GPU, питание, системный процесс);
- **модуль или процесс** из текста события, параметров Kernel-Power 41 или файла `Report.wer`;
- **человеческое пояснение**, что обычно ломается при этом STOP.

Источники кода: WER SystemErrorReporting, провайдер BugCheck, поле `BugcheckCode` у Kernel-Power 41, архив Windows Error Reporting, сопоставление минидампов по времени.

База покрывает частые коды (`0xA`, `0x1A`, `0x3B`, `0x50`, `0x7E`, `0x9F`, `0xD1`, `0xEF`, `0x116`, `0x124`, `0x133` и др.). Неизвестный код всё равно выводится — без выдуманной причины.

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
- серия ошибок диска сильнее единичного 153;
- BSOD → минидампы, код STOP, драйвер из стека;
- WHEA / RAM → `mdsched`, XMP/разгон, BIOS, температуры;
- GPU → чистая переустановка драйвера;
- 41 после сна / Fast Startup → полное выключение для проверки;
- dirty bit → бэкап и проверка тома;
- дампы выключены → включить минидампы, иначе следующий BSOD пропадёт.

Общих шаблонов вроде «почините Windows Update» нет. Дата последнего KB показывается только как контекст.

---

## Что скрывается как шум

В отчёт **намеренно не попадают** (обычно не ломают ПК):

- Windows Update Client (кроме отдельного блока «последнее обновление»)
- DCOM, DNS, DHCP, служба времени
- Service Control Manager (как отдельный топ)
- TPM / SPP / PerfNet / ETW и похожий фон
- краши Steam, Chrome, Discord, игр и прочего бытового софта

Их всё ещё можно смотреть вручную в `eventvwr.msc`. Полный режим (меню **4**) показывает служебный шум, но **не** подмешивает игры в вердикт железа.

---

## Типичные связки симптомов

| Симптом | Куда смотреть в отчёте |
|---------|-------------------------|
| Внезапная перезагрузка | Kernel-Power 41 + блок ±5 мин + сон / Fast Startup |
| Синий экран | BSOD / Minidump + «дампы включены?» |
| Зависания, отвал диска | disk / volmgr / stornvme + dirty bit |
| «Сломалось после обновления» | блок обновлений Windows + свежие драйверы |
| Артефакты / TDR | Display / GPU |
| Отвал флешки / сети / слота | USB / NDIS / PCIe |
| WHEA ID 3 | PCIe / NVMe / RAM / CPU |

---

## Ошибка ParserError / кракозябры

Если видите `Unexpected token`, `hash literal was incomplete`, кириллица как `P?P?`:

→ `WinErrorParser.ps1` сохранён **не** как UTF-8 with BOM.

В VS Code: **Save with Encoding → UTF-8 with BOM**.  
Bat-файл должен быть **без BOM**.

---

## Проверка файлов (SHA256)

После клонирования можно сверить хеши:

```powershell
Get-FileHash .\WinErrorParser.ps1, .\Start-WinErrorParser.bat -Algorithm SHA256
```

| Файл | SHA256 |
|------|--------|
| `WinErrorParser.ps1` | `62F4219B86487DEAABA4D6E98D896A1E774B01AF5E6AC6B0D06110F83F127D0A` |
| `Start-WinErrorParser.bat` | `3F05F9EEF56ACDD039016C0980D6B42D3890F16A770374927F1BF4C460C70EEA` |

Хеши относятся к релизу **2.1.0**. Если правили файлы локально — они изменятся.

---

## Ограничения и FAQ

- Не заменяет Memtest86 и SMART-утилиты производителя SSD.  
- Очищенный журнал → «всё зелёное» не значит, что проблем не было раньше.  
- Без администратора диагностика неполная, очистка недоступна.  
- Только Windows. Интернет не используется и не нужен.  
- Полный NVMe SMART Windows не отдаёт — для атрибутов нужна утилита производителя.

**Как изменить период анализа?**  
Пункт меню **3** или параметр `-DaysBack`.

**Отчёт пропал после повторного запуска?**  
Каждый запуск создаёт два файла с датой в имени: `.txt` и `.html`. Старые не затираются.

**Очистка удаляет отчёт?**  
Нет. Чистятся только журналы Windows.

**Лицензия?**  
[MIT](LICENSE) — можно копировать, менять и выкладывать с указанием копирайта.

---

## Краткая шпаргалка (RU)

```text
Запуск:     Start-WinErrorParser.bat  (администратор)
Меню:       1 диагностика | 2 очистка | 3 период | 4 полный отчёт | 5 язык
            6 последний HTML | 7 список отчётов | 8 ZIP
Скрипт:     WinErrorParser.ps1        (UTF-8 с BOM), v2.1
Отчёт:      WinErrorParser_Report_RU_дата.txt + .html
Период:     14 дней (меню), корреляция ±5 мин
Фокус:      неисправности железа + расшифровка BSOD
```

<p align="right"><a href="#winerrorparser">⬆ К переключателю языка</a></p>

---

# 🇬🇧 English version

**WinErrorParser 2.1** is a standalone Windows PC diagnostics tool. It reads Event Logs and hardware inventory, filters noise, **decodes BSODs** (STOP code, module/process, likely cause), analyzes critical failures (including a **±5 minute** window around Kernel-Power / BSOD / WHEA / disk), and writes a **Russian or English report** to the console, a timestamped text file, and HTML.

No Internet required. Diagnostics are read-only for the OS; log clearing (menu item) changes Event Log only after explicit confirmation.

### What’s new in 2.1

- Executive summary at the top of the TXT and HTML jump links.
- Event **weight**: a single hit vs a repeating series.
- **Diff against the previous run** in the same folder.
- Game/browser crashes are hidden and **do not** drive the hardware verdict.
- “Broke after a Windows update” context.
- Sleep / Fast Startup, dirty bit / CHKDSK, USB-NIC-PCIe dropouts, dump settings, pending reboot, BIOS date.
- Menu: open last HTML, recent reports, ZIP the last TXT+HTML pair.

### Quick start (EN)

1. Put `Start-WinErrorParser.bat` and `WinErrorParser.ps1` in the **same** folder.
2. Right-click the bat → **Run as administrator**.
3. Menu:
   - **1** — PC diagnostics
   - **2** — clear Event Logs
   - **3** — analysis period
   - **4** — faults-only / full report
   - **5** — report language RU/EN
   - **6** — open last HTML
   - **7** — recent reports
   - **8** — ZIP the last report
   - **0** — exit
4. After diagnostics, open the timestamped `WinErrorParser_Report_*.txt` or `.html`. A short summary is also copied to the clipboard.

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
13. [File hashes (SHA256)](#file-hashes-sha256)
14. [Limits & FAQ](#limits--faq)
15. [Russian version](#-русская-версия)

---

## Menu

```text
1. PC diagnostics (logs + hardware)
2. Clear Event Logs
3. Analysis period
4. Report mode: faults / full
5. Language: ru / en
6. Open last HTML report
7. Recent reports
8. Pack last report into a ZIP
0. Exit
```

After diagnostics or cleanup you return to the menu.

---

## Features

| Feature | Purpose |
|---------|---------|
| Menu: diagnose / clear / archive | Period, language, last HTML, ZIP |
| RU/EN report (console + `.txt` + HTML) | Timestamped archive + clipboard summary |
| Executive summary + HTML anchors | Verdict and event weight at the top |
| Event frequency | Single vs repeating series |
| Diff vs previous run | New / increased / gone |
| BSOD decode | STOP code, name, module/process, likely area |
| Noise filter or full mode | Update / DCOM / DNS hidden |
| Game/browser crashes | Hidden; they do **not** affect the hardware verdict |
| ±5 min correlation | System + Application + Setup around critical events |
| System / disks / SMART / RAM | Model, volumes, PhysicalDisk, reliability counters |
| WHEA, Kernel-Power 41, EventLog 6008 | Hardware faults, sudden reboots |
| Sleep / Fast Startup / dumps | 41 after resume; are minidumps enabled? |
| Dirty bit / CHKDSK | Volume was not closed cleanly |
| USB / NIC / PCIe | Bus dropouts, not only the SSD |
| Windows update context | Did faults start after the last KB? |
| Event Log cleanup | Exports `.evtx` first; wipe-all is behind `CLEAR ALL` |

---

## Project files

| File | Role |
|------|------|
| `Start-WinErrorParser.bat` | Launcher (ASCII, **no BOM**), UAC, `.ps1` BOM check |
| `WinErrorParser.ps1` | Menu, diagnostics, log clear (**UTF-8 with BOM**), v2.1 |
| `LICENSE` | MIT |
| `docs/preview.svg` | Dashboard preview for GitHub |
| `WinErrorParser_Report_RU_date.txt` + `.html` | Two files per run (not committed) |
| `README.md` | This guide (RU + EN) |

---

## Requirements

- Windows 10 / 11 (Windows PowerShell 5.1).
- **Administrator** rights for full diagnostics and log clearing.
- No Internet.

Diagnostics do not change services/registry/drivers. Log clear only touches Event Log after typing `ДА` or `YES` (logs are exported to `logs_backup_*` first).

---

## How to run

1. Place both files in one folder.
2. Run the bat as administrator.
3. Pick a menu item.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\WinErrorParser.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\WinErrorParser.ps1" -NonInteractive -DaysBack 30 -Language en -Action Diagnose
```

Parameters: `-DaysBack`, `-Language ru|en`, `-FullReport`, `-NonInteractive`, `-Action Menu|Diagnose`, `-ReportPath`, `-NoHtml`.

---

## Clearing Event Logs

Menu item **2** (admin required).

| Mode | Clears |
|------|--------|
| 1 | System, Application, Setup |
| 2 | Same + Security |
| 3 | All enabled logs that contain records |

Confirm by typing **`ДА`** or **`YES`**. Mode 9 (all logs) also requires **`CLEAR ALL`** / **`ОЧИСТИТЬ ВСЁ`**. Save the diagnostics report first if you need the old evidence.

---

## Report layout

Self-check → System → Disks → RAM → Sleep → WHEA → Kernel-Power 41 (±5 min) → BSOD → Disk / dirty volume → GPU / bus → system-process crashes → drivers / Windows update → frequency / previous-run diff → **fact-based analysis** → Summary.

The saved TXT starts with an **executive summary**. Report files: timestamped `WinErrorParser_Report_RU_yyyy-MM-dd_HHmmss.txt` and the matching `.html` (UTF-8 with BOM).

Default window: **14 days** (`$Script:DaysBack`).

---

## Diagnostic sections

Default period: **14 days** (menu **3** or `-DaysBack`).

Inventory and SMART, WHEA / Kernel-Power 41 / BSOD decode, storage stack, GPU TDR, sleep/Fast Startup, dirty volumes, USB-NIC-PCIe, update timing, event weight, and a diff against the last run in the same folder.

---

## ±5 minute analysis

For each critical event the script shows before/anchor/after entries and a short window conclusion (storage / WHEA / BSOD / GPU / no clear cause). Noise providers are filtered here too.

---

## Fact-based recommendations

Built only from findings: 41+disk → backup & SSD; repeating disk errors outweigh a one-off; BSOD → dumps & STOP code; WHEA/RAM → `mdsched` & XMP off; GPU → clean driver reinstall; 41 after sleep → disable Fast Startup; dirty bit → backup & volume check. No generic “fix Windows Update” checklist.

---

## Noise filtering

Intentionally hidden from the verdict: Windows Update Client, DCOM, DNS/DHCP, Time service, SCM as a top noise source, TPM/SPP/PerfNet-like background, and **game/browser crashes**. Use Event Viewer manually if you need them. Full-report mode still does not treat Steam/Chrome as hardware.

---

## ParserError

`Unexpected token` / `hash literal was incomplete` → save `WinErrorParser.ps1` as **UTF-8 with BOM**. Keep the `.bat` **without** BOM.

---

## File hashes (SHA256)

```powershell
Get-FileHash .\WinErrorParser.ps1, .\Start-WinErrorParser.bat -Algorithm SHA256
```

| File | SHA256 |
|------|--------|
| `WinErrorParser.ps1` | `62F4219B86487DEAABA4D6E98D896A1E774B01AF5E6AC6B0D06110F83F127D0A` |
| `Start-WinErrorParser.bat` | `3F05F9EEF56ACDD039016C0980D6B42D3890F16A770374927F1BF4C460C70EEA` |

Hashes are for release **2.1.0**.

---

## Limits & FAQ

- Not a replacement for Memtest86 or vendor SSD tools.
- Cleared logs can look “all green”.
- Non-admin = incomplete diagnostics; log clear disabled.
- Windows only. No Internet is used.
- Windows does not expose full NVMe SMART.

**Change analysis period:** menu item **3** or `-DaysBack`.  
**Report overwritten?** Each run creates a new timestamped `.txt` + `.html` pair. Old files are kept.  
**Does log clear delete the report file?** No — only Windows Event Logs.  
**License:** [MIT](LICENSE).

---

## Cheat sheet (EN)

```text
Launch:   Start-WinErrorParser.bat  (Administrator)
Menu:     1 diagnose | 2 clear | 3 period | 4 full report | 5 language
          6 last HTML | 7 recent reports | 8 ZIP
Script:   WinErrorParser.ps1        (UTF-8 with BOM), v2.1
Report:   WinErrorParser_Report_RU_date.txt + .html
Window:   14 days (menu), ±5 min correlation
Focus:    real hardware faults + BSOD decode
```

<p align="right"><a href="#winerrorparser">⬆ Back to language switcher</a></p>
