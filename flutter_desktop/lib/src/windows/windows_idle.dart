import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _GetLastInputInfoNative = Int32 Function(Pointer<_LastInputInfo> info);
typedef _GetLastInputInfoDart = int Function(Pointer<_LastInputInfo> info);
typedef _GetTickCountNative = Uint32 Function();
typedef _GetTickCountDart = int Function();
typedef _GetSystemPowerStatusNative = Int32 Function(
  Pointer<_SystemPowerStatus> status,
);
typedef _GetSystemPowerStatusDart = int Function(
  Pointer<_SystemPowerStatus> status,
);
typedef _PowerGetActiveSchemeNative = Uint32 Function(
  IntPtr userRootPowerKey,
  Pointer<Pointer<_Guid>> activePolicyGuid,
);
typedef _PowerGetActiveSchemeDart = int Function(
  int userRootPowerKey,
  Pointer<Pointer<_Guid>> activePolicyGuid,
);
typedef _PowerReadValueIndexNative = Uint32 Function(
  IntPtr rootPowerKey,
  Pointer<_Guid> schemeGuid,
  Pointer<_Guid> subgroupGuid,
  Pointer<_Guid> settingGuid,
  Pointer<Uint32> valueIndex,
);
typedef _PowerReadValueIndexDart = int Function(
  int rootPowerKey,
  Pointer<_Guid> schemeGuid,
  Pointer<_Guid> subgroupGuid,
  Pointer<_Guid> settingGuid,
  Pointer<Uint32> valueIndex,
);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> memory);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> memory);

final class WindowsIdle {
  WindowsIdle._();

  static const Duration _displayTimeoutCacheDuration = Duration(minutes: 1);
  static DateTime? _displayTimeoutCachedAt;
  static Duration? _displayTimeoutCache;

  static Duration idleDuration() {
    if (!Platform.isWindows) {
      return Duration.zero;
    }

    final info = calloc<_LastInputInfo>();
    try {
      info.ref.cbSize = sizeOf<_LastInputInfo>();
      final success = _getLastInputInfo(info) != 0;
      if (!success) {
        return Duration.zero;
      }

      final now = _getTickCount();
      final lastInput = info.ref.dwTime;
      final elapsed = (now - lastInput) & 0xFFFFFFFF;
      return Duration(milliseconds: elapsed);
    } finally {
      calloc.free(info);
    }
  }

  static Duration? displayIdleTimeout() {
    if (!Platform.isWindows) {
      return null;
    }

    final now = DateTime.now();
    final cachedAt = _displayTimeoutCachedAt;
    if (cachedAt != null &&
        now.difference(cachedAt) < _displayTimeoutCacheDuration) {
      return _displayTimeoutCache;
    }

    _displayTimeoutCache = _readDisplayIdleTimeout();
    _displayTimeoutCachedAt = now;
    return _displayTimeoutCache;
  }

  static Duration? _readDisplayIdleTimeout() {
    final activeScheme = calloc<Pointer<_Guid>>();
    final subgroup = _allocateGuid(
      0x7516b95f,
      0xf776,
      0x4464,
      [0x8c, 0x53, 0x06, 0x16, 0x7f, 0x40, 0xcc, 0x99],
    );
    final setting = _allocateGuid(
      0x3c0bc021,
      0xc8a8,
      0x4e07,
      [0xa9, 0x73, 0x6b, 0x14, 0xcb, 0xcb, 0x2b, 0x7e],
    );
    final valueIndex = calloc<Uint32>();

    try {
      final schemeResult = _powerGetActiveScheme(0, activeScheme);
      if (schemeResult != 0 || activeScheme.value == nullptr) {
        return null;
      }

      final readValue = _isOnBatteryPower()
          ? _powerReadDCValueIndex
          : _powerReadACValueIndex;
      var readResult = readValue(
        0,
        activeScheme.value,
        subgroup,
        setting,
        valueIndex,
      );

      if (readResult != 0) {
        readResult = _powerReadACValueIndex(
          0,
          activeScheme.value,
          subgroup,
          setting,
          valueIndex,
        );
      }

      if (readResult != 0) {
        return null;
      }

      return Duration(seconds: valueIndex.value);
    } finally {
      if (activeScheme.value != nullptr) {
        _localFree(activeScheme.value.cast<Void>());
      }
      calloc.free(activeScheme);
      calloc.free(subgroup);
      calloc.free(setting);
      calloc.free(valueIndex);
    }
  }

  static bool _isOnBatteryPower() {
    final status = calloc<_SystemPowerStatus>();
    try {
      if (_getSystemPowerStatus(status) == 0) {
        return false;
      }

      return status.ref.acLineStatus == 0;
    } finally {
      calloc.free(status);
    }
  }

  static Pointer<_Guid> _allocateGuid(
    int data1,
    int data2,
    int data3,
    List<int> data4,
  ) {
    final guid = calloc<_Guid>();
    guid.ref.data1 = data1;
    guid.ref.data2 = data2;
    guid.ref.data3 = data3;
    for (var index = 0; index < 8; index++) {
      guid.ref.data4[index] = data4[index];
    }
    return guid;
  }

  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final DynamicLibrary _powrprof = DynamicLibrary.open('powrprof.dll');

  static final _GetLastInputInfoDart _getLastInputInfo = _user32
      .lookupFunction<_GetLastInputInfoNative, _GetLastInputInfoDart>(
    'GetLastInputInfo',
  );

  static final _GetTickCountDart _getTickCount =
      _kernel32.lookupFunction<_GetTickCountNative, _GetTickCountDart>(
    'GetTickCount',
  );

  static final _GetSystemPowerStatusDart _getSystemPowerStatus =
      _kernel32.lookupFunction<_GetSystemPowerStatusNative,
          _GetSystemPowerStatusDart>('GetSystemPowerStatus');

  static final _LocalFreeDart _localFree =
      _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  static final _PowerGetActiveSchemeDart _powerGetActiveScheme =
      _powrprof.lookupFunction<_PowerGetActiveSchemeNative,
          _PowerGetActiveSchemeDart>('PowerGetActiveScheme');

  static final _PowerReadValueIndexDart _powerReadACValueIndex =
      _powrprof.lookupFunction<_PowerReadValueIndexNative,
          _PowerReadValueIndexDart>('PowerReadACValueIndex');

  static final _PowerReadValueIndexDart _powerReadDCValueIndex =
      _powrprof.lookupFunction<_PowerReadValueIndexNative,
          _PowerReadValueIndexDart>('PowerReadDCValueIndex');
}

final class _LastInputInfo extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int dwTime;
}

final class _SystemPowerStatus extends Struct {
  @Uint8()
  external int acLineStatus;

  @Uint8()
  external int batteryFlag;

  @Uint8()
  external int batteryLifePercent;

  @Uint8()
  external int systemStatusFlag;

  @Uint32()
  external int batteryLifeTime;

  @Uint32()
  external int batteryFullLifeTime;
}

final class _Guid extends Struct {
  @Uint32()
  external int data1;

  @Uint16()
  external int data2;

  @Uint16()
  external int data3;

  @Array(8)
  external Array<Uint8> data4;
}
