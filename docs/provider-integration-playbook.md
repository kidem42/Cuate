# Плейбук: интеграция нового LLM-провайдера

**Версия кода:** 3.5+ (после внедрения учёта затрат)
**Назначение:** пошаговый чек-лист для добавления нового чат-провайдера в Cuate — от enum'а до вкладки «Расходы». Порядок шагов = порядок зависимостей; после каждого блока указано, чем проверять.

Все пути — относительно `Cuate/Cuate/`.

---

## 0. Выбор пути реализации

| Ситуация | Путь | Референс |
|---|---|---|
| API совместимо с OpenAI chat/completions (большинство: DeepSeek, Kimi, Mistral…) | Новый статический инстанс `OpenAICompatibleProvider` с своим base URL | `Providers/OpenAICompatibleProvider.swift:11-30` |
| Своё уникальное API | Отдельный файл-провайдер | `Providers/GeminiProvider.swift` (простой), `Providers/AnthropicProvider.swift` (с кэш-брейкпоинтами) |
| Агрегатор с каталогом моделей и ручным вводом слага | Как OpenRouter: `usesManualModelEntry`, каталог `ModelInfo` | `fetchModelCatalog`, `OpenAICompatibleProvider.swift:447` |

## 1. Идентификатор провайдера — `Providers/ProviderCore.swift`

Добавить case в `enum ProviderID` и заполнить **все** switch'и (компилятор подсветит):

- `displayName` — имя в UI;
- `usesManualModelEntry` — true только для агрегаторов без выпадающего списка;
- `supportsVision` — грубый пер-провайдерный дефолт (пер-модельные исключения — шаг 6);
- `badgeLetter` + `brandColorHex` — бейдж и фирменный цвет (цвет также красит провайдера на графиках «Расходов»);
- `apiKeyURL` — страница создания ключа (открывается из настроек);
- `modelCatalogURL` — только для агрегаторов;
- `preferredDefaultModels` — предпочтительные модели, лучшая первой. Матчинг: точное совпадение id или префикс датированного снапшота («claude-sonnet-5» → «claude-sonnet-5-20250929»). Предпочитать rolling-алиасы `-latest`.

## 2. Реализация `LLMProvider`

Протокол (`ProviderCore.swift`): `streamChat` / `fetchModels` / `validateKey` (дефолт — «валиден, если умеет листить модели»; для провайдеров с публичным `/models` переопределить, как OpenRouter → `/api/v1/key`).

`streamChat` обязан:
1. Стримить через общий `HTTPClient.sseStream` (фильтрует `data:`-кадры, режет `[DONE]`).
2. Yield'ить `.text(chunk)` по мере прихода текста.
3. Собирать фрагментированные tool-вызовы и отдавать `.toolCalls([...])` одним событием в конце (web search работает через function calling у всех).
4. **Отдавать `.usage(TokenUsage)`** перед `finish()` — см. шаг 3.
5. Мапить ошибки через `ProviderError.fromHTTP` (сырые тела ответов не должны доходить до UI).

Не забыть: `maxTokens`-кап, если у провайдера есть модельные лимиты (`AnthropicProvider.maxTokensCap`, клампы DeepSeek/Gemini в `ChatService.streamReply`).

## 3. Захват usage (учёт затрат) — ОБЯЗАТЕЛЬНО

Каждый провайдер обязан отдать `.usage(TokenUsage)` — иначе расходы пользователя по нему будут считаться грубой оценкой. Нормализация полей:

| Поле `TokenUsage` | Семантика |
|---|---|
| `inputTokens` | **НЕкэшированный** вход (если API даёт только total — вычесть cached) |
| `outputTokens` | Весь выход, включая reasoning |
| `cacheReadTokens` | Прочитано из кэша (тарифицируется дешевле: Anthropic ×0.1, DeepSeek ≈1/50) |
| `cacheWriteTokens` | Запись в кэш (Anthropic ×1.25; у остальных обычно 0) |
| `reasoningTokens` | Справочно; уже входят в `outputTokens` |

Чек-лист ловушек (каждая уже случилась на существующих провайдерах):

- [ ] **Usage-кадр приходит с пустым `choices`/без контента** — парсить `usage` ДО guard'ов на контент (OpenAI-совместимые: финальный чанк с `include_usage`; Gemini: usage-only последний чанк — читается до guard'а `candidates`).
- [ ] **Кумулятивность** — если провайдер шлёт usage несколько раз (Anthropic `message_delta`, Gemini каждый чанк), хранить последнее значение, не суммировать.
- [ ] **Флаг в запросе** — OpenAI-совместимым нужен `stream_options: {"include_usage": true}`. Слать только проверенным: непроверенный параметр может дать 4xx. Проверить живым запросом; если провайдер шлёт usage сам (Mistral, Kimi) — флаг не нужен.
- [ ] **Разбивка кэша** — искать поля вида `cache_read_input_tokens`, `prompt_cache_hit_tokens`/`miss`, `cached_tokens` в `prompt_tokens_details`, `cachedContentTokenCount`.
- [ ] `yield(.usage(...))` строго до `continuation.finish()`, и только если `!usage.isEmpty`.

Агрегацию по итерациям агент-цикла и запись в леджер делает `ChatService` — в провайдере ничего больше не нужно. При обрыве стрима usage не придёт — `ChatService.recordSpend` сам запишет оценку с флагом `isEstimate`.

## 4. Прайсинг — `Providers/PricingCatalog.swift`

1. Добавить модели провайдера в `snapshotJSON` (USD **за один токен**, поля LiteLLM: `input_cost_per_token`, `output_cost_per_token`, `cache_read_input_token_cost`, `cache_creation_input_token_cost`).
2. Ключ таблицы матчится по «точное совпадение → самый длинный префикс», поэтому семейство можно покрыть одним ключом («claude-sonnet-4» покрывает 4.5/4.6), но следить за коллизиями («gpt-5» и «gpt-5.5» — длинный префикс побеждает).
3. В `mapLiteLLMKey` добавить маппинг префикса LiteLLM-каталога на наш `ProviderID` — тогда еженедельное авто-обновление цен подхватит провайдера.
4. Если провайдер отдаёт цены в собственном каталоге моделей (как OpenRouter `pricing`) — пробросить их в `ModelInfo.promptPricePerToken`/`completionPricePerToken` и научить `ChatService.recordSpend` их предпочитать.

Нет цены → не страшно: леджер запишет токены с `costUSD = nil`, UI покажет «нет цены». Но снапшот лучше заполнить.

## 5. Регистрация — `Providers/AppSettings.swift`

`ProviderRegistry.provider(for:)` — вернуть инстанс для нового case (единственное место, компилятор напомнит).

## 6. Capabilities

- `ModelCapabilities.supportsReasoningControl` (`ProviderCore.swift`) — эвристика по слагу, если у провайдера есть reasoning-модели;
- пер-модельные особенности vision/tools — `AppSettings.modelSupportsVision/Tools/ReasoningControl` (для агрегаторов — из каталога `ModelInfo`);
- клампы параметров (например, `max_tokens ≤ 8192`) — в `ChatService.streamReply` (`providerTokenCap`).

## 7. UI и локализация

- Ключ API: слот появляется автоматически из `ProviderID.allCases` в Keys-секции; проверить, что `validateKey` даёт вменяемую ошибку на мусорный ключ.
- Строки: новые ключи в `App/Localization.swift` — **все три языка** (en/es/ru), английский — фолбэк.
- Тултипы `.help` на новые контролы — правило проекта (см. `docs/TECH-DEBT.md`, фикс 3.5).
- Бейдж: буква+цвет уже заданы в шаге 1; отдельных ассетов не нужно (`Views/ProviderBadge.swift`).

## 8. e2e-чеклист перед коммитом

Сборка — только `./scripts/make-dmg.sh` для дистрибутива; для проверки компиляции достаточно raw `xcodebuild build`.

- [ ] `fetchModels` наполняет дропдаун; `preferredDefaultModels` выбирает вменяемый дефолт;
- [ ] обычный стрим: текст идёт чанками, финиш чистый;
- [ ] tool-цикл: web search вызывается и результат скармливается обратно (если модель умеет tools);
- [ ] vision: картинка уходит (или корректный OCR-фолбэк для не-vision);
- [ ] **usage**: в логах `Diagnostics` есть `spend.append … est=false` с ненулевыми токенами; повторный запрос в том же чате показывает `cacheRead > 0` (если у провайдера есть кэш);
- [ ] **цена**: запись в леджере с `costUSD != nil`, число сходится с ручным расчётом (токены × прайс);
- [ ] отмена генерации: запись с `est=true`, приложение не падает;
- [ ] невалидный ключ: человекочитаемая ошибка в чате;
- [ ] вкладка «Расходы»: провайдер появился на графиках со своим фирменным цветом.

---

## Приложение: карта файлов учёта затрат

| Что | Где |
|---|---|
| `TokenUsage`, `LLMStreamEvent.usage` | `Providers/ProviderCore.swift` |
| Захват usage по провайдерам | `AnthropicProvider.swift` (message_start/delta), `OpenAICompatibleProvider.swift` (chat/completions + /responses), `GeminiProvider.swift` (usageMetadata) |
| Цены | `Providers/PricingCatalog.swift` (снапшот + LiteLLM-обновление + OpenRouter live) |
| Леджер и агрегаты | `Models/SpendLedger.swift` (`SDSpendRecord`, `SpendLedger`, `SpendStore`) |
| Запись chat/summary + оценка при обрыве | `Providers/ChatService.swift` (`recordSpend`) |
| Запись OCR / STT / поиск / картинки | `MistralOCRService.swift`, `TranscriptionService.swift`, `BraveSearchService.swift` (поиск: $0.005/запрос по тарифу Base AI, `isEstimate` — фри-тир реально бесплатен), `Addons/ImageAddon/Core/ImageTaskRunner.swift` |
| UI | `Views/CostsSettingsView.swift`, вкладка `costs` в `Views/SettingsView.swift` |
