# Hermes API — живые фикстуры (стенд localhost:8642, Hermes 0.19.0, 2026-07-25)

Снято curl'ом с реального инстанса. Транспорт (`HermesTransport`) пишется по ЭТОМУ файлу,
не по прозе доков. При апгрейде Hermes на стенде — перепроверить и обновить.

## Включение API-сервера (онбординг-инструкция)

В `~/.hermes/.env`:
```
API_SERVER_ENABLED=true
API_SERVER_PORT=8642
API_SERVER_KEY=<секрет>
```
API-сервер живёт в процессе **gateway**: `hermes gateway run` (или `install` как сервис).
Десктоп-приложение Hermes гейтвей НЕ поднимает (его `serve --port 0` — другое).

## Аутентификация

`Authorization: Bearer <API_SERVER_KEY>`. Неверный ключ И отсутствие ключа → **401** (без тела WWW-Authenticate).

## `/v1/capabilities` (гейтинг UI)

```json
{"object": "hermes.api_server.capabilities", "platform": "hermes-agent", "model": "hermes-agent",
 "auth": {"type": "bearer", "required": true},
 "runtime": {"mode": "server_agent", "tool_execution": "server", "split_runtime": false},
 "features": {
   "chat_completions": true, "chat_completions_streaming": true,
   "responses_api": true, "responses_streaming": true,
   "run_submission": true, "run_status": true, "run_events_sse": true, "run_stop": true,
   "run_approval_response": true, "tool_progress_events": true, "approval_events": true,
   "session_resources": true, "model_options": true,
   "session_chat": true, "session_chat_streaming": true, "session_fork": true, "session_model_lock": true,
   "admin_config_rw": false, "jobs_admin": false, "memory_write_api": false,
   "skills_api": true, "audio_api": false, "realtime_voice": false,
   "session_continuity_header": "X-Hermes-Session-Id", "session_key_header": "X-Hermes-Session-Key",
   "cors": false},
 "endpoints": { /* method+path для каждой фичи, см. полный дамп ниже по эндпоинтам */ }}
```

⚠️ На дефолтном сервере **`admin_config_rw=false`, `jobs_admin=false`, `memory_write_api=false`** —
секции «Задачи»/конфиг/память гейтим по этим флагам (выключено → секцию прячем).

## `/v1/models`

Одна псевдо-модель: `{"object":"list","data":[{"id":"hermes-agent","object":"model","owned_by":"hermes",...}]}`.
Профили выглядели бы отдельными id. **Список ролей строим отсюда** (обычно 1 роль).

## Сессии

### POST `/api/sessions` `{"title":"..."}` → 
```json
{"object":"hermes.session","session":{"id":"api_1785015297_041aa50e","source":"api_server",
 "model":"hermes-agent","title":"cuate-fixture","started_at":1785015297.63,
 "message_count":0,"tool_call_count":0,"input_tokens":0,"output_tokens":0,
 "cache_read_tokens":0,"cache_write_tokens":0,"reasoning_tokens":0,
 "estimated_cost_usd":null,"parent_session_id":null,...}}
```

### ⚠️ Model lock ОБЯЗАТЕЛЕН после создания
Свежая сессия наследует литерал `model:"hermes-agent"` и КАЖДЫЙ ход падает:
`HTTP 404: Model 'hermes-agent' not found` (даже при явных `model`+`provider` в запросе хода —
`route_source` показывает попытку, но runtime остаётся на литерале).

Лечится: `POST /api/sessions/{id}/model {"model":"tencent/hy3:free","provider":"nous"}` →
`{"object":"hermes.session.model_lock","runtime":{...,"model_lock":"accepted"}}`.
После лока ходы идут с `route_source:"session_model_lock"`.
Пары model/provider берём из `/api/model/options` (см. ниже).

### GET `/api/sessions?limit=&offset=` — список
Элемент богатый: `id, source, model, title, started_at, ended_at, end_reason, message_count,
tool_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
reasoning_tokens, estimated_cost_usd, api_call_count, parent_session_id, last_active, preview,
has_system_prompt` — хватает на секцию «Сессии» без дополнительных запросов.

### GET `/api/sessions/{id}/messages`
```json
{"object":"list","session_id":"...","data":[
 {"id":3,"session_id":"...","role":"user","content":"...","tool_call_id":null,"tool_calls":null,
  "tool_name":null,"timestamp":1785015309.72,"token_count":null,"finish_reason":null,
  "reasoning":null,"reasoning_content":null},
 {"id":6,"role":"assistant","content":"pong","finish_reason":"stop","reasoning":"..."}]}
```
- **`id` — целочисленный, монотонный внутри сессии → наш `seq`.**
- `externalID` у нас = `"<session_id>#<id>"`.
- user-сообщения НЕУДАВШИХСЯ ходов тоже записаны (роутинг упал — а user-строка осталась);
  ассистентские ошибки в историю не пишутся.
- роли: user / assistant / tool (`content` у tool — JSON `{"output","exit_code","error"}`).

## Чат-стрим: POST `/api/sessions/{id}/chat/stream` `{"input":"..."}`

SSE-кадры `event: <name>\ndata: <json>`; в каждом `data`: `session_id`, `run_id`, `seq` (нумерация
кадров ЭТОГО рана, не сообщений), `ts`. Порядок реального хода с инструментом:

```
run.started        {"user_message":{"role":"user","content":"..."},"runtime":{...}}
message.started    {"message":{"id":"msg_<hex>","role":"assistant"}}
tool.started       {"message_id":"msg_...","tool_name":"terminal","preview":"echo cuate-test-123",
                    "args":{"command":"echo cuate-test-123"}}
tool.completed     {"message_id":"...","tool_name":"terminal","preview":null,"args":null}
assistant.delta    {"message_id":"...","delta":"\n\ncu"}     ← только при стриминге модели
tool.progress      {"message_id":"...","tool_name":"_thinking","delta":"..."}  ← служебный, "_thinking" не показывать как инструмент
assistant.completed{"message_id":"...","content":"<ПОЛНЫЙ текст>","completed":true,"partial":false,
                    "interrupted":false,"runtime":{...}}
run.completed      {"completed":true,"messages":[<весь транскрипт хода: assistant+tool_calls,
                    tool-результаты, финальный assistant>],
                    "usage":{"input_tokens":35019,"output_tokens":31,"total_tokens":35050,...}}
done               {}
```

⚠️ **Ловушка клиента (живой баг 2026-07-25):** `URLSession.AsyncBytes.lines`
ПРОПУСКАЕТ пустые строки — SSE-парсер, ждущий пустую строку-разделитель, не
собирает ни одного кадра (каждый ход завершался с нулём событий, «(empty
reply)», а ответ находился потом зеркалом). Кадр диспатчится по строке
`data:` (payload у Hermes однострочный JSON).

⚠️ **Interim-сообщения:** один ран может отдать НЕСКОЛЬКО assistant-сообщений
(«Сначала проверю…» → тулзы → ответ; `display.interim_assistant_messages`).
Каждое приходит своей парой `message.started` → `assistant.completed`.
Клеим в один пузырь через пустую строку — замена последним теряла текст.

Выводы для транспорта:
- Текст может прийти ТОЛЬКО в `assistant.completed` (без единой дельты — напр. короткий ответ
  или `streaming.enabled:false` в конфиге агента). Рендерим дельты, а на completed сверяем/заменяем
  полный текст.
- Ошибка хода приходит НЕ ошибкой HTTP, а `assistant.completed` с текстом ошибки
  (`"HTTP 404: Model ... not found"`). HTTP-статус стрима — 200. Детектировать нечем, показываем как ответ.
- `usage` — в `run.completed` (реальные токены, вкл. cache_read; сессия суммирует).
- `tool.started.args` — есть тело команды → карточке аппрува/журналу шагов хватает.
- `_thinking` в `tool.progress` — поток рассуждений, не инструмент.

## Аппрувы (снято живьём 2026-07-25 — МИД-РАН АППРУВОВ В 0.19.0 НЕТ)

Проверено на стенде:
- `terminal` на local-бэкенде НЕ гейтится: `echo`, `sudo -n whoami` — выполняются сразу.
- `skills.write_approval: true` → `skill_manage create` возвращает staged-результат КАК
  ОБЫЧНЫЙ tool-result: `{"success":true,"staged":true,"pending_id":"c2c24583",
  "message":"Staged for approval… review with /skills pending"}`. Ран НЕ приостанавливается,
  SSE-событий `approval.*` не приходит; ревью — асинхронно через CLI `/skills pending`.
  REST-доступа к pending-очереди в 0.19.0 нет (нет в capabilities.endpoints).
- ⚠️ Наблюдение: модель ОБОШЛА staged-гейт, записав SKILL.md напрямую через `write_file`
  (аргумент в пользу показа бэкенда/изоляции в нашем UI и `skills.guard_agent_created`).

`features.approval_events:true` и `run_approval_response:true` при этом объявлены —
эндпоинт `POST /v1/runs/{run_id}/approval` существует. Вывод: событийные аппрувы относятся
к другому пути (или будущей версии). Наш UI аппрувов подключён к `approval.*`-кадрам
session-стрима и дремлет, пока гейтвей их не шлёт; тело resolve-запроса
(`{"approval_id","approved"}`) — лучшая догадка, перепроверить при первом живом кадре.

## `/v1/skills` → `{"data":[{"name":"apple-notes","description":"...","category":"apple"},...]}`

## `/v1/toolsets` → богатый:
```json
{"object":"list","platform":"api_server","data":[
 {"name":"web","label":"🔍 Web Search & Scraping","description":"web_search, web_extract",
  "enabled":true,"configured":true,"tools":["web_extract","web_search"]},
 {"name":"browser","label":"🌐 Browser Automation",...},
 {"name":"terminal","label":"💻 Terminal & Processes",...}]}
```
label уже с эмодзи — секция «Скиллы/Тулсеты» рисуется из этого as is.

## `/api/model/options` → провайдеры и модели для секции «Агент»
```json
{"providers":[{"slug":"nous","name":"Nous Portal","is_current":true,"is_user_defined":false,
  "models":["anthropic/claude-fable-5","anthropic/claude-opus-5",...]},...]}
```
Пары (provider, model) отсюда идут в model lock сессии.

## Вложения-картинки в session chat (снято 2026-07-25)

`input` принимает НЕ только строку, но и массив OpenAI-частей:
```json
{"input":[{"type":"text","text":"..."},
          {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}
```
Работает (модель видит картинку). Плоское поле `images:[...]` запрос НЕ ломает,
но картинка до модели НЕ доходит — не использовать.

## Топ-левел `/api/model/options` (снято 2026-07-25)

Кроме `providers[]` в корне есть **`model` и `provider`** — ТЕКУЩАЯ пара агента.
Именно её берём для model lock, когда пользователь выбрал «как настроено у агента».

## Аудио (STT/TTS) — проверено по исходникам 0.19.0

`"audio_api": False` **захардкожен** в `gateway/platforms/api_server.py:2829` —
аудио-эндпоинтов у API-сервера нет и конфигом не включаются. TTS/STT Hermes
(`tools/tts_tool.py`, `tools/transcription_tools.py`) — инструменты АГЕНТА на
его хосте: «озвучь и дай путь» работает уже сейчас (файл откроет наш чип).
Голосовые в композере транскрибирует НАШ STT-пайплайн (осознанно: аудио через
API не передать). При появлении audio_api в новых версиях — capability-гейт
подхватит, тогда возможен тумблер «STT/TTS на стороне агента».

## Открытое/на потом
- [ ] Живая фикстура approval-события (этап 6).
- [ ] Пагинация `/api/sessions/{id}/messages` (limit/offset? проверить при курсорном догрузе, этап 5).
- [ ] `/v1/runs` + `/v1/runs/{id}/events` как альтернативный канал (стоп/аппрув привязаны к run_id;
      run_id уже приходит в каждом кадре session-стрима — stop должен работать и так).
- [ ] Что включает `jobs_admin`/`admin_config_rw` на сервере (env-флаги?) — для секции «Задачи».
