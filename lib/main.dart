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
import 'package:health/health.dart'; // ✅ Add this for iOS HealthKit

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

   // ✅ CRITICAL: Configure Firebase Auth for iOS
  if (Platform.isIOS) {
    
    // Set language code for better SMS delivery
    FirebaseAuth.instance.setLanguageCode('en');
    
    // Request HealthKit permissions early
    try {
      Health health = Health();
      await health.requestAuthorization([HealthDataType.STEPS], []);
      debugPrint("✅ Early HealthKit permission request completed");
    } catch (e) {
      debugPrint("❌ Early HealthKit permission error: $e");
    }
  }

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

  // Background service init (Android only)
  if (Platform.isAndroid) {
    await initializeService();
  }

  // Crashlytics global handler
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;

  runZonedGuarded(
    () {
      runApp(const MyApp());
    },
    (error, stackTrace) {
      FirebaseCrashlytics.instance.recordError(error, stackTrace, fatal: true);
    },
  );
}

// Initializes the background service (Android only)
Future<void> initializeService() async {
  if (!Platform.isAndroid) return;

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
        AndroidFlutterLocalNotificationsPlugin
      >()
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
      autoStart: false, // ✅ Changed to false - iOS handles differently
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
  int totalSteps = 0;
  String lastSavedDay = "";
  int _lastStepCount = 0;
  DateTime _lastStepTimestamp = DateTime.now();

  StreamSubscription<StepCount>? stepCountStreamSubscription;
  Timer? midnightTimer;
  Timer? healthKitTimer; // ✅ For iOS HealthKit polling

  String getTodayDateKey() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  debugPrint("✅ [Service] Started on ${Platform.operatingSystem}");

  // Helper: persist steps safely
  Future<void> persistSteps(int steps, int total, String dayKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('stepsToday', steps);
    await prefs.setInt('totalSteps', total);
    await prefs.setString('lastSavedDay', dayKey);
    await prefs.setInt('stepsOnDayStart', stepsOnDayStart);
  }

  // Helper: update notification (Android only)
  Future<void> updateNotification(int steps) async {
    if (Platform.isAndroid && service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "MBM fitness challenge 2025",
        content: "Today's Steps: $steps",
      );
    }
  }

  // ✅ iOS HealthKit step fetching
  Future<int> getHealthKitSteps() async {
  if (!Platform.isIOS) return 0;

  try {
    Health health = Health();

    // Define the types to get
    List<HealthDataType> types = [HealthDataType.STEPS];

    // Check if HealthKit is available on device
    bool? available = Health.hasPermissions(types);
    
    if (available != true) {
      // Request permissions - this will show iOS permission dialog
      bool authorized = await health.requestAuthorization(types, []);
      
      if (!authorized) {
        debugPrint("❌ HealthKit authorization denied");
        return 0;
      }
    }

    // Get today's date range
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day, 0, 0, 0);
    final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59);

    // Fetch step data for today
    List<HealthDataPoint> healthData = await health.getHealthDataFromTypes(
      types: types,
      startTime: startOfDay,
      endTime: endOfDay,
    );

    // Sum up steps from all data points
    int totalSteps = 0;
    for (var point in healthData) {
      if (point.type == HealthDataType.STEPS) {
        totalSteps += (point.value as num).round();
      }
    }

    debugPrint("📱 HealthKit steps for today: $totalSteps");
    return totalSteps;
  } catch (e, st) {
    debugPrint("❌ HealthKit error: $e");
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      reason: 'HealthKit integration error',
    );
    return 0;
  }
}

  // 🔔 Schedule midnight reset
  void scheduleMidnightReset() {
    midnightTimer?.cancel();
    final now = DateTime.now();
    final nextMidnight = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));
    final duration = nextMidnight.difference(now);

    midnightTimer = Timer(duration, () async {
      // Reset ONLY daily steps
      if (Platform.isAndroid) {
        stepsOnDayStart = _lastStepCount;
      }
      stepsToday = 0;
      lastSavedDay = getTodayDateKey();
      await persistSteps(stepsToday, totalSteps, lastSavedDay);
      await updateNotification(stepsToday);

      debugPrint(
        "🌙 Midnight reset -> stepsToday = 0 (total stays $totalSteps)",
      );

      // Schedule again for next midnight
      scheduleMidnightReset();
    });
  }

  // Load saved state
  final prefs = await SharedPreferences.getInstance();
  stepsToday = prefs.getInt('stepsToday') ?? 0;
  totalSteps = prefs.getInt('totalSteps') ?? 0;
  stepsOnDayStart = prefs.getInt('stepsOnDayStart') ?? 0;
  lastSavedDay = prefs.getString('lastSavedDay') ?? getTodayDateKey();
  await updateNotification(stepsToday);
  scheduleMidnightReset();

  // ✅ Platform-specific step tracking
  if (Platform.isAndroid) {
    // Android: Use Pedometer package
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
            await persistSteps(stepsToday, totalSteps, lastSavedDay);
            await updateNotification(stepsToday);
          }

          final int newStepsDetected = event.steps - _lastStepCount;

          if (newStepsDetected > 0) {
            final now = DateTime.now();

            // Debounce filter
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
          FirebaseCrashlytics.instance.recordError(
            error,
            st,
            reason: 'Pedometer stream error',
          );
        },
        cancelOnError: true,
      );
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'Critical: step listener failed',
      );
    }
  } else if (Platform.isIOS) {
    // iOS: Use HealthKit with periodic polling
    healthKitTimer = Timer.periodic(const Duration(minutes: 5), (timer) async {
      try {
        final todayKey = getTodayDateKey();

        // Reset daily values when a new day starts
        if (todayKey != lastSavedDay) {
          lastSavedDay = todayKey;
          stepsToday = 0;
          await persistSteps(stepsToday, totalSteps, lastSavedDay);
        }

        final healthKitSteps = await getHealthKitSteps();

        if (healthKitSteps > stepsToday) {
          final delta = healthKitSteps - stepsToday;
          stepsToday = healthKitSteps;
          totalSteps += delta;

          await persistSteps(stepsToday, totalSteps, lastSavedDay);

          service.invoke('update', {
            'stepsToday': stepsToday,
            'totalSteps': totalSteps,
          });

          debugPrint(
            "📊 iOS steps updated: today=$stepsToday, total=$totalSteps",
          );
        }
      } catch (e, st) {
        FirebaseCrashlytics.instance.recordError(
          e,
          st,
          reason: 'iOS HealthKit polling error',
        );
      }
    });

    // Initial HealthKit fetch
    final initialSteps = await getHealthKitSteps();
    if (initialSteps > 0) {
      stepsToday = initialSteps;
      await persistSteps(stepsToday, totalSteps, lastSavedDay);

      service.invoke('update', {
        'stepsToday': stepsToday,
        'totalSteps': totalSteps,
      });
    }
  }

  service.on('stopService').listen((event) async {
    stepCountStreamSubscription?.cancel();
    midnightTimer?.cancel();
    healthKitTimer?.cancel(); // ✅ Cancel iOS timer
    await persistSteps(stepsToday, totalSteps, lastSavedDay);
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
              child: Text("Something went wrong. Please try again."),
            ),
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
  String _permissionMessage = '';

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
  if (Platform.isAndroid) {
    // Your existing Android code
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
      _permissionMessage = 'This app needs permission to track your physical activity...';
    });
  } else if (Platform.isIOS) {
    // iOS: HealthKit permission handling
    try {
      Health health = Health();
      List<HealthDataType> types = [HealthDataType.STEPS];
      
      // Request authorization - this triggers iOS Health permission dialog
      bool authorized = await health.requestAuthorization(types, []);
      
      setState(() {
        _hasPermission = authorized;
        _permanentlyDenied = !authorized;
        _permissionMessage = authorized 
            ? 'Health access granted successfully!'
            : 'Please enable Steps access in Settings → Privacy & Security → Health → Data Access & Devices → [Your App Name]';
      });
      
      debugPrint("✅ iOS Health permission: $authorized");
      
    } catch (e) {
      debugPrint("❌ iOS Health permission error: $e");
      
      setState(() {
        _hasPermission = false;
        _permanentlyDenied = true;
        _permissionMessage = 'Unable to access Health data. Please check Health app settings.';
      });
    }
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
              Icon(
                Platform.isIOS
                    ? Icons.health_and_safety
                    : Icons.directions_walk,
                size: 64,
                color: Colors.blue,
              ),
              const SizedBox(height: 16),
              Text(
                _permissionMessage.isEmpty
                    ? 'This app needs permission to track your steps.'
                    : _permissionMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _checkPermission,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 12,
                  ),
                ),
                child: Text(
                  Platform.isIOS ? 'Allow Health Access' : 'Grant Permission',
                ),
              ),
              if (_permanentlyDenied) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () async {
                    if (Platform.isIOS) {
                      // On iOS, direct users to Health app
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Please open the Health app → Data Access & Devices → [Your App] → Turn on Steps',
                          ),
                          duration: Duration(seconds: 5),
                        ),
                      );
                    } else {
                      await openAppSettings();
                    }
                  },
                  child: Text(
                    Platform.isIOS ? 'Open Health App' : 'Open App Settings',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  Platform.isIOS
                      ? 'Please enable "Steps" access in the Health app for this app to work properly.'
                      : 'Permission was blocked. Please enable "Physical activity" and "Notifications" in Settings.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
