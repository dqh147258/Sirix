import 'package:flutter_test/flutter_test.dart';

import 'package:client/src/shell/shell_view_model.dart';
import 'package:infra_api/infra_api.dart';

void main() {
  group('ShellViewModel', () {
    test('tracks selected tab changes', () {
      final viewModel = ShellViewModel();

      viewModel.selectIndex(2);

      expect(viewModel.state.selectedIndex, 2);
    });

    test('stores and clears active remote session', () {
      final viewModel = ShellViewModel();
      const session = RemoteSessionSummary(
        requestId: 'request-1',
        sessionId: 'session-1',
        targetDeviceId: 'device-1',
        state: 'pending_approval',
      );

      viewModel.attachRemoteSession(session);
      expect(viewModel.state.selectedIndex, 1);
      expect(viewModel.state.activeRemoteSession, session);

      viewModel.clearRemoteSession();
      expect(viewModel.state.selectedIndex, 0);
      expect(viewModel.state.activeRemoteSession, isNull);
    });
  });
}
