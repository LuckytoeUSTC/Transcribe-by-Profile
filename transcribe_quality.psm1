function Get-TranscriptTextKey([string]$Text) {
    return ($Text.ToLowerInvariant() -replace '[^\p{L}\p{N}]+',' ').Trim()
}

function Compress-TranscriptLoop([string]$Text) {
    # Character loops such as "短短..." need no whitespace. Keep three characters
    # rather than inventing missing speech; eight repeats is the detection floor.
    $Text=[regex]::Replace($Text,'([\u3400-\u9fff])\1{7,}','$1$1$1')
    $Text=[regex]::Replace($Text,'([\u3400-\u9fff]{2,8})\1{5,}','$1$1')
    # Require at least four repetitions of a phrase with four or more words.
    # Short emphasis ("very very", "yes yes") is deliberately untouched.
    $pattern='(?i)(?<![\p{L}\p{N}])(?<phrase>[\p{L}\p{N}]+(?:[\s,;:.!?，。！？；：]+[\p{L}\p{N}]+){3,39})(?<separator>[\s,;:.!?，。！？；：]+)(?:\k<phrase>\k<separator>){2,}\k<phrase>(?![\p{L}\p{N}])'
    return [regex]::Replace($Text,$pattern,'${phrase}',[Text.RegularExpressions.RegexOptions]::None,[TimeSpan]::FromMilliseconds(150))
}

function Test-TranscriptExpansion([string]$Source,[string]$Output) {
    if($Output.Length -gt [math]::Max(160,3*$Source.Length)){return $true}
    try { return (Compress-TranscriptLoop $Output).Length -lt $Output.Length } catch [Text.RegularExpressions.RegexMatchTimeoutException] { return $true }
}

function Join-TranscriptText($Parts) {
    $joined=''
    foreach($part in @($Parts)){
        $piece=([string]$part.text).Trim()
        if(-not $piece){continue}
        if(-not $joined){$joined=$piece;continue}
        if($joined -match '[\u3400-\u9fff]$' -or $piece -match '^[\u3400-\u9fff\p{P}]'){$joined+=$piece}else{$joined+=' '+$piece}
    }
    return $joined.Trim()
}
Export-ModuleMember -Function Get-TranscriptTextKey,Compress-TranscriptLoop,Test-TranscriptExpansion,Join-TranscriptText
