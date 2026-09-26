# Hand

A voice agent that lives in the MacBook notch and controls the whole Mac. Hold **Right Option**, say what you want ("play the weeknd on spotify", "open storage in settings"), let go.

Decisions are made by [TypeSafe's Jev](https://docs.typesafe.ai), a System One model that returns typed choices with calibrated confidence instead of generated text — about 0.2s and a fraction of a cent per step.

## How it works

1. **Listen** — push-to-talk, Apple on-device speech recognition (`SpeechListener`).
2. **Route** — one Jev call: what kind of request (open / quit / operate / other) and which installed app (`Agent`).
3. **See** — the front window is read through the Accessibility API and merged with on-device OCR of a screenshot of the app's windows (`ScreenReader`, `ScreenVision`). Each item is labelled with its section, like `e5: button: New page (in "Scripting")`. The first read starts the moment the talk key goes down.
4. **Decide** — one Jev call per step asks in parallel: is the goal done, click/type/submit, which element, which field, and which words from the request to type.
5. **Remember "this"** — at key-down Hand also records the front app's link, title, selected text and clipboard, so "add the link to this reel to Notion" can paste the reel's URL after switching apps (`SourceContext`).
6. **Act** — Hand clicks or pastes text (`Input`), then looks again. Loops up to 8 steps, stops early when unsure, and never presses Return in a chat box unless you said send/message/reply.

The notch UI (`NotchView`, `NotchWindow`) drops out of the camera housing and shows each step live.

## Setup

```bash
# 1. TypeSafe key (never commit it)
mkdir -p ~/.config/hand && echo 'TYPESAFE_API_KEY=your_key' > ~/.config/hand/.env && chmod 600 ~/.config/hand/.env
scripts/test-jev.sh

# 2. Build and run
scripts/build-app.sh --run
```

Grant **Accessibility**, **Screen Recording**, **Microphone**, and **Speech Recognition** to Hand when asked. The build is signed with your Apple Development identity when one exists, so grants survive rebuilds.

Requires macOS 14+ and Swift 5.10+ (Command Line Tools are enough, no Xcode project).

## Debugging

Logs go to `~/Library/Logs/Hand/` — `hand.log` for every run, `last-screen.txt` for what Hand last saw, `last-capture.png` for its last screenshot.

```bash
open build/Hand.app --args --say "open storage in settings"   # run a command without speaking
open build/Hand.app --args --axdump com.spotify.client        # what Hand can see in an app
open build/Hand.app --args --axtree com.spotify.client        # raw accessibility tree
open build/Hand.app --args --context com.google.Chrome        # what "this" would mean in an app
open build/Hand.app --args --demo                             # notch animation only
```

## Known limits

- Sees text (accessibility labels + OCR), not icons: an unlabeled icon-only button is invisible.
- Can only type words you spoke or values from what you were looking at (link, title, selection, clipboard); Jev doesn't generate text.
- Chromium Embedded apps (Spotify) are relaunched once with `--force-renderer-accessibility` so their UI is readable.
