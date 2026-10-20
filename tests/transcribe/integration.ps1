param([int]$Port)
$projectRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('transcribe-integration-'+[guid]::NewGuid().ToString('N'))
$scripts=Join-Path $root 'scripts'
[void][IO.Directory]::CreateDirectory($scripts)
foreach($name in @('transcribe.ps1','transcribe_refine.ps1','transcribe_glossary.ps1','transcribe_lecture.ps1','transcribe_reference.psm1','transcribe_runtime.psm1','transcribe_quality.psm1','transcribe_workers.psm1','transcribe_config.psm1','transcribe_audio.psm1','profiles')){Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $scripts $name) -Recurse}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fake_local.ps1') -Destination (Join-Path $scripts 'transcribe_local.ps1')
$env:APPDATA=Join-Path $root 'appdata'
[void][IO.Directory]::CreateDirectory((Join-Path $env:APPDATA 'Subtitle Edit'))
function Set-TestEndpoint([string]$Path){
    $env:TRANSCRIBE_API_URL="http://127.0.0.1:$Port/$Path"
    $env:TRANSCRIBE_API_KEY='mock-test-key'
    @{AutoTranslate=@{OpenAiCompatibleUrl="http://127.0.0.1:$Port/$Path";OpenAiCompatibleApiKey='mock-test-key'}}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $env:APPDATA 'Subtitle Edit\Settings.json')
}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERTION FAILED: $Message"}}
Set-TestEndpoint 'normal'
$media=Join-Path $root 'lecture.wav';[IO.File]::WriteAllBytes($media,[byte[]]@(0,0))
& (Join-Path $scripts 'transcribe.ps1') $media -Profile course -Terms 'fixed point' -FullOutput
$base=Join-Path $root 'transcripts\lecture_auto';$work=Join-Path $root 'transcripts\.work\lecture_auto'
foreach($name in @('raw.json','raw.srt','vad.json','config.json','refined.json','glossary.txt')){Assert (Test-Path -LiteralPath (Join-Path $work $name)) "FullOutput $name"}
foreach($ext in @('.srt','.segmented.srt','.segmented.md','.lecture.md')){Assert (Test-Path -LiteralPath ($base+$ext)) "Product $ext"}
Assert (-not(Test-Path -LiteralPath (Join-Path $work 'raw.txt'))) 'No raw.txt'
Assert (-not(Test-Path -LiteralPath (Join-Path $work 'lecture.review.md'))) 'No empty review'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'transcripts') -File).Count -eq 4) 'Only products outside .work'
Write-Host 'PASS full pipeline, glossary from JSON, lecture, layout and no raw.txt'

& (Join-Path $scripts 'transcribe_refine.ps1') $base -FullOutput
Write-Host 'PASS prefix-based standalone recovery'

Set-TestEndpoint 'review'
& (Join-Path $scripts 'transcribe_lecture.ps1') -SegmentedPath ($base+'.segmented.md') -Outline 'Test outline'
Assert (Test-Path -LiteralPath (Join-Path $work 'lecture.review.md')) 'Review inside work'
Write-Host 'PASS lecture review location'

Set-TestEndpoint 'normal'
& (Join-Path $scripts 'transcribe.ps1') $media -SkipRefine
Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'transcripts\.work') -Directory).Count -eq 2) 'No name collision'
Write-Host 'PASS SkipRefine and collision protection'

$briefMedia=Join-Path $root 'brief.wav';[IO.File]::WriteAllBytes($briefMedia,[byte[]]@(0))
& (Join-Path $scripts 'transcribe.ps1') $briefMedia -Brief
Assert (Test-Path -LiteralPath (Join-Path $root 'brief.srt')) 'Brief output beside media'
Write-Host 'PASS brief'

$cleanMedia=Join-Path $root 'clean.wav';[IO.File]::WriteAllBytes($cleanMedia,[byte[]]@(0))
& (Join-Path $scripts 'transcribe.ps1') $cleanMedia
Assert (-not(Test-Path -LiteralPath (Join-Path $root 'transcripts\.work\clean_auto'))) 'Clean run cleanup'
Write-Host 'PASS default cleanup'

foreach($profile in @('interview','podcast')){
    $profileMedia=Join-Path $root ($profile+'.wav');[IO.File]::WriteAllBytes($profileMedia,[byte[]]@(0))
    & (Join-Path $scripts 'transcribe.ps1') $profileMedia -Profile $profile -FullOutput
    $profileBase=Join-Path $root ('transcripts\'+$profile+'_auto')
    foreach($ext in @('.srt','.segmented.srt','.segmented.md')){Assert (Test-Path -LiteralPath ($profileBase+$ext)) "$profile product $ext"}
    Assert (-not(Test-Path -LiteralPath ($profileBase+'.lecture.md'))) "$profile has no unsolicited lecture"
    $profileWork=Join-Path $root ('transcripts\.work\'+$profile+'_auto')
    Assert (Test-Path -LiteralPath (Join-Path $profileWork 'raw.json')) "$profile work layout"
    Assert (-not(Test-Path -LiteralPath (Join-Path $profileWork 'raw.txt'))) "$profile has no raw.txt"
    Write-Host "PASS $profile shared output, progress and working-file pipeline"
}

Import-Module (Join-Path $scripts 'transcribe_runtime.psm1') -Force
$options=Get-TranscriptProfile 'course' @{RefineModel='explicit';FullOutput=$true}
Assert (-not $options.Values.ContainsKey('RefineModel')) 'Explicit model beats profile'
Assert (-not $options.Values.ContainsKey('FullOutput')) 'Explicit FullOutput beats profile'
$saved=[pscustomobject]@{refine_model='saved';lecture_notes=$false;terms=@('A','B')}
$values=Get-TranscriptSettingValues $saved @{RefineModel=$true} @('RefineModel','LectureNotes','Terms')
Assert (-not $values.ContainsKey('RefineModel')) 'Saved settings respect override'
Assert ($values.Terms -eq 'A; B') 'Saved glossary list conversion'
Assert ($values.LectureNotes -eq $false) 'Explicit false saved settings preserved'
Write-Host 'PASS shared profile/settings precedence'

$legacyBase=Join-Path $root 'transcripts\legacy_auto'
Copy-Item -LiteralPath (Join-Path $work 'raw.json') -Destination ($legacyBase+'.raw.json')
Copy-Item -LiteralPath (Join-Path $work 'raw.srt') -Destination ($legacyBase+'.raw.srt')
Copy-Item -LiteralPath (Join-Path $work 'vad.json') -Destination ($legacyBase+'.vad.json')
& (Join-Path $scripts 'transcribe_refine.ps1') ($legacyBase+'.raw.json') -FullOutput
Assert (Test-Path -LiteralPath (Join-Path $root 'transcripts\.work\legacy_auto\raw.json')) 'Legacy migration'
Assert (Test-Path -LiteralPath ($legacyBase+'.segmented.md')) 'Legacy product naming'
Write-Host 'PASS legacy recovery and naming'

Set-TestEndpoint 'fail-glossary'
$failMedia=Join-Path $root 'failure.wav';[IO.File]::WriteAllBytes($failMedia,[byte[]]@(0))
$failed=$false
try{& (Join-Path $scripts 'transcribe.ps1') $failMedia -Terms 'fixed point'}catch{$failed=$true}
Assert $failed 'Intentional glossary failure'
Assert (Test-Path -LiteralPath (Join-Path $root 'transcripts\.work\failure_auto\config.json')) 'Config retained before glossary API'
Write-Host 'PASS recovery configuration on glossary failure'

Set-TestEndpoint 'truncate'
& (Join-Path $scripts 'transcribe_refine.ps1') $base -FullOutput
Assert (@(Get-ChildItem -LiteralPath (Join-Path $work 'api-diagnostics') -Filter '*.json').Count -gt 0) 'Failure diagnostics'
Write-Host 'PASS truncation fallback and diagnostics'
Write-Host "All integration checks passed: $root"
