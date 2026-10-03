# Transcribe by Profile

Local Whisper transcription with profile-aware LLM refinement for lectures, interviews, and podcasts.

## About

Transcribe by Profile is a Windows PowerShell pipeline that keeps speech recognition local while using an OpenAI-compatible API to clean and organize the result. It combines whisper.cpp, Silero VAD, word-level timing, terminology-aware correction, semantic paragraph reconstruction, and optional lecture-note generation.

The included profiles adapt the same pipeline to different material:

- **Course** preserves technical terminology, formulas, qualifications, and long explanations; it can also produce a referenced lecture reading text.
- **Interview** preserves questions, short answers, hesitation, and conversational turn boundaries.
- **Podcast** favors coherent continuous reading and semantic paragraphs suitable for rolling transcripts.

Normal output consists of conventional sentence subtitles (`.srt`), semantic rolling subtitles (`.segmented.srt`), and a readable transcript (`.segmented.md`). Raw Whisper data, VAD mappings, and recovery configuration can be retained when needed.

## Highlights

- Local ASR with whisper.cpp; recordings are not sent to the refinement API.
- Silero VAD removes non-speech regions without adding `[silence]` labels.
- Word timing is remapped to the original media after VAD compaction.
- Recording-specific glossary ranking combines transcript evidence, topic relevance, ASR risk, and conceptual importance.
- Concurrent LLM batches include retries and resumable recovery files.
- Course references may be PDF, TXT, MD, or a directory containing those formats.
- No subject-specific glossary is built in; your own `glossary.txt` remains editable.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 or PowerShell 7
- `whisper-cli.exe` and FFmpeg, either supplied by [Buzz](https://github.com/chidiwilliams/buzz) or installed separately
- A whisper.cpp GGML/GGUF Whisper model
- `ggml-silero-v6.2.0.bin` for VAD
- An OpenAI-compatible chat-completions API for refinement

## Installation

1. Clone or download this repository.
2. Put the repository directory on your user `PATH` so the `.cmd` commands work from any terminal.
3. Copy `transcribe.config.example.json` to `transcribe.config.json`.
4. Configure the API, executable paths, and model paths as described below.
5. Open a new PowerShell window and run `transcribe -?`.

The local `transcribe.config.json` file is ignored by Git and may safely contain machine-specific paths. Environment variables are preferable on shared computers or when the repository directory is synchronized.

## Configuration

### Option A: local configuration file

```powershell
Copy-Item .\transcribe.config.example.json .\transcribe.config.json
notepad .\transcribe.config.json
```

Paths may be absolute or relative to the configuration file. A typical layout is:

```text
Transcribe-by-Profile/
  models/
    ggml-silero-v6.2.0.bin
    ggml-large-v3-turbo-q5_0.bin
  tools/
    whisper-cli.exe
    ffmpeg.exe
  transcribe.config.json
```

Buzz installations are detected automatically, so `whisper_cli` and `ffmpeg` may be left blank when Buzz supplies both executables.

### Option B: environment variables

```powershell
[Environment]::SetEnvironmentVariable('TRANSCRIBE_API_URL', 'https://provider.example/v1/chat/completions', 'User')
[Environment]::SetEnvironmentVariable('TRANSCRIBE_API_KEY', 'your-api-key', 'User')
[Environment]::SetEnvironmentVariable('TRANSCRIBE_MODEL_TURBO', 'D:\Models\ggml-large-v3-turbo-q5_0.bin', 'User')
[Environment]::SetEnvironmentVariable('TRANSCRIBE_VAD_MODEL', 'D:\Models\ggml-silero-v6.2.0.bin', 'User')
```

Additional variables are `TRANSCRIBE_MODEL_MEDIUM`, `TRANSCRIBE_WHISPER_CLI`, `TRANSCRIBE_FFMPEG`, and `TRANSCRIBE_CONFIG`. Subtitle Edit's OpenAI-compatible API settings remain a fallback when neither environment variables nor the local configuration supplies API credentials.

Configuration precedence is: explicit command option, environment variable, local configuration, project-local file, and supported application fallback.

## Quick start

```powershell
# General transcription
transcribe "D:\recordings\audio.mp3"

# Academic lecture with reference material
transcribe "D:\course\lecture.mp4" -Profile course -Topic "computational neuroscience" -Reference "D:\course\references"

# Player-ready subtitle beside the media
transcribe "D:\recordings\audio.mp3" -Brief

# Resume refinement after an interrupted run
transcribe_refine "D:\course\transcripts\lecture_auto.raw.json"
```

See [TRANSCRIBE_HELP.md](TRANSCRIBE_HELP.md) for all commands, outputs, profiles, glossary behavior, and recovery workflows.

## Configure it with Codex

See [SETUP_WITH_CODEX.md](SETUP_WITH_CODEX.md) for a safe, copyable Codex workflow that detects installed tools, prepares local configuration, checks models, and runs a smoke test without committing credentials.

## Privacy and security

Whisper transcription runs locally. The refinement, glossary, and lecture stages send transcript text—and references when explicitly supplied—to the configured API. Review your provider's data policy before using private recordings or documents. Never commit `transcribe.config.json`, API keys, recordings, transcripts, glossaries, or course references.

## Documentation

- [Command reference](TRANSCRIBE_HELP.md)
- [Codex-assisted setup](SETUP_WITH_CODEX.md)
- [Profile template](profiles/PROFILE_TEMPLATE.md)

This repository intentionally does not include a license.
