Set-StrictMode -Version Latest

function Get-TranscribeProjectConfig {
    $path = if ($env:TRANSCRIBE_CONFIG) { $env:TRANSCRIBE_CONFIG } else { Join-Path $PSScriptRoot 'transcribe.config.json' }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $resolved = (Resolve-Path -LiteralPath $path).Path
    $config = Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
    $config | Add-Member -NotePropertyName '_base_dir' -NotePropertyValue ([IO.Path]::GetDirectoryName($resolved)) -Force
    return $config
}

function Get-TranscribeConfigValue {
    param($Config, [Parameter(Mandatory=$true)][string]$Name)
    if ($null -eq $Config) { return $null }
    $value = $Config
    foreach ($part in $Name.Split('.')) {
        $property = $value.PSObject.Properties[$part]
        if ($null -eq $property) { return $null }
        $value = $property.Value
        if ($null -eq $value) { return $null }
    }
    return $value
}

function Resolve-TranscribeConfiguredPath {
    param([string]$Value, $Config)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $candidate = $Value
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        $base = if ($Config -and $Config.PSObject.Properties['_base_dir']) { [string]$Config._base_dir } else { $PSScriptRoot }
        $candidate = Join-Path $base $candidate
    }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    return $null
}

function Find-TranscribeFile {
    param([string[]]$Candidates, $Config)
    foreach ($candidate in $Candidates) {
        $resolved = Resolve-TranscribeConfiguredPath -Value $candidate -Config $Config
        if ($resolved) { return $resolved }
    }
    return $null
}

function Get-TranscribeApiConfiguration {
    $config = Get-TranscribeProjectConfig
    $url = if ($env:TRANSCRIBE_API_URL) { $env:TRANSCRIBE_API_URL } else { [string](Get-TranscribeConfigValue $config 'api.url') }
    $key = if ($env:TRANSCRIBE_API_KEY) { $env:TRANSCRIBE_API_KEY } else { [string](Get-TranscribeConfigValue $config 'api.key') }
    $settings = Join-Path $env:APPDATA 'Subtitle Edit\Settings.json'
    if (([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($key)) -and (Test-Path -LiteralPath $settings -PathType Leaf)) {
        $subtitleEdit = (Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json).AutoTranslate
        if ([string]::IsNullOrWhiteSpace($url)) { $url = [string]$subtitleEdit.OpenAiCompatibleUrl }
        if ([string]::IsNullOrWhiteSpace($key)) { $key = [string]$subtitleEdit.OpenAiCompatibleApiKey }
    }
    if ([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($key)) {
        throw 'API configuration is missing. Use environment variables, transcribe.config.json, or Subtitle Edit settings.'
    }
    return [pscustomobject]@{ Url=$url; Key=$key }
}

Export-ModuleMember -Function Get-TranscribeProjectConfig,Get-TranscribeConfigValue,Resolve-TranscribeConfiguredPath,Find-TranscribeFile,Get-TranscribeApiConfiguration
