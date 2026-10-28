$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-MsixDataPath','Get-PackageCachePath','Get-FirstValue','Get-CodeSessionRoot','Get-CodeSessions')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('claude-msixdata-test-' + [guid]::NewGuid().ToString('N'))
$originalLocal = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = Join-Path $fixture 'Local'
    $family = 'Claude_test'
    $legacy = Join-Path $env:LOCALAPPDATA "Packages\$family\LocalCache\Roaming\Claude"
    $moved  = Join-Path $env:LOCALAPPDATA "Claude-Data\$family"
    New-Item -ItemType Directory -Path $legacy -Force | Out-Null

    # Older builds keep the data inside the package.
    Assert ((Get-MsixDataPath -Family $family) -eq $legacy) 'Old build: package folder expected'

    # Newer builds move it to %LOCALAPPDATA%\Claude-Data\<family> and leave a marker behind.
    New-Item -ItemType Directory -Path $moved -Force | Out-Null
    Assert ((Get-MsixDataPath -Family $family) -eq $legacy) 'An empty Claude-Data folder must not win'
    Set-Content -LiteralPath (Join-Path $moved 'config.json') -Value '{}'
    Assert ((Get-MsixDataPath -Family $family) -eq $moved) 'Moved data folder not found'

    # The package cache is derived from the family, not from where the data happens to be.
    $cache = Join-Path $env:LOCALAPPDATA "Packages\$family\LocalCache"
    $script:ClaudeApp = [pscustomobject]@{Kind='Msix'; AppUserModelId="$family!Claude"; DefaultProfilePath=$moved}
    Assert ((Get-PackageCachePath) -eq $cache) 'Package cache wrong for moved data'
    $script:ClaudeApp = [pscustomobject]@{Kind='Msix'; AppUserModelId=$null; DefaultProfilePath=(Join-Path $cache 'Roaming\Claude')}
    Assert ((Get-PackageCachePath) -eq $cache) 'Package cache wrong without a family'

    # The original account's chats are listed from the moved folder.
    $store = Join-Path $moved 'claude-code-sessions\acct\org'
    New-Item -ItemType Directory -Path $store -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $store 'local_abc12345.json'), '{"title":"Hello","cwd":"C:\\p"}')
    $script:ClaudeApp = [pscustomobject]@{Kind='Msix'; AppUserModelId="$family!Claude"; DefaultProfilePath=$moved}
    $default = [pscustomobject]@{Path=$moved}
    Assert (@(Get-CodeSessions -Source $default).Count -eq 1) 'Default chat missing in moved folder'
    Write-Output 'PASS: package data folder (old and moved), package cache, default chats in moved folder.'
} finally {
    $env:LOCALAPPDATA = $originalLocal
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected fixture path' }
    if (Test-Path -LiteralPath $resolved) {
        Get-ChildItem -LiteralPath $resolved -Recurse -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
        Get-ChildItem -LiteralPath $resolved -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
        Remove-Item -LiteralPath $resolved
    }
}
