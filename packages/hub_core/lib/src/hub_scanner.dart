import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

import 'protocol.dart';

/// Discovered hub endpoint on the local network.
class HubEndpoint {
  const HubEndpoint({
    required this.host,
    required this.port,
    required this.name,
    this.id,
    this.version = kProtocolVersion,
  });

  final String host;
  final int port;
  final String name;
  final String? id;
  final int version;

  String get address => '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is HubEndpoint &&
      other.host == host &&
      other.port == port &&
      other.id == id &&
      other.name == name;

  @override
  int get hashCode => Object.hash(host, port, id, name);
}

/// Reads one `key=value` entry from a TXT record string.
String? hubTxtValue(String txt, String key) {
  for (final line in txt.split(RegExp(r'[\r\n]+'))) {
    if (line.startsWith('$key=') && line.length > key.length + 1) {
      return line.substring(key.length + 1);
    }
  }
  return null;
}

/// Discovers `_tvsaver._tcp` hubs on the LAN via mDNS PTR -> SRV -> TXT -> A.
class HubScanner {
  HubScanner({this.timeout = const Duration(seconds: 6)});

  final Duration timeout;

  Stream<HubEndpoint> scan() {
    late StreamController<HubEndpoint> out;
    MDnsClient? client;
    var stopped = false;

    Future<void> stop() async {
      if (stopped) return;
      stopped = true;
      client?.stop();
      if (!out.isClosed) await out.close();
    }

    Future<void> run() async {
      try {
        client = MDnsClient();
        await client!.start();
        if (stopped) {
          client!.stop(); // stop() ran while start() was still pending.
          return;
        }
        final deadline = DateTime.now().add(timeout);
        final seen = <String>{};
        await for (final ptr in client!.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer('$kHubService.local'),
          timeout: timeout,
        )) {
          if (stopped || DateTime.now().isAfter(deadline)) break;
          if (seen.contains(ptr.domainName)) continue;
          final endpoint = await _resolve(client!, ptr.domainName);
          if (endpoint == null) continue; // A transient failure can retry.
          seen.add(ptr.domainName);
          if (!out.isClosed) out.add(endpoint);
        }
      } catch (_) {
        // Multicast can be unavailable on some networks; caller falls back to QR or manual entry.
      } finally {
        await stop();
      }
    }

    out = StreamController<HubEndpoint>(onListen: run, onCancel: stop);
    return out.stream;
  }

  Future<HubEndpoint?> _resolve(MDnsClient client, String instance) async {
    const t = Duration(seconds: 3);
    final srv = await _first(
      client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(instance),
        timeout: t,
      ),
    );
    if (srv == null) return null;
    final txt = await _first(
      client.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(instance),
        timeout: t,
      ),
    );
    final ip = await _first(
      client.lookup<IPAddressResourceRecord>(
        ResourceRecordQuery.addressIPv4(srv.target),
        timeout: t,
      ),
    );
    if (ip == null) return null;
    final text = txt?.text ?? '';
    final name =
        hubTxtValue(text, 'name') ?? instance.split('.$kHubService').first;
    final version =
        int.tryParse(hubTxtValue(text, 'v') ?? '') ?? kProtocolVersion;
    return HubEndpoint(
      host: ip.address.address,
      port: srv.port,
      name: name,
      id: hubTxtValue(text, 'id'),
      version: version,
    );
  }
}

Future<T?> _first<T>(Stream<T> s) async {
  await for (final v in s) {
    return v;
  }
  return null;
}
