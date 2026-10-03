#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputFile,

    [Parameter(Position = 1)]
    [string]$Language = "auto",

    [ValidateSet("turbo", "medium")]
    [string]$Model = "turbo",

    [string]$ModelPath,
    [string]$WhisperCliPath,
    [string]$FfmpegPath,
    [string]$VadModelPath,
    [string]$OutputDirectory,
    [string]$Prompt = "",
    [string]$VadMapPath,
    [int]$Threads = 8,
    [switch]$TranslateToEnglish,
    [switch]$Cpu,
    [switch]$VerboseVad
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot 'transcribe_config.psm1') -Force

$ProjectConfig = Get-TranscribeProjectConfig
$WhisperCli = Find-TranscribeFile @($WhisperCliPath,$env:TRANSCRIBE_WHISPER_CLI,(Get-TranscribeConfigValue $ProjectConfig 'whisper_cli'),'tools\whisper-cli.exe',"$env:ProgramFiles\Buzz\_internal\buzz\whisper_cpp\whisper-cli.exe","${env:ProgramFiles(x86)}\Buzz\_internal\buzz\whisper_cpp\whisper-cli.exe") $ProjectConfig
$Ffmpeg = Find-TranscribeFile @($FfmpegPath,$env:TRANSCRIBE_FFMPEG,(Get-TranscribeConfigValue $ProjectConfig 'ffmpeg'),'tools\ffmpeg.exe',"$env:ProgramFiles\Buzz\_internal\ffmpeg.exe","${env:ProgramFiles(x86)}\Buzz\_internal\ffmpeg.exe") $ProjectConfig
$VadModel = Find-TranscribeFile @($VadModelPath,$env:TRANSCRIBE_VAD_MODEL,(Get-TranscribeConfigValue $ProjectConfig 'vad_model'),'models\ggml-silero-v6.2.0.bin') $ProjectConfig
$KnownModels = @{
    turbo  = Find-TranscribeFile @($env:TRANSCRIBE_MODEL_TURBO,(Get-TranscribeConfigValue $ProjectConfig 'models.turbo'),'models\ggml-large-v3-turbo-q5_0.bin') $ProjectConfig
    medium = Find-TranscribeFile @($env:TRANSCRIBE_MODEL_MEDIUM,(Get-TranscribeConfigValue $ProjectConfig 'models.medium'),'models\ggml-medium.bin') $ProjectConfig
}

function Resolve-FullPath([string]$PathText) {
    return (Resolve-Path -LiteralPath $PathText -ErrorAction Stop).Path
}

if (-not $WhisperCli) {
    throw 'Whisper CLI was not found. Install Buzz, configure whisper_cli, place it in tools, or set TRANSCRIBE_WHISPER_CLI.'
}
if (-not $VadModel) {
    throw 'The Silero VAD model was not found. Configure vad_model, place it in models, or set TRANSCRIBE_VAD_MODEL.'
}

$InputPath = Resolve-FullPath $InputFile
if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "Input file does not exist: $InputPath"
}

$LanguageKey = $Language.Trim().ToLowerInvariant()
if ($LanguageKey -notmatch '^(auto|[a-z]{2,3})$') {
    throw "Language must be 'auto' or an ISO language code such as en, zh, or ja."
}

if ([string]::IsNullOrWhiteSpace($ModelPath)) {
    $SelectedModel = $KnownModels[$Model]
} else {
    $SelectedModel = Resolve-FullPath $ModelPath
}
if (-not $SelectedModel -or -not (Test-Path -LiteralPath $SelectedModel -PathType Leaf)) {
    throw "Whisper model '$Model' was not found. Configure models.$Model, place it in models, use -ModelPath, or set the corresponding environment variable."
}

$InputItem = Get-Item -LiteralPath $InputPath
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $InputItem.DirectoryName "transcripts"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

$OutputBaseName = "{0}_{1}" -f $InputItem.BaseName, $LanguageKey
$OutputPrefix = Join-Path $OutputDirectory $OutputBaseName
if ((Test-Path -LiteralPath ($OutputPrefix + ".txt")) -or
    (Test-Path -LiteralPath ($OutputPrefix + ".srt"))) {
    $Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputPrefix = Join-Path $OutputDirectory ("{0}_{1}" -f $OutputBaseName, $Stamp)
}

$AudioForWhisper = $InputPath
$TemporaryWav = $null
$DirectFormats = @(".mp3", ".wav", ".flac", ".ogg")
$VadMappings = [Collections.Generic.List[object]]::new()
$VadSpeechSegments = [Collections.Generic.List[object]]::new()

try {
    if ($DirectFormats -notcontains $InputItem.Extension.ToLowerInvariant()) {
        if (-not $Ffmpeg) {
            throw 'This input requires FFmpeg. Install Buzz, configure ffmpeg, place it in tools, or set TRANSCRIBE_FFMPEG.'
        }
        $TemporaryWav = Join-Path ([IO.Path]::GetTempPath()) ("whisper_" + [guid]::NewGuid().ToString("N") + ".wav")
        Write-Host "Converting the audio to a temporary WAV file..."
        & $Ffmpeg -hide_banner -loglevel error -y -i $InputPath -ar 16000 -ac 1 -c:a pcm_s16le $TemporaryWav
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $TemporaryWav -PathType Leaf)) {
            throw "Audio conversion failed."
        }
        $AudioForWhisper = $TemporaryWav
    }

    $Arguments = @(
        "-m", $SelectedModel,
        "-f", $AudioForWhisper,
        "-l", $LanguageKey,
        "-t", [Math]::Max(1, $Threads).ToString(),
        "-otxt", "-osrt", "-ojf", "-fa",
        "--vad",
        "-vm", $VadModel,
        "-vt", "0.50",
        "-vspd", "250",
        "-vsd", "500",
        "-vmsd", "30",
        "-vp", "200",
        "-vo", "0.10",
        "-mc", "0",
        "-of", $OutputPrefix
    )
    if ($TranslateToEnglish) { $Arguments += "-tr" }
    if ($Cpu) { $Arguments += "-ng" }
    if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
        $Arguments += @("--prompt", $Prompt)
    }

    Write-Host "Model: $SelectedModel"
    Write-Host "VAD: $VadModel"
    Write-Host "Language: $LanguageKey"
    Write-Host "Transcribing: $InputPath"
    & $WhisperCli @Arguments 2>&1 | ForEach-Object {
        $line = $_.ToString()
        if ($line -match '^whisper_vad: vad_segment_info: orig_start: ([0-9.]+), orig_end: ([0-9.]+), vad_start: ([0-9.]+), vad_end: ([0-9.]+)') {
            $VadMappings.Add([pscustomobject]@{
                orig_start_ms = [int64]([double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) * 1000)
                orig_end_ms   = [int64]([double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture) * 1000)
                vad_start_ms  = [int64]([double]::Parse($Matches[3], [Globalization.CultureInfo]::InvariantCulture) * 1000)
                vad_end_ms    = [int64]([double]::Parse($Matches[4], [Globalization.CultureInfo]::InvariantCulture) * 1000)
            })
        } elseif ($line -match '^whisper_vad_segments_from_probs: VAD segment \d+: start = ([0-9.]+), end = ([0-9.]+)') {
            $VadSpeechSegments.Add([pscustomobject]@{
                start_ms = [int64]([double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) * 1000)
                end_ms   = [int64]([double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture) * 1000)
            })
        }
        $isVadDetail = $line -match '^(?:whisper_vad_segments_from_probs: VAD segment \d+:|whisper_vad: Including segment \d+:|whisper_vad: vad_segment_info:)'
        if ($VerboseVad -or -not $isVadDetail) { Write-Host $line }
    }
    $whisperExitCode = $LASTEXITCODE
    if ($whisperExitCode -ne 0) {
        throw "Whisper transcription failed with exit code $whisperExitCode."
    }
    if (-not [string]::IsNullOrWhiteSpace($VadMapPath)) {
        @{
            mappings = @($VadMappings)
            speech_segments = @($VadSpeechSegments)
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $VadMapPath -Encoding utf8
    }

    $TxtPath = $OutputPrefix + ".txt"
    $SrtPath = $OutputPrefix + ".srt"
    $JsonPath = $OutputPrefix + ".json"
    foreach ($ResultPath in @($TxtPath, $SrtPath, $JsonPath)) {
        if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf) -or
            (Get-Item -LiteralPath $ResultPath).Length -eq 0) {
            throw "Transcription finished, but an output file is missing or empty: $ResultPath"
        }
    }

    Write-Host ""
    Write-Host "Transcription completed."
    Write-Host "TXT: $TxtPath"
    Write-Host "SRT: $SrtPath"
    Write-Host "JSON: $JsonPath"
}
finally {
    if ($null -ne $TemporaryWav -and (Test-Path -LiteralPath $TemporaryWav -PathType Leaf)) {
        Remove-Item -LiteralPath $TemporaryWav -Force
    }
}
