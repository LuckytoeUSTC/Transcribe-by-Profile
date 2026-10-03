# Transcribe

Transcribe audio or video locally with Whisper, then correct and organize the transcript with an OpenAI-compatible LLM API. Profile-aware processing supports academic lectures, interviews, and podcasts; output includes conventional subtitles, semantic rolling subtitles, readable transcripts, and optional referenced lecture notes.

Whisper and VAD run locally. Refinement sends transcript text to the configured API, while reference files are sent only when explicitly selected for glossary or lecture processing.

## Installation and portable configuration

Add the repository directory to your user `PATH`, copy `transcribe.config.example.json` to the ignored `transcribe.config.json`, and configure the API and model paths. Paths in that file may be absolute or relative to the repository. Alternatively, use environment variables so one checkout can move between machines without editing tracked files.

Required API settings are `TRANSCRIBE_API_URL` and `TRANSCRIBE_API_KEY`. Model/tool variables are `TRANSCRIBE_MODEL_TURBO`, `TRANSCRIBE_MODEL_MEDIUM`, `TRANSCRIBE_VAD_MODEL`, `TRANSCRIBE_WHISPER_CLI`, and `TRANSCRIBE_FFMPEG`. Buzz executables and Subtitle Edit API settings are detected as fallbacks. Full manual setup is in `README.md`; a safe Codex-assisted workflow is in `SETUP_WITH_CODEX.md`.

## Quick start

```powershell
# Standard transcription
transcribe "D:\recordings\audio.mp3"

# Academic course
transcribe "D:\course\f0.mp4" -Profile course -Topic "computational neuroscience"

# Add a few temporary terms
transcribe "D:\course\f0.mp4" -Terms "Brian2; Purkinje cell"

# Renew glossary.txt after Whisper using the rough transcript and references
transcribe "D:\course\f0.mp4" -Profile course -Reference "D:\course\references" -GlossaryRenew

# One subtitle file beside the media, ready for a player
transcribe "D:\recordings\audio.mp3" -Brief

# Resume only the LLM refinement stage
transcribe_refine "D:\course\transcripts\f0_auto.raw.json"

# Generate or update glossary.txt without transcribing
transcribe_glossary "D:\course\references" -Topic "computational neuroscience"

# Show command help
transcribe -?
```

The first positional argument is always the input media file. `-Profile` selects defaults for the recording type, and `-Topic` gives the LLM a short subject hint.

By default, the spoken language is detected automatically, `glossary.txt` beside the media is loaded when present, and output goes to a `transcripts` folder beside the media. The `course` profile automatically uses a single PDF beside the media as its reference. `transcribe_refine` automatically restores the matching `.vad.json` timing map and `.config.json` settings when they are available.

## Common options

| Option | Use |
|---|---|
| `-Profile course` | Academic lectures; also creates a lecture reading text |
| `-Profile interview` | Interviews and group conversations |
| `-Profile podcast` | Podcasts and continuous spoken programs |
| `-Topic "..."` | Improve terminology ranking and global structure |
| `-Language en` | Specify the spoken language instead of automatic detection |
| `-Brief` | Keep only one conventional SRT beside the media |
| `-SkipRefine` | Run Whisper only and retain recovery files |
| `-RefineModel qwen3.8-chat` | Select the LLM used after Whisper |
| `-GlossaryFile "..."` | Use a particular terminology file |
| `-Terms "A; B"` | Add a few temporary terms |
| `-Reference "..."` | Supply course references for verification and lecture generation |
| `-GlossaryRenew` | Update `glossary.txt` after Whisper using recording evidence and references |
| `-FullOutput` | Keep raw, timing, configuration, and diagnostic files |

## Profiles

Profiles supply tested defaults. An explicit command-line option overrides the corresponding profile value.

| Profile | Intended use | Additional behavior |
|---|---|---|
| `course` | Academic lectures | Preserves terminology and reasoning; creates `.lecture.md` |
| `interview` | Interviews and group conversations | Preserves questions, short answers, hesitation, and turn boundaries |
| `podcast` | Podcasts and spoken programs | Produces paragraphs suited to continuous reading |

```powershell
transcribe "D:\course\f0.mp4" -Profile course
transcribe "D:\course\f0.mp4" -Profile course -RefineModel deepseek-flash-2
transcribe "D:\course\f0.mp4" -Profile "D:\course\my-profile.json"
```

The profile template and field reference are in `profiles\PROFILE_TEMPLATE.md` beside the scripts.

## Glossaries and references

If `glossary.txt` exists beside the input media, it is loaded automatically. Use `-GlossaryFile` to select a different file. Glossaries are UTF-8 text with one preferred spelling per line; blank lines and lines beginning with `#` are ignored. No subject-specific glossary is built in.

```text
# Names
Eve Marder
David Marr

# Technical terms
integrate-and-fire model
Purkinje cell
Brian2
```

The same glossary helps both Whisper and LLM refinement. For a short temporary list:

```powershell
transcribe "D:\course\f0.mp4" -Terms "Brian2; Purkinje cell"
```

`-Terms` and `-Glossary` are synonyms.

A reference can be one PDF, TXT, or MD file, or a directory. For a directory, only PDF/TXT/MD files directly inside it are read. Extracted text is cached locally.

Whisper first uses the existing manual glossary. Before refinement, terms are automatically reordered for this recording from the rough transcript, with references used to recover canonical spellings. This recording-specific list is stored in the recovery configuration, while the manual file remains unchanged. Add `-GlossaryRenew` to merge the recording-grounded result back into `glossary.txt`:

```powershell
transcribe "D:\course\f0.mp4" `
  -Profile course `
  -Topic "single-neuron computation" `
  -Reference "D:\course\references" `
  -GlossaryRenew
```

Generate or update a glossary without transcribing:

```powershell
transcribe_glossary "D:\course\slides.pdf"
transcribe_glossary "D:\course\references" -Topic "single-neuron computation"
transcribe_glossary "D:\course\slides.pdf" -GlossaryFile "D:\course\terms.txt"
transcribe_glossary "D:\course\slides.pdf" -NoMerge
```

By default, existing terms are retained and new terms are added. During transcription, the rough transcript is the primary evidence: ranking weights are 35% recording evidence, 25% topic relevance, 20% ASR error risk, and 20% expected frequency or conceptual importance. Terms are written in canonical form; uncertain names, transcript fragments, numerical facts, and terms found only in unrelated reference sections are excluded. Initial manual header comments are preserved. Old comments inside the term list are replaced with sparse `High priority`, `Medium priority`, and `Additional terms` headings, translated when most terms in that tier are Chinese. `-NoMerge` writes `glossary.extracted.txt` instead.

## Refining an existing Whisper result

`transcribe` saves recovery files before calling the LLM. If refinement is interrupted, run `transcribe_refine` on the raw JSON:

```powershell
transcribe_refine "D:\course\transcripts\f0_auto.raw.json"
transcribe_refine "D:\course\transcripts\f0_auto.raw.json" -Profile course
transcribe_refine "D:\course\transcripts\f0_auto.raw.json" -RefineModel deepseek-flash-2
```

Standalone refinement automatically reads the matching `.vad.json` and `.config.json`. Its setting priority is: explicit command-line options, profile values, saved configuration, then built-in defaults.

The refinement workflow is:

1. Correct overlapping batches and reconstruct complete sentences.
2. Read the complete ordered sentence list to create a global outline and semantic paragraph boundaries.
3. For an overlong semantic paragraph, offer complete-sentence candidates near balanced text positions to the LLM and validate its context-aware split choices.
4. Create conventional subtitles, semantic rolling subtitles, and a readable transcript.
5. For the `course` profile, reuse the global outline to create lecture notes.

## Output

The normal workflow keeps three files:

```text
f0_auto.srt             Conventional subtitles for display over video
f0_auto.segmented.srt   Semantic paragraphs for rolling transcript views
f0_auto.segmented.md    The same semantic paragraphs as readable Markdown
```

The `course` profile additionally creates:

```text
f0_auto.lecture.md          Lecture reading text
f0_auto.lecture.review.md   Corrections or unresolved factual uncertainty, when present
```

`.segmented.srt` and `.segmented.md` use identical paragraphs. If a semantic paragraph exceeds about 1,400 characters, the script finds balanced candidate sentence endings and asks the LLM to choose the most natural transitions from the full paragraph context. Invalid choices are retried; the nearest balanced endings are used only if all retries fail. Lecture timestamps use whole seconds.

`-Brief` keeps only `D:\course\f0.srt` beside `D:\course\f0.mp4`. It cannot be combined with `-FullOutput`, `-SkipRefine`, or `-OutputDirectory`.

`-SkipRefine` keeps `.raw.txt`, `.raw.srt`, `.raw.json`, `.vad.json`, and `.config.json`, but does not create refined or segmented output.

`-FullOutput` additionally keeps `.raw.txt`, `.raw.srt`, `.raw.json`, `.vad.json`, `.config.json`, and `.refined.json` after successful refinement.

## Languages and models

Common language codes:

| Code | Language | Code | Language |
|---|---|---|---|
| `auto` | Automatic detection | `ko` | Korean |
| `zh` | Chinese | `fr` | French |
| `en` | English | `de` | German |
| `ja` | Japanese | `es` | Spanish |
| `ru` | Russian | `pt` | Portuguese |

Refinement models:

| Model | Notes |
|---|---|
| `qwen3.8-chat` | Default; faster in the tested course transcript |
| `deepseek-flash-2` | Slower and more conservative |

Whisper models:

| Model | Notes |
|---|---|
| `turbo` | Default; faster |
| `medium` | Alternative local model |

## Less common options

These options are mainly for customization or troubleshooting:

| Option | Description | Default |
|---|---|---|
| `-WhisperPrompt` | Read Whisper instructions from a file | None |
| `-RefinePrompt` | Read additional refinement instructions from a file | None |
| `-LecturePrompt` | Read lecture-generation instructions from a file | None |
| `-LectureNotes` | Request lecture reading text without relying on a profile | Off |
| `-RefineBatchMinutes` | Approximate source duration per correction batch | `3` |
| `-WhisperThreads` | Whisper processing threads | `8` |
| `-WhisperCpu` | Disable GPU acceleration | Off |
| `-VerboseVad` | Show every VAD segment and mapping line | Off |
| `-NoSDH` | Remove sound-event labels from final refined output | Off |
| `-OutputDirectory` | Override the output directory | `transcripts` beside the media |
