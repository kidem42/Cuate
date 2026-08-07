# Research: models and providers for the Cuate Image addon

Date: 2026-07-17. Sources: arena.ai (LMArena, snapshot 2026-07-10), Artificial Analysis Image Arena, Reddit (r/StableDiffusion, r/Bard, r/GeminiAI, r/OpenAI, r/singularity, r/midjourney), HN, official provider pricing.

---

## 1. Image generation (text-to-image)

### Leaderboards (ELO, both arenas agree)

| # | Model | Provider | arena.ai ELO | Artificial Analysis ELO | Price /1k img |
|---|-------|----------|--------------|--------------------------|---------------|
| 1 | **GPT Image 2** | OpenAI | **1385** (~80 ahead) | **1336** | $211 (high) |
| 2 | Reve 2.1 / 2.0 | Reve | 1302 / 1271 | 1254 | $24 |
| 3 | MAI-Image-2.5 | Microsoft | 1257 | 1264 | $48 |
| 4 | Nano Banana 2 (Gemini 3.1 Flash Image) | Google | 1261 | 1252 | $67 |
| 5 | Nano Banana 2 Lite | Google | 1250 | 1257 | ~$34 |
| 6 | Nano Banana Pro (Gemini 3 Pro Image) | Google | 1245 | 1217 | $134 |
| 7 | HiDream-O1-Image-1.5 | HiDream (CN) | — | 1262 | $80 |
| 8 | Seedream 5.0 Pro / 4.5 | ByteDance | 1231 / 1147 | 1163 (4.5) | ~$40 |
| — | FLUX.2 [max] / [pro] | BFL | 1162 (20th place) | 1189 / 1184 | ~$30/MP |
| — | Ideogram 4.0 Quality | Ideogram | 1207 | 1165 | $90 |
| — | Recraft V4.1 Utility Pro | Recraft | 1169 | 1205 | $210 |
| — | ERNIE-Image / Turbo | Baidu | — | 1162 / 1161 | $30 / $10 |
| — | Imagen 4 Ultra | Google | 1148 | 1169 | deprecated (shutting down ~2026-08) |

Midjourney v8: no API, not benchmarked on the arenas. Meta muse-image: high ELO, but no API at all.

### Reddit consensus (where it diverges from the arenas)

- **GPT Image 2**: genuinely top (tone, text, character consistency), the "yellow filter" is beaten. Downsides: price, censorship (gray placeholder cards), no honest 16:9.
- **Nano Banana 2/Pro**: practitioners' best pick for quality and editing, BUT widespread complaints through 2026: "nerfs" (quiet quality degradation), tightened limits, harsher censorship. The API/AI Studio is freer than the Gemini chat.
- **Seedream 4.5/5.0**: the "silent killer", #2 after Nano Banana in users' opinion; its main trump card is almost no censorship.
- **FLUX.2**: mid-table, but the local community's favorite (Klein 9B), with no random censorship refusals.
- **Reve / Recraft / MAI**: high ELO — almost zero mindshare among users. Be careful picking "by benchmark".
- Censorship is criterion #1 for practitioners; the leaderboards do not reflect it.

### Asian providers (checked separately)

- **Baidu ERNIE-Image/Turbo** — the only "new" Asian entry in the top 30, open weights, cheap, available through fal.ai/SiliconFlow without a Chinese account.
- **HiDream-O1-1.5** — #3 in the world on Artificial Analysis.
- **Kuaishou Kolors 2.1 / Kling Image 3.0** — mid-table (ELO 1124/1091), international API + fal.ai.
- **Zhipu GLM-Image** — excellent availability and price (~$0.015/img), but ELO 1044 (bottom).
- **Moonshot Kimi, Xiaomi MiMo** — NO image generation at all (understanding only). MiniMax Image-01 is abandoned. SenseTime, iFlytek, Naver, Kakao, LG, Sakana — irrelevant (no competitive public image API).

## 2. Editing (instruction-based edit / inpaint)

arena.ai Image Edit (2026-07-10): GPT Image 2 — 1465 (#1), MAI-Image-2.5 — 1401, Seedream 5.0 Pro — 1393, Nano Banana Pro — 1388, Nano Banana 2 — 1385, Qwen-Image-Edit — 1241 (best Apache-2.0), FLUX Kontext — 1181 (outdated).

Reddit: Nano Banana is the "go-to" for edits and identity preservation (with the caveat that it distorts faces); GPT Image is worse at consistency when editing; FLUX Kontext is the best for restoring old photos. Important: generative editors **repaint the whole frame** (shifting crop/tone) — pinpoint object removal needs specialized inpaint tools.

## 3. Upscale / Super-Resolution

There are no public arenas; the consensus of reviews + Reddit:

| Niche | Leader | Notes |
|-------|--------|-------|
| Faithful (photorealism) | **Topaz API** (Wonder 2/3) | The commercial standard; up to 512 MP; ~$0.08–0.15/frame; available on fal.ai and Replicate |
| Open-source SOTA | **SeedVR2** | The r/StableDiffusion 2026 consensus: "by a long margin"; slow, hallucinates micro-texture above 2–3x |
| Cheap and clean | **Recraft Crisp Upscale** | $0.004/img, "no hallucinated details" |
| Creative | Magnific (up to 16K) | Expensive, being displaced; Krea Enhance goes to 22K |
| Budget | Real-ESRGAN (Replicate ~$0.0025), Clarity Upscaler | |

SUPIR is going stale. Stability Fast Upscale at $0.02 is a fine middle ground.

## 4. Background removal

| Tool | Price | Notes |
|------|-------|-------|
| **Bria RMBG-2.0** | $0.018 (fal.ai) | Claimed SOTA (a vendor benchmark!), license-clean data, the API standard |
| **BiRefNet HR** | pennies (fal) / free | The open SOTA, r/StableDiffusion consensus |
| **Photoroom** | $0.02 (min. $20/mo) | Winner of the crowdsourced Background Removal Arena; ~350 ms latency |
| remove.bg | ~$0.20+ | Quality is fine, reputation for "price gouging" |
| Recraft | $0.01 | Convenient if you already have a Recraft key |

## 5. Object removal (Object Cleanup)

| Tool | Price | Notes |
|------|-------|-------|
| **Bria Eraser** | ~$0.04 (fal/Replicate) | The best specialized API, clean licensing |
| Recraft Erase Region | $0.002 | The cheapest mask-based option |
| fal.ai object-removal | ~$0.01–0.04 | Removal by text description (no mask) |
| FLUX Fill / LaMa (IOPaint) | cheap/free | The community standard |
| Nano Banana / GPT Image edit | — | Top quality, but they repaint the whole frame — not for pinpoint cleanup |

**Legal note**: removing watermarks is ordinary inpainting, but DMCA §1202 forbids removing someone else's watermarks (CMI), and every provider's ToS forbids IP infringement. The resolution: in the UI the function is called "Remove objects", and the word watermark is never used.

## 6. Aggregator coverage (top models × availability)

| Model | fal.ai | Replicate | Together | OpenRouter | Direct |
|-------|--------|-----------|----------|------------|--------|
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
| remove.bg / Photoroom / Magnific / Adobe | ✗ | ✗ | ✗ | ✗ | direct only |

**Bottom line:** fal.ai covers ~15/19 of the leaders and is the only aggregator that closes all 5 categories. Replicate is a close second (~14/19, no Reve) and is a good failover. OpenRouter covers generation/editing only. Together is the outsider.

## 7. Recommended lineup for the addon

The user picks the provider and model per function on the settings tab (as with voice). Proposed defaults and options:

| Function | Default | Options |
|----------|---------|---------|
| Upscale | Recraft Crisp (fal.ai, $0.004) | Topaz (premium), SeedVR2 (fal), Real-ESRGAN (budget) |
| Background removal | Bria RMBG-2.0 (fal.ai, $0.018) | BiRefNet v2 (fal), Recraft |
| Object removal | Bria Eraser (fal.ai) | Recraft Erase, fal object-removal (by text) |
| Generation (later) | Nano Banana 2 (the user already has a Gemini key) | GPT Image 2 (the OpenAI key is already there), Seedream 4.5, FLUX.2 |

Keys: fal.ai — one new key covers upscale/background/cleanup plus generation; for generation the existing OpenAI/Gemini keys from `APIKeyStore` are additionally reused.
