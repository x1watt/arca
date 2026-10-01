// Putting a downloaded release in place (docs/architecture.md, 11).
//
// - Android: the APK goes to the system's package installer, which asks
//   the user; the app does that through a platform channel.
// - Windows and Linux: the archive is unpacked next to the app folder
//   (`<parent>/.arca-update/arca`). When the user chooses "Restart to
//   update", a small script waits for Arca to exit, moves the old folder
//   aside as `<app>.previous` (kept for going back), moves the new one in,
//   and starts Arca again. If the new folder cannot be moved in, the old
//   one is put back. Nothing is swapped without the user's click.
// - An app folder that cannot be written (installed for all users) is not
//   touched: the user is pointed at the downloaded file.

import 'dart:io';

import 'release.dart';

/// How a downloaded release is put in place on this device.
enum InstallKind { apk, restart, folder }

/// The folder the running app was started from.
Directory runningAppDir() => File(Platform.resolvedExecutable).parent;

/// Whether [dir] is a release bundle of Arca for [os], the kind the
/// release workflow packs (and not, say, a debug build or the Dart VM
/// running the seed node).
Future<bool> isReleaseBundle(Directory dir, String os) async {
  final needed = switch (os) {
    'linux' => ['arca', 'lib/libapp.so'],
    'windows' => ['arca.exe', 'data/app.so'],
    _ => const <String>[],
  };
  if (needed.isEmpty) return false;
  for (final n in needed) {
    if (!await File('${dir.path}/$n').exists()) return false;
  }
  return true;
}

/// How the release for [target] can be installed from [appDir].
Future<InstallKind?> installKindFor(Target? target, Directory appDir) async {
  if (target == null) return null;
  if (target.os == 'android') return InstallKind.apk;
  if (!await isReleaseBundle(appDir, target.os)) return InstallKind.folder;
  if (!await dirWritable(appDir) || !await dirWritable(appDir.parent)) return InstallKind.folder;
  return InstallKind.restart;
}

/// Where a release is unpacked before the swap: beside the app folder, on
/// the same disk, so the swap is two renames.
Directory stagingDir(Directory appDir) => Directory('${appDir.parent.path}/.arca-update');

/// The unpacked app inside [stagingDir].
Directory stagedApp(Directory appDir) => Directory('${stagingDir(appDir).path}/arca');

/// Unpacks [archive] (already checked against its SHA-256) into the
/// staging folder for [os]; returns the staged app folder, or throws with
/// a message.
Future<Directory> stageArchive(File archive, String os, Directory appDir) async {
  final staging = stagingDir(appDir);
  if (await staging.exists()) await staging.delete(recursive: true);
  await staging.create(recursive: true);
  ProcessResult r;
  if (os == 'windows') {
    // tar.exe ships with Windows 10 and 11 and reads zip files.
    final tar = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\tar.exe';
    r = await Process.run(tar, ['-xf', archive.path, '-C', staging.path]);
    if (r.exitCode != 0) {
      r = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Expand-Archive -LiteralPath "${archive.path}" -DestinationPath "${staging.path}" -Force',
      ]);
    }
  } else {
    r = await Process.run('tar', ['-xzf', archive.path, '-C', staging.path]);
  }
  if (r.exitCode != 0) {
    await staging.delete(recursive: true);
    throw ReleaseException('Could not unpack the update: ${r.stderr}'.trim());
  }
  final app = stagedApp(appDir);
  if (!await isReleaseBundle(app, os)) {
    await staging.delete(recursive: true);
    throw ReleaseException('The update does not hold an Arca folder for this system.');
  }
  return app;
}

/// Writes the swap script for [os] into [dir] and starts it, detached, to
/// wait for this process to exit. Returns the log file it writes to.
Future<String> startSwap(String os, Directory appDir, Directory staged, String dir) async {
  final log = '$dir/arca-update.log';
  if (os == 'windows') {
    final script = File('$dir/arca-update.ps1');
    await script.writeAsString(windowsSwapScript, flush: true);
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-ProcessId',
        '$pid',
        '-App',
        appDir.path,
        '-Staged',
        staged.path,
        '-Log',
        log,
      ],
      mode: ProcessStartMode.detached,
    );
  } else {
    final script = File('$dir/arca-update.sh');
    await script.writeAsString(unixSwapScript, flush: true);
    await Process.start('/bin/sh', [script.path, '$pid', appDir.path, staged.path, log], mode: ProcessStartMode.detached);
  }
  return log;
}

/// The swap on Linux. Arguments: the pid to wait for, the app folder, the
/// staged folder and a log file.
const unixSwapScript = r'''#!/bin/sh
# Arca's updater (docs/architecture.md, 11): waits for Arca to exit, moves
# the old app folder aside as <app>.previous, moves the new one in, and
# starts Arca again. When the new one cannot be moved in, the old one is
# put back.
pid="$1"; app="$2"; staged="$3"; log="$4"
say() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$log"; }
n=0
while kill -0 "$pid" 2>/dev/null; do
  n=$((n + 1))
  if [ "$n" -gt 600 ]; then say "Arca did not exit; nothing changed"; exit 1; fi
  sleep 0.2
done
if [ -x "$staged/arca" ] && [ -d "$app" ]; then
  rm -rf "$app.previous"
  if mv "$app" "$app.previous"; then
    if mv "$staged" "$app"; then
      say "updated $app"
    else
      say "could not move the new version in; the old one is back"
      mv "$app.previous" "$app"
    fi
  else
    say "could not move the old version aside; nothing changed"
  fi
else
  say "nothing staged at $staged; nothing changed"
fi
rmdir "$(dirname "$staged")" 2>/dev/null
cd "$app" && exec ./arca >/dev/null 2>&1
''';

/// The swap on Windows, the same steps in PowerShell. Folders can stay
/// locked for a moment after a process ends (the virus scanner, Explorer),
/// so moving the old folder aside is tried for ten seconds.
const windowsSwapScript = r'''param([int]$ProcessId, [string]$App, [string]$Staged, [string]$Log)
# Arca's updater (docs/architecture.md, 11): waits for Arca to exit, moves
# the old app folder aside as <app>.previous, moves the new one in, and
# starts Arca again. When the new one cannot be moved in, the old one is
# put back.
function Say([string]$m) {
  Add-Content -LiteralPath $Log -Value ('{0} {1}' -f (Get-Date).ToUniversalTime().ToString('s'), $m)
}
Set-Location -LiteralPath ([System.IO.Path]::GetTempPath())
$p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
if ($p -and -not $p.WaitForExit(120000)) { Say 'Arca did not exit; nothing changed'; exit 1 }
Start-Sleep -Milliseconds 500
$backup = "$App.previous"
if ((Test-Path -LiteralPath (Join-Path $Staged 'arca.exe')) -and (Test-Path -LiteralPath $App)) {
  try {
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop }
    $moved = $false
    for ($i = 0; $i -lt 20 -and -not $moved; $i++) {
      try {
        Rename-Item -LiteralPath $App -NewName (Split-Path -Leaf $backup) -ErrorAction Stop
        $moved = $true
      } catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $moved) { throw 'could not move the old version aside' }
    try {
      Move-Item -LiteralPath $Staged -Destination $App -ErrorAction Stop
      Say "updated $App"
    } catch {
      Say "could not move the new version in ($_); the old one is back"
      Rename-Item -LiteralPath $backup -NewName (Split-Path -Leaf $App)
    }
  } catch { Say "nothing changed: $_" }
} else { Say "nothing staged at $Staged; nothing changed" }
$parent = Split-Path -Parent $Staged
if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent -Force)) {
  Remove-Item -LiteralPath $parent -Force
}
Start-Process -FilePath (Join-Path $App 'arca.exe') -WorkingDirectory $App
''';
