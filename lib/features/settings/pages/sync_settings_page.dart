import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../core/providers/sync_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/responsive/screen_type_helper.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/section_card.dart';
import '../../scan/pages/qr_scan_page.dart';

/// This short form uses the same controls on desktop and mobile.
class SyncSettingsPage extends StatefulWidget {
  const SyncSettingsPage({super.key, this.embedded = false});
  final bool embedded;
  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  final _server = TextEditingController();
  final _code = TextEditingController();
  bool _local = false;
  bool _loaded = false;
  String? _pairingError;
  @override
  void dispose() {
    _server.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (raw == null || !mounted) return;
    try {
      final data = jsonDecode(raw) as Map;
      if (data['type'] != 'kelivo-sync' ||
          data['server'] is! String ||
          data['code'] is! String) {
        throw const FormatException();
      }
      setState(() {
        _server.text = data['server'] as String;
        _code.text = data['code'] as String;
        _pairingError = null;
      });
    } catch (_) {
      setState(
        () => _pairingError = AppLocalizations.of(context)!.syncPairExpired,
      );
    }
  }

  Future<void> _showQr() async {
    final p = context.read<SyncProvider>();
    try {
      final data = await p.pairingQr();
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l.syncShowQr),
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PrettyQrView.data(data: jsonEncode(data)),
                const SizedBox(height: 16),
                SelectableText(data['code'] as String),
                const SizedBox(height: 8),
                Text(l.syncQrExpires),
              ],
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _pairingError = AppLocalizations.of(context)!.syncUnavailable,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<SyncProvider>();
    final l = AppLocalizations.of(context)!;
    if (!_loaded && p.ready) {
      _loaded = true;
      _server.text = p.server;
      _local = p.allowLocalHttp;
    }
    final status = p.busy
        ? l.syncWorking
        : p.paired
        ? l.syncReady
        : l.syncNotPaired;
    final error = switch (p.error) {
      null => null,
      'invalid_pair_code' => l.syncPairExpired,
      'invalid_token' => l.syncRePair,
      'cursor_ahead' => l.syncCursorAhead,
      'sync_streaming_busy' || 'sync_restore_busy' => l.syncBusy,
      _ => l.syncUnavailable,
    };
    final body = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.embedded)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  l.syncTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            SectionCard(
              children: [
                IosFormTextField(
                  label: l.syncServer,
                  controller: _server,
                  hintText: 'https://sync.example.com',
                  enabled: !p.busy && !p.paired,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                ),
                if (!p.paired)
                  IosFormTextField(
                    label: l.syncPairCode,
                    controller: _code,
                    enabled: !p.busy,
                    autocorrect: false,
                    enableSuggestions: false,
                  ),
                if (!p.paired)
                  SwitchListTile(
                    title: Text(l.syncLocalHttp),
                    value: _local,
                    onChanged: p.busy
                        ? null
                        : (v) => setState(() => _local = v),
                  ),
                if (p.paired)
                  SwitchListTile(
                    title: Text(l.syncEnabled),
                    value: p.enabled,
                    onChanged: p.busy ? null : p.setEnabled,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(l.syncScope),
            const SizedBox(height: 16),
            Text(status),
            if (p.lastSync != null)
              Text('${l.syncLast}: ${p.lastSync!.toLocal()}'),
            if (error != null || _pairingError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error ?? _pairingError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            if (!p.paired)
              FilledButton(
                onPressed: !p.ready || p.busy
                    ? null
                    : () => p.pair(_server.text, _code.text, localHttp: _local),
                child: Text(l.syncPair),
              ),
            if (!p.paired && !ResponsiveHelper.isDesktop(context))
              TextButton.icon(
                onPressed: p.busy ? null : _scan,
                icon: const Icon(LucideIcons.scanLine),
                label: Text(l.syncScan),
              ),
            if (p.paired)
              FilledButton(
                onPressed: p.busy ? null : p.sync,
                child: Text(l.syncNow),
              ),
            if (p.paired)
              TextButton(
                onPressed: p.busy ? null : _showQr,
                child: Text(l.syncShowQr),
              ),
            if (p.paired)
              TextButton(
                onPressed: p.busy
                    ? null
                    : () async {
                        await p.disconnect();
                        if (mounted) setState(() => _loaded = false);
                      },
                child: Text(l.syncDisconnect),
              ),
          ],
        ),
      ),
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: Text(l.syncTitle)),
            body: body,
          );
  }
}
