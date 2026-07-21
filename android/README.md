# AISpotlight for Android

Android-порт AISpotlight: тот же мульти-провайдерный AI-чат, но в форме обычного
мобильного приложения (на macOS это Spotlight-панель с быстрым доступом; на
телефоне — ассистент-чат с теми же функциями).

## Статус: 1.7.0 — полный порт (кроме системной диктовки)

Готовый к установке APK: `dist/AISpotlight-1.7.0.apk` (release, minified,
подписан ключом из `release.keystore`; keystore и `keystore.properties`
в git не попадают — храните их локально, они нужны для обновлений с той же
подписью). Сборка релиза — только через `scripts/make-apk.sh` (бамп версии,
подпись, выкладка в `dist/`).

Добавлено в 1.6.x–1.7.0:

- **Учёт расходов** — порт macOS-версии целиком: перехват usage у всех
  провайдеров, прайсинг-каталог, спенд-леджер (Room-миграция 2→3, история
  чатов сохраняется), экран Costs с Canvas-графиками по дням и мягкий
  месячный бюджет; адаптивно для планшетов/раскладных.
- **Голосовые сообщения, UX** — перемотка тапом/драгом по волне (живая
  заливка, таймкод позиции); один общий транспорт на чат: старт нового
  сообщения останавливает и перематывает предыдущее, автопереход к следующему
  голосовому; транскрипт складывается под плеер (тумблер Show/Hide text) и
  доступен во время синтеза и после сбоя TTS; ответы на голосовые вопросы
  помечаются VOICE с первого токена — пульсирующий силуэт плеера вместо
  стримящегося текста.

Добавлено в 1.1.0 к базовому чату:

- **Темы** — 8 тем: Material You (dynamic) + Blueprint, Terminal, Synthwave,
  Sakura, Pastel, Halloween, Día de Muertos (light/dark палитры, фоновые
  градиенты, сетка/сканлайны, градиентные баблы и send-кнопка, моноширинный
  Terminal); режим внешнего вида System/Light/Dark; **праздничное
  автопереключение** (31 окт → Halloween, 1–2 ноя → Día de Muertos, с
  запоминанием и возвратом темы — порт HolidayThemeManager).
- **Image tools (fal.ai)** — долгое нажатие на изображение в чате: апскейл
  (Recraft Crisp), удаление фона (Bria RMBG-2.0), удаление объекта по
  текстовому описанию (Object Removal); Queue API submit→poll→fetch; результат
  падает в чат отдельной карточкой; «Сохранить в галерею» для любого
  изображения.
- **Голосовые сообщения** — как на маке: запись → транскрипция → сообщение в
  чате с плеером (аудио хранится) и транскриптом, уходящим модели.
- **Переключатель пресетов** в топ-баре чата (эмодзи активного пресета).
- **Quick Settings tile** — плитка в шторке открывает ассистента (аналог
  глобального хоткея).
- **Max tokens** в настройках.

Портировано с macOS-версии (`../AISpotlight`, Swift → Kotlin):

- **Слой провайдеров** — Anthropic (Messages API + explicit prompt caching),
  OpenAI (Responses API), Mistral / DeepSeek / OpenRouter / Kimi
  (chat/completions), Gemini (streamGenerateContent). SSE-стриминг через OkHttp,
  function calling, reasoning-режимы (auto/fast/deep) — порт 1:1 из
  `Providers/*.swift`.
- **ChatService** — агентный цикл web_search (Brave, до 4 итераций),
  компрессия контекста (rolling summary: порог 24k токенов, script-aware
  оценка, последние 12 сообщений verbatim, merge-style промпт), tool-context
  grounding на последнем ответе.
- **Хранение** — Room (беседы + сообщения, оконная загрузка по 120),
  API-ключи в Android Keystore (AES/GCM), настройки в SharedPreferences.
- **UI** — Jetpack Compose + Material 3 (dynamic color), Markdown-рендер
  (код, таблицы, списки, цитаты, ссылки), стриминг с индикатором,
  список бесед, экран настроек, пресеты системных промптов.
- **Вложения** — галерея через системный Photo Picker (без разрешений) и
  камера (`TakePicture` + FileProvider); изображения даунскейлятся до 2048px,
  хранятся файлами; vision-модели получают пиксели (последнее сообщение),
  не-vision (DeepSeek) — OCR-текст через Mistral OCR; старые вложения — кэш
  OCR на аттачменте (ленивая экстракция, бюджет 3/ход) — 1:1 политика macOS.
- **Голосовой ввод** — кнопка микрофона: запись (AAC/m4a) → STT (Mistral
  Voxtral / OpenAI / Deepgram, с фолбэком на любой настроенный) → голосовое
  сообщение в чате.
- **Артефакты** — полные ```html-страницы и ````markdown-документы из ответа
  показываются карточкой; открытие — живой WebView (JS включён) или рендер
  Markdown, вкладка Code, share и сохранение в Downloads.
- **Раскладные / планшеты** — при ширине окна ≥ 600dp список бесед
  закрепляется слева от чата (two-pane); на сложенном экране — одна панель.
- **Системная интеграция** — Share-target (текст из других приложений) и
  `ACTION_PROCESS_TEXT` (пункт в меню выделения текста) → текст попадает
  в поле ввода как цитата (аналог selection capture на macOS).
- **Локализация** — en / ru / es (по языку системы).

## Дальше (запланировано)

Единственное отложенное — **голосовая IME-клавиатура**: системная диктовка в
любое приложение + перевод на лету (порт DictationService; на Android это
InputMethodService c `commitText()` вместо синтеза ⌘V).

## Сборка

Требуется Android SDK (compileSdk 36) и JDK 17+ (подойдёт JBR из Android Studio):

```bash
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleDebug
```

APK: `app/build/outputs/apk/debug/app-debug.apk`. Либо открыть папку `android/`
в Android Studio.

Релизный APK собирается **только** через `scripts/make-apk.sh` — скрипт бампит
версию, подписывает ключом из `release.keystore` и кладёт результат в `dist/`.

## Структура

```text
app/src/main/kotlin/com/aispotlight/android/
  core/        ProviderCore: типы, LLMProvider, HttpClient (SSE)   ← ProviderCore.swift
  providers/   Anthropic, OpenAICompatible, Gemini, Brave, Registry ← Providers/*.swift
  chat/        ChatService (агентный цикл, компрессия), ChatViewModel ← ChatService.swift
  data/        Room (Db, ChatModels)                                ← ChatModels/ChatPersistence.swift
  settings/    AppSettings, ApiKeyStore (Keystore), Presets         ← AppSettings/APIKeyStore.swift
  ui/          MainActivity (adaptive), ChatScreen, Markdown, Settings ← Views/*.swift
```

Лицензия: AGPL-3.0 (см. `../LICENSE`).
