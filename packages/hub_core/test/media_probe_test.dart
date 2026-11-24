import 'dart:convert';

import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_tools.dart';

CapabilityVerdict check(ProbeInfo i, [Map<String, Object?> caps = tvCaps]) =>
    checkCapabilities(
      codec: i.codec,
      profile: i.profile,
      hdr: i.hdr,
      audioCodec: i.audioCodec,
      capabilities: caps,
      width: i.width,
      height: i.height,
    );

Map<String, Object?> capsWith(List<String> decoders, [List<String>? hdr]) => {
  'decoders': decoders,
  'hdr': hdr ?? ['HDR10'],
  'panel': '3840x2160',
};

void main() {
  group('parse fixtures', () {
    test('rotate tag swaps the size', () {
      final i = parseFfprobe(
        ffprobeJson(width: 1920, height: 1080, tags: {'rotate': '90'}),
      );
      expect((i.width, i.height), (1080, 1920));
    });

    test('dvh1 tag without side data is Dolby Vision', () {
      expect(parseFfprobe(ffprobeJson(tag: 'dvh1')).hdr, 'DolbyVision');
    });

    test('DTS audio', () {
      final i = parseFfprobe(ffprobeJson(audio: 'dts'));
      expect(i.audioCodec, 'dts');
      expect(check(i).reason, contains('DTS sound is not supported'));
    });

    test('HEVC with no profile: derived from the pixel format', () {
      expect(
        parseFfprobe(ffprobeJson(profile: null, pixFmt: 'yuv420p10le')).profile,
        'Main 10',
      );
      expect(
        parseFfprobe(ffprobeJson(profile: null, pixFmt: 'yuv444p12le')).profile,
        'Rext',
      );
      expect(parseFfprobe(ffprobeJson(profile: null)).profile, isNull);
    });

    test('a missing or empty codec name is an unknown codec', () {
      for (final name in [null, '', '  ']) {
        final j = jsonEncode({
          'streams': [
            {
              'codec_type': 'video',
              'codec_name': ?name,
              'width': 10,
              'height': 10,
            },
          ],
          'format': {'duration': '1'},
        });
        expect(
          () => parseFfprobe(j),
          throwsA(
            isA<ProbeException>().having(
              (e) => e.reason,
              'reason',
              'Unknown video codec',
            ),
          ),
        );
      }
    });

    test('anamorphic video is stored at its displayed size', () {
      final i = parseFfprobe(
        ffprobeJson(width: 1440, height: 1080, sar: '4:3'),
      );
      expect((i.width, i.height), (1920, 1080));
      final sq = parseFfprobe(
        ffprobeJson(width: 1440, height: 1080, sar: '1:1'),
      );
      expect(sq.width, 1440);
    });

    test('Dolby Vision with an HDR10 base layer', () {
      final i = parseFfprobe(
        ffprobeJson(
          transfer: 'smpte2084',
          sideData: [
            {
              'side_data_type': 'DOVI configuration record',
              'dv_profile': 8,
              'dv_bl_signal_compatibility_id': 1,
            },
          ],
        ),
      );
      expect(i.hdr, 'DolbyVision/HDR10');
      // Profile 5 has no compatible base layer.
      final p5 = parseFfprobe(
        ffprobeJson(
          transfer: 'smpte2084',
          sideData: [
            {
              'side_data_type': 'DOVI configuration record',
              'dv_profile': 5,
              'dv_bl_signal_compatibility_id': 0,
            },
          ],
        ),
      );
      expect(p5.hdr, 'DolbyVision');
    });
  });

  group('capability rules', () {
    test(
      'Dolby Vision with an HDR10 base plays where only HDR10 is listed',
      () {
        final dv = parseFfprobe(
          ffprobeJson(
            transfer: 'smpte2084',
            sideData: [
              {
                'side_data_type': 'DOVI configuration record',
                'dv_profile': 8,
                'dv_bl_signal_compatibility_id': 1,
              },
            ],
          ),
        );
        expect(check(dv).supported, isTrue); // tvCaps: HDR10, no Dolby Vision
        expect(check(dv, {...tvCaps, 'hdr': <String>[]}).supported, isFalse);
        final pure = parseFfprobe(ffprobeJson(tag: 'dvh1'));
        expect(check(pure).reason, contains('Dolby Vision is not supported'));
      },
    );

    test('H.264 High 10 and 4:2:2 need a listing; plain H.264 does not', () {
      final plain = parseFfprobe(ffprobeJson(codec: 'h264', profile: 'High'));
      expect(check(plain).supported, isTrue);
      final high10 = parseFfprobe(
        ffprobeJson(codec: 'h264', profile: 'High 10'),
      );
      expect(check(high10).reason, contains('H.264 High 10'));
      final y422 = parseFfprobe(
        ffprobeJson(codec: 'h264', profile: 'High 4:2:2'),
      );
      expect(check(y422).supported, isFalse);
      final listed = capsWith([
        'x video/avc profiles=[High,High10,High422] max=3840x2160',
      ]);
      expect(check(high10, listed).supported, isTrue);
      expect(check(y422, listed).supported, isTrue);
    });

    test('HEVC Rext, 4:4:4 and 12-bit are unsupported unless listed', () {
      final rext = parseFfprobe(ffprobeJson(profile: 'Main 4:4:4 12'));
      expect(check(rext).reason, contains('HEVC'));
      expect(check(rext).supported, isFalse);
      final listed = capsWith([
        'x video/hevc profiles=[Main,Main10,Main444_12] max=3840x2160',
      ]);
      expect(check(rext, listed).supported, isTrue);
    });

    test('10-bit HEVC needs a Main10 listing; no profile list passes', () {
      final main10 = parseFfprobe(ffprobeJson());
      expect(
        check(
          main10,
          capsWith(['x video/hevc profiles=[Main] max=3840x2160']),
        ).reason,
        contains('Main10'),
      );
      expect(
        check(main10, capsWith(['x video/hevc hw=true'])).supported,
        isTrue,
      );
    });

    test('video larger than the decoder or panel is unsupported', () {
      final k8 = parseFfprobe(ffprobeJson(width: 7680, height: 4320));
      final v = check(k8);
      expect(v.supported, isFalse);
      expect(v.reason, contains('8K'));
      // Without a decoder max the panel size decides.
      final noMax = capsWith(['x video/hevc profiles=[Main,Main10]']);
      expect(check(k8, noMax).supported, isFalse);
      final k4 = parseFfprobe(ffprobeJson());
      expect(check(k4, noMax).supported, isTrue);
      // Portrait phone video fits by edges, not by orientation.
      final portrait = parseFfprobe(ffprobeJson(width: 2160, height: 3840));
      expect(check(portrait).supported, isTrue);
    });

    test('more decoder patterns and the video/<name> fallback', () {
      for (final (codec, line) in [
        ('mpeg2video', 'x video/mpeg2 hw=true'),
        ('vc1', 'x video/vc1'),
        ('h263', 'x video/3gpp h263'),
        ('prores', 'x video/prores'),
        ('mjpeg', 'x video/mjpeg'),
        ('theora', 'x video/theora'),
      ]) {
        final i = parseFfprobe(ffprobeJson(codec: codec, profile: null));
        expect(check(i, capsWith([line])).supported, isTrue, reason: codec);
        expect(
          check(i, capsWith(['x video/hevc'])).supported,
          isFalse,
          reason: codec,
        );
      }
    });
  });

  group('server config from the environment', () {
    ServerConfig from(Map<String, String> env) =>
        ServerConfig.fromEnvironment({'HOME': '/h', ...env});

    test('defaults', () {
      final c = from({});
      expect(c.streamCeilingMbps, 80);
      expect(c.tvCacheBytes, 2500000000);
    });

    test('valid values', () {
      final c = from({
        'TVSAVER_STREAM_CEILING_MBPS': '120',
        'TVSAVER_TV_CACHE_BYTES': '5000000000',
      });
      expect(c.streamCeilingMbps, 120);
      expect(c.tvCacheBytes, 5000000000);
    });

    test('zero, negative and garbage fall back to the defaults', () {
      for (final v in ['0', '-5', 'abc', '', '1.5']) {
        final c = from({
          'TVSAVER_STREAM_CEILING_MBPS': v,
          'TVSAVER_TV_CACHE_BYTES': v,
        });
        expect(c.streamCeilingMbps, 80, reason: v);
        expect(c.tvCacheBytes, 2500000000, reason: v);
      }
    });
  });
}
