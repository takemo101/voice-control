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

## Chat

- **Queue while it thinks** (like Zed and Codync): if you ask again while an answer is being worked on — by typing or by voice — the new question joins a queue (dashed bubbles in the conversation) and is sent when the current one finishes. Waiting typed messages are merged into one question; spoken ones go one at a time. Each queued message has **Send now** (stops the current question and sends that one first) and **Remove**. When the input is empty the send button becomes **Stop**: it stops the current question and drops the queue (the dropped messages stay in the log as “not sent”). Not included: injecting a message into the answer that is already running (Zed's Steer).
- **Spoken “stop”** (chat key only): saying only “stop”, “cancel”, “never mind”, “wait” (or the Japanese equivalents) stops reading aloud and the current question and drops the queue. It is a whole-utterance word match (no model): a longer sentence such as “stop the music” is an ordinary question. The words are fixed for now (not configurable).
- **Answers can start sooner** (agents that stream over ACP): the text appears while the agent is still answering, and read-aloud starts sentence by sentence. It depends on the agent — measured: opencode streams, agy sends almost everything at once (little gain). Apple's model and non-streaming agents behave as before.
- **“Latest” button** when you scroll up in the conversation, and a **multi-line input** (Return sends, ⇧Return inserts a line break; up to 6 lines).
- **Attach files** (external-agent chats only): drop files on the chat window, pick them with the paperclip button, or paste copied files with ⌘V. They go with the next question only, and **you are asked before every send** (names, sizes, destination). Small text files (up to 100 KB) are passed as content; others are copied into the working folder for the run and passed as a link, only when tools are “+ Read files” or higher. Keys, `.env`, `~/.ssh`, and this app’s data are refused (judged by name and location — the confirmation is the last safeguard).
- Chat history is kept in memory only.

## Dictation extras (experimental)

- **Keys to press after typing** (Settings > Dictation): add as many as you like with “Add a key” (Enter, ⌘Enter, …). The choices are “Don't send” plus those keys; switch with a shortcut, the menu bar, or the “Current key” setting (no restart).
- **Paste the last input again** (shortcut in Settings > Keys, or the menu bar) and **copy a recent input** (the last five are kept in memory only).
- **History** (Settings > Dictation, **off by default**): when on, only the typed text and the time are saved, in `~/.voice-control/history.jsonl` (readable only by you), for 7 days by default. Search, copy, delete one, or delete all. Nothing is sent anywhere.
- **Text cleanup**: remove filler words (um, uh…), and add a space before English text typed right after a word (never for Japanese).

## Settings pages

General · Keys · Voice (language, recording, read-aloud) · Dictation · Chat · Models · Skills.

## Languages

Two settings, both defaulting to Japanese:

- **Display language** (Settings > General > Language): the UI text (settings window, dialogs, menu, on-screen panel, screenshot selection, chat and Markdown windows, the `vc` command help) is shown in Japanese or English. Skill names/descriptions and agent answers are not translated. Permission prompts (microphone etc.) follow your Mac's language.
- **Speech recognition language** (Settings > Voice > Language: Japanese / English / Auto): the language you speak. **Auto** detects the language from the audio, but only with a downloaded Whisper model; Apple's recognizer must be told a language, so Auto means the Mac's language there. It affects recognition (Apple SpeechTranscriber `en-US`, or the downloaded Whisper model), live captions, the spoken voice, the spoken "yes" for confirmations, and the language the models are told to answer in.

The skill selection was built and measured in Japanese. With the same sentences translated to English it worked (action vs. chat: 19/20 and 20/20 on 40 sentences), but confidence is lower, so you may see more confirmations. The spoken “stop” words work in both Japanese and English; the “end the chat” phrases are Japanese only.

**Languages can be added** (for developers): per-language data (names, spoken “yes”, filler words, “stop” words…) lives in one place, translation tables are per language, and untranslated strings fall back to English. See [docs/development.md](docs/development.md) (Japanese). Adding a language covers the UI, recognition and read-aloud only; the skill selection accuracy has been measured only in Japanese and English.

## Getting started

1. Open the dmg and move `VoiceControl.app` to Applications. If Gatekeeper blocks it: `xattr -dr com.apple.quarantine /Applications/VoiceControl.app`.
2. Open Settings > General and follow the setup checklist (microphone and accessibility permissions, the Tiny-Jev model download, about 1.2 GB).
3. Hold the key, say "Open Calculator" (or the equivalent in your language), release.

## Safety in brief

The language model can only run commands that a skill's `allowed-commands` permits; the check is done in code, not in the prompt. Speech, screen text, and model output are treated as untrusted data. Destructive operations ask for confirmation. Speech and typed text are not written to files or logs, **except** the opt-in dictation history above and a screenshot you take yourself (kept for 3 minutes in a private location). When a command or an agent connection is stopped, the child processes it started are stopped too (next release). See [SPEC.md](SPEC.md) (Japanese) for the requirements.

## License

See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
