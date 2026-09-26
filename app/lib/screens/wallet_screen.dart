// The wallet: the active profile's marcas on the test chain, what it keeps
// for its circle and what that earns, and the circle's pool. Everything
// shown comes from the chain the core runs (docs/architecture.md, 10).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_client.dart';
import '../widgets/collab.dart' show askText;
import '../widgets/common.dart';

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet')),
      body: ValueListenableBuilder(
        valueListenable: Core.instance.state,
        builder: (context, state, _) {
          final chain = state?.chain;
          if (state == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (chain != null) return _OnChain(chain: chain);
          if (state.chainPending) return _Waiting(error: state.chainError);
          return _NotOnChain(state: state);
        },
      ),
    );
  }
}

Future<void> _run(
  BuildContext context,
  Future<String?> action, [
  String? done,
]) async {
  final error = await action;
  if (!context.mounted) return;
  if (error != null) {
    showMessage(context, error);
  } else if (done != null) {
    showMessage(context, done);
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({this.error});
  final String? error;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: error == null ? Icons.hourglass_top_outlined : Icons.error_outline,
      title: error == null
          ? 'Connecting to the test network'
          : 'The test network could not start',
      text:
          error ??
          'Waiting for the I2P network, which takes a minute or two after Arca starts. '
              'The wallet appears here as soon as this device follows the chain.',
      action: TextButton(
        onPressed: () => _run(context, Core.instance.chainLeave()),
        child: const Text('Leave the test network'),
      ),
    );
  }
}

class _NotOnChain extends StatefulWidget {
  const _NotOnChain({required this.state});
  final CoreState state;

  @override
  State<_NotOnChain> createState() => _NotOnChainState();
}

class _NotOnChainState extends State<_NotOnChain> {
  bool _busy = false;

  /// Why the last start or join failed; stays on screen until the next try.
  String? _error;

  Future<void> _do(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await action();
    if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  Future<void> _start() async {
    final collections = widget.state.collections
        .where((c) => c.files.isNotEmpty)
        .toList();
    if (collections.isEmpty) {
      showMessage(
        context,
        'Add files to a collection first: a test network starts from one of your collections.',
      );
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Start a test network from'),
        children: [
          for (final c in collections)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, c.id),
              child: ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(c.name),
                subtitle: Text(
                  '${plural(c.files.length, 'file')}, ${formatBytes(c.size)}',
                ),
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await _do(() => Core.instance.chainStart(picked));
  }

  Future<void> _join() async {
    final invite = await askText(
      context,
      title: 'Join a test network',
      label: 'Invite',
      hint: 'arca-chain:...',
    );
    if (invite == null || invite.isEmpty || !mounted) return;
    await _do(() => Core.instance.chainJoin(invite));
  }

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.toll_outlined,
      title: _error != null
          ? 'That did not work'
          : 'Marcas are earned by keeping files',
      text: _error != null
          ? _error!
          : 'Keep a copy of a circle\'s files and prove it every day, and the chain pays your circle in marcas. '
                'This is a test network: its marcas have no value. Start one from one of your collections, '
                'or join one with an invite from someone who started it.',
      action: _busy
          ? const Column(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Setting up. Joining can take a minute over I2P.'),
              ],
            )
          : Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: const Text('Start a test network'),
                ),
                OutlinedButton.icon(
                  onPressed: _join,
                  icon: const Icon(Icons.group_add_outlined),
                  label: const Text('Join with an invite'),
                ),
              ],
            ),
    );
  }
}

class _OnChain extends StatelessWidget {
  const _OnChain({required this.chain});
  final ChainView chain;

  Future<void> _send(BuildContext context) async {
    final r = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _SendDialog(),
    );
    if (r == null || !context.mounted) return;
    await _run(
      context,
      Core.instance.chainSend(r.$1, r.$2),
      'Sent. It is final once in a block.',
    );
  }

  Future<void> _copy(BuildContext context, String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) showMessage(context, '$what copied');
  }

  Future<void> _leave(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave this test network?'),
        content: const Text(
          'This device stops following the chain and keeping its files. The copy of the collection stays.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await _run(context, Core.instance.chainLeave());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final me = Core.instance.state.value?.active;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    formatMarcas(chain.balance),
                    style: theme.textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Test network "${chain.name}". Its marcas have no value.',
                    style: muted,
                  ),
                  const SizedBox(height: 4),
                  _DayLine(chain: chain),
                  if (chain.pending > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${plural(chain.pending, 'transaction')} waiting for a block',
                      style: muted,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _send(context),
                        icon: const Icon(Icons.send_outlined),
                        label: const Text('Send'),
                      ),
                      OutlinedButton.icon(
                        onPressed: me == null
                            ? null
                            : () => _copy(context, me.npub, 'Your address'),
                        icon: const Icon(Icons.qr_code_2_outlined),
                        label: const Text('Receive'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _copy(context, chain.invite, 'Invite'),
                        icon: const Icon(Icons.person_add_alt),
                        label: const Text('Copy invite'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        const SectionTitle('Keeping files'),
        _Keeping(chain: chain),
        SectionTitle(chain.circleName.isEmpty ? 'Circle' : chain.circleName),
        _Circle(chain: chain),
        const Divider(height: 32),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Leave this test network'),
          onTap: () => _leave(context),
        ),
      ],
    );
  }
}

/// "Day 4, the next starts in 3:12. Block 812, 2 peers."
class _DayLine extends StatefulWidget {
  const _DayLine({required this.chain});
  final ChainView chain;

  @override
  State<_DayLine> createState() => _DayLineState();
}

class _DayLineState extends State<_DayLine> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.chain;
    final left = ((c.nextDayAt - DateTime.now().millisecondsSinceEpoch) ~/ 1000)
        .clamp(0, c.dayLength);
    final clock = '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}';
    final net = Core.instance.state.value?.net;
    if (net != null && net != NetStatus.up) {
      return Text(
        net == NetStatus.failed
            ? 'I2P is not connected, so this device neither hears nor reaches the network (Settings, Network).'
            : 'Connecting to I2P...',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final text = c.behind
        ? 'Catching up with the chain: block ${c.height}, ${plural(c.peers, 'peer')}.'
        : 'Day ${c.day}, the next starts in $clock. Block ${c.height}, ${plural(c.peers, 'peer')}.';
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _Keeping extends StatelessWidget {
  const _Keeping({required this.chain});
  final ChainView chain;

  String _status(PartitionView p) {
    if (!p.keep) return 'Not kept on this device';
    if (p.packing != null) {
      return 'Preparing the copy: ${(p.packing! * 100).round()}%';
    }
    if (!p.packed) return 'Waiting to be prepared';
    if (!p.declared) return 'Ready; being registered on the chain';
    if (p.provenToday) return 'Kept and proven today';
    if (!p.dueToday) return 'Kept; the first proof is due tomorrow';
    return 'Kept; today\'s proof is on its way';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (chain.light) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.phone_android_outlined),
            title: const Text('Following the chain lightly'),
            subtitle: Text(
              'This device checks block headers and reads what it needs with proofs. '
              'It keeps no files, so it earns nothing, and it is easy on the battery.',
              style: muted,
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.inventory_2_outlined),
            title: const Text('Keep files on this device'),
            subtitle: Text(
              'Copies the circle\'s files, proves them every day and earns for the circle. '
              'Uses disk space and, while making blocks, some battery.',
              style: muted,
            ),
            value: false,
            onChanged: (v) => _run(context, Core.instance.chainLight(!v)),
          ),
        ],
      );
    }
    if (!chain.corpusReady) {
      final text =
          chain.corpusError ??
          (chain.corpusBuilding
              ? 'Checking the files against the chain...'
              : 'Copying the circle\'s files: ${chain.corpusPresent} of ${plural(chain.corpusFiles, 'file')}.');
      return ListTile(
        leading: chain.corpusError == null
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.error_outline, color: theme.colorScheme.error),
        title: Text(text),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in chain.partitions)
          ListTile(
            leading: Icon(
              p.provenToday
                  ? Icons.verified_outlined
                  : p.keep
                  ? Icons.inventory_2_outlined
                  : Icons.inventory_outlined,
            ),
            title: Text('Part ${p.index + 1}, ${formatBytes(p.bytes)}'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_status(p)}. ${plural(p.copies, 'copy')} on the network.',
                  style: muted,
                ),
                if (p.packing != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(value: p.packing),
                  ),
              ],
            ),
            trailing: Switch(
              value: p.keep,
              onChanged: (v) =>
                  _run(context, Core.instance.chainKeep(p.index, v)),
            ),
          ),
        SwitchListTile(
          secondary: const Icon(Icons.bolt_outlined),
          title: const Text('Take part in making blocks'),
          subtitle: Text(switch (chain.paused) {
            'charging' when chain.mining => 'Waiting until the device charges (Settings, Sharing). Daily proofs still go out.',
            'network' when chain.mining => 'Waiting for Wi-Fi or a cable (Settings, Sharing). Daily proofs still go out.',
            _ =>
              'Uses a little disk and processor time each second while Arca is open, '
                  'within the sharing limits in Settings.',
          }, style: muted),
          value: chain.mining,
          onChanged: (v) => _run(context, Core.instance.chainMining(v)),
        ),
        if (!chain.founder)
          SwitchListTile(
            secondary: const Icon(Icons.inventory_2_outlined),
            title: const Text('Keep files on this device'),
            subtitle: Text(
              'Off: follow the chain lightly, keeping nothing (for phones).',
              style: muted,
            ),
            value: true,
            onChanged: (v) => _run(context, Core.instance.chainLight(!v)),
          ),
        ListTile(
          leading: const Icon(Icons.insights_outlined),
          title: Text(
            'Standing ${formatMarcas(chain.standing).replaceFirst(' marcas', '')}, sync score ${chain.syncScore}',
          ),
          subtitle: Text(
            'Standing grows with the interest in what you keep; the sync score with how much you keep, '
            'more for rare parts. Both reset if a daily proof is missed.',
            style: muted,
          ),
        ),
      ],
    );
  }
}

class _Circle extends StatelessWidget {
  const _Circle({required this.chain});
  final ChainView chain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.savings_outlined),
          title: Text('Pool: ${formatMarcas(chain.pool)}'),
          subtitle: Text(
            chain.isAdmin
                ? 'What the circle\'s keepers earned. As admin you pay it out: 45% to keepers by sync score, '
                      '45% to the collection\'s contributor, 10% to the admin and moderators.'
                : 'What the circle\'s keepers earned, waiting for the admin to pay it out. '
                      'You have claimed ${formatMarcas(chain.claimed)} so far.',
            style: muted,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (chain.isAdmin)
                FilledButton.tonal(
                  onPressed: () => _run(
                    context,
                    Core.instance.chainPayout(),
                    'Paid out. Members can claim once the circle anchors it, within a minute or so.',
                  ),
                  child: const Text('Pay out the pool'),
                ),
              OutlinedButton(
                onPressed: () => _run(
                  context,
                  Core.instance.chainClaim(),
                  'Claimed. It arrives with the next block.',
                ),
                child: const Text('Claim my share'),
              ),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.menu_book_outlined),
          title: Text(
            'Reading: free up to ${formatBytes(chain.freeAllowance)} a day',
          ),
          subtitle: Text(
            [
              chain.passPrice > 0
                  ? 'A 24-hour pass for more costs ${formatMarcas(chain.passPrice)}: half is burned, half goes to whoever serves the files.'
                  : 'No passes are sold.',
              if (chain.memberScore > 0)
                'Members with a sync score of ${chain.memberScore} or more read freely.'
              else
                'Members who keep the circle\'s files read freely.',
              if (chain.passEndsAt != null)
                'Your pass runs until ${_time(chain.passEndsAt!)}.',
            ].join(' '),
            style: muted,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (chain.passPrice > 0 && chain.passEndsAt == null)
                OutlinedButton(
                  onPressed: () => _run(
                    context,
                    Core.instance.chainBuyPass(),
                    'Pass bought. It starts with the next block.',
                  ),
                  child: const Text('Buy a pass'),
                ),
              if (chain.isAdmin)
                OutlinedButton(
                  onPressed: () => _readingSettings(context, chain),
                  child: const Text('Reading settings'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SendDialog extends StatefulWidget {
  const _SendDialog();

  @override
  State<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends State<_SendDialog> {
  final _to = TextEditingController();
  final _amount = TextEditingController();

  @override
  void dispose() {
    _to.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Send marcas'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _to,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'To',
              hintText: 'npub1... or an Arca address',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Amount in marcas',
              hintText: '12.5',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, (_to.text.trim(), _amount.text.trim())),
        child: const Text('Send'),
      ),
    ],
  );
}

String _time(int millis) {
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

Future<void> _readingSettings(BuildContext context, ChainView chain) async {
  final r = await showDialog<(String, String, String)>(
    context: context,
    builder: (_) => _ReadingDialog(chain: chain),
  );
  if (r == null || !context.mounted) return;
  final megabytes = int.tryParse(r.$2);
  final score = int.tryParse(r.$3);
  if (megabytes == null || score == null) {
    showMessage(
      context,
      'Enter whole numbers for the allowance and the score.',
    );
    return;
  }
  await _run(
    context,
    Core.instance.chainReading(
      passPrice: r.$1,
      freeAllowance: megabytes * 1024 * 1024,
      memberScore: score,
    ),
    'Saved. The circle\'s next anchor puts it on the chain.',
  );
}

class _ReadingDialog extends StatefulWidget {
  const _ReadingDialog({required this.chain});
  final ChainView chain;

  @override
  State<_ReadingDialog> createState() => _ReadingDialogState();
}

class _ReadingDialogState extends State<_ReadingDialog> {
  late final _price = TextEditingController(
    text: formatMarcas(widget.chain.passPrice)
        .replaceFirst(' marcas', '')
        .replaceAll(',', ''),
  );
  late final _allowance = TextEditingController(
    text: '${widget.chain.freeAllowance ~/ (1024 * 1024)}',
  );
  late final _score = TextEditingController(
    text: '${widget.chain.memberScore}',
  );

  @override
  void dispose() {
    _price.dispose();
    _allowance.dispose();
    _score.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('How the circle is read'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Price of a 24-hour pass, in marcas',
              helperText: '0 sells no passes',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _allowance,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Free reading per person per day, in MB',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _score,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Sync score for free member access',
              helperText: '0: every member who keeps files',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, (
          _price.text.trim(),
          _allowance.text.trim(),
          _score.text.trim(),
        )),
        child: const Text('Save'),
      ),
    ],
  );
}
