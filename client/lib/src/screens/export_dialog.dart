import 'package:flutter/material.dart';

import '../export_controller.dart';
import '../models.dart';
import '../ui/widgets.dart';

/// Колонки шаблона экспорта (ключи export-сервиса) и их подписи.
const exportColumns = {
  'number': '№',
  'start': 'Начало',
  'end': 'Конец',
  'shot': 'План',
  'description': 'Описание',
  'dialogue': 'Диалоги',
};

const _formats = [
  ('xlsx', 'Excel', '.xlsx · таблица', GIcons.fileX, Cs.success),
  ('docx', 'Word', '.docx · документ', GIcons.fileW, Cs.accentInk),
  ('pdf', 'PDF', '.pdf · для печати', GIcons.fileP, Cs.danger),
];

/// Экспорт листа (FR-C12, этап 5): формат, колонки и последние файлы. Файл формируется в фоне,
/// окно можно закрыть: готовность придёт уведомлением.
class ExportDialog extends StatefulWidget {
  const ExportDialog({super.key, required this.controller, required this.subtitle, required this.onSave});
  final ExportController controller;
  final String subtitle;
  final void Function(ExportJob job) onSave;

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  String _format = 'xlsx';
  final Set<String> _columns = {...exportColumns.keys};
  bool _sending = false;

  Map<String, Object?>? get _options => _columns.length == exportColumns.length
      ? null
      : {'columns': exportColumns.keys.where(_columns.contains).toList()};

  Future<void> _request([String? format]) async {
    setState(() => _sending = true);
    await widget.controller.request(format ?? _format, options: _options);
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final label = _formats.firstWhere((f) => f.$1 == _format).$2;
    return CsDialog(
      title: 'Экспорт листа',
      subtitle: widget.subtitle,
      icon: GIcons.download,
      width: 620,
      footerNote: 'Файл появится в списке ниже, окно можно закрыть.',
      actions: [
        Btn('Закрыть', kind: BtnKind.ghost, onPressed: () => Navigator.pop(context)),
        Btn(
          'Сформировать $label',
          kind: BtnKind.primary,
          onPressed: _sending || _columns.isEmpty ? null : () => _request(),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CapsLabel('Формат'),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final (i, f) in _formats.indexed) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: _formatCard(f)),
              ],
            ],
          ),
          const SizedBox(height: 20),
          const CapsLabel('Колонки'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in exportColumns.entries)
                FilterChip(
                  label: Text(e.value),
                  selected: _columns.contains(e.key),
                  showCheckmark: true,
                  checkmarkColor: Cs.ink,
                  labelStyle: Cs.small.copyWith(color: Cs.ink),
                  backgroundColor: Cs.surface,
                  selectedColor: Cs.surfaceMuted,
                  side: const BorderSide(color: Cs.borderStrong),
                  shape: const StadiumBorder(),
                  onSelected: (on) => setState(() => on ? _columns.add(e.key) : _columns.remove(e.key)),
                ),
            ],
          ),
          const SizedBox(height: 20),
          ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final jobs = widget.controller.jobs.take(5).toList();
              if (jobs.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const CapsLabel('Последние файлы'),
                  const SizedBox(height: 4),
                  for (final (i, j) in jobs.indexed) _job(j, last: i == jobs.length - 1),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _formatCard((String, String, String, String, Color) f) {
    final (key, name, hint, icon, color) = f;
    final on = _format == key;
    return InkWell(
      borderRadius: BorderRadius.circular(Cs.rMedium),
      onTap: () => setState(() => _format = key),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: on ? Cs.surfaceSoft : null,
          border: Border.all(color: on ? Cs.ink : Cs.border, width: on ? 1.5 : 1),
          borderRadius: BorderRadius.circular(Cs.rMedium),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GIcon(icon, size: 22, color: color),
                  const SizedBox(height: 10),
                  Text(name, style: Cs.strong),
                  Text(hint, style: Cs.small.copyWith(color: Cs.inkFaint)),
                ],
              ),
            ),
            Icon(
              on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: on ? Cs.ink : Cs.dashed,
            ),
          ],
        ),
      ),
    );
  }

  Widget _job(ExportJob j, {required bool last}) {
    final c = widget.controller;
    final saving = c.isSaving(j);
    final (icon, color) = switch (j.status) {
      'completed' => (_formats.firstWhere((f) => f.$1 == j.format, orElse: () => _formats.first).$4, Cs.success),
      'failed' => (GIcons.circleXmark, Cs.danger),
      _ => (GIcons.rotate, Cs.accentInk),
    };
    final t = j.createdAt;
    final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last ? null : const Border(bottom: BorderSide(color: Cs.divider)),
      ),
      child: Row(
        children: [
          GIcon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(j.filename, style: Cs.strong, overflow: TextOverflow.ellipsis),
                Text(
                  switch (j.status) {
                    'completed' => 'Готов · $time',
                    'failed' => j.error ?? 'Не удалось сформировать файл',
                    _ => 'Формируется…',
                  },
                  style: Cs.small.copyWith(color: j.status == 'failed' ? Cs.danger : Cs.inkFaint),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (j.pending)
            const Bar(value: null, height: 4, width: 96)
          else if (saving)
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else if (j.status == 'completed')
            Btn('Скачать', icon: GIcons.download, small: true, onPressed: () => widget.onSave(j))
          else
            Btn('Повторить', kind: BtnKind.ghost, small: true, onPressed: _sending ? null : () => _request(j.format)),
        ],
      ),
    );
  }
}
