import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class RgsSensorSnapshot {
  const RgsSensorSnapshot({
    required this.available,
    required this.status,
    required this.timestamp,
    required this.hasSystemMetrics,
    this.cpu = const RgsCpuReading(),
    this.memory = const RgsMemoryReading(),
    this.gpus = const [],
    this.storage = const [],
  });

  final bool available;
  final String status;
  final DateTime timestamp;
  final bool hasSystemMetrics;
  final RgsCpuReading cpu;
  final RgsMemoryReading memory;
  final List<RgsGpuReading> gpus;
  final List<RgsStorageReading> storage;

  factory RgsSensorSnapshot.unavailable(String status) {
    return RgsSensorSnapshot(
      available: false,
      status: status,
      timestamp: DateTime.now(),
      hasSystemMetrics: false,
    );
  }
}

final class RgsCpuReading {
  const RgsCpuReading({
    this.name,
    this.load,
    this.temperature,
    this.power,
    this.clock,
  });

  final String? name;
  final double? load;
  final double? temperature;
  final double? power;
  final double? clock;
}

final class RgsMemoryReading {
  const RgsMemoryReading({
    this.name,
    this.load,
    this.usedBytes,
    this.totalBytes,
    this.temperature,
    this.power,
    this.clock,
    this.speed,
  });

  final String? name;
  final double? load;
  final int? usedBytes;
  final int? totalBytes;
  final double? temperature;
  final double? power;
  final double? clock;
  final double? speed;
}

final class RgsGpuReading {
  const RgsGpuReading({
    required this.id,
    required this.name,
    this.load,
    this.temperature,
    this.power,
    this.clock,
  });

  final String id;
  final String name;
  final double? load;
  final double? temperature;
  final double? power;
  final double? clock;
}

final class RgsStorageReading {
  const RgsStorageReading({
    required this.id,
    required this.name,
    this.percent,
    this.freeBytes,
    this.totalBytes,
    this.readBytesPerSecond,
    this.writeBytesPerSecond,
    this.temperature,
    this.power,
    this.clock,
  });

  final String id;
  final String name;
  final double? percent;
  final int? freeBytes;
  final int? totalBytes;
  final double? readBytesPerSecond;
  final double? writeBytesPerSecond;
  final double? temperature;
  final double? power;
  final double? clock;
}

final class RgsEnableSensorsResult {
  const RgsEnableSensorsResult._({
    required this.enabled,
    required this.message,
  });

  const RgsEnableSensorsResult.success()
      : this._(
          enabled: true,
          message: 'Background sensors enabled.',
        );

  const RgsEnableSensorsResult.failure(this.message)
      : enabled = false;

  final bool enabled;
  final String message;
}

final class RgsWindowsSensors {
  RgsWindowsSensors._();

  static final RgsWindowsSensors instance = RgsWindowsSensors._();

  static const backendPort = 8095;
  static const backendTaskName = 'RGS Sensor Panel Hardware Sensor Backend';
  static const backendExeName = 'rgs-sensor-backend.exe';

  DateTime _lastTaskStartAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<RgsSensorSnapshot> readSnapshot({bool tryStartExistingTask = true}) async {
    if (!Platform.isWindows) {
      return RgsSensorSnapshot.unavailable('Windows sensors are only available on Windows.');
    }

    var snapshot = await _readBackendSnapshot();
    if (snapshot.available || !tryStartExistingTask) {
      return snapshot;
    }

    await _tryStartExistingTaskThrottled();
    snapshot = await _readBackendSnapshot();
    if (snapshot.available) {
      return snapshot;
    }

    return RgsSensorSnapshot.unavailable(
      _findBackendPath() == null
          ? 'RGS backend executable not found.'
          : 'RGS backend is not running.',
    );
  }

  Future<RgsEnableSensorsResult> enableBackgroundSensors() async {
    final backendPath = _findBackendPath();
    if (backendPath == null) {
      return const RgsEnableSensorsResult.failure(
        'RGS backend executable was not found in the app folder.',
      );
    }

    final script = _buildInstallTaskScript(backendPath);
    final elevatedArguments =
        _powerShellQuote('-NoProfile -ExecutionPolicy Bypass -Command $script');
    final command =
        '\$process = Start-Process -FilePath powershell.exe '
        '-ArgumentList $elevatedArguments '
        '-WindowStyle Hidden -Verb RunAs -Wait -PassThru; '
        'exit \$process.ExitCode';

    try {
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command],
      );
      if (result.exitCode != 0) {
        return const RgsEnableSensorsResult.failure(
          'Windows did not create the elevated sensor task. Approve the UAC prompt and try again.',
        );
      }

      if (await _waitForBackendHealth()) {
        return const RgsEnableSensorsResult.success();
      }

      final snapshot = await _readBackendSnapshot();
      final diagnostics = await _backendDiagnostics();
      return RgsEnableSensorsResult.failure(
        'The sensor task started, but the backend did not answer yet. '
        'Check %TEMP%\\rgs-sensor-backend.log if this keeps happening. '
        '${snapshot.status}${diagnostics.isEmpty ? '' : ' $diagnostics'}',
      );
    } on Object {
      return const RgsEnableSensorsResult.failure(
        'Windows could not start the elevated sensor setup.',
      );
    }
  }

  Future<bool> _waitForBackendHealth() async {
    for (var attempt = 0; attempt < 15; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (await _readBackendHealth()) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _readBackendHealth() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final uri = Uri.parse('http://127.0.0.1:$backendPort/health');
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 2));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }

      final text = await response.transform(utf8.decoder).join();
      return text.contains('"ok":true');
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _tryStartExistingTaskThrottled() async {
    final now = DateTime.now();
    if (now.difference(_lastTaskStartAttempt) < const Duration(seconds: 20)) {
      return;
    }

    _lastTaskStartAttempt = now;
    try {
      await Process.run('schtasks.exe', [
        '/Run',
        '/TN',
        backendTaskName,
      ]).timeout(const Duration(seconds: 3));
    } on Object {
      // The UI can still offer the explicit enable button.
    }
  }

  Future<RgsSensorSnapshot> _readBackendSnapshot() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final uri = Uri.parse('http://127.0.0.1:$backendPort/data.json');
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 4));
      if (response.statusCode != HttpStatus.ok) {
        return RgsSensorSnapshot.unavailable('RGS backend returned HTTP ${response.statusCode}.');
      }

      final text = await response.transform(utf8.decoder).join();
      return _parseSnapshot(jsonDecode(text));
    } on Object {
      return RgsSensorSnapshot.unavailable('RGS backend unavailable.');
    } finally {
      client.close(force: true);
    }
  }

  RgsSensorSnapshot _parseSnapshot(Object? decoded) {
    if (decoded is! Map || decoded['available'] != true) {
      return RgsSensorSnapshot.unavailable('RGS backend returned no sensors.');
    }

    final sensors = decoded['sensors'];
    if (sensors is! List) {
      return RgsSensorSnapshot.unavailable('RGS backend returned invalid JSON.');
    }

    final rows = sensors
        .whereType<Map>()
        .map(
          (row) => _SensorRow(
            name: row['name']?.toString() ?? '',
            type: row['type']?.toString() ?? '',
            identifier: row['identifier']?.toString() ?? '',
            hardware: row['hardware']?.toString() ?? '',
            hardwareType: row['hardwareType']?.toString() ?? '',
            value: _asDouble(row['value']),
          ),
        )
        .where((row) => row.value != null)
        .toList();

    if (rows.isEmpty) {
      return RgsSensorSnapshot.unavailable('RGS backend returned empty sensors.');
    }

    final memory = _parseMemory(decoded['memory']);
    final hasSystemMetrics = memory.usedBytes != null || decoded['storageDevices'] is List;
    return RgsSensorSnapshot(
      available: true,
      status: hasSystemMetrics
          ? 'Libre sensors ready'
          : 'RGS backend needs update for RAM and SSD details.',
      timestamp: DateTime.now(),
      hasSystemMetrics: hasSystemMetrics,
      cpu: RgsCpuReading(
        name: _bestHardwareName(rows.where(_isCpu)),
        temperature: _bestValue(
          rows,
          hardware: _isCpu,
          type: 'temperature',
          preferredNames: const ['tctl', 'tdie', 'package', 'cpu package'],
          requirePositive: true,
        ),
        load: _bestValue(
          rows,
          hardware: _isCpu,
          type: 'load',
          preferredNames: const ['total', 'cpu total'],
        ),
        power: _bestValue(
          rows,
          hardware: _isCpu,
          type: 'power',
          preferredNames: const ['package', 'cpu package'],
          requirePositive: true,
        ),
        clock: _bestCpuClock(rows),
      ),
      memory: RgsMemoryReading(
        name: memory.name ?? _bestHardwareName(rows.where(_isMemory)),
        load: memory.load ??
            _bestValue(
              rows,
              hardware: _isMemory,
              type: 'load',
              preferredNames: const ['memory', 'used memory'],
            ),
        usedBytes: memory.usedBytes,
        totalBytes: memory.totalBytes,
        temperature: _bestValue(
          rows,
          hardware: _isMemory,
          type: 'temperature',
          preferredNames: const ['memory', 'dimm', 'module', 'temperature'],
          requirePositive: true,
        ),
        power: _bestValue(
          rows,
          hardware: _isMemory,
          type: 'power',
          preferredNames: const ['memory', 'dram', 'package'],
          requirePositive: true,
        ),
        clock: _bestValue(
          rows,
          hardware: _isMemory,
          type: 'clock',
          preferredNames: const ['memory', 'dram', 'fabric'],
          requirePositive: true,
          preferHighest: true,
        ),
        speed: memory.speedMHz,
      ),
      gpus: _buildGpuDevices(rows),
      storage: _buildStorageDevices(rows, decoded['storageDevices']),
    );
  }

  static List<RgsGpuReading> _buildGpuDevices(List<_SensorRow> rows) {
    final groups = _groupByDevice(rows.where(_isGpu));
    return [
      for (final entry in groups.entries)
        RgsGpuReading(
          id: 'gpu:${entry.key}',
          name: _bestHardwareName(entry.value) ?? 'GPU',
          load: _bestValue(
            entry.value,
            hardware: (_) => true,
            type: 'load',
            preferredNames: const ['gpu core', 'core', '3d'],
          ),
          temperature: _bestValue(
            entry.value,
            hardware: (_) => true,
            type: 'temperature',
            preferredNames: const ['gpu core', 'core'],
            requirePositive: true,
          ),
          power: _bestValue(
            entry.value,
            hardware: (_) => true,
            type: 'power',
            preferredNames: const ['gpu package', 'gpu power', 'total board'],
            requirePositive: true,
          ),
          clock: _bestValue(
            entry.value,
            hardware: (_) => true,
            type: 'clock',
            preferredNames: const ['gpu core', 'core'],
            requirePositive: true,
            preferHighest: true,
          ),
        ),
    ];
  }

  static List<RgsStorageReading> _buildStorageDevices(
    List<_SensorRow> rows,
    Object? storageDevices,
  ) {
    final groups = _groupByDevice(rows.where(_isStorage));
    final hardwareDevices = [
      for (final entry in groups.entries)
        RgsStorageReading(
          id: 'storage:${entry.key}',
          name: _bestHardwareName(entry.value) ?? 'SSD',
          temperature: _bestValue(
            entry.value,
            hardware: (_) => true,
            type: 'temperature',
            preferredNames: const ['temperature', 'composite', 'drive'],
            requirePositive: true,
          ),
          power: _bestValue(
            entry.value,
            hardware: (_) => true,
            type: 'power',
            preferredNames: const ['power', 'package'],
            requirePositive: true,
          ),
          clock: _bestValue(
            entry.value,
            hardware: (_) => true,
            type: 'clock',
            preferredNames: const ['clock'],
            requirePositive: true,
            preferHighest: true,
          ),
        ),
    ];

    final logicalDevices = _parseStorageDevices(storageDevices);
    if (logicalDevices.isEmpty) {
      return hardwareDevices;
    }

    final canMapHardwareByIndex = hardwareDevices.length == logicalDevices.length ||
        (hardwareDevices.length == 1 && logicalDevices.length == 1);
    return [
      for (var index = 0; index < logicalDevices.length; index++)
        RgsStorageReading(
          id: logicalDevices[index].id,
          name: logicalDevices[index].name,
          percent: logicalDevices[index].percent,
          freeBytes: logicalDevices[index].freeBytes,
          totalBytes: logicalDevices[index].totalBytes,
          readBytesPerSecond: logicalDevices[index].readBytesPerSecond,
          writeBytesPerSecond: logicalDevices[index].writeBytesPerSecond,
          temperature:
              canMapHardwareByIndex && index < hardwareDevices.length
                  ? hardwareDevices[index].temperature
                  : null,
          power: canMapHardwareByIndex && index < hardwareDevices.length
              ? hardwareDevices[index].power
              : null,
          clock: canMapHardwareByIndex && index < hardwareDevices.length
              ? hardwareDevices[index].clock
              : null,
        ),
    ];
  }

  static _ParsedMemory _parseMemory(Object? value) {
    if (value is! Map) {
      return const _ParsedMemory();
    }

    return _ParsedMemory(
      name: value['name']?.toString(),
      load: _asDouble(value['load']),
      usedBytes: _asInt(value['usedBytes']),
      totalBytes: _asInt(value['totalBytes']),
      speedMHz: _asDouble(value['speedMHz']),
    );
  }

  static List<RgsStorageReading> _parseStorageDevices(Object? value) {
    if (value is! List) {
      return const [];
    }

    return [
      for (final row in value.whereType<Map>())
        if (row['id'] != null && row['name'] != null)
          RgsStorageReading(
            id: row['id'].toString(),
            name: row['name'].toString(),
            percent: _asDouble(row['percent']),
            freeBytes: _asInt(row['freeBytes']),
            totalBytes: _asInt(row['totalBytes']),
            readBytesPerSecond: _asDouble(row['readBytesPerSecond']),
            writeBytesPerSecond: _asDouble(row['writeBytesPerSecond']),
          ),
    ];
  }

  static Map<String, List<_SensorRow>> _groupByDevice(Iterable<_SensorRow> rows) {
    final groups = <String, List<_SensorRow>>{};
    for (final row in rows) {
      groups.putIfAbsent(_deviceGroupId(row), () => []).add(row);
    }
    return groups;
  }

  static String _deviceGroupId(_SensorRow row) {
    final parts = row.identifier.split('/').where((part) => part.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '/${parts[0]}/${parts[1]}';
    }
    if (parts.length == 1) {
      return '/${parts[0]}';
    }
    if (row.hardware.isNotEmpty) {
      return row.hardware;
    }
    return row.identifier;
  }

  static String? _bestHardwareName(Iterable<_SensorRow> rows) {
    for (final row in rows) {
      if (row.hardware.trim().isNotEmpty) {
        return row.hardware.trim();
      }
    }
    return null;
  }

  static double? _bestValue(
    List<_SensorRow> rows, {
    required bool Function(_SensorRow row) hardware,
    required String type,
    List<String> preferredNames = const [],
    bool requirePositive = false,
    bool preferHighest = false,
  }) {
    final matches = rows
        .where(
          (row) =>
              hardware(row) &&
              row.type.toLowerCase() == type.toLowerCase() &&
              (!requirePositive || (row.value ?? 0) > 0),
        )
        .toList();
    if (matches.isEmpty) {
      return null;
    }

    matches.sort((a, b) {
      final score = _scoreName(b.name, preferredNames).compareTo(
        _scoreName(a.name, preferredNames),
      );
      if (score != 0) {
        return score;
      }
      if (preferHighest) {
        return b.value!.compareTo(a.value!);
      }
      return a.identifier.compareTo(b.identifier);
    });
    return matches.first.value;
  }

  static double? _bestCpuClock(List<_SensorRow> rows) {
    final coreClocks = rows
        .where(
          (row) =>
              _isCpu(row) &&
              row.type.toLowerCase() == 'clock' &&
              (row.value ?? 0) > 0 &&
              row.name.toLowerCase().contains('core') &&
              !row.name.toLowerCase().contains('bus') &&
              !row.name.toLowerCase().contains('fabric'),
        )
        .map((row) => row.value!)
        .toList();
    if (coreClocks.isNotEmpty) {
      coreClocks.sort();
      return coreClocks.last;
    }

    return _bestValue(
      rows,
      hardware: _isCpu,
      type: 'clock',
      preferredNames: const ['effective', 'average', 'core'],
      requirePositive: true,
      preferHighest: true,
    );
  }

  static int _scoreName(String name, List<String> preferredNames) {
    final normalized = name.toLowerCase();
    var score = 0;
    for (var index = 0; index < preferredNames.length; index++) {
      if (normalized.contains(preferredNames[index])) {
        score += 100 - index;
      }
    }
    return score;
  }

  static bool _isCpu(_SensorRow row) {
    final id = row.identifier.toLowerCase();
    return id.contains('/cpu') ||
        id.contains('/amdcpu') ||
        id.contains('/intelcpu');
  }

  static bool _isGpu(_SensorRow row) {
    if (_isCpu(row)) {
      return false;
    }

    final id = row.identifier.toLowerCase();
    final hardwareType = row.hardwareType.toLowerCase();
    return id.contains('/gpu') || hardwareType.contains('gpu');
  }

  static bool _isMemory(_SensorRow row) {
    final text = '${row.identifier} ${row.hardware} ${row.hardwareType}'.toLowerCase();
    return text.contains('/ram') ||
        text.contains('memory') ||
        text.contains('dimm');
  }

  static bool _isStorage(_SensorRow row) {
    final text = '${row.identifier} ${row.hardware} ${row.hardwareType}'.toLowerCase();
    return text.contains('/hdd') ||
        text.contains('/ssd') ||
        text.contains('storage') ||
        text.contains('nvme');
  }

  static double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  static String? _findBackendPath() {
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    final currentDir = Directory.current.path;
    final candidates = [
      '$executableDir\\$backendExeName',
      '$currentDir\\$backendExeName',
      '$currentDir\\sensor_backend\\bin\\Release\\net48\\$backendExeName',
      '$currentDir\\sensor_backend\\bin\\Debug\\net48\\$backendExeName',
      '$currentDir\\..\\sensor_backend\\bin\\Release\\net48\\$backendExeName',
      '$currentDir\\..\\sensor_backend\\bin\\Debug\\net48\\$backendExeName',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  static String _buildInstallTaskScript(String backendPath) {
    final exe = _powerShellQuote(backendPath);
    final taskName = _powerShellQuote(backendTaskName);
    final taskArguments = _powerShellQuote('--port $backendPort');
    return [
      r"$ErrorActionPreference = 'Stop'",
      '\$taskName = $taskName',
      '\$exe = $exe',
      'if (-not (Test-Path -LiteralPath \$exe)) { throw "Backend executable was not found." }',
      '\$taskArguments = $taskArguments',
      'Stop-ScheduledTask -TaskName \$taskName -ErrorAction SilentlyContinue',
      "Get-Process -Name 'rgs-sensor-backend' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue",
      '\$action = New-ScheduledTaskAction -Execute \$exe -Argument \$taskArguments',
      '\$trigger = New-ScheduledTaskTrigger -AtLogOn',
      '\$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name',
      '\$principal = New-ScheduledTaskPrincipal -UserId \$user -LogonType Interactive -RunLevel Highest',
      'Register-ScheduledTask -TaskName \$taskName -Action \$action -Trigger \$trigger -Principal \$principal -Force | Out-Null',
      'Start-ScheduledTask -TaskName \$taskName',
    ].join('; ');
  }

  Future<String> _backendDiagnostics() async {
    final parts = <String>[];
    final taskStatus = await _queryBackendTaskStatus();
    if (taskStatus != null) {
      parts.add(taskStatus);
    }

    final logTail = _readBackendLogTail();
    if (logTail != null) {
      parts.add(logTail);
    }

    return parts.join(' ');
  }

  Future<String?> _queryBackendTaskStatus() async {
    try {
      final result = await Process.run('schtasks.exe', [
        '/Query',
        '/TN',
        backendTaskName,
        '/V',
        '/FO',
        'LIST',
      ]).timeout(const Duration(seconds: 3));
      if (result.exitCode != 0) {
        return null;
      }

      final output = '${result.stdout}\n${result.stderr}';
      final status = _findTaskLine(output, 'Status');
      final lastResult = _findTaskLine(output, 'Last Run Result');
      final details = [
        if (status != null) 'task status: $status',
        if (lastResult != null) 'last result: $lastResult',
      ].join(', ');
      return details.isEmpty ? null : '($details)';
    } on Object {
      return null;
    }
  }

  static String? _findTaskLine(String output, String key) {
    final prefix = '$key:';
    for (final line in const LineSplitter().convert(output)) {
      final trimmed = line.trim();
      if (trimmed.toLowerCase().startsWith(prefix.toLowerCase())) {
        return trimmed.substring(prefix.length).trim();
      }
    }
    return null;
  }

  static String? _readBackendLogTail() {
    try {
      final logFile = File('${Directory.systemTemp.path}\\rgs-sensor-backend.log');
      if (!logFile.existsSync()) {
        return null;
      }

      final lines = logFile.readAsLinesSync();
      if (lines.isEmpty) {
        return null;
      }

      final tail = lines.skip(lines.length > 2 ? lines.length - 2 : 0).join(' | ');
      return 'log: ${tail.length > 360 ? '${tail.substring(0, 360)}...' : tail}';
    } on Object {
      return null;
    }
  }

  static String _powerShellQuote(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }
}

final class _SensorRow {
  const _SensorRow({
    required this.name,
    required this.type,
    required this.identifier,
    required this.hardware,
    required this.hardwareType,
    required this.value,
  });

  final String name;
  final String type;
  final String identifier;
  final String hardware;
  final String hardwareType;
  final double? value;
}

final class _ParsedMemory {
  const _ParsedMemory({
    this.name,
    this.load,
    this.usedBytes,
    this.totalBytes,
    this.speedMHz,
  });

  final String? name;
  final double? load;
  final int? usedBytes;
  final int? totalBytes;
  final double? speedMHz;
}
