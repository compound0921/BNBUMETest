import 'dart:async';
import '../usage_sync_service.dart';

/// The shared device identity gateway for sync transports. Credentials remain
/// in the existing secure record; refresh work is single-flight per service/account.
class DeviceSessionProvider {
  DeviceSessionProvider({UsageSyncStore? store})
    : store = store ?? SecureUsageSyncStore();
  final UsageSyncStore store;
  static final Map<String, Future<void>> _refreshes = {};

  Future<String> token(String owner) async {
    final record = await store.loadDevice(schoolEmailForUsername(owner));
    if (record?.deviceToken == null) {
      throw const FormatException('Device enrollment required');
    }
    return record!.deviceToken!;
  }

  Future<void> invalidate(
    String owner,
    String rejectedToken, {
    required String origin,
  }) => mutate('$origin:${schoolEmailForUsername(owner)}', () async {
    final email = schoolEmailForUsername(owner);
    final record = await store.loadDevice(email);
    if (record != null && record.deviceToken == rejectedToken) {
      await store.saveDevice(
        email,
        UsageSyncDeviceRecord(
          installationId: record.installationId,
          deviceToken: null,
        ),
      );
    }
  });

  static final _mutations = <String, Future<void>>{};
  static Future<T> mutate<T>(String key, Future<T> Function() action) {
    final future = (_mutations[key] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final settled = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _mutations[key] = settled;
    unawaited(
      settled.whenComplete(() {
        if (identical(_mutations[key], settled)) _mutations.remove(key);
      }),
    );
    return future;
  }

  static Future<void> refresh(
    String key,
    Future<void> Function() action,
  ) async {
    final existing = _refreshes[key];
    if (existing != null) return existing;
    final future = mutate(key, action);
    _refreshes[key] = future;
    try {
      await future;
    } finally {
      if (identical(_refreshes[key], future)) _refreshes.remove(key);
    }
  }
}
