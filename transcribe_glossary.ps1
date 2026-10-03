#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Reference,
    [Alias('OutputFile')][string]$GlossaryFile,
    [string]$Topic='',
    [string]$Model='qwen3.8-chat',
    [switch]$NoMerge,
    [Parameter(DontShow=$true)][string]$ExtractedTextPath,
    [Parameter(DontShow=$true)][string]$TranscriptFile,
    [Parameter(DontShow=$true)][string]$SeedGlossaryFile,
    [Parameter(DontShow=$true)][string]$SeedTerms
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'transcribe_reference.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'transcribe_config.psm1') -Force
if(-not $Reference -and -not $TranscriptFile){throw 'Provide -Reference, -TranscriptFile, or both.'}
if(-not $GlossaryFile){if(-not $Reference){throw '-GlossaryFile is required when no reference is supplied.'};$GlossaryFile=Get-TranscriptionReferenceGlossaryPath -Reference $Reference}
$GlossaryFile=[IO.Path]::GetFullPath($GlossaryFile)
if($NoMerge){
    $directory=[IO.Path]::GetDirectoryName($GlossaryFile);$name=[IO.Path]::GetFileNameWithoutExtension($GlossaryFile);$extension=[IO.Path]::GetExtension($GlossaryFile)
    $GlossaryFile=Join-Path $directory ($name+'.extracted'+$extension)
}
$ownsExtractedText=($Reference -and [string]::IsNullOrWhiteSpace($ExtractedTextPath))
$conversion=$null
if($Reference){$conversion=if($ExtractedTextPath){Convert-TranscriptionReference -Reference $Reference -OutputPath $ExtractedTextPath}else{Convert-TranscriptionReference -Reference $Reference};$ExtractedTextPath=$conversion.Path}
function Remove-OwnedReferenceText{if($ownsExtractedText -and (Test-Path -LiteralPath $ExtractedTextPath)){Remove-Item -LiteralPath $ExtractedTextPath -Force}}
trap{Remove-OwnedReferenceText;throw $_}
if($conversion){Write-Host "Reference prepared ($($conversion.Files.Count) file(s), $($conversion.PageCount) section(s)): $Reference" -ForegroundColor Cyan}

$lockPath=$GlossaryFile+'.lock';$lockStream=$null
for($attempt=0;$attempt -lt 120 -and -not $lockStream;$attempt++){
    try{$lockStream=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{Start-Sleep -Seconds 1}
}
if(-not $lockStream){throw "Timed out waiting for glossary lock: $lockPath"}
try{
    # Read only after acquiring the lock so concurrent renewals cannot overwrite
    # terms written by the process that held the lock immediately before us.
    $header=@();$existingTerms=@()
    if(-not $NoMerge -and (Test-Path -LiteralPath $GlossaryFile -PathType Leaf)){
        $seenContent=$false
        foreach($rawLine in Get-Content -LiteralPath $GlossaryFile){
            $line=([string]$rawLine).Trim()
            if(-not $seenContent -and (-not $line -or $line.StartsWith('#'))){if($line -notmatch '^#\s*Topic\s*:'){$header += [string]$rawLine};continue}
            if(-not $line){continue}
            $seenContent=$true
            if(-not $line.StartsWith('#')){$existingTerms += $line}
        }
    }
    if($SeedGlossaryFile -and (Test-Path -LiteralPath $SeedGlossaryFile -PathType Leaf)){
        $existingTerms += @(Get-Content -LiteralPath $SeedGlossaryFile|ForEach-Object{$line=([string]$_).Trim();if($line -and -not $line.StartsWith('#')){$line}})
    }
    if($SeedTerms){$existingTerms += @($SeedTerms -split ';'|ForEach-Object{$_.Trim()}|Where-Object{$_})}
    $existingTerms=@($existingTerms|Select-Object -Unique)
    $api=Get-TranscribeApiConfiguration;$url=$api.Url;$key=$api.Key
    $referenceText=if($ExtractedTextPath){Get-Content -Raw -LiteralPath $ExtractedTextPath}else{''};if($referenceText.Length -gt 240000){$referenceText=$referenceText.Substring(0,240000)}
    $transcriptText=if($TranscriptFile){Get-Content -Raw -LiteralPath (Resolve-Path -LiteralPath $TranscriptFile -ErrorAction Stop)}else{''};if($transcriptText.Length -gt 180000){$transcriptText=$transcriptText.Substring(0,180000)}
    $termSchema=@{type='object';additionalProperties=$false;required=@('term','observed_form','canonical_confidence','evidence','relevance','asr_risk','importance');properties=@{term=@{type='string'};observed_form=@{type='string'};canonical_confidence=@{type='integer';minimum=0;maximum=4};evidence=@{type='integer';minimum=0;maximum=4};relevance=@{type='integer';minimum=0;maximum=4};asr_risk=@{type='integer';minimum=0;maximum=4};importance=@{type='integer';minimum=0;maximum=4}}}
    $schema=@{type='json_schema';json_schema=@{name='course_glossary';strict=$true;schema=@{type='object';additionalProperties=$false;required=@('topic','terms');properties=@{topic=@{type='string'};terms=@{type='array';minItems=1;maxItems=80;items=$termSchema}}}}}
    $system=@"
Build a compact ASR glossary for one recording. The rough transcript is the primary evidence of what this recording actually discusses; course references are supporting evidence for recovering canonical spellings and resolving likely phonetic or contextual ASR errors. The requested topic is an additional hint. Infer a concise topic when it is empty. Prefer 30-60 high-value terms and never return more than 80.

A term may be strongly evidenced even when its correct spelling is absent from the rough transcript: use nearby concepts, formulas, names, and plausible homophones. For example, a passage about dichotomies, binomial coefficients, and perceptron capacity supports Cover's theorem even if ASR produced a different phrase. The term field must contain the canonical corrected spelling, never the raw ASR wording. Put the corresponding raw wording in observed_form, or an empty string when none is identifiable. canonical_confidence measures confidence that the spelling and identity are standard and correct. If a name or institution cannot be confirmed from matching reference context or well-established terminology, omit it instead of canonizing a plausible transcription.

A term appearing only in an unrelated reference chapter has evidence=0 and must not be selected as a new term. Prefer concepts central to the recording, terms likely to recur, and terms whose correction changes technical meaning. Incidental examples and one-off names must not outrank core concepts merely because they are distinctive. Omit general vocabulary, definitions, equations, complete clauses, numerical facts, conversational fragments, page furniture, bibliography-only names, and descriptive phrases such as "10 to the 5 neurons", "80% excitatory", or "one layer before neural network".

Existing terms are user-owned and will be preserved by the script. Do not return all of them mechanically. Return an existing term only when it belongs in the selected compact glossary so it can be rescored; spend the remaining slots on high-value new terms. Keep every returned term concise and unique; never add tabs, type suffixes, tags, definitions, headings, or comments.

Score each term from 0 to 4. evidence: support from this recording, including contextual or phonetic evidence. relevance: relevance to the recording's actual topic. asr_risk: likelihood of transcription error. importance: expected frequency or importance to understanding this recording. canonical_confidence: confidence in the canonical identity and spelling. Do not group terms by subject category. When a transcript is supplied, the script ranks by 35% evidence + 25% relevance + 20% ASR risk + 20% importance. Reference-only rarity and incidental examples must never outrank recording evidence and central concepts.
"@
    $input=[ordered]@{requested_topic=$Topic;existing_terms=$existingTerms;rough_transcript=$transcriptText;reference_text=$referenceText}|ConvertTo-Json -Depth 5 -Compress
    $request=@{model=$Model;temperature=0;max_tokens=8192;response_format=$schema;messages=@(@{role='system';content=$system},@{role='user';content=$input})}|ConvertTo-Json -Depth 15
    $result=$null
    for($attempt=1;$attempt -le 3;$attempt++){
        Write-Host "Glossary API: attempt $attempt of 3." -ForegroundColor DarkCyan
        try{$result=Invoke-RestMethod -Method Post -Uri $url -Headers @{Authorization="Bearer $key"} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($request)) -TimeoutSec 600;if($result.choices[0].finish_reason -eq 'length'){throw 'Response truncated by output token limit.'};break}
        catch{
            $failure=$_;$statusCode=$null;if($failure.Exception.Response -and $null -ne $failure.Exception.Response.StatusCode){$statusCode=[int]$failure.Exception.Response.StatusCode}
            Write-Warning "Glossary attempt $attempt failed: $($failure.Exception.Message)"
            if($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -notin @(408,425,429,499)){throw}
            if($attempt -eq 3){throw 'Glossary generation failed after three attempts.'}
            $delay=if($statusCode -eq 429){15*[math]::Pow(2,$attempt-1)}else{5*[math]::Pow(2,$attempt-1)};Start-Sleep -Seconds $delay
        }
    }
    $content=([string]$result.choices[0].message.content -replace '(?s)^.*?```(?:json)?\s*','' -replace '(?s)\s*```.*$','').Trim();$object=$content|ConvertFrom-Json
    $rankedTerms=@();$seenTerms=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$modelIndex=0
    foreach($modelTerm in @($object.terms)){
        $term=([string]$modelTerm.term).Trim()
        if($term -and $term.Length -le 120 -and $seenTerms.Add($term)){
            $canonicalConfidence=[math]::Max(0,[math]::Min(4,[int]$modelTerm.canonical_confidence));$evidence=[math]::Max(0,[math]::Min(4,[int]$modelTerm.evidence));$relevance=[math]::Max(0,[math]::Min(4,[int]$modelTerm.relevance));$risk=[math]::Max(0,[math]::Min(4,[int]$modelTerm.asr_risk));$importance=[math]::Max(0,[math]::Min(4,[int]$modelTerm.importance))
            $isExisting=$existingTerms -contains $term
            $looksLikeFragment=($term -match '^\s*\d' -or $term -match '\d+\s*%' -or ($term -split '\s+').Count -gt 7 -or $term -match '^(one layer before neural network|long range cables?|cubic millimeters?)$')
            $score=if($TranscriptFile){0.35*$evidence+0.25*$relevance+0.20*$risk+0.20*$importance}else{0.40*$relevance+0.35*$risk+0.25*$importance}
            if($isExisting -or (-not $looksLikeFragment -and $canonicalConfidence -ge 3 -and (-not $TranscriptFile -or $evidence -ge 2) -and $relevance -ge 2 -and ($risk -ge 2 -or $importance -ge 3))){$rankedTerms += [pscustomobject]@{term=$term;evidence=$evidence;relevance=$relevance;asr_risk=$risk;importance=$importance;score=$score;model_index=$modelIndex}}
            $modelIndex++
        }
    }
    $missing=@($existingTerms|Where-Object{-not $seenTerms.Contains($_)})
    if($missing.Count){
        foreach($term in $missing){[void]$seenTerms.Add($term);$rankedTerms += [pscustomobject]@{term=$term;evidence=0;relevance=0;asr_risk=0;importance=0;score=0.0;model_index=$modelIndex};$modelIndex++}
    }
    if(-not $rankedTerms.Count){throw 'The glossary model returned no usable terms.'}
    $rankedTerms=@($rankedTerms|Sort-Object @{Expression='score';Descending=$true},@{Expression='evidence';Descending=$true},@{Expression='relevance';Descending=$true},@{Expression='asr_risk';Descending=$true},@{Expression='importance';Descending=$true},model_index)
    while($header.Count -and -not ([string]$header[-1]).Trim()){if($header.Count -eq 1){$header=@()}else{$header=@($header[0..($header.Count-2)])}}
    $output=@();if($header.Count){$output += $header;$output += ''}
    $topicText=([string]$object.topic).Trim();if($topicText){$output += "# Topic: $topicText";$output += ''}
    # Scores from different models are not calibrated and often cluster near
    # the maximum. Preserve the global score order, then use relative tiers so
    # the file remains useful even when every selected term scores above 3.
    $termCount=$rankedTerms.Count
    $highCount=[math]::Max(1,[math]::Ceiling($termCount*0.30))
    $mediumCount=[math]::Min($termCount-$highCount,[math]::Ceiling($termCount*0.50))
    $highItems=@($rankedTerms|Select-Object -First $highCount)
    $mediumItems=if($mediumCount -gt 0){@($rankedTerms|Select-Object -Skip $highCount -First $mediumCount)}else{@()}
    $additionalItems=@($rankedTerms|Select-Object -Skip ($highCount+$mediumCount))
    $priorityGroups=@(
        [pscustomobject]@{name='high';items=$highItems},
        [pscustomobject]@{name='medium';items=$mediumItems},
        [pscustomobject]@{name='additional';items=$additionalItems}
    )
    foreach($group in $priorityGroups){
        if(-not $group.items.Count){continue}
        $chineseCount=@($group.items|Where-Object{$_.term -match '[\u3400-\u9fff]'}).Count;$useChinese=$chineseCount -ge [math]::Ceiling($group.items.Count/2.0)
        $heading=switch($group.name){'high'{if($useChinese){'高优先级'}else{'High priority'}}'medium'{if($useChinese){'中优先级'}else{'Medium priority'}}default{if($useChinese){'补充术语'}else{'Additional terms'}}}
        $output += "# $heading";$output += @($group.items.term);$output += ''
    }
    while($output.Count -and -not ([string]$output[-1]).Trim()){$output=$output[0..($output.Count-2)]}
    $temporary=$GlossaryFile+'.tmp.'+[guid]::NewGuid().ToString('N');try{$output -join "`r`n"|Set-Content -LiteralPath $temporary -Encoding utf8;Move-Item -LiteralPath $temporary -Destination $GlossaryFile -Force}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
    Write-Host "Glossary updated ($($rankedTerms.Count) terms): $GlossaryFile" -ForegroundColor Green
}finally{
    $lockStream.Dispose();Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue;Remove-OwnedReferenceText
}
