# Transcribe

Local Whisper transcription with LLM correction, semantic paragraphs, and optional lecture notes. Profiles adapt the output to courses, interviews, and podcasts.

Whisper and VAD run locally. Configure the API using environment variables or a local config file; Subtitle Edit settings are also supported. See [setup](SETUP.md). LLM stages send transcript text and selected references to that service.

All profiles preprocess every input format, including WAV, MP3, and video, into the same 16 kHz mono WAV for both VAD and Whisper. Mono keeps its channel content; stereo uses only the left channel; inputs with more than two channels are downmixed. The original media timeline and leading audio offsets are preserved. There is no automatic right-channel review. FFmpeg and FFprobe are required.

## Quick start

```powershell
transcribe "D:\recordings\audio.mp3"
transcribe "D:\course\lecture.mp4" -Profile course -Topic "recurrent neural networks"
transcribe "D:\course\lecture.mp4" -Terms "Purkinje cell; Brian2"
transcribe "D:\course\lecture.mp4" -Profile course -Reference "D:\course\slides.pdf" -GlossaryRenew
transcribe "D:\recordings\audio.mp3" -Brief
transcribe -?
```

Language defaults to `auto`. The command loads `glossary.txt` beside the media when present and writes to a `transcripts` folder there. The `course` profile also selects a reference when exactly one PDF is beside the media.

## Common options

| Option | Purpose |
|---|---|
| `-Profile course` | Academic lectures and a lecture reading text |
| `-Profile interview` | Questions, short answers, and conversational turns |
| `-Profile podcast` | Continuous speech and readable paragraphs |
| `-Topic "..."` | Context for terminology and organization |
| `-Language en` | Set the spoken language explicitly |
| `-Terms "A; B"` / `-Glossary "A; B"` | Temporary terms shared by Whisper and refinement |
| `-GlossaryFile "..."` | Select a terminology file |
| `-Reference "..."` | A PDF, TXT, MD, or folder containing those formats |
| `-GlossaryRenew` | Merge recording-specific terms into `glossary.txt` |
| `-RefineModel qwen3.8-chat` | Select the API model; this is the default |
| `-Brief` | Only one SRT beside the media, with the same base name |
| `-SkipRefine` | Stop after Whisper and keep recovery files |
| `-FullOutput` | Keep working files after success |

`-Brief` cannot be combined with `-FullOutput`, `-SkipRefine`, or `-OutputDirectory`. Custom profiles use `-Profile "path\profile.json"`; see [the profile template](profiles/PROFILE_TEMPLATE.md).

Languages: `auto`, `en` (English), `zh` (Chinese), `ja` (Japanese), `ko` (Korean), `fr` (French), `de` (German), `es` (Spanish), `ru` (Russian), `pt` (Portuguese).

Whisper models: `turbo` (default), `medium`. API models include `qwen3.8-chat` (default) and `deepseek-flash-2`; availability depends on your provider.

## Glossaries and references

A glossary is a UTF-8 text file with one preferred term per line. Blank lines and `#` comments are ignored:

```text
# Names and technical terms
Eve Marder
Purkinje cell
integrate-and-fire model
```

Whisper uses the existing list. Before refinement, the LLM uses the rough transcript, topic, and references to select and rank terms. This working list leaves your manual glossary unchanged unless you add `-GlossaryRenew`. Existing terms and header comments are retained; internal comments may be replaced with priority headings.

Reference folders include only directly contained PDF/TXT/MD files. Extracted text is cached in the system temporary directory.

Generate a glossary separately:

```powershell
transcribe_glossary "D:\course\references" -Topic "recurrent neural networks"
transcribe_glossary "D:\course\slides.pdf" -NoMerge
```

The default output is `glossary.txt` beside the reference. `-GlossaryFile` selects another destination; `-NoMerge` writes `glossary.extracted.txt` instead.

## Resume or regenerate

Recovery settings are saved before API processing. Resume without running Whisper again:

```powershell
transcribe_refine "D:\course\transcripts\lecture_auto" -FullOutput
transcribe_refine "D:\course\transcripts\.work\lecture_auto\raw.json" -RefineModel deepseek-flash-2
```

Both forms load the matching VAD map and saved settings. Priority is command line, profile, saved settings, then defaults. Standalone refinement reuses supplied terminology; it does not rerun glossary generation.

Regenerate only lecture notes:

```powershell
transcribe_lecture -SegmentedPath "D:\course\transcripts\lecture_auto.segmented.md" -Reference "D:\course\slides.pdf"
```

## Output

| File | Use |
|---|---|
| `lecture_auto.srt` | Conventional subtitles |
| `lecture_auto.segmented.srt` | Semantic paragraphs for rolling subtitles |
| `lecture_auto.segmented.md` | The same paragraphs for reading |
| `lecture_auto.lecture.md` | Course reading text, when requested |

Long paragraphs are split at complete-sentence transitions using text length and context. Lecture timestamps use whole seconds.

Working files live in `.work/lecture_auto/`: `raw.json`, `raw.srt`, `vad.json`, `config.json`, and any generated glossary, refinement data, or diagnostics. No `raw.txt` is generated. A lecture review appears there only when corrections or unresolved questions need attention.

`-FullOutput` retains working files. Failed or warning-producing runs retain recovery data automatically; a clean successful run removes it. Review notes remain when present. Existing flat raw JSON files can also be passed explicitly and are moved with their recovery sidecars into `.work`.

Progress appears above batch completion lines. Batches are reported as they finish, with their original numbers and elapsed time; output text stays in source order. Warnings identify unchanged fallback text, and failed responses are saved under `api-diagnostics`. Validation checks structure and coverage, not factual accuracy.

## Additional options

| Option | Purpose / default |
|---|---|
| `-WhisperModel medium` | Choose the local model; default `turbo` |
| `-WhisperModelPath "..."` | Use a model outside the default model folder |
| `-WhisperPrompt`, `-RefinePrompt`, `-LecturePrompt` | Read stage instructions from a file |
| `-LectureNotes` | Request lecture notes without a course profile |
| `-NoSDH` | Remove sound-event labels; VAD stays enabled |
| `-RefineBatchMinutes` | Approximate correction batch duration; default `3` |
| `-WhisperThreads` | Local processing threads; default `8` |
| `-WhisperCpu` | Disable GPU acceleration |
| `-OutputDirectory` | Choose the output folder |
| `-Verbose` | Show technical details |
| `-VerboseVad` | Show individual VAD regions and mappings |
