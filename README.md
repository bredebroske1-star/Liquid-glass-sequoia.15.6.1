# Liquid Glass for macOS Sequoia

A small desktop customization app for macOS Sequoia 15.6.1 and newer. The universal app supports Intel and Apple silicon Macs.

## Download

**Latest release: [Liquid Glass 2.3.0](https://github.com/bredebroske1-star/Liquid-glass-sequoia.15.6.1/releases/tag/v2.3.0)**

[Download the macOS installer](https://github.com/bredebroske1-star/Liquid-glass-sequoia.15.6.1/releases/download/v2.3.0/Liquid-Glass-macOS.dmg)

Open the downloaded DMG, drag **Liquid Glass.app** to the **Applications** shortcut, then launch it from Applications. If macOS displays an unidentified-developer warning, Control-click the app and choose **Open**.

SHA-256: `b5b1d6d64ab62bfb4a4b3b1ef4e6dda0453966d1d17b885bf67809f6503367ff`

## Glass Desktop companion

This repository also includes **Glass Desktop**, a separate macOS app with Spotlight-style app/file search and an Ollama Cloud AI assistant, with local Ollama as an optional fallback. It does not modify the Liquid Glass app above.

- **Stable:** [Glass Desktop 1.0.0 release](https://github.com/bredebroske1-star/Liquid-glass-sequoia.15.6.1/releases/tag/glass-desktop-v1.0.0) · [Download DMG](https://github.com/bredebroske1-star/Liquid-glass-sequoia.15.6.1/releases/download/glass-desktop-v1.0.0/Glass-Desktop-macOS.dmg)
- **Nightly:** [latest development build](https://github.com/bredebroske1-star/Liquid-glass-sequoia.15.6.1/releases/tag/nightly) · [Download nightly DMG](https://github.com/bredebroske1-star/Liquid-glass-sequoia.15.6.1/releases/download/nightly/Glass-Desktop-macOS.dmg) (prerelease; may be unstable)
- [Glass Desktop source, setup, and install instructions](./GlassDesktop/README.md)

## Features

- A reversible, click-through glass tint over the desktop wallpaper.
- Optional translucent Finder icons with adjustable 0–100% transparency; apply to selected apps or eligible apps in `/Applications` and `~/Applications`.
- Original user app icons are backed up and can be restored individually or all at once.
- Apple system apps are excluded. macOS may prevent changes to read-only apps.
- Ollama Cloud AI chat with a local Ollama fallback; cloud use requires an API key and internet connection.

Liquid Glass uses user-space customization. It does not disable SIP, change protected system files, or make every macOS window/menu transparent.
