# Dot-sourced by install.ps1 and uninstall.ps1.
#
# Does the same as lib/todo_fix.py, without needing Python: sets
# CLAUDE_CODE_ENABLE_TODO_TOOLS=1 in settings.json and adds the rule from
# snippet/CLAUDE.md to CLAUDE.md, or removes both again. Keep the two in sync.
#
# Runs on Windows PowerShell 5.1 and PowerShell 7, so it avoids newer syntax
# (ternaries, ??, &&) and keeps to ASCII: Windows PowerShell reads scripts
# without a byte order mark in the legacy code page.

$TodoFixKey = 'CLAUDE_CODE_ENABLE_TODO_TOOLS'
$TodoFixValue = '1'
$TodoFixStart = '<!-- claude-code-todo-fix:start -->'
$TodoFixEnd = '<!-- claude-code-todo-fix:end -->'
$TodoFixBlock = [regex]::new(
    [regex]::Escape($TodoFixStart) + '.*?' + [regex]::Escape($TodoFixEnd) + '\n?',
    [System.Text.RegularExpressions.RegexOptions]::Singleline)
$TodoFixStamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)

# A JSON number, kept as written so it round-trips unchanged.
class TodoFixJsonNumber {
    [string] $Text

    TodoFixJsonNumber([string] $text) {
        $this.Text = $text
    }
}

# Strict JSON parser (RFC 8259), like JSON.parse in Claude Code: no comments,
# no trailing commas, no NaN. Objects become ordered, case-sensitive
# dictionaries so key order survives a rewrite.
class TodoFixJsonReader {
    static [regex] $Space = [regex]::new('\G[ \t\r\n]*')
    static [regex] $String = [regex]::new('\G"((?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*)"')
    static [regex] $Number = [regex]::new('\G-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?')
    static [regex] $Literal = [regex]::new('\G(?:true|false|null)')

    [string] $Text
    [int] $Pos

    TodoFixJsonReader([string] $text) {
        $this.Text = $text
        $this.Pos = 0
    }

    [object] ReadDocument() {
        $this.SkipSpace()
        $value = $this.ReadValue()
        $this.SkipSpace()
        if ($this.Pos -lt $this.Text.Length) {
            throw $this.Error('unexpected data after the JSON value')
        }
        return $value
    }

    [string] Error([string] $message) {
        $before = $this.Text.Substring(0, $this.Pos)
        $line = $before.Split([char]10).Length
        $column = $this.Pos - $before.LastIndexOf([char]10)
        return ('{0} at line {1}, column {2}' -f $message, $line, $column)
    }

    # The next character as a code unit, or -1 at the end. Comparing numbers
    # keeps this ordinal: PowerShell's string -eq is culture-aware.
    [int] Peek() {
        if ($this.Pos -lt $this.Text.Length) {
            return [int]$this.Text[$this.Pos]
        }
        return -1
    }

    [void] SkipSpace() {
        $this.Pos += [TodoFixJsonReader]::Space.Match($this.Text, $this.Pos).Length
    }

    [object] ReadValue() {
        $next = $this.Peek()
        if ($next -eq [int][char]'{') { return $this.ReadObject() }
        if ($next -eq [int][char]'[') { return $this.ReadArray() }
        if ($next -eq [int][char]'"') { return $this.ReadString() }
        $match = [TodoFixJsonReader]::Literal.Match($this.Text, $this.Pos)
        if ($match.Success) {
            $this.Pos += $match.Length
            if ($next -eq [int][char]'n') { return $null }
            return ($next -eq [int][char]'t')
        }
        $match = [TodoFixJsonReader]::Number.Match($this.Text, $this.Pos)
        if ($match.Success) {
            $this.Pos += $match.Length
            return [TodoFixJsonNumber]::new($match.Value)
        }
        if ($next -eq -1) { throw $this.Error('unexpected end of data') }
        throw $this.Error('unexpected character')
    }

    [object] ReadObject() {
        $result = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        $this.Pos += 1
        $this.SkipSpace()
        if ($this.Peek() -eq [int][char]'}') {
            $this.Pos += 1
            return $result
        }
        while ($true) {
            if ($this.Peek() -ne [int][char]'"') { throw $this.Error('expected a property name in double quotes') }
            $key = $this.ReadString()
            $this.SkipSpace()
            if ($this.Peek() -ne [int][char]':') { throw $this.Error("expected ':'") }
            $this.Pos += 1
            $this.SkipSpace()
            $result[$key] = $this.ReadValue()
            $this.SkipSpace()
            $next = $this.Peek()
            if ($next -eq [int][char]'}') {
                $this.Pos += 1
                return $result
            }
            if ($next -ne [int][char]',') { throw $this.Error("expected ',' or '}'") }
            $this.Pos += 1
            $this.SkipSpace()
        }
        throw $this.Error('unreachable')
    }

    [object] ReadArray() {
        $result = [System.Collections.Generic.List[object]]::new()
        $this.Pos += 1
        $this.SkipSpace()
        if ($this.Peek() -eq [int][char]']') {
            $this.Pos += 1
            return $result
        }
        while ($true) {
            $result.Add($this.ReadValue())
            $this.SkipSpace()
            $next = $this.Peek()
            if ($next -eq [int][char]']') {
                $this.Pos += 1
                return $result
            }
            if ($next -ne [int][char]',') { throw $this.Error("expected ',' or ']'") }
            $this.Pos += 1
            $this.SkipSpace()
        }
        throw $this.Error('unreachable')
    }

    [string] ReadString() {
        $match = [TodoFixJsonReader]::String.Match($this.Text, $this.Pos)
        if (-not $match.Success) { throw $this.Error('invalid string') }
        $this.Pos += $match.Length
        $raw = $match.Groups[1].Value
        if ($raw.IndexOf([char]92) -lt 0) { return $raw }

        # The regex already checked every escape, so each one is well-formed.
        $out = [System.Text.StringBuilder]::new($raw.Length)
        $i = 0
        while ($i -lt $raw.Length) {
            $code = [int]$raw[$i]
            if ($code -ne 92) {
                [void]$out.Append($raw[$i])
                $i += 1
                continue
            }
            $escape = [int]$raw[$i + 1]
            if ($escape -eq [int][char]'u') {
                [void]$out.Append([char][Convert]::ToInt32($raw.Substring($i + 2, 4), 16))
                $i += 6
                continue
            }
            if ($escape -eq [int][char]'b') { [void]$out.Append([char]8) }
            elseif ($escape -eq [int][char]'f') { [void]$out.Append([char]12) }
            elseif ($escape -eq [int][char]'n') { [void]$out.Append([char]10) }
            elseif ($escape -eq [int][char]'r') { [void]$out.Append([char]13) }
            elseif ($escape -eq [int][char]'t') { [void]$out.Append([char]9) }
            else { [void]$out.Append($raw[$i + 1]) }
            $i += 2
        }
        return $out.ToString()
    }
}

# Writes JSON the way Python's json.dumps(indent=2, ensure_ascii=False) does,
# so both installers produce the same settings.json.
class TodoFixJsonWriter {
    static [regex] $NeedsEscape = [regex]::new('[\x00-\x1f"\\]')

    static [string] Write([object] $value) {
        $out = [System.Text.StringBuilder]::new()
        [TodoFixJsonWriter]::WriteValue($out, $value, '')
        [void]$out.Append("`n")
        return $out.ToString()
    }

    static [void] WriteValue([System.Text.StringBuilder] $out, [object] $value, [string] $indent) {
        if ($null -eq $value) {
            [void]$out.Append('null')
        } elseif ($value -is [bool]) {
            if ($value) { [void]$out.Append('true') } else { [void]$out.Append('false') }
        } elseif ($value -is [TodoFixJsonNumber]) {
            [void]$out.Append($value.Text)
        } elseif ($value -is [string]) {
            [TodoFixJsonWriter]::WriteString($out, $value)
        } elseif ($value -is [System.Collections.IDictionary]) {
            if ($value.Count -eq 0) {
                [void]$out.Append('{}')
                return
            }
            $inner = $indent + '  '
            $separator = "{`n"
            foreach ($key in $value.Keys) {
                [void]$out.Append($separator).Append($inner)
                [TodoFixJsonWriter]::WriteString($out, [string]$key)
                [void]$out.Append(': ')
                [TodoFixJsonWriter]::WriteValue($out, $value[$key], $inner)
                $separator = ",`n"
            }
            [void]$out.Append("`n").Append($indent).Append('}')
        } elseif ($value -is [System.Collections.IList]) {
            if ($value.Count -eq 0) {
                [void]$out.Append('[]')
                return
            }
            $inner = $indent + '  '
            $separator = "[`n"
            foreach ($item in $value) {
                [void]$out.Append($separator).Append($inner)
                [TodoFixJsonWriter]::WriteValue($out, $item, $inner)
                $separator = ",`n"
            }
            [void]$out.Append("`n").Append($indent).Append(']')
        } else {
            throw ('cannot write a value of type {0} as JSON' -f $value.GetType().FullName)
        }
    }

    static [void] WriteString([System.Text.StringBuilder] $out, [string] $text) {
        [void]$out.Append('"')
        if (-not [TodoFixJsonWriter]::NeedsEscape.IsMatch($text)) {
            [void]$out.Append($text)
        } else {
            foreach ($char in $text.ToCharArray()) {
                $code = [int]$char
                if ($code -eq 34) { [void]$out.Append('\"') }
                elseif ($code -eq 92) { [void]$out.Append('\\') }
                elseif ($code -eq 8) { [void]$out.Append('\b') }
                elseif ($code -eq 9) { [void]$out.Append('\t') }
                elseif ($code -eq 10) { [void]$out.Append('\n') }
                elseif ($code -eq 12) { [void]$out.Append('\f') }
                elseif ($code -eq 13) { [void]$out.Append('\r') }
                elseif ($code -lt 32) { [void]$out.Append('\u').Append($code.ToString('x4')) }
                else { [void]$out.Append($char) }
            }
        }
        [void]$out.Append('"')
    }
}

function Get-TodoFixErrorMessage($ErrorRecord) {
    # Errors thrown inside class methods and .NET calls arrive wrapped.
    $exception = $ErrorRecord.Exception
    while ($exception -is [System.Management.Automation.MethodInvocationException] -and
        $null -ne $exception.InnerException) {
        $exception = $exception.InnerException
    }
    return $exception.Message
}

function Get-TodoFixConfigDir {
    # Claude Code uses %USERPROFILE%\.claude on Windows and ~/.claude elsewhere.
    if ([System.IO.Path]::DirectorySeparatorChar -eq [char]92) {
        $userHome = $env:USERPROFILE
    } else {
        $userHome = $env:HOME
    }
    if (-not $userHome) {
        $userHome = [Environment]::GetFolderPath('UserProfile')
    }

    $dir = $env:CLAUDE_CONFIG_DIR
    if (-not $dir) {
        $dir = [System.IO.Path]::Combine($userHome, '.claude')
    } elseif ($dir -eq '~' -or $dir.StartsWith('~/', [StringComparison]::Ordinal) -or
        $dir.StartsWith('~\', [StringComparison]::Ordinal)) {
        $dir = $userHome + $dir.Substring(1)
    }
    # .NET resolves relative paths against the process directory, which
    # PowerShell doesn't keep in sync with Set-Location.
    $location = (Get-Location -PSProvider FileSystem).ProviderPath
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($location, $dir))
}

function Read-TodoFixDocument([string] $Path) {
    # Returns the file's text with line endings normalized to LF, plus what
    # Save-TodoFixDocument needs to write it back the same way.
    $document = [pscustomobject]@{
        Path = $Path
        Exists = [System.IO.File]::Exists($Path)
        Bom = $false
        Eol = "`n"
        Text = ''
    }
    if (-not $document.Exists) {
        return $document
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $document.Bom = $true
        $offset = 3
    }
    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    } catch {
        throw ('{0} is not UTF-8 text. Save it as UTF-8 or follow the manual steps in README.md.' -f $Path)
    }
    if ($text.Contains("`r`n")) {
        $document.Eol = "`r`n"
    }
    $document.Text = $text.Replace("`r`n", "`n")
    return $document
}

function Save-TodoFixDocument($Document, [string] $Text) {
    $encoding = [System.Text.UTF8Encoding]::new([bool]$Document.Bom)
    [byte[]] $bytes = $encoding.GetPreamble() + $encoding.GetBytes($Text.Replace("`n", $Document.Eol))
    $path = $Document.Path

    if ($Document.Exists) {
        [System.IO.File]::Copy($path, ('{0}.bak-{1}' -f $path, $TodoFixStamp), $true)
        $attributes = [System.IO.File]::GetAttributes($path)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            # Write through a symlink so the link itself stays in place.
            [System.IO.File]::WriteAllBytes($path, $bytes)
            return
        }
    }

    $directory = [System.IO.Path]::GetDirectoryName($path)
    [void][System.IO.Directory]::CreateDirectory($directory)
    $temp = [System.IO.Path]::Combine($directory, '.todo-fix-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllBytes($temp, $bytes)
        if ($Document.Exists) {
            $unixMode = [System.IO.File].GetMethod('GetUnixFileMode', [type[]]@([string]))
            if ([System.IO.Path]::DirectorySeparatorChar -eq [char]47 -and $null -ne $unixMode) {
                [System.IO.File]::SetUnixFileMode($temp, [System.IO.File]::GetUnixFileMode($path))
            }
            # [NullString]::Value, because PowerShell turns $null into '' for string arguments.
            [System.IO.File]::Replace($temp, $path, [NullString]::Value)
        } else {
            [System.IO.File]::Move($temp, $path)
        }
    } finally {
        if ([System.IO.File]::Exists($temp)) {
            [System.IO.File]::Delete($temp)
        }
    }
}

function Read-TodoFixSetting($Document) {
    if (-not $Document.Text.Trim()) {
        return [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    }
    try {
        $data = [TodoFixJsonReader]::new($Document.Text).ReadDocument()
    } catch {
        throw ('{0} is not valid JSON ({1}). Fix it or follow the manual steps in README.md.' -f
            $Document.Path, (Get-TodoFixErrorMessage $_))
    }
    if ($data -isnot [System.Collections.IDictionary]) {
        throw ('{0} must contain a JSON object.' -f $Document.Path)
    }
    return $data
}

function Get-TodoFixTextWithoutBlock([string] $Text) {
    while ($true) {
        $match = $TodoFixBlock.Match($Text)
        if (-not $match.Success) {
            return $Text
        }
        $before = $Text.Substring(0, $match.Index)
        $after = $Text.Substring($match.Index + $match.Length)
        if (-not $after -and $before.EndsWith("`n`n", [StringComparison]::Ordinal)) {
            # Drop the blank line that install put in front of the block.
            $before = $before.Substring(0, $before.Length - 1)
        }
        $Text = $before + $after
    }
}

function Install-TodoFix([string] $ConfigDir, [string] $SnippetPath) {
    $snippet = Read-TodoFixDocument $SnippetPath
    if (-not $snippet.Exists -or -not $snippet.Text.Contains($TodoFixStart) -or
        -not $snippet.Text.Contains($TodoFixEnd)) {
        throw "snippet missing or without markers: $SnippetPath"
    }
    $block = $snippet.Text.Trim() + "`n"

    $settings = Read-TodoFixDocument ([System.IO.Path]::Combine($ConfigDir, 'settings.json'))
    $memory = Read-TodoFixDocument ([System.IO.Path]::Combine($ConfigDir, 'CLAUDE.md'))
    $data = Read-TodoFixSetting $settings
    if (-not $data.Contains('env')) {
        $data['env'] = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    }
    $envBlock = $data['env']
    if ($envBlock -isnot [System.Collections.IDictionary]) {
        throw ('"env" in {0} must be an object.' -f $settings.Path)
    }

    $changed = $false
    $current = $null
    if ($envBlock.Contains($TodoFixKey)) {
        $current = $envBlock[$TodoFixKey]
    }
    # Compare ordinally: -eq and -ceq are culture-aware and skip characters like
    # zero-width spaces.
    if ($current -is [string] -and [string]::Equals($current, $TodoFixValue, [StringComparison]::Ordinal)) {
        Write-Host "settings.json  $TodoFixKey already set"
    } else {
        $envBlock[$TodoFixKey] = $TodoFixValue
        Save-TodoFixDocument $settings ([TodoFixJsonWriter]::Write($data))
        $changed = $true
        Write-Host "settings.json  set $TodoFixKey=$TodoFixValue"
    }

    $text = $memory.Text
    $match = $TodoFixBlock.Match($text)
    if ($match.Success) {
        $rest = Get-TodoFixTextWithoutBlock $text.Substring($match.Index + $match.Length)
        $updated = $text.Substring(0, $match.Index) + $block + $rest
        $action = 'updated'
    } else {
        if (-not $text) {
            $separator = ''
        } elseif ($text.EndsWith("`n", [StringComparison]::Ordinal)) {
            $separator = "`n"
        } else {
            $separator = "`n`n"
        }
        $updated = $text + $separator + $block
        $action = 'added'
    }
    if ([string]::Equals($updated, $text, [StringComparison]::Ordinal)) {
        Write-Host 'CLAUDE.md      task list rule already present'
    } else {
        Save-TodoFixDocument $memory $updated
        $changed = $true
        Write-Host "CLAUDE.md      task list rule $action"
    }
    return $changed
}

function Uninstall-TodoFix([string] $ConfigDir) {
    $settings = Read-TodoFixDocument ([System.IO.Path]::Combine($ConfigDir, 'settings.json'))
    $memory = Read-TodoFixDocument ([System.IO.Path]::Combine($ConfigDir, 'CLAUDE.md'))
    $data = Read-TodoFixSetting $settings

    $changed = $false
    $envBlock = $null
    if ($data.Contains('env')) {
        $envBlock = $data['env']
    }
    if ($envBlock -is [System.Collections.IDictionary] -and $envBlock.Contains($TodoFixKey)) {
        $envBlock.Remove($TodoFixKey)
        if ($envBlock.Count -eq 0) {
            $data.Remove('env')
        }
        Save-TodoFixDocument $settings ([TodoFixJsonWriter]::Write($data))
        $changed = $true
        Write-Host "settings.json  removed $TodoFixKey"
    } else {
        Write-Host "settings.json  $TodoFixKey not set"
    }

    if (-not $TodoFixBlock.IsMatch($memory.Text)) {
        Write-Host 'CLAUDE.md      no task list rule found'
    } else {
        Save-TodoFixDocument $memory (Get-TodoFixTextWithoutBlock $memory.Text)
        $changed = $true
        Write-Host 'CLAUDE.md      task list rule removed'
    }
    return $changed
}

function Invoke-TodoFix([string] $Action, [string] $Root) {
    $configDir = Get-TodoFixConfigDir
    Write-Host "Config directory: $configDir"
    Write-Host ''
    if ($Action -eq 'install') {
        $changed = Install-TodoFix $configDir ([System.IO.Path]::Combine($Root, 'snippet', 'CLAUDE.md'))
    } else {
        $changed = Uninstall-TodoFix $configDir
    }
    if ($changed) {
        Write-Host ''
        Write-Host 'Restart Claude Code to apply the change.'
    }
}
