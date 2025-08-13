import 'dart:async';
import 'package:fitnesschallenge/pages/home_page.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:pin_code_fields/pin_code_fields.dart';
import 'package:fitnesschallenge/pages/signup_page.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController otpController = TextEditingController();

 String _selectedCountryCode = '+971';

  String? verificationId;
  int? forceResendingToken;
  bool otpSent = false;
  bool _isLoggedIn = false;
  bool isLoading = false;
  int resendTimeout = 30;
  Timer? _resendTimer;

  void _startResendTimer() {
    resendTimeout = 30;
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (resendTimeout == 0) {
        timer.cancel();
      } else {
        setState(() => resendTimeout--);
      }
    });
  }

  Future<void> _sendOTP() async {
    final phone = phoneController.text.trim();

    // Dynamic validation based on the selected country code
    bool isPhoneNumberValid =
        (_selectedCountryCode == '+971' && phone.length == 9) ||
            (_selectedCountryCode == '+91' && phone.length == 10);

    if (!isPhoneNumberValid) {
      String country = _selectedCountryCode == '+971' ? 'UAE' : 'Indian';
      String length = _selectedCountryCode == '+971' ? '9' : '10';
      Fluttertoast.showToast(
          msg: "Please enter a valid $length-digit $country phone number");
      return;
    }

    // Construct the full phone number with the selected country code
    final fullPhone = '$_selectedCountryCode$phone';
    setState(() => isLoading = true);

    try {
      // 🔍 Check Firestore for existing user with this phone number
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('phone', isEqualTo: fullPhone)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        Fluttertoast.showToast(
          msg: "User not registered. Please sign up first.",
        );
        setState(() => isLoading = false);
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => LoginSignupPage()),
        );
        return;
      }

      // ✅ If user exists, proceed with OTP verification
      await _auth.verifyPhoneNumber(
        phoneNumber: fullPhone,
        timeout: const Duration(seconds: 60),
        forceResendingToken: forceResendingToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          if (_isLoggedIn) return;

          final userCredential = await _auth.signInWithCredential(credential);
          if (userCredential.user != null) {
            _isLoggedIn = true;
            Fluttertoast.showToast(msg: "Auto-login success");
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => HomePage()),
              );
            });
          }
        },
        verificationFailed: (e) {
          Fluttertoast.showToast(msg: e.message ?? "Verification failed");
          setState(() => isLoading = false);
        },
        codeSent: (verId, resendToken) {
          verificationId = verId;
          setState(() {
            otpSent = true;
            isLoading = false;
            forceResendingToken = resendToken;
          });
          _startResendTimer();
        },
        codeAutoRetrievalTimeout: (verId) {
          verificationId = verId;
        },
      );
    } catch (e) {
      Fluttertoast.showToast(msg: "Error: ${e.toString()}");
      setState(() => isLoading = false);
    }
  }

  Future<void> _verifyOTP() async {
    if (_isLoggedIn) return; // prevent duplicate
    if (verificationId == null || otpController.text.length != 6) return;

    setState(() => isLoading = true);
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId!,
        smsCode: otpController.text.trim(),
      );

      final result = await _auth.signInWithCredential(credential);
      if (result.user != null) {
        Fluttertoast.showToast(msg: "Login success");
        //Navigate to dashboard

        WidgetsBinding.instance.addPostFrameCallback((_) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => HomePage()),
          );
        });
      }
    } catch (e) {
      Fluttertoast.showToast(msg: "Invalid OTP");
    } finally {
      setState(() => isLoading = false);
    }
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Login")),

      body:
          isLoading
              ? Center(child: CircularProgressIndicator())
              : Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Image.asset(
                        'assets/images/logo_highscope.png',
                        height: 100,
                      ),
                       //give a button to bypass to home screen
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(builder: (_) => HomePage()),
                          );
                        },
                        child: Text("Skip Login"),
                      ),
                      const SizedBox(height: 24),
                      Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey),
                      ),
                      child: Row(
                        children: [
                          // Dropdown for country codes
                          DropdownButton<String>(
                            value: _selectedCountryCode,
                            underline: SizedBox(), // Hides the default underline
                            items: [
                              DropdownMenuItem(
                                value: '+971',
                                child: Text('🇦🇪 +971'),
                              ),
                              DropdownMenuItem(
                                value: '+91',
                                child: Text('🇮🇳 +91'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setState(() {
                                  _selectedCountryCode = value;
                                });
                              }
                            },
                          ),
                          SizedBox(width: 8),
                          // Phone number input field
                          Expanded(
                            child: TextFormField(
                              controller: phoneController,
                              keyboardType: TextInputType.phone,
                              decoration: InputDecoration(
                                labelText: "Phone Number",
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                      const SizedBox(height: 20),
                      if (otpSent) ...[
                        PinCodeTextField(
                          appContext: context,
                          controller: otpController,
                          length: 6,
                          keyboardType: TextInputType.number,
                          onChanged: (_) {},
                        ),
                        ElevatedButton(
                          onPressed: _verifyOTP,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color.fromARGB(
                              255,
                              92,
                              233,
                              97,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 32,
                              vertical: 12,
                            ),
                          ),
                          child: Text("Verify OTP"),
                        ),
                        TextButton(
                          onPressed: resendTimeout == 0 ? _sendOTP : null,
                          child: Text(
                            resendTimeout == 0
                                ? "Resend OTP"
                                : "Resend in $resendTimeout sec",
                          ),
                        ),
                      ] else ...[
                        ElevatedButton(
                          onPressed: _sendOTP,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color.fromARGB(
                              255,
                              81,
                              227,
                              86,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 32,
                              vertical: 12,
                            ),
                          ),
                          child: Text("Send OTP"),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text("Don't have an account? "),
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => LoginSignupPage(),
                                ),
                              );
                            },
                            child: Text(
                              "Sign up",
                              style: TextStyle(
                                color: Colors.blue,
                                fontWeight: FontWeight.bold,
                              ),
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
