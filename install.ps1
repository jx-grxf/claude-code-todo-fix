#Requires -Version 5.1
# Brings the task list back: enables the todo tools and adds the CLAUDE.md rule.
#
#   powershell -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'todo_fix.ps1'))

try {
    Invoke-TodoFix 'install' $PSScriptRoot
} catch {
    [Console]::Error.WriteLine('error: ' + (Get-TodoFixErrorMessage $_))
    exit 1
}
