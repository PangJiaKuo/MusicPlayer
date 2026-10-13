import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

// ===================== LRC 歌词解析 =====================
class LrcLine {
  final Duration time;
  final String text;
  const LrcLine(this.time, this.text);
}

List<LrcLine> parseLrc(String raw) {
  final out = <LrcLine>[];
  final reg = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');
  for (var line in raw.split('\n')) {
    final matches = reg.allMatches(line);
    if (matches.isEmpty) continue;
    final text = line.replaceAll(reg, '').trim();
    for (final m in matches) {
      final min = int.parse(m.group(1)!);
      final sec = double.parse(m.group(2)!);
      out.add(LrcLine(
          Duration(milliseconds: (min * 60000 + sec * 1000).round()), text));
    }
  }
  out.sort((a, b) => a.time.compareTo(b.time));
  return out;
}

// ===================== 歌单 =====================
class Playlist {
  String name;
  final List<Song> songs;
  Playlist(this.name, this.songs);

  Map<String, dynamic> toJson() =>
      {'name': name, 'songs': songs.map((e) => e.toJson()).toList()};

  static Playlist fromJson(Map<String, dynamic> j) => Playlist(
        (j['name'] ?? '未命名').toString(),
        ((j['songs'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => Song.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

enum PlayMode { sequence, repeatOne, shuffle, once }

// ===================== 全局状态（收藏/歌单/播放队列） =====================
class AppState extends ChangeNotifier {
  AppState._() {
    _init();
  }

  static final AppState i = AppState._();

  final AudioPlayer player = AudioPlayer();
  List<Song> queue = [];
  int index = -1;
  List<Song> favorites = [];
  List<Playlist> playlists = [];

  // 歌词状态
  List<LrcLine> lyrics = [];
  String lyricsSongKey = '';
  bool lyricsLoading = false;

  bool get hasCurrent => index >= 0 && index < queue.length;
  Song? get current => hasCurrent ? queue[index] : null;
  bool get isPlaying => player.playing;
  Duration? get position => player.position;
  Duration? get duration => player.duration;

  Future<void> _init() async {
    player.processingStateStream.listen((st) {
      if (st == ProcessingState.completed) _onCompleted();
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final fav = prefs.getString('favorites');
      if (fav != null) {
        final l = jsonDecode(fav);
        if (l is List) {
          favorites = l
              .whereType<Map>()
              .map((e) => Song.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      }
      final pl = prefs.getString('playlists');
      if (pl != null) {
        final l = jsonDecode(pl);
        if (l is List) {
          playlists = l
              .whereType<Map>()
              .map((e) => Playlist.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'favorites', jsonEncode(favorites.map((e) => e.toJson()).toList()));
      await prefs.setString('playlists',
          jsonEncode(playlists.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  // ---- 收藏 ----
  bool isFavorite(Song s) => favorites.any((f) => f.key == s.key);

  Future<void> toggleFavorite(Song s) async {
    if (isFavorite(s)) {
      favorites.removeWhere((f) => f.key == s.key);
    } else {
      favorites.insert(0, s);
    }
    await _save();
    notifyListeners();
  }

  // ---- 播放 ----
  Future<void> playSongs(List<Song> list, int start) async {
    queue = List.of(list);
    await _playAt(start);
  }

  int _loadToken = 0;

  Future<void> _playAt(int i) async {
    if (i < 0 || i >= queue.length) {
      index = -1;
      notifyListeners();
      return;
    }
    final myToken = ++_loadToken;
    index = i;
    notifyListeners();
    final s = queue[i];
    loadLyric(s);
    try {
      final url = await MusicApi.playUrl(s);
      if (myToken != _loadToken) return; // 已有更新的切歌请求，丢弃本次结果
      if (url == null) throw Exception('获取播放地址失败');
      await player.setAudioSource(AudioSource.uri(Uri.parse(url), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
      }));
      if (myToken != _loadToken) return;
      player.play();
    } catch (e) {
      if (myToken != _loadToken) return;
      // 单曲失败自动尝试下一首（仅当仍是最新请求时）
      await Future.delayed(const Duration(milliseconds: 300));
      if (myToken != _loadToken) return;
      if (i < queue.length - 1) {
        await _playAt(i + 1);
      } else {
        index = -1;
        notifyListeners();
      }
    }
  }

  Future<void> playPause() async {
    if (!hasCurrent) return;
    if (player.playing) {
      await player.pause();
    } else {
      await player.play();
    }
    notifyListeners();
  }

  PlayMode _mode = PlayMode.sequence;
  PlayMode get mode => _mode;
  String get modeLabel => switch (_mode) {
        PlayMode.sequence => '列表循环',
        PlayMode.repeatOne => '单曲循环',
        PlayMode.shuffle => '随机播放',
        PlayMode.once => '播放一遍',
      };
  IconData get modeIcon => switch (_mode) {
        PlayMode.sequence => Icons.repeat,
        PlayMode.repeatOne => Icons.repeat_one_on,
        PlayMode.shuffle => Icons.shuffle,
        PlayMode.once => Icons.playlist_play,
      };

  void cycleMode() {
    _mode = switch (_mode) {
      PlayMode.sequence => PlayMode.repeatOne,
      PlayMode.repeatOne => PlayMode.shuffle,
      PlayMode.shuffle => PlayMode.once,
      PlayMode.once => PlayMode.sequence,
    };
    notifyListeners();
  }

  int _randomIndex() {
    if (queue.length <= 1) return index;
    var r = DateTime.now().millisecond % queue.length;
    if (r == index) r = (r + 1) % queue.length;
    return r;
  }

  Future<void> next() async {
    if (queue.isEmpty) return;
    if (_mode == PlayMode.shuffle) {
      await _playAt(_randomIndex());
      return;
    }
    if (index < queue.length - 1) {
      await _playAt(index + 1);
    } else if (_mode == PlayMode.sequence) {
      await _playAt(0);
    }
  }

  Future<void> prev() async {
    if (queue.isEmpty) return;
    if (_mode == PlayMode.shuffle) {
      await _playAt(_randomIndex());
      return;
    }
    if (index > 0) {
      await _playAt(index - 1);
    } else {
      await player.seek(Duration.zero);
    }
  }

  Future<void> _onCompleted() async {
    if (!hasCurrent) return;
    switch (_mode) {
      case PlayMode.repeatOne:
        await _playAt(index);
      case PlayMode.shuffle:
        await _playAt(_randomIndex());
      case PlayMode.sequence:
        await _playAt(index < queue.length - 1 ? index + 1 : 0);
      case PlayMode.once:
        if (index < queue.length - 1) await _playAt(index + 1);
    }
  }

  Future<void> seek(Duration d) async => player.seek(d);

  // ---- 歌词 ----
  Future<void> loadLyric(Song s) async {
    lyricsSongKey = s.key;
    lyrics = [];
    lyricsLoading = true;
    notifyListeners();
    try {
      final raw = await MusicApi.lyric(s);
      if (lyricsSongKey != s.key) return; // 已切歌，丢弃旧结果
      if (raw != null) lyrics = parseLrc(raw);
    } catch (_) {}
    lyricsLoading = false;
    notifyListeners();
  }

  // ---- 歌单 ----
  Future<void> createPlaylist(String name) async {
    playlists.add(Playlist(name, []));
    await _save();
    notifyListeners();
  }

  Future<void> addToPlaylist(Playlist pl, Song s) async {
    if (!pl.songs.any((x) => x.key == s.key)) pl.songs.add(s);
    await _save();
    notifyListeners();
  }

  Future<void> removeFromPlaylist(Playlist pl, Song s) async {
    pl.songs.removeWhere((x) => x.key == s.key);
    await _save();
    notifyListeners();
  }

  Future<void> deletePlaylist(Playlist pl) async {
    playlists.remove(pl);
    await _save();
    notifyListeners();
  }

  Future<void> playPlaylist(Playlist pl, int start) async {
    if (pl.songs.isEmpty) return;
    await playSongs(pl.songs, start);
  }
}

// ===================== 应用入口 =====================
void main() => runApp(const MusicApp());

class MusicApp extends StatelessWidget {
  const MusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '音乐播放器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5B6CFF)),
        scaffoldBackgroundColor: const Color(0xFFF5F7FB),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F7FB),
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Color(0xFF1B2A41),
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: Color(0xFFE4EEFF),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B6CFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF12141C),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF12141C),
          elevation: 0,
          centerTitle: true,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF1B1E2E),
          indicatorColor: Color(0xFF2A3355),
        ),
      ),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}

// ===================== 封面（接口无封面可用，用确定性渐变兜底） =====================
class AlbumArt extends StatelessWidget {
  final Song song;
  final double size;
  final double radius;

  const AlbumArt({
    super.key,
    required this.song,
    this.size = 44,
    this.radius = 10,
  });

  static const _palettes = <List<Color>>[
    [Color(0xFF4E8CFF), Color(0xFF7FB2FF)],
    [Color(0xFFFF7A59), Color(0xFFFFB199)],
    [Color(0xFF5BC0A6), Color(0xFF8FE0C6)],
    [Color(0xFF9B7BFF), Color(0xFFC3B0FF)],
    [Color(0xFFFFB84D), Color(0xFFFFD99A)],
    [Color(0xFFF06BB4), Color(0xFFF9A5D6)],
  ];

  @override
  Widget build(BuildContext context) {
    final seed = song.name.codeUnits.fold<int>(0, (a, b) => a + b);
    final palette = _palettes[seed % _palettes.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette,
        ),
        boxShadow: [
          BoxShadow(
            color: palette[0].withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Icon(
        Icons.music_note,
        color: Colors.white.withValues(alpha: 0.92),
        size: size * 0.5,
      ),
    );
  }
}

// ===================== 歌曲条目 =====================
class SongTile extends StatelessWidget {
  final Song song;
  final VoidCallback? onTap;
  final bool showFavorite;
  final Widget? trailing;

  const SongTile({
    super.key,
    required this.song,
    this.onTap,
    this.showFavorite = true,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: AlbumArt(song: song, size: 44),
      title: Text(
        song.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1B2A41)),
      ),
      subtitle: Text(
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
      ),
      onTap: onTap ?? () => AppState.i.playSongs([song], 0),
      trailing: trailing ??
          (showFavorite
              ? ListenableBuilder(
                  listenable: AppState.i,
                  builder: (ctx, _) {
                    final fav = AppState.i.isFavorite(song);
                    return IconButton(
                      tooltip: fav ? '取消收藏' : '收藏',
                      onPressed: () => AppState.i.toggleFavorite(song),
                      icon: Icon(
                        fav ? Icons.favorite : Icons.favorite_border,
                        color: fav ? const Color(0xFFE94B5F) : Colors.grey,
                      ),
                    );
                  },
                )
              : null),
    );
  }
}

// ===================== 发现页（搜索 + 热门推荐） =====================
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  final _ctl = TextEditingController();
  List<Song> _songs = [];
  bool _loading = true;
  String? _error;
  bool _isSearch = false;

  // 输入联想
  final _layerLink = LayerLink();
  List<Song> _suggestions = [];
  bool _showSuggestions = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_onTextChanged);
    _loadHot();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.removeListener(_onTextChanged);
    _ctl.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final kw = _ctl.text.trim();
    _debounce?.cancel();
    if (kw.isEmpty) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }
    setState(() => _showSuggestions = true);
    _debounce = Timer(const Duration(milliseconds: 400), () => _fetchSuggestions(kw));
  }

  Future<void> _fetchSuggestions(String kw) async {
    try {
      final r = await MusicApi.search(kw);
      if (!mounted || !_showSuggestions) return;
      setState(() => _suggestions = r.take(8).toList());
    } catch (_) {}
  }

  void _pickSuggestion(Song s) {
    setState(() {
      _ctl.text = s.name;
      _showSuggestions = false;
    });
    _debounce?.cancel();
    _search(s.name);
  }

  Future<void> _loadHot() async {
    setState(() {
      _loading = true;
      _error = null;
      _isSearch = false;
    });
    try {
      final r = await MusicApi.hot();
      if (!mounted) return;
      setState(() {
        _songs = r;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败，请检查网络';
        _loading = false;
      });
    }
  }

  Future<void> _search(String kw) async {
    if (kw.trim().isEmpty) return _loadHot();
    setState(() {
      _loading = true;
      _error = null;
      _isSearch = true;
    });
    try {
      final r = await MusicApi.search(kw);
      if (!mounted) return;
      setState(() {
        _songs = r;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '搜索失败，请检查网络';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          Container(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF5B6CFF), Color(0xFF8E6CFF)],
              ),
              boxShadow: const [
                BoxShadow(color: Color(0x335B6CFF), blurRadius: 18, offset: Offset(0, 8)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('音乐播放器',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
                SizedBox(height: 4),
                Text('发现好音乐，从这里开始',
                    style: TextStyle(fontSize: 13, color: Color(0xFFE3E7FF))),
              ],
            ),
          ),
          CompositedTransformTarget(
            link: _layerLink,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _ctl,
                textInputAction: TextInputAction.search,
                onSubmitted: (v) {
                  setState(() => _showSuggestions = false);
                  _search(v);
                },
                decoration: InputDecoration(
                  hintText: '搜索歌曲 / 歌手',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          if (!_loading && _error == null && !_isSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.local_fire_department,
                      color: Color(0xFFFF7A59), size: 20),
                  const SizedBox(width: 6),
                  Text(
                    '热门推荐',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: const Color(0xFF1B2A41),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _loadHot,
                              icon: const Icon(Icons.refresh),
                              label: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : _songs.isEmpty
                        ? const Center(child: Text('没有找到相关歌曲'))
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 8),
                            itemCount: _songs.length,
                            itemBuilder: (ctx, i) => SongTile(
                                  song: _songs[i],
                                  onTap: () =>
                                      AppState.i.playSongs(_songs, i),
                                ),
                          ),
          ),
            ],
          ),
          if (_showSuggestions) _buildSuggestions(),
        ],
      ),
    );
  }

  Widget _buildSuggestions() {
    final w = MediaQuery.of(context).size.width - 32;
    return CompositedTransformFollower(
      link: _layerLink,
      showWhenUnlinked: false,
      offset: const Offset(0, 50),
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: w,
          constraints: const BoxConstraints(maxHeight: 300),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [
              BoxShadow(color: Color(0x22000000), blurRadius: 16, offset: Offset(0, 6)),
            ],
          ),
          child: _suggestions.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('搜索中…',
                      style: TextStyle(fontSize: 12, color: Color(0xFF9AA7BD))),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: _suggestions.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final sg = _suggestions[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.search,
                          size: 18, color: Color(0xFF9AA7BD)),
                      title: Text(sg.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(sg.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11)),
                      onTap: () => _pickSuggestion(sg),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

// ===================== 歌单页 =====================
class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage({super.key});

  Future<void> _create(BuildContext context) async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '歌单名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await AppState.i.createPlaylist(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: AppState.i,
        builder: (ctx, _) {
          final pls = AppState.i.playlists;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Text(
                      '我的歌单',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF1B2A41),
                      ),
                    ),
                    const Spacer(),
                    FilledButton.tonalIcon(
                      onPressed: () => _create(context),
                      icon: const Icon(Icons.add),
                      label: const Text('新建'),
                    ),
                  ],
                ),
              ),
              if (pls.isEmpty)
                const Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.queue_music,
                            size: 56, color: Color(0xFFC3CDDC)),
                        SizedBox(height: 12),
                        Text('还没有歌单，点右上角新建一个吧',
                            style: TextStyle(color: Color(0xFF8A98AC))),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: pls.length,
                    itemBuilder: (ctx, i) {
                      final pl = pls[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        elevation: 0,
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: ListTile(
                          leading: AlbumArt(
                            song: pl.songs.isNotEmpty
                                ? pl.songs.first
                                : const Song(
                                    id: '',
                                    name: '歌单',
                                    artist: '',
                                    album: '',
                                    source: '',
                                    sign: '',
                                    urlId: '',
                                  ),
                            size: 46,
                          ),
                          title: Text(
                            pl.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1B2A41)),
                          ),
                          subtitle: Text('${pl.songs.length} 首',
                              style: const TextStyle(fontSize: 12)),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => PlaylistDetailPage(pl: pl)),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ===================== 歌单详情 =====================
class PlaylistDetailPage extends StatelessWidget {
  final Playlist pl;
  const PlaylistDetailPage({super.key, required this.pl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(pl.name),
        actions: [
          IconButton(
            tooltip: '删除歌单',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await AppState.i.deletePlaylist(pl);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: AppState.i,
        builder: (ctx, _) {
          if (pl.songs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('歌单还是空的',
                      style: TextStyle(color: Color(0xFF8A98AC))),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => AddSongsToPlaylistPage(pl: pl)),
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('添加歌曲'),
                  ),
                ],
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => AppState.i.playPlaylist(pl, 0),
                      icon: const Icon(Icons.play_arrow),
                      label: Text('播放全部（${pl.songs.length} 首）'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonalIcon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => AddSongsToPlaylistPage(pl: pl)),
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('添加歌曲'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: pl.songs.length,
                  itemBuilder: (ctx, i) {
                    final s = pl.songs[i];
                    return SongTile(
                      song: s,
                      showFavorite: false,
                      onTap: () => AppState.i.playPlaylist(pl, i),
                      trailing: IconButton(
                        tooltip: '移出歌单',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => AppState.i.removeFromPlaylist(pl, s),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ===================== 往歌单添加歌曲（收藏选择 / 在线搜索） =====================
class AddSongsToPlaylistPage extends StatefulWidget {
  final Playlist pl;
  const AddSongsToPlaylistPage({super.key, required this.pl});

  @override
  State<AddSongsToPlaylistPage> createState() => _AddSongsToPlaylistPageState();
}

class _AddSongsToPlaylistPageState extends State<AddSongsToPlaylistPage> {
  List<Song> _results = [];
  bool _searching = false;
  String _kw = '';

  Future<void> _search(String kw) async {
    _kw = kw.trim();
    if (_kw.isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final r = await MusicApi.search(_kw);
      if (!mounted) return;
      setState(() {
        _results = r;
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _searching = false);
    }
  }

  Widget _addTile(Song s) {
    final inPl = widget.pl.songs.any((x) => x.key == s.key);
    return ListTile(
      leading: AlbumArt(song: s, size: 44),
      title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(s.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12)),
      trailing: inPl
          ? const Icon(Icons.check_circle, color: Color(0xFF5BC0A6))
          : IconButton(
              icon: const Icon(Icons.add_circle_outline,
                  color: Color(0xFF3F7CFF)),
              onPressed: () async {
                await AppState.i.addToPlaylist(widget.pl, s);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已添加「${s.name}」')),
                );
                setState(() {});
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final favs = AppState.i.favorites;
    return Scaffold(
      appBar: AppBar(title: Text('添加到「${widget.pl.name}」')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              decoration: InputDecoration(
                hintText: '搜索歌曲 / 歌手',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(24)),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_kw.isEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
              child: Text('从我的收藏选择',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            if (favs.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('还没有收藏歌曲',
                    style: TextStyle(color: Color(0xFF8A98AC))),
              )
            else
              ...favs.map(_addTile),
          ] else ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
              child: Text('搜索结果',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            if (_results.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('没有找到相关歌曲'),
              )
            else
              ..._results.map(_addTile),
          ],
        ],
      ),
    );
  }
}

// ===================== 我的（收藏） =====================
class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: AppState.i,
        builder: (ctx, _) {
          final fav = AppState.i.favorites;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  '我的收藏',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF1B2A41),
                  ),
                ),
              ),
              if (fav.isEmpty)
                const Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.favorite_border,
                            size: 56, color: Color(0xFFC3CDDC)),
                        SizedBox(height: 12),
                        Text('还没有收藏，点歌曲右侧的爱心收藏',
                            style: TextStyle(color: Color(0xFF8A98AC))),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: fav.length,
                    itemBuilder: (ctx, i) => SongTile(
                          song: fav[i],
                          onTap: () => AppState.i.playSongs(fav, i),
                        ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ===================== 播放页 =====================
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  bool _showLyrics = false;

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('正在播放')),
      body: ListenableBuilder(
        listenable: AppState.i,
        builder: (ctx, _) {
          final s = AppState.i.current;
          if (s == null) {
            return const Center(child: Text('暂无播放'));
          }
          final playing = AppState.i.isPlaying;
          final fav = AppState.i.isFavorite(s);
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? const [Color(0xFF1F2438), Color(0xFF12141C)]
                    : const [Color(0xFFE7EBFF), Color(0xFFF4F6FB)],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
              children: [
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () => setState(() => _showLyrics = !_showLyrics),
                  child: SizedBox(
                    height: 260,
                    child: _showLyrics
                        ? _LyricView(
                            lines: AppState.i.lyrics,
                            loading: AppState.i.lyricsLoading,
                          )
                        : Center(
                            child: AlbumArt(song: s, size: 260, radius: 20)),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _showLyrics ? '点击返回封面' : '点击封面查看歌词',
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFFB3BECE)),
                ),
                const SizedBox(height: 18),
                Text(
                  s.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1B2A41)),
                ),
                const SizedBox(height: 8),
                Text(
                  s.artist,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                ),
                const SizedBox(height: 24),
                _buildProgress(),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '上一首',
                      iconSize: 44,
                      onPressed: () => AppState.i.prev(),
                      icon: const Icon(Icons.skip_previous),
                    ),
                    const SizedBox(width: 24),
                    IconButton(
                      tooltip: playing ? '暂停' : '播放',
                      iconSize: 72,
                      onPressed: () => AppState.i.playPause(),
                      icon: Icon(
                        playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
                        color: const Color(0xFF3F7CFF),
                      ),
                    ),
                    const SizedBox(width: 24),
                    IconButton(
                      tooltip: '下一首',
                      iconSize: 44,
                      onPressed: () => AppState.i.next(),
                      icon: const Icon(Icons.skip_next),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      tooltip: AppState.i.modeLabel,
                      onPressed: () => AppState.i.cycleMode(),
                      icon: Icon(AppState.i.modeIcon,
                          size: 24, color: const Color(0xFF3F7CFF)),
                    ),
                    IconButton(
                      tooltip: '收藏',
                      iconSize: 28,
                      onPressed: () => AppState.i.toggleFavorite(s),
                      icon: Icon(
                        fav ? Icons.favorite : Icons.favorite_border,
                        color: fav ? const Color(0xFFE94B5F) : Colors.grey,
                      ),
                    ),
                    IconButton(
                      tooltip: '加入歌单',
                      iconSize: 28,
                      onPressed: () => _showAddToPlaylist(context, s),
                      icon: const Icon(Icons.playlist_add),
                    ),
                  ],
                ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildProgress() {
    return StreamBuilder<Duration?>(
      stream: AppState.i.player.durationStream,
      builder: (ctx, durSnap) {
        final dur = durSnap.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: AppState.i.player.positionStream,
          builder: (ctx, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
            final val = dur.inMilliseconds > 0
                ? pos.inMilliseconds.clamp(0, dur.inMilliseconds).toDouble()
                : 0.0;
            return Column(
              children: [
                Slider(
                  value: val,
                  max: maxMs,
                  onChanged: dur.inMilliseconds > 0
                      ? (v) => AppState.i.seek(Duration(milliseconds: v.round()))
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(pos),
                          style: const TextStyle(fontSize: 12, color: Color(0xFF8A98AC))),
                      Text(_fmt(dur),
                          style: const TextStyle(fontSize: 12, color: Color(0xFF8A98AC))),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAddToPlaylist(BuildContext context, Song s) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final pls = AppState.i.playlists;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('添加到歌单',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (pls.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Text('还没有歌单'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () async {
                          final nameCtl = TextEditingController();
                          final name = await showDialog<String>(
                            context: ctx,
                            builder: (dctx) => AlertDialog(
                              title: const Text('新建歌单'),
                              content: TextField(
                                controller: nameCtl,
                                autofocus: true,
                                decoration:
                                    const InputDecoration(hintText: '歌单名称'),
                              ),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(dctx),
                                    child: const Text('取消')),
                                FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(dctx, nameCtl.text.trim()),
                                    child: const Text('创建')),
                              ],
                            ),
                          );
                          if (name == null || name.isEmpty) return;
                          await AppState.i.createPlaylist(name);
                          final newPl = AppState.i.playlists.last;
                          await AppState.i.addToPlaylist(newPl, s);
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('已创建并加入「$name」')),
                            );
                          }
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('新建歌单'),
                      ),
                    ],
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: pls
                        .map((pl) => ListTile(
                              title: Text(pl.name),
                              trailing: Text('${pl.songs.length} 首',
                                  style: const TextStyle(fontSize: 12)),
                              onTap: () {
                                AppState.i.addToPlaylist(pl, s);
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('已添加到「${pl.name}」')),
                                );
                              },
                            ))
                        .toList(),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

// ===================== 歌词视图（随播放进度滚动高亮） =====================
class _LyricView extends StatefulWidget {
  final List<LrcLine> lines;
  final bool loading;
  const _LyricView({required this.lines, required this.loading});

  @override
  State<_LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<_LyricView> {
  final _controller = ScrollController();
  int _lastIndex = -1;
  static const double _extent = 44;

  @override
  void didUpdateWidget(_LyricView old) {
    super.didUpdateWidget(old);
    if (old.lines != widget.lines) _lastIndex = -1;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return const Center(
          child: Text('歌词加载中…', style: TextStyle(color: Color(0xFF9AA7BD))));
    }
    if (widget.lines.isEmpty) {
      return const Center(
          child: Text('暂无歌词', style: TextStyle(color: Color(0xFF9AA7BD))));
    }
    return StreamBuilder<Duration>(
      stream: AppState.i.player.positionStream,
      builder: (ctx, snap) {
        final pos = snap.data ?? Duration.zero;
        var idx = 0;
        for (var i = 0; i < widget.lines.length; i++) {
          if (widget.lines[i].time <= pos) {
            idx = i;
          } else {
            break;
          }
        }
        if (idx != _lastIndex) {
          _lastIndex = idx;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_controller.hasClients) {
              final target =
                  (_extent * (idx - 2)).clamp(0.0, _extent * widget.lines.length);
              _controller.animateTo(target,
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOut);
            }
          });
        }
        return ListView.builder(
          controller: _controller,
          itemExtent: _extent,
          padding: const EdgeInsets.symmetric(vertical: 100),
          itemCount: widget.lines.length,
          itemBuilder: (ctx, i) {
            final active = i == idx;
            final text =
                widget.lines[i].text.isEmpty ? '♪' : widget.lines[i].text;
            return Center(
              child: Text(
                text,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: active ? 17 : 13.5,
                  height: 1.3,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                  color: active
                      ? const Color(0xFF3F7CFF)
                      : const Color(0xFF9AA7BD),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ===================== 迷你播放器 =====================
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppState.i,
      builder: (ctx, _) {
        final s = AppState.i.current;
        if (s == null) return const SizedBox.shrink();
        return Material(
          color: Theme.of(context).colorScheme.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          elevation: 8,
          shadowColor: Color(0x33000000),
          child: InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PlayerPage()),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                StreamBuilder<Duration>(
                  stream: AppState.i.player.positionStream,
                  builder: (ctx, posSnap) {
                    final dur = AppState.i.duration;
                    final maxMs =
                        (dur != null && dur.inMilliseconds > 0)
                            ? dur.inMilliseconds.toDouble()
                            : 1.0;
                    final val = (dur != null && dur.inMilliseconds > 0)
                        ? (posSnap.data ?? Duration.zero)
                            .inMilliseconds
                            .clamp(0, dur.inMilliseconds)
                            .toDouble()
                        : 0.0;
                    return LinearProgressIndicator(
                      value: val / maxMs,
                      minHeight: 2,
                      backgroundColor: const Color(0xFFE4E8F0),
                      valueColor:
                          const AlwaysStoppedAnimation(Color(0xFF3F7CFF)),
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                  child: Row(
                    children: [
                      AlbumArt(song: s, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: Color(0xFF1B2A41)),
                            ),
                            Text(
                              s.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => AppState.i.playPause(),
                        icon: Icon(
                          AppState.i.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: const Color(0xFF3F7CFF),
                          size: 38,
                        ),
                      ),
                      IconButton(
                        onPressed: () => AppState.i.next(),
                        icon: const Icon(Icons.skip_next),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ===================== 底部导航外壳 =====================
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = const [DiscoverPage(), PlaylistsPage(), LibraryPage()];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.explore_outlined),
                  selectedIcon: Icon(Icons.explore),
                  label: '发现',
                ),
                NavigationDestination(
                  icon: Icon(Icons.queue_music_outlined),
                  selectedIcon: Icon(Icons.queue_music),
                  label: '歌单',
                ),
                NavigationDestination(
                  icon: Icon(Icons.favorite_outline),
                  selectedIcon: Icon(Icons.favorite),
                  label: '我的',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
