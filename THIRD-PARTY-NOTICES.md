# Third-Party Notices

Cuate bundles the following third-party components. Their licenses apply to
those components independently of Cuate's own license.

## Mermaid

- Files: `Cuate/Resources/mermaid.min.js`, `android/app/src/main/assets/mermaid.min.js`
- Version: 11.12.1 — <https://github.com/mermaid-js/mermaid>
- License: MIT

> Copyright (c) 2014–2025 Knut Sveidqvist and Mermaid contributors
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
> THE SOFTWARE.

## Word-frequency lists (LayoutFix addon)

- Files: `Cuate/Addons/LayoutFix/Resources/words_{en,es,ru}.txt`
- Derived from [hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords)
  (OpenSubtitles 2018 corpus lists), with curated additions.
- License: **CC-BY-SA 4.0** — these data files (and derivatives of them) remain
  under CC-BY-SA 4.0 with attribution to the source above, independently of the
  license covering Cuate's code. See also
  [`Cuate/Addons/LayoutFix/README.md`](Cuate/Addons/LayoutFix/README.md).

## Android dependencies

The Android app depends on AndroidX / Jetpack Compose, Kotlin coroutines,
OkHttp and Room — all licensed under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). They are
fetched from Maven at build time and are not vendored in this repository.

## Trademarks and logos

- Provider names and logos (OpenAI, Anthropic, Google Gemini, Mistral,
  DeepSeek, Moonshot/Kimi, OpenRouter, Deepgram, Brave, Nous Research) are
  trademarks of their respective owners, used here solely to identify the
  services the user can connect to. No affiliation or endorsement is implied.
- PLAUD and the Plaud "Λ·" mark are trademarks of their owner. Cuate is an
  independent application that works with Plaud via the user's own account
  and Plaud's public third-party API; no affiliation or endorsement is
  implied.
- Design mockups under `design/` include renders of Apple SF Symbols, used in
  accordance with the Xcode and SF Symbols license terms for Apple-platform
  software.
