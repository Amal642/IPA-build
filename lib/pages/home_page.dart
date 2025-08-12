import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:fitnesschallenge/pages/full_leaderboard_page.dart';
import 'package:fitnesschallenge/pages/login_page.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:intl/intl.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:flutter_background_service/flutter_background_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  // --- STATE VARIABLES ---
  // Listener for the "walking" or "stopped" status from the pedometer.
  StreamSubscription<PedestrianStatus>? _pedestrianStatusSubscription;

  // UI State
  String _status = "stopped";
  String _userName = "";
  int _steps = 0; // This is the main state variable for today's steps.
  bool _isPermissionGranted = false;
  bool _isLoading = true;

  // Calculated Metrics
  double _calories = 0;
  double _distance = 0;
  int _dailyGoal = 10000; // A more standard default goal.

  // Data for UI
  List<Map<String, dynamic>> topUsers = [];

  // --- LIFECYCLE METHODS ---
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // This is the main entry point for all initializations.
    _checkPermissions();
    _fetchUserName();
    _loadTopUsersOnceDaily().then((top) {
      if (mounted) setState(() => topUsers = top);
    });
    _scheduleDailyFirestoreUpdate();
    _loadDailyGoal();
  }

  @override
  void dispose() {
    _pedestrianStatusSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Save data to Firestore when the app is backgrounded or closed.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _saveDailyStepsToFirestore();
    }
  }

  // --- PERMISSIONS & INITIALIZATION ---

  /// Checks for activity permission and starts the step counter if granted.
  Future<void> _checkPermissions() async {
    final status = await Permission.activityRecognition.request();
    if (mounted) {
      setState(() {
        _isPermissionGranted = status.isGranted;
      });
    }

    if (_isPermissionGranted) {
      await _initializeStepCounter();
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Initializes listeners to get step data from the background service.
  Future<void> _initializeStepCounter() async {
    // 1. Get the latest steps saved by the background service upon opening the app.
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _steps = prefs.getInt('stepsToday') ?? 0;
        _calculateMetrics();
      });
    }

    // 2. Listen for LIVE updates from the background service while the app is open.
    FlutterBackgroundService().on('update').listen((event) {
      final newSteps = event?['steps'];
      if (newSteps != null && newSteps is int && mounted) {
        setState(() {
          _steps = newSteps;
          _calculateMetrics();
        });
      }
    });

    // 3. (Optional but good for UI) Get the walking/stopped status.
    _pedestrianStatusSubscription = Pedometer.pedestrianStatusStream.listen((
      event,
    ) {
      if (mounted) setState(() => _status = event.status);
    });
  }

  // --- DATA HANDLING & CALCULATIONS ---

  /// Calculates calories and distance based on the current step count.
  void _calculateMetrics() {
    _calories = _steps * 0.04;
    _distance = (_steps * 0.762) / 1000;
  }

  /// Helper to get a formatted date string for keys.
  String _getDateKey() {
    return DateFormat('yyyy-MM-dd').format(DateTime.now());
  }

  /// Periodically saves the latest step count to Firestore.
  void _scheduleDailyFirestoreUpdate() {
    // This timer ensures data is saved at least once a day, even if the app isn't backgrounded.
    Timer.periodic(const Duration(minutes: 30), (timer) {
      _saveDailyStepsToFirestore();
    });
  }

  /// Saves the daily step count to Firestore safely.
  /// This method is transactional and prevents double-counting.
  Future<void> _saveDailyStepsToFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final prefs = await SharedPreferences.getInstance();
    final todayKey = _getDateKey();

    // Get the current total steps for today from the reliable source (SharedPreferences).
    final int currentTotalSteps = prefs.getInt('stepsToday') ?? 0;

    // Get the step count that we last successfully saved to Firestore for today.
    final int lastSavedSteps =
        prefs.getInt('firestore_saved_steps_$todayKey') ?? 0;

    // Calculate the difference (new steps since the last save).
    final int stepsToAdd = currentTotalSteps - lastSavedSteps;

    if (stepsToAdd <= 0) return; // No new steps to add.

    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);

    // Use a transaction to safely read and update the grand total steps.
    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(userRef);

      final currentGrandTotal = (snapshot.data()?['total_steps'] ?? 0) as int;
      final newGrandTotal = currentGrandTotal + stepsToAdd;

      final double distanceToAdd = (stepsToAdd * 0.762) / 1000.0;
      final currentTotalKms = (snapshot.data()?['total_kms'] ?? 0.0) as double;
      final newTotalKms = currentTotalKms + distanceToAdd;

      transaction.set(userRef, {
        'total_steps': newGrandTotal,
        'total_kms': newTotalKms,
        // Also, save today's absolute step count in a sub-map for historical data.
        'daily_steps': {todayKey: currentTotalSteps},
      }, SetOptions(merge: true));
    });

    // After a successful save, update the local marker to prevent recounting these steps.
    await prefs.setInt('firestore_saved_steps_$todayKey', currentTotalSteps);
  }

  /// Fetches the user's name, caching it for the day.
  void _fetchUserName() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _getDateKey();
    final cachedDate = prefs.getString('cached_name_date');
    final cachedName = prefs.getString('cached_user_name');

    if (cachedDate == today && cachedName != null && mounted) {
      setState(() => _userName = cachedName);
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final doc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();
      final name = "${doc['first_name']} ${doc['last_name'] ?? 'User'}";
      if (mounted) setState(() => _userName = name);

      await prefs.setString('cached_name_date', today);
      await prefs.setString('cached_user_name', name);
    }
  }

  /// Fetches the top 3 performers from Firestore, caching the result for the day.
  Future<List<Map<String, dynamic>>> _loadTopUsersOnceDaily() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _getDateKey();

    final cachedDate = prefs.getString('cached_top_date');
    final cachedTopUsersJson = prefs.getStringList('cached_top_users');

    if (cachedDate == today && cachedTopUsersJson != null) {
      return cachedTopUsersJson.map((jsonStr) {
        return Map<String, dynamic>.from(json.decode(jsonStr) as Map);
      }).toList();
    }

    final querySnapshot =
        await FirebaseFirestore.instance
            .collection('users')
            .orderBy('total_kms', descending: true)
            .limit(3)
            .get();

    List<Map<String, dynamic>> freshTopUsers = [];
    for (var doc in querySnapshot.docs) {
      final data = doc.data();
      freshTopUsers.add({
        'name': "${data['first_name'] ?? ''}",
        'total_km': (data['total_kms']?.toDouble() ?? 0.0),
        'total_steps': data['total_steps'] ?? 0,
        'profileUrl': data['profile_image_url'] ?? '',
      });
    }

    await prefs.setString('cached_top_date', today);
    await prefs.setStringList(
      'cached_top_users',
      freshTopUsers.map((e) => json.encode(e)).toList(),
    );

    return freshTopUsers;
  }

  /// Loads the user's grand total stats from Firestore, caching for the day.
  Future<Map<String, dynamic>> _loadTotalStatsOnceDaily() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _getDateKey();

    final cachedDate = prefs.getString('cached_total_date');
    if (cachedDate == today) {
      return {
        'total_steps': prefs.getInt('cached_total_steps') ?? 0,
        'total_kms': prefs.getDouble('cached_total_kms') ?? 0.0,
      };
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return {'total_steps': 0, 'total_kms': 0.0};

    final snapshot =
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
    final data = snapshot.data() ?? {};
    final totalSteps = data['total_steps'] ?? 0;
    final totalKms = (data['total_kms'] ?? 0.0).toDouble();

    await prefs.setString('cached_total_date', today);
    await prefs.setInt('cached_total_steps', totalSteps);
    await prefs.setDouble('cached_total_kms', totalKms);

    return {'total_steps': totalSteps, 'total_kms': totalKms};
  }

  // --- UI METHODS ---

  /// Shows a dialog to let the user set their daily step goal.
  void _showGoalDialog() {
    showDialog(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: _dailyGoal.toString());
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
                final newGoal = int.tryParse(controller.text) ?? 10000;
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

  /// Loads the daily goal from shared preferences.
  Future<void> _loadDailyGoal() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _dailyGoal = prefs.getInt('dailyGoal') ?? 10000;
      });
    }
  }

  /// Compacts a large number into a K/M format.
  String _formatCompactDouble(double number) {
    if (number >= 1000000) return "${(number / 1000000).toStringAsFixed(1)}M";
    if (number >= 1000) return "${(number / 1000).toStringAsFixed(1)}K";
    return number.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    // final averageSteps = ((_steps + _filteredSteps) / 2).ceil();
    // final progress = _dailyGoal > 0 ? averageSteps / _dailyGoal : 0.0;
    final progress = _dailyGoal > 0 ? _steps / _dailyGoal : 0.0;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text("Hi, $_userName", style: TextStyle(fontSize: 20)),

        elevation: 0,
        actions:
            _isPermissionGranted
                ? [
                  IconButton(
                    icon: Icon(Icons.settings),
                    onPressed: _showGoalDialog,
                  ),
                  IconButton(
                    icon: Icon(Icons.logout),
                    onPressed: () async {
                      await FirebaseAuth.instance.signOut();
                      if (context.mounted) {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(builder: (_) => LoginPage()),
                        );
                        Fluttertoast.showToast(msg: "Logged out successfully");
                      }
                    },
                    tooltip: 'Logout',
                  ),
                ]
                : [],
      ),

      body:
          _isLoading
              ? Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                ),
              )
              : !_isPermissionGranted
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.directions_walk, size: 100, color: Colors.blue),
                    SizedBox(height: 30),
                    Text(
                      "Permission Required",
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    SizedBox(height: 10),
                    Text(
                      "Please grant activity recognition permission to use the app.",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, color: Colors.blueGrey),
                    ),
                    SizedBox(height: 40),
                    ElevatedButton(
                      onPressed: _checkPermissions,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: Text(
                        "Grant Permission",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    SizedBox(height: 20),
                    TextButton(
                      onPressed: () async {
                        await openAppSettings();
                      },
                      child: Text(
                        "Open Settings",
                        style: TextStyle(fontSize: 16, color: Colors.blue),
                      ),
                    ),
                  ],
                ),
              )
              : SingleChildScrollView(
                padding: EdgeInsets.all(20),
                child: Column(
                  children: [
                    Container(
                      padding: EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 10,
                            offset: Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          //align this to center
                          Center(
                            child: Text(
                              "🏆 Leaderboard",
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.blueGrey[800],
                              ),
                            ),
                          ),
                          //make this center
                          Center(
                            child: Text(
                              "📅 Resets daily",
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          if (topUsers.isNotEmpty)
                            buildTop3Podium(topUsers)
                          else
                            Center(
                              child: Text(
                                "No users found",
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Colors.blueGrey,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(height: 30),
                    Container(
                      padding: EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.blue[400]!, Colors.blue[600]!],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blue.withOpacity(0.2),
                            blurRadius: 10,
                            offset: Offset(0, 5),
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
                                  value: progress.clamp(0.0, 1.0),
                                  strokeWidth: 12,
                                  backgroundColor: Colors.white.withOpacity(
                                    0.3,
                                  ),
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
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
                                    style: TextStyle(
                                      fontSize: 36,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  SizedBox(height: 10),
                                  Text(
                                    "of $_dailyGoal Steps",
                                    style: TextStyle(
                                      fontSize: 18,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          SizedBox(height: 20),

                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 8,
                            ),
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
                                color:
                                    _status == "walking"
                                        ? Colors.white
                                        : Colors.black,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 30),
                    Row(
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
                          value: _distance.toStringAsFixed(2),
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
                    ),

                    FutureBuilder<Map<String, dynamic>>(
                      future: _loadTotalStatsOnceDaily(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const CircularProgressIndicator();
                        }

                        if (!snapshot.hasData) {
                          return const Text("No data available.");
                        }

                        final totalSteps = snapshot.data!['total_steps'] ?? 0;
                        final totalKms = snapshot.data!['total_kms'] ?? 0.0;

                        return Container(
                          margin: const EdgeInsets.only(top: 20),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.deepPurple.shade50,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.deepPurple.withOpacity(0.2),
                                blurRadius: 8,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              const Text(
                                'Total Progress',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              //make this center
                              Center(
                                child: Text(
                                  "📅 Refreshes daily",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
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
                                        "${_formatCompactDouble(totalKms.toDouble())} km",
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
                      },
                    ),
                  ],
                ),
              ),
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
      width: MediaQuery.of(context).size.width * 0.25,
      padding: EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 195, 255, 112),
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.1),
            spreadRadius: 1,
            blurRadius: 5,
          ),
        ],
      ),
      child: Column(
        // mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 30, color: color),
          SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              // color: color,
            ),
          ),
          // SizedBox(height: 5),
          Text(unit, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
        ],
      ),
    );
  }

  Widget buildTop3Podium(List<Map<String, dynamic>> topUsers) {
    if (topUsers.length < 3) {
      // You can return a message or a simpler widget if there aren't enough users.
      return const Text(
        "Leaderboard is gathering data...",
        style: TextStyle(color: Colors.blueGrey),
      );
    }

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          // crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Rank #2
            buildUserColumn(
              rank: 2,
              user: topUsers[1],
              imageSize: 60,
              fontSize: 14,
            ),
            const SizedBox(width: 16),
            // Rank #1
            buildUserColumn(
              rank: 1,
              user: topUsers[0],
              imageSize: 90,
              fontSize: 16,
              isCenter: true,
            ),
            const SizedBox(width: 16),
            // Rank #3
            buildUserColumn(
              rank: 3,
              user: topUsers[2],
              imageSize: 60,
              fontSize: 14,
            ),
          ],
        ),
        const SizedBox(height: 20),
        TextButton(
          onPressed: () {
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

  Widget buildUserColumn({
    required int rank,
    required Map<String, dynamic> user,
    required double imageSize,
    required double fontSize,
    bool isCenter = false,
  }) {
    ImageProvider imageProvider;
    final String? profileUrl = user['profileUrl'];

    if (profileUrl != null && profileUrl.isNotEmpty) {
      // If the URL exists and is not empty, use the cached network image.
      imageProvider = CachedNetworkImageProvider(profileUrl);
    } else {
      // Otherwise, use the local asset as a fallback.
      imageProvider = const AssetImage('assets/images/logo_highscope.png');
    }
    // --- New Display Name Logic ---
    String displayName;

   if (user['name'] != null && (user['name'] as String).isNotEmpty) {
    displayName = user['name'];
  } else {
    // 2. Fall back to combining first and last name.
    displayName = '${user['first_name'] ?? ''}}'.trim();
  }
    // 3. If all name fields are empty, provide a final fallback name.
    if (displayName.isEmpty) {
      displayName = 'User';
    }
    return Column(
      children: [
        Text("#$rank", style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        CircleAvatar(radius: imageSize / 2, backgroundImage: imageProvider),
        const SizedBox(height: 6),
        // --- Use the determined displayName here ---
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
          style: TextStyle(fontSize: fontSize - 2),
        ),
      ],
    );
  }
}
