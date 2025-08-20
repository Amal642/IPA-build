import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class FullLeaderboardPage extends StatefulWidget {
  const FullLeaderboardPage({super.key});

  @override
  State<FullLeaderboardPage> createState() => _FullLeaderboardPageState();
}

class _FullLeaderboardPageState extends State<FullLeaderboardPage> {
  final List<Map<String, dynamic>> _items = [];
  final ScrollController _scrollController = ScrollController();
  DocumentSnapshot? _lastDoc;
  bool _hasMore = true;
  bool _isLoading = false;
  bool _isInitialLoad = true;

  static const int pageSize = 20;

  @override
  void initState() {
    super.initState();
    _fetchPage(replace: true);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _formatNumber(num value) {
    if (value >= 1000000) {
      return "${(value / 1000000).toStringAsFixed(1)}M";
    } else if (value >= 1000) {
      return "${(value / 1000).toStringAsFixed(1)}K";
    } else {
      return value.toStringAsFixed(2);
    }
  }

  Future<void> _fetchPage({bool replace = false}) async {
    if (_isLoading || (!_hasMore && !replace)) return;
    setState(() => _isLoading = true);

    try {
      Query query = FirebaseFirestore.instance
          .collection('users')
          .orderBy('total_steps', descending: true)
          .limit(pageSize);

      if (_lastDoc != null && !replace) {
        query = query.startAfterDocument(_lastDoc!);
      }

      final snapshot = await query.get();

      if (replace) {
        _items.clear();
        _lastDoc = null;
        _hasMore = true;
      }

      if (snapshot.docs.isNotEmpty) {
        setState(() {
          _items.addAll(
            snapshot.docs.map((doc) {
              final data = doc.data() as Map<String, dynamic>;
              return {
                'id': doc.id,
                'first_name': data['first_name'] ?? '',
                'last_name': data['last_name'] ?? '',
                'total_steps': (data['total_steps'] ?? 0) as num,
                'total_kms': (data['total_kms'] ?? 0.0) as num,
                'profileUrl': data['profile_image_url'] ?? '',
              };
            }),
          );
          _lastDoc = snapshot.docs.last;
          _hasMore = snapshot.docs.length == pageSize;
        });
      } else {
        setState(() => _hasMore = false);
      }
    } catch (e) {
      debugPrint('Error fetching leaderboard: $e');
    } finally {
      setState(() {
        _isLoading = false;
        _isInitialLoad = false;
      });
    }
  }

  Future<void> _refresh() async {
    await _fetchPage(replace: true);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Leaderboard refreshed")));
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoading &&
        _hasMore) {
      _fetchPage();
    }
  }

  Widget _buildItem(BuildContext context, int index) {
    final user = _items[index];
    return ListTile(
      leading: CircleAvatar(
        backgroundImage:
            user['profileUrl'] != '' ? NetworkImage(user['profileUrl']) : null,
        child:
            user['profileUrl'] == ''
                ? Text(
                  user['first_name'].isNotEmpty
                      ? user['first_name'][0].toUpperCase()
                      : '?',
                )
                : null,
      ),
      title: Text(
        '${user['first_name']} ${user['last_name']}',
        style: TextStyle(
          color:
              (index < 3)
                  ? const Color.fromARGB(255, 216, 172, 42)
                  : Colors.black,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${_formatNumber(user['total_steps'])} steps • ${_formatNumber(user['total_kms'])} km',
      ),
      trailing: Text(
        '#${index + 1}',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color:
              (index < 3)
                  ? const Color.fromARGB(255, 216, 172, 42)
                  : Colors.black,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Full Leaderboard"),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body:
          _isInitialLoad
              ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text(
                      "Fetching full leaderboard...",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              )
              : RefreshIndicator(
                onRefresh: _refresh,
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount:
                      _items.length +
                      (_isLoading || _hasMore ? 1 : 0), // loader slot
                  itemBuilder: (context, index) {
                    if (index < _items.length) {
                      return _buildItem(context, index);
                    } else if (_isLoading) {
                      return const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    } else {
                      return const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Center(
                          child: Text(
                            "🎉 End of leaderboard",
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      );
                    }
                  },
                ),
              ),
    );
  }
}
