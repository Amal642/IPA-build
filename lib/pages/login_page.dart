import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fitnesschallenge/pages/home_page.dart';
import 'package:fitnesschallenge/pages/signup_page.dart';
import 'package:flutter/material.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';


class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final TextEditingController phoneController = TextEditingController();
  final List<TextEditingController> otpControllers =
      List.generate(6, (_) => TextEditingController());

  String _selectedCountryCode = '+971';
  String? verificationId;
  int? forceResendingToken;
  bool otpSent = false;
  bool isLoading = false;
  bool _verifying = false;

  int resendTimeout = 30;
  Timer? _resendTimer;

  // ===== Utils =====
  void _showSnack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : Colors.green),
    );
  }

  void _startResendTimer() {
    resendTimeout = 30;
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (resendTimeout == 0) {
        t.cancel();
      } else {
        setState(() => resendTimeout--);
      }
    });
  }

  bool _isValidPhone(String phone, String code) {
    if (code == '+971') return phone.length == 9;
    if (code == '+91') return phone.length == 10;
    return phone.isNotEmpty; // fallback
  }

  // ===== OTP Flow =====
  Future<void> _sendOTP() async {
    FocusScope.of(context).unfocus();
    final phone = phoneController.text.trim();

    if (!_isValidPhone(phone, _selectedCountryCode)) {
      final country = _selectedCountryCode == '+971' ? 'UAE' : 'Indian';
      final len = _selectedCountryCode == '+971' ? '9' : '10';
      _showSnack('Enter a valid $len-digit $country phone number', error: true);
      return;
    }

    final fullPhone = '$_selectedCountryCode$phone';

    setState(() {
      isLoading = true;
    });

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: fullPhone,
        timeout: const Duration(seconds: 60),
        forceResendingToken: forceResendingToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          // Disabled auto sign-in; user must type OTP manually
        },
        verificationFailed: (FirebaseAuthException e) {
          setState(() => isLoading = false);
          _showSnack(e.message ?? 'Verification failed', error: true);
        },
        codeSent: (String verId, int? resendToken) async {
          verificationId = verId;
          forceResendingToken = resendToken;
          setState(() {
            otpSent = true;
            isLoading = false;
          });
          _startResendTimer();
        },
        codeAutoRetrievalTimeout: (String verId) {
          verificationId = verId;
        },
      );
    } on SocketException {
      _showSnack('No internet connection', error: true);
      setState(() => isLoading = false);
    } catch (e) {
      _showSnack('Error: $e', error: true);
      setState(() => isLoading = false);
    }
  }

  Future<void> _verifyOTP() async {
    if (_verifying) return;
    if (verificationId == null) {
      _showSnack('Please request an OTP first', error: true);
      return;
    }

    final smsCode = otpControllers.map((c) => c.text).join();
    if (smsCode.length != 6) {
      _showSnack('Enter a valid 6-digit OTP', error: true);
      return;
    }

    setState(() {
      _verifying = true;
      isLoading = true;
    });

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId!,
        smsCode: smsCode,
      );
      await _signInWithCredentialAndRoute(credential);
    } catch (e) {
      _showSnack('Invalid OTP', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _verifying = false;
          isLoading = false;
        });
      }
    }
  }

  Future<void> _signInWithCredentialAndRoute(PhoneAuthCredential credential) async {
    final userCred = await _auth.signInWithCredential(credential);
    final user = userCred.user;
    if (user == null) {
      _showSnack('Login failed. Try again.', error: true);
      return;
    }

    final users = FirebaseFirestore.instance.collection('users');

    final uidDoc = await users.doc(user.uid).get();

    bool exists = uidDoc.exists;
    if (!exists) {
      final fullPhone = user.phoneNumber ?? '';
      if (fullPhone.isNotEmpty) {
        final snap = await users.where('phone', isEqualTo: fullPhone).limit(1).get();
        exists = snap.docs.isNotEmpty;
      }
    }

    if (!exists) {
      try {
        await _auth.signOut();
      } catch (_) {}
      if (!mounted) return;
      _showSnack('User not registered, please sign up first', error: true);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginSignupPage()),
      );
      return;
    }

    if (!mounted) return;
    _showSnack('Login success');
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    phoneController.dispose();
    for (final c in otpControllers) {
      c.dispose();
    }
    super.dispose();
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Image.asset('assets/images/logo_highscope.png', height: 100),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(builder: (_) => const HomePage()),
                        );
                      },
                      child: const Text('Continue as Guest'),
                    ),
                    //give a button to simulate crash for firebase crashlytics
                    ElevatedButton(
                      onPressed: () {
                        FirebaseCrashlytics.instance.crash();
                      },
                      child: const Text('Simulate Crash'),
                    ),
                    // Phone field
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey),
                      ),
                      child: Row(
                        children: [
                          DropdownButton<String>(
                            value: _selectedCountryCode,
                            underline: const SizedBox(),
                            items: const [
                              DropdownMenuItem(value: '+971', child: Text('🇦🇪 +971')),
                              DropdownMenuItem(value: '+91', child: Text('🇮🇳 +91')),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => _selectedCountryCode = v);
                            },
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: phoneController,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                labelText: 'Phone Number',
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    if (!otpSent) ...[
                      ElevatedButton(
                        onPressed: _sendOTP,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                        ),
                        child: const Text('Send OTP'),
                      ),
                    ] else ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Enter OTP', style: Theme.of(context).textTheme.bodyMedium),
                      ),
                      const SizedBox(height: 12),

                      // OTP individual boxes
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: List.generate(6, (i) {
                          return SizedBox(
                            width: 45,
                            child: TextField(
                              controller: otpControllers[i],
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              maxLength: 1,
                              decoration: InputDecoration(
                                counterText: "",
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              onChanged: (value) {
                                if (value.isNotEmpty && i < 5) {
                                  FocusScope.of(context).nextFocus();
                                } else if (value.isEmpty && i > 0) {
                                  FocusScope.of(context).previousFocus();
                                }
                              },
                            ),
                          );
                        }),
                      ),

                      const SizedBox(height: 16),

                      ElevatedButton(
                        onPressed: _verifying ? null : _verifyOTP,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                        ),
                        child: _verifying ? const Text('Verifying...') : const Text('Verify OTP'),
                      ),

                      TextButton(
                        onPressed: resendTimeout == 0 ? _sendOTP : null,
                        child: Text(resendTimeout == 0 ? 'Resend OTP' : 'Resend in $resendTimeout sec'),
                      ),
                    ],

                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text("Don't have an account? "),
                        GestureDetector(
                          onTap: () {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(builder: (_) => const LoginSignupPage()),
                            );
                          },
                          child: const Text(
                            'Sign up',
                            style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
