import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bnbu_me/services/device_identity_service.dart';
import 'package:bnbu_me/services/usage_sync_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  test('school email is derived without retaining the submitted password', () {
    expect(
      schoolEmailForUsername(' Student01@mail.bnbu.edu.cn '),
      'student01@mail.bnbu.edu.cn',
    );
    expect(
      () => schoolEmailForUsername('student+tag'),
      throwsA(isA<UsageSyncException>()),
    );
  });

  test(
    'enrollment sends only policy-covered directory and device metadata',
    () async {
      final store = _MemoryUsageSyncStore();
      late Map<String, dynamic> payload;
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://sync.example/v1/enrollment');
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'user_id': '00000000-0000-0000-0000-000000000001',
            'device_id': '00000000-0000-0000-0000-000000000002',
            'device_token': 'dev_test-device-token',
            'email_verified': false,
          }),
          201,
        );
      });
      final service = RemoteUsageSyncService(
        client: client,
        store: store,
        baseUrl: 'https://sync.example',
        platformProvider: () => 'ios',
        packageInfoLoader: () async => PackageInfo(
          appName: 'BNBU.ME',
          packageName: 'dev.example.bnbu.test',
          version: '1.2.0',
          buildNumber: '42',
        ),
      );

      await service.synchronize('student01');

      expect(payload['email'], 'student01@mail.bnbu.edu.cn');
      expect(payload['platform'], 'ios');
      expect(payload['app_version'], '1.2.0+42');
      expect(payload['consent_version'], usageDataConsentVersion);
      expect(payload.keys, isNot(contains('password')));
      expect(payload.keys, isNot(contains('token')));
      expect(payload.keys, isNot(contains('cookie')));
      expect(store.record?.deviceToken, 'dev_test-device-token');
    },
  );

  test('远端旧关闭状态会在下一次 heartbeat 时自动重新开启', () async {
    final store = _MemoryUsageSyncStore(
      record: const UsageSyncDeviceRecord(
        installationId: 'installation-id-000000000000000001',
        deviceToken: 'dev_existing-token',
      ),
    );
    final requests = <http.Request>[];
    final service = RemoteUsageSyncService(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/v1/devices/current/heartbeat') {
          return http.Response('', 403);
        }
        expect(request.url.path, '/v1/enrollment');
        return http.Response(
          jsonEncode({'device_token': 'dev_reenabled-token'}),
          201,
        );
      }),
      store: store,
      baseUrl: 'https://sync.example',
      platformProvider: () => 'ios',
      packageInfoLoader: () async => PackageInfo(
        appName: 'BNBU.ME',
        packageName: 'dev.example.bnbu.test',
        version: '1.2.0',
        buildNumber: '42',
      ),
    );

    await service.heartbeat('student01');

    expect(requests.map((request) => request.url.path), <String>[
      '/v1/devices/current/heartbeat',
      '/v1/enrollment',
    ]);
    expect(store.record?.deviceToken, 'dev_reenabled-token');
  });

  test('heartbeat authenticates with the stored device token', () async {
    final store = _MemoryUsageSyncStore(
      record: const UsageSyncDeviceRecord(
        installationId: 'installation-id-000000000000000001',
        deviceToken: 'dev_existing-token',
      ),
    );
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://sync.example/v1/devices/current/heartbeat',
      );
      expect(request.headers['authorization'], 'Bearer dev_existing-token');
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload, {'platform': 'android', 'app_version': '1.2.0+7'});
      return http.Response('', 204);
    });
    final service = RemoteUsageSyncService(
      client: client,
      store: store,
      baseUrl: 'https://sync.example',
      platformProvider: () => 'android',
      packageInfoLoader: () async => PackageInfo(
        appName: 'BNBU.ME',
        packageName: 'me.bnbu.app',
        version: '1.2.0',
        buildNumber: '7',
      ),
    );

    await service.heartbeat('student01');
  });

  test('旧安装令牌会把实体设备标识原位迁移到服务端', () async {
    const physicalDeviceId =
        'physical-device-identity-000000000000000000000001';
    final store = _MemoryUsageSyncStore(
      record: const UsageSyncDeviceRecord(
        installationId: 'legacy-installation-0000000000000001',
        deviceToken: 'dev_legacy-device-token',
      ),
    );
    late Map<String, dynamic> payload;
    final service = RemoteUsageSyncService(
      client: MockClient((request) async {
        expect(
          request.headers['authorization'],
          'Bearer dev_legacy-device-token',
        );
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'device_token': 'dev_migrated-device-token'}),
          201,
        );
      }),
      store: store,
      deviceIdentityProvider: const FixedPhysicalDeviceIdentityProvider(
        physicalDeviceId,
      ),
      baseUrl: 'https://sync.example',
      platformProvider: () => 'android',
      packageInfoLoader: () async => PackageInfo(
        appName: 'BNBU.ME',
        packageName: 'me.bnbu.app',
        version: '1.2.0',
        buildNumber: '7',
      ),
    );

    await service.synchronize('student01');

    expect(payload['device_installation_id'], physicalDeviceId);
    expect(store.record?.installationId, physicalDeviceId);
    expect(store.record?.deviceToken, 'dev_migrated-device-token');
  });

  test('heartbeat retries a transient gateway failure', () async {
    final store = _MemoryUsageSyncStore(
      record: const UsageSyncDeviceRecord(
        installationId: 'installation-id-000000000000000001',
        deviceToken: 'dev_existing-token',
      ),
    );
    var attempts = 0;
    final service = RemoteUsageSyncService(
      client: MockClient((_) async {
        attempts++;
        return http.Response('', attempts == 1 ? 503 : 204);
      }),
      store: store,
      baseUrl: 'https://sync.example',
      platformProvider: () => 'ios',
      packageInfoLoader: () async => PackageInfo(
        appName: 'BNBU.ME',
        packageName: 'dev.example.bnbu.test',
        version: '1.2.0',
        buildNumber: '42',
      ),
      retryDelay: (_) async {},
    );

    await service.heartbeat('student01');

    expect(attempts, 2);
  });
}

class _MemoryUsageSyncStore implements UsageSyncStore {
  _MemoryUsageSyncStore({this.record});

  UsageSyncDeviceRecord? record;

  @override
  Future<UsageSyncDeviceRecord?> loadDevice(String email) async => record;

  @override
  Future<void> saveDevice(String email, UsageSyncDeviceRecord record) async {
    this.record = record;
  }
}
