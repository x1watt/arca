import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../core/core_client.dart';
import '../core/pickers.dart';
import '../widgets/common.dart';
import '../widgets/subtitles.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _askEachTime = false;
  bool _wifiOnly = true;
  bool _charging = true;
  double _upload = 2;
  double _freeShare = 20;
  double _noteCache = 2;
  double _mediaCache = 5;
  bool _circleRelay = false;
  final _relayCircles = <String>{};
  double _relayBudget = 20;

  final _core = Core.instance;

  Future<void> _run(Future<String?> action) async {
    final error = await action;
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: _core.state,
      builder: (context, state, _) =>
          _build(context, state ?? const CoreState([], null)),
    );
  }

  Widget _build(BuildContext context, CoreState state) {
    final me = state.active;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final joined = [state.commons];
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 48),
            children: [
              // Profiles on this device.
              SectionTitle(
                'Profiles on this device',
                trailing: PopupMenuButton<String>(
                  tooltip: 'Add a profile',
                  onSelected: (v) => v == 'import'
                      ? _importDialog(context)
                      : _createDialog(context),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'create',
                      child: Text('Create a new profile'),
                    ),
                    PopupMenuItem(
                      value: 'import',
                      child: Text('Import with an nsec'),
                    ),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Icon(Icons.person_add_alt, size: 18),
                        SizedBox(width: 6),
                        Text('Add'),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Each profile is a separate account with its own key, address, circles, '
                  'collections and settings. Profiles marked to stay online keep sharing and '
                  'answering in the background.',
                  style: muted,
                ),
              ),
              RadioGroup<String>(
                groupValue: me?.id,
                onChanged: (id) => _run(_core.switchTo(id!)),
                child: Column(
                  children: [
                    for (final p in state.profiles)
                      ListTile(
                        leading: Radio<String>(value: p.id),
                        title: Text(p.name),
                        subtitle: Text(
                          p.npubShort,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Stay online', style: muted),
                            Switch(
                              value: p.stayOnline,
                              onChanged: (on) =>
                                  _run(_core.setStayOnline(p.id, on)),
                            ),
                          ],
                        ),
                        onTap: () => _run(_core.switchTo(p.id)),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 16, color: muted?.color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Profiles on one device go online and offline together, and share this '
                        'device\'s I2P tunnels. Someone watching closely could guess they belong '
                        'to the same person. Use separate devices if that matters.',
                        style: muted,
                      ),
                    ),
                  ],
                ),
              ),

              // Active profile.
              if (me != null) ...[
                SectionTitle('Profile: ${me.name}'),
                ListTile(
                  leading: CircleAvatar(child: Text(me.initials)),
                  title: const Text('Name'),
                  subtitle: Text(me.name),
                  trailing: const Icon(Icons.edit_outlined, size: 18),
                  onTap: () => _renameDialog(context, me),
                ),
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: const Text('Public key'),
                  subtitle: SelectableText(
                    me.npub,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  trailing: IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: me.npub));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Public key copied')),
                        );
                      }
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('Export secret key'),
                  subtitle: const Text(
                    'Shows the nsec, to move this profile to another device',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _exportDialog(context, me),
                ),
                ListTile(
                  leading: const Icon(Icons.toll_outlined),
                  title: const Text('Wallet'),
                  subtitle: const Text('Not available yet'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showPrototypeNote(context, 'Wallet'),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Delete this profile from this device'),
                  enabled: state.profiles.length > 1,
                  subtitle: state.profiles.length > 1
                      ? null
                      : const Text(
                          'It is the only profile; create or import another one first',
                        ),
                  onTap: () => _deleteDialog(context, me),
                ),
              ],

              // Network: I2P only.
              const SectionTitle('Network'),
              Card.filled(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(switch (state.net) {
                            NetStatus.up => Icons.shield_moon,
                            NetStatus.failed => Icons.error_outline,
                            _ => Icons.shield_moon_outlined,
                          }),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(switch (state.net) {
                              NetStatus.up => 'I2P  -  connected',
                              NetStatus.starting => 'I2P  -  starting',
                              NetStatus.failed => 'I2P  -  could not start',
                              NetStatus.off => 'I2P  -  off',
                            }, style: theme.textTheme.titleSmall),
                          ),
                          if (state.net == NetStatus.starting)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          if (state.net == NetStatus.failed ||
                              state.net == NetStatus.off)
                            TextButton(
                              onPressed: () => _run(_core.startNetwork()),
                              child: const Text('Try again'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(switch (state.net) {
                        NetStatus.starting =>
                          'Building private tunnels. The first start also downloads the list of I2P '
                              'routers, which can take a few minutes.',
                        NetStatus.failed =>
                          state.netError ?? 'The I2P node could not start.',
                        _ =>
                          'All traffic goes through I2P, so nobody learns your IP address. '
                              'Each profile has its own address; profiles that are online answer on it.',
                      }, style: muted),
                      const SizedBox(height: 12),
                      for (final p in state.profiles)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 5,
                                  right: 8,
                                ),
                                child: Icon(
                                  Icons.circle,
                                  size: 8,
                                  color: p.online && state.net == NetStatus.up
                                      ? const Color(0xFF4CAF50)
                                      : theme.colorScheme.outline,
                                ),
                              ),
                              SizedBox(
                                width: 150,
                                child: Text(
                                  p.online ? p.name : '${p.name} (offline)',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Expanded(
                                child: SelectableText(
                                  p.i2pAddress,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // When the node may run.
              const SectionTitle('Sharing'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'When this device shares and answers others. These limits never leave it.',
                  style: muted,
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.wifi),
                title: const Text('Only on WiFi or Ethernet'),
                value: _wifiOnly,
                onChanged: (v) => setState(() => _wifiOnly = v),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.battery_charging_full),
                title: const Text('Only while charging'),
                value: _charging,
                onChanged: (v) => setState(() => _charging = v),
              ),
              _slider(
                Icons.upload,
                'Upload speed limit',
                '${_upload.toStringAsFixed(1)} MB/s',
                _upload,
                0.5,
                20,
                (v) => _upload = v,
              ),
              _slider(
                Icons.volunteer_activism_outlined,
                'Share for free readers',
                '${_freeShare.round()}%',
                _freeShare,
                0,
                100,
                (v) => _freeShare = v,
              ),
              ListTile(
                leading: const Icon(Icons.schedule),
                title: const Text('Hours'),
                subtitle: const Text('Any time'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showPrototypeNote(context, 'Sharing hours'),
              ),

              // Circle relay.
              const SectionTitle('Circle relay'),
              SwitchListTile(
                secondary: const Icon(Icons.dns_outlined),
                title: const Text('Volunteer as a circle relay'),
                subtitle: const Text(
                  'Circles automatically pick their most available volunteers to keep and serve '
                  'members\' notes and comments while they are offline.',
                ),
                isThreeLine: true,
                value: _circleRelay,
                onChanged: (v) => setState(() => _circleRelay = v),
              ),
              if (_circleRelay) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
                  child: Row(
                    children: [
                      Icon(
                        _wifiOnly || _charging
                            ? Icons.warning_amber_rounded
                            : Icons.check_circle_outline,
                        size: 16,
                        color: muted?.color,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _wifiOnly || _charging
                              ? 'Declared as intermittent because sharing is limited to WiFi or '
                                    'charging. Circles rarely pick intermittent machines; turn '
                                    'those limits off on a computer that is always on.'
                              : 'Declared as always on.',
                          style: muted,
                        ),
                      ),
                    ],
                  ),
                ),
                for (final c in joined)
                  CheckboxListTile(
                    secondary: const SizedBox(width: 24),
                    title: Text(c.name),
                    subtitle: Text(
                      _relayCircles.contains(c.id)
                          ? 'Volunteering; relay selection is not built yet'
                          : 'Not volunteering',
                    ),
                    value: _relayCircles.contains(c.id),
                    onChanged: (on) => setState(
                      () => on!
                          ? _relayCircles.add(c.id)
                          : _relayCircles.remove(c.id),
                    ),
                  ),
                _slider(
                  Icons.storage_outlined,
                  'Storage for circle notes',
                  '${_relayBudget.round()} GB',
                  _relayBudget,
                  1,
                  200,
                  (v) => _relayBudget = v,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
                  child: Text(
                    'While volunteering, the circle\'s relays check this machine at random times '
                    'and publish how often it answered each day. Others can then tell it is online '
                    'most of the time; its IP address stays hidden behind I2P.',
                    style: muted,
                  ),
                ),
              ],

              // Storage.
              SectionTitle(
                'Storage folders',
                trailing: TextButton.icon(
                  onPressed: () async {
                    final path = await pickFolder(title: 'Add');
                    if (path != null) await _run(_core.addStorageFolder(path));
                  },
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Add folder'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Collections are stored in these folders, shared by all profiles on this device. '
                  'Add one per disk to spread the library across several drives.',
                  style: muted,
                ),
              ),
              RadioGroup<String>(
                groupValue: state.storage
                    .where((f) => f.isDefault)
                    .firstOrNull
                    ?.path,
                onChanged: (v) => _run(_core.setDefaultStorageFolder(v!)),
                child: Column(
                  children: [
                    for (final f in state.storage)
                      _FolderTile(
                        f,
                        onRemove: state.storage.length > 1
                            ? () => _run(_core.removeStorageFolder(f.path))
                            : null,
                      ),
                  ],
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.help_outline),
                title: const Text('Ask where to store each new collection'),
                value: _askEachTime,
                onChanged: (v) => setState(() => _askEachTime = v),
              ),
              _slider(
                Icons.forum_outlined,
                'Space for other people\'s notes',
                '${_noteCache.round()} GB',
                _noteCache,
                0.5,
                50,
                (v) => _noteCache = v,
              ),
              _slider(
                Icons.photo_library_outlined,
                'Space for pictures in notes',
                '${_mediaCache.round()} GB',
                _mediaCache,
                0.5,
                50,
                (v) => _mediaCache = v,
              ),

              // Subtitles.
              const SectionTitle('Subtitles'),
              SubtitleSettings(status: state.subtitles),

              // Search.
              const SectionTitle('Search'),
              ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: const Text('Circle catalogs on this device'),
                subtitle: const Text('6 circles, 18.4 GB'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showPrototypeNote(context, 'Catalogs'),
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Clear search history of this profile'),
                onTap: () => showPrototypeNote(context, 'Clear history'),
              ),

              const SectionTitle('About'),
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Arca prototype'),
                subtitle: Text('Version 0.1.0'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _slider(
    IconData icon,
    String label,
    String value,
    double current,
    double min,
    double max,
    void Function(double) apply,
  ) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: Text(value),
      subtitle: Slider(
        value: current,
        min: min,
        max: max,
        onChanged: (v) => setState(() => apply(v)),
      ),
    );
  }

  Future<void> _createDialog(BuildContext context) async {
    final name = await _askText(
      context,
      title: 'Create a new profile',
      label: 'Name (optional)',
      action: 'Create',
    );
    if (name == null) return;
    await _run(_core.createProfile(name));
  }

  Future<void> _renameDialog(BuildContext context, ProfileView p) async {
    final name = await _askText(
      context,
      title: 'Profile name',
      label: 'Name',
      action: 'Save',
      initial: p.name,
    );
    if (name == null || name.trim().isEmpty) return;
    await _run(_core.rename(p.id, name));
  }

  Future<String?> _askText(
    BuildContext context, {
    required String title,
    required String label,
    required String action,
    String initial = '',
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _TextDialog(
        title: title,
        label: label,
        action: action,
        initial: initial,
      ),
    );
  }

  void _importDialog(BuildContext context) {
    showDialog<void>(context: context, builder: (_) => const _ImportDialog());
  }

  Future<void> _exportDialog(BuildContext context, ProfileView p) async {
    final show = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('Export secret key'),
        content: const SizedBox(
          width: 460,
          child: Text(
            'Anyone with this key controls the profile: they can post as you and, later, '
            'spend its marcas. Only show it when nobody is looking, and keep it offline.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Show nsec'),
          ),
        ],
      ),
    );
    if (show != true) return;
    final String nsec;
    try {
      nsec = await _core.exportNsec(p.id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Secret key of ${p.name}'),
        content: SizedBox(
          width: 460,
          child: SelectableText(
            nsec,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: nsec));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Copy and close'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteDialog(BuildContext context, ProfileView p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text('Delete ${p.name}?'),
        content: const SizedBox(
          width: 460,
          child: Text(
            'This removes the profile\'s key and data from this device. Unless you exported '
            'its secret key, the account cannot be recovered. Files shared with other profiles stay.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await _run(_core.deleteProfile(p.id));
  }
}

/// A one-field dialog that owns its controller, so the field is never left
/// holding a disposed controller while the dialog animates out.
class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.label,
    required this.action,
    this.initial = '',
  });
  final String title;
  final String label;
  final String action;
  final String initial;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _c,
          autofocus: true,
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _c.text),
          child: Text(widget.action),
        ),
      ],
    );
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _key = TextEditingController();
  final _name = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _key.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await Core.instance.importProfile(
      _key.text,
      name: _name.text,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile imported and selected')),
      );
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import a profile'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste a secret key. It becomes a new profile on this device; '
              'your current profiles stay as they are.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _key,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'nsec1...',
                border: const OutlineInputBorder(),
                errorText: _error,
                errorMaxLines: 3,
              ),
              onSubmitted: (_) => _import(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name (optional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _import,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Import'),
        ),
      ],
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile(this.folder, {this.onRemove});
  final StorageFolder folder;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final free = folder.free;
    return ListTile(
      leading: Radio<String>(value: folder.path),
      title: Row(
        children: [
          Flexible(
            child: Text(
              folder.path,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
          if (folder.isDefault) ...[
            const SizedBox(width: 8),
            Text(
              'Default',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          if (free != null)
            LinearProgressIndicator(
              value: folder.used / (folder.used + free).clamp(1, 1 << 62),
            ),
          const SizedBox(height: 4),
          Text(
            '${formatBytes(folder.used)} used by Arca${free == null ? '' : '  -  ${formatBytes(free)} free'}',
          ),
        ],
      ),
      trailing: IconButton(
        tooltip: onRemove == null
            ? 'The only storage folder'
            : 'Stop using this folder',
        icon: const Icon(Icons.delete_outline),
        onPressed: onRemove,
      ),
    );
  }
}
