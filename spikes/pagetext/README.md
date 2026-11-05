# Page-text spike (M1)

Proves the riskiest part of the stack before M1 is built on it: can Superclick read a web page's **full** text, including what's scrolled off screen, through the macOS Accessibility API, fast enough to do on every summon?

Throwaway code. The real capture will live in the app.

## Run it

Needs macOS 13+ and Xcode or the Command Line Tools (`xcode-select --install`).

```sh
cd spikes/pagetext
swift run pagetext            # then switch to the browser within 3 seconds
```

Or target a browser directly without switching:

```sh
swift run pagetext --app com.apple.Safari
swift run pagetext --app com.google.Chrome
```

The first run asks for **Accessibility** permission for the app you ran it from (Terminal, iTerm, VS Code…). Turn it on in System Settings → Privacy & Security → Accessibility, quit and reopen that app, and run again.

## The test

1. Open a long article (for example a long Wikipedia page) in Safari. Don't scroll down.
2. Select a sentence somewhere in the visible part.
3. Run the tool and read the report.
4. Repeat in Chrome (and Arc or Edge if you use them).

It **passes** when:

- **Off-screen:** "Ends with" matches the article's last lines, even though you never scrolled there.
- **Speed:** the fastest full read is under 300 ms.
- **Details:** the URL, your selection and the headings came through.

It also saves the full text and the trimmed version (what we'd send by default) next to where you ran it, as `pagetext-<app>-full.txt` and `pagetext-<app>-trimmed.txt`.

## What it tries

- **Text markers:** asks the page for all text between its start and end markers in one call.
- **Tree walk:** walks the accessibility tree collecting text and headings. Slower, but a fallback where markers aren't supported.
- **Chromium switch:** sets `AXManualAccessibility` so Chrome-based browsers expose the page. If that isn't enough it briefly sets `AXEnhancedUserInterface`, then turns it back off.
