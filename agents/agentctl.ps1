# PowerShell wrapper: .\agents\agentctl.ps1 <command> [options]
$py = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $py) { $py = Get-Command py -ErrorAction Stop }
& $py.Source (Join-Path $PSScriptRoot "orchestrator\agentctl.py") @args
exit $LASTEXITCODE
