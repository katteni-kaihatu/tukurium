param([ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Profile = 'default', [switch]$Services, [switch]$Online)
$ErrorActionPreference = 'Stop'
$localRoot = Split-Path -Parent $PSScriptRoot
$stateRoot = if ($env:KOKOVERSE_DATA_ROOT) { [IO.Path]::GetFullPath($env:KOKOVERSE_DATA_ROOT) } else { $localRoot }
$recordPath = Join-Path $stateRoot $(if ($Online) { ".run/online/$Profile/processes.json" } else { ".run/local/$Profile/processes.json" })
function Stop-OwnedProcess($record) {
    $p = Get-Process -Id $record.id -ErrorAction SilentlyContinue
    if ($p -and $p.Path -eq $record.path -and $p.StartTime.ToUniversalTime().Ticks.ToString() -eq $record.startTicks) { Stop-Process -Id $p.Id }
}
if (Test-Path -LiteralPath $recordPath) {
    $records = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    $live = @($records.processes | Where-Object {
        $p = Get-Process -Id $_.id -ErrorAction SilentlyContinue
        $p -and $p.Path -eq $_.path -and $p.StartTime.ToUniversalTime().Ticks.ToString() -eq $_.startTicks
    })
    $engineLive = @($live | Where-Object { [IO.Path]::GetFileName($_.path) -eq 'kokoverse-engine.exe' })
    $frontendLive = @($live | Where-Object { [IO.Path]::GetFileName($_.path) -like 'Godot_*.exe' })
    if ($engineLive) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            if (-not $client.ConnectAsync('127.0.0.1',[int]$records.ui_port).Wait(5000)) { throw 'Engine connection timed out.' }
            $stream = $client.GetStream(); $stream.ReadTimeout=10000; $stream.WriteTimeout=5000
            function Read-LocalFrame {
                $header = New-Object byte[] 4; $offset=0
                while ($offset -lt 4) { $n=$stream.Read($header,$offset,4-$offset); if ($n -eq 0) { throw 'Engine disconnected.' }; $offset+=$n }
                $size=[Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($header,0))
                if ($size -lt 1 -or $size -gt 1048576) { throw 'Invalid response.' }
                $data=New-Object byte[] $size; $offset=0
                while ($offset -lt $size) { $n=$stream.Read($data,$offset,$size-$offset); if ($n -eq 0) { throw 'Engine disconnected.' }; $offset+=$n }
                return [Text.Encoding]::UTF8.GetString($data) | ConvertFrom-Json
            }
            do { $state=Read-LocalFrame } until ($state.body.kind -eq 'service_state')
            $requestId=[guid]::NewGuid().ToString()
            $payload=@{protocol_version=3;session_id=$state.session_id;authority_epoch=$state.authority_epoch;sequence='1';body=@{kind='service';action='leave_session';request_id=$requestId}} | ConvertTo-Json -Depth 6 -Compress
            $data=[Text.Encoding]::UTF8.GetBytes($payload);$header=[BitConverter]::GetBytes([Net.IPAddress]::HostToNetworkOrder($data.Length));$stream.Write($header,0,4);$stream.Write($data,0,$data.Length)
            do { $result=Read-LocalFrame } until ($result.body.kind -eq 'service_result' -and $result.body.request_id -eq $requestId)
            if (-not $result.body.ok) { throw $result.body.message }
        } catch {
            # Godot already gone and Engine wedged: force-stop so Start is not permanently blocked.
            if ($frontendLive.Count -eq 0) {
                Write-Warning "save/leave failed with no live Godot ($_). Force-stopping the orphaned Engine."
            } else {
                throw "The application was left running because save/leave failed: $_"
            }
        } finally { $client.Close() }
    }
    foreach ($record in $records.processes) { Stop-OwnedProcess $record }
    Remove-Item -LiteralPath $recordPath
}
if ($Services -and -not $Online) {
    $otherClients = Get-ChildItem -LiteralPath (Join-Path $stateRoot '.run/local') -Filter processes.json -Recurse -ErrorAction SilentlyContinue
    if ($otherClients) { throw 'Stop the other local profiles before stopping the shared services.' }
    $sharedPath=Join-Path $stateRoot '.run/local/services.json'
    if (Test-Path -LiteralPath $sharedPath) { foreach ($record in (Get-Content -LiteralPath $sharedPath -Raw | ConvertFrom-Json)) { Stop-OwnedProcess $record }; Remove-Item -LiteralPath $sharedPath }
}
Write-Host 'Session saved and stopped.'
