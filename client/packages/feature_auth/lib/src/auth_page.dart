import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_state.dart';
import 'auth_view_model.dart';

class AuthPage extends ConsumerWidget {
  const AuthPage({
    super.key,
    required this.clientType,
    this.onLoginSuccess,
  });

  final String clientType;
  final VoidCallback? onLoginSuccess;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(authViewModelProvider(clientType));
    final vm = ref.read(authViewModelProvider(clientType).notifier);

    ref.listen<AuthState>(authViewModelProvider(clientType), (previous, next) {
      if ((previous?.isAuthenticated ?? false) == false && next.isAuthenticated) {
        onLoginSuccess?.call();
      }
    });

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            decoration: const InputDecoration(labelText: '用户名'),
            onChanged: vm.setUsername,
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(labelText: '密码'),
            obscureText: true,
            onChanged: vm.setPassword,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              ElevatedButton(
                onPressed: state.isLoading ? null : vm.login,
                child: const Text('登录'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: state.isLoading ? null : vm.register,
                child: const Text('注册'),
              ),
            ],
          ),
          if (state.isLoading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (state.errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              state.errorMessage!,
              style: const TextStyle(color: Colors.red),
            ),
          ],
          if (state.session != null) ...[
            const SizedBox(height: 12),
            Text('当前用户: ${state.session!.username}'),
          ],
        ],
      ),
    );
  }
}
