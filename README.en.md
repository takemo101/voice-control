# voice-control (English summary)

**Hold a key and speak, and your Mac does it.** A macOS menu-bar app (and the `vc` command) that runs Mac operations from your voice or text, and answers questions in a chat. The full documentation is in Japanese ([README.md](README.md)); this page is a short English guide. **It is an experiment, not a finished product.**

[Download the latest dmg](https://github.com/takemo101/voice-control/releases/latest) (macOS 26 or later, Apple silicon).

## What it does

| Use | How | What happens |
|---|---|---|
| Ask by voice | Hold a key (default: Shift), speak, release | Tiny-Jev (an on-device 0.6B model) picks a matching skill; only the commands that skill allows are run |
| Dictation | Another key | Your speech is typed into the frontmost app |
| Chat | A chat key, or the Chat window | Questions are answered by Apple's on-device model or an agent you choose (agy, opencode, Claude, Codex…), with optional tools |

Audio and screen contents never leave your Mac, except where you explicitly choose an external agent (the settings window says so).

**Dictation extras (experimental)**: register up to four keys to press after typing (Enter, ⌘Enter, …) and switch between them and “don't send” with a shortcut, the menu bar, or Settings > Voice; paste the last input again or copy a recent one (the last five are kept in memory only); an opt-in history (Settings > History, off by default; text and time only, in a file only you can read, auto-deleted after 7 days by default); speech language “Auto” (with a downloaded model) and a space added before English text typed right after a word.

## Languages

Two settings, both defaulting to Japanese:

- **Display language** (Settings > General > Language): the UI text (settings window, dialogs, menu, on-screen panel, screenshot selection, chat and Markdown windows, the `vc` command help) is shown in Japanese or English. Skill names/descriptions and agent answers are not translated. Permission prompts (microphone etc.) follow your Mac's language.
- **Speech recognition language** (Settings > Voice > Language): the language you speak. It affects recognition (Apple SpeechTranscriber `en-US`, or the downloaded Whisper model), live captions, the spoken voice, the spoken "yes" for confirmations, and the language the models are told to answer in.

The skill selection was built and measured in Japanese. With the same sentences translated to English it worked (action vs. chat: 19/20 and 20/20 on 40 sentences), but confidence is lower, so you may see more confirmations. Japanese-specific word rules (for example "end the chat" phrases in chat) do not work in English.

## Getting started

1. Open the dmg and move `VoiceControl.app` to Applications. If Gatekeeper blocks it: `xattr -dr com.apple.quarantine /Applications/VoiceControl.app`.
2. Open Settings > General and follow the setup checklist (microphone and accessibility permissions, the Tiny-Jev model download, about 1.2 GB).
3. Hold the key, say "Open Calculator" (or the equivalent in your language), release.

## Safety in brief

The language model can only run commands that a skill's `allowed-commands` permits; the check is done in code, not in the prompt. Speech, screen text, and model output are treated as untrusted data. Destructive operations ask for confirmation. See [SPEC.md](SPEC.md) (Japanese) for the requirements.

## License

See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
