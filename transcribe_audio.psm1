function Get-TranscriptAudioInfo([string]$InputPath,[string]$FfprobePath) {
    $output=& $FfprobePath -v error -select_streams a:0 -show_entries stream=channels,sample_rate,start_time:format=start_time -of json -i $InputPath 2>&1
    if($LASTEXITCODE -ne 0){throw "Could not inspect audio: $($output -join ' ')"}
    $info=($output -join "`n")|ConvertFrom-Json
    if(-not @($info.streams).Count -or [int]$info.streams[0].channels -lt 1){throw "No usable audio stream found: $InputPath"}
    return $info.streams[0]
}

function Convert-TranscriptAudio {
    param([string]$InputPath,[string]$OutputPath,[string]$FfmpegPath,[string]$FfprobePath)
    $info=Get-TranscriptAudioInfo $InputPath $FfprobePath
    $channels=[int]$info.channels
    $filter='aresample=16000:async=1:first_pts=0'
    $operation='mono preserved'
    if($channels -eq 2){$filter='pan=mono|c0=c0,'+$filter;$operation='left only; right excluded'}
    elseif($channels -gt 2){$operation='downmixed to mono'}
    Write-Host "Audio: $channels channel(s) -> $operation" -ForegroundColor Cyan
    # Keep stream offsets relative to media time zero, including leading silence.
    # Pan precedes output channel conversion so stereo right audio cannot enter it.
    & $FfmpegPath -hide_banner -loglevel error -nostdin -y -copyts -start_at_zero -i $InputPath -map 0:a:0 -vn -sn -dn -af $filter -ar 16000 -ac 1 -c:a pcm_s16le $OutputPath
    if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $OutputPath -PathType Leaf)){throw 'Audio preprocessing failed.'}
    return [pscustomobject]@{Path=$OutputPath;Channels=$channels;Operation=$operation}
}

Export-ModuleMember -Function Get-TranscriptAudioInfo,Convert-TranscriptAudio
