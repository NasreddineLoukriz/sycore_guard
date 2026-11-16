# Models — what is in the app, and how to get it

SYcore Guard runs three models, all on the device:

| Role | Model | Quantisation | Size |
|---|---|---|---|
| Speech → text | Whisper-tiny, 30 s window | int8 | 41.6 MB |
| Guard classifier | Qwen3-0.6B (LiteRT-LM) | dynamic int4 weights, fp32 activations | 328.7 MB |
| Verdict → speech | Matcha-TTS + a phonemiser | fp16 | 89.8 MB |

**They are not in this repository.** The bundle is ~460 MB, and a Git host is the wrong
place for it: every clone would pay for it, every CI run would download it, and GitHub
rejects any single file over 100 MB anyway. The code is here; the weights are fetched once,
locally, with the commands below.

---

## Expected layout

The app reads the bundle from `assets/models/`, declared as asset directories in
`pubspec.yaml`:

```
assets/models/
├── stt/
│   ├── whisper_tiny_30s_i8.tflite      # 39.2 MB
│   └── tokenizer.json                  #  2.4 MB
├── llm/
│   └── Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm   # 328.7 MB
└── tts/
    ├── matcha_textenc_fp16.tflite      # 14.1 MB
    ├── matcha_decoder_fp16.tflite      # 21.6 MB
    ├── matcha_vocoder_fp16.tflite      # 27.6 MB
    ├── dp_g2p_matcha_fp16.tflite       # 24.6 MB
    ├── g2p_dict.txt.gz                 #  1.7 MB
    ├── emb.bin                         #  134 KB
    ├── config.json                     #    2 KB
    └── g2p_meta.json                   #    2 KB
```

`lib/src/models/model_installer.dart` names each of these paths in `ModelAssets`; the
directories themselves are copied into the app bundle at build time and installed into app
storage on first launch.

---

## Download

```bash
cd /path/to/sycore_guard
mkdir -p assets/models/{stt,llm,tts}

# 1) Guard LLM — LiteRT-LM bundle built for mobile GPU/NPU/CPU
curl -L -o assets/models/llm/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm \
  "https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm"

# 2) Whisper-tiny (int8) and its tokenizer
curl -L -o assets/models/stt/whisper_tiny_30s_i8.tflite \
  "https://huggingface.co/litert-community/whisper-tiny/resolve/main/whisper_tiny_30s_i8.tflite"
curl -L -o assets/models/stt/tokenizer.json \
  "https://huggingface.co/openai/whisper-tiny/resolve/main/tokenizer.json"

# 3) Matcha-TTS bundle (every file the installer expects)
for f in matcha_textenc_fp16.tflite matcha_decoder_fp16.tflite matcha_vocoder_fp16.tflite \
         dp_g2p_matcha_fp16.tflite g2p_dict.txt.gz emb.bin config.json g2p_meta.json; do
  curl -L -o "assets/models/tts/$f" \
    "https://huggingface.co/litert-community/Matcha-TTS/resolve/main/$f"
done
```

If you have the Hugging Face CLI, the equivalent is:

```bash
hf download litert-community/Qwen3-0.6B \
  Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm --local-dir assets/models/llm
```

**Do not substitute `Qwen3-0.6B.litertlm`.** That older bundle carries a tokenizer that
LiteRT-LM ≥ 0.17 rejects (`piece must not include null character`). The `dynamic_wi4b32_afp32`
file is the one this app was built and measured against.

---

## Verify what you downloaded

`flutter analyze` and `flutter test` do not need the weights. One test does check them, and it
skips itself when the bundle is absent — so once the files are in place, run:

```bash
flutter test test/model_assets_test.dart
```

To check bytes rather than presence, `sha256sum` against this table (first 16 hex digits
shown; the full digest is what a hostile mirror would have to match):

| file | size | sha256 (first 16) |
|---|---|---|
| `assets/models/llm/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm` | 328.7 MB | `03e7da1eb1108b50` |
| `assets/models/stt/tokenizer.json` | 2.4 MB | `27fc476bfe7f1729` |
| `assets/models/stt/whisper_tiny_30s_i8.tflite` | 39.2 MB | `6748ac565a228c4a` |
| `assets/models/tts/config.json` | 2 KB | `7363e9e4dda1613a` |
| `assets/models/tts/dp_g2p_matcha_fp16.tflite` | 24.6 MB | `6e4b481f6874dfab` |
| `assets/models/tts/emb.bin` | 134 KB | `18be34cda4afa1f5` |
| `assets/models/tts/g2p_dict.txt.gz` | 1.7 MB | `5b3493a8cd4d20b7` |
| `assets/models/tts/g2p_meta.json` | 2 KB | `7b87bfeaaa072be2` |
| `assets/models/tts/matcha_decoder_fp16.tflite` | 21.6 MB | `2c2e70235f0daaa9` |
| `assets/models/tts/matcha_textenc_fp16.tflite` | 14.1 MB | `adf2642699b09a9f` |
| `assets/models/tts/matcha_vocoder_fp16.tflite` | 27.6 MB | `7d0b4d975eb1558d` |

The Qwen checkpoint is re-exported upstream from time to time. If the digest differs but the
app still answers correctly, you have a newer export, not a corrupted file.

---

## Licensing and shipping

The app's own code is MIT (see `LICENSE`). The weights keep their upstream licences —
Qwen3-0.6B is Apache-2.0, Whisper is MIT, Matcha-TTS is MIT, and the LiteRT community
conversions follow the model they convert. Read the model card before you redistribute them,
and keep `NOTICE`/licence files with any bundle you ship.

For a store build, do **not** ship the 460 MB base module:

- **Play Asset Delivery** with an install-time asset pack, or
- **download on first use** — the installer already supports `fromNetwork()` and reports
  progress; only the URL constant changes.

Either way, the app must not *require* a network connection to keep its core promise: typed
messages are checked by the rules engine even before any model is installed.
