import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

// ───────── models/anime.dart ─────────
class Episode {
  final int number;
  final String title;
  final String videoUrl;
  const Episode(this.number, this.title, this.videoUrl);
}

class Anime {
  final String id, title, synopsis, coverUrl;
  final double rating;
  final List<String> genres;
  final List<Episode> episodes;
  const Anime({
    required this.id,
    required this.title,
    required this.synopsis,
    required this.coverUrl,
    required this.rating,
    required this.genres,
    required this.episodes,
  });
}

/// حلقة تم تنزيلها: نخزّن مسار الملف على الهاتف + بيانات العرض.
class DownloadedEpisode {
  final String animeId, animeTitle, coverUrl, episodeTitle, filePath;
  final int episodeNumber;
  const DownloadedEpisode({
    required this.animeId,
    required this.animeTitle,
    required this.coverUrl,
    required this.episodeNumber,
    required this.episodeTitle,
    required this.filePath,
  });

  Map<String, dynamic> toJson() => {
        'animeId': animeId,
        'animeTitle': animeTitle,
        'coverUrl': coverUrl,
        'episodeNumber': episodeNumber,
        'episodeTitle': episodeTitle,
        'filePath': filePath,
      };

  factory DownloadedEpisode.fromJson(Map<String, dynamic> j) => DownloadedEpisode(
        animeId: j['animeId'],
        animeTitle: j['animeTitle'],
        coverUrl: j['coverUrl'],
        episodeNumber: j['episodeNumber'],
        episodeTitle: j['episodeTitle'],
        filePath: j['filePath'],
      );
}

// ───────── data/mock_data.dart ─────────
const _base = 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/';
const _videos = ['ForBiggerBlazes.mp4', 'ForBiggerEscapes.mp4', 'ForBiggerJoyrides.mp4'];

List<Episode> _eps(int n) => List.generate(
      n,
      (i) => Episode(i + 1, 'الحلقة ${i + 1}', '$_base${_videos[i % _videos.length]}'),
    );

String _cover(String seed) => 'https://picsum.photos/seed/$seed/400/600';

/// بيانات تجريبية — استبدلها لاحقاً بـ API حقيقي.
final List<Anime> animeList = [
  Anime(
    id: 'a1',
    title: 'سيف الفجر',
    synopsis: 'محارب شاب يرث سيفاً قديماً ويكتشف أن الفجر نفسه مهدد بالزوال.',
    coverUrl: _cover('dawn'),
    rating: 9.1,
    genres: ['أكشن', 'فانتازيا'],
    episodes: _eps(6),
  ),
  Anime(
    id: 'a2',
    title: 'رونين النيون',
    synopsis: 'ساموراي سابق يعمل مرتزقاً في مدينة مستقبلية لا تنام.',
    coverUrl: _cover('neon'),
    rating: 8.7,
    genres: ['خيال علمي', 'أكشن'],
    episodes: _eps(5),
  ),
  Anime(
    id: 'a3',
    title: 'أكاديمية ميناء النجوم',
    synopsis: 'طلاب أكاديمية فضائية يتنافسون ويكتشفون سراً خلف أسوارها.',
    coverUrl: _cover('harbor'),
    rating: 8.2,
    genres: ['مدرسي', 'مغامرة'],
    episodes: _eps(4),
  ),
  Anime(
    id: 'a4',
    title: 'راسمة الأرواح',
    synopsis: 'رسامة خرائط تتتبع أرواحاً ضائعة بين عالمين.',
    coverUrl: _cover('spirit'),
    rating: 8.9,
    genres: ['دراما', 'خارق'],
    episodes: _eps(5),
  ),
];

// ───────── services/download_service.dart ─────────
/// الجسر بين الواجهة والتخزين المحلي:
///  - الملفات (mp4) تُحفظ في مجلد التطبيق عبر path_provider.
///  - قائمة التحميلات (المسار + البيانات) تُحفظ في SharedPreferences كـ JSON.
///  - الواجهة تستمع للتغييرات عبر ChangeNotifier.
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final instance = DownloadService._();

  static const _prefsKey = 'downloaded_episodes';
  final _dio = Dio();

  final List<DownloadedEpisode> downloaded = [];
  final Map<String, double> progress = {}; // المفتاح -> نسبة 0..1

  String _key(String animeId, int ep) => '$animeId-$ep';

  /// تُستدعى عند تشغيل التطبيق لاسترجاع التحميلات السابقة.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? [];
    downloaded
      ..clear()
      ..addAll(raw
          .map((s) => DownloadedEpisode.fromJson(jsonDecode(s)))
          .where((d) => File(d.filePath).existsSync())); // تجاهل الملفات المحذوفة
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsKey,
      downloaded.map((d) => jsonEncode(d.toJson())).toList(),
    );
  }

  DownloadedEpisode? find(String animeId, int ep) {
    for (final d in downloaded) {
      if (d.animeId == animeId && d.episodeNumber == ep) return d;
    }
    return null;
  }

  double? progressOf(String animeId, int ep) => progress[_key(animeId, ep)];

  Future<void> download(Anime anime, Episode ep) async {
    final key = _key(anime.id, ep.number);
    if (progress.containsKey(key) || find(anime.id, ep.number) != null) return;

    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/anime/${anime.id}');
    await folder.create(recursive: true);
    final path = '${folder.path}/ep${ep.number}.mp4';

    progress[key] = 0;
    notifyListeners();
    try {
      await _dio.download(
        ep.videoUrl,
        path,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            progress[key] = received / total;
            notifyListeners();
          }
        },
      );
      downloaded.add(DownloadedEpisode(
        animeId: anime.id,
        animeTitle: anime.title,
        coverUrl: anime.coverUrl,
        episodeNumber: ep.number,
        episodeTitle: ep.title,
        filePath: path,
      ));
      await _save();
    } catch (_) {
      final f = File(path);
      if (await f.exists()) await f.delete(); // حذف الملف غير المكتمل
    } finally {
      progress.remove(key);
      notifyListeners();
    }
  }

  Future<void> remove(DownloadedEpisode d) async {
    final f = File(d.filePath);
    if (await f.exists()) await f.delete();
    downloaded.remove(d);
    await _save();
    notifyListeners();
  }
}

// ───────── widgets/anime_card.dart ─────────
Widget coverImage(String url, {BoxFit fit = BoxFit.cover}) => Image.network(
      url,
      fit: fit,
      errorBuilder: (_, __, ___) => Container(
        color: const Color(0xFF241C3F),
        child: const Icon(Icons.image_not_supported_outlined, color: Colors.white24),
      ),
    );

class AnimeCard extends StatelessWidget {
  final Anime anime;
  const AnimeCard({super.key, required this.anime});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
      ),
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(height: 190, width: 140, child: coverImage(anime.coverUrl)),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.65),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.star_rounded, size: 14, color: Color(0xFFFFC857)),
                      const SizedBox(width: 3),
                      Text('${anime.rating}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(anime.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 2),
            Text(anime.synopsis,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white54, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

// ───────── screens/home_screen.dart ─────────
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DownloadService.instance,
      builder: (context, _) {
        final popular = [...animeList]..sort((a, b) => b.rating.compareTo(a.rating));
        final saved = animeList
            .where((a) => DownloadService.instance.downloaded.any((d) => d.animeId == a.id))
            .toList();

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('اكتشف الأنمي',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 20),
              _Section(title: 'الأكثر مشاهدة', items: popular),
              const SizedBox(height: 24),
              if (saved.isNotEmpty)
                _Section(title: 'الأنميات المحفوظة محلياً', items: saved)
              else
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('حمّل حلقة لتظهر هنا وتشاهدها بدون إنترنت.',
                      style: TextStyle(color: Colors.white54)),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Anime> items;
  const _Section({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 270,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (_, i) => AnimeCard(anime: items[i]),
          ),
        ),
      ],
    );
  }
}

// ───────── screens/detail_screen.dart ─────────
class DetailScreen extends StatelessWidget {
  final Anime anime;
  const DetailScreen({super.key, required this.anime});

  void _play(BuildContext context, Episode ep) {
    final local = DownloadService.instance.find(anime.id, ep.number);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          title: '${anime.title} - ${ep.title}',
          source: local?.filePath ?? ep.videoUrl,
          isLocal: local != null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 320,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(fit: StackFit.expand, children: [
                coverImage(anime.coverUrl),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xFF0E0B1A)],
                    ),
                  ),
                ),
              ]),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(anime.title,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.star_rounded, color: Color(0xFFFFC857), size: 18),
                    const SizedBox(width: 4),
                    Text('${anime.rating}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        children: anime.genres
                            .map((g) => Chip(
                                  label: Text(g, style: const TextStyle(fontSize: 11)),
                                  visualDensity: VisualDensity.compact,
                                  backgroundColor: cs.surface,
                                  side: BorderSide.none,
                                ))
                            .toList(),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Text(anime.synopsis,
                      style: const TextStyle(color: Colors.white70, height: 1.6)),
                  const SizedBox(height: 20),
                  const Text('الحلقات',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: ListenableBuilder(
              listenable: DownloadService.instance,
              builder: (context, _) => Column(
                children: anime.episodes.map((ep) {
                  final svc = DownloadService.instance;
                  final done = svc.find(anime.id, ep.number) != null;
                  final p = svc.progressOf(anime.id, ep.number);
                  return ListTile(
                    onTap: () => _play(context, ep),
                    leading: CircleAvatar(
                      backgroundColor: cs.surface,
                      child: Text('${ep.number}'),
                    ),
                    title: Text(ep.title),
                    subtitle: done
                        ? Text('محمّلة', style: TextStyle(color: cs.primary, fontSize: 12))
                        : null,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'تشغيل',
                        icon: const Icon(Icons.play_circle_fill_rounded),
                        color: cs.primary,
                        onPressed: () => _play(context, ep),
                      ),
                      if (p != null)
                        SizedBox(
                          width: 40,
                          height: 40,
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: CircularProgressIndicator(value: p, strokeWidth: 3),
                          ),
                        )
                      else if (done)
                        const SizedBox(
                            width: 40,
                            child: Icon(Icons.download_done_rounded, color: Colors.greenAccent))
                      else
                        IconButton(
                          tooltip: 'تحميل',
                          icon: const Icon(Icons.download_rounded),
                          onPressed: () => svc.download(anime, ep),
                        ),
                    ]),
                  );
                }).toList(),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

// ───────── screens/downloads_screen.dart ─────────
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: DownloadService.instance,
        builder: (context, _) {
          final items = DownloadService.instance.downloaded;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('التحميلات',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
              ),
              Expanded(
                child: items.isEmpty
                    ? const Center(
                        child: Text('لا توجد حلقات محمّلة بعد.\nافتح أنمي واضغط على زر التحميل.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54, height: 1.6)),
                      )
                    : ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final d = items[i];
                          return ListTile(
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                  width: 48, height: 64, child: coverImage(d.coverUrl)),
                            ),
                            title: Text(d.animeTitle),
                            subtitle: Text(d.episodeTitle),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PlayerScreen(
                                  title: '${d.animeTitle} - ${d.episodeTitle}',
                                  source: d.filePath,
                                  isLocal: true, // يعمل بدون إنترنت
                                ),
                              ),
                            ),
                            trailing: IconButton(
                              tooltip: 'حذف',
                              icon: const Icon(Icons.delete_outline_rounded),
                              onPressed: () => DownloadService.instance.remove(d),
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

// ───────── screens/player_screen.dart ─────────
class PlayerScreen extends StatefulWidget {
  final String title, source;
  final bool isLocal;
  const PlayerScreen({
    super.key,
    required this.title,
    required this.source,
    required this.isLocal,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final VideoPlayerController _c;

  @override
  void initState() {
    super.initState();
    _c = widget.isLocal
        ? VideoPlayerController.file(File(widget.source))
        : VideoPlayerController.networkUrl(Uri.parse(widget.source));
    _c.addListener(() {
      if (mounted) setState(() {});
    });
    _c.initialize().then((_) {
      if (mounted) _c.play();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final v = _c.value;
    final total = v.duration.inMilliseconds.toDouble();
    final pos = v.position.inMilliseconds.toDouble().clamp(0, total > 0 ? total : 1).toDouble();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.title, style: const TextStyle(fontSize: 15)),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: v.hasError
                  ? const Text('تعذّر تشغيل الفيديو', style: TextStyle(color: Colors.white70))
                  : v.isInitialized
                      ? AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(_c))
                      : const CircularProgressIndicator(),
            ),
          ),
          Container(
            color: const Color(0xFF14102A),
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
            child: Column(children: [
              Slider(
                value: pos,
                max: total > 0 ? total : 1,
                onChanged: v.isInitialized
                    ? (x) => _c.seekTo(Duration(milliseconds: x.toInt()))
                    : null,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(v.position)),
                  IconButton(
                    iconSize: 48,
                    icon: Icon(v.isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_fill_rounded),
                    color: Theme.of(context).colorScheme.primary,
                    onPressed: v.isInitialized
                        ? () => v.isPlaying ? _c.pause() : _c.play()
                        : null,
                  ),
                  Text(_fmt(v.duration)),
                ],
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ───────── main.dart ─────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DownloadService.instance.load(); // استرجاع التحميلات المحفوظة
  runApp(const AnimeApp());
}

class AnimeApp extends StatelessWidget {
  const AnimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF0E0B1A);
    const surface = Color(0xFF1A1530);
    const sakura = Color(0xFFFF4D8D);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Anime',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(
          primary: sakura,
          secondary: Color(0xFF7C5CFF),
          surface: surface,
        ),
        appBarTheme: const AppBarTheme(backgroundColor: bg, elevation: 0),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: surface,
          indicatorColor: sakura.withOpacity(.25),
        ),
      ),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const _Shell(),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell();
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _i, children: const [HomeScreen(), DownloadsScreen()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _i,
        onDestinationSelected: (i) => setState(() => _i = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_rounded), label: 'الرئيسية'),
          NavigationDestination(icon: Icon(Icons.download_done_rounded), label: 'التحميلات'),
        ],
      ),
    );
  }
}
