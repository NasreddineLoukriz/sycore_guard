import 'package:flutter/material.dart';

/// Shown when the native on-device engines could not be registered at startup.
class StartupErrorScreen extends StatelessWidget {
  const StartupErrorScreen({required this.error, super.key});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('SYcore Guard')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.memory, size: 56, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                'On-device AI is unavailable',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'The LiteRT native libraries could not be loaded on this '
                'device. SYcore Guard needs a 64-bit ARM Android device '
                '(API 30 or newer) or a supported desktop platform.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  error.toString(),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
