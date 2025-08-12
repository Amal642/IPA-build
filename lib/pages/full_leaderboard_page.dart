import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:intl/intl.dart';

class FullLeaderboardPage extends StatefulWidget {
  const FullLeaderboardPage({super.key});
  @override
  _FullLeaderboardPageState createState() => _FullLeaderboardPageState();
}

class _FullLeaderboardPageState extends State<FullLeaderboardPage> {
  List<Map<String, dynamic>> _leaderboard = [];
  bool _isLoading = false;
  bool _hasMore = true;
  String _error = '';
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _isLoading = true;

    _loadFullLeaderboardOnceDaily()
        .then((cached) {
          setState(() {
            _leaderboard = cached;
            _hasMore = false;
            _isLoading = false;
          });
        })
        .catchError((e) {
          setState(() {
            _error = 'Failed to load leaderboard.';
            _isLoading = false;
          });
        });
  }

  Future<List<Map<String, dynamic>>> _loadFullLeaderboardOnceDaily() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

    final cachedDate = prefs.getString('cached_full_leaderboard_date');
    final cachedJson = prefs.getStringList('cached_full_leaderboard');

    if (cachedDate == today && cachedJson != null) {
      return cachedJson
          .map((e) => Map<String, dynamic>.from(json.decode(e)))
          .toList();
    }

    final query =
        await FirebaseFirestore.instance
            .collection('users')
            .orderBy('total_kms', descending: true)
            .limit(100) // Limit to 100 for caching; scroll fetch more
            .get();

    final data =
        query.docs.map((doc) {
          return {
            'first_name': doc['first_name'] ?? '',
            'last_name': doc['last_name'] ?? '',
            'steps': doc['total_steps'] ?? 0,
            'total_km': doc['total_kms'] ?? 0.0,
            'avatarUrl': doc['profile_image_url'] ?? '',
          };
        }).toList();

    await prefs.setString('cached_full_leaderboard_date', today);
    await prefs.setStringList(
      'cached_full_leaderboard',
      data.map((e) => json.encode(e)).toList(),
    );

    return data;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Full Leaderboard'),
        backgroundColor: Colors.blue[600],
      ),
      body:
          _leaderboard.isEmpty && _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error.isNotEmpty
              ? Center(child: Text(_error))
              : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 12.0),
                    child: Text(
                      "📅 Leaderboard resets daily at 11:59 PM",
                      style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 16,
                      ),
                      itemCount: _leaderboard.length,
                      separatorBuilder: (context, index) => const Divider(),
                      itemBuilder: (context, index) {
                        final user = _leaderboard[index];
                        final isTop3 = index < 3;
                        final rankColor =
                            isTop3 ? Colors.amber[800] : Colors.blueGrey[800];

                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.grey[300],
                            child: ClipOval(
                              child: CachedNetworkImage(
                                imageUrl: user['avatarUrl'],
                                fit: BoxFit.cover,
                                width: 40,
                                height: 40,
                                placeholder:
                                    (context, url) =>
                                        const Icon(Icons.person, size: 24),
                                errorWidget:
                                    (context, url, error) =>
                                        const Icon(Icons.person, size: 24),
                              ),
                            ),
                          ),

                          title: Text(
                            "#${index + 1} ${user['first_name']} ${user['last_name'] ?? ''}",
                            style: TextStyle(
                              color: rankColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          subtitle: Text(
                            "${(user['total_km'] ?? 0.0).toStringAsFixed(2)} km • ${user['steps'] ?? 0} steps",
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[700],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
    );
  }
}
