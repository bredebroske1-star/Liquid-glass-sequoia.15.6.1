# Glass Desktop

Glass Desktop is a lightweight native macOS companion with a Liquid Glass-inspired dashboard, a Spotlight-style app/file/web search, instant calculator results, an Ollama Cloud AI chat with an optional local Ollama fallback, and an optional reversible desktop tint. It supports both Intel and Apple silicon Macs.

## Build and run

Requires macOS 13 or newer and Swift 5.9 or newer:

```sh
swift run
```

## Download and install

- **Stable:** [Glass Desktop 1.0.0 release](https://github.com/bredebroske1-star/Liquid-glass-sequoia.15.6.1/releases/tag/glass-desktop-v1.0.0) · [Download DMG](https://github.com/bredebroske1-star/Liquid-glass-sequoia.15.6.1/releases/download/glass-desktop-v1.0.0/Glass-Desktop-macOS.dmg)
- **Nightly:** [latest development build](https://github.com/bredebroske1-star/Liquid-glass-sequoia.15.6.1/releases/tag/nightly) · [Download nightly DMG](https://github.com/bredebroske1-star/Liquid-glass-sequoia.15.6.1/releases/download/nightly/Glass-Desktop-macOS.dmg) (prerelease; may be unstable)

Open the downloaded DMG and drag **Glass Desktop.app** to **Applications**. The app is unsigned, so on first launch you may need to Control-click it in Applications and choose **Open**.

## Build the installer

On a Mac with Xcode Command Line Tools installed, run `./package-macos.sh` from this directory. It builds an Intel and Apple silicon universal app and writes `dist/Glass-Desktop-macOS.dmg`.

Use the **Tint desktop** switch to add a click-through, all-Spaces tint behind desktop icons. Turn it off to remove the overlay immediately. The intensity slider adjusts the treatment, and **Command-Shift-G** toggles it.

Press **Command-Shift-Space** to open Glass Search from anywhere. Its **Search**, **Apps**, and **Ask AI** options switch between local/web search, a filterable app library, and local chat. The Apps view uses translucent glass tiles with white, semi-transparent logo marks and opens the selected app; original app icons remain unchanged. Search finds apps in the standard Applications folders and files indexed by macOS Spotlight under your home folder. Select a result to open it.
If another app already uses that shortcut, try **Command-Option-Space**. Glass Desktop also shows a small **Glass Search** launcher at the bottom-left of the desktop; it only reacts when you click the launcher and does not intercept wallpaper or icon clicks.
Typing a query also shows Google web-search options for installed browsers, such as Chrome, Opera, Firefox, and Safari. Select a browser row to open that search directly in the chosen browser. Web searches open Google in your browser; Glass Desktop does not fetch or display web results itself.
Type an arithmetic expression such as `(12 + 8) * 3` to calculate it instantly. Select the result or press Return to copy the answer.

Choose **Ask AI** to use **Ollama Cloud** by default, without running a model on this Mac. Create an API key at [ollama.com/settings/keys](https://ollama.com/settings/keys), enter it in the AI panel, and save it to macOS Keychain. The default cloud model is `gemma4:31b`; you can change the model name in the panel. Cloud chat needs an internet connection and is subject to Ollama account usage and pricing.

The local **On this Mac** provider remains available as a manual fallback. It uses Ollama at `127.0.0.1:11434` and the default `qwen2.5:3b` text model. For local photo understanding, install `qwen2.5vl:3b` as well. Glass Desktop does not silently switch providers if a cloud request fails.

Attach up to three homework photos with the photo button; images are resized and compressed on-device. By default, macOS Vision reads the photo text locally, then sends the recognized text (not the photo itself) with your prompt to the selected AI service. Turn on **Use full photo vision (for diagrams)** when the selected model needs to see the actual image; the photo is then sent to that service. Cloud mode sends chat content and OCR text to Ollama Cloud; use the local provider if you want inference to stay on this Mac. Responses stream as they are generated. The tutor is prompted to show math steps, explain the method, and check answers. Chat requests include only recent conversation messages.

The app waits briefly for typing to pause, cancels outdated Spotlight searches, indexes application names once per launch instead of rescanning Applications on every keystroke, and limits file results. App-logo processing runs off the UI thread and uses a small bounded cache. The optional desktop tint uses a lightweight color overlay instead of a costly full-screen blur. These choices help keep the app responsive on older Intel Macs, including 2018 MacBook Pro models. The dashboard's **App Library** below the widgets lists installed apps and lets you filter and launch them.

## Scope and limitations

macOS does not provide a supported API for a third-party app to force Liquid Glass onto arbitrary apps, system menus, or Apple's built-in widgets. This app styles its own dashboard and search panel, and adds a reversible desktop-level overlay. It does not disable SIP, modify protected system files, or change other apps' icons.
