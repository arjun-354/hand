# Hand

A voice agent that lives in the MacBook notch and controls the whole Mac. Hold **Right Option**, say what you want ("play the weeknd on spotify", "open storage in settings"), let go.

Decisions are made by [TypeSafe's Jev](https://docs.typesafe.ai), a System One model that returns typed choices with calibrated confidence instead of generated text — about 0.2s and a fraction of a cent per step.

## How it works

1. **Listen** — push-to-talk, Apple on-device speech recognition (`SpeechListener`).
2. **Route** — one Jev call: what kind of request (open / quit / operate / other) and which installed app (`Agent`).
3. **See** — the front window is read through the Accessibility API and flattened into a labelled list like `e5: search field: What do you want to play?` (`ScreenReader`).
4. **Decide** — one Jev call per step asks in parallel: is the goal done, click/type/submit, which element, which field, and which words from the request to type.
5. **Act** — a glowing pointer glides to the element, then Hand clicks or pastes text (`Pointer`, `Input`). Loops up to 8 steps.

The notch UI (`NotchView`, `NotchWindow`) drops out of the camera housing and shows each step live.

## Setup

```bash
# 1. TypeSafe key (never commit it)
mkdir -p ~/.config/hand && echo 'TYPESAFE_API_KEY=your_key' > ~/.config/hand/.env && chmod 600 ~/.config/hand/.env
scripts/test-jev.sh

# 2. Build and run
scripts/build-app.sh --run
```

Grant **Accessibility**, **Microphone**, and **Speech Recognition** to Hand when asked. The build is signed with your Apple Development identity when one exists, so grants survive rebuilds.

Requires macOS 14+ and Swift 5.10+ (Command Line Tools are enough, no Xcode project).

## Debugging

Logs go to `~/Library/Logs/Hand/` — `hand.log` for every run, `last-screen.txt` for what Hand last saw.

```bash
open build/Hand.app --args --say "open storage in settings"   # run a command without speaking
open build/Hand.app --args --axdump com.spotify.client        # what Hand can see in an app
open build/Hand.app --args --axtree com.spotify.client        # raw accessibility tree
open build/Hand.app --args --demo                             # notch animation only
```

## Known limits

- Sees text labels, not pixels: unlabeled icon buttons are invisible.
- Can only type words that were spoken; Jev doesn't generate text.
- Chromium Embedded apps (Spotify) are relaunched once with `--force-renderer-accessibility` so their UI is readable.
