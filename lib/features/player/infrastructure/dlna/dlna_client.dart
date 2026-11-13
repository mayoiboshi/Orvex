import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

class DlnaFailure implements Exception {
  DlnaFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class DlnaDevice {
  DlnaDevice._(this.peer, this.control, this.service, this.sourceAddress);
  final InternetAddress peer;
  final Uri control;
  final String service;
  final InternetAddress? sourceAddress;

  static InternetAddress _address(Uri uri, {required bool allowLoopback}) {
    final ip = InternetAddress.tryParse(uri.host);
    if (uri.scheme != 'http' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        ip.address == '0.0.0.0' ||
        ip.isMulticast ||
        (!allowLoopback && ip.isLoopback)) {
      throw DlnaFailure('需要指定单播 IPv4 HTTP 地址');
    }
    return ip;
  }

  static void _samePeer(
    Uri uri,
    InternetAddress peer, {
    required bool allowLoopback,
  }) {
    if (_address(uri, allowLoopback: allowLoopback).address != peer.address) {
      throw DlnaFailure('设备返回的地址不属于指定主机');
    }
  }

  static XmlDocument _xml(String body) {
    if (RegExp(
      r'<!\s*(?:DOCTYPE|ENTITY)',
      caseSensitive: false,
    ).hasMatch(body)) {
      throw DlnaFailure('不支持 XML DTD');
    }
    try {
      return XmlDocument.parse(body);
    } catch (_) {
      throw DlnaFailure('设备 XML 格式无效');
    }
  }

  static List<XmlElement> _children(XmlElement e, String name) =>
      e.childElements.where((x) => x.name.local == name).toList();
  static String? _single(XmlElement e, String name) {
    final found = _children(e, name);
    return found.length == 1 ? found.single.innerText.trim() : null;
  }

  /// Query only the user-specified address; no multicast or network scan.
  static Future<Uri> discover(
    InternetAddress target,
    InternetAddress local, {
    Duration timeout = const Duration(seconds: 3),
    int port = 1900,
  }) async {
    if (target.type != InternetAddressType.IPv4 ||
        local.type != InternetAddressType.IPv4 ||
        timeout <= Duration.zero) {
      throw DlnaFailure('无效的局域网地址');
    }
    final socket = await RawDatagramSocket.bind(local, 0);
    final found = Completer<Uri>();
    late final StreamSubscription<RawSocketEvent> subscription;
    subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read || found.isCompleted) return;
        final datagram = socket.receive();
        if (datagram == null ||
            datagram.address.address != target.address ||
            datagram.data.length > 8192) {
          return;
        }
        String response;
        try {
          response = ascii.decode(datagram.data);
        } catch (_) {
          return;
        }
        final lines = response.split(RegExp(r'\r?\n'));
        if (lines.isEmpty ||
            !RegExp(r'^HTTP/1\.[01] 200(?: |$)').hasMatch(lines.first)) {
          return;
        }
        final locations = <String>[];
        for (final line in lines.skip(1)) {
          final at = line.indexOf(':');
          if (at > 0 &&
              line.substring(0, at).trim().toLowerCase() == 'location') {
            locations.add(line.substring(at + 1).trim());
          }
        }
        if (locations.length != 1) return;
        try {
          final uri = Uri.parse(locations.single);
          _samePeer(uri, target, allowLoopback: target.isLoopback);
          found.complete(uri);
        } catch (_) {}
      },
      onError: (Object e) {
        if (!found.isCompleted) found.completeError(DlnaFailure('设备发现失败'));
      },
    );
    final request =
        'M-SEARCH * HTTP/1.1\r\nHOST: ${target.address}:$port\r\nMAN: "ssdp:discover"\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSER-AGENT: iOS/1 UPnP/1.1 Orvex/1\r\n\r\n';
    try {
      if (socket.send(ascii.encode(request), target, port) == 0) {
        throw DlnaFailure('无法发送设备查询');
      }
      return await found.future.timeout(timeout);
    } on TimeoutException {
      throw DlnaFailure('未找到设备，请确认地址及设备投屏功能');
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }

  static Future<DlnaDevice> inspect(
    Uri description, {
    bool allowLoopback = false,
    Duration timeout = const Duration(seconds: 3),
    InternetAddress? sourceAddress,
  }) async {
    final peer = _address(description, allowLoopback: allowLoopback);
    final data = await _request(
      description,
      method: 'GET',
      timeout: timeout,
      sourceAddress: sourceAddress,
    );
    final doc = _xml(data);
    final root = doc.rootElement;
    if (root.name.local != 'root') throw DlnaFailure('无效的设备描述');
    final bases = _children(root, 'URLBase');
    if (bases.length > 1) throw DlnaFailure('无效的设备地址');
    Uri base = description;
    if (bases.isNotEmpty) {
      base = Uri.parse(bases.single.innerText.trim());
      _samePeer(base, peer, allowLoopback: allowLoopback);
    }
    final devices = root.descendants
        .whereType<XmlElement>()
        .where(
          (e) =>
              e.name.local == 'device' &&
              RegExp(r'^urn:schemas-upnp-org:device:MediaRenderer:\d+$')
                  .hasMatch(_single(e, 'deviceType') ?? ''),
        )
        .toList();
    final candidates = <(String, String)>[];
    for (final d in devices) {
      for (final list in _children(d, 'serviceList')) {
        for (final service in _children(list, 'service')) {
          final type = _single(service, 'serviceType'),
              path = _single(service, 'controlURL');
          if (type != null &&
              path != null &&
              path.isNotEmpty &&
              RegExp(r'^urn:schemas-upnp-org:service:AVTransport:\d+$')
                  .hasMatch(type)) {
            candidates.add((type, path));
          }
        }
      }
    }
    if (candidates.length != 1) throw DlnaFailure('未找到唯一 AVTransport 服务');
    Uri endpoint;
    try {
      endpoint = base.resolve(candidates.single.$2);
    } catch (_) {
      throw DlnaFailure('无效的控制地址');
    }
    _samePeer(endpoint, peer, allowLoopback: allowLoopback);
    return DlnaDevice._(peer, endpoint, candidates.single.$1, sourceAddress);
  }

  static String mediaMetadata(Uri uri, String title, String mime) {
    final escapedTitle = XmlText(title).toXmlString();
    final escapedUri = XmlText(uri.toString()).toXmlString();
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="1" parentID="0" restricted="1"><dc:title>$escapedTitle</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:$mime:*">$escapedUri</res></item></DIDL-Lite>';
  }

  Future<Map<String, String>> command(
    String action,
    Map<String, String> args, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!const {
      'SetAVTransportURI',
      'Play',
      'Pause',
      'Stop',
      'Seek',
      'GetTransportInfo',
      'GetPositionInfo',
    }.contains(action)) {
      throw DlnaFailure('不支持的设备命令');
    }
    if (args.keys.any((x) => !RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(x))) {
      throw DlnaFailure('无效的参数名');
    }
    final b = XmlBuilder();
    b.element(
      's:Envelope',
      namespaceUris: {'s': 'http://schemas.xmlsoap.org/soap/envelope/'},
      nest: () {
        b.element(
          's:Body',
          nest: () {
            b.element(
              'u:$action',
              namespaceUris: {'u': service},
              nest: () {
                for (final e in args.entries) {
                  b.element(e.key, nest: e.value);
                }
              },
            );
          },
        );
      },
    );
    final data = await _request(
      control,
      method: 'POST',
      timeout: timeout,
      sourceAddress: sourceAddress,
      body: b.buildDocument().toXmlString(),
      headers: {
        'Content-Type': 'text/xml; charset="utf-8"',
        'SOAPAction': '"$service#$action"',
      },
    );
    final doc = _xml(data);
    final root = doc.rootElement;
    if (root.name.local != 'Envelope' ||
        root.name.namespaceUri != 'http://schemas.xmlsoap.org/soap/envelope/') {
      throw DlnaFailure('无效的 SOAP 响应');
    }
    final bodies = _children(root, 'Body');
    if (bodies.length != 1) throw DlnaFailure('无效的 SOAP 响应');
    final matches = _children(bodies.single, '${action}Response');
    if (matches.length != 1 || matches.single.name.namespaceUri != service) {
      throw DlnaFailure('SOAP 响应与命令不符');
    }
    final values = <String, String>{};
    for (final item in matches.single.childElements) {
      if (values.containsKey(item.name.local)) throw DlnaFailure('SOAP 响应字段重复');
      values[item.name.local] = item.innerText.trim();
    }
    return values;
  }

  static Future<String> _request(
    Uri uri, {
    required String method,
    required Duration timeout,
    String? body,
    InternetAddress? sourceAddress,
    Map<String, String> headers = const {},
  }) async {
    if (timeout <= Duration.zero) throw DlnaFailure('无效超时');
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = timeout;
    if (sourceAddress != null) {
      client.connectionFactory = (uri, _, _) =>
          Socket.startConnect(uri.host, uri.port, sourceAddress: sourceAddress);
    }
    try {
      return await (() async {
        final request = await client.openUrl(method, uri);
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        if (body != null) request.write(body);
        final response = await request.close();
        if (response.isRedirect ||
            response.statusCode < 200 ||
            response.statusCode >= 300) {
          throw DlnaFailure('设备请求失败（HTTP ${response.statusCode}）');
        }
        if (response.contentLength > 256 * 1024) throw DlnaFailure('设备响应过大');
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 256 * 1024) {
            throw DlnaFailure('设备响应过大');
          }
          bytes.addAll(chunk);
        }
        return utf8.decode(bytes);
      })().timeout(timeout);
    } on TimeoutException {
      throw DlnaFailure('设备请求超时');
    } on DlnaFailure {
      rethrow;
    } catch (_) {
      throw DlnaFailure('无法连接或解析投屏设备');
    } finally {
      client.close(force: true);
    }
  }
}
