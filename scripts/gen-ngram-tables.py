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
    src_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    for lang in ("ru", "en", "es"):
        build(lang, os.path.join(src_dir, f"{lang}_50k.txt"), out_dir)
