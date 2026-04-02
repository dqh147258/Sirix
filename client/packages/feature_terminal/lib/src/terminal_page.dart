import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({
    super.key,
    required this.accessToken,
    this.deviceId,
    this.allowCreate = true,
    this.showHeader = true,
    this.compact = false,
  });

  final String accessToken;
  final String? deviceId;
  final bool allowCreate;
  final bool showHeader;
  final bool compact;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final TerminalTheme _theme = TerminalThemes.defaultTheme;
  Terminal _terminal = Terminal(maxLines: 10000);
  List<TerminalSessionSummary> _terminals = const [];
  String? _activeTerminalId;
  String? _errorMessage;
  bool _loading = true;
  bool _connecting = false;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  @override
  void initState() {
    super.initState();
    _bindTerminalCallbacks();
    Future.microtask(_loadTerminals);
  }

  @override
  void didUpdateWidget(covariant TerminalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId != widget.deviceId || oldWidget.accessToken != widget.accessToken) {
      Future.microtask(_loadTerminals);
    }
  }

  @override
  void dispose() {
    unawaited(_detachChannel());
    super.dispose();
  }

  Future<void> _loadTerminals() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final api = ref.read(backendApiClientProvider);
      final terminals = await api.listTerminals(
        accessToken: widget.accessToken,
        deviceId: widget.deviceId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _terminals = terminals;
        _loading = false;
      });
      if (terminals.isNotEmpty) {
        await _attachTerminal(terminals.first.id);
      } else {
        await _detachChannel();
        _resetTerminal();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _errorMessage = AppLocalizations.current.terminalLoadFailed('$error');
      });
    }
  }

  Future<void> _createTerminal() async {
    final deviceId = widget.deviceId;
    if (deviceId == null) {
      return;
    }
    setState(() {
      _errorMessage = null;
    });

    try {
      final api = ref.read(backendApiClientProvider);
      final created = await api.createTerminal(
        accessToken: widget.accessToken,
        targetDeviceId: deviceId,
        cols: 120,
        rows: 32,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _terminals = [created, ..._terminals];
      });
      await _attachTerminal(created.id);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = AppLocalizations.current.terminalCreateFailed('$error');
      });
    }
  }

  Future<void> _closeActiveTerminal() async {
    final terminalId = _activeTerminalId;
    if (terminalId == null) {
      return;
    }
    try {
      final api = ref.read(backendApiClientProvider);
      await api.closeTerminal(accessToken: widget.accessToken, terminalId: terminalId);
      if (!mounted) {
        return;
      }
      setState(() {
        _terminals = _terminals.where((item) => item.id != terminalId).toList(growable: false);
        _activeTerminalId = null;
      });
      _resetTerminal();
      await _detachChannel();
      if (_terminals.isNotEmpty) {
        await _attachTerminal(_terminals.first.id);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = AppLocalizations.current.terminalCloseFailed('$error');
      });
    }
  }

  Future<void> _attachTerminal(String terminalId) async {
    if (_activeTerminalId == terminalId) {
      return;
    }

    final eventClient = ref.read(backendEventClientProvider);
    if (eventClient == null) {
      setState(() {
        _activeTerminalId = terminalId;
        _errorMessage = AppLocalizations.current.terminalStreamUnavailable;
      });
      return;
    }

    await _detachChannel();
    _resetTerminal();
    setState(() {
      _activeTerminalId = terminalId;
      _connecting = true;
      _errorMessage = null;
    });

    try {
      final channel = eventClient.connectTerminalEvents(
        accessToken: widget.accessToken,
        terminalId: terminalId,
      );
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleSocketEvent,
        onError: (error) {
          if (mounted) {
            setState(() {
              _connecting = false;
              _errorMessage = AppLocalizations.current.terminalStreamError('$error');
            });
          }
        },
        onDone: () {
          if (mounted) {
            setState(() {
              _connecting = false;
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          _connecting = false;
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _connecting = false;
        _errorMessage = AppLocalizations.current.terminalConnectFailed('$error');
      });
    }
  }

  Future<void> _detachChannel() async {
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }

  void _handleSocketEvent(dynamic raw) {
    final payload = BackendEventClient.decodeEvent(raw);
    if (payload == null) {
      return;
    }

    final type = payload['type'] as String?;
    final body = payload['payload'] as Map<String, dynamic>?;
    if (type == null || body == null) {
      return;
    }

    switch (type) {
      case 'terminal.ready':
        final title = body['title'] as String?;
        if (title != null && mounted) {
          setState(() {
            _terminals = [
              for (final item in _terminals)
                if (item.id == _activeTerminalId)
                  TerminalSessionSummary(
                    id: item.id,
                    deviceId: item.deviceId,
                    title: title,
                    shell: body['shell'] as String? ?? item.shell,
                    cwd: body['cwd'] as String? ?? item.cwd,
                    state: body['state'] as String? ?? item.state,
                    cols: body['cols'] as int? ?? item.cols,
                    rows: body['rows'] as int? ?? item.rows,
                    createdAt: item.createdAt,
                    closedAt: item.closedAt,
                  )
                else
                  item,
            ];
          });
        }
        break;
      case 'terminal.output':
        final data = body['data_base64'] as String?;
        if (data == null) {
          return;
        }
        final bytes = base64Decode(data);
        _terminal.write(const Utf8Decoder(allowMalformed: true).convert(bytes));
        break;
      case 'terminal.closed':
        _terminal.write('\r\n[terminal closed]\r\n');
        break;
      case 'terminal.error':
        final message = body['error_message'] as String? ?? 'unknown';
        _terminal.write('\r\n[terminal error] $message\r\n');
        break;
      default:
        break;
    }
  }

  void _bindTerminalCallbacks() {
    _terminal.onOutput = (data) {
      final channel = _channel;
      if (channel == null) {
        return;
      }
      channel.sink.add(
        jsonEncode({
          'type': 'terminal.input',
          'data_base64': base64Encode(utf8.encode(data)),
        }),
      );
    };
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      final channel = _channel;
      if (channel == null) {
        return;
      }
      channel.sink.add(
        jsonEncode({
          'type': 'terminal.resize',
          'cols': width,
          'rows': height,
        }),
      );
    };
  }

  void _resetTerminal() {
    _terminal = Terminal(maxLines: 10000);
    _bindTerminalCallbacks();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;
    final activeTerminal = _terminals.cast<TerminalSessionSummary?>().firstWhere(
          (item) => item?.id == _activeTerminalId,
          orElse: () => _terminals.isEmpty ? null : _terminals.first,
        );
    final statusLabel = activeTerminal?.state.toUpperCase() ?? l10n.idle.toUpperCase();

    return Column(
      children: [
        if (widget.showHeader)
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, widget.compact ? 10 : 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.terminalPageTitle,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 26),
                      ),
                      if (!widget.compact) ...[
                        const SizedBox(height: 6),
                        Text(
                          l10n.sharedTerminalHint,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: palette.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                _ActionIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: l10n.refresh,
                  onPressed: _loadTerminals,
                ),
                if (widget.allowCreate && widget.deviceId != null) ...[
                  const SizedBox(width: 8),
                  _ActionIconButton(
                    icon: Icons.add_rounded,
                    tooltip: l10n.createTerminal,
                    onPressed: _createTerminal,
                  ),
                ],
                const SizedBox(width: 8),
                _ActionIconButton(
                  icon: Icons.close_rounded,
                  tooltip: l10n.disconnectSession,
                  onPressed: _closeActiveTerminal,
                ),
              ],
            ),
          ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: palette.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: palette.error.withValues(alpha: 0.24)),
              ),
              child: Text(
                _errorMessage!,
                style: TextStyle(color: palette.error),
              ),
            ),
          ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          height: 42,
          decoration: BoxDecoration(
            color: palette.surface.withValues(alpha: 0.88),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            border: Border(
              top: BorderSide(color: palette.glassStroke),
              left: BorderSide(color: palette.glassStroke),
              right: BorderSide(color: palette.glassStroke),
            ),
          ),
          child: _loading
              ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
              : Row(
                  children: [
                    Expanded(
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _terminals.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 4),
                        itemBuilder: (context, index) {
                          final item = _terminals[index];
                          return _TerminalTab(
                            summary: item,
                            selected: item.id == _activeTerminalId,
                            onTap: () => _attachTerminal(item.id),
                          );
                        },
                      ),
                    ),
                    if (widget.allowCreate && widget.deviceId != null)
                      IconButton(
                        onPressed: _createTerminal,
                        icon: const Icon(Icons.add, size: 18),
                        splashRadius: 18,
                      ),
                  ],
                ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF0A0D10),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
                border: Border(
                  left: BorderSide(color: palette.glassStroke),
                  right: BorderSide(color: palette.glassStroke),
                  bottom: BorderSide(color: palette.glassStroke),
                ),
              ),
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        if (_terminals.isEmpty && !_loading)
                          _TerminalEmptyState(canCreate: widget.allowCreate && widget.deviceId != null),
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: _terminals.isEmpty,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
                              child: TerminalView(
                                _terminal,
                                theme: _theme,
                                autofocus: true,
                                backgroundOpacity: 0,
                              ),
                            ),
                          ),
                        ),
                        if (_connecting)
                          Positioned(
                            top: 14,
                            right: 14,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: palette.surface.withValues(alpha: 0.84),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: palette.glassStroke),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    height: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF11161C),
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
                      border: Border(top: BorderSide(color: palette.glassStroke)),
                    ),
                    child: Row(
                      children: [
                        _StatusText(
                          color: palette.primaryBright,
                          text: l10n.terminalStable,
                        ),
                        const SizedBox(width: 16),
                        _StatusText(text: 'UTF-8'),
                        const SizedBox(width: 16),
                        _StatusText(
                          text: activeTerminal == null
                              ? '--'
                              : 'COL ${activeTerminal.cols}  ROW ${activeTerminal.rows}',
                        ),
                        const Spacer(),
                        _StatusText(text: statusLabel),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionIconButton extends StatelessWidget {
  const _ActionIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: palette.surfaceRaised.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.glassStroke),
          ),
          child: Icon(icon, size: 20),
        ),
      ),
    );
  }
}

class _TerminalTab extends StatelessWidget {
  const _TerminalTab({
    required this.summary,
    required this.selected,
    required this.onTap,
  });

  final TerminalSessionSummary summary;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return InkWell(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? palette.surfaceRaised : Colors.transparent,
          border: selected
              ? Border(
                  left: BorderSide(color: palette.primaryBright, width: 2),
                )
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.terminal_rounded,
              size: 14,
              color: selected ? palette.primaryBright : palette.textMuted,
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                summary.title.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? palette.textPrimary : palette.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalEmptyState extends StatelessWidget {
  const _TerminalEmptyState({
    required this.canCreate,
  });

  final bool canCreate;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;
    final l10n = context.l10n;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal, size: 42, color: palette.primaryBright),
            const SizedBox(height: 14),
            Text(
              l10n.noTerminalSession,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              canCreate ? l10n.noTerminalSessionHint : l10n.terminalTargetMissing,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: palette.textMuted,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({
    this.color,
    required this.text,
  });

  final Color? color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: color ?? palette.textMuted,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            fontFamily: 'JetBrains Mono',
            letterSpacing: 0.6,
          ),
    );
  }
}
