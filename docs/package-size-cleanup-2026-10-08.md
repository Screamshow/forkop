# Очистка legacy и размеры пакетов — 8 октября 2026

Работа выполнена на существующей main с сохранением предыдущих изменений. Новые изменения этого этапа находятся в рабочей копии и локальных пакетах 2.0.0. На пользовательском роутере этот этап не устанавливался; Sing-Box X не менялся. Публикация, commit и выпуск 2.1.0-canary.1 не выполнялись.

## Внедрённые изменения в рабочей копии

* Удалена невызываемая restore_list_nft_snapshot, возвращавшая true. Удалены никогда не заданный list_nft_snapshot_file, неиспользуемый аргумент commit и недостижимая ветка сообщения об ошибке восстановления. Реальные восстановление rule-set файлов и транзакции cache/runtime generation сохранены.
* Существующие begin/finish helpers переименованы в begin_list_nft_candidate/discard_list_nft_candidate. Сообщение об ошибке больше не утверждает, что делается snapshot активной таблицы: подготовка записывает отдельный nft batch.
* list_update_reload_policy больше не требует наличия пустой restore-функции. Он проверяет запись в candidate и вызов cleanup. list_update_final_reload дополнен отказом source transaction: нет runtime apply, сохранены committed generation и pending list/ruleset retry.
* shell_inventory актуализирован точным списком уже существующих support helpers, forkop-support и package-init. Запрет возвращения legacy shell owners сохранён.
* tsup для main.js использует только minifyWhitespace. minifySyntax и minifyIdentifiers отключены. Ручные JS-файлы, включая section.js, не изменялись; LUCI_MINIFY_JS=0 сохранён.

## Размеры

| Что измерено | До | После | Разница |
| --- | ---: | ---: | ---: |
| main.js из репозитория | 469619 байт | 369482 байта | 100137 байт / 97,79 КиБ |
| updates.uc в payload IPK | 174862 байта | 174389 байт | 473 байта |
| luci-app-forkop APK | 221882 байта | 211066 байт | 10816 байт / 10,56 КиБ |
| luci-app-forkop IPK | 223794 байта | 211837 байт | 11957 байт / 11,68 КиБ |
| forkop APK | 370601 байт | 370494 байта | 107 байт |
| forkop IPK | 371850 байт | 371769 байт | 81 байт |

Это сравнение с локальными пакетами предыдущего этапа next-profile. Размеры архивов включают упаковку и metadata; снижение размера JS-файла не равно снижению APK/IPK на ту же величину. Физический выигрыш overlay/squashfs отдельно не измерен. Старые 150 КиБ относятся к оценке компактности всех JS-файлов; этот этап реализует только main.js.

## Проверки

* TypeScript checking и tsup build прошли; 559 frontend-тестов в 53 файлах прошли.
* AST baseline из HEAD main.js и новой сборки совпали после удаления только positions/comments/raw spelling metadata. Имена, выражения, порядок и директивы сохранены.
* Прочитан настоящий LuCI loader на обеих ВМ: require directives разбираются сканированием строковых литералов, не по отдельным строкам файла. Компактное размещение строковых директив совместимо с этой реализацией. Это проверка loader source и AST, не полный browser UI test.
* Локально shell_inventory, list_update_reload_policy, list_update_final_reload и nft_atomic_apply прошли. list_update_final_reload выводит предупреждение отсутствующего /usr/lib/forkop/service/state.uc в одном изолированном fixture пути WSL; тест завершился успешно. На ВМ этот helper существует и такого предупреждения нет.
* На обеих ВМ временно заменены только updates.uc и main.js после сохранения package/service state и оригинальных файлов. Отказной final reload test, policy test и atomic candidate test прошли.
* OpenWrt 25 прошла полный restart с кандидатом. На OpenWrt 24 первый запуск тестового runner не выполнил tests из-за отсутствия bash; runner переведён на совместимый ash/sh без установки пакетов. Следующий запуск прошёл tests, но не дошёл до подтверждения candidate runtime. После восстановления оригиналов readiness/DNS прошли; отдельный baseline restart вернул 0. Повторный candidate restart затем прошёл с CANDIDATE_RUNTIME_VERIFIED. Причина первого runtime неуспеха не установлена; обновление DHCP во время операции само по себе не доказывает причинность.
* Обе ВМ после тестов получили исходные updates.uc/main.js, сравнение cmp успешно, one-core/stably-running/DNS и неизменный package list проверены. Временные подмены production-файлов убраны; diagnostics/backup остаются в /tmp/forkop-size-cleanup-20261008.
* APK/IPK backend/LuCI/i18n собраны и metadata проверены build.sh. Новые пакеты на ВМ не устанавливались: VM coverage относится к source overlay. Полное browser UI coverage форм/переводов/RPC и package install/upgrade этого нового этапа остаётся до установки клиентам.
* git diff --check прошёл.

## Актуализация после выполнения плана

Этот документ фиксирует предыдущий промежуточный этап. Последующие реальные package install/upgrade/rollback, browser UI Save & Apply, минификация остальных JS и установка на роутер описаны в optimization-plan-stage2-2026-10-08.md. Старый WSL bytecode 0x00 оказался несовместим с текущими native runtimes; отдельная native 0x01 сборка прошла только loader/read-command matrix и не установлена в production.

## UPX и дальнейшее уменьшение

Установленный Sing-Box X 1.0.1 уже упакован UPX -9 после Go -s -w. Build script выполняет upx -t. На пользовательском ARM64 роутере executable сейчас **8537372 байта / 8,14 МиБ**, на обеих x86 ВМ — **9863528 байт / 9,41 МиБ**. Повторно упаковывать уже упакованный бинарник как отдельную оптимизацию не имеет смысла. Эксперименты более сильного сжатия, если понадобятся, должны начинаться с исходного ELF и проходить повторную проверку integrity/startup/RAM; выигрыш не измерен.

Forkop backend — набор ucode, shell, конфигураций и ресурсов, а LuCI — JS. /usr/bin/forkop является shebang ucode entrypoint, не ELF. UPX применим к поддерживаемым executable formats, не к APK/IPK, JS или ucode source. Оборачивать весь backend самораспаковывающимся ELF ради этого нецелесообразно: это добавит новый loader, RAM/workspace и риски recovery. APK/IPK и так сжимают свои данные.

Повторный локальный эксперимент с текущими 68 .uc модулями: **1877848 байт текста → 1340836 байт stripped bytecode**, разница **537012 байт / 524,43 КиБ**. Скрипт bytecode-size.py компилирует отдельный каталог, не заменяя production. Это свежий размерный кандидат; runtime совместимость и package hooks этого варианта не проверены. Для принятия нужны matrix ucode/OpenWrt, shebang/loader, installation/update/rollback, migrations и reboot. Предыдущий эксперимент не подтвердил заметного ускорения restart одним bytecode.

Другие следующие кандидаты:

1. Компактная упаковка section.js и остальных ручных LuCI-файлов с сохранением readable source и проверкой top-level return/require. Старый остаточный потенциал около 50 КиБ, свежая оценка ещё не выполнена.
2. Перенос тестовых fixture entrypoints из production с сохранением доступа тестов к настоящим алгоритмам. Верхняя старая оценка около 40 КиБ, это не безопасное массовое удаление функций.
3. Stripped bytecode после проверки совместимости. Он даёт гораздо больший потенциал, чем дальнейшая уборка нескольких пустых функций.
4. CLI-only сокращение Sing-Box X отдельным profile: старый эксперимент около 99512 байт ARM64 и 117580 байт x86_64 после UPX. Функциональность CLI меняется, поэтому это отдельный компонентный выпуск, не часть backend cleanup.

bind-dig, миграции, package rollback, arbitrary outbound/inbound JSON и QUIC sniffing/blocking сохранять. Удаление некомпилируемых Go исходников не уменьшает executable.

## Артефакты

`tmp/optimization-review-20261008/size-cleanup`: build.log, packages, VM logs, main.before.js и bytecode-size.json/bytecode-size.py. Тестовая версия пакетов — 2.0.0.

* forkop APK SHA-256: dbfb475702111a0f7744c707ad38a979dd0d038669a5e95d89cb0fd8a6239fa8
* luci-app-forkop APK SHA-256: 58e358babb63f2edda951997ce67374ab7fa322d5237f1156ed9101e3507e257

Нового измеренного ускорения manual_restart на пользовательском роутере этот этап не заявляет. Предыдущие 29,92/28,98 с относятся к установленному предыдущему backend.
