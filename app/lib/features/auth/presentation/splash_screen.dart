import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../application/auth_notifier.dart';
import '../application/auth_state.dart';

class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: authState.status == AuthStatus.networkError
                ? _buildNetworkErrorState(context, ref, authState.errorMessage)
                : _buildLoadingState(),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        Text('Pixel Chat', style: AppTypography.headlineLarge),
        SizedBox(height: AppSpacing.xl),
        CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
        ),
      ],
    );
  }

  Widget _buildNetworkErrorState(
    BuildContext context,
    WidgetRef ref,
    String? errorMessage,
  ) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.cloud_off_rounded,
          size: AppSpacing.xxl,
          color: AppColors.error,
        ),
        const SizedBox(height: AppSpacing.md),
        const Text('Connection Issue', style: AppTypography.headlineMedium),
        const SizedBox(height: AppSpacing.sm),
        Text(
          errorMessage ??
              'Unable to connect to the server. The server might be waking up.',
          textAlign: TextAlign.center,
          style: AppTypography.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.lg),
        ElevatedButton.icon(
          onPressed: () {
            ref.read(authNotifierProvider.notifier).retryBootstrap();
          },
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Retry Connection'),
        ),
      ],
    );
  }
}
