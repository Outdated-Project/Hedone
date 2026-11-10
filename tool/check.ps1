$ErrorActionPreference = 'Stop'
function Run-Checked {
    param([string] $Executable, [string[]] $Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}
Run-Checked -Executable flutter -Arguments @('pub', 'get', '--enforce-lockfile')
Run-Checked -Executable flutter -Arguments @('analyze', '--no-pub')
Run-Checked -Executable flutter -Arguments @('test', '--no-pub')
Run-Checked -Executable cargo -Arguments @('fmt', '--manifest-path', 'rust/Cargo.toml', '--check')
Run-Checked -Executable cargo -Arguments @('test', '--manifest-path', 'rust/Cargo.toml', '--features', 'server', '--locked')
Run-Checked -Executable cargo -Arguments @('clippy', '--manifest-path', 'rust/Cargo.toml', '--features', 'server', '--all-targets', '--locked', '--', '-D', 'warnings')
