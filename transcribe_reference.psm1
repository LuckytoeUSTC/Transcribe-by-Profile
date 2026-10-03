Set-StrictMode -Version 2
$script:ReferenceCacheVersion='ref-v1'

function Resolve-TranscriptionReference {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true,Position=0)][string]$Reference)
    $resolved=(Resolve-Path -LiteralPath $Reference -ErrorAction Stop).Path
    $extensions=@('.pdf','.txt','.md')
    if(Test-Path -LiteralPath $resolved -PathType Container){
        $files=@(Get-ChildItem -LiteralPath $resolved -File|Where-Object{$extensions -contains $_.Extension.ToLowerInvariant()}|Sort-Object Name,FullName)
        if(-not $files.Count){throw "No PDF, TXT, or MD reference files were found directly in: $resolved"}
        return @($files.FullName)
    }
    if($extensions -notcontains [IO.Path]::GetExtension($resolved).ToLowerInvariant()){throw "Unsupported reference type. Use a PDF, TXT, MD, or a directory containing those files: $resolved"}
    return @($resolved)
}

function Get-ReferencePythonExtractor {
    $bundled=Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    $pathCommand=Get-Command python.exe -ErrorAction SilentlyContinue
    $pathPython=if($pathCommand){$pathCommand.Source}else{$null}
    foreach($candidate in @($bundled,$pathPython)|Where-Object{$_}|Select-Object -Unique){
        if(-not(Test-Path -LiteralPath $candidate)){continue}
        & $candidate -c 'import pdfplumber' 2>$null
        if($LASTEXITCODE -eq 0){return [pscustomobject]@{Path=$candidate;Module='pdfplumber'}}
        & $candidate -c 'import pypdf' 2>$null
        if($LASTEXITCODE -eq 0){return [pscustomobject]@{Path=$candidate;Module='pypdf'}}
    }
    return $null
}

function Convert-ReferenceFileToCache {
    param([Parameter(Mandatory=$true)][string]$File,[Parameter(Mandatory=$true)][string]$CacheRoot)
    $hash=(Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
    $cachePath=Join-Path $CacheRoot ($hash+'.'+$script:ReferenceCacheVersion+'.txt')
    if(Test-Path -LiteralPath $cachePath -PathType Leaf){return $cachePath}
    $temporary=$cachePath+'.tmp.'+[guid]::NewGuid().ToString('N')
    try{
        if([IO.Path]::GetExtension($File) -ieq '.pdf'){
            $extractor=Get-ReferencePythonExtractor
            if($extractor -and $extractor.Module -eq 'pdfplumber'){
                & $extractor.Path -c 'import sys,pdfplumber; p=pdfplumber.open(sys.argv[1]); open(sys.argv[2],"w",encoding="utf-8").write("\f".join((x.extract_text() or "") for x in p.pages)); p.close()' $File $temporary
            }elseif($extractor -and $extractor.Module -eq 'pypdf'){
                & $extractor.Path -c 'import sys; from pypdf import PdfReader; p=PdfReader(sys.argv[1]); open(sys.argv[2],"w",encoding="utf-8").write("\f".join((x.extract_text() or "") for x in p.pages))' $File $temporary
            }else{
                $pdftotext=(Get-Command pdftotext.exe -ErrorAction SilentlyContinue).Source
                if(-not $pdftotext){throw 'Python with pdfplumber/pypdf or pdftotext.exe is required to extract PDF references.'}
                & $pdftotext -layout $File $temporary
            }
            if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $temporary)){throw "Could not extract PDF reference: $File"}
        }else{
            Get-Content -Raw -LiteralPath $File -ErrorAction Stop|Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        }
        $length=(Get-Item -LiteralPath $temporary).Length
        if($length -lt 40 -and [IO.Path]::GetExtension($File) -ieq '.pdf'){Write-Warning "Very little text was extracted from PDF reference; it may be scanned or empty: $File"}
        Move-Item -LiteralPath $temporary -Destination $cachePath -Force
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
    return $cachePath
}

function Convert-TranscriptionReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true,Position=0)][string]$Reference,
        [string]$OutputPath
    )
    $files=@(Resolve-TranscriptionReference $Reference)
    $cacheRoot=Join-Path ([IO.Path]::GetTempPath()) 'Transcribe\reference-cache'
    [IO.Directory]::CreateDirectory($cacheRoot)|Out-Null
    $parts=[Collections.Generic.List[string]]::new()
    foreach($file in $files){
        $cached=Convert-ReferenceFileToCache -File $file -CacheRoot $cacheRoot
        $pages=@((Get-Content -Raw -LiteralPath $cached)-split "`f")
        for($i=0;$i -lt $pages.Count;$i++){
            $text=([string]$pages[$i]).Trim()
            if($text){$parts.Add("[Reference file: $([IO.Path]::GetFileName($file)) | page: $($i+1)]`n$text")}
        }
    }
    $ownsOutput=[string]::IsNullOrWhiteSpace($OutputPath)
    if($ownsOutput){$OutputPath=Join-Path ([IO.Path]::GetTempPath()) ('transcribe_reference_'+[guid]::NewGuid().ToString('N')+'.txt')}
    else{$OutputPath=[IO.Path]::GetFullPath($OutputPath)}
    $temporary=$OutputPath+'.tmp.'+[guid]::NewGuid().ToString('N')
    try{$parts -join "`f"|Set-Content -LiteralPath $temporary -Encoding utf8;Move-Item -LiteralPath $temporary -Destination $OutputPath -Force}
    finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
    [pscustomobject]@{Path=$OutputPath;Files=$files;OwnsPath=$ownsOutput;PageCount=$parts.Count}
}

function Get-TranscriptionReferenceGlossaryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Reference)
    $resolved=(Resolve-Path -LiteralPath $Reference -ErrorAction Stop).Path
    $directory=if(Test-Path -LiteralPath $resolved -PathType Container){$resolved}else{[IO.Path]::GetDirectoryName($resolved)}
    Join-Path $directory 'glossary.txt'
}

Export-ModuleMember -Function Resolve-TranscriptionReference,Convert-TranscriptionReference,Get-TranscriptionReferenceGlossaryPath
