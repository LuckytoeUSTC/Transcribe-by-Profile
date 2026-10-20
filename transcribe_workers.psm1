Import-Module (Join-Path $PSScriptRoot 'transcribe_runtime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'transcribe_quality.psm1') -Force

function Invoke-TranscriptCorrection($Task) {
    $index=$Task.index;$work=$Task.work;$url=$Task.url;$key=$Task.key;$model=$Task.model;$system=$Task.system;$diagnosticDirectory=$Task.diagnostics
    $ErrorActionPreference='Stop'
    $responseBudget=@{abnormal=0}
    function Invoke-Chunk($items,$contextBefore,$contextAfter,[int]$depth=0){
        if($responseBudget.abnormal -ge 3){
            Write-Warning "Batch $($index+1): abnormal-response budget exhausted; preserving $($items.Count) source item(s)."
            return @($items|ForEach-Object{[pscustomobject]@{source_id=[int]$_.id;text=[string]$_.text;sentence_end=([string]$_.text -match '[.!?。！？]\s*$');fallback=$true}})
        }
        $want=@($items|ForEach-Object{[int]$_.id}); $feedback=''
        $requestItems=@($items|ForEach-Object{[pscustomobject]@{source_id=[int]$_.id;text=[string]$_.text}})
        $request=[ordered]@{
            context_before=@($contextBefore|ForEach-Object{[pscustomobject]@{source_id=[int]$_.id;text=[string]$_.text}})
            items=$requestItems
            context_after=@($contextAfter|ForEach-Object{[pscustomobject]@{source_id=[int]$_.id;text=[string]$_.text}})
        }
        for($attempt=1;$attempt -le 3;$attempt++){
            $receivedResponse=$false
            $res=$null
            try{
                $messages=@(@{role='system';content=$system},@{role='user';content=($request|ConvertTo-Json -Depth 4 -Compress)})
                if($feedback){$messages += @{role='system';content=$feedback}}
                $itemSchema=@{type='object';additionalProperties=$false;required=@('source_id','text','sentence_end');properties=@{source_id=@{type='integer'};text=@{type='string';minLength=1};sentence_end=@{type='boolean'}}}
                $responseFormat=@{type='json_schema';json_schema=@{name='transcript_items';strict=$true;schema=@{type='object';additionalProperties=$false;required=@('items');properties=@{items=@{type='array';minItems=$items.Count;maxItems=$items.Count;items=$itemSchema}}}}}
                $payload=@{model=$model;temperature=0;max_tokens=8192;response_format=$responseFormat;messages=$messages}|ConvertTo-Json -Depth 20
                $res=Invoke-TranscriptApi $url $key $payload 300
                $receivedResponse=$true
                $text=Get-TranscriptResponseText $res
                $obj=$text|ConvertFrom-Json; $got=@($obj.items|ForEach-Object{[int]$_.source_id})
                if(($got -join ',') -ne ($want -join ',')){throw 'invalid id coverage'}
                for($oi=0;$oi -lt $obj.items.Count;$oi++){
                    $item=$obj.items[$oi]
                    if([string]::IsNullOrWhiteSpace([string]$item.text)){throw 'empty text'}
                    if(Test-TranscriptExpansion ([string]$items[$oi].text) ([string]$item.text)){throw 'Abnormal output expansion or repeated phrase loop.'}
                }
                return @($obj.items)
            }catch{
                $failure=$_
                Save-TranscriptDiagnostic $diagnosticDirectory ("batch-{0}-depth-{1}-id-{2}-attempt-{3}" -f ($index+1),$depth,$want[0],$attempt) $res $failure
                $statusCode=$null
                if($failure.Exception.Response -and $null -ne $failure.Exception.Response.StatusCode){$statusCode=[int]$failure.Exception.Response.StatusCode}
                $statusLabel=if($statusCode){"HTTP ${statusCode}: "}else{''}
                Write-Warning "Batch $($index+1), attempt $attempt failed: $statusLabel$($failure.Exception.Message)"
                if($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -notin @(408,425,429,499)){
                    throw "Batch $($index+1) stopped after non-retryable HTTP $statusCode. Check the API key, model permission, endpoint, or request format."
                }
                if($statusCode -eq 429){
                    if($attempt -eq 3){throw "Batch $($index+1) failed after repeated HTTP 429 rate limits. Recovery files were retained."}
                    $retrySeconds=15*[math]::Pow(2,$attempt-1)
                    try{
                        $serverDelay=$failure.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds
                        if($serverDelay -gt 0){$retrySeconds=[math]::Min(120,[math]::Ceiling($serverDelay))}
                    }catch{}
                    Write-Warning "Batch $($index+1): rate limited; retrying in $retrySeconds seconds."
                    Start-Sleep -Seconds $retrySeconds
                    continue
                }
                if(($statusCode -ge 500 -and $statusCode -lt 600) -or $statusCode -in @(408,425,499) -or (-not $receivedResponse -and -not $statusCode)){
                    if($attempt -eq 3){throw "Batch $($index+1) failed after repeated API or network errors. Recovery files were retained."}
                    $retrySeconds=5*[math]::Pow(2,$attempt-1)
                    Write-Warning "Batch $($index+1): transient API error; retrying in $retrySeconds seconds."
                    Start-Sleep -Seconds $retrySeconds
                    continue
                }
                $unsafeResponse=$failure.Exception.Message -match 'truncated by output token limit|Abnormal output expansion'
                if($unsafeResponse){$responseBudget.abnormal++}
                if(($unsafeResponse -or $attempt -ge 2) -and $items.Count -gt 1 -and $depth -lt 2 -and $responseBudget.abnormal -lt 3){
                    Write-Warning "Batch $($index+1): retrying as two smaller chunks."
                    $mid=[int][math]::Floor($items.Count/2)
                    $leftItems=@($items[0..($mid-1)]);$rightItems=@($items[$mid..($items.Count-1)])
                    $left=@(Invoke-Chunk $leftItems $contextBefore (@($rightItems|Select-Object -First 3)) ($depth+1))
                    $right=@(Invoke-Chunk $rightItems (@($leftItems|Select-Object -Last 3)) $contextAfter ($depth+1))
                    return @($left)+@($right)
                }
                if($unsafeResponse -or $attempt -eq 3){
                    Write-Warning "Batch $($index+1): keeping $($items.Count) source item(s) unchanged after model response failure."
                    return @($items|ForEach-Object{[pscustomobject]@{source_id=[int]$_.id;text=[string]$_.text;sentence_end=([string]$_.text -match '[.!?。！？]\s*$');fallback=$true}})
                }
                $feedback="The previous response failed validation. Return exactly one nonempty item for each of these IDs, once and in order: $($want -join ',')."
                Start-Sleep -Seconds (2*$attempt)
            }
        }
    }
    $result=@(Invoke-Chunk @($work.core) @($work.before) @($work.after))
    return $result
}

function Invoke-TranscriptLecture($Task) {
    $referencePages=$Task.referencePages;$Outline=$Task.outline;$system=$Task.system;$responseFormat=$Task.format;$url=$Task.url;$key=$Task.key;$Model=$Task.model;$diagnosticDirectory=$Task.diagnostics;$responseBudget=@{abnormal=0}
    function Get-ReferenceContext($items){
        if(-not $referencePages.Count){return ''}
        $stop=@('this','that','with','from','have','will','what','when','where','which','they','them','their','there','then','than','into','about','also','some','very','just','because','these','those','using','used','model','neuron','neurons')
        $best=@{}
        foreach($item in $items){
            $words=@([regex]::Matches(([string]$item.text).ToLowerInvariant(),'[\p{L}][\p{L}\p{N}_-]{2,}')|ForEach-Object{$_.Value})
            $terms=@($words|Where-Object{$_.Length -ge 4 -and $_ -notin $stop}|Select-Object -Unique)
            $bigrams=@();$trigrams=@()
            for($j=0;$j -lt $words.Count-1;$j++){$bigrams += "$($words[$j]) $($words[$j+1])"}
            for($j=0;$j -lt $words.Count-2;$j++){$trigrams += "$($words[$j]) $($words[$j+1]) $($words[$j+2])"}
            $ranked=for($i=0;$i -lt $referencePages.Count;$i++){
                $page=[string]$referencePages[$i];$lower=($page.ToLowerInvariant() -replace '\s+',' ');$score=0
                foreach($term in $terms){if($lower.Contains($term)){$score++}}
                foreach($phrase in ($bigrams|Select-Object -Unique)){if($lower.Contains($phrase)){$score+=4}}
                foreach($phrase in ($trigrams|Select-Object -Unique)){if($lower.Contains($phrase)){$score+=7}}
                if($score){[pscustomobject]@{index=$i;score=$score;text=$page}}
            }
            foreach($page in @($ranked|Sort-Object score -Descending|Select-Object -First 2)){
                if(-not $best.ContainsKey($page.index) -or $page.score -gt $best[$page.index].score){$best[$page.index]=$page}
            }
        }
        $primary=@($best.Values|Sort-Object score -Descending|Select-Object -First 3)
        $selected=@();$seen=@{}
        foreach($page in $primary){
            foreach($index in @($page.index,($page.index-1))){
                if($index -ge 0 -and $index -lt $referencePages.Count -and -not $seen.ContainsKey($index)){
                    $selected += [pscustomobject]@{index=$index;text=[string]$referencePages[$index]};$seen[$index]=$true
                }
            }
        }
        $parts=@()
        foreach($page in $selected){$text=([string]$page.text).Trim();if($text.Length -gt 3500){$text=$text.Substring(0,3500)};$parts += "[Reference page $($page.index+1)]`n$text"}
        $joined=$parts -join "`n`n";if($joined.Length -gt 15000){$joined=$joined.Substring(0,15000)};return $joined
    }


    function Invoke-LectureChunk($chunk,[string]$context,[string]$futureContext,[string]$label,[int]$depth=0){
        if($responseBudget.abnormal -ge 3){return @($chunk|ForEach-Object{[pscustomobject]@{source_id=[int]$_.source_id;include=$true;heading='';markdown=[string]$_.text;review_note='Model output validation failed; original paragraph retained.'}})}
        $want=@($chunk.source_id)
        $request=[ordered]@{global_outline=$Outline;previous_context=$context;next_context=$futureContext;reference_context=(Get-ReferenceContext $chunk);items=@($chunk|ForEach-Object{[ordered]@{source_id=$_.source_id;text=$_.text}})}
        for($attempt=1;$attempt -le 3;$attempt++){
            $response=$null
            try{
                $payload=@{model=$Model;temperature=0;max_tokens=8192;response_format=$responseFormat;messages=@(@{role='system';content=$system},@{role='user';content=($request|ConvertTo-Json -Depth 5 -Compress)})}|ConvertTo-Json -Depth 20
                $response=Invoke-TranscriptApi $url $key $payload 300
                $content=Get-TranscriptResponseText $response
                $items=@(($content|ConvertFrom-Json).items);$got=@($items|ForEach-Object{[int]$_.source_id})
                if(($got -join ',') -ne ($want -join ',')){throw 'Invalid source_id coverage.'}
                foreach($item in $items){if([bool]$item.include -and [string]::IsNullOrWhiteSpace([string]$item.markdown)){throw "Empty included paragraph for source_id $($item.source_id)."}}
                return $items
            }catch{
                $failure=$_;$statusCode=$null
                if($failure.Exception.Response -and $null -ne $failure.Exception.Response.StatusCode){$statusCode=[int]$failure.Exception.Response.StatusCode}
                Write-Warning "Lecture batch $label, attempt $attempt failed: $($failure.Exception.Message)"
                Save-TranscriptDiagnostic $diagnosticDirectory ("lecture-$label-attempt-$attempt") $response $failure
                if($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -notin @(408,425,429,499)){throw "Lecture generation stopped after non-retryable HTTP $statusCode."}
                $isTransient=$statusCode -in @(408,425,429,499) -or ($statusCode -ge 500 -and $statusCode -lt 600) -or ($null -eq $statusCode -and $failure.Exception.Message -match 'connection|network|timed out|timeout|SSL')
                if(-not $isTransient){$responseBudget.abnormal++}
                if(-not $isTransient -and $chunk.Count -gt 1 -and $depth -lt 2 -and $responseBudget.abnormal -lt 3){
                    $mid=[int][math]::Floor($chunk.Count/2);Write-Warning "Lecture batch ${label}: retrying as two smaller chunks."
                    $left=@(Invoke-LectureChunk @($chunk[0..($mid-1)]) $context ([string]$chunk[$mid].text) "$label.a" ($depth+1))
                    $rightContext=[string]$chunk[$mid-1].text
                    $right=@(Invoke-LectureChunk @($chunk[$mid..($chunk.Count-1)]) $rightContext $futureContext "$label.b" ($depth+1))
                    return @($left)+@($right)
                }
                if(-not $isTransient -or $attempt -eq 3){
                    if(-not $isTransient){Write-Warning "Lecture batch ${label}: preserving $($chunk.Count) original paragraph(s) after validation failure.";return @($chunk|ForEach-Object{[pscustomobject]@{source_id=[int]$_.source_id;include=$true;heading='';markdown=[string]$_.text;review_note='Model output validation failed; original paragraph retained.'}})}
                    throw "Lecture batch $label failed after three attempts."
                }
                $delay=if($statusCode -eq 429){15*[math]::Pow(2,$attempt-1)}else{5*[math]::Pow(2,$attempt-1)};Start-Sleep -Seconds $delay
            }
        }
    }

    return @(Invoke-LectureChunk $Task.batch $Task.previous $Task.future ([string]($Task.index+1)))
}

Export-ModuleMember -Function Invoke-TranscriptCorrection,Invoke-TranscriptLecture
