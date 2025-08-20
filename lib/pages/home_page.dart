// lib/pages/home_page.dart
// Production-ready HomePage for iOS + Android
// - Safe lifecycle handling (mounted checks, stream disposals)
// - Platform-aware permissions (Android requests ACTIVITY_RECOGNITION; iOS allows and relies on CMPedometer runtime prompt)
// - Robust Firestore reads (null-safe, defensive decoding)
// - Fixed leaderboard podium (#2 | #1 | #3) and removed duplicate/invalid code
// - Outbox + hourly sync retained; added guards and error handling

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fitnesschallenge/pages/full_leaderboard_page.dart';
import 'package:fitnesschallenge/pages/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:intl/intl.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  // --- CONSTANTS ---
  static const double _kMetersPerStep = 0.762; // avg adult step length
  static const double _kKcalPerStep = 0.04; // rough kcal/step

  // --- SUBSCRIPTIONS / TIMERS ---
  StreamSubscription<PedestrianStatus>? _pedestrianStatusSubscription;
  StreamSubscription<Map<String, dynamic>?>? _bgServiceSubscription;
  Timer? _hourlySyncTimer;

  int _liveTotalSteps = 0;

  // --- UI STATE ---
  String _status = "stopped";
  String _userName = "";
  int _steps = 0;
  bool _isPermissionGranted = false;
  bool _isLoading = true;
  bool _isRefreshing = false;

  // --- CALCULATED METRICS ---
  double _calories = 0;
  double _distanceKm = 0;
  int _dailyGoal = 10000;

  // --- DATA FOR UI ---
  List<Map<String, dynamic>> topUsers = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  @override
  void dispose() {
    _pedestrianStatusSubscription?.cancel();
    _bgServiceSubscription?.cancel();
    _hourlySyncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _saveDailyStepsToFirestore();
    }
  }

  // --- INITIALIZATION ---
  Future<void> _initializeApp() async {
    try {
      await _checkPermissions();
      await _fetchUserName();
      await _processMidnightOutbox();
      await _loadDailyGoal();
      await _refreshData();
      _startHourlySyncTimer();
    } finally {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  Future<void> _checkPermissions() async {
    bool granted = true;

    if (Platform.isAndroid) {
      final status = await Permission.activityRecognition.request();
      granted = status.isGranted;
    } else if (Platform.isIOS) {
      // iOS: CMPedometer prompts at first use. We allow UI; stream will handle denial.
      granted = true;
    }

    if (!mounted) return;
    setState(() => _isPermissionGranted = granted);

    if (granted) {
      await _initializeSensorsAndBackground();
    }
  }

  Future<void> _initializeSensorsAndBackground() async {
    // Load cached steps immediately for a responsive first frame.
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getInt('stepsToday') ?? 0;
    if (mounted) {
      setState(() {
        _steps = cached;
        _recalculate();
      });
    }

    // Listen for status stream (walking/stopped)
    try {
      _pedestrianStatusSubscription = Pedometer.pedestrianStatusStream.listen(
        (event) {
          final next = (event.status ?? '').toLowerCase();
          if (mounted) setState(() => _status = next);
        },
        onError: (_) {
          if (mounted) setState(() => _status = "unknown");
        },
      );
    } catch (_) {
      if (mounted) setState(() => _status = "unknown");
    }

    // Listen for live updates from your background service
    try {
      _bgServiceSubscription = FlutterBackgroundService().on('update').listen((
        event,
      ) {
        if (event == null || !mounted) return;

        final int? today =
            event['stepsToday'] is int
                ? event['stepsToday']
                : int.tryParse("${event['stepsToday']}");
        final int? total =
            event['totalSteps'] is int
                ? event['totalSteps']
                : int.tryParse("${event['totalSteps']}");

        setState(() {
          if (today != null) _steps = today;
          if (total != null) _liveTotalSteps = total; // 🔥 keep running total
          _recalculate();
        });
      });
    } catch (_) {
      // If the background service isn't running, we just keep cached steps.
    }
  }

  // --- SYNC & OUTBOX ---
  void _startHourlySyncTimer() {
    _hourlySyncTimer?.cancel();
    _hourlySyncTimer = Timer.periodic(const Duration(minutes: 30), (_) async {
      await _processMidnightOutbox();
      await _saveDailyStepsToFirestore();
    });
  }

  Future<void> _processMidnightOutbox() async {
    final prefs = await SharedPreferences.getInstance();
    final outboxSteps = prefs.getInt('midnight_outbox_steps');
    final outboxDate = prefs.getString('midnight_outbox_date');

    if (outboxSteps != null && outboxDate != null) {
      try {
        await _pushMidnightStepsToFirestore(outboxSteps);
        await prefs.remove('midnight_outbox_steps');
        await prefs.remove('midnight_outbox_date');
      } catch (e) {
        // Keep for retry
        debugPrint('Failed to push midnight outbox: $e');
      }
    }
  }

  Future<void> _pushMidnightStepsToFirestore(int stepsToAdd) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || stepsToAdd <= 0) return;

    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(userRef);
      if (!snap.exists) return;

      final data = snap.data() as Map<String, dynamic>? ?? {};
      final currentTotalSteps = (data['total_steps'] ?? 0) as int;
      final currentTotalKms = (data['total_kms'] ?? 0.0).toDouble();

      final distanceToAddKm = (stepsToAdd * _kMetersPerStep) / 1000.0;

      tx.update(userRef, {
        'total_steps': currentTotalSteps + stepsToAdd,
        'total_kms': currentTotalKms + distanceToAddKm,
      });
    });
  }

  Future<void> _saveDailyStepsToFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final prefs = await SharedPreferences.getInstance();
    final todayKey = _dateKey();
    final currentSteps = prefs.getInt('stepsToday') ?? 0;
    final lastSaved = prefs.getInt('firestore_saved_steps_$todayKey') ?? 0;
    final delta = currentSteps - lastSaved;

    if (delta <= 0) return;

    try {
      final userRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(userRef);
        if (!snap.exists) return;

        final data = snap.data() as Map<String, dynamic>? ?? {};
        final totalSteps = (data['total_steps'] ?? 0) as int;
        final totalKms = (data['total_kms'] ?? 0.0).toDouble();

        final distanceToAddKm = (delta * _kMetersPerStep) / 1000.0;

        tx.update(userRef, {
          'total_steps': totalSteps + delta,
          'total_kms': totalKms + distanceToAddKm,
        });
      });

      await prefs.setInt('firestore_saved_steps_$todayKey', currentSteps);
    } catch (e) {
      debugPrint('Failed to sync to Firestore: $e');
    }
  }

  // --- REFRESH ---
  Future<void> _refreshData() async {
    if (_isRefreshing) return;
    if (mounted) setState(() => _isRefreshing = true);

    try {
      final freshTop = await _loadTopUsersFromFirestore();
      if (mounted) {
        setState(() => topUsers = freshTop);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Leaderboard refreshed ✅")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Failed to refresh leaderboard ❌")),
        );
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  // --- DATA ---
  void _recalculate() {
    _calories = _steps * _kKcalPerStep;
    _distanceKm = (_steps * _kMetersPerStep) / 1000.0;
  }

  String _dateKey() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  Future<void> _fetchUserName() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _dateKey();
    final cachedDate = prefs.getString('cached_name_date');
    final cachedName = prefs.getString('cached_user_name');

    if (cachedDate == today && cachedName != null) {
      if (mounted) setState(() => _userName = cachedName);
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final doc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();

      final data = doc.data();
      final first = (data?['first_name'] ?? '').toString();
      final last = (data?['last_name'] ?? '').toString();
      final name =
          '$first $last'.trim().isEmpty ? 'User' : '$first $last'.trim();

      if (mounted) setState(() => _userName = name);

      await prefs.setString('cached_name_date', today);
      await prefs.setString('cached_user_name', name);
    } catch (e) {
      debugPrint('Failed to fetch user name: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _loadTopUsersFromFirestore() async {
    try {
      final qs =
          await FirebaseFirestore.instance
              .collection('users')
              .orderBy('total_kms', descending: true)
              .limit(3)
              .get();

      final fresh = <Map<String, dynamic>>[];
      for (final doc in qs.docs) {
        final d = doc.data();
        final first = (d['first_name'] ?? '').toString();
        final last = (d['last_name'] ?? '').toString();
        final combinedName = (first + (last.isEmpty ? '' : ' $last')).trim();

        fresh.add({
          'name': combinedName.isEmpty ? 'User' : combinedName,
          'first_name': first,
          'last_name': last,
          'total_km': (d['total_kms'] ?? 0.0).toDouble(),
          'total_steps': (d['total_steps'] ?? 0) as int,
          'profileUrl': (d['profile_image_url'] ?? '').toString(),
        });
      }

      // Cache
      final prefs = await SharedPreferences.getInstance();
      final today = _dateKey();
      await prefs.setString('cached_top_date', today);
      await prefs.setStringList(
        'cached_top_users',
        fresh.map((e) => json.encode(e)).toList(),
      );

      return fresh;
    } catch (e) {
      debugPrint('Failed to load top users: $e');
      return [];
    }
  }

  Future<void> _stopBackgroundTasks() async {
    try {
      _hourlySyncTimer?.cancel();
      _hourlySyncTimer = null;

      await _pedestrianStatusSubscription?.cancel();
      _pedestrianStatusSubscription = null;

      await _bgServiceSubscription?.cancel();
      _bgServiceSubscription = null;
    } catch (e) {
      debugPrint("Error stopping background tasks: $e");
    }
  }

  // --- LOGOUT ---
  Future<void> _handleLogout() async {
    if (!mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text("Confirm Logout"),
            content: const Text("Are you sure you want to logout?"),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text("Logout"),
              ),
            ],
          ),
    );

    if (confirm != true) return;

    // Show "Logging out..." dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (_) => const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text("Logging out...", style: TextStyle(fontSize: 16)),
              ],
            ),
          ),
    );

    try {
      // Save daily steps
      await _saveDailyStepsToFirestore();

      // Stop sensors & timers
      await _stopBackgroundTasks();

      // Clear local session data
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('stepsToday');
      await prefs.remove('totalSteps');
      await prefs.remove('cached_user_name');
      await prefs.remove('dailyGoal');
      // Keep leaderboard cache if desired

      // Firebase sign out
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      debugPrint("Logout error: $e");
    } finally {
      if (!mounted) return;
      Navigator.of(context).pop(); // close progress dialog

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Logged out successfully ✅")),
      );
    }
  }

  // --- UI BUILD ---
  @override
  Widget build(BuildContext context) {
    final progress =
        _dailyGoal > 0 ? (_steps / _dailyGoal).clamp(0.0, 1.0) : 0.0;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text("Hi, $_userName", style: const TextStyle(fontSize: 20)),
        elevation: 0,
        actions:
            _isPermissionGranted
                ? [
                  IconButton(
                    icon: const Icon(Icons.settings),
                    onPressed: _showGoalDialog,
                  ),
                  IconButton(
                    icon: const Icon(Icons.logout),
                    tooltip: 'Logout',
                    onPressed: _handleLogout,
                  ),
                ]
                : [],
      ),
      body:
          _isLoading
              ? const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                ),
              )
              : !_isPermissionGranted
              ? _buildPermissionScreen()
              : RefreshIndicator(
                onRefresh: _refreshData,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      _buildLeaderboardCard(),
                      const SizedBox(height: 30),
                      _buildStepsCard(progress),
                      const SizedBox(height: 30),
                      _buildMetricsRow(),
                      _buildTotalStatsCard(),
                    ],
                  ),
                ),
              ),
    );
  }

  Widget _buildPermissionScreen() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.directions_walk, size: 100, color: Colors.blue),
          const SizedBox(height: 30),
          const Text(
            "Permission Required",
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24.0),
            child: Text(
              "Please allow motion/activity recognition to enable step tracking.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.blueGrey),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _checkPermissions,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
            child: const Text(
              "Grant Permission",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: openAppSettings,
            child: const Text(
              "Open Settings",
              style: TextStyle(fontSize: 16, color: Colors.blue),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeaderboardCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text(
            "🏆 Leaderboard",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.blueGrey,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "↻ Pull to refresh",
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const SizedBox(height: 20),
          if (topUsers.length >= 3)
            _buildTop3Podium(topUsers)
          else
            const Text(
              "Leaderboard is gathering data...",
              style: TextStyle(fontSize: 16, color: Colors.blueGrey),
            ),
        ],
      ),
    );
  }

  Widget _buildStepsCard(double progress) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.blue[400]!, Colors.blue[600]!],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withOpacity(0.2),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                height: 180,
                width: 180,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 12,
                  backgroundColor: Colors.white.withOpacity(0.3),
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              Column(
                children: [
                  Icon(
                    _status == "walking"
                        ? Icons.directions_walk
                        : Icons.accessibility_new,
                    size: 50,
                    color: Colors.white,
                  ),
                  Text(
                    "$_steps",
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "of ${_formatCompactDouble(_dailyGoal.toDouble())} steps",
                    style: const TextStyle(fontSize: 18, color: Colors.white70),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color:
                  _status == "walking"
                      ? Colors.green
                      : Colors.white.withOpacity(0.3),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _status == "walking" ? "Walking" : "Stopped",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: _status == "walking" ? Colors.white : Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildStatCard(
          title: "Calories",
          value: _calories.toStringAsFixed(1),
          icon: Icons.local_fire_department,
          unit: "kcal",
          color: Colors.orange,
        ),
        _buildStatCard(
          title: "Distance",
          value: _distanceKm.toStringAsFixed(2),
          icon: Icons.directions_walk,
          unit: "km",
          color: Colors.purple,
        ),
        _buildStatCard(
          title: "Today",
          value: (_steps * 0.008).toStringAsFixed(0),
          icon: Icons.timer,
          unit: "min",
          color: Colors.teal,
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    required IconData icon,
    required String unit,
    required Color color,
  }) {
    return Container(
      width: MediaQuery.of(context).size.width * 0.28,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FB),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, size: 28, color: color),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          Text(unit, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
        ],
      ),
    );
  }

  Widget _buildTotalStatsCard() {
    final totalSteps = _liveTotalSteps;
    final totalKms = (totalSteps * _kMetersPerStep) / 1000.0;

    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.deepPurple.shade50,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.deepPurple.withOpacity(0.15),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          const Text(
            'Total Progress',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            "📅 Live synced",
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Column(
                children: [
                  const Text('👣 Steps'),
                  const SizedBox(height: 4),
                  Text(
                    "${_formatCompactDouble(totalSteps.toDouble())} steps",
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Column(
                children: [
                  const Text('📏 Distance'),
                  const SizedBox(height: 4),
                  Text(
                    "${_formatCompactDouble(totalKms)} km",
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTop3Podium(List<Map<String, dynamic>> users) {
    // Expecting exactly top-3 list ordered by total_km desc
    if (users.length < 3) {
      return const Text(
        "Leaderboard is gathering data...",
        style: TextStyle(color: Colors.blueGrey),
      );
    }

    // Layout: #2 | #1 (elevated) | #3
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,

          children: [
            _buildUserColumn(
              rank: 2,
              user: users[1],
              imageSize: 60,
              fontSize: 14,
            ),
            const SizedBox(width: 16),
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              child: _buildUserColumn(
                rank: 1,
                user: users[0],
                imageSize: 80,
                fontSize: 16,
                isCenter: true,
              ),
            ),
            const SizedBox(width: 16),
            _buildUserColumn(
              rank: 3,
              user: users[2],
              imageSize: 60,
              fontSize: 14,
            ),
            const SizedBox(width: 16),
          ],
        ),
        const SizedBox(height: 20),
        TextButton(
          onPressed: () {
            if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const FullLeaderboardPage(),
              ),
            );
          },
          child: const Text(
            "View Full Leaderboard",
            style: TextStyle(
              color: Colors.blue,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUserColumn({
    required int rank,
    required Map<String, dynamic> user,
    required double imageSize,
    required double fontSize,
    bool isCenter = false,
  }) {
    final String profileUrl = (user['profileUrl'] ?? '').toString();
    final ImageProvider imageProvider =
        profileUrl.isNotEmpty
            ? CachedNetworkImageProvider(profileUrl)
            : const AssetImage('assets/images/logo_highscope.png');

    // Prefer 'name', fall back to first/last or "User"
    String displayName = (user['name'] ?? '').toString().trim();
    if (displayName.isEmpty) {
      final first = (user['first_name'] ?? '').toString();
      final last = (user['last_name'] ?? '').toString();
      displayName = (first + (last.isEmpty ? '' : ' $last')).trim();
      if (displayName.isEmpty) displayName = 'User';
    }

    final double avatarBorderWidth = rank == 1 ? 3 : 0;

    return SizedBox(
      width: 90,
      child: Column(
        children: [
          Text(
            "#$rank",
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: fontSize,
              color: rank == 1 ? Colors.amber[700] : Colors.blueGrey,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border:
                  avatarBorderWidth > 0
                      ? Border.all(
                        color: Colors.amber,
                        width: avatarBorderWidth,
                      )
                      : null,
            ),
            child: CircleAvatar(
              radius: imageSize / 2,
              backgroundImage: imageProvider,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            displayName,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: fontSize),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            "${(user['total_km'] ?? 0.0).toStringAsFixed(2)} km",
            style: TextStyle(fontSize: fontSize - 2, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  // --- GOAL DIALOG & PERSISTENCE ---
  void _showGoalDialog() {
    final controller = TextEditingController(text: _dailyGoal.toString());
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Set Daily Goal"),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: "Daily Steps Goal",
              hintText: "Enter your daily steps goal",
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                final parsed = int.tryParse(controller.text);
                final newGoal =
                    (parsed == null || parsed <= 0) ? 10000 : parsed;
                if (mounted) setState(() => _dailyGoal = newGoal);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setInt('dailyGoal', newGoal);
                if (mounted) Navigator.pop(context);
              },
              child: const Text("Set Goal"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadDailyGoal() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _dailyGoal = prefs.getInt('dailyGoal') ?? 10000);
  }

  // --- UTILS ---
  String _formatCompactDouble(double number) {
    if (number >= 1000000) return "${(number / 1000000).toStringAsFixed(1)}M";
    if (number >= 1000) return "${(number / 1000).toStringAsFixed(1)}K";
    return number.toStringAsFixed(number == number.roundToDouble() ? 0 : 1);
  }
}
