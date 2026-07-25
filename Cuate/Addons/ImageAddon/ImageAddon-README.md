# ImageAddon — addon

Image operations on chat attachments through cloud AI APIs (fal.ai).
P1 (реализовано): апскейл · удаление фона · удаление объектов (маска/текст).
P2 (не реализовано): генерация/редактирование по промпту (fal / OpenAI / Gemini).

Основание: `docs/ImageAddon-TZ.md` (+ `docs/ImageAddon-Model-Research.md`).

## Design

Everything lives in this folder (pattern: `Addons/LayoutFix`). The addon
reuses host building blocks (`APIKeyStore`, `HTTPClient`, `ChatStore` /
`ChatAttachment`, `ProviderGlyph`, `Diagnostics`) but stores no state in
`AppSettings` and adds nothing to the global `L()` table.

| File | Responsibility |
|------|----------------|
| `ImageAddon.swift` | Singleton, `start()` (boot hook). |
| `ImageAddonSettings.swift` | `UserDefaults` (`imageAddon.*`): enable, модели per-function, формат вывода, автокопирование, лимит входа, папка сохранения (nil = Downloads), счётчики расходов. |
| `ImageAddonSettingsView.swift` | Settings tab: ключ fal.ai (glyph + проверка + ошибки, паттерн вкладки Keys), rich-пикеры моделей (бейдж класса + подпись + цена, ТЗ §3.1a), опции, папка, расходы + `ImageAddonEnableToggle`. |
| `ImageAddonLocalization.swift` | Self-contained `IAL()` strings (EN/ES/RU). |
| `Core/ImageOperationProvider.swift` | Протокол + `ImageFunction`/`ImageRequest`/`ImageResult`/`ImageModelInfo` (факторы, face-enhance, потолки МП) + реестр. |
| `Core/ImageOperations.swift` | Пайплайн операций (общий для кнопок/слэшей/повторов): нормализация входа, статус, результат в чат, реестр результатов, автокопирование, восстановление аттача при ошибке. + `ChatWindowBridge`, `ImageResultStore` (>8 MB → файл), `ImageOperationCancelButton`, `ImageSlashCommands`. |
| `Core/ImageTaskRunner.swift` | Single-flight executor: cancel(), 1 автоповтор на таймаут/5xx, Diagnostics-лог, учёт расходов. |
| `Core/ImageAddonError.swift` | Ошибки с локализованными описаниями, санитайзер HTTP-тел. |
| `Core/ImageInputPreparer.swift` | PNG-конверсия (ImageIO), data-URI, GIF→первый кадр, автодаунскейл 25 МП/20 МБ, конверсия формата вывода. |
| `Providers/FalProvider.swift` | REST-клиент Queue API fal.ai (submit → poll → fetch, cancel_url) + статический каталог всех моделей P1 + no-cost `validateKey`. |
| `Views/AttachmentActionsBar.swift` | [Апскейл ▾(факторы/лица)] [Убрать фон] [Удалить объекты] под превью аттача + именование результатов. |
| `Views/MaskEditorView.swift` | Инлайн-редактор: кисть 10–100 px (деф. 40), undo, сброс, режим «текстом», Применить. |
| `Views/ImageResultActionsBar.swift` | Сохранить (в папку без диалогов) / Finder / Копировать / Повторить с другой моделью ▾ / Продолжить редактирование. |

## Модели (каталог статический, обновляется релизами)

| Функция | Модели (fal id) | Дефолт |
| ------- | --------------- | ------ |
| Апскейл | Recraft Crisp (`fal-ai/recraft/upscale/crisp`) · Topaz (`fal-ai/topaz/upscale/image`) · SeedVR2 (`fal-ai/seedvr/upscale/image`) · Real-ESRGAN (`fal-ai/esrgan`) | Recraft Crisp |
| Фон | Bria RMBG-2.0 (`fal-ai/bria/background/remove`) · BiRefNet v2 (`fal-ai/birefnet/v2`) | Bria RMBG-2.0 |
| Объекты | Bria Eraser (`fal-ai/bria/eraser`, маска) · Object Removal (`fal-ai/object-removal`, текст) | Bria Eraser |

## Host mount points (outside this folder)

1. **Boot** — `App/CuateApp.swift`: `ImageAddon.shared.start()`.
2. **Settings** — `Views/SettingsView.swift`: `case imageAddon`, условная вкладка, `ImageAddonEnableToggle()` в General.
3. **Panel** — `Views/ChatWindow.swift`: `ImageAttachmentActionsBar` под превью; `ImageSlashCommands.handle` в начале `sendMessage`; `ImageOperationCancelButton()` в thinking-пилюле; `ChatWindowBridge.chatStore = chatStore` в onAppear; onReceive `.imageAddonAttachRequest`.
4. **Chat** — `Views/MessageRow.swift`: `ImageResultActionsBar(attachment:)` под картинками ассистента.
5. **Key slot** — `Providers/APIKeyStore.swift`: `AuxKey.fal`.

Хост-доработки, полезные и без аддона: кнопка-скрепка + системные диалоги
как sheet панели, ⌘V картинки из буфера (`ChatWindow`/`CustomTextEditor`),
защита `hideChatWindow` от attached sheet, нотификация `.openSettingsWindow`,
file-backed `ChatAttachment` (`fileURLString` + `contentBase64`).

Removing the addon = delete this folder + revert the hooks above.

## How it works

1. Картинка попадает в панель: скрепка (NSOpenPanel-sheet), ⌘V, скриншоты.
   Drag&drop сознательно НЕ поддерживается — конфликтует с авто-скрытием
   панели по потере фокуса.
2. Под превью — ряд действий (аддон включён). Без ключа fal.ai клик
   показывает popover со ссылкой в настройки (ТЗ §6).
3. Вход нормализуется: GIF → первый кадр (плашка), > лимита → даунскейл
   (плашка), PNG-конверсия где требует модель.
4. `FalProvider`: base64 data-URI → `queue.fal.run/<model>`; поллинг
   `status_url` (1 с, дедлайн 120 с); отмена — крестик в пилюле → PUT
   `cancel_url`; 1 автоповтор на таймаут/5xx; 422 с policy-текстом →
   «модель отклонила изображение».
5. Результат: конверсия в формат из настроек (фон — всегда PNG), > 8 МБ —
   в `Application Support/Cuate/images/` (файловая ссылка в
   `ChatAttachment`), сообщение ассистента `<имя>-upscaled/-nobg/-cleaned`.
   Под ним: Сохранить (Downloads/кастомная папка, без диалогов), Finder,
   Копировать, Повторить с другой моделью, для cleanup — Продолжить
   редактирование. Ошибка — системное сообщение + исходник возвращается в
   композер для повтора в один клик.
6. Слэш-команды: `/upscale [2|4|8]`, `/bg`, `/cleanup <что удалить>`.

## Requirements & limitations

- Ключ fal.ai (Keychain, `AuxKey.fal`); проверка ключа — бесплатный
  auth-probe (status несуществующей задачи).
- Изображения передаются data-URI (без storage-upload) — на очень больших
  файлах это медленнее.
- «Повторить с другой моделью» / «Продолжить редактирование» живут в рамках
  сессии (реестр результатов не персистится).
