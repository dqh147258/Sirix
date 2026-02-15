import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:infra_api/infra_api.dart';

import 'device_list_view_model.dart';

class DeviceListPage extends ConsumerStatefulWidget {
  const DeviceListPage({
    super.key,
    required this.accessToken,
    this.onConnectSession,
  });

  final String accessToken;
  final ValueChanged<RemoteSessionSummary>? onConnectSession;

  @override
  ConsumerState<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends ConsumerState<DeviceListPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(deviceListViewModelProvider.notifier).load(widget.accessToken);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(deviceListViewModelProvider);
    final vm = ref.read(deviceListViewModelProvider.notifier);

    return RefreshIndicator(
      onRefresh: () => vm.load(widget.accessToken),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (state.loading) const LinearProgressIndicator(),
          if (state.errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              state.errorMessage!,
              style: const TextStyle(color: Colors.red),
            ),
          ],
          const SizedBox(height: 8),
          for (final device in state.devices)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${device.deviceName} (${device.platform})'),
                    const SizedBox(height: 6),
                    Text('版本: ${device.clientVersion}'),
                    Text('状态: ${device.online ? '在线' : '离线'}'),
                    Row(
                      children: [
                        Expanded(
                          child: SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('自动授权'),
                            value: device.autoApproveScreenShare,
                            onChanged: (value) => vm.toggleAutoApprove(
                              accessToken: widget.accessToken,
                              device: device,
                              nextValue: value,
                            ),
                          ),
                        ),
                        ElevatedButton(
                          onPressed: device.online
                              ? () async {
                                  final session = await vm.connectToDevice(
                                    accessToken: widget.accessToken,
                                    deviceId: device.id,
                                  );
                                  if (session != null && mounted) {
                                    widget.onConnectSession?.call(session);
                                  }
                                }
                              : null,
                          child: const Text('连接'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
