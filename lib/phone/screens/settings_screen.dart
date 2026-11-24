import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../phone_controller.dart';
import 'about_screen.dart';
import 'devices_screen.dart';
import 'ui.dart';

const _ownerNote = 'Only the owner can change this';

/// The Settings destination: one scrolling page, one titled card per topic.
/// Everyone reads every value; only the owner changes them.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.versionLoader,
    this.onForgetPi,
  });

  final PhoneController controller;
  final VersionLoader? versionLoader;

  /// Called after the user confirms "Forget this Pi"; defaults to the
  /// controller's own.
  final Future<void> Function()? onForgetPi;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// What the user just chose, until the Pi answers.
  final Map<String, Object?> _optimistic = {};

  /// Why the Pi refused a value, by setting key.
  final Map<String, String> _errors = {};

  PhoneController get c => widget.controller;

  Object? _value(String key) =>
      _optimistic.containsKey(key) ? _optimistic[key] : c.settings[key];

  /// The newest request per key: an older reply must not undo a newer
  /// choice.
  final Map<String, int> _seq = {};

  Future<void> _save(String key, Object value) async {
    final seq = _seq[key] = (_seq[key] ?? 0) + 1;
    setState(() {
      _optimistic[key] = value;
      _errors.remove(key);
    });
    final r = await c.updateSettings({key: value});
    if (!mounted || _seq[key] != seq) return;
    setState(() {
      _optimistic.remove(key);
      if (!r.ok) _errors[key] = r.message ?? 'The change was refused';
    });
    if (r.ok) {
      showBrief(context, 'Saved');
    } else if (r.field == null || r.field != key) {
      // The Pi named no field (offline, forbidden): say it where it is seen.
      showBrief(context, r.message ?? 'The change was refused');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final enabled = c.canChangeSettings;
        return PageList(
          children: [
            _AccessNote(controller: c),
            if (c.hasSettings) ...[
              _playback(enabled),
              _storage(enabled),
              _network(enabled),
            ] else
              const _NoSettings(),
            _devices(),
            AboutPane(controller: c, versionLoader: widget.versionLoader),
          ],
        );
      },
    );
  }

  // ---- Playback ----

  Widget _playback(bool enabled) {
    final theme = Theme.of(context);
    final lim = c.limitFor('imageSeconds');
    final min = (lim?['min'] ?? 3).toDouble();
    final max = (lim?['max'] ?? 120).toDouble();
    final seconds = ((_value('imageSeconds') as int?) ?? 10).clamp(
      min.toInt(),
      max.toInt(),
    );
    final transition = (_value('transition') as String?) ?? 'crossfade';
    return PaneCard(
      title: 'Playback',
      icon: Icons.slideshow_outlined,
      intro: 'How photos and videos appear on the TV.',
      children: [
        _OwnerLine(controller: c),
        _DurationSlider(
          key: const Key('setting-imageSeconds'),
          seconds: seconds,
          min: min,
          max: max,
          enabled: enabled,
          error: _errors['imageSeconds'],
          onSave: (v) => _save('imageSeconds', v),
        ),
        const SizedBox(height: 8),
        Text('Change between items', style: theme.textTheme.bodyLarge),
        Text(
          transition == 'cut'
              ? 'Cut jumps straight to the next one.'
              : 'Crossfade blends one into the next.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            key: const Key('setting-transition'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'crossfade', label: Text('Crossfade')),
              ButtonSegment(value: 'cut', label: Text('Cut')),
            ],
            selected: {transition},
            onSelectionChanged: enabled
                ? (s) => _save('transition', s.first)
                : null,
          ),
        ),
        if (_errors['transition'] != null) _FieldError(_errors['transition']!),
        const SizedBox(height: 8),
        _SwitchRow(
          key: const Key('setting-kenBurns'),
          title: 'Slow zoom on photos',
          subtitle: 'Photos drift and zoom gently while they are shown.',
          value: (_value('kenBurns') as bool?) ?? false,
          enabled: enabled,
          error: _errors['kenBurns'],
          onChanged: (v) => _save('kenBurns', v),
        ),
        _SwitchRow(
          key: const Key('setting-playWithSound'),
          title: 'Play with sound',
          subtitle: 'Videos play their sound on the TV.',
          value: (_value('playWithSound') as bool?) ?? true,
          enabled: enabled,
          error: _errors['playWithSound'],
          onChanged: (v) => _save('playWithSound', v),
        ),
      ],
    );
  }

  // ---- Library and storage ----

  Widget _storage(bool enabled) {
    final theme = Theme.of(context);
    final cap = c.storageCapBytes;
    final used = c.storageUsedBytes;
    final over = cap > 0 && used > cap;
    final ratio = cap <= 0 ? 0.0 : (used / cap).clamp(0.0, 1.0);
    final color = over ? theme.colorScheme.error : theme.colorScheme.primary;
    return PaneCard(
      title: 'Library and storage',
      icon: Icons.photo_library_outlined,
      intro: 'How much room your photos and videos may take on the Pi.',
      children: [
        _OwnerLine(controller: c),
        if (!c.hasLibrary || cap <= 0)
          const InfoRow(label: 'Used', value: 'Loading…')
        else ...[
          Text(
            '${formatBytes(used)} of ${formatBytes(cap)} used',
            key: const Key('storage-text'),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Semantics(
            label: 'Storage used',
            value: '${(ratio * 100).round()} percent',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                key: const Key('storage-bar'),
                value: ratio,
                minHeight: 10,
                color: color,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          if (over)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Over the limit. New uploads are refused until you free up '
                'space or raise the limit. Nothing is deleted.',
                key: const Key('storage-over'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
        const SizedBox(height: 16),
        _NumberField(
          key: const Key('setting-storageCapBytes'),
          label: 'Storage limit',
          unit: 'GB',
          help: 'The most the library may use on the Pi.',
          valueInUnit: (((_value('storageCapBytes') as int?) ?? 0)) / 1e9,
          scale: 1e9,
          decimals: true,
          min: c.limitFor('storageCapBytes')?['min'],
          max: c.limitFor('storageCapBytes')?['max'],
          enabled: enabled,
          error: _errors['storageCapBytes'],
          onSave: (v) => _save('storageCapBytes', v),
          onEdit: () => setState(() => _errors.remove('storageCapBytes')),
        ),
      ],
    );
  }

  // ---- Network and streaming ----

  Widget _network(bool enabled) {
    final theme = Theme.of(context);
    final ceiling = (_value('streamingCeilingMbps') as int?) ?? 0;
    final cache = (_value('tvCacheBytes') as int?) ?? 0;
    return PaneCard(
      title: 'Network and streaming',
      icon: Icons.wifi,
      intro: 'How videos travel from the Pi to the TV.',
      children: [
        _OwnerLine(controller: c),
        _NumberField(
          key: const Key('setting-streamingCeilingMbps'),
          label: 'Streaming limit',
          unit: 'Mbps',
          help:
              'Videos above this speed are copied to the TV before they '
              'play.',
          valueInUnit: ceiling.toDouble(),
          scale: 1,
          decimals: false,
          min: c.limitFor('streamingCeilingMbps')?['min'],
          max: c.limitFor('streamingCeilingMbps')?['max'],
          enabled: enabled,
          error: _errors['streamingCeilingMbps'],
          onSave: (v) => _save('streamingCeilingMbps', v),
          onEdit: () => setState(() => _errors.remove('streamingCeilingMbps')),
        ),
        const SizedBox(height: 16),
        _NumberField(
          key: const Key('setting-tvCacheBytes'),
          label: 'TV cache size',
          unit: 'GB',
          help: 'Room on the TV for those copies.',
          valueInUnit: cache / 1e9,
          scale: 1e9,
          decimals: true,
          min: c.limitFor('tvCacheBytes')?['min'],
          max: c.limitFor('tvCacheBytes')?['max'],
          enabled: enabled,
          error: _errors['tvCacheBytes'],
          onSave: (v) => _save('tvCacheBytes', v),
          onEdit: () => setState(() => _errors.remove('tvCacheBytes')),
        ),
        const SizedBox(height: 16),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lightbulb_outline,
                  size: 20,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Why this matters: the TV reads videos over Wi-Fi. If a '
                    'video is more than the Wi-Fi can carry, it would '
                    'stutter. Copying it first keeps playback smooth, but '
                    'the TV has little free storage, so keep the cache '
                    'small.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---- Devices and pairing ----

  Widget _devices() {
    final theme = Theme.of(context);
    final canForgetAll = c.canChangeSettings;
    return PaneCard(
      title: 'Devices and pairing',
      icon: Icons.devices_outlined,
      intro: 'Phones and the TV that are paired with this Pi.',
      children: [
        Text('This phone', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                c.me?.name ?? 'Phone',
                key: const Key('my-name'),
                style: theme.textTheme.titleMedium,
              ),
            ),
            OutlinedButton.icon(
              key: const Key('rename-this-phone'),
              onPressed: c.isLinked ? () => showRenameDialog(context, c) : null,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Rename'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Paired devices', style: theme.textTheme.labelLarge),
        DeviceList(controller: c),
        const SizedBox(height: 16),
        _OwnerLine(controller: c),
        OutlinedButton.icon(
          key: const Key('forget-all'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            foregroundColor: theme.colorScheme.error,
          ),
          onPressed: canForgetAll
              ? () => confirmForgetAllPhones(context, c)
              : null,
          icon: const Icon(Icons.group_off_outlined),
          label: const Text('Forget all phones'),
        ),
        const SizedBox(height: 4),
        Text(
          'Every phone has to pair again. The next one becomes the owner.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          key: const Key('forget-pi'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: () => _confirmForgetPi(context),
          icon: const Icon(Icons.link_off),
          label: const Text('Forget this Pi'),
        ),
        const SizedBox(height: 4),
        Text(
          'Only this phone stops controlling it.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _confirmForgetPi(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget this Pi?'),
        content: const Text(
          'This phone will stop controlling it. Other phones and the TV '
          'are not affected, and the Pi keeps the device record of this phone. '
          'To control it again, ask the owner, or use Forget all phones on '
          'the TV.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('forget-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    final custom = widget.onForgetPi;
    if (custom != null) return custom();
    final ok = await c.forgetThisPi();
    if (!ok && context.mounted) {
      showBrief(context, 'Could not forget this Pi.');
    }
  }
}

/// The Pi sent no settings (an older Pi software, or the link just came up).
class _NoSettings extends StatelessWidget {
  const _NoSettings();

  @override
  Widget build(BuildContext context) {
    return const PaneCard(
      key: Key('no-settings'),
      title: 'Settings not available',
      icon: Icons.settings_suggest_outlined,
      children: [
        Text(
          'The Pi has not shared its settings with this phone. If this stays '
          'like this, update the software on the Pi.',
        ),
      ],
    );
  }
}

/// Says who may change the settings, or why nobody can right now.
class _AccessNote extends StatelessWidget {
  const _AccessNote({required this.controller});

  final PhoneController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.isLinked) return const SizedBox.shrink();
    final theme = Theme.of(context);
    const text =
        'The Pi is not reachable. You see the last values, and nothing can '
        'be changed until it is back.';
    return Padding(
      padding: const EdgeInsets.only(bottom: kGap),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            key: const Key('owner-note'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Read only for now',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(text, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Only the owner can change this", at the top of a pane, for a controller.
class _OwnerLine extends StatelessWidget {
  const _OwnerLine({required this.controller});

  final PhoneController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.isLinked || controller.canChangeSettings) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        key: const Key('owner-note'),
        children: [
          Icon(
            Icons.lock_outline,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _ownerNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldError extends StatelessWidget {
  const _FieldError(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.error,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final String? error;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: Text(subtitle),
          value: value,
          onChanged: enabled ? onChanged : null,
        ),
        if (error != null) _FieldError(error!),
      ],
    );
  }
}

/// A slider with its value in words ("12 seconds"); saves when released.
class _DurationSlider extends StatefulWidget {
  const _DurationSlider({
    super.key,
    required this.seconds,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onSave,
    this.error,
  });

  final int seconds;
  final double min;
  final double max;
  final bool enabled;
  final String? error;
  final ValueChanged<int> onSave;

  @override
  State<_DurationSlider> createState() => _DurationSliderState();
}

class _DurationSliderState extends State<_DurationSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = (_drag ?? widget.seconds.toDouble()).clamp(
      widget.min,
      widget.max,
    );
    final shown = value.round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Photo time', style: theme.textTheme.bodyLarge),
            ),
            Text(
              '$shown ${shown == 1 ? 'second' : 'seconds'}',
              key: const Key('imageSeconds-value'),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
        Text(
          'How long each photo stays on the TV.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Slider(
          key: const Key('imageSeconds-slider'),
          value: value,
          min: widget.min,
          max: widget.max,
          divisions: (widget.max - widget.min).round(),
          label: '$shown s',
          semanticFormatterCallback: (v) => '${v.round()} seconds',
          onChanged: widget.enabled ? (v) => setState(() => _drag = v) : null,
          onChangeEnd: widget.enabled
              ? (v) {
                  setState(() => _drag = null);
                  if (v.round() != widget.seconds) widget.onSave(v.round());
                }
              : null,
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('${widget.min.round()} s', style: theme.textTheme.labelSmall),
            Text('${widget.max.round()} s', style: theme.textTheme.labelSmall),
          ],
        ),
        if (widget.error != null) _FieldError(widget.error!),
      ],
    );
  }
}

/// A number with a unit that saves when the user is done typing. A value the
/// Pi (or the range) refuses goes back to what is stored, with the reason
/// under the field.
class _NumberField extends StatefulWidget {
  const _NumberField({
    super.key,
    required this.label,
    required this.unit,
    required this.help,
    required this.valueInUnit,
    required this.scale,
    required this.decimals,
    required this.enabled,
    required this.onSave,
    required this.onEdit,
    this.min,
    this.max,
    this.error,
  });

  final String label;
  final String unit;
  final String help;

  /// The stored value in [unit].
  final double valueInUnit;

  /// Stored units per [unit] (1e9 for GB).
  final double scale;
  final bool decimals;

  /// The range the Pi accepts, in stored units.
  final int? min;
  final int? max;
  final bool enabled;
  final String? error;
  final Future<void> Function(int stored) onSave;
  final VoidCallback onEdit;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _text = TextEditingController(
    text: _format(widget.valueInUnit),
  );
  final FocusNode _focus = FocusNode();
  String? _localError;

  /// A save is under way: submit and focus loss must not send it twice.
  bool _saving = false;

  String _format(double v) => trimNumber(v, widget.decimals ? 2 : 0);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted && !_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    // A change from another phone, or a refused value going back.
    if (!_focus.hasFocus && old.valueInUnit != widget.valueInUnit) {
      _text.text = _format(widget.valueInUnit);
    }
    if (widget.error != null && old.error == null) {
      _text.text = _format(widget.valueInUnit);
    }
    // The control went read-only (link lost, role changed): drop what was
    // typed.
    if (old.enabled && !widget.enabled) {
      _text.text = _format(widget.valueInUnit);
      _localError = null;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  String get _range {
    final lo = widget.min, hi = widget.max;
    if (lo == null || hi == null) return '';
    return 'Between ${_format(lo / widget.scale)} and '
        '${_format(hi / widget.scale)} ${widget.unit}.';
  }

  /// The one way a typed value is saved (Done key and focus loss).
  Future<void> _commit() async {
    if (_saving) return;
    if (!widget.enabled) {
      _text.text = _format(widget.valueInUnit);
      return;
    }
    final raw = _text.text.trim().replaceAll(',', '.');
    final parsed = double.tryParse(raw);
    if (parsed == null ||
        !parsed.isFinite ||
        (!widget.decimals && parsed != parsed.truncate())) {
      _revert(widget.decimals ? 'Enter a number' : 'Enter a whole number');
      return;
    }
    final stored = (parsed * widget.scale).round();
    final lo = widget.min, hi = widget.max;
    if ((lo != null && stored < lo) || (hi != null && stored > hi)) {
      _revert(_range.isEmpty ? 'That value is not allowed' : _range);
      return;
    }
    if (stored == (widget.valueInUnit * widget.scale).round()) {
      _text.text = _format(widget.valueInUnit);
      return;
    }
    setState(() {
      _localError = null;
      _saving = true;
    });
    try {
      await widget.onSave(stored);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _revert(String message) {
    setState(() => _localError = message);
    _text.text = _format(widget.valueInUnit);
  }

  @override
  Widget build(BuildContext context) {
    final error = _localError ?? widget.error;
    return TextField(
      controller: _text,
      focusNode: _focus,
      enabled: widget.enabled,
      keyboardType: TextInputType.numberWithOptions(decimal: widget.decimals),
      textInputAction: TextInputAction.done,
      inputFormatters: [
        FilteringTextInputFormatter.allow(
          RegExp(widget.decimals ? r'[0-9.,]' : r'[0-9]'),
        ),
        LengthLimitingTextInputFormatter(8),
      ],
      onChanged: (_) {
        if (_localError != null) setState(() => _localError = null);
        widget.onEdit();
      },
      onSubmitted: (_) => _commit(),
      decoration: InputDecoration(
        labelText: widget.label,
        suffixText: widget.unit,
        helperText: widget.help,
        helperMaxLines: 3,
        errorText: error,
        errorMaxLines: 3,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
