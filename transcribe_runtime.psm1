Import-Module (Join-Path $PSScriptRoot 'transcribe_config.psm1') -Force

function New-TranscriptProgress {
    $interactive=$false
    try{$interactive=$Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected}catch{}
    return @{interactive=$interactive;width=0;headerRow=-1;last='';lastLogged=[datetime]::MinValue}
}
function Clear-TranscriptProgress($State) {
    # Leave the final header and completed-batch lines in terminal history.
    $State.headerRow=-1;$State.width=0
}
function Write-TranscriptProgress($State,[string]$Message,[switch]$Force) {
    if($State.interactive){
        try{
            $width=[math]::Max(1,[Console]::WindowWidth-1)
            $display=if($Message.Length -gt $width){$Message.Substring(0,$width)}else{$Message}
            if($State.headerRow -lt [Console]::WindowTop -or $State.headerRow -ge [Console]::BufferHeight -or $State.headerRow -lt 0){
                # Re-anchor when earlier output scrolls out of the viewport.
                Write-Host $display -ForegroundColor Cyan
                $State.headerRow=[Console]::CursorTop-1
            }else{
                $left=[Console]::CursorLeft;$top=[Console]::CursorTop
                [Console]::SetCursorPosition(0,$State.headerRow)
                Write-Host $display.PadRight($width) -NoNewline -ForegroundColor Cyan
                [Console]::SetCursorPosition($left,$top)
            }
            $State.width=$display.Length
        }catch{
            $State.interactive=$false
            Write-Host $Message;$State.lastLogged=Get-Date
        }
    }elseif($Force -or ($Message -ne $State.last -and ((Get-Date)-$State.lastLogged).TotalSeconds -ge 15)){
        Write-Host $Message;$State.lastLogged=Get-Date
    }
    $State.last=$Message
}
function Write-TranscriptStatus($State,[string]$Message,[ConsoleColor]$Color='Gray') {
    Write-Host $Message -ForegroundColor $Color
    if($State.interactive -and $State.last){Write-TranscriptProgress $State $State.last}
}
function Format-TranscriptDuration([double]$Seconds) {
    $span=[TimeSpan]::FromSeconds([math]::Max(0,$Seconds))
    return '{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($span.TotalHours),$span.Minutes,$span.Seconds
}
function Get-TranscriptLayout([string]$InputPath) {
    $path=[IO.Path]::GetFullPath($InputPath)
    if(Test-Path -LiteralPath $path -PathType Container){$path=Join-Path $path 'raw.json'}
    if([IO.Path]::GetFileName($path) -eq 'raw.json' -and [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($path))) -eq '.work'){
        $work=[IO.Path]::GetDirectoryName($path)
        $root=[IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($work))
        $base=Join-Path $root ([IO.Path]::GetFileName($work))
    }else{
        $base=$path -replace '\.raw\.json$|\.json$',''
        $work=Join-Path (Join-Path ([IO.Path]::GetDirectoryName($base)) '.work') ([IO.Path]::GetFileName($base))
    }
    return [pscustomobject]@{Base=$base;Work=$work;RawJson=(Join-Path $work 'raw.json');RawSrt=(Join-Path $work 'raw.srt');Config=(Join-Path $work 'config.json');Vad=(Join-Path $work 'vad.json');Review=(Join-Path $work 'lecture.review.md');Diagnostics=(Join-Path $work 'api-diagnostics')}
}
function Initialize-TranscriptWork([string]$InputPath) {
    $layout=Get-TranscriptLayout $InputPath
    [void][IO.Directory]::CreateDirectory($layout.Work)
    $source=[IO.Path]::GetFullPath($InputPath)
    if($source -ne $layout.RawJson -and (Test-Path -LiteralPath $source -PathType Leaf)){
        $moves=@(@{from=$source;to=$layout.RawJson},@{from=($layout.Base+'.raw.srt');to=$layout.RawSrt},@{from=($layout.Base+'.config.json');to=$layout.Config},@{from=($layout.Base+'.vad.json');to=$layout.Vad},@{from=($layout.Base+'.refined.json');to=(Join-Path $layout.Work 'refined.json')},@{from=($layout.Base+'.lecture.review.md');to=$layout.Review})
        foreach($move in $moves){if((Test-Path -LiteralPath $move.from) -and (Test-Path -LiteralPath $move.to)){throw "Recovery destination already exists: $($move.to). Use its raw.json to resume."}}
        foreach($move in $moves){if(Test-Path -LiteralPath $move.from){Move-Item -LiteralPath $move.from -Destination $move.to}}
    }
    return $layout
}
function Remove-TranscriptRecovery($Layout) {
    # Delete only known recovery files after a successful run; retain reviews/logs.
    foreach($name in @('raw.json','raw.srt','config.json','vad.json','refined.json','glossary.txt','loops.json')){
        $path=Join-Path $Layout.Work $name
        if(Test-Path -LiteralPath $path -PathType Leaf){Remove-Item -LiteralPath $path -Force}
    }
    if((Test-Path -LiteralPath $Layout.Work) -and @(Get-ChildItem -LiteralPath $Layout.Work -Force).Count -eq 0){Remove-Item -LiteralPath $Layout.Work}
    $parent=[IO.Path]::GetDirectoryName($Layout.Work)
    if((Test-Path -LiteralPath $parent) -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0){Remove-Item -LiteralPath $parent}
}
function Get-TranscriptSettingMap {
    return [ordered]@{
        language='Language';whisper_model='WhisperModel';whisper_model_path='WhisperModelPath';refine_model='RefineModel';glossary_file='GlossaryFile';terms='Terms'
        whisper_instruction='WhisperInstruction';refine_instruction='RefineInstruction';lecture_instruction='LectureInstruction'
        lecture_notes='LectureNotes';reference='Reference';topic='Topic';glossary_renew='GlossaryRenew';output_directory='OutputDirectory'
        refine_batch_minutes='RefineBatchMinutes';whisper_threads='WhisperThreads';whisper_cpu='WhisperCpu';verbose_vad='VerboseVad'
        skip_refine='SkipRefine';no_sdh='NoSDH';brief='Brief';full_output='FullOutput'
    }
}
function Get-TranscriptSettingValues($Data,$BoundParameters,[string[]]$Fields,[string]$BaseDirectory='') {
    $values=@{}
    foreach($entry in (Get-TranscriptSettingMap).GetEnumerator()){
        if($Fields -and $entry.Value -notin $Fields){continue}
        $parameter=$entry.Value -replace 'Instruction$','Prompt'
        $property=$Data.PSObject.Properties[$entry.Key]
        if($null -eq $property -or $null -eq $property.Value -or $BoundParameters.ContainsKey($entry.Value) -or $BoundParameters.ContainsKey($parameter)){continue}
        $value=$property.Value
        if($entry.Key -eq 'terms' -and $value -isnot [string]){$value=@($value)-join '; '}
        if($BaseDirectory -and $entry.Key -in @('whisper_model_path','glossary_file','reference','output_directory') -and $value -and -not [IO.Path]::IsPathRooted([string]$value)){$value=[IO.Path]::GetFullPath((Join-Path $BaseDirectory $value))}
        $values[$entry.Value]=$value
    }
    return $values
}
function Get-TranscriptProfile([string]$Profile,$BoundParameters,[string[]]$Fields) {
    $path=$Profile
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){$path=Join-Path (Join-Path $PSScriptRoot 'profiles') ($Profile+'.json')}
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){
        $available=@(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'profiles') -Filter '*.json'|ForEach-Object BaseName)
        throw "Profile '$Profile' was not found. Available profiles: $($available -join ', ')."
    }
    $path=(Resolve-Path -LiteralPath $path).Path
    $data=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json
    if([int]$data.version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$data.name)){throw "Invalid profile name or version: $path"}
    $known=@('version','name','description')+@((Get-TranscriptSettingMap).Keys)
    $unknown=@($data.PSObject.Properties.Name|Where-Object{$_ -notin $known})
    if($unknown.Count){throw "Unknown profile field(s) in ${path}: $($unknown -join ', ')."}
    return [pscustomobject]@{Path=$path;Name=$data.name;Values=(Get-TranscriptSettingValues $data $BoundParameters $Fields ([IO.Path]::GetDirectoryName($path)))}
}
function Get-TranscriptApi {
    return Get-TranscribeApiConfiguration
}
function Invoke-TranscriptApi([string]$Url,[string]$Key,[string]$Payload,[int]$Timeout=300) {
    return Invoke-RestMethod -Method Post -Uri $Url -Headers @{Authorization="Bearer $Key"} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($Payload)) -TimeoutSec $Timeout
}
function Get-TranscriptResponseText($Response) {
    if($Response.choices[0].finish_reason -eq 'length'){throw 'Response truncated by output token limit.'}
    $text=([string]$Response.choices[0].message.content).Trim()
    return ($text -replace '^```(?:json)?\s*','' -replace '\s*```$','').Trim()
}
function Save-TranscriptDiagnostic([string]$Directory,[string]$Label,$Response,$Failure) {
    if($null -eq $Response){return}
    try{
        [void][IO.Directory]::CreateDirectory($Directory)
        $path=Join-Path $Directory ($Label+'-'+[guid]::NewGuid().ToString('N')+'.response.json')
        @{error=$Failure.Exception.Message;response=$Response}|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $path -Encoding utf8
        Write-Verbose "API diagnostic: $path"
    }catch{Write-Warning "Could not save API diagnostic: $($_.Exception.Message)"}
}
function Invoke-TranscriptBatches {
    param([string]$Stage,[object[]]$Tasks,[ValidateSet('Invoke-TranscriptCorrection','Invoke-TranscriptLecture')][string]$Command,[int]$Concurrency=4,[hashtable]$State)
    $watch=[Diagnostics.Stopwatch]::StartNew();$progress=New-TranscriptProgress
    $active=@{};$rows=@{};$next=0;$lastFinished=-1
    $totalItems=($Tasks|Measure-Object -Property count -Sum).Sum
    try{
        do{
            while($next -lt $Tasks.Count -and $active.Count -lt $Concurrency){
                $task=$Tasks[$next]
                $job=Start-ThreadJob -ArgumentList $task,$Command -ScriptBlock {
                    param($task,$command)
                    $ErrorActionPreference='Stop';$timer=[Diagnostics.Stopwatch]::StartNew()
                    Import-Module $task.module -Force
                    $items=@(& $command $task)
                    return (@{index=$task.index;count=$task.count;items=$items;elapsed_seconds=$timer.Elapsed.TotalSeconds}|ConvertTo-Json -Depth 12 -Compress)
                }
                $active[$job.Id]=$job;$next++
            }
            $completed=@($active.Values|Where-Object State -In @('Completed','Failed','Stopped')|Sort-Object PSEndTime)
            foreach($job in @($active.Values)){
                foreach($warning in @($job.Warning.ReadAll())){$State.warnings=$true;Write-TranscriptStatus $progress ('WARN '+$warning.Message) Yellow}
            }
            foreach($job in $completed){
                $result=@($job|Receive-Job -ErrorAction Stop|ForEach-Object{$_|ConvertFrom-Json})
                if($result.Count -ne 1){throw "$Stage batch returned no result. Recovery files were retained."}
                $row=$result[0];$rows[[int]$row.index]=$row
                $kept=@($row.items|Where-Object {$_.PSObject.Properties['fallback'] -and $_.fallback}).Count
                $suffix=if($kept){" | $kept items kept unchanged"}else{''}
                Write-TranscriptStatus $progress ("{0} batch {1}/{2} completed in {3}{4}" -f $Stage,($row.index+1),$Tasks.Count,(Format-TranscriptDuration $row.elapsed_seconds),$suffix) $(if($kept){'Yellow'}else{'Green'})
                [void]$active.Remove($job.Id);$job|Remove-Job -Force
            }
            $processed=0;foreach($row in $rows.Values){$processed+=[int]$row.count}
            Write-TranscriptProgress $progress ("{0}: {1}/{2} batches | {3}/{4} items | elapsed {5}" -f $Stage,$rows.Count,$Tasks.Count,$processed,$totalItems,(Format-TranscriptDuration $watch.Elapsed.TotalSeconds)) -Force:($lastFinished -ne $rows.Count)
            $lastFinished=$rows.Count
            if($rows.Count -lt $Tasks.Count){Start-Sleep -Milliseconds 200}
        }while($rows.Count -lt $Tasks.Count)
    }finally{
        Clear-TranscriptProgress $progress
        foreach($job in @($active.Values)){$job|Stop-Job -ErrorAction SilentlyContinue;$job|Remove-Job -Force}
    }
    return @($rows.Values|Sort-Object index)
}
Export-ModuleMember -Function *-Transcript*
