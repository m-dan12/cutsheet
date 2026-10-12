import 'package:flutter/material.dart';

/// Подпись статуса пайплайна по этапу и состоянию (FR-C3).
String statusLabel(String stage, String status) {
  const stages = {
    'upload': 'Загрузка видео',
    'scenes': 'Поиск планов',
    'dialogue': 'Диалоги',
    'enrichment': 'Описание сцен',
    'review': 'Проверка',
    'export': 'Экспорт',
  };
  const states = {
    'pending': 'ожидает',
    'running': 'идёт',
    'done': 'готово',
    'failed': 'ошибка',
    'ready_for_review': 'готово к проверке',
  };
  if (status == 'created') return 'Новый проект';
  return '${stages[stage] ?? stage}: ${states[status] ?? status}';
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.stage, required this.status});
  final String stage;
  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (status) {
      'running' => (Icons.sync, scheme.primary),
      'done' || 'ready_for_review' => (Icons.check_circle, Colors.green),
      'failed' => (Icons.error, scheme.error),
      _ => (Icons.schedule, scheme.outline),
    };
    return Chip(
      avatar: Icon(icon, color: color, size: 18),
      label: Text(statusLabel(stage, status)),
      visualDensity: VisualDensity.compact,
    );
  }
}
