# Чек-лист внедрения темы

Полная поверхность адаптации при добавлении темы. Источник истины — код;
этот файл фиксирует, ГДЕ искать, чтобы ничего не забыть. Проверено на цикле
Yule/Aurora (4.8). При добавлении нового токена или `themeID`-ветки — обнови
и этот файл.

## 1. Шаги внедрения (по порядку)

| # | Шаг | Где |
|---|-----|-----|
| 1 | `case` в enum + `displayName` | `Cuate/Views/AppTheme.swift` (AppTheme) |
| 2 | Два пресета `<тема>Dark` / `<тема>Light` (~40 токенов) | AppTheme.swift (ThemePalette) |
| 3 | `case` в `resolve()` + panelTint в `tinted(...)` | AppTheme.swift |
| 4 | Токены мирового времени, dark+light (~25) | `Cuate/Addons/WorldTimeAddon/WorldTimeTheme.swift` (switch без default — компилятор напомнит) |
| 5 | Декорации: файл `<Тема>Theme.swift` + `case` в `ThemeDecorations` — оба варианта: `.chat` и `.worldTime` (спокойный, у краёв) | AppTheme.swift ~L1000 ⚠️ там `default: Color.clear` — забытую тему компилятор НЕ поймает |
| 6 | Сигнатурные ветки по `themeID` (см. §4) — решить для каждой: дефолт или фирменное | по списку §4 |
| 7 | Праздничная автоактивация (если тема сезонная) | `Cuate/App/HolidayThemeManager.swift` (Holiday enum, occurrence, userPicked) + caption `appearance.holidayThemes.caption` в `Localization.swift` |
| 8 | Пикер тем — автоматически (CaseIterable), только проверить миниатюру | `Cuate/Views/ThemeGridPicker.swift` |

## 2. Токены ThemePalette (AppTheme.swift)

- **Панель**: `backgroundStyle` `panelTint` `pattern` `panelBorder` `panelGlow` `glassSurface` `cornerMarkColor`
- **Пузыри**: `userFill/Text/Stroke/Corners` `userGlow` `assistantFill/Text/Stroke/Corners` `assistantGlyph` `glyphColor`
- **Текст**: `accent` `accentInk` (→`ink`) `primaryText` `secondaryText` `timestampColor` `timestamp` (формат!) `timestampMono` `fontDesign`
- **Композер**: `inputFill/Stroke/Radius` `placeholderColor` `placeholderCaret` `divider` `composerButtonRadius` `micColor/Stroke/Fill/GlyphColor/Dashed` `sendFill/GlyphColor/Glow/Rim`
- **Контент**: `codeFill/Text` `inlineCodeFill/Text` `bulletGlyph` `bulletColor` `quoteColor` `dictationColors` `recordingAccent` `voiceProgress`

## 3. Токены WorldTimeTheme

`midnight night shoulder work cellDarkText midnightStroke` · `text secondary` ·
`sep bandStroke bandRadius` · `selStroke/Fill/Dash/Glow hoverStroke` ·
`now nowDash` · `weekend capsule chip daySel rail link`

## 4. Сигнатурные ветки по `themeID` (компилятор НЕ проверяет — пройти руками)

| Точка | Файл | Прецеденты |
|---|---|---|
| Send-кнопка | `ChatWindow.swift` ~L956 | Día=бархатцы, Halloween=тыква, `sendRim` (Yule/…), остальные — круг `sendFill`+paperplane |
| «Думаю…»-спиннер | `ThinkingIndicator.swift` | Yule=CandyCaneSpinner, остальные — эквалайзер `dictationColors` |
| Глиф ассистента | `MessageRow.swift` ~L303 | Día=SugarSkull, Halloween=PumpkinIcon, остальные — `assistantGlyph` текстом |
| Декорации + WT-вариант | `AppTheme.swift` ThemeDecorations | Halloween/Día/Sakura/Pastel=только чат; Yule/Aurora=оба контекста |
| Пиллы действий картинок | `AttachmentActionsBar.swift` `pillColors` | Día=три цвета по ролям, Halloween=сплошная обводка, остальные — generic accent |
| Мик-кнопка | `EnhancedVoiceButton.swift` ~L150 | форма от `composerButtonRadius`, dashed от `micDashed` |
| ANSI в код-блоках | `MarkdownBlocksView.swift` ~L337 | семейство `placeholderCaret` красит green в accent |
| Фоновый паттерн | `AppTheme.swift` ThemePatternOverlay | Blueprint=сетка (+PatternFadeMask в WT), Terminal=сканлайны |
| Таймстамп-формат | `MessageRow.swift` `formatTime` | новый формат = новый case `ThemeTimestamp` |

## 5. Потребители палитры (что проверять глазами)

| Файл | Элементы |
|---|---|
| ChatWindow | поверхность панели, шапка, статус-пилюля (+обводка `inputStroke`), pinned-bar, кнопка «вниз», retry, карточка вложения, композер целиком |
| MessageRow | пузыри, таймстампы, глиф, инлайн-код, ссылки |
| MarkdownBlocksView | заголовки, списки (буллет-глиф!), код-блок+ANSI+copy, инлайн-код, цитата (и в юзер-пузыре — `isInUserBubble`), таблицы, разделители |
| VoiceMessagePlayer / EnhancedVoiceButton / RecordingStatusView / DictationService | войс, мик, пилюля записи, капсулы диктовки (148/182×34, 14 полос) |
| ThinkingIndicator | спиннер везде (статус, бэкфилл, плейсхолдеры картинок) |
| ArtifactView / MermaidBlockView / AgentInlineImageView | карточка артефакта, mermaid, инлайн-картинки |
| AttachmentActionsBar / ImageResultActionsBar | пиллы под вложением и под результатом |
| AgentGatewayViews / AgentFileChips / AgentSidebar / AgentTerminalText / HermesSidebarView | approval-карточка, журнал шагов, чип роли, файловые пиллы, сайдбар (подсветка активной сессии = `ink` 0.12), терминальный текст |
| WorldTimeView (+Theme) | вся сетка, топбар с дата-стрипом, занятость, выделение/«сейчас», декорации `.worldTime` |
| ThemeGridPicker | миниатюра темы |

## 6. Прогон перед сдачей

Обе схемы (светлая/тёмная) × [чат со всеми состояниями → маркдаун-набор →
войс+диктовка+запись → вложение с пиллами → агентские поверхности → мировое
время → пикер тем] + переключение тем туда-обратно на macOS 26 (glass-нода
резидентна — см. `themedPanelSurface`, не пересоздавать в if-ветках).

## 7. Правила, оплаченные кровью

- Мокапы — только транскрипцией кода вьюхи (размеры/иконки/строки из
  исходников; SF Symbols рендерить в PNG-маски), ничего «по памяти».
- Новый элемент каркаса = автоматически все темы; тема = только токены.
- TODO: убрать `default:` из `ThemeDecorations` — единственный switch по
  темам, где компилятор не ловит забытую тему.
