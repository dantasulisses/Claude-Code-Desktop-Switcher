$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-ProfileCodeConfig', 'Test-WhisprOn', 'Test-WhisprFollow', 'Get-WhisprPath', 'Install-WhisprProxy',
        'Get-WhisprAccountId', 'Write-WhisprAccountFile', 'Set-WhisprAccount', 'Update-WhisprOnSwitch', 'Write-WhisprLog')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }

$script:DefaultName = 'Default'
$script:Settings = @{}
function Get-Setting { param($Name) return $script:Settings[$Name] }
function Set-Setting { param($Name, $Value) $script:Settings[$Name] = $Value }
$script:Profiles = @('Default', 'Work')
function Resolve-ClaudeProfile {
    param($Name, [switch]$SkipStatus)
    if ($script:Profiles -contains $Name) { return [pscustomobject]@{ Id = $Name; Name = "Label $Name" } }
    return $null
}
$userHome = [Environment]::GetFolderPath('UserProfile')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('openwhispr-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:WhisprAccountFile = Join-Path $tmp '.openwhispr\account.json'
$script:LogPath = Join-Path $tmp 'switcher-error.log'
try {
    # Defaults: switched on and following, until the user says otherwise.
    Assert (Test-WhisprOn) 'OpenWhispr should be on by default'
    Assert (Test-WhisprFollow) 'OpenWhispr should follow by default'
    $script:Settings['OpenWhisprOn'] = $false
    Assert (-not (Test-WhisprOn)) 'Switching it off was not honoured'
    $script:Settings['ClaudeWhisprOn'] = $true
    Assert (-not (Test-WhisprOn)) 'The old ClaudeWhispr key must be ignored'

    # The proxy ships next to the script, in openwhispr\; without server.mjs the feature is hidden.
    $app = Join-Path $tmp 'switcher'
    $script:ScriptPath = Join-Path $app 'ClaudeSwitcher.ps1'
    New-Item -ItemType Directory -Path (Join-Path $app 'openwhispr') -Force | Out-Null
    Assert ($null -eq (Get-WhisprPath)) 'A proxy folder without server.mjs must not count'
    Set-Content -LiteralPath (Join-Path $app 'openwhispr\server.mjs') -Value '//'
    Set-Content -LiteralPath (Join-Path $app 'openwhispr\account.mjs') -Value '//'
    Assert ((Get-WhisprPath) -eq (Join-Path $app 'openwhispr')) 'The bundled proxy was not found'
    # OpenWhisprProxyPath points somewhere else, for development; a wrong one hides the feature.
    $dev = Join-Path $tmp 'dev'
    New-Item -ItemType Directory -Path $dev | Out-Null
    $script:Settings['OpenWhisprProxyPath'] = $dev
    Assert ($null -eq (Get-WhisprPath)) 'An override without server.mjs must not count'
    Set-Content -LiteralPath (Join-Path $dev 'server.mjs') -Value '//'
    Assert ((Get-WhisprPath) -eq $dev) 'The override was ignored'
    $script:Settings.Remove('OpenWhisprProxyPath')

    # -Install copies the .mjs files and drops ones that are gone from the source.
    $installed = Join-Path $tmp 'installed\openwhispr'
    New-Item -ItemType Directory -Path $installed -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $installed 'old.mjs') -Value '//'
    Assert (Install-WhisprProxy -From (Join-Path $app 'openwhispr') -To $installed) 'Proxy not installed'
    $names = @(Get-ChildItem -LiteralPath $installed -File | ForEach-Object { $_.Name } | Sort-Object)
    Assert (($names -join ',') -eq 'account.mjs,server.mjs') "Wrong installed files: $($names -join ',')"
    Assert (-not (Install-WhisprProxy -From $tmp -To (Join-Path $tmp 'nowhere'))) 'A source without the proxy must be skipped'
    Assert (-not (Test-Path -LiteralPath (Join-Path $tmp 'nowhere'))) 'Nothing should be created for a missing source'

    # The account: what was chosen, or Default when it is missing or gone.
    Assert ((Get-WhisprAccountId -KnownIds @('Default', 'Work')) -eq 'Default') 'Nothing chosen must mean Default'
    $script:Settings['OpenWhisprAccount'] = 'Work'
    Assert ((Get-WhisprAccountId -KnownIds @('Default', 'Work')) -eq 'Work') 'The chosen account was not used'
    Assert ((Get-WhisprAccountId -KnownIds @('Default')) -eq 'Default') 'A deleted account must fall back to Default'

    # account.json: the account's CLAUDE_CONFIG_DIR, null for Default, written only on change.
    Assert (Write-WhisprAccountFile -Id 'Work' -Label 'Work') 'First write not reported'
    $j = Get-Content -LiteralPath $script:WhisprAccountFile -Raw | ConvertFrom-Json
    Assert ($j.configDir -eq (Join-Path $userHome '.claude-Work') -and $j.label -eq 'Work' -and $j.profileId -eq 'Work') 'Wrong account.json for Work'
    Assert (-not (Write-WhisprAccountFile -Id 'Work' -Label 'Work')) 'Unchanged account rewritten'
    $bytes = [IO.File]::ReadAllBytes($script:WhisprAccountFile)
    Assert (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'account.json must be written without a BOM'
    Write-WhisprAccountFile -Id 'Default' -Label 'Default' | Out-Null
    $j = Get-Content -LiteralPath $script:WhisprAccountFile -Raw | ConvertFrom-Json
    Assert ($null -eq $j.configDir) 'Default must be null (the plain ~\.claude)'
    Assert (-not (Test-Path -LiteralPath ($script:WhisprAccountFile + '.tmp'))) 'Temp file left behind'
    $script:Settings['ProfileCode'] = [pscustomobject]@{ Default = [pscustomobject]@{ ConfigDir = 'C:\cfg\personal' } }
    Write-WhisprAccountFile -Id 'Default' | Out-Null
    Assert ((Get-Content -LiteralPath $script:WhisprAccountFile -Raw | ConvertFrom-Json).configDir -eq 'C:\cfg\personal') 'A ProfileCode override was ignored'
    $script:Settings.Remove('ProfileCode')

    # Set-WhisprAccount remembers the choice; an account that is gone becomes Default.
    Assert ((Set-WhisprAccount -Id 'Work') -eq 'Label Work' -and $script:Settings['OpenWhisprAccount'] -eq 'Work') 'Work not set'
    Assert ((Set-WhisprAccount -Id 'Gone') -eq 'Label Default' -and $script:Settings['OpenWhisprAccount'] -eq 'Default') 'A missing account must become Default'

    # Following a switch: only when the proxy is there and following is on; never raises.
    $script:Settings['OpenWhisprFollow'] = $false
    Update-WhisprOnSwitch -Id 'Work'
    Assert ($script:Settings['OpenWhisprAccount'] -eq 'Default') 'Followed a switch with following off'
    $script:Settings['OpenWhisprFollow'] = $true
    Update-WhisprOnSwitch -Id 'Work'
    Assert ($script:Settings['OpenWhisprAccount'] -eq 'Work') 'Did not follow the switch'
    function Resolve-ClaudeProfile { param($Name, [switch]$SkipStatus) throw 'profiles unreadable' }
    Update-WhisprOnSwitch -Id 'Default'
    Assert ((Get-Content -LiteralPath $script:LogPath -Raw) -match 'OpenWhispr: .*profiles unreadable') 'A failure must be logged, not raised'
    Remove-Item -LiteralPath (Join-Path $app 'openwhispr\server.mjs')
    Update-WhisprOnSwitch -Id 'Default'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

'OpenWhispr tests passed'
