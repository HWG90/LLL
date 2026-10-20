"""Generate the Steam helper's one-shot, hidden Windows startup command.

The helper must signal Local\\LLL_Steam_Ready_<pipe> after creating BOTH pipes.
The launcher never connects to those pipes, never opens the game process, and
never changes PowerShell execution policy. Lua must close the popen stream
without reading it to EOF: the external GUI child can outlive that stream.
"""
from __future__ import annotations

import base64
import re
import subprocess


def _literal(value: str) -> str:
    """A literal PowerShell string, including apostrophes and Unicode."""
    if not isinstance(value, str) or any(ord(char) < 32 for char in value):
        raise ValueError('Launcher values must be printable strings')
    return "'" + value.replace("'", "''") + "'"


def ready_event(pipe: str) -> str:
    if not re.fullmatch(r'[a-z0-9_]{16,96}', pipe):
        raise ValueError('Invalid Steam pipe token')
    return 'Local\\LLL_Steam_Ready_' + pipe


def powershell(service_name: str, service_sha256: str, game_root: str | None,
               pipe: str, timeout_ms: int = 8000) -> str:
    """Return a one-shot launcher. Its readiness wait is bounded and event based.

    Create/open the readiness event before starting the child, avoiding a missed
    notification. An already signaled event reuses the waiting helper. A second
    concurrent launcher waits on the same event instead of starting a duplicate.
    The service's own AppData mutex remains the final single-instance guard.
    """
    event = ready_event(pipe)
    if not re.fullmatch(r'[0-9a-f]{64}', service_sha256):
        raise ValueError('Invalid service SHA256')
    if service_name != 'lll_steam_service_' + service_sha256[:16] + '.exe':
        raise ValueError('Service content address mismatch')
    if not isinstance(timeout_ms, int) or not 1 <= timeout_ms <= 8000:
        raise ValueError('Startup timeout must be between 1 and 8000 milliseconds')
    # Windows paths cannot contain double quotes. list2cmdline also handles a
    # trailing backslash correctly when Start-Process joins ArgumentList again.
    if game_root is not None and (not game_root or '"' in game_root):
        raise ValueError('Invalid game root')
    arguments = subprocess.list2cmdline(['--game', game_root, '--pipe', pipe]) if game_root is not None else None
    binding = '' if arguments is not None else r'''
    $binding = [IO.Path]::Combine([IO.Path]::GetDirectoryName($service), 'game-root.txt')
    $game = [IO.File]::ReadAllText($binding, [Text.Encoding]::UTF8).TrimEnd([char[]]"`r`n")
    if (-not [IO.Path]::IsPathRooted($game) -or $game -match '[\x00-\x1f"]') { throw 'Invalid LLL game-root binding' }
    $quotedGame = '"' + [Regex]::Replace($game, '(\\+)$', '$1$1') + '"'
    $arguments = '--game ' + $quotedGame + ' --pipe ' + PIPE_LITERAL
'''.replace('PIPE_LITERAL', _literal(pipe))
    argument_expression = _literal(arguments) if arguments is not None else '$arguments'
    service_relative = 'LLL\\Helldivers2\\Service\\' + service_name
    return f"""$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$timer = [Diagnostics.Stopwatch]::StartNew()
$ready = $null
$exited = $null
$child = $null
try {{
    $service = [IO.Path]::Combine($env:LOCALAPPDATA, {_literal(service_relative)})
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $source = [IO.File]::OpenRead($service)
    try {{ $actual = [BitConverter]::ToString($algorithm.ComputeHash($source)).Replace('-', '').ToLowerInvariant() }}
    finally {{ $source.Dispose(); $algorithm.Dispose() }}
    if ($actual -ne {_literal(service_sha256)}) {{
        throw 'Installed LLL filesystem service changed'
    }}
{binding}
    $created = $false
    $ready = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, {_literal(event)}, [ref]$created)
    if ($ready.WaitOne(0)) {{
        [Console]::Out.WriteLine('LLL_READY')
        exit 0
    }}
    if ($created) {{
        $child = Start-Process -FilePath $service -ArgumentList {argument_expression} -WindowStyle Hidden -PassThru
        $exited = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset)
        $exited.SafeWaitHandle = [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new($child.Handle, $false)
        $remaining = [Math]::Max(0, {timeout_ms} - [int]$timer.ElapsedMilliseconds)
        $outcome = [Threading.WaitHandle]::WaitAny([Threading.WaitHandle[]]@($ready, $exited), $remaining)
        if ($outcome -eq 1) {{ throw 'LLL filesystem service exited before readiness' }}
        if ($outcome -ne 0) {{ throw 'LLL filesystem service readiness timed out' }}
    }} else {{
        $remaining = [Math]::Max(0, {timeout_ms} - [int]$timer.ElapsedMilliseconds)
        if (-not $ready.WaitOne($remaining)) {{ throw 'LLL filesystem service readiness timed out' }}
    }}
    [Console]::Out.WriteLine('LLL_READY')
}} catch {{
    [Console]::Out.WriteLine('LLL_ERROR: ' + $_.Exception.Message)
    exit 1
}} finally {{
    if ($exited) {{ $exited.Dispose() }}
    if ($ready) {{ $ready.Dispose() }}
    if ($child) {{ $child.Dispose() }}
}}
"""


def encoded_command(service_name: str, service_sha256: str, game_root: str | None,
                    pipe: str, timeout_ms: int = 8000) -> str:
    return base64.b64encode(powershell(service_name, service_sha256, game_root,
                                     pipe, timeout_ms).encode('utf-16-le')).decode('ascii')


def command(service_name: str, service_sha256: str, game_root: str | None,
            pipe: str, timeout_ms: int = 8000) -> str:
    """Command for io.popen(..., 'r'): close it without an EOF read."""
    encoded = encoded_command(service_name, service_sha256, game_root, pipe, timeout_ms)
    return ('powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden '
            '-EncodedCommand ' + encoded)
