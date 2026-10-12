import 'package:flutter/material.dart';

import '../api.dart';
import '../ui/widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api});
  final Api api;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _email.text = widget.api.email ?? '';
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = _email.text.trim();
      if (_register) {
        await widget.api.register(email, _password.text);
      } else {
        await widget.api.login(email, _password.text);
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Нет связи с сервером ${widget.api.base}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= 960;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Panel(padding: const EdgeInsets.fromLTRB(48, 40, 48, 32), child: _form()),
                ),
                if (wide) ...[const SizedBox(width: 16), const Expanded(child: _Showcase())],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _form() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Brand(),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(_register ? 'Регистрация' : 'Вход', style: Cs.heading(32, height: 40)),
                      const SizedBox(height: 8),
                      Text('Монтажные листы из видео и сценария.', style: Cs.body.copyWith(color: Cs.inkMuted)),
                      const SizedBox(height: 28),
                      const FieldLabel('Почта'),
                      TextField(
                        controller: _email,
                        style: Cs.body,
                        autofillHints: const [AutofillHints.email],
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          hintText: 'name@studio.ru',
                          prefixIcon: Padding(
                            padding: EdgeInsets.all(14),
                            child: GIcon(GIcons.envelope, color: Cs.inkFaint),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const FieldLabel('Пароль'),
                      TextField(
                        controller: _password,
                        style: Cs.body,
                        obscureText: !_showPassword,
                        autofillHints: const [AutofillHints.password],
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          helperText: _register ? 'Не короче 8 символов' : null,
                          prefixIcon: const Padding(
                            padding: EdgeInsets.all(14),
                            child: GIcon(GIcons.lock, color: Cs.inkFaint),
                          ),
                          suffixIcon: IconBtn(
                            _showPassword ? GIcons.eyeSlash : GIcons.eye,
                            tooltip: _showPassword ? 'Скрыть пароль' : 'Показать пароль',
                            onPressed: () => setState(() => _showPassword = !_showPassword),
                          ),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: Cs.dangerSoft,
                            borderRadius: BorderRadius.circular(Cs.rSmall),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 3),
                                child: GIcon(GIcons.circleXmark, color: Cs.danger),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(_error!, style: Cs.body.copyWith(color: Cs.danger)),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text(_register ? 'Зарегистрироваться' : 'Войти'),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _register ? 'Уже есть аккаунт?' : 'Нет аккаунта?',
                            style: Cs.body.copyWith(color: Cs.inkMuted),
                          ),
                          TextButton(
                            onPressed: _busy ? null : () => setState(() => _register = !_register),
                            style: TextButton.styleFrom(
                              foregroundColor: Cs.accent,
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                            ),
                            child: Text(_register ? 'Войти' : 'Зарегистрироваться'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const Row(
          children: [
            GIcon(GIcons.lock, size: 14, color: Cs.inkFaint),
            SizedBox(width: 8),
            Text('Сессия хранится в защищённом хранилище системы', style: Cs.small),
          ],
        ),
      ],
    );
  }
}

/// Правая половина экрана входа: слоган и пример листа.
class _Showcase extends StatelessWidget {
  const _Showcase();

  static const _rows = [
    ('1', '00:00:00:00', 'Общий', 'Пустой перрон на рассвете, туман.'),
    ('2', '00:00:04:12', 'Средний', 'Анна идёт вдоль края платформы.'),
    ('3', '00:00:09:03', 'Крупный', 'Лицо Анны, она смотрит на часы.'),
    ('4', '00:00:12:20', 'Деталь', 'Стрелки вокзальных часов.'),
  ];

  @override
  Widget build(BuildContext context) {
    Widget row((String, String, String, String) r, {bool head = false, bool selected = false, bool low = false}) {
      final style = head ? Cs.label : Cs.small.copyWith(color: Cs.ink);
      return Container(
        color: head ? Cs.surfaceMuted : (selected ? Cs.accentSoft : null),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                r.$1,
                style: head ? style : Cs.monoText.copyWith(color: selected ? Cs.accentInk : Cs.inkFaint),
              ),
            ),
            SizedBox(width: 104, child: Text(r.$2, style: head ? style : Cs.monoText)),
            SizedBox(
              width: 76,
              child: Text(r.$3, style: low ? style.copyWith(color: Cs.warn) : style),
            ),
            Expanded(
              child: Text(r.$4, style: style, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );
    }

    return Panel(
      color: Cs.bgDeep,
      padding: const EdgeInsets.all(48),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Загрузите фильм и сценарий. Черновик листа соберётся сам, вам останется проверить.',
                style: Cs.heading(28, height: 38).copyWith(color: Cs.inkSoft),
              ),
              const SizedBox(height: 24),
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Cs.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: Cs.shadowSoft,
                ),
                child: ExcludeSemantics(
                  child: Column(
                    children: [
                      row(('№', 'НАЧАЛО', 'ПЛАН', 'ОПИСАНИЕ'), head: true),
                      for (final (i, r) in _rows.indexed) ...[
                        const Divider(height: 1),
                        row(r, selected: i == 2, low: i == 3),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
