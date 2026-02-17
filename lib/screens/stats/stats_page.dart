import 'package:flutter/material.dart';
import '../../models/tweet_item.dart';
import '../gallery/gallery_page.dart';

enum StatsMode { user, hashtag }

class _StatsEntry {
  final String name;
  final int count;
  final String thumbnailUrl;
  final List<TweetItem> items;

  const _StatsEntry({
    required this.name,
    required this.count,
    required this.thumbnailUrl,
    required this.items,
  });
}

class StatsPage extends StatefulWidget {
  final List<TweetItem> items;

  const StatsPage({super.key, required this.items});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  StatsMode _mode = StatsMode.user;

  static final RegExp _userRegExp = RegExp(r'@([a-zA-Z0-9_]+)');
  static final RegExp _hashtagRegExp = RegExp(r'#[^\s#]+');

  List<_StatsEntry> _buildStats() {
    final Map<String, List<TweetItem>> grouped = {};

    for (final item in widget.items) {
      final matches = _mode == StatsMode.user
          ? _userRegExp.allMatches(item.fullText)
          : _hashtagRegExp.allMatches(item.fullText);

      for (final match in matches) {
        final key = match.group(0)!;
        grouped.putIfAbsent(key, () => []).add(item);
      }
    }

    final entries = grouped.entries.map((e) {
      final firstWithThumb = e.value.firstWhere(
        (item) => item.thumbnailUrl.isNotEmpty,
        orElse: () => e.value.first,
      );
      return _StatsEntry(
        name: e.key,
        count: e.value.length,
        thumbnailUrl: firstWithThumb.thumbnailUrl,
        items: e.value,
      );
    }).toList();

    entries.sort((a, b) => b.count.compareTo(a.count));
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final stats = _buildStats();

    return Scaffold(
      appBar: AppBar(
        title: Text(_mode == StatsMode.user ? 'Users' : 'Hashtags'),
        actions: [
          IconButton(
            icon: Icon(
              _mode == StatsMode.user ? Icons.tag : Icons.person,
            ),
            tooltip: _mode == StatsMode.user ? 'Hashtags' : 'Users',
            onPressed: () {
              setState(() {
                _mode = _mode == StatsMode.user
                    ? StatsMode.hashtag
                    : StatsMode.user;
              });
            },
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: stats.length,
        itemBuilder: (context, index) {
          final entry = stats[index];
          return ListTile(
            leading: SizedBox(
              width: 48,
              height: 48,
              child: entry.thumbnailUrl.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        entry.thumbnailUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (c, e, s) =>
                            const Icon(Icons.broken_image, color: Colors.grey),
                      ),
                    )
                  : const Icon(Icons.image, color: Colors.grey),
            ),
            title: Text(
              entry.name,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(
              '${entry.count}',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => GalleryPage(
                    initialItems: entry.items,
                    title: entry.name,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
