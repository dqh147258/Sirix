import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_authorize_view_model.dart';

class DesktopAuthorizePage extends ConsumerStatefulWidget {
  const DesktopAuthorizePage({super.key});

  @override
  ConsumerState<DesktopAuthorizePage> createState() => _DesktopAuthorizePageState();
}

class _DesktopAuthorizePageState extends ConsumerState<DesktopAuthorizePage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(desktopAuthorizeViewModelProvider.notifier).connect();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(desktopAuthorizeViewModelProvider);
    final vm = ref.read(desktopAuthorizeViewModelProvider.notifier);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Row(
            children: [
              Icon(
                state.connected ? Icons.link : Icons.link_off,
                color: state.connected ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(state.connected ? '已连接 desktop-server' : '未连接 desktop-server'),
              ),
              OutlinedButton(
                onPressed: vm.reconnect,
                child: const Text('重连'),
              ),
            ],
          ),
          if (state.connecting) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('自动授权屏幕共享'),
            subtitle: const Text('设备级设置，默认关闭'),
            value: state.autoApprove,
            onChanged: vm.setAutoApprove,
          ),
          if (state.lastEventType != null) ...[
            const SizedBox(height: 8),
            Text('最近事件: ${state.lastEventType}'),
          ],
          const SizedBox(height: 12),
          if (state.pendingRequests.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('当前没有待授权请求'),
              ),
            ),
          for (final request in state.pendingRequests)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('请求者: ${request.requester}'),
                    Text('目标设备: ${request.deviceName}'),
                    Text('会话ID: ${request.sessionId}'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => vm.approve(request.sessionId),
                            child: const Text('授权'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => vm.reject(request.sessionId),
                            child: const Text('拒绝'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (state.errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              state.errorMessage!,
              style: const TextStyle(color: Colors.red),
            ),
          ],
        ],
      ),
    );
  }
}
