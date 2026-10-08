# Config, DNS и подготовка данных — 8 октября 2026

Проверенные изменения установлены на 192.168.90.1 только в локальный backend Forkop 2.0.0. Работа выполнена на существующей main с сохранением незакоммиченных изменений предыдущих этапов. Релиз, публикация, commit и обновление sing-box X не выполнялись. Обе существующие VMware ВМ восстановлены в прежние production-модули и рабочий runtime.

## Результат на роутере

Сначала снят новый профиль установленного backend с SHA-256 reuse SRS. Затем выполнены два полных manual_restart с новым backend. Внешние границы измерены через /proc/uptime; вложенные метки тоже монотонные, разрешение 0,01 с. Это отдельные последовательные измерения с реальной подпиской и сетью, а не статистическая парная серия.

| Этап | До новых изменений | После, установка | После, контроль |
|---|---:|---:|---:|
| Полный вызов manual_restart, внешние границы | 34,03 с | 29,92 с | 28,98 с |
| manual_restart, внутри lifecycle | 33,99 с | 29,87 с | 28,93 с |
| subscription-prepare-only | 2,97 с | 2,13 с | 2,21 с |
| list-update preparation | 2,91 с | 2,95 с | 2,93 с |
| Refresh SRS | 1,17 с | 1,18 с | 1,20 с |
| Внутренний restart | 26,68 с | 23,39 с | 22,37 с |
| stop_impl | 5,44 с | 2,94 с | 3,01 с |
| DNS restore | 3,04 с | 0,56 с | 0,65 с |
| Подготовка subscription cache при start, lifecycle | 1,24 с | 0,79 с | 0,79 с |
| singbox init-config, весь модуль | 2,76 с | 4,57 с | 3,54 с |
| Два/один запрос версии в init-config | 0,88 с | 0,43 с | 0,44 с |
| Сам процесс generator | 0,44 с | 0,43 с | около 0,43 с |
| sing-box check | 0,82 с | 3,10 с | 2,07 с |
| Start core вместе с ожиданием стабильности | 8,60 с | 8,61 с | 8,60 с |
| DNS configure | 2,73 с | 0,58 с | 0,56 с |
| start_impl | 20,52 с | 19,72 с | 18,65 с |

Вложенные строки не следует складывать с родительскими. Два DNS-перехода в исходном новом профиле занимали **5,77 с**, после — **1,14 / 1,21 с**. Раннее сообщение в чате ошибочно называло configure исходного профиля 3,06 с; raw log содержит 2,73 с. Время init-config целиком не уменьшилось из-за более медленного sing-box check; выигрыш устранения второго запроса версии виден отдельно. Причина изменения времени check не установлена. Проверка конфигурации сохранена, её не запускали параллельно с работающим core, чтобы не увеличивать пик памяти.

Наблюдаемая разница полного restart составляет 4,11 / 5,05 с. Она не является гарантией каждого запуска или холодного boot. Восьмисекундный минимальный возраст core сохранён. Reboot этого этапа не выполнялся, прежние проверки SRS после reboot не повторялись.

## Устранение повторных запросов версии

В singbox/runtime.uc init_config() получает core_version один раз и передаёт одну версию обоим аргументам генератора: capability и executable version. Сам вызов не устанавливает пакеты и не изменяет core.

В subscription/cache.uc успешное определение default User-Agent используется повторно в пределах одной операции подготовки/обновления. Кэш сбрасывается при update_subscription_source(), prepare_subscription_caches() и subscription_bootstrap_retry_result(). Поэтому длительный bootstrap worker не сохраняет старую версию между попытками. Неуспешное определение не кэшируется; появившийся позднее core проверяется вновь. Явный custom User-Agent не вызывает определения версии.

Исходный профиль подтвердил три запуска executable version перед restart и два при подготовке startup-cache, около 0,43 с каждый. После — один в каждой фазе; повторные get_subscription_user_agent() занимают 0,00–0,01 с. Новый tests/subscription_version_snapshot.sh проверяет число вызовов, custom UA, новый operation snapshot и повтор после отсутствующего core. Он прошёл локально и на обеих ВМ. Проверки sing_box_runtime, subscription_bootstrap_dns и manual_restart_contract также прошли.

Сама генерация JSON занимала около 0,44 с, а не все прежние 3–4 с init-config. Массовое изменение generator, правил, сортировок и повторного чтения UCI по этому профилю не оправдано.

## DNS reload с проверкой готовности

Новый модуль dns/reload.uc вызывается существующим DNS transaction owner dns/apply.uc. Восстановление DNS между stop/start сохранено. Snapshot ownership, external-conflict handling, legacy cleanup и dont_touch_dhcp не переписаны.

Для штатного init и поддерживаемых listeners:

1. Фиксируются все dnsmasq UCI sections, реальные процессы, procd instances и прежнее содержимое generated configs.
2. Выполняется штатный reload, затем до четырёх секунд ожидается подтверждение применения.
3. Generated config проверяется против UCI по server (включая порядок), noresolv, cachesize и port. Нужный daemon определяется по точному executable /usr/sbin/dnsmasq и аргументу -C; процесс связывается с нужным procd instance по PID или parent PID jail-wrapper.
4. Когда generated config изменился, прежние PID/start_ticks не принимаются: требуется новый процесс. Затем проверяются принадлежащие этому daemon TCP LISTEN и UDP socket на нужном IPv4 loopback/wildcard port и DNS protocol response на этот port. Проверка выполняется дважды с интервалом 50 мс; config и identity перечитываются после запроса.
5. Probe использует version.bind TXT CH с +norecurse, без рекурсивной проверки WAN. NOERROR, REFUSED, NXDOMAIN и NOTIMP принимаются как protocol response; socket ownership и новая конфигурация проверяются независимо. SERVFAIL не считается готовностью.
6. port=0 не требует ответа на несуществующем DNS port: проверяются новый config и принадлежащий instance daemon. Disabled/deleted instances не должны оставаться работающими. При нескольких enabled instances каждый проверяется отдельно.
7. Ошибка reload или истечение readiness deadline приводит к restart и повторной проверке до восьми секунд. Если restart тоже не применил config, возвращается ошибка; старый отвечающий DNS не даёт ложного успеха.

Команды init ограничены 15 секундами через system() с exec; убраны дополнительные ожидающие shell. Readiness dig ограничен оставшимся deadline и максимум 1,1 с, ubus — одной секундой. При худшем отказе двух команд и двух проверок время существенно больше нормального пути: до примерно 42 с плюс ограниченные накладные расходы. Timeout не является обещанием завершения всех потомков произвольного модифицированного init-скрипта; зависающий сторонний init и его process tree отдельно не тестировались.

OpenWrt 24 не имеет fs.mkdtemp: для закрытого временного каталога используется совместимый mktemp -d. OpenWrt 25 использует native fs.mkdtemp. При невозможности получить procd/process evidence штатный reload не принимается, а попытка restart всё равно должна пройти readiness.

### Область поддержки и ограничения

Оптимизированный путь проверен для обычного OpenWrt dnsmasq с IPv4 loopback/wildcard listeners, несколькими instances, custom port и port=0. Настройки, явно исключающие loopback или ограничивающие интерфейсы/listen_address другими адресами, а также нестандартный DNSMASQ_INIT/неизвестный UCI layout сохраняют прежний restart-путь. Для них ускорение и новая проверка protocol readiness не заявляются. IPv6-only listeners отдельно не тестировались. Изменения произвольных include-файлов, confdir и scripts сторонним компонентом во время перехода не покрываются проверкой основных управляемых параметров. Это кандидат с явно ограниченной областью применения, проверенный и установленный на данном роутере, а не универсальная гарантия для всех конфигураций dnsmasq.

## Отказы на обеих ВМ

Использованы существующие 192.168.1.1 и 192.168.241.2; замены ВМ и установки пакетов не было. Перед воздействием сохранены package/service state, dhcp и init, несмотря на разрешение пользователя пропустить эти snapshots. Все воздействия ограничены соответствующей ВМ.

На обеих прошли:

- unchanged reload и применение нового cachesize;
- два instances с отдельным port=1053, переход дополнительного instance на port=0, затем disabled;
- reload с ненулевым status → рабочий restart;
- reload, возвращающий 0 без применения нового config → readiness timeout и рабочий restart;
- reload, останавливающий dnsmasq без запуска → readiness timeout и рабочий restart;
- оба init actions возвращают ошибку → отказ без ложного успеха;
- оба actions возвращают 0, но оставляют старую конфигурацию → отказ через 12,06 / 12,08 с;
- нормальный переход после этих ошибок → recovery;
- недоступный procd evidence при init wrapper, возвращающем 0: reload пропускается, restart без подтверждения отвергается, работающий прежний runtime сохраняется (дополнительный тест на обеих ВМ);
- полный Forkop restart с новыми runtime/subscription/DNS-модулями;
- dont_touch_dhcp восстанавливает прошлую транзакцию и не оставляет перенаправление на core;
- отказ generator после остановки core оставляет восстановленный DNS и потреблённый snapshot; следующий start восстанавливает рабочий core.

Normal changed-config readiness около 0,18 с на обеих; дополнительные instances — 0,24–0,48 с. Ошибка команды с fallback — 0,44–1,37 с. No-op/stopped reload с fallback — около 4,44–4,48 с.

Первый кандидат отвергал NOTIMP и нуждался в исправлении. При добавлении deadline выявлена ошибка порядка объявления monotonic в ucode; она исправлена до установки. Финальный OpenWrt 24 повтор сначала использовал неподдерживаемую fs.mkdtemp и уходил в прежний restart-путь, поэтому тот запуск не считался проверкой reload; после совместимого helper и запрета такого fail-open полный тест пройден. Внешний тестовый DNS probe также переведён на +norecurse. Все неуспешные тестовые запуски завершались восстановлением init/dhcp и working runtime.

После экспериментов исходные модули и init восстановлены и cmp проверены, новые DNS helper/fixture links убраны с ВМ, тестовые forkop_probe generated config/hosts/confdir удалены, UCI instance отсутствует. Один sing-box и DNS проверены. Локально прошли tests/dns_reload_config.sh и dns_rollback_transaction через dns_apply.sh. Интеграционный тест сохранён в tests/dns_reload_vm.sh; запускать его только на тестовой ВМ с /tmp/reload_candidate.uc из dns/reload.uc и нужным module search path.

## Сеть, обработка и публикация

Детализация первого нового запуска на реальном роутере:

| Подписка | Время |
|---|---:|
| Вся subscription-prepare-only | 2,13 с |
| Запрос version для default UA | 0,43 с |
| Загрузка body/headers | 0,15 с |
| Gzip detection/decode | 0,01 с |
| Извлечение UI metadata | 0,09 с |
| Нормализация и проверка body | 0,27 с |
| Пополнение direct share links | 0,20 с |
| Сохранение identity/filter metadata | 0,05 с |
| Persistent publication | 0,07 с |
| Финализация metadata section | 0,01 с |

Остаток включает проверку/чтение существующих кэшей, выбор request profiles, UCI/lock/helper coordination и logging; эти составляющие не полностью разделены. Контрольный запуск подтвердил network 0,17 с, processing около тех же 0,63 с и persistent publication 0,06 с. JSON, URL и секреты подписки оставались только на роутере.

| Обычные списки, отдельная от SRS-cache транзакция | Время |
|---|---:|
| Весь list-update preparation | 2,95 с |
| DNS preflight | 0,04 с |
| Семь последовательных загрузок | 0,61 с |
| Validation staged sources, главным образом один binary | около 0,43 с |
| Import builtin subnet lists | 0,66 с |
| Import custom rule sets/subnets | 0,52 с |
| Runtime generation commit | 0,13 с |
| Persistent cache publication | 0,24 с |

Некоторые строки вложенные; таблица описывает наблюдаемые вызовы, не независимые предполагаемые выигрыши. При start cached list application повторяет локальный import, около 0,65 + 0,52 с, без повторного скачивания. Его nft candidate/atomic generation semantics сохранены. Отдельный восьмифайловый SRS-cache refresh стабильно около 1,18–1,20 с; новый профиль не разделял его network/hash/publication заново, поскольку такое исследование уже выполнено ранее.

Параллелизм не введён: на этом наборе абсолютный потолок устранения последовательного network ожидания обычных списков меньше секунды, а подписки — около 0,17 с. Processing, checks и публикация заметнее. Параллельный parser и дополнительная memory load не оправданы этими измерениями.

## Установка, сохранность и артефакты

Финальный APK: tmp/optimization-review-20261008/next-profile/packages/forkop_2.0.0.apk.

SHA-256: **4bbbe40005ab5ac2e8387c3da67c4f85d3af744e782de518b3e2a10e714dd9e3**.

Собраны APK и IPK backend/LuCI/i18n, установлен только backend offline, force-reinstall, no-scripts в ту же локальную версию. Container verify и SHA-256 target/rollback выполнены. Симуляция и установка заменили только forkop; осталось 271 packages. Исходный exact rollback APK проверен: 0e4b9e08da65d026321fcb71d8a4ebcec8115ca65ade54324e470022756d9ad3.

До воздействия сохранены package/procd state, UCI/generated config, модули и rollback APK в root-only /tmp/forkop-next-install-20261008. Автоматический rollback подготовлен, но не потребовался. Конфигурации и backup с секретами не выгружались на операторский компьютер. Эта новая резервная копия, как и прежние три подтверждённые копии, исчезнет после reboot.

После обоих запусков:

- Один sing-box, forkop-stably-running с min_age=8 успешен, Forkop running/enabled; sing-box running, его отдельный autostart по-прежнему disabled.
- DNS отвечает, настоящий HTTPS через SOCKS 192.168.90.1:2080 вернул 204.
- /etc/config/forkop, /etc/config/sing-box и /usr/bin/sing-box SHA-256 сохранены.
- sing-box-x остаётся 1.0.1-r1, executable исходный 1.14.2-x-1.0.1.
- nfqws отдельного Zapret остались PID 2809/2810.
- Installed runtime/subscription/DNS source совпал с repo/package SHA-256. Все восемь диагностических модулей восстановлены в installed production source и cmp проверены.
- Generated config отличается только порядком 20 тех же членов provider URLTest-группы; member set совпадает, другие поля равны. Причина подтверждена исходником: generator применяет runtime_urltest.rotate_start() с /proc/sys/kernel/random/uuid seed. Это отличие от прежнего этапа, где наблюдали сортировку selector; здесь type именно urltest. Сравнение, исключающее только selector order, поэтому ожидаемо вернуло false и затем было подробно разобрано на самом роутере.

Raw timings и build/test logs: tmp/optimization-review-20261008/next-profile/ — router-timings.log (исходный профиль), router-final-timings.log, router-confirm-timings.log, vm24/25-dns.log, vm24/25-runtime.log, vm24/25-evidence.log, build-final.log. Скрипты instrument.py, router-install.sh, router-confirm.sh и dns-evidence-vm.sh диагностические; profiling-код не включён в production package. git diff --check прошёл.
