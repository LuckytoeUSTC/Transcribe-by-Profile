# Setup on Windows

Use PowerShell 7, whisper.cpp, FFmpeg, FFprobe, a Whisper model, and the Silero VAD model. A Buzz installation can supply the executables. Models and executables are downloaded separately and excluded from Git.

## Local configuration

Copy `transcribe.config.example.json` to `transcribe.config.json` and edit the paths and API credentials. The local file is ignored by Git. Relative paths start from its directory.

```powershell
Copy-Item .\transcribe.config.example.json .\transcribe.config.json
notepad .\transcribe.config.json
```

| Setting | Value |
|---|---|
| `api.url` | Full chat-completions URL, ending in `/v1/chat/completions` |
| `api.key` | Your complete API key |
| `whisper_cli` | Path to `whisper-cli.exe` |
| `ffmpeg`, `ffprobe` | Paths to both executables; required for every input format |
| `vad_model` | Path to `ggml-silero-v6.2.0.bin` |
| `models.turbo` | Path to `ggml-large-v3-turbo-q5_0.bin` |
| `models.medium` | Optional path to `ggml-medium.bin` |

Common Buzz executable locations are detected automatically. You may instead place executables in `tools/` and models in `models/`.

## Environment variables

Environment variables override the local configuration:

```powershell
[Environment]::SetEnvironmentVariable('TRANSCRIBE_API_URL', 'https://provider.example/v1/chat/completions', 'User')
[Environment]::SetEnvironmentVariable('TRANSCRIBE_API_KEY', 'your-key', 'User')
[Environment]::SetEnvironmentVariable('TRANSCRIBE_MODEL_TURBO', 'D:\Models\ggml-large-v3-turbo-q5_0.bin', 'User')
```

Other variables: `TRANSCRIBE_MODEL_MEDIUM`, `TRANSCRIBE_VAD_MODEL`, `TRANSCRIBE_WHISPER_CLI`, `TRANSCRIBE_FFMPEG`, and `TRANSCRIBE_FFPROBE`. `TRANSCRIBE_CONFIG` selects another configuration file. Subtitle Edit's OpenAI-compatible settings provide an API fallback.

## Commands

Add the repository directory to your user `PATH` and open a new terminal. Keep other PATH entries unchanged. The included launchers provide `transcribe`, `transcribe_refine`, `transcribe_glossary`, and `transcribe_lecture`; PowerShell 7 users can also run the `.ps1` files directly.

```powershell
transcribe -?
transcribe "D:\recordings\sample.mp3" -SkipRefine
```

For assistance locating dependencies and configuring this checkout, see [Codex-assisted setup](SETUP_WITH_CODEX.md).
