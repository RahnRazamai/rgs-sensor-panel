import 'dart:io';

final class RgsStartupRegistrationResult {
  const RgsStartupRegistrationResult._({
    required this.success,
    required this.message,
  });

  const RgsStartupRegistrationResult.success()
      : this._(success: true, message: '');

  const RgsStartupRegistrationResult.failure(String message)
      : this._(success: false, message: message);

  final bool success;
  final String message;
}

final class RgsStartupRegistration {
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'RGS Sensor Panel';

  static Future<RgsStartupRegistrationResult> setEnabled(bool enabled) async {
    if (!Platform.isWindows) {
      return const RgsStartupRegistrationResult.success();
    }

    return enabled ? _enable() : _disable();
  }

  static Future<RgsStartupRegistrationResult> _enable() async {
    final command = '"${Platform.resolvedExecutable}" --rgs-startup';
    final result = await Process.run(
      'reg.exe',
      [
        'add',
        _runKey,
        '/v',
        _valueName,
        '/t',
        'REG_SZ',
        '/d',
        command,
        '/f',
      ],
    );

    if (result.exitCode == 0) {
      return const RgsStartupRegistrationResult.success();
    }

    return RgsStartupRegistrationResult.failure(
      'Windows startup registration failed. ${_processOutput(result)}',
    );
  }

  static Future<RgsStartupRegistrationResult> _disable() async {
    final result = await Process.run(
      'reg.exe',
      [
        'delete',
        _runKey,
        '/v',
        _valueName,
        '/f',
      ],
    );

    if (result.exitCode == 0 || _looksLikeMissingValue(result)) {
      return const RgsStartupRegistrationResult.success();
    }

    return RgsStartupRegistrationResult.failure(
      'Windows startup cleanup failed. ${_processOutput(result)}',
    );
  }

  static bool _looksLikeMissingValue(ProcessResult result) {
    final output = _processOutput(result).toLowerCase();
    return output.contains('unable to find') ||
        output.contains('cannot find') ||
        output.contains('not found');
  }

  static String _processOutput(ProcessResult result) {
    final stdout = result.stdout.toString().trim();
    final stderr = result.stderr.toString().trim();
    final output = [stdout, stderr].where((item) => item.isNotEmpty).join(' ');
    return output.isEmpty ? 'Exit code ${result.exitCode}.' : output;
  }
}
