import 'dart:async';

import 'package:flutter_test/flutter_test.dart' as ft;

import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'package:orvex/features/player/infrastructure/dlna/dlna_client.dart';
import 'package:orvex/features/player/infrastructure/dlna/media_server.dart';

void expect(bool x, String m) {
  if (!x) throw StateError(m);
}

Future<void> rejects(Future<Object?> Function() f, String message) async {
  try {
    await f();
  } on DlnaFailure {
    return;
  }
  throw StateError('not rejected: $message');
}

void main() {
  ft.test(
    'container signatures drive MIME and escaped DIDL metadata',
    () async {
      final dir = await Directory.systemTemp.createTemp('orvex-dlna-mime-');
      try {
        final file = File('${dir.path}/wrong-name.mkv');
        await file.writeAsBytes([
          0,
          0,
          0,
          24,
          0x66,
          0x74,
          0x79,
          0x70,
          0x69,
          0x73,
          0x6f,
          0x6d,
        ]);
        final loop = InternetAddress.loopbackIPv4;
        final lease = await LeasedMediaServer.start(
          file: file,
          bind: loop,
          peer: loop,
        );
        expect(lease.mimeType == 'video/mp4', 'container signature');
        final client = HttpClient()..findProxy = ((_) => 'DIRECT');
        final req = await client.headUrl(lease.uri);
        final res = await req.close();
        expect(
          res.headers.contentType?.mimeType == 'video/mp4',
          'response MIME',
        );
        await res.drain<void>();
        client.close(force: true);
        final metadata = DlnaDevice.mediaMetadata(
          lease.uri,
          'A < B & C',
          lease.mimeType,
        );
        final document = XmlDocument.parse(metadata);
        final title = document.descendants.whereType<XmlElement>().singleWhere(
          (e) => e.name.local == 'title',
        );
        expect(title.innerText == 'A < B & C', 'title escaped');
        expect(
          metadata.contains('http-get:*:video/mp4:*'),
          'DIDL protocol metadata',
        );
        await lease.close();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  ft.test('unicast query accepts only same-host description response', () async {
    final loop = InternetAddress.loopbackIPv4;
    final udp = await RawDatagramSocket.bind(loop, 0);
    var wrong = false;
    final sub = udp.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = udp.receive();
      if (datagram == null) return;
      final request = ascii.decode(datagram.data);
      expect(
        request.contains('M-SEARCH * HTTP/1.1') &&
            request.contains('USER-AGENT:'),
        'request format',
      );
      final host = wrong ? '127.0.0.2' : '127.0.0.1';
      final response =
          'HTTP/1.1 200 OK\r\nLOCATION: http://$host:12345/device.xml\r\n\r\n';
      udp.send(ascii.encode(response), datagram.address, datagram.port);
    });
    try {
      final uri = await DlnaDevice.discover(loop, loop, port: udp.port);
      expect(uri.host == '127.0.0.1', 'matching target');
      wrong = true;
      await rejects(
        () => DlnaDevice.discover(
          loop,
          loop,
          port: udp.port,
          timeout: const Duration(milliseconds: 50),
        ),
        'wrong host in discovery',
      );
    } finally {
      await sub.cancel();
      udp.close();
    }
  });
  ft.test('controlled device SOAP and source lifecycle', () async {
    final dir = await Directory.systemTemp.createTemp('orvex-dlna-');
    final renderer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = <String>[];
    var state = 'STOPPED', mode = 'normal';
    Uri? media;
    final sub = renderer.listen((req) async {
      final res = req.response;
      try {
        if (req.method == 'GET') {
          if (mode == 'redirect') {
            res.statusCode = 302;
            res.headers.set('Location', 'http://127.0.0.2/steal');
          } else if (mode == 'slow') {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          } else if (mode == 'oversized') {
            res.write('X' * (256 * 1024 + 1));
          } else if (mode == 'malformed') {
            res.write('<bad>');
          } else if (mode == 'doctype') {
            res.write(
              '<!DOCTYPE root [<!ENTITY x SYSTEM "file:///etc/passwd">]><root>&x;</root>',
            );
          } else {
            final target = mode == 'cross'
                ? 'http://127.0.0.2/evil'
                : '/control';
            final base = mode == 'crossbase'
                ? '<URLBase>http://127.0.0.2/</URLBase>'
                : '';
            final type = mode == 'wrongtype' ? 'NotRenderer' : 'MediaRenderer';
            res.write(
              '<root>$base<device><deviceType>urn:schemas-upnp-org:device:$type:1</deviceType><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>$target</controlURL></service></serviceList></device></root>',
            );
          }
        } else if (req.method == 'POST') {
          if (mode == 'redirect') {
            res.statusCode = 307;
            res.headers.set('Location', 'http://127.0.0.2/steal');
          } else if (mode == 'slow') {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          } else if (mode == 'soapfault') {
            res.statusCode = 500;
            res.write('<Fault/>');
          } else {
            final action = (req.headers.value('soapaction') ?? '')
                .split('#')
                .last
                .replaceAll('"', '');
            received.add(action);
            final doc = XmlDocument.parse(await utf8.decoder.bind(req).join());
            if (action == 'SetAVTransportURI') {
              final value = doc.descendants
                  .whereType<XmlElement>()
                  .singleWhere((e) => e.name.local == 'CurrentURI')
                  .innerText;
              media = Uri.parse(value);
              final c = HttpClient()..findProxy = ((_) => 'DIRECT');
              final get = await c.getUrl(media!);
              get.headers.set('Range', 'bytes=1-3');
              final result = await get.close();
              expect(
                result.statusCode == 206 &&
                    (await utf8.decoder.bind(result).join()) == '123',
                'renderer file read',
              );
              c.close(force: true);
            }
            if (action == 'Play') state = 'PLAYING';
            if (action == 'Pause') state = 'PAUSED_PLAYBACK';
            if (action == 'Stop') state = 'STOPPED';
            final fields = action == 'GetPositionInfo'
                ? '<RelTime>00:00:12</RelTime><TrackDuration>00:10:00</TrackDuration>'
                : action == 'GetTransportInfo'
                ? '<CurrentTransportState>$state</CurrentTransportState>'
                : '';
            if (mode == 'wrongresponse') {
              res.write(
                '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:BadResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/></s:Body></s:Envelope>',
              );
            } else {
              res.write(
                '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:${action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">$fields</u:${action}Response></s:Body></s:Envelope>',
              );
            }
          }
        }
        await res.close();
      } catch (_) {
        try {
          await res.close();
        } catch (_) {}
      }
    });
    try {
      final loop = InternetAddress.loopbackIPv4;
      final url = Uri.parse(
        'http://127.0.0.1:${renderer.port}/description.xml',
      );
      final file = File('${dir.path}/fixture')..writeAsStringSync('0123456789');
      final lease = await LeasedMediaServer.start(
        file: file,
        bind: loop,
        peer: loop,
        ttl: const Duration(seconds: 10),
      );
      final dev = await DlnaDevice.inspect(
        url,
        allowLoopback: true,
        sourceAddress: loop,
      );
      await dev.command('SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': lease.uri.toString(),
        'CurrentURIMetaData': '',
      });
      await dev.command('Play', {'InstanceID': '0', 'Speed': '1'});
      expect(
        (await dev.command('GetTransportInfo', {
              'InstanceID': '0',
            }))['CurrentTransportState'] ==
            'PLAYING',
        'play state',
      );
      expect(
        (await dev.command('GetPositionInfo', {
              'InstanceID': '0',
            }))['RelTime'] ==
            '00:00:12',
        'position',
      );
      await dev.command('Pause', {'InstanceID': '0'});
      expect(state == 'PAUSED_PLAYBACK', 'pause');
      await dev.command('Stop', {'InstanceID': '0'});
      expect(state == 'STOPPED', 'stop');
      await lease.close();
      for (final bad in [
        'cross',
        'crossbase',
        'wrongtype',
        'redirect',
        'oversized',
        'malformed',
        'doctype',
      ]) {
        mode = bad;
        await rejects(() => DlnaDevice.inspect(url, allowLoopback: true), bad);
      }
      mode = 'slow';
      await rejects(
        () => DlnaDevice.inspect(
          url,
          allowLoopback: true,
          timeout: const Duration(milliseconds: 50),
        ),
        'timeout',
      );
      mode = 'redirect';
      await rejects(
        () => dev.command('Play', {'InstanceID': '0'}),
        'command redirect',
      );
      mode = 'soapfault';
      await rejects(() => dev.command('Stop', {'InstanceID': '0'}), 'fault');
      mode = 'wrongresponse';
      await rejects(
        () => dev.command('GetPositionInfo', {'InstanceID': '0'}),
        'wrong SOAP action',
      );
      mode = 'slow';
      await rejects(
        () => dev.command('Stop', {
          'InstanceID': '0',
        }, timeout: const Duration(milliseconds: 50)),
        'stop timeout',
      );
      await rejects(
        () =>
            DlnaDevice.inspect(Uri.parse('http://localhost:${renderer.port}/')),
        'DNS',
      );
    } finally {
      await sub.cancel();
      await renderer.close(force: true);
      await dir.delete(recursive: true);
    }
  });
}
