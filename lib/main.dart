import 'dart:async';
import 'dart:ui';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:pedometer/pedometer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'pages/login_page.dart';
import 'pages/home_page.dart';
import 'firebase_options.dart';
import 'package:permission_handler/permission_handler.dart';

// Notification details for the foreground service
const notificationChannelId = 'my_foreground';
const notificationId = 888;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // Initialize and configure the background service
  await initializeService();

  // Configure Crashlytics and AppCheck
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

  // Create a notification channel for Android
  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  const channel = AndroidNotificationChannel(
    notificationChannelId,
    'MBM fitness challenge 2025',
    description: 'This channel is used for step tracking notifications.',
    importance: Importance.low,
  );
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
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

// Entry point for iOS background service
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}



@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  
  // --- In-memory variables for efficiency ---
  int stepsOnDayStart = 0;
  int stepsToday = 0;
  String lastSavedDay = "";
  StreamSubscription<StepCount>? stepCountStreamSubscription;

  String getTodayDateKey() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  // --- LOGGING: Service has started ---
  print("✅ [Background Service] Service has started.");

  // Add a delay to give plugins time to initialize properly.
  await Future.delayed(const Duration(seconds: 3));

  // --- LOGGING: Delay finished ---
  print("✅ [Background Service] Initial delay complete. Setting up pedometer.");

  try {
    stepCountStreamSubscription = Pedometer.stepCountStream.listen(
      (StepCount event) async {
        // --- LOGGING: Event received ---
        print("➡️ [Background Service] Step Count Event Received: ${event.steps}");

        String todayKey = getTodayDateKey();

        if (todayKey != lastSavedDay) {
          final prefs = await SharedPreferences.getInstance();
          lastSavedDay = todayKey;
          stepsOnDayStart = event.steps;
          stepsToday = 0;
          
          await prefs.setInt('stepsOnDayStart', stepsOnDayStart);
          await prefs.setString('lastSavedDay', lastSavedDay);
          print("🌅 [Background Service] New day detected. Baseline set to $stepsOnDayStart.");
        }
        
        int newStepsToday = max(0, event.steps - stepsOnDayStart);

        if (newStepsToday != stepsToday) {
          stepsToday = newStepsToday;
          
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('stepsToday', stepsToday);

          if (service is AndroidServiceInstance) {
            service.setForegroundNotificationInfo(
              title: "MBM fitness challenge 2025",
              content: "Today's Steps: $stepsToday",
            );
          }
          
          service.invoke('update', {'steps': stepsToday});
          print("👣 [Background Service] Steps updated: $stepsToday");
        }
      },
      onError: (error) {
        // --- LOGGING: Error in stream ---
        print("🐛 [Background Service] Pedometer Stream Error: $error");
      },
      cancelOnError: true,
    );
  } catch (e) {
    // --- LOGGING: Error setting up listener ---
    print(" Błąd krytyczny [Background Service] Could not start step listener: $e");
  }

  // Handle service stopping
  service.on('stopService').listen((event) {
    print("🔴 [Background Service] Stopping service.");
    stepCountStreamSubscription?.cancel();
    service.stopSelf();
  });
}

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
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
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

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final status = await Permission.activityRecognition.request();
    if (status.isGranted) {
      setState(() {
        _hasPermission = true;
      });
    } else {
      // You can add logic here to show a dialog or another widget
      // explaining why the permission is needed.
      print("Physical activity permission denied.");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasPermission) {
      return const AuthGate();
    } else {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'This app needs permission to track your physical activity for step counting.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _checkPermission,
                child: const Text('Grant Permission'),
              ),
            ],
          ),
        ),
      );
    }
  }
}
