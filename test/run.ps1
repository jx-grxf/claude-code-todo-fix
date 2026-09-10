#Requires -Version 5.1
# Runs install.ps1 and uninstall.ps1 against throwaway config directories, with
# the same PowerShell that runs this file. If Python 3 is available, also checks
# that install.ps1 and install.sh write byte-identical files.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$shell = (Get-Process -Id $PID).Path
$work = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'todo-fix-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding $false
$bom = [string][char]0xFEFF
# JSON escapes are assembled at runtime so this file stays plain ASCII.
$u = '\' + 'u'
$script:failures = 0

function Assert-That([string] $Name, [bool] $Condition) {
    if ($Condition) {
        Write-Host "  ok    $Name"
    } else {
        Write-Host "  FAIL  $Name"
        $script:failures += 1
    }
}

function Test-Equal([string] $A, [string] $B) {
    # -eq and -ceq are culture-aware and would ignore a byte order mark.
    return [string]::Equals($A, $B, [StringComparison]::Ordinal)
}

function Write-Fixture([string] $Path, [string] $Text) {
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Read-Raw([string] $Path) {
    # Decodes without dropping a byte order mark, so it shows up in comparisons.
    return $utf8.GetString([System.IO.File]::ReadAllBytes($Path))
}

function Get-BackupCount([string] $Dir) {
    return @(Get-ChildItem -LiteralPath $Dir -Force -Filter '*.bak-*').Count
}

function Test-SameContent([string] $A, [string] $B) {
    $aExists = [System.IO.File]::Exists($A)
    if ($aExists -ne [System.IO.File]::Exists($B)) { return $false }
    if (-not $aExists) { return $true }
    return Test-Equal ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($A))) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($B)))
}

function Invoke-Child([string] $FileName, [string] $Arguments, [string] $ConfigDir, [string] $WorkingDirectory) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FileName
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $ConfigDir
    if ($WorkingDirectory) {
        $info.WorkingDirectory = $WorkingDirectory
    }
    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $stdout.Result
        Error = $stderr
    }
}

function Invoke-Fix([string] $Action, [string] $ConfigDir, [string] $WorkingDirectory) {
    $script = [System.IO.Path]::Combine($root, "$Action.ps1")
    return Invoke-Child $shell ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script) $ConfigDir $WorkingDirectory
}

function Find-Python {
    foreach ($name in 'python3', 'python', 'py') {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { continue }
        $prefix = ''
        if ($name -eq 'py') { $prefix = '-3 ' }
        # Running each candidate skips the Microsoft Store placeholders on Windows.
        $probe = Invoke-Child $command.Source ($prefix + '-c "import sys; sys.exit(sys.version_info < (3, 7))"') '' ''
        if ($probe.ExitCode -eq 0) {
            return [pscustomobject]@{ Path = $command.Source; Prefix = $prefix }
        }
    }
    return $null
}

$snippetText = (Read-Raw ([System.IO.Path]::Combine($root, 'snippet', 'CLAUDE.md'))).Replace("`r`n", "`n")
$block = $snippetText.Trim() + "`n"
$flagOnly = "{`n  `"env`": {`n    `"CLAUDE_CODE_ENABLE_TODO_TOOLS`": `"1`"`n  }`n}`n"

[void][System.IO.Directory]::CreateDirectory($work)
try {
    Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

    Write-Host 'fresh config directory'
    $dir = Join-Path $work 'fresh'
    $settings = Join-Path $dir 'settings.json'
    $memory = Join-Path $dir 'CLAUDE.md'
    $run = Invoke-Fix 'install' $dir
    Assert-That 'install succeeds' ($run.ExitCode -eq 0 -and $run.Error.Length -eq 0)
    Assert-That 'flag is set' (Test-Equal (Read-Raw $settings) $flagOnly)
    Assert-That 'rule added once' (Test-Equal (Read-Raw $memory) $block)
    Assert-That 'no backups for new files' ((Get-BackupCount $dir) -eq 0)
    Assert-That 'asks for a restart' ($run.Output.Contains('Restart Claude Code'))
    $run = Invoke-Fix 'install' $dir
    Assert-That 'rerun leaves settings.json alone' (Test-Equal (Read-Raw $settings) $flagOnly)
    Assert-That 'rerun leaves CLAUDE.md alone' (Test-Equal (Read-Raw $memory) $block)
    Assert-That 'rerun writes no backups' ((Get-BackupCount $dir) -eq 0)
    Assert-That 'rerun asks for nothing' ($run.ExitCode -eq 0 -and -not $run.Output.Contains('Restart'))
    $run = Invoke-Fix 'uninstall' $dir
    Assert-That 'uninstall succeeds' ($run.ExitCode -eq 0)
    Assert-That 'uninstall leaves empty settings' (Test-Equal (Read-Raw $settings) "{}`n")
    Assert-That 'uninstall empties CLAUDE.md' (Test-Equal (Read-Raw $memory) '')

    Write-Host 'existing settings and rules'
    $dir = Join-Path $work 'existing'
    $settings = Join-Path $dir 'settings.json'
    $memory = Join-Path $dir 'CLAUDE.md'
    $originalSettings = "{`n  `"model`": `"opus`",`n  `"env`": { `"FOO`": `"bar`" },`n  `"permissions`": { `"allow`": [`"Bash(git status)`"] }`n}`n"
    $originalMemory = "# My rules`n`n- Keep answers short.`n"
    Write-Fixture $settings $originalSettings
    Write-Fixture $memory $originalMemory
    $run = Invoke-Fix 'install' $dir
    Assert-That 'install succeeds' ($run.ExitCode -eq 0)
    Assert-That 'other settings kept' (Test-Equal (Read-Raw $settings) ("{`n  `"model`": `"opus`",`n  `"env`": {`n    `"FOO`": `"bar`",`n" +
        "    `"CLAUDE_CODE_ENABLE_TODO_TOOLS`": `"1`"`n  },`n  `"permissions`": {`n    `"allow`": [`n      `"Bash(git status)`"`n    ]`n  }`n}`n"))
    Assert-That 'rule appended after a blank line' (Test-Equal (Read-Raw $memory) ($originalMemory + "`n" + $block))
    Assert-That 'both files backed up' ((Get-BackupCount $dir) -eq 2)
    $backup = @(Get-ChildItem -LiteralPath $dir -Force -Filter 'settings.json.bak-*')[0].FullName
    Assert-That 'backup holds the old settings' (Test-Equal (Read-Raw $backup) $originalSettings)
    $run = Invoke-Fix 'uninstall' $dir
    Assert-That 'uninstall restores settings' (Test-Equal (Read-Raw $settings) ("{`n  `"model`": `"opus`",`n  `"env`": {`n    `"FOO`": `"bar`"`n  },`n" +
        "  `"permissions`": {`n    `"allow`": [`n      `"Bash(git status)`"`n    ]`n  }`n}`n"))
    Assert-That 'uninstall restores CLAUDE.md' (Test-Equal (Read-Raw $memory) $originalMemory)

    Write-Host 'outdated and duplicate rule blocks'
    $dir = Join-Path $work 'outdated'
    $memory = Join-Path $dir 'CLAUDE.md'
    $old = "<!-- claude-code-todo-fix:start -->`nold rule`n<!-- claude-code-todo-fix:end -->`n"
    Write-Fixture $memory ("# Rules`n`n" + $old + "`n- Other rule.`n`n" + $old)
    $run = Invoke-Fix 'install' $dir
    $text = Read-Raw $memory
    Assert-That 'old rule replaced' (-not $text.Contains('old rule'))
    Assert-That 'one block left' (([regex]::Matches($text, 'claude-code-todo-fix:start')).Count -eq 1)
    Assert-That 'text around the block kept' (Test-Equal $text ("# Rules`n`n" + $block + "`n- Other rule.`n"))

    Write-Host 'line endings and byte order mark'
    $dir = Join-Path $work 'crlf'
    $settings = Join-Path $dir 'settings.json'
    $memory = Join-Path $dir 'CLAUDE.md'
    Write-Fixture $settings ($bom + "{`r`n  `"model`": `"opus`"`r`n}`r`n")
    $originalMemory = "# Rules`r`n`r`n- Keep answers short."
    Write-Fixture $memory $originalMemory
    $run = Invoke-Fix 'install' $dir
    Assert-That 'install succeeds' ($run.ExitCode -eq 0)
    Assert-That 'settings.json keeps BOM and CRLF' (Test-Equal (Read-Raw $settings) ($bom + "{`r`n  `"model`": `"opus`",`r`n  `"env`": {`r`n" +
        "    `"CLAUDE_CODE_ENABLE_TODO_TOOLS`": `"1`"`r`n  }`r`n}`r`n"))
    Assert-That 'CLAUDE.md keeps CRLF' (Test-Equal (Read-Raw $memory) ($originalMemory + "`r`n`r`n" + $block.Replace("`n", "`r`n")))
    $run = Invoke-Fix 'uninstall' $dir
    Assert-That 'uninstall restores CLAUDE.md' (Test-Equal (Read-Raw $memory) ($originalMemory + "`r`n"))

    Write-Host 'symlinked settings.json'
    $dir = Join-Path $work 'symlink'
    $dotfiles = Join-Path $work 'dotfiles'
    $target = Join-Path $dotfiles 'settings.json'
    $link = Join-Path $dir 'settings.json'
    Write-Fixture $target "{`"model`": `"opus`"}`n"
    [void][System.IO.Directory]::CreateDirectory($dir)
    $linked = $false
    try {
        [void](New-Item -ItemType SymbolicLink -Path $link -Value $target -ErrorAction Stop)
        $linked = $true
    } catch {
        Write-Host '  skip  cannot create symlinks here'
    }
    if ($linked) {
        $run = Invoke-Fix 'install' $dir
        Assert-That 'install succeeds' ($run.ExitCode -eq 0)
        Assert-That 'symlink kept' ((Get-Item -LiteralPath $link -Force).LinkType -eq 'SymbolicLink')
        Assert-That 'link target updated' ((Read-Raw $target).Contains('"CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"'))
        Assert-That 'backup next to the link' ((Get-BackupCount $dir) -eq 1)
        Assert-That 'no backup inside dotfiles' ((Get-BackupCount $dotfiles) -eq 0)
    }

    Write-Host 'relative CLAUDE_CONFIG_DIR'
    $run = Invoke-Fix 'install' 'relative' $work
    Assert-That 'resolved against the working directory' ($run.ExitCode -eq 0 -and
        [System.IO.File]::Exists([System.IO.Path]::Combine($work, 'relative', 'settings.json')))

    Write-Host 'numbers and escapes'
    $dir = Join-Path $work 'values'
    $settings = Join-Path $dir 'settings.json'
    Write-Fixture $settings ("{`"a`": [1.50, 1e3, -0, 2.5E-3], `"s`": `"caf${u}00e9 \/ tab\t quote\`" ${u}001f`"}")
    $run = Invoke-Fix 'install' $dir
    $text = Read-Raw $settings
    Assert-That 'numbers kept as written' ($text.Contains("    1.50,`n    1e3,`n    -0,`n    2.5E-3`n"))
    Assert-That 'escapes written like Python' ($text.Contains("`"s`": `"caf$([char]0xE9) / tab\t quote\`" ${u}001f`""))

    Write-Host 'invalid files are left alone'
    $cases = [ordered]@{
        'trailing comma' = @('{ "model": "opus", }', 'is not valid JSON')
        'comment' = @("{`n  // note`n  `"model`": `"opus`"`n}", 'is not valid JSON')
        'NaN' = @('{ "n": NaN }', 'is not valid JSON')
        'single quotes' = @("{ 'model': 'opus' }", 'is not valid JSON')
        'truncated' = @('{ "model": "opus"', 'is not valid JSON')
        'top-level array' = @('[]', 'must contain a JSON object')
        'env is not an object' = @('{ "env": "x" }', '"env" in')
    }
    foreach ($case in $cases.Keys) {
        $dir = Join-Path $work ('invalid-' + ($case -replace '[^a-z]', '-'))
        $settings = Join-Path $dir 'settings.json'
        Write-Fixture $settings $cases[$case][0]
        $run = Invoke-Fix 'install' $dir
        Assert-That "$case`: install refuses" ($run.ExitCode -eq 1 -and
            $run.Error.StartsWith('error: ', [StringComparison]::Ordinal) -and $run.Error.Contains($cases[$case][1]))
        Assert-That "$case`: nothing written" ((Test-Equal (Read-Raw $settings) $cases[$case][0]) -and
            -not (Test-Path -LiteralPath (Join-Path $dir 'CLAUDE.md')) -and (Get-BackupCount $dir) -eq 0)
    }
    $run = Invoke-Fix 'uninstall' (Join-Path $work 'invalid-trailing-comma')
    Assert-That 'uninstall refuses too' ($run.ExitCode -eq 1)

    $dir = Join-Path $work 'utf16'
    $settings = Join-Path $dir 'settings.json'
    $memory = Join-Path $dir 'CLAUDE.md'
    Write-Fixture $settings "{}`n"
    [System.IO.File]::WriteAllText($memory, "# Rules`r`n", [System.Text.Encoding]::Unicode)
    $memoryBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($memory))
    $run = Invoke-Fix 'install' $dir
    Assert-That 'UTF-16 CLAUDE.md: install refuses' ($run.ExitCode -eq 1 -and $run.Error.Contains('is not UTF-8 text'))
    Assert-That 'UTF-16 CLAUDE.md: settings.json untouched' ((Test-Equal (Read-Raw $settings) "{}`n") -and (Get-BackupCount $dir) -eq 0)
    Assert-That 'UTF-16 CLAUDE.md: file untouched' (Test-Equal ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($memory))) $memoryBefore)

    Write-Host 'same result as install.sh'
    $python = Find-Python
    if (-not $python) {
        Write-Host '  skip  no Python 3.7+ found'
    } else {
        $fixtures = [ordered]@{
            'empty' = @($null, $null)
            'existing' = @($originalSettings, "# My rules`n`n- Keep answers short.")
            'strings' = @(("{`"allow`": [`"Bash(echo 'hi' <x> & y)`", `"caf${u}00e9 \/ \t \`" \\ ${u}0001 ${u}d83d${u}de00`"]," +
                " `"dup`": 1, `"dup`": 2, `"`": `"empty key`", `"n`": [1, -3, 2.5, true, false, null, {}, []]," +
                " `"unicode`": `"$([char]0xFC)`"}"), $null)
            'crlf and bom' = @(($bom + "{`r`n  `"env`": {}`r`n}`r`n"), "# Rules`r`n")
            'flag as number' = @('{"env": {"CLAUDE_CODE_ENABLE_TODO_TOOLS": 1, "B": "2"}}', $null)
            'duplicate blocks' = @($null, ("# Rules`n`n" + $old + "`nmiddle`n`n" + $old))
        }
        $core = [System.IO.Path]::Combine($root, 'lib', 'todo_fix.py')
        foreach ($name in $fixtures.Keys) {
            $slug = $name -replace '[^a-z]', '-'
            $dirs = @((Join-Path $work "parity-ps-$slug"), (Join-Path $work "parity-py-$slug"))
            foreach ($d in $dirs) {
                [void][System.IO.Directory]::CreateDirectory($d)
                if ($null -ne $fixtures[$name][0]) { Write-Fixture (Join-Path $d 'settings.json') $fixtures[$name][0] }
                if ($null -ne $fixtures[$name][1]) { Write-Fixture (Join-Path $d 'CLAUDE.md') $fixtures[$name][1] }
            }
            foreach ($action in 'install', 'uninstall') {
                $ps = Invoke-Fix $action $dirs[0]
                $py = Invoke-Child $python.Path ('{0}"{1}" {2}' -f $python.Prefix, $core, $action) $dirs[1] ''
                $same = $ps.ExitCode -eq 0 -and $py.ExitCode -eq 0
                foreach ($file in 'settings.json', 'CLAUDE.md') {
                    $same = $same -and (Test-SameContent (Join-Path $dirs[0] $file) (Join-Path $dirs[1] $file))
                }
                Assert-That "$name`: $action" $same
            }
        }
    }

    Write-Host 'PowerShell files are ASCII'
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1') {
        $nonAscii = @([System.IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }).Count
        Assert-That $file.Name ($nonAscii -eq 0)
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -ne 0) {
    Write-Host "$($script:failures) check(s) failed"
    exit 1
}
Write-Host 'all checks passed'
