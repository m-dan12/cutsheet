import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../timecode.dart';
import '../ui/widgets.dart';
import 'new_project_dialog.dart';
import 'project_screen.dart';
import 'status_chip.dart';

/// Список проектов: название, статус обработки, длительность, дата (FR-C1).
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key, required this.api});
  final Api api;

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

enum _Filter { all, running, ready }

class _ProjectsScreenState extends State<ProjectsScreen> {
  late Future<List<Project>> _projects = widget.api.projects();
  List<Project> _last = const [];
  _Filter _filter = _Filter.all;
  String _query = '';

  void _reload() => setState(() => _projects = widget.api.projects());

  Future<void> _create() async {
    final project = await showDialog<Project>(
      context: context,
      barrierColor: const Color(0x521C1B19),
      barrierDismissible: false,
      builder: (_) => NewProjectDialog(api: widget.api),
    );
    if (project == null || !mounted) return;
    await _open(project);
  }

  Future<void> _open(Project p) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProjectScreen(api: widget.api, project: p),
      ),
    );
    _reload();
  }

  bool _matches(Project p) {
    if (_query.isNotEmpty && !p.name.toLowerCase().contains(_query.toLowerCase())) return false;
    return switch (_filter) {
      _Filter.all => true,
      _Filter.running => !isReady(p.stage, p.status) && p.status != 'failed',
      _Filter.ready => isReady(p.stage, p.status),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<List<Project>>(
          future: _projects,
          builder: (context, snap) {
            if (snap.hasData) _last = snap.data!;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 240,
                  child: _Sidebar(api: widget.api, projects: _last, onOpen: _open),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Panel(padding: const EdgeInsets.fromLTRB(36, 32, 36, 16), child: _main(snap)),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _main(AsyncSnapshot<List<Project>> snap) {
    final all = snap.data ?? _last;
    final running = all
        .where((p) => !isReady(p.stage, p.status) && p.status != 'failed' && p.status != 'created')
        .length;
    final shown = all.where(_matches).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Проекты', style: Cs.heading(28, height: 36)),
                  Text(
                    snap.hasData
                        ? '${_plural(all.length, 'проект', 'проекта', 'проектов')}${running > 0 ? ' · $running в обработке' : ''}'
                        : 'Загрузка…',
                    style: Cs.body.copyWith(color: Cs.inkMuted),
                  ),
                ],
              ),
            ),
            IconBtn(GIcons.rotate, tooltip: 'Обновить', onPressed: _reload),
            const SizedBox(width: 8),
            Btn('Новый проект', icon: GIcons.plus, kind: BtnKind.primary, onPressed: _create),
          ],
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SearchField(hint: 'Поиск по названию', onChanged: (v) => setState(() => _query = v.trim()), width: 320),
            Segmented<_Filter>(
              value: _filter,
              items: const [(_Filter.all, 'Все'), (_Filter.running, 'В работе'), (_Filter.ready, 'Готовы')],
              onChanged: (f) => setState(() => _filter = f),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(child: _table(snap, all, shown)),
      ],
    );
  }

  Widget _table(AsyncSnapshot<List<Project>> snap, List<Project> all, List<Project> shown) {
    if (snap.hasError) {
      return Center(
        child: Text('${snap.error}', style: Cs.body.copyWith(color: Cs.danger)),
      );
    }
    if (!snap.hasData && all.isEmpty) return const Center(child: CircularProgressIndicator());
    if (all.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GIcon(GIcons.folder, size: 28, color: Cs.inkFaint),
            const SizedBox(height: 12),
            Text('Проектов пока нет', style: Cs.heading(18)),
            const SizedBox(height: 4),
            Text('Создайте проект и загрузите видео со сценарием.', style: Cs.body.copyWith(color: Cs.inkMuted)),
            const SizedBox(height: 16),
            Btn('Новый проект', icon: GIcons.plus, kind: BtnKind.primary, onPressed: _create),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Row(
          header: true,
          cells: [
            CapsLabel('Название'),
            CapsLabel('Статус'),
            CapsLabel('Длительность'),
            CapsLabel('Создан'),
            SizedBox.shrink(),
          ],
        ),
        const Divider(height: 1, color: Cs.border),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text('Ничего не найдено', style: Cs.body.copyWith(color: Cs.inkMuted)),
                )
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) => _ProjectRow(project: shown[i], onOpen: () => _open(shown[i])),
                ),
        ),
      ],
    );
  }
}

String _plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  final w = m10 == 1 && m100 != 11
      ? one
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
      ? few
      : many;
  return '$n $w';
}

String formatWhen(BuildContext context, DateTime t) {
  final now = DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  if (day == today) return 'Сегодня, $hm';
  if (day == today.subtract(const Duration(days: 1))) return 'Вчера, $hm';
  return '${MaterialLocalizations.of(context).formatShortMonthDay(t)}, $hm';
}

/// Тон миниатюры проекта: стабильный тёплый серый по имени.
Color projectTone(String name) {
  const tones = [
    Color(0xFFC9C2B4),
    Color(0xFF9FA8B5),
    Color(0xFFB9C4B0),
    Color(0xFFA89A8C),
    Color(0xFFD8C7A4),
    Color(0xFFBDB8B0),
  ];
  return tones[name.codeUnits.fold<int>(0, (a, b) => a + b) % tones.length];
}

class _Row extends StatelessWidget {
  const _Row({required this.cells, this.header = false});
  final List<Widget> cells;
  final bool header;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: 4, vertical: header ? 12 : 14),
    child: Row(
      children: [
        Expanded(child: cells[0]),
        SizedBox(width: 240, child: cells[1]),
        SizedBox(width: 130, child: cells[2]),
        SizedBox(width: 150, child: cells[3]),
        SizedBox(width: 40, child: cells[4]),
      ],
    ),
  );
}

class _ProjectRow extends StatefulWidget {
  const _ProjectRow({required this.project, required this.onOpen});
  final Project project;
  final VoidCallback onOpen;

  @override
  State<_ProjectRow> createState() => _ProjectRowState();
}

class _ProjectRowState extends State<_ProjectRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.project;
    final running = statusKind(p.stage, p.status) == PillKind.run;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: Container(
          decoration: BoxDecoration(
            color: _hover ? Cs.surfaceMuted : null,
            border: const Border(bottom: BorderSide(color: Cs.divider)),
          ),
          child: _Row(
            cells: [
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 36,
                    decoration: BoxDecoration(color: projectTone(p.name), borderRadius: BorderRadius.circular(8)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.name, style: Cs.strong, overflow: TextOverflow.ellipsis),
                        if (p.status == 'failed' && p.error != null)
                          Text(
                            p.error!,
                            style: Cs.small.copyWith(color: Cs.danger),
                            overflow: TextOverflow.ellipsis,
                          )
                        else if (p.fps != null)
                          Text('${p.fps!.toStringAsFixed(p.fps! % 1 == 0 ? 0 : 2)} кадр/с', style: Cs.small),
                      ],
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusChip(stage: p.stage, status: p.status),
                  if (running) ...[const SizedBox(height: 6), const Bar(value: null, height: 4, width: 160)],
                ],
              ),
              Text(p.durationMs == null ? '—' : timecode(p.durationMs!, p.fps), style: Cs.monoText),
              Text(formatWhen(context, p.createdAt), style: Cs.body.copyWith(color: Cs.inkMuted)),
              const Align(
                alignment: Alignment.centerRight,
                child: GIcon(GIcons.chevronRight, color: Cs.inkFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Боковое меню: логотип, разделы, недавние проекты, карточка пользователя с выходом.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.api, required this.projects, required this.onOpen});
  final Api api;
  final List<Project> projects;
  final void Function(Project) onOpen;

  @override
  Widget build(BuildContext context) {
    final email = api.email ?? '';
    final recent = [...projects]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Brand()),
          const SizedBox(height: 24),
          NavItem(icon: GIcons.folder, label: 'Проекты', selected: true, trailing: '${projects.length}', onTap: () {}),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 6), child: CapsLabel('Недавние')),
            for (final p in recent.take(4))
              NavItem(
                dot: switch (statusKind(p.stage, p.status)) {
                  PillKind.ok => Cs.successDot,
                  PillKind.run => Cs.accent,
                  PillKind.err => Cs.danger,
                  _ => Cs.dashed,
                },
                label: p.name,
                onTap: () => onOpen(p),
              ),
          ],
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Cs.bgDeep, borderRadius: BorderRadius.circular(Cs.rMedium)),
            child: Row(
              children: [
                Avatar(email: email),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    email,
                    style: Cs.small.copyWith(color: Cs.ink, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconBtn(GIcons.logout, tooltip: 'Выйти', onPressed: api.logout, background: Cs.surface),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Пункт бокового меню: белая «таблетка» у выбранного.
class NavItem extends StatelessWidget {
  const NavItem({
    super.key,
    this.icon,
    this.dot,
    required this.label,
    this.selected = false,
    this.trailing,
    required this.onTap,
  });
  final String? icon;
  final Color? dot;
  final String label;
  final bool selected;
  final String? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Cs.ink : Cs.inkMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? Cs.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        elevation: 0,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: selected
                ? BoxDecoration(borderRadius: BorderRadius.circular(10), boxShadow: Cs.shadowSoft, color: Cs.surface)
                : null,
            child: Row(
              children: [
                if (icon != null) GIcon(icon!, color: color),
                if (dot != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Dot(dot!)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: Cs.body.copyWith(color: color, fontWeight: selected ? FontWeight.w700 : FontWeight.w400),
                  ),
                ),
                if (trailing != null) Text(trailing!, style: Cs.monoText.copyWith(fontSize: 12, color: Cs.inkFaint)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Кружок с инициалами из почты.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.email, this.size = 36});
  final String email;
  final double size;

  @override
  Widget build(BuildContext context) {
    final name = email.split('@').first;
    final parts = name.split(RegExp(r'[._\-]+')).where((s) => s.isNotEmpty).toList();
    final initials = (parts.length >= 2 ? '${parts[0][0]}${parts[1][0]}' : name.characters.take(2).toString())
        .toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(color: Cs.surface, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: const TextStyle(fontFamily: Cs.sans, fontWeight: FontWeight.w700, fontSize: 12, color: Cs.ink),
      ),
    );
  }
}
