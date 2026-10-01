// Updates of Arca in the UI (docs/architecture.md, 11): a banner while a
// newer version is available, and the About section of Settings. The core
// finds, downloads, checks and prepares updates; the UI shows them and
// installs only on the user's click.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_client.dart';
import '../screens/settings_screen.dart';
import 'common.dart';

const _installer = MethodChannel('arca/update');

/// The label of the button that installs [offer] on this device.
String installLabel(UpdateOffer offer) => switch (offer.install) {
  'restart' => 'Restart to update',
  'folder' => 'Show the file',
  _ => 'Install',
};

/// Installs the downloaded update: the system installer on Android, a
/// restart into the new version on a desktop, or the file's folder.
/// Returns a message to show, or null.
Future<String?> installUpdate() async {
  final r = await Core.instance.updateInstall();
  if (r['error'] != null) return r['error'] as String;
  if (r['apk'] case final String apk) {
    try {
      final result = await _installer.invokeMethod<String>('installApk', {
        'path': apk,
      });
      if (result == 'permission') {
        return 'Allow Arca to install apps in the screen that opened, then '
            'press Install again.';
      }
      return null;
    } on PlatformException catch (e) {
      return 'The installer could not start: ${e.message}';
    }
  }
  if (r['restart'] == true) {
    // The core has stopped and the updater waits for this process to end.
    exit(0);
  }
  if (r['folder'] case final String folder) {
    return 'Arca cannot replace itself here (it was installed for all users). '
        'The new version is in $folder.';
  }
  return null;
}

/// Asks before downloading from GitHub, saying what it reveals.
Future<void> downloadFromGithub(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Download from GitHub instead?'),
      content: const Text(
        'Arca sends everything over I2P, so nobody learns your IP address. '
        'GitHub is an ordinary website: downloading from it shows GitHub '
        '(and anyone watching your connection) that this IP address '
        'downloaded Arca. It carries no profile key or I2P address, and the '
        'file is still checked against the signed release.\n\n'
        'Use it only when no device on I2P has the update.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Download from GitHub'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  final error = await Core.instance.updateDownload(github: true);
  if (error != null && context.mounted) showMessage(context, error);
}

/// A strip above [child] while a newer version is available.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key, required this.child});
  final Widget child;

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  /// Hidden for this session for this version.
  static String? _dismissed;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Core.instance.state,
      builder: (context, state, _) {
        final u = state?.update;
        final offer = u?.available;
        if (u == null || offer == null || _dismissed == offer.version) {
          return _layout(context, null);
        }
        final theme = Theme.of(context);
        final String detail;
        if (u.downloading) {
          detail =
              'Downloading ${_percent(u.received, offer.size)} over '
              '${u.source == 'github' ? 'GitHub' : 'I2P'}';
        } else if (u.staging) {
          detail = 'Getting it ready';
        } else if (offer.held && offer.install != null) {
          detail = 'Ready to install';
        } else if (u.error != null) {
          detail = u.error!;
        } else {
          detail = formatBytes(offer.size);
        }
        final strip = Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
              child: Row(
                children: [
                  const Icon(Icons.system_update_alt, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Arca ${offer.version} is available',
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (offer.held && offer.install != null)
                    FilledButton.tonal(
                      onPressed: _busy ? null : _install,
                      child: Text(
                        _busy ? 'Closing Arca...' : installLabel(offer),
                      ),
                    )
                  else if (!u.downloading && !u.staging)
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SettingsScreen(),
                        ),
                      ),
                      child: const Text('Details'),
                    ),
                  IconButton(
                    tooltip: 'Later',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => setState(() => _dismissed = offer.version),
                  ),
                ],
              ),
            ),
          ),
        );
        return _layout(context, strip);
      },
    );
  }

  /// The same tree with or without the strip, so the pages below keep
  /// their state when it comes and goes. The strip takes the status bar's
  /// space; the pages do not leave room for it again.
  Widget _layout(BuildContext context, Widget? strip) => Column(
    children: [
      strip ?? const SizedBox.shrink(),
      Expanded(
        child: MediaQuery.removePadding(
          context: context,
          removeTop: strip != null,
          child: widget.child,
        ),
      ),
    ],
  );

  Future<void> _install() async {
    setState(() => _busy = true);
    final message = await installUpdate();
    if (!mounted) return;
    setState(() => _busy = false);
    if (message != null) showMessage(context, message);
  }
}

String _percent(int received, int size) =>
    size <= 0 ? '' : '${(received * 100 ~/ size).clamp(0, 100)}%';

/// Settings, About: this version, a newer one when there is one, and the
/// automatic updates setting.
class UpdateSection extends StatefulWidget {
  const UpdateSection({super.key, required this.update});
  final UpdateView update;

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

class _UpdateSectionState extends State<UpdateSection> {
  bool _busy = false;
  final _core = Core.instance;

  Future<void> _run(Future<String?> action) async {
    final error = await action;
    if (error != null && mounted) showMessage(context, error);
  }

  Future<void> _install() async {
    setState(() => _busy = true);
    final message = await installUpdate();
    if (!mounted) return;
    setState(() => _busy = false);
    if (message != null) showMessage(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.update;
    final offer = u.available;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final checked = u.lastCheck == null
        ? 'Not checked yet since Arca started'
        : 'Checked ${timeAgo(u.lastCheck! ~/ 1000)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('Arca'),
          subtitle: Text(
            u.current.isEmpty ? '' : 'Version ${u.current} (${u.build})',
          ),
        ),
        if (offer == null)
          ListTile(
            leading: const Icon(Icons.verified_outlined),
            title: Text(
              u.checking
                  ? 'Looking for updates over I2P'
                  : 'Arca is up to date',
            ),
            subtitle: Text(
              u.error ?? checked,
              style: u.error != null
                  ? TextStyle(color: theme.colorScheme.error)
                  : null,
            ),
            trailing: u.checking
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: () => _run(_core.updateCheck()),
                    child: const Text('Check now'),
                  ),
          )
        else
          _offer(context, u, offer, muted),
        ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: const Text('Automatic updates'),
          subtitle: Text(switch (u.mode) {
            'notify' => 'Tell me when a new version is out',
            'off' => 'Never look for new versions by itself',
            _ =>
              'Download new versions over I2P by itself; installing always '
                  'asks',
          }),
          trailing: DropdownButton<String>(
            value: u.mode,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 'download', child: Text('Download')),
              DropdownMenuItem(value: 'notify', child: Text('Notify only')),
              DropdownMenuItem(value: 'off', child: Text('Off')),
            ],
            onChanged: (m) => m == null ? null : _run(_core.setUpdateMode(m)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Updates are announced with a signature by Arca\'s release key and '
            'travel over I2P from other devices, checked by their SHA-256. '
            '${u.serving > 0 ? 'This device passes on ${plural(u.serving, 'update file')} to others.' : ''}',
            style: muted,
          ),
        ),
      ],
    );
  }

  Widget _offer(
    BuildContext context,
    UpdateView u,
    UpdateOffer offer,
    TextStyle? muted,
  ) {
    final theme = Theme.of(context);
    final ready = offer.held && offer.install != null;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Arca ${offer.version} is available',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            Text(
              [
                if (offer.date.isNotEmpty) offer.date,
                '${offer.name}, ${formatBytes(offer.size)}',
              ].join(', '),
              style: muted,
            ),
            if (offer.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              SelectableText(offer.notes, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 12),
            if (u.downloading) ...[
              LinearProgressIndicator(
                value: offer.size > 0 ? u.received / offer.size : null,
              ),
              const SizedBox(height: 6),
              Text(
                '${formatBytes(u.received)} of ${formatBytes(offer.size)} '
                'over ${u.source == 'github' ? 'GitHub (HTTPS)' : 'I2P'}',
                style: muted,
              ),
            ] else if (u.staging)
              Text('Checking and unpacking the update', style: muted)
            else if (u.error != null)
              Text(u.error!, style: TextStyle(color: theme.colorScheme.error)),
            if (offer.install == 'folder' && offer.path != null) ...[
              const SizedBox(height: 6),
              SelectableText(offer.path!, style: muted),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (ready)
                  FilledButton(
                    onPressed: _busy ? null : _install,
                    child: Text(
                      _busy ? 'Closing Arca...' : installLabel(offer),
                    ),
                  )
                else if (u.downloading)
                  OutlinedButton(
                    onPressed: () => _run(_core.updateStop()),
                    child: const Text('Stop'),
                  )
                else if (!offer.held)
                  FilledButton(
                    onPressed: () => _run(_core.updateDownload()),
                    child: const Text('Download over I2P'),
                  ),
                if (!offer.held && !u.downloading && u.offerGithub)
                  OutlinedButton(
                    onPressed: () => downloadFromGithub(context),
                    child: const Text('Download from GitHub instead'),
                  ),
                if (!u.downloading)
                  TextButton(
                    onPressed: u.checking
                        ? null
                        : () => _run(_core.updateCheck()),
                    child: Text(u.checking ? 'Looking...' : 'Check again'),
                  ),
              ],
            ),
            if (Platform.isAndroid && ready) ...[
              const SizedBox(height: 8),
              Text(
                'Android asks you to confirm. If Arca 0.1.0 is installed, '
                'Android refuses the update: uninstall it once and install this '
                'version by hand (back up your profile key first).',
                style: muted,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
