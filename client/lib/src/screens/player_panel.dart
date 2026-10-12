import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models.dart';
import '../scene_player.dart';
import '../timecode.dart';
import '../ui/widgets.dart';
import 'sheet_view.dart';

/// Правая колонка редактора: тёмный плеер со шкалой сцен (FR-C7) и карточка выбранной сцены
/// с уверенностью модели по плану, описанию и диалогам.
class PlayerPanel extends StatelessWidget {
  const PlayerPanel({
    super.key,
    required this.player,
    required this.sheet,
    required this.scene,
    required this.onSelect,
    required this.onlyScene,
    required this.onOnlySceneChanged,
  });

  final ScenePlayer? player;
  final SceneSheet sheet;
  final Scene? scene;
  final void Function(Scene scene, {bool play}) onSelect;
  final bool onlyScene;
  final ValueChanged<bool> onOnlySceneChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: Cs.stage, borderRadius: BorderRadius.circular(Cs.rLarge)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _screen(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [_strip(), const SizedBox(height: 10), _controls()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: _details()),
      ],
    );
  }

  Widget _badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: const Color(0x73000000), borderRadius: BorderRadius.circular(6)),
    child: Text(text, style: Cs.monoText.copyWith(fontSize: 12, color: Colors.white)),
  );

  Widget _screen() {
    final s = scene;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ColoredBox(
        color: Cs.stageInner,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (player != null)
              Video(controller: player!.video, controls: NoVideoControls, fill: Cs.stageInner)
            else
              const Center(
                child: Text(
                  'Видео появится после загрузки',
                  style: TextStyle(fontFamily: Cs.sans, color: Cs.stageText),
                ),
              ),
            if (s != null) ...[
              Positioned(left: 12, top: 10, child: _badge('Сцена ${s.index + 1}')),
              Positioned(right: 12, top: 10, child: _badge(timecode(s.startMs, sheet.fps))),
            ],
            if (player != null && s != null)
              Center(
                child: StreamBuilder<bool>(
                  stream: player!.playing,
                  builder: (_, snap) => (snap.data ?? false)
                      ? const SizedBox.shrink()
                      : Material(
                          color: const Color(0x24FFFFFF),
                          shape: const CircleBorder(),
                          child: IconButton(
                            tooltip: 'Воспроизвести сцену',
                            iconSize: 20,
                            padding: const EdgeInsets.all(18),
                            onPressed: () => onSelect(s, play: true),
                            icon: const GIcon(GIcons.play, size: 20, color: Colors.white),
                          ),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Шкала сцен: ширина — длительность, янтарные — требуют проверки, белая — выбранная.
  Widget _strip() {
    return SizedBox(
      height: 22,
      child: Row(
        children: [
          for (final (i, s) in sheet.scenes.indexed) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              flex: ((s.endMs - s.startMs) ~/ 100).clamp(1, 1 << 20),
              child: Tooltip(
                message: 'Сцена ${s.index + 1}',
                child: GestureDetector(
                  onTap: () => onSelect(s),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        color: s.id == scene?.id
                            ? Colors.white
                            : needsReview(s)
                            ? const Color(0xFF8A6A2E)
                            : Cs.stageMuted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _controls() {
    final s = scene;
    final i = s == null ? -1 : sheet.scenes.indexWhere((x) => x.id == s.id);
    Widget ctl(String icon, String tip, VoidCallback? onTap, {bool primary = false}) => Material(
      color: primary ? Colors.white : Colors.transparent,
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tip,
        onPressed: onTap,
        icon: GIcon(icon, color: onTap == null ? Cs.stageMuted : (primary ? Cs.ink : Colors.white)),
      ),
    );
    final duration = sheet.durationMs ?? (sheet.scenes.isEmpty ? 0 : sheet.scenes.last.endMs);
    return Row(
      children: [
        ctl(GIcons.chevronLeft, 'Предыдущая сцена', i > 0 ? () => onSelect(sheet.scenes[i - 1]) : null),
        if (player != null)
          StreamBuilder<bool>(
            stream: player!.playing,
            builder: (_, snap) {
              final playing = snap.data ?? false;
              return ctl(playing ? GIcons.pause : GIcons.play, playing ? 'Пауза' : 'Воспроизвести', () {
                if (!playing && onlyScene && s != null) {
                  onSelect(s, play: true);
                } else {
                  player!.toggle();
                }
              }, primary: true);
            },
          )
        else
          ctl(GIcons.play, 'Воспроизвести', null, primary: true),
        ctl(
          GIcons.chevronRight,
          'Следующая сцена',
          i >= 0 && i < sheet.scenes.length - 1 ? () => onSelect(sheet.scenes[i + 1]) : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: player == null
              ? const SizedBox.shrink()
              : StreamBuilder<Duration>(
                  stream: player!.position,
                  builder: (_, snap) => Text(
                    '${timecode(snap.data?.inMilliseconds ?? 0, sheet.fps)} / ${timecode(duration, sheet.fps)}',
                    overflow: TextOverflow.ellipsis,
                    style: Cs.monoText.copyWith(fontSize: 12, color: Cs.stageText),
                  ),
                ),
        ),
        InkWell(
          onTap: () => onOnlySceneChanged(!onlyScene),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Checkbox(
                  value: onlyScene,
                  onChanged: (v) => onOnlySceneChanged(v ?? false),
                  fillColor: WidgetStateProperty.resolveWith(
                    (st) => st.contains(WidgetState.selected) ? Colors.white : Colors.transparent,
                  ),
                  checkColor: Cs.ink,
                  side: const BorderSide(color: Cs.stageText),
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'Только сцена',
                style: TextStyle(fontFamily: Cs.sans, fontSize: 12, color: Cs.stageText),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _details() {
    final s = scene;
    if (s == null) {
      return Panel(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Text('Выберите строку в листе', style: Cs.body.copyWith(color: Cs.inkMuted)),
        ),
      );
    }
    double? dialogueConfidence() {
      final c = s.replicas.map((r) => r.confidence).nonNulls.toList();
      return c.isEmpty ? null : c.reduce((a, b) => a + b) / c.length;
    }

    final conf = [
      ('План', s.auto['shot_type']?.confidence),
      ('Описание', s.auto['description']?.confidence),
      ('Диалоги', dialogueConfidence()),
    ];
    Widget field(String label, Widget value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [CapsLabel(label), const SizedBox(height: 4), value],
    );
    return Panel(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(child: Text('Сцена ${s.index + 1}', style: Cs.heading(18, height: 26))),
                Text(seconds(s.endMs - s.startMs), style: Cs.monoText.copyWith(fontSize: 12, color: Cs.inkFaint)),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: field('Начало', Text(timecode(s.startMs, sheet.fps), style: Cs.monoText))),
                Expanded(child: field('Конец', Text(timecode(s.endMs, sheet.fps), style: Cs.monoText))),
              ],
            ),
            const SizedBox(height: 14),
            field('План', Text(s.shotType == null ? '—' : shotTypeLabels[s.shotType] ?? s.shotType!, style: Cs.body)),
            const SizedBox(height: 14),
            field('Описание', Text((s.description ?? '').isEmpty ? '—' : s.description!, style: Cs.body)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Cs.surfaceMuted, borderRadius: BorderRadius.circular(12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const CapsLabel('Уверенность модели'),
                  for (final (k, v) in conf) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        SizedBox(width: 84, child: Text(k, style: Cs.small)),
                        Expanded(
                          child: Bar(value: v ?? 0, height: 4, color: (v ?? 1) < 0.65 ? Cs.warnBar : Cs.inkMuted),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            v == null ? '—' : percent(v),
                            textAlign: TextAlign.right,
                            style: Cs.monoText.copyWith(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
