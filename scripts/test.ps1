# Runs the unit tests one file at a time.
#
# Each file is built into its own binary and executed. A single `v test` over
# the directory builds the files concurrently, which on Windows can fail while
# compiling libgc and reports only "exec failed (SetHandleInformation)".
# Splitting the runs keeps a failure attributable to one file.

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot

# VEXE matters when the compiler was downloaded as a release archive: it has no
# vlib beside it, and without VEXE every build fails with
# "builtin/ not included on module lookup path".
$v = if ($env:V) { $env:V } elseif ($env:VEXE) { $env:VEXE } else { 'v' }

$tests = @(
	'torabot\http_test.v'
	'torabot\discord_test.v'
	'torabot\args_test.v'
	'torabot\inflate_test.v'
)

$failed = 0

foreach ($t in $tests) {
	$name = [System.IO.Path]::GetFileNameWithoutExtension($t)
	Write-Output "==> $name"
	& $v -cc tcc -o t.exe (Join-Path $projectRoot $t)
	if ($LASTEXITCODE -ne 0) {
		Write-Error "    build FAILED: $t"
		$failed++
		continue
	}
	& .\t.exe
	if ($LASTEXITCODE -ne 0) {
		Write-Error "    run FAILED: $t"
		$failed++
		continue
	}
	Write-Output '    ok'
	Remove-Item t.exe -Force -ErrorAction SilentlyContinue
}

if ($failed -ne 0) {
	Write-Error "$failed test file(s) failed"
	exit 1
}

Write-Output 'all test files passed'