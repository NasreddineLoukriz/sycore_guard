# 90-second demo — shot list and narration

Record on the device itself (`adb shell screenrecord`) or with the phone mirrored. Keep the
status bar clean: no notifications, no SIM names, 100 % battery, and set the clock to a plain
time. English UI, light mode, one hand.

| # | Time | On screen | Narration (read slowly, ~140 words total) |
|---|---|---|---|
| 1 | 0:00–0:08 | App already open on an empty chat. A message is typed: `My password is Hunter2!` and sent. | "Every chat app asks you to trust it with what you type. This one checks the message before it leaves your hands." |
| 2 | 0:08–0:22 | The bubble comes back **BLOCKED**, the chip reads *Credential or secret*, and the same sentence appears with `XXXXXXXX` in place of the password. | "The password is caught by the on-device rules — no model, no network, milliseconds — and the message comes back with the secret masked, so the rest of it is still usable." |
| 3 | 0:22–0:34 | Type `My number is 06631233` (Arabic-Indic digits: `٠٦٦٣١٢٣٣`). Blocked, digits replaced by `X`s of the same length. | "Phone numbers too, in Latin or Arabic-Indic digits. Every value is masked character for character." |
| 4 | 0:34–0:44 | Type `Let's meet at 6 to review the slides.` → **SAFE**, and the model's own sentence is shown. | "Now an ordinary message. The rules pass it, and the on-device Qwen model confirms it. No server saw either sentence." |
| 5 | 0:44–1:00 | Tap the mic, speak a short note ("remind me to call the dentist tomorrow"), stop. The transcript appears in the composer, then send → verdict. | "Voice works the same way: Whisper transcribes it on the phone, the text lands in the composer for review, and then it is checked like anything else." |
| 6 | 1:00–1:12 | Tap the speaker; the notice *preparing voice* appears once, then the verdict is spoken. | "The verdict can be spoken too — synthesised locally by Matcha, cached, so it replays instantly." |
| 7 | 1:12–1:20 | Pull down notification shade / toggle airplane mode on, then back. Repeat step 1. | "Airplane mode. Nothing changes, because nothing was ever going online." |
| 8 | 1:20–1:30 | Cut to the model install strip for a second, then the GitHub repo on screen: file tree, `docs/models.md`, green CI badge. | "The code is open — MIT, with the tests and the model instructions. Built with Flutter, LiteRT-LM, Whisper and Matcha." |

## Checklist before recording

- [ ] Real device, `arm64-v8a`, API 30+, models already installed (step 4's install strip needs a fresh install — record it once, cut it in).
- [ ] `flutter build apk --release` isn't required for the video, but avoid the debug banner: run a **profile** build (`flutter run --profile`).
- [ ] Set the app to English so the narration matches the UI; show Arabic at 1:18 in a two-second cut if you want the bilingual point.
- [ ] Font size default; nothing scrolled mid-typing.
- [ ] Screen recording at 1080×2400, 30 fps; trim each cut on the tap.
- [ ] Add captions — Upwork autoplays muted.

## Publishing

1. Upload to YouTube as **unlisted**, title `SYcore Guard — offline privacy guard for text and voice (90s demo)`.
2. Add the link to the top of `README.md` and to the Upwork project card.
3. Keep the raw file too (`docs/img/` is for stills, not video).
