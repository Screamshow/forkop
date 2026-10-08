# Проверенный этап плана оптимизации — 8 октября 2026

> Следующий этап завершён: точные пакеты 2.1.0-canary.1, SDK, clean install/upgrade/rollback/reboot, DNS/UI и парная router-серия. Актуальные результаты: [canary-2.1.0-validation-2026-10-08.md](canary-2.1.0-validation-2026-10-08.md). Публикации нет; клиентский пилот ждёт устройств.

> Исторический отчёт этапа. Актуальный итог двух чатов, статус кандидатов и оставшиеся проверки: [optimization-final-review-2026-10-08.md](optimization-final-review-2026-10-08.md). Bytecode рекомендуется отложить; он выключен по умолчанию и не входит в релиз.

Работа выполнена на существующей main, предыдущие незакоммиченные изменения сохранены. Ничего не публиковалось. Локальные пакеты имеют тестовую версию 2.0.0; релиз 2.1.0-canary.1 не создавался. Порог стабильного возраста core — 8 секунд.

## Принятые изменения

1. Основной main.js и восемь остальных JS-файлов LuCI упаковываются компактно. Ручные исходники остаются читаемыми; generated overlay используется build.sh и OpenWrt Makefile. Сохраняются require directives, top-level return и имена. Для ручных файлов Babel generator удаляет пробелы/комментарии; сборка проверяет совпадение AST без source positions и комментариев. Esbuild-кандидат для этих файлов отклонён: даже при minifySyntax=false он менял undefined на void 0.
2. generated/source.sha256 проверяет актуальность ручных исходников перед упаковкой. Generated manifest остаётся вне /www. Изменение ручного JS требует повторной frontend build. Прямой полный SDK build через Makefile на этом этапе не запускался; обе упаковки APK/IPK проверены через build.sh.
3. Убрана пустая nft snapshot-заглушка и недостижимая ветка candidate-кода lists из предыдущего этапа. Atomic publication, committed generation и deferred retry сохранены.
4. Проверка отсутствия DHCP-секции forkop в standalone installer передана его собственному временно доступному ucode helper. Пропуск остановки возможен только при положительном доказательстве отсутствия секции, core и nft table. Нет helper/UCI, не загружен dhcp или произошла ошибка — выполняется обычная остановка. Это архитектурная правка, ускорение не заявляется.
5. Актуализированы installer_owner и installer_package_upgrade_vm: текущий default X, прежний Tiny для backend до 2.0, получение standalone helper в VM fixture. Это изменение тестов, не новая смена default в продукте.

## Размер

| Объект | До | После | Уменьшение |
| --- | ---: | ---: | ---: |
| main.js с version placeholder | 469619 | 369482 | 100137 байт |
| Восемь ручных JS-файлов | 256199 | 203224 | 52975 байт |
| Все JS выше | 725818 | 572706 | **153112 байт / 149,52 КиБ** |
| LuCI APK | 221882 | 204897 | **16985 байт / 16,59 КиБ** |
| LuCI IPK | 223794 | 205344 | **18450 байт / 18,02 КиБ** |
| Backend APK | 370601 | 370494 | 107 байт |
| Backend IPK | 371850 | 371754 | 96 байт |

Архивы сравниваются с next-profile/packages предыдущего установленного этапа. Backend source cleanup составляет 473 байта. В установленном main.js placeholder заменён версией 2.0.0: абсолютные размеры ниже на 24 байта с обеих сторон; экономия та же. Разницу файлов, сжатых архивов, RAM и physical flash blocks нельзя считать одной величиной. Небольшие изменения размера архивов i18n не выдаются за оптимизацию переводов.

## Проверки

* TypeScript, tsup и 559 frontend-тестов в 53 файлах прошли. Сборка всех ручных JS прошла AST equivalence.
* На обеих существующих ВМ установлены реальные APK/IPK backend/LuCI/i18n, затем восстановлен точный предыдущий пакетный комплект next-profile, затем повторно установлен кандидат. Проверены хеши JS, сохранение UCI, один core, возраст 8 секунд, DNS и неизменный binary core. Это пакетные тесты, а не source overlay.
* Через реальные функции install.sh проверен переход со старых 2.0.0-canary.1 на 2.0.0 и повторный вызов. APK действительно выполнял upgrade rc1 → final; opkg считает canary.1 старше final и использует предусмотренный installer --force-downgrade. Повторный IPK вызов оказался up-to-date; отдельная принудительная переустановка уже проверена циклом выше. После этого runner восстановил кандидат и исходную конфигурацию.
* LuCI проверен headless Chrome/Playwright на обеих ВМ: шесть вкладок, русский интерфейс на 25 и английский на 24, редактор секции, изменение имени секции и Save & Apply. Новое имя подтверждено в UCI через SSH; исходная конфигурация и runtime затем восстановлены. Page errors отсутствуют. Временные root ubus sessions уничтожены; пароль root не изменялся. Первые ошибки runner были неверными селекторами Dismiss/Save & Apply, не ошибками приложения.
* installer_owner, installer_dhcp_detection, installer_update_rollback, shell_inventory, list_update_reload_policy и list_update_final_reload прошли. Отказные fixture намеренно вызывают ошибки tar/timeout; их финальные assertions прошли.
* Новая DHCP-проверка отдельно проверена для present/absent, отказа load, отсутствующего UCI и отсутствующего helper; реальные old-package hooks проверены на обеих ВМ.

## Пользовательский роутер

Установлен проверенный комплект из tmp/optimization-review-20261008/plan-stage2/packages. Перед воздействием сохранены пакеты, service state, UCI, generated config и исходные файлы; rollback APK payload предварительно сравнен с текущими файлами. Финальная копия находится в **/root/forkop-plan-stage2c-20261008**; прежние попытки в /root/forkop-plan-stage2-20261008 и /root/forkop-plan-stage2b-20261008. Эти каталоги находятся вне /tmp и не исчезают при обычном reboot; это не внешний резервный носитель.

Первый runner вернул ошибку и восстановил предыдущий комплект. При повторе с фазовыми метками выявлен config-comparison: URLTest отличался только циклическим сдвигом тех же 20 узлов на одну позицию. Причина подтверждена существующим generator.uc → runtime_urltest.rotate_start, а не новым backend patch. Остальные config fields совпали; unordered set сам по себе не принят за доказательство. Исправленный контроль нормализует только циклический сдвиг URLTest и прежний порядок selector, затем сравнивает весь config. Финальная установка прошла этот контроль. Предыдущие попытки сохранены, не считаются успешной установкой кандидата.

Подтверждены UCI/core hashes, package accounting, один sing-box, возраст 8 секунд, DNS и HTTPS через SOCKS (HTTP 204). Отдельный zapret-manager сохранил PID **2809/2810**. Sing-Box X остался 1.0.1-r1; SHA-256 executable: 4aeaf2a3915cde4507c9cc01fc6cf15fd87a8fea3a49097cd1d05ad86d71beb8. Роутер не reboot. Runtime libraries и /www содержат штатный кандидат без profiling overlays и bytecode; bytecode experiment лежит отдельно в /tmp.

Это подтверждение перечисленных сценариев, не гарантия всех клиентских конфигураций. На пользовательском роутере дополнительно проверена read-only загрузка шести вкладок LuCI без page errors и served main.js hash; редактирование и Save & Apply выполнены только на двух ВМ.

## Bytecode — отдельный эксперимент

68 модулей, текст **1877848 байт**. Старый WSL compiler создаёт bytecode version 0x00: **1340836 байт**. Все три native runtimes отвергли его с `Bytecode version mismatch, got 0x00, expected 0x01`. Поэтому старый размерный эксперимент нельзя считать пригодным payload.

Компиляция штатным ucode ВМ25 даёт version 0x01: **1342632 байта**, экономия **535216 байт / 522,67 КиБ**. Один и тот же архив проверен на:

| Устройство | ucode | Результат |
| --- | --- | --- |
| VM OpenWrt 24 x86_64 | 2025.07.18~3f64c808-r1 | Native loading всех 68 модулей; get_status/get_sing_box_status через FORKOP_LIB дают JSON |
| VM OpenWrt 25 x86_64 | 2026.01.16~85922056-r2 | Те же проверки прошли |
| Router OpenWrt 25 ARM64 | 2026.01.16~85922056-r1 | Те же проверки прошли |

Это loader/read-command matrix, не проверка запуска, DNS recovery, migrations, installation, rollback и reboot bytecode backend. Production libraries не заменялись. Нужен воспроизводимый совместимый host compiler и отдельная packaging/failure/reboot matrix. Bytecode в принятые изменения и установленный комплект не входит; дополнительное ускорение/RAM gain не измерено.

## Измерения времени и остаток плана

Нового измерения полного manual_restart на роутере этот этап не добавляет. По предыдущему этапу остаются 29,92/28,98 с, отдельные наблюдения, не парная серия. Длительность package reinstall или контрольного recovery не подменяет manual_restart benchmark. Обновлённый release draft включает подтверждённое уменьшение JS, но не обещает дополнительное ускорение или ускорение reboot.

Далее: совместимый bytecode build и полная матрица его отказов; выделение тестовых fixture entrypoints с сохранением production algorithms; точечный runtime profile; исследование orderly shutdown/cold boot. CLI сокращение X остаётся необязательным отдельным компонентным изменением. Протоколы, миграции, bind-dig, DNS recovery и 8 секунд не удаляются.

## Артефакты

tmp/optimization-review-20261008/plan-stage2: build.log, packages.json, VM cycle/installer logs, ui-save-check-retry.log, router-install-c.log, bytecode-native-build.log и три native bytecode logs. Секретные router config snapshots остаются на роутере.

* backend APK: d7cb202594a955fa84780686b6bb515d9111f574a1b1c54d07ee7fc2bc1e33b2
* backend IPK: e349e28d32cf2d7e582835aac274a9becbf92e6737957b1e8d27259960c35dc5
* LuCI APK: 5e4680d597d84db6c0cfaf97aa3fd9816f552c6731bc8aa6b08e055d806b8a2f
* LuCI IPK: b7576fd6c540c79cf72a390ad911a81f8e3e2b19b9c971166762c6d6428993b6
