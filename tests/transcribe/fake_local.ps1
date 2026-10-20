[CmdletBinding()]
param($InputFile,$Language,$Model,$OutputDirectory,$OutputPrefix,$Prompt,$VadMapPath,$Threads,[switch]$Cpu,[switch]$VerboseVad)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$rows=@(0..9|ForEach-Object{@{text="This technical sentence describes fixed point number $_.";offsets=@{from=($_*200000);to=($_*200000+3000)};tokens=@()}})
@{transcription=$rows}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath ($OutputPrefix+'.json')
'1'|Set-Content -LiteralPath ($OutputPrefix+'.srt')
@{mappings=@();speech_segments=@()}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $VadMapPath
Write-Host 'Whisper completed (test double).'
