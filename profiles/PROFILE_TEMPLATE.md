# Transcription profile template

Copy one of the JSON profiles in this folder, rename it, and edit only the settings you want the profile to supply. Run it by name when it remains in this folder, or pass the path to a JSON file elsewhere.

```powershell
transcribe "D:\course\f0.mp4" -Profile course
transcribe "D:\course\f0.mp4" -Profile "D:\course\my-profile.json"
transcribe_refine "D:\course\transcripts\f0_auto.raw.json" -Profile podcast
```

Explicit command-line options override profile values. During standalone refinement, the priority is: command line, profile, saved `.config.json`, built-in defaults.

## Template

```json
{
  "version": 1,
  "name": "my-profile",
  "description": "Short description of the recording type.",
  "language": "auto",
  "whisper_model": "turbo",
  "whisper_model_path": "../models/ggml-large-v3-turbo-q5_0.bin",
  "refine_model": "qwen3.8-chat",
  "refine_batch_minutes": 3,
  "whisper_threads": 8,
  "whisper_instruction": "Context for Whisper.",
  "refine_instruction": "Instructions for transcript refinement.",
  "lecture_notes": false,
  "lecture_instruction": "Optional instructions for the lecture reading text.",
  "reference": "course-slides.pdf",
  "topic": "Course topic",
  "glossary_renew": false,
  "no_sdh": false
}
```

All fields except `version` and `name` are optional. Delete unused fields instead of leaving placeholder values.

## Supported fields

| JSON field | Command-line equivalent | Value |
|---|---|---|
| `language` | `-Language` | `auto` or an ISO language code |
| `whisper_model` | `-WhisperModel` | `turbo` or `medium` |
| `whisper_model_path` | `-WhisperModelPath` | Optional model path; relative paths start from this profile's folder |
| `refine_model` | `-RefineModel` | API model name |
| `glossary_file` | `-GlossaryFile` | File path |
| `terms` | `-Terms` | String or JSON array |
| `whisper_instruction` | Profile-only default | Text; the command-line `-WhisperPrompt` reads a file |
| `refine_instruction` | Profile-only default | Text; the command-line `-RefinePrompt` reads a file |
| `lecture_notes` | `-LectureNotes` | Boolean |
| `lecture_instruction` | Profile-only default | Text; the command-line `-LecturePrompt` reads a file |
| `reference` | `-Reference` | PDF, TXT, MD, or directory of reference files |
| `topic` | `-Topic` | Short subject hint |
| `glossary_renew` | `-GlossaryRenew` | Boolean |
| `output_directory` | `-OutputDirectory` | Directory path |
| `refine_batch_minutes` | `-RefineBatchMinutes` | Integer from 1 to 30 |
| `whisper_threads` | `-WhisperThreads` | Integer from 1 to 128 |
| `whisper_cpu` | `-WhisperCpu` | Boolean |
| `verbose_vad` | `-VerboseVad` | Boolean |
| `skip_refine` | `-SkipRefine` | Boolean |
| `no_sdh` | `-NoSDH` | Boolean |
| `brief` | `-Brief` | Boolean |
| `full_output` | `-FullOutput` | Boolean |

Relative file and directory paths are resolved from the profile's folder. Unknown fields and unsupported profile versions stop with an error instead of being ignored.
