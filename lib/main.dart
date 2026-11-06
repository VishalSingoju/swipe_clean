import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const SwipeCleanApp());

class SwipeCleanApp extends StatelessWidget {
  const SwipeCleanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Swipe Clean',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Photo service: loading photos and moving them to the "Deleted" folder.
// ---------------------------------------------------------------------------

const String kDeletedName = 'Deleted';
const int kFlushEvery = 20; // apply pending deletions in batches

class PhotoService {
  /// Returns true if we have (at least limited) access to the library.
  static Future<bool> requestAccess() async {
    final state = await PhotoManager.requestPermissionExtend();
    return state.hasAccess;
  }

  /// Loads photos/videos, newest first, skipping ids in [skip] and anything
  /// already inside the Deleted folder.
  static Future<List<AssetEntity>> load(Set<String> skip) async {
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false)
        ],
      ),
    );
    if (albums.isEmpty) return [];
    final all = albums.first;
    final total = await all.assetCountAsync;
    final assets = await all.getAssetListRange(start: 0, end: total);

    // Ids of items already in the Deleted album, so they don't show up again.
    final deletedIds = <String>{};
    final named = await PhotoManager.getAssetPathList(type: RequestType.common);
    for (final p in named) {
      if (p.name == kDeletedName) {
        final n = await p.assetCountAsync;
        final items = await p.getAssetListRange(start: 0, end: n);
        deletedIds.addAll(items.map((e) => e.id));
      }
    }
    return assets
        .where((a) => !skip.contains(a.id) && !deletedIds.contains(a.id))
        .toList();
  }

  /// Moves [items] into a folder called "Deleted".
  /// Android: copies the file into Pictures/Deleted (or Movies/Deleted), then
  ///          removes the original (one system confirmation per batch).
  /// iOS:     adds the item to an album called "Deleted" (the original stays
  ///          in the library, iOS has no real folders).
  /// Returns the ids that were successfully moved.
  static Future<Set<String>> moveToDeleted(List<AssetEntity> items) async {
    if (items.isEmpty) return {};
    final moved = <String>{};

    if (Platform.isAndroid) {
      final copied = <String>[];
      for (final a in items) {
        try {
          final file = await a.originFile;
          if (file == null) continue;
          final title = a.title ?? 'item_${a.id}';
          if (a.type == AssetType.video) {
            await PhotoManager.editor.saveVideo(
              file,
              title: title,
              relativePath: 'Movies/$kDeletedName',
            );
          } else {
            await PhotoManager.editor.saveImageWithPath(
              file.path,
              title: title,
              relativePath: 'Pictures/$kDeletedName',
            );
          }
          copied.add(a.id);
        } catch (_) {
          // Skip anything that fails to copy; it will not be deleted.
        }
      }
      if (copied.isNotEmpty) {
        final removed = await PhotoManager.editor.deleteWithIds(copied);
        moved.addAll(removed);
      }
    } else if (Platform.isIOS) {
      final albums =
          await PhotoManager.getAssetPathList(type: RequestType.common);
      AssetPathEntity? target;
      for (final p in albums) {
        if (p.name == kDeletedName) target = p;
      }
      target ??= await PhotoManager.editor.darwin.createAlbum(kDeletedName);
      if (target != null) {
        for (final a in items) {
          try {
            await PhotoManager.editor
                .copyAssetToPath(asset: a, pathEntity: target);
            moved.add(a.id);
          } catch (_) {}
        }
      }
    }
    return moved;
  }
}

// ---------------------------------------------------------------------------
// Home screen
// ---------------------------------------------------------------------------

enum Decision { keep, delete }

class _Action {
  _Action(this.asset, this.decision);
  final AssetEntity asset;
  final Decision decision;
  bool flushed = false; // true once a delete has been applied to storage
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _prefsKey = 'kept_ids';

  final _cardKey = GlobalKey<SwipeCardState>();
  SharedPreferences? _prefs;

  List<AssetEntity> _queue = [];
  int _index = 0;
  final Set<String> _kept = {};
  final List<_Action> _history = [];
  final List<_Action> _pending = []; // deletes not yet applied
  bool _loading = true;
  bool _denied = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Don't lose queued deletions when the user leaves the app.
    if (state == AppLifecycleState.paused) _flush();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _kept.addAll(_prefs!.getStringList(_prefsKey) ?? const []);
    final ok = await PhotoService.requestAccess();
    if (!ok) {
      setState(() {
        _denied = true;
        _loading = false;
      });
      return;
    }
    final items = await PhotoService.load(_kept);
    setState(() {
      _queue = items;
      _index = 0;
      _loading = false;
    });
  }

  Future<void> _saveKept() async =>
      _prefs?.setStringList(_prefsKey, _kept.toList());

  AssetEntity? get _current => _index < _queue.length ? _queue[_index] : null;
  AssetEntity? get _next =>
      _index + 1 < _queue.length ? _queue[_index + 1] : null;

  void _onSwiped(bool keep) {
    final asset = _current;
    if (asset == null) return;
    final action = _Action(asset, keep ? Decision.keep : Decision.delete);
    setState(() {
      _history.add(action);
      if (keep) {
        _kept.add(asset.id);
        _saveKept();
      } else {
        _pending.add(action);
      }
      _index++;
    });
    if (_pending.length >= kFlushEvery || _current == null) _flush();
  }

  Future<void> _flush() async {
    if (_busy || _pending.isEmpty) return;
    _busy = true;
    final batch = List<_Action>.from(_pending);
    try {
      final moved = await PhotoService.moveToDeleted(
        batch.map((a) => a.asset).toList(),
      );
      for (final a in batch) {
        if (moved.contains(a.asset.id)) {
          a.flushed = true;
          _pending.remove(a);
        }
      }
      if (mounted && moved.length < batch.length) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('${batch.length - moved.length} item(s) were not moved.'),
        ));
      }
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  void _undo() {
    if (_history.isEmpty) return;
    final last = _history.last;
    if (last.flushed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Already moved to Deleted. Restore it from that folder.'),
      ));
      return;
    }
    setState(() {
      _history.removeLast();
      _pending.remove(last);
      if (last.decision == Decision.keep) {
        _kept.remove(last.asset.id);
        _saveKept();
      }
      _index--;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Swipe Clean'),
        actions: [
          if (_pending.isNotEmpty)
            TextButton.icon(
              onPressed: _busy ? null : _flush,
              icon: const Icon(Icons.drive_file_move_outline),
              label: Text('Move ${_pending.length}'),
            ),
        ],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_denied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Swipe Clean needs access to your photos.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: PhotoManager.openSetting,
                child: const Text('Open settings'),
              ),
            ],
          ),
        ),
      );
    }
    final current = _current;
    if (current == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _queue.isEmpty
                ? 'No photos to review.'
                : "All done! Reviewed ${_queue.length} items.",
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Text('${_index + 1} / ${_queue.length}'),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Stack(
              children: [
                if (_next != null)
                  Positioned.fill(
                    child: Transform.scale(
                      scale: 0.95,
                      child: PhotoCard(asset: _next!),
                    ),
                  ),
                Positioned.fill(
                  child: SwipeCard(
                    key: _cardKey,
                    onSwiped: _onSwiped,
                    child: PhotoCard(asset: current),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _RoundButton(
                icon: Icons.close,
                color: Colors.redAccent,
                onTap: () => _cardKey.currentState?.swipe(false),
              ),
              _RoundButton(
                icon: Icons.undo,
                color: Colors.amber,
                small: true,
                onTap: _undo,
              ),
              _RoundButton(
                icon: Icons.check,
                color: Colors.greenAccent,
                onTap: () => _cardKey.currentState?.swipe(true),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.small = false,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final size = small ? 48.0 : 64.0;
    return Material(
      color: Colors.transparent,
      shape: CircleBorder(side: BorderSide(color: color, width: 2)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: color, size: small ? 24 : 32),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Photo card (thumbnail)
// ---------------------------------------------------------------------------

class PhotoCard extends StatefulWidget {
  const PhotoCard({super.key, required this.asset});
  final AssetEntity asset;

  @override
  State<PhotoCard> createState() => _PhotoCardState();
}

class _PhotoCardState extends State<PhotoCard> {
  late Future<Uint8List?> _future = _load();

  Future<Uint8List?> _load() =>
      widget.asset.thumbnailDataWithSize(const ThumbnailSize(1080, 1440));

  @override
  void didUpdateWidget(PhotoCard old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) _future = _load();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List?>(
              future: _future,
              builder: (context, snap) {
                final data = snap.data;
                if (data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Image.memory(data,
                    fit: BoxFit.contain, gaplessPlayback: true);
              },
            ),
            if (widget.asset.type == AssetType.video)
              const Positioned(
                top: 12,
                right: 12,
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white70, size: 36),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Swipeable card
// ---------------------------------------------------------------------------

class SwipeCard extends StatefulWidget {
  const SwipeCard({super.key, required this.child, required this.onSwiped});
  final Widget child;

  /// Called with true for a right swipe (keep), false for left (delete).
  final void Function(bool keep) onSwiped;

  @override
  State<SwipeCard> createState() => SwipeCardState();
}

class SwipeCardState extends State<SwipeCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Offset>? _anim;
  Offset _drag = Offset.zero;
  bool _animating = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(() {
      if (_anim != null) setState(() => _drag = _anim!.value);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _run(Offset target) async {
    _anim = Tween<Offset>(begin: _drag, end: target)
        .animate(CurvedAnimation(parent: _c, curve: Curves.easeOut));
    _c.reset();
    await _c.forward();
  }

  /// Programmatic swipe, used by the buttons.
  Future<void> swipe(bool keep) async {
    if (_animating) return;
    _animating = true;
    final w = MediaQuery.of(context).size.width;
    await _run(Offset((keep ? 1 : -1) * w * 1.5, 0));
    widget.onSwiped(keep);
    if (mounted) {
      setState(() => _drag = Offset.zero);
    }
    _animating = false;
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final progress = (_drag.dx / (w * 0.4)).clamp(-1.0, 1.0);
    return GestureDetector(
      onPanUpdate: (d) {
        if (_animating) return;
        setState(() => _drag += Offset(d.delta.dx, d.delta.dy * 0.3));
      },
      onPanEnd: (_) {
        if (_animating) return;
        if (_drag.dx.abs() > w * 0.3) {
          swipe(_drag.dx > 0);
        } else {
          _run(Offset.zero);
        }
      },
      child: Transform.translate(
        offset: _drag,
        child: Transform.rotate(
          angle: progress * 0.12,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (progress.abs() > 0.05)
                Positioned(
                  top: 24,
                  left: progress > 0 ? 24 : null,
                  right: progress < 0 ? 24 : null,
                  child: Opacity(
                    opacity: progress.abs(),
                    child: _Stamp(
                      label: progress > 0 ? 'KEEP' : 'DELETE',
                      color:
                          progress > 0 ? Colors.greenAccent : Colors.redAccent,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stamp extends StatelessWidget {
  const _Stamp({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 28, fontWeight: FontWeight.w800),
      ),
    );
  }
}
