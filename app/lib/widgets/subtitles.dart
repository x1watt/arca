import 'dart:io';

import 'package:flutter/material.dart';

import '../core/core_client.dart';
import 'common.dart';

/// Names for the languages whisper reports most often; others show the code.
const _languages = {
  'en': 'English',
  'pt': 'Portuguese',
  'de': 'German',
  'es': 'Spanish',
  'fr': 'French',
  'it': 'Italian',
  'nl': 'Dutch',
  'pl': 'Polish',
  'ru': 'Russian',
  'uk': 'Ukrainian',
  'tr': 'Turkish',
  'ar': 'Arabic',
  'zh': 'Chinese',
  'ja': 'Japanese',
  'ko': 'Korean',
  'hi': 'Hindi',
  'sv': 'Swedish',
  'da': 'Danish',
  'no': 'Norwegian',
  'fi': 'Finnish',
  'cs': 'Czech',
  'el': 'Greek',
  'he': 'Hebrew',
  'ro': 'Romanian',
  'hu': 'Hungarian',
  'id': 'Indonesian',
  'vi': 'Vietnamese',
  'th': 'Thai',
};

String languageName(String? code) =>
    code == null ? '' : _languages[code] ?? code.toUpperCase();

/// One line of a SubRip file.
class Cue {
  const Cue(this.start, this.text);
  final Duration start;
  final String text;
}

List<Cue> parseSrt(String srt) {
  final cues = <Cue>[];
  final time = RegExp(r'(\d+):(\d+):(\d+),(\d+)\s*-->');
  for (final block in srt.replaceAll('\r', '').split('\n\n')) {
    final lines = block.trim().split('\n');
    final i = lines.indexWhere(time.hasMatch);
    if (i < 0) continue;
    final m = time.firstMatch(lines[i])!;
    final text = lines.skip(i + 1).join(' ').trim();
    if (text.isEmpty) continue;
    cues.add(
      Cue(
        Duration(
          hours: int.parse(m[1]!),
          minutes: int.parse(m[2]!),
          seconds: int.parse(m[3]!),
          milliseconds: int.parse(m[4]!),
        ),
        text,
      ),
    );
  }
  return cues;
}

String _clock(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// The subtitles part of a video or audio file's page: the transcript when
/// there is one, the running job, or a way to start one.
class SubtitlePanel extends StatelessWidget {
  const SubtitlePanel({super.key, required this.file, required this.status});
  final FileView file;
  final SubtitleStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final core = Core.instance;
    Future<void> run(Future<String?> action) async {
      final error = await action;
      if (error != null && context.mounted) showMessage(context, error);
    }

    if (status.currentSha == file.sha256) {
      final reading = status.progress < 0;
      return ListTile(
        leading: const Icon(Icons.subtitles_outlined),
        title: Text(reading ? 'Reading the audio' : 'Making subtitles'),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: LinearProgressIndicator(
            value: reading ? null : status.progress / 100,
          ),
        ),
        trailing: TextButton(
          onPressed: () => run(core.stopSubtitles()),
          child: const Text('Stop'),
        ),
      );
    }

    final subtitles = file.subtitles;
    if (subtitles != null) {
      return _Transcript(
        path: subtitles,
        language: languageName(file.subtitleLanguage),
        machine: file.subtitleMachine,
        onRedo: status.hasModel && file.subtitleMachine
            ? () => run(core.makeSubtitles(file))
            : null,
      );
    }

    if (!status.available) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.subtitles_outlined),
      title: const Text('Subtitles'),
      subtitle: Text(
        !status.hasModel
            ? 'Download a speech model in Settings, under Subtitles, to make '
                  'subtitles on this device.'
            : file.subtitleError != null
            ? 'Not made: ${file.subtitleError}'
            : status.auto
            ? 'Waiting for the files before it.'
            : 'None yet.',
        style: muted,
      ),
      trailing: status.hasModel
          ? FilledButton.tonal(
              onPressed: () => run(core.makeSubtitles(file)),
              child: const Text('Make subtitles'),
            )
          : null,
    );
  }
}

class _Transcript extends StatefulWidget {
  const _Transcript({
    required this.path,
    required this.language,
    required this.machine,
    required this.onRedo,
  });
  final String path;
  final String language;
  final bool machine;
  final VoidCallback? onRedo;

  @override
  State<_Transcript> createState() => _TranscriptState();
}

class _TranscriptState extends State<_Transcript> {
  late Future<List<Cue>> _cues = _load();

  Future<List<Cue>> _load() async =>
      parseSrt(await File(widget.path).readAsString());

  @override
  void didUpdateWidget(_Transcript old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _cues = _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      leading: const Icon(Icons.subtitles_outlined),
      title: Text(
        widget.language.isEmpty
            ? 'Transcript'
            : 'Transcript (${widget.language})',
      ),
      subtitle: Text(
        widget.machine
            ? 'Made on this device by speech recognition'
            : 'From ${widget.path.split('/').last}',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        FutureBuilder(
          future: _cues,
          builder: (context, snap) {
            final cues = snap.data;
            if (cues == null) return const LinearProgressIndicator();
            if (cues.isEmpty) {
              return const Text('No speech was found in this file.');
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final c in cues)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 64,
                          child: Text(
                            _clock(c.start),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        Expanded(child: Text(c.text)),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
        if (widget.onRedo != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: widget.onRedo,
              child: const Text('Make again with the current model'),
            ),
          ),
      ],
    );
  }
}

/// The Subtitles part of Settings: which speech model this device uses,
/// downloading it, and whether new files are done automatically.
class SubtitleSettings extends StatelessWidget {
  const SubtitleSettings({super.key, required this.status});
  final SubtitleStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final core = Core.instance;
    Future<void> run(Future<String?> action) async {
      final error = await action;
      if (error != null && context.mounted) showMessage(context, error);
    }

    if (!status.available) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          'Speech recognition is not part of this build.',
          style: muted,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Subtitles are made on this device from the speech in videos and '
            'audio. The speech model is downloaded once from Arca\'s releases on '
            'GitHub and checked against its fingerprint; larger models are more '
            'accurate but slower.',
            style: muted,
          ),
        ),
        RadioGroup<String>(
          groupValue: status.selected,
          onChanged: (id) => run(core.selectModel(id!)),
          child: Column(
            children: [
              for (final m in status.models)
                _ModelTile(
                  model: m,
                  recommended: m.id == status.recommended,
                  onRun: run,
                ),
            ],
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.auto_awesome_outlined),
          title: const Text('Make subtitles automatically'),
          subtitle: const Text(
            'For every video and audio file in your collections, one at a time '
            'in the background.',
          ),
          value: status.auto,
          onChanged: (v) => run(core.setAutoSubtitles(v)),
        ),
        if (status.currentSha != null)
          ListTile(
            leading: const Icon(Icons.subtitles_outlined),
            title: Text('Working on ${status.currentName}'),
            subtitle: Text(
              [
                status.progress < 0
                    ? 'Reading the audio'
                    : '${status.progress}% done',
                if (status.queued > 0) '${status.queued} more waiting',
              ].join(', '),
            ),
            trailing: TextButton(
              onPressed: () => run(core.stopSubtitles()),
              child: const Text('Stop'),
            ),
          ),
      ],
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.model,
    required this.recommended,
    required this.onRun,
  });
  final SpeechModelView model;
  final bool recommended;
  final Future<void> Function(Future<String?>) onRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = model;
    final core = Core.instance;
    final lines = <String>[
      m.detail,
      if (m.downloading)
        'Downloading ${formatBytes(m.received)} of ${formatBytes(m.bytes)}'
      else if (!m.installed && m.received > 0)
        '${formatBytes(m.received)} of ${formatBytes(m.bytes)} downloaded, '
            'continue to finish'
      else
        formatBytes(m.bytes),
    ];
    final action = m.installed
        ? TextButton.icon(
            onPressed: () => onRun(core.deleteModel(m.id)),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          )
        : m.downloading
        ? TextButton.icon(
            onPressed: () => onRun(core.stopDownload(m.id)),
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Stop'),
          )
        : TextButton.icon(
            onPressed: () => onRun(core.downloadModel(m.id)),
            icon: const Icon(Icons.download_outlined),
            label: Text(m.received > 0 ? 'Continue' : 'Download'),
          );
    // Actions sit under the text, so the row stays readable on a phone.
    return ListTile(
      leading: Radio<String>(value: m.id, enabled: m.installed),
      title: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(m.label),
          if (recommended)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Recommended for this device',
                style: theme.textTheme.labelSmall,
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(lines.join('\n')),
          if (m.downloading)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(
                value: m.bytes == 0 ? null : m.received / m.bytes,
              ),
            ),
          if (m.error != null)
            Text(m.error!, style: TextStyle(color: theme.colorScheme.error)),
          Align(alignment: AlignmentDirectional.centerStart, child: action),
        ],
      ),
    );
  }
}
