# PlaudAddon — интеграция диктофона Plaud (выпущено в 4.5)

Аддон подключает личный аккаунт Plaud: модель в любом чате находит записи
встреч, читает AI-саммари по вкладкам и полные транскрипты; записи появляются
под ответами как чипы с полноценным превью (вкладки + транскрипт + аудио).
Работает с любым провайдером — тулзы исполняются на стороне приложения.

## Протокол (проверено на живом аккаунте, 2026-07-28)

Официальный пакет `@plaud-ai/mcp` — НЕ MCP-прокси, а тонкий REST-клиент.
Мы повторяем его напрямую на Swift, без Node:

- **API**: `https://platform.plaud.ai/developer/api`
  - `GET /open/third-party/users/current` — профиль
  - `POST /open/third-party/users/current/revoke` — отзыв доступа
  - `GET /open/third-party/files/?page=&page_size=` — список записей
  - `GET /open/third-party/files/{id}` — запись целиком
- **OAuth** (authorization code + PKCE S256):
  - авторизация: `https://web.plaud.ai/platform/oauth`
  - обмен/рефреш: `platform.plaud.ai/developer/api/oauth/third-party/access-token[/refresh]`
  - публичный `client_id` (`client_9c50…`), пустой secret (Basic `id:`)
  - redirect **строго** `http://localhost:8199/auth/callback` — порт зашит в
    регистрацию клиента; наш одноразовый NWListener слушает только loopback
- **Токены** — в Keychain (`APIKeyStore.AuxKey.plaud`, один JSON-блоб),
  авторефреш за 60 с до истечения + один ретрай на 401.

### Модель данных записи

- `note_list[]` — вкладки саммари: `data_type` (`auto_sum_note`, `high_light`, …),
  `data_tab_name` ("Summary", "Highlights"), контент Markdown.
- `source_list[]` — `data_type == "transaction"` держит транскрипт: JSON-массив
  сегментов `{start_time, end_time, content, speaker, original_speaker}` (мс).
- ⚠️ **Ловушка**: пустой `data_content` ⇒ контент за `data_link` — presigned
  S3-ссылка, живёт **~5 минут**. Правило: `content = data_content ||
  fetch(data_link)`, фетчить в том же вызове, ссылки не хранить.
- `presigned_url` — mp3, живёт 24 ч; S3 отдаёт Range ⇒ стриминг и перемотка.
- Необработанная запись (юзер не потратил кредиты): пустые `note_list` и
  `source_list`, нет `presigned_url`. Запустить обработку по API **нельзя** —
  всё API read-only (спикеров назначить тоже нельзя).
- Deep-link в веб-интерфейс: `https://web.plaud.ai/file/<id>` (формат из
  адресной строки самого приложения Plaud).

## Архитектура (Cuate/Addons/PlaudAddon/)

| Файл | Роль |
|---|---|
| `PlaudClient.swift` | actor: OAuth (PKCE, loopback-коллбэк, отмена), REST, резолв `data_link` |
| `PlaudAddon.swift` | синглтон: connect/disconnect, `isAvailable`, deep-link |
| `PlaudToolService.swift` | тулзы модели + чипы + промпт-хинты (паттерн CalendarToolService) |
| `PlaudNoteCache.swift` | дисковый кэш + `PlaudFormat` (длительности, таймкоды, markdown транскрипта) |
| `PlaudNotePreview.swift` | окно превью: вкладки, транскрипт с кликабельными таймкодами, AVPlayer + Now Playing |
| `PlaudChipView.swift` | чип в пузыре + `PlaudBadge` (чёрный глиф на белой плашке — оригинальная ливрея) |
| `PlaudSettings(+View)` | тумблер, Connect/Disconnect, режим «только по /plaud», карточка аккаунта |
| `PlaudLocalization.swift` | строки `PLL()` (en/es/ru) |

### Тулзы модели

- `plaud_find(query?, date_from?, date_to?, limit?)` — серверных фильтров нет:
  при фильтрах пагинация до 5×100 и фильтр на клиенте (как в официальном MCP).
- `plaud_get_note(file_id, tab?)` — все вкладки (или одна), Markdown.
- `plaud_get_transcript(file_id, from_min?, to_min?)` — `[MM:SS] Speaker: …`,
  срез по минутам, кап 60k символов.

Промпт-хинт: сначала note, транскрипт — только если саммари не хватило;
необработанные — отдельной строкой; найденное прикрепляется карточками —
не дублировать сырые ID в текст. Гейт в ChatService: аддон включён + модель
умеет тулзы + (`alwaysAvailable` ИЛИ сообщение начинается с `/plaud`).

### Чипы и превью

- Чип = `ChatAttachment` с метаданными **в пути файла**
  (`PlaudNotes/<fileID>__<kind>__meta.json`; kind: note|unprocessed; старые
  per-tab `.md`-пути первой сборки тоже распознаются) — схема SwiftData не
  менялась. Один чип на запись за ход; `plaud_find` тоже рождает чипы (список
  «всё по X» кликабелен без чтения заметок).
- Доставка: тулза складывает чипы → ChatService шлёт событие
  `.attachments([ChatAttachment])` → ChatWindow буферизует до `deliver`
  (пузыря в момент тулзы ещё нет) с дедупом по пути.
- Превью (`PlaudNotePreview`): открывается из кэша мгновенно + фоновый
  live-рефреш всей записи (все вкладки + транскрипт). Транскрипт — всегда
  первая вкладка слева; по умолчанию выбрана первая заметка-вкладка. Аудио:
  AVPlayer со стримом с presigned URL (свежий на каждый сеанс), Now Playing
  (медиа-клавиши, перемотка), клик по таймкоду сегмента = seek+play; стоп при
  закрытии окна (окно retained — слушаем `willCloseNotification`, onDisappear
  не срабатывает). Окно floating + `.canJoinAllSpaces, .fullScreenAuxiliary`.
- Кэш: `Application Support/Cuate/PlaudNotes/` — meta JSON + `.md` на вкладку +
  транскрипт (`.md` для людей + сырой `.json` сегментов для таймкодов).

### Панель «Файлы чата» (LocalChatFilesView)

Кнопка-папка в хедере обычных чатов (аналог агентского CHAT FILES): документы
модели (HTML/MD-артефакты из fences, через кэш парсера), записи Plaud, вложения
пользователя; действия открыть / показать в Finder.

## Юридика и бренд

Путь — личный доступ пользователя к своим данным через публичный API Plaud
(тот же механизм, что у их MCP для Claude/Cursor); формулировка «works with
Plaud», без имплая партнёрства. Бейдж — фирменный глиф «Λ·» в оригинальной
ливрее (чёрное на белом); глиф вырезан из вордмарка (favicon непрозрачный —
template-рендеринг давал белый квадрат). Упоминание — THIRD-PARTY-NOTICES.md.

## Не вошло / дальше

- **Hermes-агент не видит Plaud**: клиентские тулзы не вставляются в агент-цикл
  на чужом хосте. Варианты: Plaud MCP на хосте агента / перехват `/plaud`
  локальной моделью / проброс tools через `/v1` (не проверен).
- **Семантический поиск** — API отдаёт только substring по именам; локальный
  индекс саммари (NLEmbedding) — отдельная фаза.
- **Майндмэпы** — формат в API не встречался; проверить на реальной заметке.
- Write-операции (запуск обработки, спикеры) — ждут появления write-API у Plaud.
