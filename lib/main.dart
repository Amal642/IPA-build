import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:pedometer/pedometer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_app_check/firebase_app_check.dart';

import 'pages/login_page.dart';
import 'pages/home_page.dart';
import 'firebase_options.dart';

// Notification details
const notificationChannelId = 'my_foreground';
const notificationId = 888;

// Step filtering thresholds
const int MIN_TIME_BETWEEN_STEPS_MS = 400; // debounce double counts

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };


  // Activate App Check ONCE at startup
  await FirebaseAppCheck.instance.activate(
    androidProvider: AndroidProvider.playIntegrity,
    appleProvider: AppleProvider.appAttestWithDeviceCheckFallback,
  );
  await FirebaseAppCheck.instance.setTokenAutoRefreshEnabled(true);

  // Background service init
  await initializeService();

  // Crashlytics global handler
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;

  runZonedGuarded(() {
    runApp(const MyApp());
  }, (error, stackTrace) {
    FirebaseCrashlytics.instance.recordError(error, stackTrace, fatal: true);
  });
}

// Initializes the background service
Future<void> initializeService() async {
  final service = FlutterBackgroundService();
  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  const channel = AndroidNotificationChannel(
    notificationChannelId,
    'MBM fitness challenge 2025',
    description: 'Step tracking service notifications.',
    importance: Importance.low,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      autoStart: true,
      autoStartOnBoot: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: 'MBM fitness challenge 2025',
      initialNotificationContent: 'Initializing step counter...',
      foregroundServiceNotificationId: notificationId,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  int stepsOnDayStart = 0;
  int stepsToday = 0;
  int totalSteps = 0; // 🔥 NEW
  String lastSavedDay = "";
  int _lastStepCount = 0;
  DateTime _lastStepTimestamp = DateTime.now();

  StreamSubscription<StepCount>? stepCountStreamSubscription;
  Timer? midnightTimer;

  String getTodayDateKey() =>
      DateFormat('yyyy-MM-dd').format(DateTime.now());

  debugPrint("✅ [Service] Started.");

  // Helper: persist steps safely
  Future<void> persistSteps(int steps, int total, String dayKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('stepsToday', steps);
    await prefs.setInt('totalSteps', total); // 🔥 NEW
    await prefs.setString('lastSavedDay', dayKey);
    await prefs.setInt('stepsOnDayStart', stepsOnDayStart);
  }

  // Helper: update notification
  Future<void> updateNotification(int steps) async {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "MBM fitness challenge 2025",
        content: "Today's Steps: $steps",
      );
    }
  }

  // 🔔 Schedule midnight reset
  void scheduleMidnightReset() {
    midnightTimer?.cancel();
    final now = DateTime.now();
    final nextMidnight =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final duration = nextMidnight.difference(now);

    midnightTimer = Timer(duration, () async {
      // Reset ONLY daily steps
      stepsOnDayStart = _lastStepCount;
      stepsToday = 0;
      lastSavedDay = getTodayDateKey();
      await persistSteps(stepsToday, totalSteps, lastSavedDay); // ✅ MODIFIED
      await updateNotification(stepsToday);

      debugPrint("🌙 Midnight reset -> stepsToday = 0 (total stays $totalSteps)");

      // Schedule again for next midnight
      scheduleMidnightReset();
    });
  }

  // Load saved state
  final prefs = await SharedPreferences.getInstance();
  stepsToday = prefs.getInt('stepsToday') ?? 0;
  totalSteps = prefs.getInt('totalSteps') ?? 0; // 🔥 NEW
  stepsOnDayStart = prefs.getInt('stepsOnDayStart') ?? 0;
  lastSavedDay = prefs.getString('lastSavedDay') ?? getTodayDateKey();
  await updateNotification(stepsToday);
  scheduleMidnightReset();

  try {
    stepCountStreamSubscription = Pedometer.stepCountStream.listen(
      (StepCount event) async {
        final todayKey = getTodayDateKey();

        // Reset daily values when a new day starts
        if (todayKey != lastSavedDay) {
          lastSavedDay = todayKey;
          stepsOnDayStart = event.steps;
          stepsToday = 0;
          _lastStepCount = event.steps;
          await persistSteps(stepsToday, totalSteps, lastSavedDay); // ✅ MODIFIED
          await updateNotification(stepsToday);
        }

        final int newStepsDetected = event.steps - _lastStepCount;

        if (newStepsDetected > 0) {
          final now = DateTime.now();

          // ✅ Debounce filter
          if (now.difference(_lastStepTimestamp).inMilliseconds <
              MIN_TIME_BETWEEN_STEPS_MS) {
            return;
          }

          _lastStepTimestamp = now;
          _lastStepCount = event.steps;

          final newStepsToday = mathMax0(event.steps - stepsOnDayStart);
          if (newStepsToday != stepsToday) {
            final int delta = newStepsToday - stepsToday;
            stepsToday = newStepsToday;

            // 🔥 Update total steps as well
            totalSteps += delta;

            // Persist immediately
            await persistSteps(stepsToday, totalSteps, lastSavedDay);

            await updateNotification(stepsToday);

            service.invoke('update', {
              'stepsToday': stepsToday,
              'totalSteps': totalSteps,
            });
          }
        }
      },
      onError: (error, st) {
        FirebaseCrashlytics.instance.recordError(error, st,
            reason: 'Pedometer stream error');
      },
      cancelOnError: true,
    );
  } catch (e, st) {
    FirebaseCrashlytics.instance
        .recordError(e, st, reason: 'Critical: step listener failed');
  }

  service.on('stopService').listen((event) async {
    stepCountStreamSubscription?.cancel();
    midnightTimer?.cancel();
    await persistSteps(stepsToday, totalSteps, lastSavedDay); // ✅ MODIFIED
    service.stopSelf();
  });
}

// Utility: avoid negative
int mathMax0(int value) => value < 0 ? 0 : value;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MBM fitness challenge 2025',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: Colors.white,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const PermissionWrapper(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return const Scaffold(
            body: Center(
                child: Text("Something went wrong. Please try again.")),
          );
        }
        if (snapshot.hasData) {
          return const HomePage();
        } else {
          return LoginPage();
        }
      },
    );
  }
}

class PermissionWrapper extends StatefulWidget {
  const PermissionWrapper({super.key});

  @override
  State<PermissionWrapper> createState() => _PermissionWrapperState();
}

class _PermissionWrapperState extends State<PermissionWrapper> {
  bool _hasPermission = false;
  bool _permanentlyDenied = false;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    if (Platform.isAndroid) {
      final activityStatus = await Permission.activityRecognition.status;
      final notifStatus = await Permission.notification.status;

      if (activityStatus.isGranted && notifStatus.isGranted) {
        setState(() {
          _hasPermission = true;
          _permanentlyDenied = false;
        });
        return;
      }

      final results = await [
        Permission.activityRecognition,
        Permission.notification,
      ].request();

      final allGranted = results.values.every((p) => p.isGranted);
      final anyForever = results.values.any((p) => p.isPermanentlyDenied);

      setState(() {
        _hasPermission = allGranted;
        _permanentlyDenied = anyForever;
      });
    } else if (Platform.isIOS) {
      setState(() {
        _hasPermission = true;
        _permanentlyDenied = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasPermission) {
      return const AuthGate();
    }

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'This app needs permission to track your physical activity (for step counting) and to show low-importance notifications while counting steps.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _checkPermission,
                child: const Text('Grant Permission'),
              ),
              if (_permanentlyDenied) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: openAppSettings,
                  child: const Text('Open App Settings'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Permission was blocked. Please enable “Physical activity” and “Notifications” in Settings.',
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
