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
$WhisperInstruction='';$RefineInstruction='';$LectureInstruction=''

function Resolve-ProfileFile([string]$NameOrPath){
    if(Test-Path -LiteralPath $NameOrPath -PathType Leaf){return (Resolve-Path -LiteralPath $NameOrPath).Path}
    $candidate=Join-Path (Join-Path $PSScriptRoot 'profiles') ($NameOrPath+'.json')
    if(Test-Path -LiteralPath $candidate -PathType Leaf){return (Resolve-Path -LiteralPath $candidate).Path}
    $available=@(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'profiles') -Filter '*.json' -ErrorAction SilentlyContinue|ForEach-Object{$_.BaseName})
    throw "Profile '$NameOrPath' was not found. Available profiles: $($available -join ', ')."
}
function Get-ProfilePathValue($Value,[string]$ProfilePath){
    if([string]::IsNullOrWhiteSpace([string]$Value)){return [string]$Value}
    if([IO.Path]::IsPathRooted([string]$Value)){return [string]$Value}
    return [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($ProfilePath)) ([string]$Value)))
}
if($Profile){
    $profilePath=Resolve-ProfileFile $Profile
    $profileData=Get-Content -Raw -LiteralPath $profilePath|ConvertFrom-Json
    if([int]$profileData.version -ne 1){throw "Unsupported profile version in $profilePath. Expected version 1."}
    if([string]::IsNullOrWhiteSpace([string]$profileData.name)){throw "Profile name is missing in $profilePath."}
    $knownProfileFields=@('version','name','description','language','whisper_model','whisper_model_path','refine_model','glossary_file','terms','whisper_instruction','refine_instruction','lecture_notes','lecture_instruction','reference','topic','glossary_renew','output_directory','refine_batch_minutes','whisper_threads','whisper_cpu','verbose_vad','skip_refine','no_sdh','brief','full_output')
    $unknown=@($profileData.psobject.Properties.Name|Where-Object{$_ -notin $knownProfileFields})
    if($unknown.Count){throw "Unknown profile field(s) in $profilePath`: $($unknown -join ', ')."}
    $profileMap=[ordered]@{
        language='Language'; whisper_model='WhisperModel'; whisper_model_path='WhisperModelPath'; refine_model='RefineModel'; glossary_file='GlossaryFile'; terms='Terms'
        whisper_instruction='WhisperInstruction'; refine_instruction='RefineInstruction'
        lecture_notes='LectureNotes'; lecture_instruction='LectureInstruction'; reference='Reference'; topic='Topic'; glossary_renew='GlossaryRenew'
        output_directory='OutputDirectory'; refine_batch_minutes='RefineBatchMinutes'; whisper_threads='WhisperThreads'; whisper_cpu='WhisperCpu'
        verbose_vad='VerboseVad'; skip_refine='SkipRefine'; no_sdh='NoSDH'; brief='Brief'; full_output='FullOutput'
    }
    foreach($entry in $profileMap.GetEnumerator()){
        $property=$profileData.psobject.Properties[$entry.Key]
        $overridden=($entry.Key -eq 'whisper_instruction' -and $PSBoundParameters.ContainsKey('WhisperPrompt')) -or ($entry.Key -eq 'refine_instruction' -and $PSBoundParameters.ContainsKey('RefinePrompt')) -or ($entry.Key -eq 'lecture_instruction' -and $PSBoundParameters.ContainsKey('LecturePrompt'))
        if($null -eq $property -or $PSBoundParameters.ContainsKey($entry.Value) -or $overridden){continue}
        $value=$property.Value
        if($entry.Key -in @('whisper_model_path','glossary_file','reference','output_directory')){$value=Get-ProfilePathValue $value $profilePath}
        if($entry.Key -eq 'terms' -and $value -isnot [string]){$value=@($value)-join '; '}
        Set-Variable -Name $entry.Value -Value $value
    }
    Write-Host "Profile loaded: $($profileData.name) ($profilePath)" -ForegroundColor Green
}
$isCourseProfile=($Profile -and ([string]$profileData.name -ieq 'course'))
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
$started=Get-Date
$vadMapPath=Join-Path ([IO.Path]::GetTempPath()) ('transcribe_vad_'+[guid]::NewGuid().ToString('N')+'.json')
$localParams=@{Model=$WhisperModel;OutputDirectory=$outDir;Prompt=$WhisperInstruction;VadMapPath=$vadMapPath;Threads=$WhisperThreads;Cpu=$WhisperCpu;VerboseVad=$VerboseVad}
if($WhisperModelPath){$localParams.ModelPath=$WhisperModelPath}
& (Join-Path $PSScriptRoot 'transcribe_local.ps1') $inputPath $Language @localParams
if($LASTEXITCODE -ne 0){throw "Transcription failed."}
$json=Get-ChildItem -LiteralPath $outDir -Filter (([IO.Path]::GetFileNameWithoutExtension($inputPath))+'_'+$Language+'*.json')|Where-Object LastWriteTime -ge $started|Sort-Object LastWriteTime -Descending|Select-Object -First 1
if(-not $json){throw "New transcription JSON was not found."}
$rawBase=[IO.Path]::Combine($json.DirectoryName,$json.BaseName)
$rawJsonPath=$rawBase+'.raw.json'
$savedVadPath=$rawBase+'.vad.json'
$savedConfigPath=$rawBase+'.config.json'
foreach($ext in @('.txt','.srt','.json')){
    $source=$rawBase+$ext
    $destination=$rawBase+'.raw'+$ext
    if(Test-Path -LiteralPath $source){Move-Item -LiteralPath $source -Destination $destination -Force}
}
if(Test-Path -LiteralPath $vadMapPath){Move-Item -LiteralPath $vadMapPath -Destination $savedVadPath -Force}
$effectiveGlossaryPath=$null
$effectiveTerms=@($asrTerms|Select-Object -Unique)
if(-not $SkipRefine -and ($Reference -or $effectiveTerms.Count)){
    $effectiveGlossaryPath=Join-Path ([IO.Path]::GetTempPath()) ('transcribe_effective_glossary_'+[guid]::NewGuid().ToString('N')+'.txt')
    $glossaryParams=@{GlossaryFile=$effectiveGlossaryPath;TranscriptFile=($rawBase+'.raw.txt');Model=$RefineModel;Topic=$Topic}
    if($Reference){$glossaryParams.Reference=$Reference}
    if($GlossaryFile){$glossaryParams.SeedGlossaryFile=$GlossaryFile}
    if($Terms){$glossaryParams.SeedTerms=$Terms}
    & (Join-Path $PSScriptRoot 'transcribe_glossary.ps1') @glossaryParams
    $effectiveTerms=@(Get-Content -LiteralPath $effectiveGlossaryPath|ForEach-Object{$line=([string]$_).Trim();if($line -and -not $line.StartsWith('#')){$line}})
    Write-Host "Recording-specific glossary ready ($($effectiveTerms.Count) terms)." -ForegroundColor Cyan
    if($GlossaryRenew){
        $persistentGlossary=if($GlossaryFile){[IO.Path]::GetFullPath($GlossaryFile)}else{Join-Path ([IO.Path]::GetDirectoryName($inputPath)) 'glossary.txt'}
        Copy-Item -LiteralPath $effectiveGlossaryPath -Destination $persistentGlossary -Force
        if(-not $GlossaryFile){$GlossaryFile=$persistentGlossary}
        Write-Host "Glossary renewed from recording evidence: $persistentGlossary" -ForegroundColor Green
    }
}
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
Write-Host "Recovery files saved: $rawJsonPath, $savedVadPath, $savedConfigPath"
if($SkipRefine){
    Write-Host 'Refinement skipped.'
    return
}
$refineParams=@{JsonPath=$rawJsonPath;FullOutput=$FullOutput;Topic=$Topic}
if($effectiveGlossaryPath){$refineParams.GlossaryFile=$effectiveGlossaryPath}elseif($GlossaryFile){$refineParams.GlossaryFile=$GlossaryFile}
if($Terms -and -not $effectiveGlossaryPath){$refineParams.Terms=$Terms}
try{& (Join-Path $PSScriptRoot 'transcribe_refine.ps1') @refineParams}
finally{if($effectiveGlossaryPath -and (Test-Path -LiteralPath $effectiveGlossaryPath)){Remove-Item -LiteralPath $effectiveGlossaryPath -Force}}
if(-not $FullOutput){
    foreach($path in @(($rawBase+'.raw.txt'),($rawBase+'.raw.srt'),$rawJsonPath,$savedVadPath,$savedConfigPath)){
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}
    }
}
if($Brief){
    Copy-Item -LiteralPath ($rawBase+'.srt') -Destination $briefTarget -Force
    foreach($ext in @('.srt','.segmented.srt','.segmented.md','.lecture.md','.lecture.review.md')){
        Remove-Item -LiteralPath ($rawBase+$ext) -Force
    }
    if(@(Get-ChildItem -LiteralPath $outDir -Force).Count -eq 0){Remove-Item -LiteralPath $outDir -Force}
    Write-Host "Subtitles: $briefTarget"
}
