import 'package:flutter/material.dart';

import '../ui/widgets.dart';

const _stages = {
  'upload': 'загрузка видео',
  'scenes': 'поиск сцен',
  'dialogue': 'диалоги',
  'enrichment': 'описание сцен',
  'review': 'проверка',
  'export': 'экспорт',
};

/// Этапы пайплайна по порядку (для степпера обработки).
const pipelineStages = ['upload', 'scenes', 'dialogue', 'enrichment', 'review'];

/// Лист собран: обработка дошла до проверки (или дальше).
bool isReady(String stage, String status) =>
    status == 'ready_for_review' || stage == 'export' || (stage == 'review' && status != 'failed');

/// Подпись статуса пайплайна по этапу и состоянию (FR-C3).
String statusLabel(String stage, String status) {
  final name = _stages[stage] ?? stage;
  if (status == 'created') return 'Новый проект';
  if (status == 'failed') return 'Ошибка: $name';
  if (isReady(stage, status)) return 'Готов к проверке';
  if (stage == 'upload') return 'Загрузка видео';
  return 'Обработка · $name';
}

PillKind statusKind(String stage, String status) => switch (status) {
  'created' => PillKind.mute,
  'failed' => PillKind.err,
  _ when isReady(stage, status) => PillKind.ok,
  _ => PillKind.run,
};

/// Статус проекта таблеткой: зелёный — готов, синий — в работе, красный — ошибка.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.stage, required this.status});
  final String stage;
  final String status;

  @override
  Widget build(BuildContext context) {
    final kind = statusKind(stage, status);
    return Pill(statusLabel(stage, status), kind: kind, icon: kind == PillKind.run ? GIcons.rotate : null);
  }
}
