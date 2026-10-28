$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-JsoncToken', 'Get-JsoncChildren', 'Update-VsCodeSettingsText', 'Set-VsCodeClaudeConfigDir',
        'Get-ProfileCodeConfig', 'Get-ClaudeAccountInfo', 'Test-VsCodeSyncOn', 'Sync-VsCodeAccount', 'Start-ClaudeProfile')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }

$work = 'C:\Users\someone\.claude-work'

# VS Code settings may hold comments and trailing commas, which ConvertFrom-Json refuses.
# The fixtures never put // inside a string, so this plain strip is enough to read them back.
function Read-Jsonc([string]$Text) {
    $t = $Text -replace '(?m)//.*$', '' -replace '(?s)/\*.*?\*/', ''
    $t = $t -replace ',(\s*[}\]])', '$1'
    return ($t | ConvertFrom-Json)
}
function Get-EnvEntry([string]$Text) {
    # The comma keeps a single entry (or none) an array, so .Count works on PowerShell 5.1.
    return ,@((Read-Jsonc $Text).'claudeCode.environmentVariables')
}

# Empty or missing file: a fresh object with just our entry.
$out = Update-VsCodeSettingsText -Text '' -ConfigDir $work
$e = Get-EnvEntry $out
Assert ($e.Count -eq 1 -and $e[0].name -eq 'CLAUDE_CONFIG_DIR' -and $e[0].value -eq $work) 'Empty text: entry not written, or the path was not escaped'
Assert ($out -match [regex]::Escape('C:\\Users\\someone\\.claude-work')) 'Backslashes not escaped in the file text'
Assert ((Update-VsCodeSettingsText -Text '' -ConfigDir $null) -eq '') 'Removing from an empty file must leave it empty'
Assert ((Update-VsCodeSettingsText -Text "  `r`n" -ConfigDir $null) -eq "  `r`n") 'Removing from a blank file must leave it as it was'

# Other settings stay, and the key is added.
$text = "{`n    `"editor.fontSize`": 14,`n    `"files.autoSave`": `"afterDelay`"`n}`n"
$out = Update-VsCodeSettingsText -Text $text -ConfigDir $work
$j = Read-Jsonc $out
Assert ($j.'editor.fontSize' -eq 14 -and $j.'files.autoSave' -eq 'afterDelay') 'Other settings lost'
Assert ((Get-EnvEntry $out)[0].value -eq $work) 'Entry not added next to other settings'
Assert ($out.StartsWith("{`n    `"editor.fontSize`": 14,")) 'Existing text moved'

# Comments and trailing commas survive; the indent of the file is reused.
$text = "{`r`n`t// keep me`r`n`t`"a`": 1, /* and me */`r`n`t`"b`": [1, 2,],`r`n}`r`n"
$out = Update-VsCodeSettingsText -Text $text -ConfigDir $work
Assert ($out -match '// keep me' -and $out -match '/\* and me \*/') 'Comments lost'
Assert ($out -match "`r`n`t`"claudeCode.environmentVariables`"") 'Tab indent or CRLF not reused'
Assert ($out -notmatch "[^`r]`n") 'A bare LF was written into a CRLF file'
Assert ((Read-Jsonc $out).a -eq 1 -and (Get-EnvEntry $out)[0].value -eq $work) 'Result is not valid or lost a value'

# A trailing comma after the last setting is kept valid.
$text = "{`n    `"a`": 1,`n}"
$out = Update-VsCodeSettingsText -Text $text -ConfigDir $work
Assert ((Read-Jsonc $out).a -eq 1 -and (Get-EnvEntry $out).Count -eq 1) 'Trailing comma at the root broke the file'

# A comment trailing the last setting stays on its line.
$text = "{`n    `"a`": 1 // note`n}"
$out = Update-VsCodeSettingsText -Text $text -ConfigDir $work
Assert ($out -match '"a": 1, // note') 'Trailing comment moved off its setting'

# Other variables stay; ours is added after them, or replaced in place.
$text = '{ "claudeCode.environmentVariables": [ { "name": "FOO", "value": "bar" } ] }'
$out = Update-VsCodeSettingsText -Text $text -ConfigDir $work
$e = Get-EnvEntry $out
Assert ($e.Count -eq 2 -and $e[0].name -eq 'FOO' -and $e[1].name -eq 'CLAUDE_CONFIG_DIR') 'Other variable lost or ours not appended'
$other = 'D:\other'
$out2 = Update-VsCodeSettingsText -Text $out -ConfigDir $other
$e = Get-EnvEntry $out2
Assert ($e.Count -eq 2 -and $e[1].value -eq $other -and $e[0].value -eq 'bar') 'Existing entry not replaced in place'
Assert ((Update-VsCodeSettingsText -Text $out -ConfigDir $work) -ceq $out) 'Writing the same value again changed the text'

# Empty array.
$out = Update-VsCodeSettingsText -Text '{ "claudeCode.environmentVariables": [] }' -ConfigDir $work
Assert ((Get-EnvEntry $out).Count -eq 1) 'Entry not added to an empty array'

# Removal takes only our entry, wherever it sits.
foreach ($layout in @(
    '[ { "name": "CLAUDE_CONFIG_DIR", "value": "x" }, { "name": "FOO", "value": "1" } ]',
    '[ { "name": "FOO", "value": "1" }, { "name": "CLAUDE_CONFIG_DIR", "value": "x" } ]',
    '[ { "name": "FOO", "value": "1" }, { "name": "CLAUDE_CONFIG_DIR", "value": "x" }, { "name": "BAR", "value": "2" } ]',
    '[ { "name": "FOO", "value": "1" }, { "name": "CLAUDE_CONFIG_DIR", "value": "x" }, ]')) {
    $out = Update-VsCodeSettingsText -Text ('{ "k": 1, "claudeCode.environmentVariables": ' + $layout + ' }') -ConfigDir $null
    $e = Get-EnvEntry $out
    Assert (-not ($e | Where-Object { $_.name -eq 'CLAUDE_CONFIG_DIR' })) "Entry not removed from $layout"
    Assert ($e.Count -ge 1 -and ($e | Where-Object { $_.name -eq 'FOO' }).value -eq '1') "Other variable lost removing from $layout"
    Assert ((Read-Jsonc $out).k -eq 1) 'Removal lost another setting'
}
$only = '{ "claudeCode.environmentVariables": [ { "name": "CLAUDE_CONFIG_DIR", "value": "x" } ] }'
$out = Update-VsCodeSettingsText -Text $only -ConfigDir $null
Assert ((Get-EnvEntry $out).Count -eq 0) 'Sole entry not removed'
$untouched = "{ // c`n  `"a`": 1 }"
Assert ((Update-VsCodeSettingsText -Text $untouched -ConfigDir $null) -ceq $untouched) 'Removing something absent changed the text'

# Anything it cannot read is refused, not guessed at.
foreach ($bad in @('{ "a": 1', '{ "a": "unterminated }', '[1, 2]', '{ "a" 1 }', '{ /* open ', '{ "claudeCode.environmentVariables": "text" }', '{ "a": 1 } extra', 'not json')) {
    $threw = $false
    try { Update-VsCodeSettingsText -Text $bad -ConfigDir $work | Out-Null } catch { $threw = $true }
    Assert $threw "Malformed settings accepted: $bad"
}

# The file: created when missing, backed up before a change, left alone when unchanged or unreadable.
$dir = Join-Path ([IO.Path]::GetTempPath()) ('vscode-sync-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $script:SwitcherHome = Join-Path $dir 'home'
    $file = Join-Path $dir 'User\settings.json'
    Assert ((Set-VsCodeClaudeConfigDir -ConfigDir $null -SettingsFile $file) -eq 'unchanged') 'Removing from a missing file must do nothing'
    Assert (-not (Test-Path -LiteralPath $file)) 'Removing created a file'
    Assert ((Set-VsCodeClaudeConfigDir -ConfigDir $work -SettingsFile $file) -eq 'updated') 'Missing file not created'
    Assert ((Get-EnvEntry ([IO.File]::ReadAllText($file)))[0].value -eq $work) 'Created file has the wrong content'
    Assert (-not ([IO.File]::ReadAllBytes($file)[0] -eq 0xEF)) 'File written with a byte order mark'
    Assert ((Set-VsCodeClaudeConfigDir -ConfigDir $work -SettingsFile $file) -eq 'unchanged') 'Same value must report unchanged'
    Assert ((Set-VsCodeClaudeConfigDir -ConfigDir 'D:\two' -SettingsFile $file) -eq 'updated') 'Changed value not written'
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $script:SwitcherHome 'vscode-backups') -File)
    Assert ($backups.Count -eq 1) 'No backup kept before the change'
    Assert ((Get-EnvEntry ([IO.File]::ReadAllText($backups[0].FullName)))[0].value -eq $work) 'Backup does not hold the earlier content'

    [IO.File]::WriteAllText($file, '{ "a": 1')
    $threw = $false
    try { Set-VsCodeClaudeConfigDir -ConfigDir $work -SettingsFile $file | Out-Null } catch { $threw = $true }
    Assert $threw 'Unreadable settings must raise'
    Assert (([IO.File]::ReadAllText($file)) -ceq '{ "a": 1') 'Unreadable settings were modified'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- which folder each account uses, and who is signed in there

$script:DefaultName = 'Default'
$script:Settings = @{}
function Get-Setting { param($Name) return $script:Settings[$Name] }
function Set-Setting { param($Name, $Value) $script:Settings[$Name] = $Value }
$userHome = [Environment]::GetFolderPath('UserProfile')

$c = Get-ProfileCodeConfig -Id 'Default'
Assert ($null -eq $c.EnvDir) 'Default must leave CLAUDE_CONFIG_DIR unset'
Assert ($c.Folder -eq (Join-Path $userHome '.claude') -and $c.StateFile -eq (Join-Path $userHome '.claude.json')) 'Default folder or state file wrong'
$c = Get-ProfileCodeConfig -Id 'Work'
Assert ($c.EnvDir -eq (Join-Path $userHome '.claude-Work') -and $c.StateFile -eq (Join-Path $userHome '.claude-Work\.claude.json')) 'Other accounts get ~\.claude-<id>'
$script:Settings = @{ ProfileCode = [pscustomobject]@{ Work = [pscustomobject]@{ ConfigDir = 'D:\cfg\work' } } }
$c = Get-ProfileCodeConfig -Id 'Work'
Assert ($c.EnvDir -eq 'D:\cfg\work' -and $c.Folder -eq 'D:\cfg\work' -and $c.StateFile -eq 'D:\cfg\work\.claude.json') 'ConfigDir override ignored'

$dir = Join-Path ([IO.Path]::GetTempPath()) ('vscode-info-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $state = Join-Path $dir '.claude.json'
    Assert ($null -eq (Get-ClaudeAccountInfo -StateFile $state)) 'No file must mean nobody signed in'
    [IO.File]::WriteAllText($state, '{ "userID": "u", "oauthAccount": { "emailAddress": "me@work.example", "organizationName": "Work Inc", "accountUuid": "x" } }')
    $who = Get-ClaudeAccountInfo -StateFile $state
    Assert ($who.Email -eq 'me@work.example' -and $who.Organization -eq 'Work Inc') 'Email or organization not read'
    [IO.File]::WriteAllText($state, '{ "userID": "u" }')
    Assert ($null -eq (Get-ClaudeAccountInfo -StateFile $state)) 'No oauthAccount must mean nobody signed in'
    # Text that is not valid JSON (or too large for 5.1) still gives the two values.
    [IO.File]::WriteAllText($state, '{ broken "oauthAccount": { "emailAddress": "a@b.example", "organizationName": "Org" }')
    $who = Get-ClaudeAccountInfo -StateFile $state
    Assert ($who.Email -eq 'a@b.example' -and $who.Organization -eq 'Org') 'Fallback did not find the values'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- the sync itself: what it asks VS Code for, with the file write stubbed out

$script:Applied = New-Object System.Collections.Generic.List[object]
function Set-VsCodeClaudeConfigDir { param([string]$ConfigDir) $script:Applied.Add($ConfigDir); return 'updated' }
function Resolve-ClaudeProfile { param($Name, [switch]$SkipStatus) return [pscustomobject]@{ Id = $Name; Name = "Label $Name" } }
$script:Opened = New-Object System.Collections.Generic.List[string]
function Open-ClaudeProfileWindow { param($Id) $script:Opened.Add($Id); return 'started' }

$script:Settings = @{}
Assert ($null -eq (Sync-VsCodeAccount -Id 'Work') -and $script:Applied.Count -eq 0) 'Sync off must not touch VS Code'
$msg = Sync-VsCodeAccount -Id 'Work' -Force
Assert ($script:Applied.Count -eq 1 -and $script:Applied[0] -eq (Join-Path $userHome '.claude-Work')) '-Force did not apply the account'
Assert ($msg -match "Label Work" -and $msg -match 'not signed in') 'Message does not name the account and its sign-in state'
Assert ($msg.Length -lt 70) 'Message too long for the status line'
Assert ($script:Settings['CodeAccount'] -eq 'Work') 'Applied account not remembered'

$script:Settings = @{ VsCodeSync = $true }
$script:Applied.Clear()
Sync-VsCodeAccount -Id 'Default' | Out-Null
Assert ($script:Applied.Count -eq 1 -and [string]::IsNullOrEmpty($script:Applied[0])) 'Default must remove the entry'

$script:Settings = @{ VsCodeSync = $true; ProfileCode = [pscustomobject]@{ Work = [pscustomobject]@{ ConfigDir = '~\cfg' } } }
$script:Applied.Clear()
$msg = Sync-VsCodeAccount -Id 'Work'
Assert ($script:Applied.Count -eq 0 -and $msg -match 'full path') 'A relative ConfigDir must be refused without touching VS Code'

# A failing write is reported, never raised: launching must not break because of VS Code.
$script:Settings = @{ VsCodeSync = $true }
function Set-VsCodeClaudeConfigDir { param([string]$ConfigDir) throw 'settings.json is locked' }
$msg = Sync-VsCodeAccount -Id 'Work'
Assert ($msg -match 'Could not update VS Code: settings.json is locked') 'Failure not reported as a message'

# Launching: the window first, then the sync; -NoCodeSync skips it.
function Set-VsCodeClaudeConfigDir { param([string]$ConfigDir) $script:Applied.Add($ConfigDir); return 'unchanged' }
$script:Applied.Clear(); $script:Opened.Clear()
$how = Start-ClaudeProfile -Id 'Work'
Assert ($how -eq 'started' -and $script:Opened[0] -eq 'Work' -and $script:Applied.Count -eq 1) 'Launch did not open the window and sync'
Assert ($script:CodeSyncNote -match 'Label Work') 'Launch left no note'
$script:Applied.Clear()
Start-ClaudeProfile -Id 'Work' -NoCodeSync | Out-Null
Assert ($script:Applied.Count -eq 0 -and $null -eq $script:CodeSyncNote) '-NoCodeSync still synced'

'VsCodeSync tests passed'
