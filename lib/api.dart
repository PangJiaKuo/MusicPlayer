import 'dart:convert';
import 'package:http/http.dart' as http;

/// 一首歌（来自 yinyueku api.php 搜索/榜单结果）
class Song {
  final String id;
  final String name;
  final String artist;
  final String album;
  final String source;
  final String sign; // 播放地址签名，必带
  final String urlId;

  const Song({
    required this.id,
    required this.name,
    required this.artist,
    required this.album,
    required this.source,
    required this.sign,
    required this.urlId,
  });

  factory Song.fromJson(Map<String, dynamic> j) {
    String joinArtist(dynamic a) {
      if (a is List) {
        return a.map((e) => e.toString()).join(' / ');
      }
      if (a != null) return a.toString();
      return '未知歌手';
    }

    return Song(
      id: j['id']?.toString() ?? '',
      name: (j['name'] ?? '未知歌曲').toString(),
      artist: joinArtist(j['artist']),
      album: (j['album'] ?? '').toString(),
      source: (j['source'] ?? '').toString(),
      sign: (j['sign'] ?? '').toString(),
      urlId: (j['url_id'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'artist': artist,
        'album': album,
        'source': source,
        'sign': sign,
        'url_id': urlId,
      };

  /// 用于收藏/去重的稳定标识
  String get key => '$source-$id';
}

/// yinyueku 音乐接口封装
class MusicApi {
  MusicApi._();

  static const _base = 'http://www.yinyueku.cn/api.php';

  /// 搜索歌曲
  static Future<List<Song>> search(String keyword) async {
    final uri = Uri.parse(
        '$_base?types=search&count=30&pages=1&name=${Uri.encodeQueryComponent(keyword)}');
    return _parseList(await _get(uri));
  }

  /// 热门推荐（网易云官方飙升榜）
  static Future<List<Song>> hot() async {
    final uri = Uri.parse('$_base?types=playlist&id=19723756&source=netease');
    return _parseList(await _get(uri));
  }

  /// 获取可播放的真实音频地址；失败返回 null
  static Future<String?> playUrl(Song song) async {
    if (song.sign.isEmpty || song.id.isEmpty) return null;
    final uri = Uri.parse(
        '$_base?types=url&id=${song.id}&source=${Uri.encodeQueryComponent(song.source)}&sign=${Uri.encodeQueryComponent(song.sign)}');
    final body = await _get(uri);
    final d = jsonDecode(body);
    if (d is Map) {
      final u = d['url'];
      if (u is String && u.isNotEmpty) return u;
    }
    return null;
  }

  static Future<String> _get(Uri uri) async {
    final resp =
        await http.get(uri).timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) {
      throw Exception('请求失败(${resp.statusCode})');
    }
    return resp.body;
  }

  static List<Song> _parseList(String body) {
    final data = jsonDecode(body);
    if (data is! List) return [];
    final out = <Song>[];
    for (final e in data) {
      if (e is Map) {
        try {
          out.add(Song.fromJson(Map<String, dynamic>.from(e)));
        } catch (_) {}
      }
    }
    return out;
  }
}
