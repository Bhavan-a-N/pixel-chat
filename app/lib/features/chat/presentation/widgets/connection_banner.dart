import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/websocket_client.dart';
import '../../../../core/theme/app_theme.dart';
import '../../application/websocket_provider.dart';

class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(webSocketStateProvider);

    if (connectionState == WebSocketConnectionState.connected) {
      return const SizedBox.shrink();
    }

    String message;
    Color backgroundColor;
    Color textColor;
    IconData icon;

    switch (connectionState) {
      case WebSocketConnectionState.connecting:
        message = 'Connecting...';
        backgroundColor = AppColors.primaryContainer;
        textColor = AppColors.onPrimaryContainer;
        icon = Icons.sync_rounded;
        break;
      case WebSocketConnectionState.serverWaking:
        message = 'Waking up server, please wait...';
        backgroundColor = AppColors.primaryContainer;
        textColor = AppColors.onPrimaryContainer;
        icon = Icons.cloud_sync_rounded;
        break;
      case WebSocketConnectionState.waitingToRetry:
        message = 'Waiting to reconnect...';
        backgroundColor = AppColors.errorContainer;
        textColor = AppColors.onErrorContainer;
        icon = Icons.wifi_off_rounded;
        break;
      case WebSocketConnectionState.connected:
        return const SizedBox.shrink();
    }

    return Container(
      key: const Key('connection_banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      color: backgroundColor,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: AppSpacing.md, color: textColor),
          const SizedBox(width: AppSpacing.sm),
          Text(
            message,
            style: AppTypography.bodyMedium.copyWith(
              color: textColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
