import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/node.dart';
import '../engine/native.dart';
import '../state.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> _sheet(BuildContext context, Widget Function(BuildContext, Palette) build) {
  final p = PaletteScope.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: p.bg.withValues(alpha: 0.7),
    builder: (ctx) => PaletteScope(
      palette: p,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(p.rCard)),
            border: Border.all(color: p.border),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(color: p.border, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 12),
                build(ctx, p),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _sheetButton(Palette p, IconData icon, String label, VoidCallback onTap, {bool danger = false}) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Pressable(
        onTap: onTap,
        label: label,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(p.rCard),
            border: Border.all(color: p.border),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: danger ? p.danger : p.fg),
              const SizedBox(width: 8),
              Text(label, style: p.text(15, weight: FontWeight.w500, color: danger ? p.danger : p.fg)),
            ],
          ),
        ),
      ),
    );

Future<void> showNodeSheet(BuildContext context, AppState s, ProxyNode node) => _sheet(context, (ctx, p) {
      final latency = s.latencyOf(node.id);
      final source = s.sourceById(node.sourceId);
      final pinned = s.pinnedId == node.id;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${node.place.code ?? node.badge} · ${node.place.city ?? node.title}', style: p.text(18, weight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            '${node.name} · ${node.protocol.title} · ${node.transportLabel}'
            '${latency > 0 ? ' · $latency мс' : (latency < 0 ? ' · нет ответа' : '')}',
            style: p.text(14, color: p.muted),
          ),
          if (source != null) Text('Источник: ${source.title}', style: p.text(13, color: p.muted)),
          if (node.securityIssue != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('⚠ ${node.securityIssue}', style: p.text(13, color: p.danger)),
            ),
          const SizedBox(height: 8),
          _sheetButton(p, Icons.speed_rounded, 'Проверить', () {
            Navigator.pop(ctx);
            s.checkNode(node);
          }),
          _sheetButton(p, Icons.push_pin_outlined, pinned ? 'Открепить' : 'Закрепить', () {
            Navigator.pop(ctx);
            s.togglePin(node);
          }),
          _sheetButton(p, Icons.power_settings_new_rounded, 'Идти через этот узел', () {
            Navigator.pop(ctx);
            s.connect(nodeId: node.id);
          }),
          if (s.isBanned(node))
            _sheetButton(p, Icons.undo_rounded, 'Убрать из чёрного списка', () {
              Navigator.pop(ctx);
              s.unban(node);
            })
          else
            _sheetButton(p, Icons.block_rounded, 'В чёрный список', () {
              Navigator.pop(ctx);
              s.ban(node);
            }, danger: true),
          _sheetButton(p, Icons.copy_rounded, 'Копировать ключ', () {
            Clipboard.setData(ClipboardData(text: node.raw));
            Navigator.pop(ctx);
            s.flash('Ключ скопирован');
          }),
          if (source != null && source.isMine && source.links != null)
            _sheetButton(p, Icons.delete_outline_rounded, 'Удалить', () {
              Navigator.pop(ctx);
              s.removeNode(node);
            }, danger: true),
        ],
      );
    });

Future<void> showAddSheet(BuildContext context, AppState s) => _sheet(context, (ctx, p) => _AddForm(s: s, p: p));

class _AddForm extends StatefulWidget {
  const _AddForm({required this.s, required this.p});
  final AppState s;
  final Palette p;

  @override
  State<_AddForm> createState() => _AddFormState();
}

class _AddFormState extends State<_AddForm> {
  final _name = TextEditingController();
  final _text = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  InputDecoration _decor(String hint) {
    final p = widget.p;
    OutlineInputBorder border(Color c) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(p.rCard), borderSide: BorderSide(color: c));
    return InputDecoration(
      hintText: hint,
      hintStyle: p.text(14, color: p.muted),
      filled: true,
      fillColor: p.bg,
      isDense: true,
      contentPadding: const EdgeInsets.all(12),
      enabledBorder: border(p.border),
      focusedBorder: border(p.accent),
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) setState(() => _text.text = text);
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.s.addMine(_text.text, _name.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Новый источник', style: p.text(18, weight: FontWeight.w600, display: true))),
            IconButton(
              tooltip: 'Закрыть',
              icon: Icon(Icons.close_rounded, color: p.fg),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Ссылки подписок или ключи — можно сразу много', style: p.text(14)),
        const SizedBox(height: 4),
        TextField(
          controller: _text,
          minLines: 4,
          maxLines: 10,
          style: p.text(13),
          decoration: _decor('Каждая ссылка https://… станет отдельной подпиской, ключи vless://, vmess://, trojan://, ss://, hy2:// соберутся в один источник'),
        ),
        Wrap(
          children: [
            TextButton.icon(
              onPressed: _paste,
              icon: Icon(Icons.content_paste_rounded, size: 16, color: p.accent),
              label: Text('Вставить из буфера', style: p.text(14, color: p.accent)),
            ),
            TextButton.icon(
              onPressed: () {
                Navigator.pop(context);
                widget.s.scanImport();
              },
              icon: Icon(Icons.qr_code_scanner_rounded, size: 16, color: p.accent),
              label: Text('Сканировать QR', style: p.text(14, color: p.accent)),
            ),
          ],
        ),
        Text('Название (если источник один)', style: p.text(14)),
        const SizedBox(height: 4),
        TextField(controller: _name, style: p.text(14), decoration: _decor('Например, Домашний')),
        const SizedBox(height: 8),
        Text(
          'Ключи хранятся только на этом телефоне, в закрытой папке приложения.',
          style: p.text(13, color: p.muted),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: p.text(14, color: p.danger)),
        ],
        const SizedBox(height: 16),
        PillButton(label: _busy ? 'Загружаем…' : 'Добавить', primary: true, onTap: _busy ? null : _submit),
      ],
    );
  }
}

/// Поделиться всеми своими подписками и ключами: ссылка, список и QR-код.
Future<void> showShareSheet(BuildContext context, AppState s) {
  final lines = s.shareLines();
  final link = AppState.packShare(lines);
  final subs = lines.where((l) => l.toLowerCase().startsWith('http')).length;
  final keys = lines.length - subs;
  final what = [if (subs > 0) 'подписок: $subs', if (keys > 0) 'ключей: $keys'].join(', ');
  // В QR влезает около 2900 символов; больше — только ссылкой или списком.
  final qr = link.length <= 2900 ? Native.qr(link) : Future<Uint8List?>.value(null);
  return _sheet(context, (ctx, p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Поделиться своими', style: p.text(18, weight: FontWeight.w600, display: true)),
        const SizedBox(height: 2),
        Text(what.isEmpty ? 'Своих подписок нет' : what[0].toUpperCase() + what.substring(1), style: p.text(14, color: p.muted)),
        const SizedBox(height: 12),
        Center(
          child: FutureBuilder<Uint8List?>(
            future: qr,
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return SizedBox(width: 220, height: 220, child: Center(child: CircularProgressIndicator(color: p.accent)));
              }
              final png = snap.data;
              if (png == null) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Подписок слишком много для QR-кода — поделитесь ссылкой или списком.',
                    textAlign: TextAlign.center,
                    style: p.text(14, color: p.muted),
                  ),
                );
              }
              return ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(png, width: 240, height: 240, filterQuality: FilterQuality.none),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'На другом телефоне откройте «Источники → Сканировать QR». Подойдёт и обычная камера: '
          'скопируйте текст кода и вставьте в «Источники → Добавить».',
          textAlign: TextAlign.center,
          style: p.text(13, color: p.muted),
        ),
        const SizedBox(height: 4),
        _sheetButton(p, Icons.share_rounded, 'Поделиться ссылкой', () {
          Native.share(
            'Подписки для «Лоцмана» ($what). Откройте ссылку на телефоне с «Лоцманом» '
            'или вставьте её в «Источники → Добавить»:\n$link',
            title: 'Поделиться подписками',
          );
        }),
        _sheetButton(p, Icons.list_rounded, 'Поделиться списком', () {
          Native.share(lines.join('\n'), title: 'Поделиться подписками');
        }),
        _sheetButton(p, Icons.copy_rounded, 'Копировать ссылку', () {
          Clipboard.setData(ClipboardData(text: link));
          Navigator.pop(ctx);
          s.flash('Ссылка скопирована');
        }),
        const SizedBox(height: 8),
        Text(
          'Список подойдёт и для других приложений (Happ, v2rayNG). Кто получит ссылку, сможет пользоваться '
          'вашими подписками — платные отправляйте только тем, кому доверяете.',
          style: p.text(12, color: p.muted),
        ),
      ],
    );
  });
}
