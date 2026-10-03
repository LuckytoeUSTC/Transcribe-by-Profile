# Configure Transcribe by Profile with Codex

Codex can inspect your Windows installation, locate Buzz, FFmpeg, whisper.cpp, and existing model files, then create the ignored local configuration without changing the scripts.

## Recommended request

Open the cloned repository as a Codex project and send:

```text
Configure this Transcribe by Profile checkout for my Windows computer.
Do not modify the program logic or profiles. Inspect the documented configuration
options, locate an existing Buzz/whisper.cpp installation, FFmpeg, Whisper models,
and the Silero VAD model. Create only transcribe.config.json with local paths,
make sure it remains ignored by Git, and run non-destructive syntax and dependency
checks. Do not print, copy, commit, or expose API keys. Ask me before downloading
large model files or changing PATH.
```

If API credentials are already stored in Subtitle Edit, tell Codex to leave them there. Otherwise, set `TRANSCRIBE_API_URL` and `TRANSCRIBE_API_KEY` yourself after Codex finishes path discovery; avoid sending a key through chat.

## What Codex should verify

1. `transcribe.config.json` is ignored by Git.
2. `whisper-cli.exe`, FFmpeg, the selected Whisper model, and the Silero VAD model exist.
3. Every `.ps1` file parses under the installed PowerShell version.
4. `transcribe -?` opens correctly from a fresh terminal after PATH configuration.
5. A short, non-private sample can complete local Whisper transcription before API refinement is tested.

## Optional PATH request

After reviewing the detected repository path, ask:

```text
Add only this repository directory to my user PATH, preserving every existing PATH
entry and its order. Verify the four command launchers from a new PowerShell process.
```

## Model download request

Model binaries are deliberately excluded from Git. If none are installed, ask Codex to identify the exact official download source and file size first. Approve the download only after choosing between the faster `turbo` model and the smaller/slower `medium` model. The Silero VAD model is separate and is required for the default pipeline.

## Safe API configuration

Prefer user environment variables or the ignored local configuration. Do not place credentials in profiles, scripts, Markdown files, shell history shared with others, or committed files. Before the first push, ask Codex to scan tracked files for credentials and personal absolute paths.
