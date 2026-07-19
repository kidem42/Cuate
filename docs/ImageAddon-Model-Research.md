# Ресерч: модели и провайдеры для Image-аддона AISpotlight

Дата: 17.07.2026. Источники: arena.ai (LMArena, срез 10.07.2026), Artificial Analysis Image Arena, Reddit (r/StableDiffusion, r/Bard, r/GeminiAI, r/OpenAI, r/singularity, r/midjourney), HN, официальные прайсы провайдеров.

---

## 1. Генерация изображений (text-to-image)

### Лидерборды (ELO, обе арены сходятся)

| # | Модель | Провайдер | arena.ai ELO | Artificial Analysis ELO | Цена /1k img |
|---|--------|-----------|--------------|--------------------------|--------------|
| 1 | **GPT Image 2** | OpenAI | **1385** (отрыв ~80) | **1336** | $211 (high) |
| 2 | Reve 2.1 / 2.0 | Reve | 1302 / 1271 | 1254 | $24 |
| 3 | MAI-Image-2.5 | Microsoft | 1257 | 1264 | $48 |
| 4 | Nano Banana 2 (Gemini 3.1 Flash Image) | Google | 1261 | 1252 | $67 |
| 5 | Nano Banana 2 Lite | Google | 1250 | 1257 | ~$34 |
| 6 | Nano Banana Pro (Gemini 3 Pro Image) | Google | 1245 | 1217 | $134 |
| 7 | HiDream-O1-Image-1.5 | HiDream (CN) | — | 1262 | $80 |
| 8 | Seedream 5.0 Pro / 4.5 | ByteDance | 1231 / 1147 | 1163 (4.5) | ~$40 |
| — | FLUX.2 [max] / [pro] | BFL | 1162 (20-е место) | 1189 / 1184 | ~$30/MP |
| — | Ideogram 4.0 Quality | Ideogram | 1207 | 1165 | $90 |
| — | Recraft V4.1 Utility Pro | Recraft | 1169 | 1205 | $210 |
| — | ERNIE-Image / Turbo | Baidu | — | 1162 / 1161 | $30 / $10 |
| — | Imagen 4 Ultra | Google | 1148 | 1169 | deprecated (откл. ~08.2026) |

Midjourney v8: API нет, на аренах не бенчмаркается. Meta muse-image: высокий ELO, но API нет вообще.

### Reddit-консенсус (где расходится с аренами)

- **GPT Image 2**: реально топ (тон, текст, консистентность персонажей), «жёлтый фильтр» побеждён. Минусы: цена, цензура (серые плашки), нет честного 16:9.
- **Nano Banana 2/Pro**: лучший выбор практиков для качества и редактирования, НО массовые жалобы 2026: «нерфы» (тихая деградация качества), урезание лимитов, ужесточение цензуры. API/AI Studio свободнее чата Gemini.
- **Seedream 4.5/5.0**: «тихий убийца», №2 после Nano Banana по мнению юзеров, главный козырь — почти нет цензуры.
- **FLUX.2**: середина таблиц, но любимец локального комьюнити (Klein 9B), нет случайных цензурных отказов.
- **Reve / Recraft / MAI**: высокий ELO — почти нулевой mindshare у пользователей. Осторожно с выбором «по бенчмарку».
- Цензура — критерий №1 у практиков; лидерборды её не отражают.

### Азиатские провайдеры (проверено отдельно)

- **Baidu ERNIE-Image/Turbo** — единственный «новый» азиат в топ-30, open weights, дёшево, доступен через fal.ai/SiliconFlow без китайского аккаунта.
- **HiDream-O1-1.5** — #3 мира на Artificial Analysis.
- **Kuaishou Kolors 2.1 / Kling Image 3.0** — середина (ELO 1124/1091), международный API + fal.ai.
- **Zhipu GLM-Image** — отличная доступность и цена (~$0.015/img), но ELO 1044 (низ).
- **Moonshot Kimi, Xiaomi MiMo** — генерации изображений НЕТ вообще (только понимание). MiniMax Image-01 заброшен. SenseTime, iFlytek, Naver, Kakao, LG, Sakana — нерелевантны (нет конкурентного публичного image-API).

## 2. Редактирование (instruction-based edit / inpaint)

arena.ai Image Edit (10.07.2026): GPT Image 2 — 1465 (№1), MAI-Image-2.5 — 1401, Seedream 5.0 Pro — 1393, Nano Banana Pro — 1388, Nano Banana 2 — 1385, Qwen-Image-Edit — 1241 (лучший Apache-2.0), FLUX Kontext — 1181 (устарел).

Reddit: Nano Banana — «go-to» для правок и сохранения identity (с оговоркой про искажение лиц); GPT Image — хуже с консистентностью при edit; FLUX Kontext лучший для реставрации старых фото. Важно: генеративные редакторы **перерисовывают весь кадр** (сдвиг кропа/тона) — для точечного удаления объектов нужны специализированные inpaint-инструменты.

## 3. Апскейл / Super-Resolution

Публичных арен нет; консенсус обзоров + Reddit:

| Ниша | Лидер | Примечания |
|------|-------|------------|
| Faithful (фотореализм) | **Topaz API** (Wonder 2/3) | Коммерческий стандарт; до 512 MP; ~$0.08–0.15/кадр; есть на fal.ai и Replicate |
| Open-source SOTA | **SeedVR2** | Консенсус r/StableDiffusion 2026: «by a long margin»; медленный, >2–3x галлюцинирует микротекстуру |
| Дёшево и чисто | **Recraft Crisp Upscale** | $0.004/img, «no hallucinated details» |
| Креативный | Magnific (до 16K) | Дорогой, вытесняется; Krea Enhance до 22K |
| Бюджет | Real-ESRGAN (Replicate ~$0.0025), Clarity Upscaler | |

SUPIR устаревает. Stability Fast Upscale $0.02 — ок как middle-ground.

## 4. Удаление фона

| Инструмент | Цена | Примечания |
|-----------|------|------------|
| **Bria RMBG-2.0** | $0.018 (fal.ai) | Заявленный SOTA (вендорский бенчмарк!), лицензионно чистые данные, API-стандарт |
| **BiRefNet HR** | копейки (fal) / бесплатно | Открытый SOTA, консенсус r/StableDiffusion |
| **Photoroom** | $0.02 (мин. $20/мес) | Победитель краудсорс Background Removal Arena; латентность ~350 мс |
| remove.bg | ~$0.20+ | Качество ок, репутация «price gouging» |
| Recraft | $0.01 | Удобно при ключе Recraft |

## 5. Удаление объектов (Object Cleanup)

| Инструмент | Цена | Примечания |
|-----------|------|------------|
| **Bria Eraser** | ~$0.04 (fal/Replicate) | Лучший специализированный API, чистая лицензия |
| Recraft Erase Region | $0.002 | Самый дешёвый масковый вариант |
| fal.ai object-removal | ~$0.01–0.04 | Удаление по текстовому описанию (без маски) |
| FLUX Fill / LaMa (IOPaint) | дёшево/бесплатно | Комьюнити-стандарт |
| Nano Banana / GPT Image edit | — | Качество топ, но перерисовывают весь кадр — не для точечного cleanup |

**Юридическая заметка**: удаление вотермарок = обычный inpainting, но DMCA §1202 запрещает удалять чужие вотермарки (CMI), и ToS всех провайдеров запрещают нарушение IP. Решение: в UI функция называется «Удаление объектов», слово watermark не используется.

## 6. Покрытие агрегаторами (топ-модели × доступность)

| Модель | fal.ai | Replicate | Together | OpenRouter | Direct |
|--------|--------|-----------|----------|------------|--------|
| GPT Image 2 | ✓ | ✓ (official) | ✗ | ✓ | OpenAI |
| Nano Banana 2 / Pro | ✓ | ✓ (official) | ✗ | ✓ | Gemini API |
| Seedream 4.5/5.0 | ✓ | ✓ | ✗ | ✓ | BytePlus |
| Reve 2.1 | ✓ | ✗ | ✗ | ✗ | api.reve.com |
| FLUX.2 | ✓ | ✓ | ✓ | ✓ | BFL |
| Topaz Upscale | ✓ | ✓ (official) | ✗ | ✗ | Topaz API |
| Recraft (upscale/erase/gen) | ✓ | ✓ (official) | ✗ | ✗ | Recraft |
| SeedVR2 / Real-ESRGAN | ✓ | ✓ | ✗ | ✗ | open source |
| Bria RMBG-2.0 | ✓ | ✓ | ✗ | ✗ | Bria |
| BiRefNet | ✓ | ✓ | ✗ | ✗ | open source |
| Bria Eraser | ✓ | ✓ | ✗ | ✗ | Bria |
| MAI-Image-2.5 | ✗ | ✗ | ✗ | ✓ | MS Foundry |
| remove.bg / Photoroom / Magnific / Adobe | ✗ | ✗ | ✗ | ✗ | только direct |

**Итог:** fal.ai — ~15/19 лидеров, единственный агрегатор, закрывающий все 5 категорий. Replicate — близкий второй (~14/19, нет Reve), хорош как failover. OpenRouter — только генерация/редактирование. Together — аутсайдер.

## 7. Рекомендуемый лайнап для аддона

Пользователь выбирает провайдера и модель per-функция на вкладке настроек (как для голоса). Предлагаемые дефолты и опции:

| Функция | Дефолт | Опции |
|---------|--------|-------|
| Апскейл | Recraft Crisp (fal.ai, $0.004) | Topaz (премиум), SeedVR2 (fal), Real-ESRGAN (бюджет) |
| Удаление фона | Bria RMBG-2.0 (fal.ai, $0.018) | BiRefNet v2 (fal), Recraft |
| Удаление объектов | Bria Eraser (fal.ai) | Recraft Erase, fal object-removal (по тексту) |
| Генерация (позже) | Nano Banana 2 (ключ Gemini уже есть у юзера) | GPT Image 2 (ключ OpenAI уже есть), Seedream 4.5, FLUX.2 |

Ключи: fal.ai — один новый ключ закрывает апскейл/фон/cleanup + генерацию; для генерации дополнительно переиспользуются существующие ключи OpenAI/Gemini из `APIKeyStore`.
