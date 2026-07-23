#!/usr/bin/env python3
"""
Generates the LayoutFix statistical tables from OpenSubtitles frequency lists.

Outputs (per language):
  trigrams_<lang>.bin — (N+1)^3 bytes; q = clamp(round(-log10(p)*10), 0..254),
                        255 = never seen ("impossible"). Index N = word boundary.
  words_<lang>.txt    — "word q" lines (top words), q = -log10(rel freq)*10.

Alphabets here MUST match NgramScorer.swift exactly.
"""
import math, sys, os

ALPHABETS = {
    "ru": "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
    "en": "abcdefghijklmnopqrstuvwxyz",
    "es": "abcdefghijklmnopqrstuvwxyzáéíóúüñ",
}
TOP_WORDS = 30000

# Curated anglicisms/brands the 2018 subtitles corpus predates or misses
# (gmail, tiktok, ...). Appended to the word lists so DecisionEngine treats
# them as known words; the trigram tables are untouched. q=55 puts them at
# the youtube(54)/iphone(58) frequency tier. Idempotent: existing entries win.
EXTRA_Q = 55
BRANDS = [
    "gmail", "google", "whatsapp", "telegram", "instagram", "facebook",
    "tiktok", "twitter", "youtube", "netflix", "spotify", "zoom", "slack",
    "skype", "discord", "reddit", "linkedin", "github", "chatgpt", "openai",
    "iphone", "ipad", "macbook", "android", "windows", "linux", "chrome",
    "safari", "firefox", "amazon", "uber", "paypal", "steam", "twitch",
    "figma", "notion", "viber", "signal", "wifi", "bluetooth",
]
# Tech acronyms/terms (HTML, CSS, JSON …). Their letter patterns are
# anti-language — impossible trigrams, no vowels — so the trigram clean bar
# can never accept them; DecisionEngine has a whitelist-override rule that
# trusts the frequency list instead (see verdict()). Latin-only: these are
# typed as-is by RU/ES users too, so they go into every latin list.
ACRONYMS = [
    "html", "css", "scss", "js", "jsx", "ts", "tsx", "json", "yaml", "xml",
    "sql", "php", "http", "https", "url", "api", "rest", "sdk", "cli",
    "gui", "ui", "ux", "ai", "ml", "llm", "gpt", "cpu", "gpu", "ram",
    "ssd", "hdd", "usb", "hdmi", "pdf", "docx", "xlsx", "csv", "exe",
    "dmg", "apk", "ios", "macos", "vpn", "dns", "tcp", "udp", "ssh",
    "ftp", "ssl", "tls", "jpg", "jpeg", "png", "gif", "svg", "webp",
    "mp3", "mp4", "mkv", "zip", "rar", "git", "npm", "pip", "nodejs",
    "react", "vue", "kotlin", "docker", "kubernetes", "nginx", "mysql",
    "postgres", "mongodb", "redis", "jira", "vscode", "xcode", "webpack",
]
EXTRA_WORDS = {
    "en": BRANDS + ACRONYMS + [
        "email", "online", "offline", "login", "podcast", "smartphone",
        "laptop", "deadline", "feedback", "hashtag", "livestream",
    ],
    "es": BRANDS + ACRONYMS + ["email", "online", "wasap", "mail"],
    "ru": [
        "гугл", "гмейл", "ватсап", "вотсап", "телеграм", "телега",
        "инстаграм", "инста", "фейсбук", "ютуб", "ютюб", "тикток",
        "твиттер", "нетфликс", "спотифай", "зум", "слак", "скайп",
        "дискорд", "гитхаб", "чатгпт", "айфон", "айпад", "макбук",
        "андроид", "виндовс", "хром", "сафари", "амазон", "убер",
        "пейпал", "стим", "твич", "фигма", "вайфай", "блютуз",
        "имейл", "мейл", "онлайн", "офлайн", "логин", "браузер",
        "апдейт", "апгрейд", "аккаунт", "линк", "подкаст", "стрим",
        "смартфон", "ноутбук", "дедлайн", "фидбек", "дизлайк",
        "репост", "хештег", "сторис",
    ],
}


def append_extras(outdir):
    """Adds missing EXTRA_WORDS to existing words_<lang>.txt (no corpus needed)."""
    for lang, words in EXTRA_WORDS.items():
        path = os.path.join(outdir, f"words_{lang}.txt")
        with open(path, encoding="utf-8") as f:
            existing = {line.split()[0] for line in f if line.strip()}
        alpha = set(ALPHABETS[lang])
        added = []
        with open(path, "a", encoding="utf-8") as f:
            for w in words:
                if w in existing or any(ch not in alpha for ch in w):
                    continue
                f.write(f"{w} {EXTRA_Q}\n")
                added.append(w)
        print(f"{lang}: +{len(added)} extras {added}")

def build(lang, src, outdir):
    alpha = ALPHABETS[lang]
    idx = {c: i for i, c in enumerate(alpha)}
    N = len(alpha)          # boundary index == N, table dim = N+1
    dim = N + 1
    counts = [0] * (dim ** 3)
    total_tri = 0
    word_rows = []          # (word, count) that passed the alphabet filter
    total_wc = 0

    with open(src, encoding="utf-8") as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) != 2:
                continue
            w, c = parts[0].lower(), int(parts[1])
            if not w or any(ch not in idx for ch in w):
                continue
            total_wc += c
            word_rows.append((w, c))
            seq = [N] + [idx[ch] for ch in w] + [N]   # ^word$
            for a, b, d in zip(seq, seq[1:], seq[2:]):
                counts[(a * dim + b) * dim + d] += c
                total_tri += c

    # Trigram q-table
    table = bytearray(dim ** 3)
    for i, c in enumerate(counts):
        if c == 0:
            table[i] = 255
        else:
            q = round(-math.log10(c / total_tri) * 10)
            table[i] = max(0, min(254, q))
    with open(os.path.join(outdir, f"trigrams_{lang}.bin"), "wb") as f:
        f.write(table)

    # Word-frequency list
    with open(os.path.join(outdir, f"words_{lang}.txt"), "w", encoding="utf-8") as f:
        for w, c in word_rows[:TOP_WORDS]:
            q = max(0, min(254, round(-math.log10(c / total_wc) * 10)))
            f.write(f"{w} {q}\n")

    seen = sum(1 for c in counts if c > 0)
    print(f"{lang}: dim={dim} trigrams_seen={seen}/{dim**3} "
          f"words={len(word_rows[:TOP_WORDS])} table={len(table)}B")

if __name__ == "__main__":
    # --append-extras <out_dir>: only add the curated words to existing lists.
    if sys.argv[1] == "--append-extras":
        append_extras(sys.argv[2])
        sys.exit(0)
    src_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    for lang in ("ru", "en", "es"):
        build(lang, os.path.join(src_dir, f"{lang}_50k.txt"), out_dir)
    append_extras(out_dir)
