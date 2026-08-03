import 'package:flutter_test/flutter_test.dart';
import 'package:rgs_sensor_panel_flutter/src/sensors/rgs_windows_sensors.dart';

void main() {
  test('detects a CPU fan exposed by the motherboard controller', () {
    final snapshot = RgsWindowsSensors.instance.parseSnapshot({
      'available': true,
      'sensors': [
        {
          'name': 'CPU Total',
          'type': 'Load',
          'identifier': '/amdcpu/0/load/0',
          'value': 24,
          'hardware': 'AMD Ryzen 7',
          'hardwareType': 'Cpu',
        },
        {
          'name': 'CPU Fan',
          'type': 'Fan',
          'identifier': '/lpc/nct6798d/fan/1',
          'value': 1375,
          'hardware': 'Nuvoton NCT6798D',
          'hardwareType': 'SuperIO',
        },
        {
          'name': 'Chassis Fan',
          'type': 'Fan',
          'identifier': '/lpc/nct6798d/fan/2',
          'value': 900,
          'hardware': 'Nuvoton NCT6798D',
          'hardwareType': 'SuperIO',
        },
      ],
    });

    expect(snapshot.cpu.fanRpm, 1375);
  });

  test('detects fan speed separately for each GPU', () {
    final snapshot = RgsWindowsSensors.instance.parseSnapshot({
      'available': true,
      'sensors': [
        {
          'name': 'GPU Core',
          'type': 'Load',
          'identifier': '/gpu-nvidia/0/load/0',
          'value': 55,
          'hardware': 'NVIDIA GPU',
          'hardwareType': 'GpuNvidia',
        },
        {
          'name': 'GPU Fan',
          'type': 'Fan',
          'identifier': '/gpu-nvidia/0/fan/0',
          'value': 1820,
          'hardware': 'NVIDIA GPU',
          'hardwareType': 'GpuNvidia',
        },
        {
          'name': 'GPU Fan',
          'type': 'Fan',
          'identifier': '/gpu-amd/0/fan/0',
          'value': 0,
          'hardware': 'AMD GPU',
          'hardwareType': 'GpuAmd',
        },
      ],
    });

    expect(snapshot.gpus, hasLength(2));
    expect(snapshot.gpus.firstWhere((gpu) => gpu.name == 'NVIDIA GPU').fanRpm,
        1820);
    expect(snapshot.gpus.firstWhere((gpu) => gpu.name == 'AMD GPU').fanRpm, 0);
  });

  test('uses the only running generic motherboard fan as CPU fan', () {
    final snapshot = RgsWindowsSensors.instance.parseSnapshot({
      'available': true,
      'sensors': [
        for (var index = 0; index < 4; index++)
          {
            'name': 'Fan #${index + 2}',
            'type': 'Fan',
            'identifier': '/lpc/it8613e/0/fan/$index',
            'value': index == 2 ? 1839.237 : 0,
            'hardware': 'ITE IT8613E',
            'hardwareType': 'SuperIO',
          },
      ],
    });

    expect(snapshot.cpu.fanRpm, 1839.237);
  });

  test('does not guess when several generic motherboard fans are running', () {
    final snapshot = RgsWindowsSensors.instance.parseSnapshot({
      'available': true,
      'sensors': [
        for (var index = 0; index < 2; index++)
          {
            'name': 'Fan #${index + 1}',
            'type': 'Fan',
            'identifier': '/lpc/controller/0/fan/$index',
            'value': 1000 + (index * 200),
            'hardware': 'Super I/O',
            'hardwareType': 'SuperIO',
          },
      ],
    });

    expect(snapshot.cpu.fanRpm, isNull);
  });
}
