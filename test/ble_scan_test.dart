// Regression tests for the BLE scan permission fix (v0.27.2): the scan
// must request the runtime permissions (with fine location) before
// starting, and a denial must surface the Settings guidance instead of
// running a silent empty scan.
//
// Uses a fake UniversalBlePlatform installed via UniversalBle.setInstance.
// There is no public getter to restore the default platform, so the fake
// stays installed for the rest of this test file's isolate — no other
// test in this file touches the real BLE platform.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:shepherd/services/ble_scan.dart';

class _FakeBlePlatform extends UniversalBlePlatform {
  /// Ordered call log, e.g. 'requestPermissions:true', 'startScan'.
  final List<String> calls = [];
  int get startScanCalls => calls.where((c) => c == 'startScan').length;

  /// When true, requestPermissions throws (user denied).
  bool denyPermissions = false;

  /// Device to emit on the scan stream when a scan starts, if any.
  BleDevice? deviceToEmit;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      AvailabilityState.poweredOn;

  @override
  Future<void> requestPermissions({
    bool withAndroidFineLocation = false,
  }) async {
    calls.add('requestPermissions:$withAndroidFineLocation');
    if (denyPermissions) {
      throw Exception('Permission denied by user');
    }
  }

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    calls.add('startScan');
    final d = deviceToEmit;
    if (d != null) updateScanResult(d);
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<bool> isScanning() async => false;

  // --- Not exercised by these tests. ---
  @override
  Future<bool> enableBluetooth() => throw UnimplementedError();
  @override
  Future<bool> disableBluetooth() => throw UnimplementedError();
  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) =>
      throw UnimplementedError();
  @override
  Future<void> disconnect(String deviceId) => throw UnimplementedError();
  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) =>
      throw UnimplementedError();
  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) =>
      throw UnimplementedError();
  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) =>
      throw UnimplementedError();
  @override
  Future<Uint8List> readDescriptorValue(
    String deviceId,
    String service,
    String characteristic,
    String descriptor, {
    Duration? timeout,
  }) =>
      throw UnimplementedError();
  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) =>
      throw UnimplementedError();
  @override
  Future<void> writeDescriptorValue(
    String deviceId,
    String service,
    String characteristic,
    String descriptor,
    Uint8List value,
  ) =>
      throw UnimplementedError();
  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) =>
      throw UnimplementedError();
  @override
  Future<int> readRssi(String deviceId) => throw UnimplementedError();
  @override
  Future<void> requestConnectionPriority(
    String deviceId,
    BleConnectionPriority priority,
  ) =>
      throw UnimplementedError();
  @override
  Future<bool> isPaired(String deviceId) => throw UnimplementedError();
  @override
  Future<bool> pair(String deviceId) => throw UnimplementedError();
  @override
  Future<void> unpair(String deviceId) => throw UnimplementedError();
  @override
  Future<BleConnectionState> getConnectionState(String deviceId) =>
      throw UnimplementedError();
  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) =>
      throw UnimplementedError();
}

void main() {
  late _FakeBlePlatform fake;

  setUp(() {
    fake = _FakeBlePlatform();
    UniversalBle.setInstance(fake);
  });

  test('scan requests fine-location permission before starting the scan',
      () async {
    final found = await UniversalBleScanSource().scan(
      timeout: const Duration(milliseconds: 50),
    );
    expect(found, isEmpty);
    expect(
      fake.calls,
      ['requestPermissions:true', 'startScan'],
      reason: 'permission request (with fine location) must precede startScan',
    );
  });

  test('scan returns devices heard on the stream', () async {
    fake.deviceToEmit = BleDevice(
      deviceId: 'AA:BB:CC:DD:EE:FF',
      name: 'Test Beacon',
      rssi: -65,
    );
    final found = await UniversalBleScanSource().scan(
      timeout: const Duration(milliseconds: 100),
    );
    expect(found.map((d) => d.id), ['AA:BB:CC:DD:EE:FF']);
    expect(found.single.name, 'Test Beacon');
    expect(fake.calls.first, 'requestPermissions:true');
  });

  test('denied permission surfaces Settings guidance and never scans',
      () async {
    fake.denyPermissions = true;
    final service = BleScanService();
    await service.scan(simulate: false);
    expect(service.error, contains('Settings'));
    expect(service.error, contains('Nearby devices'));
    expect(service.devices, isEmpty);
    expect(fake.startScanCalls, 0);
    expect(fake.calls, ['requestPermissions:true']);
  });
}
