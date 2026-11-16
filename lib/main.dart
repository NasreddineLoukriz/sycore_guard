import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';

import 'src/ui/chat_screen.dart';
import 'src/ui/startup_error_screen.dart';

/// Registers the on-device engines before the UI starts.
///
/// A failure here is shown in the UI instead of crashing to a white screen:
/// the native LiteRT libraries are the one part of the app that can be missing
/// on unsupported devices.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Object? startupError;
  try {
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [LiteRtLmEngine()],
      sttBackends: const [LiteRtSttBackend()],
      ttsBackends: const [LiteRtTtsBackend()],
    );
  } catch (error, stackTrace) {
    startupError = error;
    debugPrint('On-device engines failed to initialize: $error\n$stackTrace');
  }

  runApp(SycoreGuardApp(startupError: startupError));
}

class SycoreGuardApp extends StatelessWidget {
  const SycoreGuardApp({this.startupError, super.key});

  /// Non-null when the native engines could not be registered.
  final Object? startupError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SYcore Guard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F51B5)),
        useMaterial3: true,
      ),
      home: startupError == null
          ? const ChatScreen()
          : StartupErrorScreen(error: startupError!),
    );
  }
}
