import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../core/core_client.dart';
import '../screens/settings_screen.dart';
import '../screens/wallet_screen.dart';
import 'common.dart';

/// Account avatar in the top-right corner of every main tab.
class ProfileButton extends StatelessWidget {
  const ProfileButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Core.instance.state,
      builder: (context, state, _) => _menu(context, state),
    );
  }

  Widget _menu(BuildContext context, CoreState? state) {
    final scheme = Theme.of(context).colorScheme;
    final me = state?.active;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: PopupMenuButton<String>(
        tooltip: 'Profile and settings',
        offset: const Offset(0, 48),
        onSelected: (v) async {
          if (v == 'address') {
            final a = me?.arcaAddress ?? '';
            await Clipboard.setData(ClipboardData(text: a));
            if (context.mounted) showPrototypeNote(context, 'Copied');
            return;
          }
          if (v.startsWith('switch:')) {
            final error = await Core.instance.switchTo(v.substring(7));
            if (error != null && context.mounted) {
              showPrototypeNote(context, error);
            }
          } else if (v == 'settings' || v == 'folders') {
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            );
          } else if (v == 'wallet') {
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const WalletScreen()),
            );
          } else {
            showPrototypeNote(context, v);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem<String>(
            enabled: false,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: scheme.primary,
                child: Text(
                  me?.initials ?? '?',
                  style: TextStyle(color: scheme.onPrimary),
                ),
              ),
              title: Text(me?.name ?? 'Starting...'),
              subtitle: Text(me?.npubShort ?? ''),
            ),
          ),
          const PopupMenuDivider(),
          for (final p in state?.others ?? const <ProfileView>[])
            PopupMenuItem<String>(
              value: 'switch:${p.id}',
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    child: Text(
                      p.initials,
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('Switch to ${p.name}'),
                ],
              ),
            ),
          _item(
            'Copy my Arca address',
            Icons.alternate_email,
            value: 'address',
          ),
          _item(
            'Add or import a profile',
            Icons.person_add_alt,
            value: 'settings',
          ),
          const PopupMenuDivider(),
          _item('Edit profile', Icons.badge_outlined, value: 'settings'),
          _item('My circles', Icons.groups_outlined),
          _item('Wallet', Icons.toll_outlined, value: 'wallet'),
          _item('Liked and shared files', Icons.thumb_up_outlined),
          _item('History', Icons.history),
          const PopupMenuDivider(),
          _item(
            'Storage folders',
            Icons.folder_special_outlined,
            value: 'folders',
          ),
          _item('Settings', Icons.settings_outlined, value: 'settings'),
          _item('Help', Icons.help_outline),
        ],
        child: CircleAvatar(
          radius: 17,
          backgroundColor: scheme.primary,
          child: Text(
            me?.initials ?? '?',
            style: TextStyle(
              color: scheme.onPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _item(String label, IconData icon, {String? value}) {
    return PopupMenuItem<String>(
      value: value ?? label,
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }
}
