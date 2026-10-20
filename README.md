# Transcribe by Profile

Local Whisper transcription with profile-based LLM correction, semantic subtitles, and lecture notes. Built for Windows and PowerShell.

## What it does

- Runs whisper.cpp and Silero VAD locally, with timing mapped back to the source media.
- Applies one audio policy to every profile and format: preserve mono, take only the left channel from stereo, and downmix inputs with more than two channels.
- Uses your glossary, topic, and references to correct terminology and organize the transcript.
- Produces conventional SRT subtitles and matching semantic-paragraph SRT/Markdown.
- Offers course, interview, and podcast profiles; course recordings can also become referenced lecture notes.
- Reports live progress and batch times, limits repeated model failures, and retains recovery data when needed.

## Get started

Install the dependencies and configure an OpenAI-compatible API using the [Windows setup guide](SETUP.md). Executables and model files are not bundled. For assisted setup, see [SETUP_WITH_CODEX.md](SETUP_WITH_CODEX.md).

```powershell
transcribe "D:\recordings\audio.mp3"
transcribe "D:\course\lecture.mp4" -Profile course -Topic "recurrent neural networks"
transcribe "D:\recordings\audio.mp3" -Brief
```

## Output and recovery

Normal output is `.srt`, `.segmented.srt`, and `.segmented.md`; the course profile also creates `.lecture.md`. Auxiliary files are grouped in `transcripts/.work/<recording>/`. Use `-FullOutput` to keep them after a successful run.

```powershell
transcribe_refine "D:\course\transcripts\lecture_auto" -FullOutput
```

See the [command guide](TRANSCRIBE_HELP.md) for glossaries, references, profiles, recovery, and other options.

## Privacy and limitations

Audio recognition stays local. LLM stages send transcript text and selected references, including automatically detected course references, to your configured provider. Keep credentials, private media, transcripts, and reference material out of Git.

Correction and timing are approximate. Unclear speech, repeated ASR hallucinations, and model failures can leave errors; inspect warnings and any lecture review notes before relying on the result.

## License

[MIT](LICENSE). Third-party tools and model files retain their own licenses.
