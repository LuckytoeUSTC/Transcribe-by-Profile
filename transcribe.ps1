#requires -Version 5.1
<#
.SYNOPSIS
Transcribe locally with Whisper, then refine with the school API.

.EXAMPLE
transcribe.cmd "D:\course\f0.mp4" -Language en -GlossaryFile "D:\course\terms.txt"

.EXAMPLE
transcribe.cmd "D:\course\f0.mp4" -Language en -SkipRefine
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true,Position=0)][string]$InputFile,
    [string]$Profile,
    [Parameter(Position=1)][string]$Language="auto",
    [ValidateSet('turbo','medium')][string]$WhisperModel='turbo',
    [string]$WhisperModelPath,
    [string]$RefineModel='qwen3.8-chat',
    [string]$GlossaryFile,
    [Alias('Glossary')][string]$Terms,
    [string]$WhisperPrompt='',
    [string]$RefinePrompt='',
    [switch]$LectureNotes,
    [string]$LecturePrompt='',
    [string]$Reference,
    [string]$Topic='',
    [switch]$GlossaryRenew,
    [string]$OutputDirectory,
    [ValidateRange(1,30)][int]$RefineBatchMinutes=3,
    [ValidateRange(1,128)][int]$WhisperThreads=8,
    [switch]$WhisperCpu,
    [switch]$VerboseVad,
    [switch]$SkipRefine,
    [switch]$NoSDH,
    [switch]$Brief,
    [switch]$FullOutput
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'transcribe_runtime.psm1') -Force
$runWatch=[Diagnostics.Stopwatch]::StartNew()
$WhisperInstruction='';$RefineInstruction='';$LectureInstruction=''

if($Profile){
    $profileSettings=Get-TranscriptProfile $Profile $PSBoundParameters
    $profilePath=$profileSettings.Path
    foreach($entry in $profileSettings.Values.GetEnumerator()){Set-Variable -Name $entry.Key -Value $entry.Value}
    Write-Host "Profile: $($profileSettings.Name) | Refine: $RefineModel" -ForegroundColor Cyan
    Write-Verbose "Profile file: $profilePath"
}
if($Language -notmatch '^(?i:auto|[a-z]{2,3})$'){throw "Language must be 'auto' or an ISO language code such as en, zh, or ja."}
if($WhisperModel -notin @('turbo','medium')){throw "WhisperModel must be 'turbo' or 'medium'."}
if($RefineBatchMinutes -lt 1 -or $RefineBatchMinutes -gt 30){throw 'RefineBatchMinutes must be between 1 and 30.'}
if($WhisperThreads -lt 1 -or $WhisperThreads -gt 128){throw 'WhisperThreads must be between 1 and 128.'}
$inputPath=(Resolve-Path -LiteralPath $InputFile).Path
if($LectureNotes -and -not $Reference){
    $referencePdfs=@(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($inputPath)) -Filter '*.pdf' -File)
    if($referencePdfs.Count -eq 1){$Reference=$referencePdfs[0].FullName;Write-Host "Reference auto-detected: $Reference" -ForegroundColor Cyan}
}
if($Brief -and ($FullOutput -or $SkipRefine -or $OutputDirectory)){
    throw '-Brief cannot be combined with -FullOutput, -SkipRefine, or -OutputDirectory.'
}
if($Brief){$LectureNotes=$false}
$outDir=if($OutputDirectory){[IO.Path]::GetFullPath($OutputDirectory)}else{Join-Path ([IO.Path]::GetDirectoryName($inputPath)) 'transcripts'}
if($Brief){
    $briefTarget=[IO.Path]::ChangeExtension($inputPath,'.srt')
    $outDir=Join-Path ([IO.Path]::GetTempPath()) ('transcribe_'+[guid]::NewGuid().ToString('N'))
}
if($GlossaryRenew -and -not $Reference){throw '-GlossaryRenew requires -Reference.'}
$glossarySource='specified'
if(-not $GlossaryFile){
    $defaultGlossary=Join-Path ([IO.Path]::GetDirectoryName($inputPath)) 'glossary.txt'
    if(Test-Path -LiteralPath $defaultGlossary -PathType Leaf){$GlossaryFile=$defaultGlossary; $glossarySource='auto-detected'}
}
if($WhisperPrompt){
    $WhisperInstruction=Get-Content -Raw -LiteralPath (Resolve-Path -LiteralPath $WhisperPrompt -ErrorAction Stop)
}
if($PSBoundParameters.ContainsKey('RefinePrompt')){
    $RefineInstruction=Get-Content -Raw -LiteralPath (Resolve-Path -LiteralPath $RefinePrompt -ErrorAction Stop)
}
if($LecturePrompt){
    $LectureInstruction=Get-Content -Raw -LiteralPath (Resolve-Path -LiteralPath $LecturePrompt -ErrorAction Stop)
}
$asrTerms=@()
if($GlossaryFile){
    $resolvedGlossary=(Resolve-Path -LiteralPath $GlossaryFile -ErrorAction Stop).Path
    $asrTerms += @(Get-Content -LiteralPath $resolvedGlossary | ForEach-Object {$line=([string]$_).Trim();if($line -and -not $line.StartsWith('#')){$line}})
    Write-Host "Glossary loaded ($glossarySource, $($asrTerms.Count) terms): $resolvedGlossary" -ForegroundColor Cyan
}
if($Terms){$asrTerms += @($Terms -split ';' | ForEach-Object {$_.Trim()} | Where-Object {$_})}
if($asrTerms.Count){
    $selectedTerms=@(); $usedLength=0
    foreach($term in @($asrTerms|Select-Object -Unique)){
        if(($usedLength+$term.Length+2) -gt 1200){break}
        $selectedTerms += $term; $usedLength += $term.Length+2
    }
    $termPrompt='Relevant names and terms: '+($selectedTerms -join ', ')+'.'
    if($selectedTerms.Count -lt @($asrTerms|Select-Object -Unique).Count){Write-Warning 'The glossary is long; only the first terms were added to the Whisper prompt. Terms will be reordered against the rough transcript before refinement.'}
    $WhisperInstruction=($WhisperInstruction.Trim()+' '+$termPrompt).Trim()
}
$name=([IO.Path]::GetFileNameWithoutExtension($inputPath))+'_'+$Language.ToLowerInvariant()
$rawBase=Join-Path $outDir $name
$layout=Get-TranscriptLayout $rawBase
if((Test-Path -LiteralPath $layout.Work) -or (Test-Path -LiteralPath ($rawBase+'.srt')) -or (Test-Path -LiteralPath ($rawBase+'.segmented.md'))){
    $rawBase=Join-Path $outDir ($name+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,6))
    $layout=Get-TranscriptLayout $rawBase
}
[void][IO.Directory]::CreateDirectory($layout.Work)
$rawJsonPath=$layout.RawJson;$savedVadPath=$layout.Vad;$savedConfigPath=$layout.Config
$localParams=@{Model=$WhisperModel;OutputDirectory=$layout.Work;OutputPrefix=(Join-Path $layout.Work 'raw');Prompt=$WhisperInstruction;VadMapPath=$savedVadPath;Threads=$WhisperThreads;Cpu=$WhisperCpu;VerboseVad=$VerboseVad;Verbose=($VerbosePreference -eq 'Continue')}
if($WhisperModelPath){$localParams.ModelPath=$WhisperModelPath}
& (Join-Path $PSScriptRoot 'transcribe_local.ps1') $inputPath $Language @localParams
if(-not(Test-Path -LiteralPath $rawJsonPath)){throw 'Whisper JSON was not found.'}
$effectiveTerms=@($asrTerms|Select-Object -Unique)
$refineSettings=[ordered]@{
    version=1
    profile=if($Profile){[IO.Path]::GetFileNameWithoutExtension($profilePath)}else{$null}
    source_file=$inputPath
    language=$Language
    refine_model=$RefineModel
    refine_batch_minutes=$RefineBatchMinutes
    no_sdh=[bool]$NoSDH
    terms=@($effectiveTerms|Select-Object -Unique)
    refine_instruction=$RefineInstruction
    lecture_notes=[bool]$LectureNotes
    lecture_instruction=$LectureInstruction
    reference=$Reference
    topic=$Topic
}
$refineSettings|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $savedConfigPath -Encoding utf8
Write-Host "Recovery files: $($layout.Work)" -ForegroundColor Cyan
if($SkipRefine){
    Write-Host 'Whisper completed; refinement skipped. Recovery files retained.' -ForegroundColor Green
    return
}
$effectiveGlossaryPath=$null
if($Reference -or $effectiveTerms.Count){
    $effectiveGlossaryPath=Join-Path $layout.Work 'glossary.txt'
    $glossaryParams=@{GlossaryFile=$effectiveGlossaryPath;TranscriptFile=$rawJsonPath;Model=$RefineModel;Topic=$Topic}
    if($Reference){$glossaryParams.Reference=$Reference}
    if($GlossaryFile){$glossaryParams.SeedGlossaryFile=$GlossaryFile}
    if($Terms){$glossaryParams.SeedTerms=$Terms}
    & (Join-Path $PSScriptRoot 'transcribe_glossary.ps1') @glossaryParams
    $effectiveTerms=@(Get-Content -LiteralPath $effectiveGlossaryPath|ForEach-Object{$line=([string]$_).Trim();if($line -and -not $line.StartsWith('#')){$line}})
    $refineSettings.terms=$effectiveTerms
    $refineSettings|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $savedConfigPath -Encoding utf8
    Write-Host "Glossary ready: $($effectiveTerms.Count) terms" -ForegroundColor Green
    if($GlossaryRenew){
        $persistentGlossary=if($GlossaryFile){[IO.Path]::GetFullPath($GlossaryFile)}else{Join-Path ([IO.Path]::GetDirectoryName($inputPath)) 'glossary.txt'}
        Copy-Item -LiteralPath $effectiveGlossaryPath -Destination $persistentGlossary -Force
        Write-Host "Glossary renewed: $persistentGlossary" -ForegroundColor Green
    }
}
$resultState=@{}
$refineParams=@{JsonPath=$rawJsonPath;FullOutput=$FullOutput;Topic=$Topic;QuietSummary=$true;ResultState=$resultState;Verbose=($VerbosePreference -eq 'Continue')}
if($effectiveGlossaryPath){$refineParams.GlossaryFile=$effectiveGlossaryPath}
& (Join-Path $PSScriptRoot 'transcribe_refine.ps1') @refineParams
if($Brief){
    Copy-Item -LiteralPath ($rawBase+'.srt') -Destination $briefTarget -Force
    foreach($ext in @('.srt','.segmented.srt','.segmented.md','.lecture.md')){
        if(Test-Path -LiteralPath ($rawBase+$ext)){Remove-Item -LiteralPath ($rawBase+$ext) -Force}
    }
    if(@(Get-ChildItem -LiteralPath $outDir -Force).Count -eq 0){Remove-Item -LiteralPath $outDir -Force}
    Write-Host "Subtitles: $briefTarget"
}else{
    Write-Host "Sentence subtitles: $rawBase.srt"
    Write-Host "Segmented subtitles: $rawBase.segmented.srt"
    Write-Host "Segmented transcript: $rawBase.segmented.md"
}
$hadWarnings=[bool]$resultState.warnings
Write-Host ("Completed{0} | elapsed {1}" -f $(if($hadWarnings){' with warnings'}else{''}),(Format-TranscriptDuration $runWatch.Elapsed.TotalSeconds)) -ForegroundColor $(if($hadWarnings){'Yellow'}else{'Green'})
