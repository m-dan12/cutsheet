import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'project_screen.dart';
import 'status_chip.dart';

/// Список проектов: название, статус обработки, дата (FR-C1).
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key, required this.api});
  final Api api;

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  late Future<List<Project>> _projects = widget.api.projects();

  void _reload() => setState(() => _projects = widget.api.projects());

  Future<void> _create() async {
    final name = await showDialog<String>(context: context, builder: (_) => const _NewProjectDialog());
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final project = await widget.api.createProject(name);
      if (!mounted) return;
      await _open(project);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _open(Project p) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ProjectScreen(api: widget.api, project: p),
    ));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Проекты'),
        actions: [
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh), tooltip: 'Обновить'),
          TextButton.icon(
            onPressed: widget.api.logout,
            icon: const Icon(Icons.logout),
            label: Text(widget.api.email ?? 'Выйти'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('Новый проект'),
      ),
      body: FutureBuilder<List<Project>>(
        future: _projects,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final projects = snap.data!;
          if (projects.isEmpty) return const Center(child: Text('Проектов пока нет'));
          return ListView.separated(
            itemCount: projects.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = projects[i];
              return ListTile(
                title: Text(p.name),
                subtitle: Text(MaterialLocalizations.of(context).formatMediumDate(p.createdAt)),
                trailing: StatusChip(stage: p.stage, status: p.status),
                onTap: () => _open(p),
              );
            },
          );
        },
      ),
    );
  }
}

class _NewProjectDialog extends StatefulWidget {
  const _NewProjectDialog();

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  final _name = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Новый проект'),
      content: TextField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Название фильма'),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, _name.text.trim()), child: const Text('Создать')),
      ],
    );
  }
}
