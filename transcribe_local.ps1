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
    [string]$FfprobePath,
    [string]$VadModelPath,
    [string]$OutputDirectory,
    [Parameter(DontShow=$true)][string]$OutputPrefix,
    [string]$Prompt = "",
    [string]$VadMapPath,
    [int]$Threads = 8,
    [switch]$TranslateToEnglish,
    [switch]$Cpu,
    [switch]$VerboseVad
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot 'transcribe_audio.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'transcribe_config.psm1') -Force

$ProjectConfig=Get-TranscribeProjectConfig
$WhisperCli=Find-TranscribeFile @($WhisperCliPath,$env:TRANSCRIBE_WHISPER_CLI,(Get-TranscribeConfigValue $ProjectConfig 'whisper_cli'),'tools\whisper-cli.exe',"$env:ProgramFiles\Buzz\_internal\buzz\whisper_cpp\whisper-cli.exe","${env:ProgramFiles(x86)}\Buzz\_internal\buzz\whisper_cpp\whisper-cli.exe") $ProjectConfig
$Ffmpeg=Find-TranscribeFile @($FfmpegPath,$env:TRANSCRIBE_FFMPEG,(Get-TranscribeConfigValue $ProjectConfig 'ffmpeg'),'tools\ffmpeg.exe',"$env:ProgramFiles\Buzz\_internal\ffmpeg.exe","${env:ProgramFiles(x86)}\Buzz\_internal\ffmpeg.exe") $ProjectConfig
$ffprobeSibling=if($Ffmpeg){Join-Path ([IO.Path]::GetDirectoryName($Ffmpeg)) 'ffprobe.exe'}else{''}
$Ffprobe=Find-TranscribeFile @($FfprobePath,$env:TRANSCRIBE_FFPROBE,(Get-TranscribeConfigValue $ProjectConfig 'ffprobe'),$ffprobeSibling,'tools\ffprobe.exe') $ProjectConfig
$VadModel=Find-TranscribeFile @($VadModelPath,$env:TRANSCRIBE_VAD_MODEL,(Get-TranscribeConfigValue $ProjectConfig 'vad_model'),'models\ggml-silero-v6.2.0.bin') $ProjectConfig
$KnownModels = @{
    turbo=Find-TranscribeFile @($env:TRANSCRIBE_MODEL_TURBO,(Get-TranscribeConfigValue $ProjectConfig 'models.turbo'),'models\ggml-large-v3-turbo-q5_0.bin') $ProjectConfig
    medium=Find-TranscribeFile @($env:TRANSCRIBE_MODEL_MEDIUM,(Get-TranscribeConfigValue $ProjectConfig 'models.medium'),'models\ggml-medium.bin') $ProjectConfig
}

function Resolve-FullPath([string]$PathText) {
    return (Resolve-Path -LiteralPath $PathText -ErrorAction Stop).Path
}

if (-not $WhisperCli) {
    throw 'Whisper CLI was not found. Configure whisper_cli or TRANSCRIBE_WHISPER_CLI, or install Buzz.'
}
if (-not $VadModel) {
    throw 'VAD model was not found. Configure vad_model or TRANSCRIBE_VAD_MODEL.'
}
if(-not $Ffmpeg -or -not $Ffprobe){throw 'FFmpeg and FFprobe are required for all inputs. Configure ffmpeg/ffprobe paths or the matching TRANSCRIBE environment variables.'}

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
    throw "Whisper model '$Model' was not found. Configure models.$Model, use -WhisperModelPath, or set TRANSCRIBE_MODEL_$($Model.ToUpperInvariant())."
}

$InputItem = Get-Item -LiteralPath $InputPath
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $InputItem.DirectoryName "transcripts"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

$OutputBaseName = "{0}_{1}" -f $InputItem.BaseName, $LanguageKey
$explicitPrefix=-not [string]::IsNullOrWhiteSpace($OutputPrefix)
if(-not $explicitPrefix){$OutputPrefix = Join-Path $OutputDirectory $OutputBaseName}
if (-not $explicitPrefix -and ((Test-Path -LiteralPath ($OutputPrefix + ".json")) -or
    (Test-Path -LiteralPath ($OutputPrefix + ".srt")))) {
    $Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputPrefix = Join-Path $OutputDirectory ("{0}_{1}" -f $OutputBaseName, $Stamp)
}

$TemporaryWav = $null
$VadMappings = [Collections.Generic.List[object]]::new()
$VadSpeechSegments = [Collections.Generic.List[object]]::new()

try {
    $TemporaryWav = Join-Path ([IO.Path]::GetTempPath()) ("whisper_" + [guid]::NewGuid().ToString("N") + ".wav")
    $audio=Convert-TranscriptAudio -InputPath $InputPath -OutputPath $TemporaryWav -FfmpegPath $Ffmpeg -FfprobePath $Ffprobe
    $AudioForWhisper=$audio.Path

    $Arguments = @(
        "-m", $SelectedModel,
        "-f", $AudioForWhisper,
        "-l", $LanguageKey,
        "-t", [Math]::Max(1, $Threads).ToString(),
        "-osrt", "-ojf", "-fa",
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

    Write-Host "Whisper: $Model | threads: $Threads | CPU only: $([bool]$Cpu)" -ForegroundColor Cyan
    Write-Verbose "Model: $SelectedModel"
    Write-Verbose "VAD: $VadModel"
    Write-Host "Language: $LanguageKey"
    Write-Host "Transcribing: $InputPath"
    $whisperWatch=[Diagnostics.Stopwatch]::StartNew()
    & $WhisperCli @Arguments 2>&1 | ForEach-Object {
        $line = $_.ToString()
        if([string]::IsNullOrWhiteSpace($line) -or $line -eq 'System.Management.Automation.RemoteException'){return}
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
        if($isVadDetail){if($VerboseVad){Write-Host $line};return}
        $isSummary=$line -match '^\[\d{2}:|^whisper_vad: (detected |total duration |Reduced audio )|^whisper_full_with_state: auto-detected language:|^ggml_vulkan: \d+ =|^whisper_backend_init_gpu: using '
        $isProblem=$line -match '(?i)\b(error|failed|failure|warning|cannot|could not)\b'
        if($isSummary){Write-Host $line}elseif($isProblem){Write-Warning $line}else{Write-Verbose $line}
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

    $SrtPath = $OutputPrefix + ".srt"
    $JsonPath = $OutputPrefix + ".json"
    foreach ($ResultPath in @($SrtPath, $JsonPath)) {
        if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf) -or
            (Get-Item -LiteralPath $ResultPath).Length -eq 0) {
            throw "Transcription finished, but an output file is missing or empty: $ResultPath"
        }
    }

    $whisperWatch.Stop()
    Write-Host ("Whisper completed: {0:mm\:ss}" -f $whisperWatch.Elapsed) -ForegroundColor Green
    if(-not $explicitPrefix){Write-Host "SRT: $SrtPath";Write-Host "JSON: $JsonPath"}
}
finally {
    if ($null -ne $TemporaryWav -and (Test-Path -LiteralPath $TemporaryWav -PathType Leaf)) {
        Remove-Item -LiteralPath $TemporaryWav -Force
    }
}
