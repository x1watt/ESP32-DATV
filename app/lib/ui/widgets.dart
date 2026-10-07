import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final c in children) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: c),
            ],
          ),
        ),
      );
}

class InfoBanner extends StatelessWidget {
  const InfoBanner(this.text, {super.key, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: error ? cs.errorContainer : cs.secondaryContainer,
      child: Padding(padding: const EdgeInsets.all(12), child: Text(text)),
    );
  }
}

class KeyValue extends StatelessWidget {
  const KeyValue(this.k, this.v, {super.key});
  final String k, v;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 150, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: SelectableText(v)),
        ]),
      );
}

/// A number field that commits on Enter or when it loses focus.
class NumberField extends StatefulWidget {
  const NumberField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.decimals = 0,
    this.signed = false,
    this.help,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final int decimals;
  final bool signed;
  final String? help;

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final TextEditingController _t = TextEditingController(text: _fmt(widget.value));
  final FocusNode _f = FocusNode();

  String _fmt(double v) {
    var s = v.toStringAsFixed(widget.decimals);
    if (widget.decimals > 0) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    return s;
  }

  @override
  void initState() {
    super.initState();
    _f.addListener(() {
      if (!_f.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(NumberField old) {
    super.didUpdateWidget(old);
    if (!_f.hasFocus && double.tryParse(_t.text) != widget.value) _t.text = _fmt(widget.value);
  }

  void _commit() {
    final v = double.tryParse(_t.text.replaceAll(',', '.'));
    if (v != null && v != widget.value) {
      widget.onChanged(v);
    } else if (v == null) {
      _t.text = _fmt(widget.value);
    }
  }

  @override
  void dispose() {
    _t.dispose();
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _t,
        focusNode: _f,
        keyboardType: TextInputType.numberWithOptions(decimal: widget.decimals > 0, signed: widget.signed),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]'))],
        decoration: InputDecoration(labelText: widget.label, helperText: widget.help, border: const OutlineInputBorder()),
        onSubmitted: (_) => _commit(),
      );
}

class TextSetting extends StatefulWidget {
  const TextSetting({super.key, required this.label, required this.value, required this.onChanged});
  final String label, value;
  final ValueChanged<String> onChanged;

  @override
  State<TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<TextSetting> {
  late final TextEditingController _t = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _t,
        decoration: InputDecoration(labelText: widget.label, border: const OutlineInputBorder()),
        onChanged: widget.onChanged,
      );
}

class Dropdown<T> extends StatelessWidget {
  const Dropdown({super.key, required this.label, required this.value, required this.items, required this.onChanged});
  final String label;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
        key: ValueKey('$label$value${items.length}'),
        initialValue: items.containsKey(value) ? value : null,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      );
}

class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.display,
    this.divisions,
    this.trailing,
  });

  final String label;
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final String Function(double) display;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(width: 150, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display(value),
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 90, child: Text(display(value))),
        ?trailing,
      ]);
}
