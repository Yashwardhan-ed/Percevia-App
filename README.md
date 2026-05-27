# Percevia

**An offline-first AI companion that helps blind and visually impaired people understand the world around  them — powered end to end by Gemma running on the device itself.**

## Overview

### Purpose

Give blind and visually impaired users an independent, private way to understand
their surroundings — scenes, text, people, and obstacles — using nothing but
their phone, even with no internet connection.

### The problem

The most capable AI vision models assume two things that quietly exclude the
people who would benefit most. They assume a reliable internet connection — yet
connectivity is weakest exactly when a blind user needs help: an unfamiliar
street, a basement shop, a rural bus stand. And they assume it is fine to
continuously stream a user's surroundings to a remote server. For someone who
cannot visually verify what the camera is capturing, that is not a privacy
footnote — it is the whole problem. Most assistive apps are also English-only
and bury the few things that matter under menus of things that don't.

### The solution

Percevia runs **Gemma 4** (a vision-language model) **fully on the device**. No
image ever leaves the phone and no network round-trip is required, which removes
the connectivity dependency and the privacy concern at the same time. Around
Gemma it layers fast on-device specialist models so every task uses the right
tool:

- **Scene description** — a quick summary or a longer, detailed brief.
- **Visual Q&A** — ask, by voice, a specific question about what is in front of you.
- **Text reading (OCR)** — read text aloud, then ask Gemma questions about it.
- **Object awareness** — nearby objects announced with a spatial sense of the scene.
- **Face recognition** — register people you know and be told hands-free who is in front of you.
- **Depth / obstacle estimation** — gauge how close obstacles are.
- **Multilingual speech** — output in English, Hindi, and Marwari.
- **Hands-free voice commands** and a discreet **"Disappear"** mode for use in public.

The whole experience lives on one screen with large, high-contrast,
text-labelled buttons, designed for non-visual use and for screen readers
(TalkBack on Android, VoiceOver on iOS).

## Download and use the app

### Requirements

- An Android phone (a physical device is recommended for camera features).
- An internet connection **on first launch only**, to download the AI model once.
- A few GB of free storage for the on-device model.

### Install the APK (recommended)

Most users should just install the prebuilt app — no developer tools needed:

1. Open the **[Releases](https://github.com/Yashwardhan-ed/Percevia-App/releases)**
   page of this repository.
2. Under the latest release, expand **Assets** and download
   **`app-release.apk`** onto your Android phone.
3. Open the downloaded file. If prompted, allow installing apps from this
   source (Android may call it "Install unknown apps") and continue.
4. Launch **Percevia** and complete the one-time setup below.

### Install from source (developers)

1. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install) and add it to your `PATH`.
2. Clone this repository and open a terminal in the project root.
3. Fetch dependencies:

   ```bash
   flutter pub get
   ```
   
4. Put the app on a phone, either by running it on a connected device (USB
   debugging enabled) or by building an installable APK:

   ```bash
   # Run on a connected device
   flutter run

   # Or build a release APK to install manually
   flutter build apk --release
   # then install build/app/outputs/flutter-apk/app-release.apk on the phone
   ```

### First launch (one-time setup)

On the first run, Percevia will either shift to gemini api for the first 2 tries(in case of direct link download) or **automatically downloads the on-device Gemma model
and configures it for you**(in case of installing from source ,developers) — there is nothing to copy, and no computer is
needed. This is a one-time download: keep the app open and connected to the
internet until it finishes. After that, the app works **fully offline**.

If a "model not ready" message appears, confirm you have an internet connection
and enough free storage, then retry — setup resumes automatically.

### Using the app

All controls are large, labelled, and screen-reader friendly.

- **Describe** — tap for a quick scene summary; press and hold for a longer, detailed description.
- **Voice input / Visual Q&A** — press and hold, then ask a question about what is in front of you.
- **Read text** — runs OCR on what the camera sees and reads it aloud; you can then ask questions about that text.
- **Object scan** — announces nearby objects and roughly where they are.
- **More menu** — face add/recognition, manage registered faces, history, recent context, output language, and speech rate.
- **Voice commands** — say things like "describe", "read text", "recognize", "register face", or "stop" to drive the app hands-free.
- **Language** — cycle the output language (English / Hindi) from the More menu.
- **Disappear mode** — hides the entire interface in public; double-tap anywhere to instantly stop speech.

### Optional: smart-glasses camera (prototype)

Percevia can use an external Wi-Fi camera (our in-development smart glasses) in
place of the phone camera by connecting to its IP address, so scene
description, OCR, face recognition, and obstacle estimation all work through the
glasses. This is entirely optional — the app is fully usable on a phone alone.
