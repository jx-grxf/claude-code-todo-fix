#Requires -Version 5.1
# Reverts install.ps1: removes the todo tools flag and the CLAUDE.md rule.
#
#   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'todo_fix.ps1'))

try {
    Invoke-TodoFix 'uninstall' $PSScriptRoot
} catch {
    [Console]::Error.WriteLine('error: ' + (Get-TodoFixErrorMessage $_))
    exit 1
}
