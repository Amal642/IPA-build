import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fitnesschallenge/pages/home_page.dart';

class LoginSignupPage extends StatefulWidget {
  const LoginSignupPage({super.key});
  @override
  State<LoginSignupPage> createState() => _LoginSignupPageState();
}

class _LoginSignupPageState extends State<LoginSignupPage> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController otpController = TextEditingController();

  final List<TextEditingController> _otpControllers = List.generate(
    6,
    (_) => TextEditingController(),
  );

  String _collectOtp() {
    return _otpControllers.map((c) => c.text.trim()).join();
  }

  File? _pickedImage;
  String? _selectedAvatarUrl;

  String _selectedCountryCode = '+971';
  final List<String> avatarUrls = [
    'https://firebasestorage.googleapis.com/v0/b/fitness-challenge-d3037.firebasestorage.app/o/avatars%2Favatar1.png?alt=media&token=1b3dbb55-3033-4e0f-8882-65451f3d687f',
    'https://firebasestorage.googleapis.com/v0/b/fitness-challenge-d3037.firebasestorage.app/o/avatars%2Favatar2.png?alt=media&token=71336887-09fa-4d9a-86f9-37d3d501f319',
    'https://firebasestorage.googleapis.com/v0/b/fitness-challenge-d3037.firebasestorage.app/o/avatars%2Favatar3.png?alt=media&token=85728e3c-0697-4f58-8252-85573ac591a0',
    'https://firebasestorage.googleapis.com/v0/b/fitness-challenge-d3037.firebasestorage.app/o/avatars%2Favatar4.png?alt=media&token=078a7a06-5ce0-419c-a340-51917e36b7cd',
    'https://firebasestorage.googleapis.com/v0/b/fitness-challenge-d3037.firebasestorage.app/o/avatars%2Favatar5.png?alt=media&token=d93d3a6f-6e0a-434d-8543-998c25b763e9',
    'https://firebasestorage.googleapis.com/v0/b/fitness-challenge-d3037.firebasestorage.app/o/avatars%2Favatar6.png?alt=media&token=5b4e22dc-63b5-4e7a-a7fb-132f701330bc',
    'https://firebasestorage.googleapis.com/v0/b/fitness-challenge-d3037.firebasestorage.app/o/avatars%2Favatar7.png?alt=media&token=b9b96c4c-fd86-42aa-b78a-7df9efc62559',
    'https://firebasestorage.googleapis.com/v0/b/fitness-challenge-d3037.firebasestorage.app/o/avatars%2Favatar8.png?alt=media&token=7ac905fd-1f34-40be-a5c0-1e6724b03293',
  ];

  final _formKey = GlobalKey<FormState>();
  final phoneController = TextEditingController();
  final fnameController = TextEditingController();
  final lnameController = TextEditingController();
  final emailController = TextEditingController();

  String? verificationId;
  int? forceResendingToken;
  bool otpSent = false;
  bool isLoading = false;
  int resendTimeout = 30;
  Timer? _resendTimer;

  void _showSnack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? Colors.red : Colors.green,
      ),
    );
  }

  Future<bool> _hasInternet({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity == ConnectivityResult.none) return false;
    try {
      final socket = await Socket.connect('8.8.8.8', 53, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _startResendTimer() {
    resendTimeout = 30;
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (resendTimeout == 0) {
        timer.cancel();
      } else {
        if (mounted) setState(() => resendTimeout--);
      }
    });
  }

  Future<File?> _pickFromGallery() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return null;
    return File(picked.path);
  }

  Future<void> _sendOTP() async {
    FocusScope.of(context).unfocus();

    if (_pickedImage == null && _selectedAvatarUrl == null) {
      _showSnack(
        'Please select an avatar or pick a photo before continuing.',
        error: true,
      );
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    final phone = phoneController.text.trim();
    final fullPhone = '$_selectedCountryCode$phone';

    final hasNet = await _hasInternet();
    if (!hasNet) {
      _showSnack('No internet connection.', error: true);
      return;
    }

    if (mounted) setState(() => isLoading = true);

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: fullPhone,
        timeout: const Duration(seconds: 60),
        forceResendingToken: forceResendingToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          try {
            await _auth.signInWithCredential(credential);
            await _afterAuthSuccess();
          } catch (e) {
            _showSnack('Auto verification failed: $e', error: true);
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          _showSnack(e.message ?? 'Verification failed', error: true);
          if (mounted) setState(() => isLoading = false);
        },
        codeSent: (String verId, int? resendToken) {
          if (!mounted) return;
          setState(() {
            verificationId = verId;
            otpSent = true;
            isLoading = false;
            forceResendingToken = resendToken;
          });
          _startResendTimer();
          _showSnack('OTP sent.');
        },
        codeAutoRetrievalTimeout: (String verId) {
          verificationId = verId;
        },
      );
    } catch (e) {
      _showSnack('Error sending OTP: $e', error: true);
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _verifyOTP(String code) async {
    if (verificationId == null || code.length != 6) {
      _showSnack('Please enter the 6-digit OTP.', error: true);
      return;
    }

    if (mounted) setState(() => isLoading = true);
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId!,
        smsCode: code,
      );

      final result = await _auth.signInWithCredential(credential);
      if (result.user != null) {
        await _afterAuthSuccess();
      } else {
        _showSnack('OTP verification failed.', error: true);
        if (mounted) setState(() => isLoading = false);
      }
    } catch (e) {
      _showSnack('OTP verification failed: $e', error: true);
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _afterAuthSuccess() async {
    final user = _auth.currentUser;
    if (user == null) {
      _showSnack('User not found after auth.', error: true);
      if (mounted) setState(() => isLoading = false);
      return;
    }

    String? imageUrl;
    try {
      if (_pickedImage != null) {
        final ref = FirebaseStorage.instance.ref(
          'user_uploads/${user.uid}/profile.jpg',
        );
        await ref.putFile(_pickedImage!);
        imageUrl = await ref.getDownloadURL();
      } else if (_selectedAvatarUrl != null) {
        imageUrl = _selectedAvatarUrl!;
      }
    } catch (e) {
      _showSnack('Could not upload profile image: $e', error: true);
      if (mounted) setState(() => isLoading = false);
      return;
    }

    try {
      final userDoc = _firestore.collection('users').doc(user.uid);
      final doc = await userDoc.get();

      if (!doc.exists) {
        await userDoc.set({
          "uid": user.uid,
          "phone": user.phoneNumber,
          "first_name": fnameController.text.trim(),
          "last_name": lnameController.text.trim(),
          "email": emailController.text.trim(),
          "profile_image_url": imageUrl,
          "created_at": Timestamp.now(),
        });
        _showSnack('Sign up successful!');
      } else {
        _showSnack('Welcome back! Logged in.');
      }

      if (!mounted) return;
      setState(() => isLoading = false);
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomePage()),
        (route) => false,
      );
    } catch (e) {
      _showSnack('Saving profile failed: $e', error: true);
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    phoneController.dispose();
    fnameController.dispose();
    lnameController.dispose();
    emailController.dispose();
    otpController.dispose();
    for (final c in _otpControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign Up')),
      body: Stack(
        children: [
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    Image.asset(
                      'assets/images/logo_highscope.png',
                      height: 100,
                    ),
                    const SizedBox(height: 16),
                    if (!otpSent) ...[
                      _boxedField(
                        child: TextFormField(
                          controller: fnameController,
                          decoration: const InputDecoration(
                            labelText: 'First Name',
                            border: InputBorder.none,
                          ),
                          validator:
                              (v) =>
                                  (v == null || v.trim().isEmpty)
                                      ? 'Required'
                                      : null,
                        ),
                      ),
                      _boxedField(
                        child: TextFormField(
                          controller: lnameController,
                          decoration: const InputDecoration(
                            labelText: 'Last Name',
                            border: InputBorder.none,
                          ),
                          validator:
                              (v) =>
                                  (v == null || v.trim().isEmpty)
                                      ? 'Required'
                                      : null,
                        ),
                      ),
                      _boxedField(
                        child: TextFormField(
                          controller: emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            border: InputBorder.none,
                          ),
                          validator: (v) {
                            final s = (v ?? '').trim();
                            if (s.isEmpty) return 'Required';
                            if (!s.contains('@') || !s.contains('.'))
                              return 'Invalid email';
                            return null;
                          },
                        ),
                      ),

                      const SizedBox(height: 8),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Choose Profile Picture',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 8),

                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children:
                            avatarUrls.map((path) {
                              final selected = _selectedAvatarUrl == path;
                              return GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedAvatarUrl = selected ? null : path;
                                    if (_selectedAvatarUrl != null)
                                      _pickedImage = null;
                                  });
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color:
                                          selected
                                              ? Colors.blue
                                              : Colors.transparent,
                                      width: 2,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  child: CircleAvatar(
                                    backgroundImage: NetworkImage(path),
                                    radius: 30,
                                  ),
                                ),
                              );
                            }).toList(),
                      ),

                      const SizedBox(height: 12),
                      TextButton.icon(
                        icon: const Icon(Icons.photo),
                        label: const Text('Pick from Gallery'),
                        onPressed:
                            isLoading
                                ? null
                                : () async {
                                  final file = await _pickFromGallery();
                                  if (file != null) {
                                    setState(() {
                                      _pickedImage = file;
                                      _selectedAvatarUrl = null;
                                    });
                                  }
                                },
                      ),

                      if (_pickedImage != null)
                        CircleAvatar(
                          backgroundImage: FileImage(_pickedImage!),
                          radius: 40,
                        ),

                      const SizedBox(height: 16),
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
                              underline: const SizedBox.shrink(),
                              items: const [
                                DropdownMenuItem(
                                  value: '+971',
                                  child: Text('🇦🇪 +971'),
                                ),
                                DropdownMenuItem(
                                  value: '+91',
                                  child: Text('🇮🇳 +91'),
                                ),
                              ],
                              onChanged:
                                  (v) => setState(
                                    () => _selectedCountryCode = v ?? '+971',
                                  ),
                            ),
                            Expanded(
                              child: TextFormField(
                                controller: phoneController,
                                keyboardType: TextInputType.phone,
                                decoration: const InputDecoration(
                                  labelText: 'Phone Number',
                                  border: InputBorder.none,
                                ),
                                validator:
                                    (v) =>
                                        (v == null || v.trim().isEmpty)
                                            ? 'Required'
                                            : null,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: isLoading ? null : _sendOTP,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                        ),
                        child: const Text('Send OTP'),
                      ),
                    ],

                    if (otpSent) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Enter the 6-digit OTP sent to ${phoneController.text}',
                      ),
                      const SizedBox(height: 12),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: List.generate(6, (index) {
                          return SizedBox(
                            width: 45,
                            child: TextField(
                              textAlign: TextAlign.center,
                              keyboardType: TextInputType.number,
                              maxLength: 1,
                              decoration: const InputDecoration(
                                counterText: '',
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (value) {
                                if (value.isNotEmpty) {
                                  if (index < 5) {
                                    FocusScope.of(
                                      context,
                                    ).nextFocus(); // move to next box
                                  } else {
                                    FocusScope.of(
                                      context,
                                    ).unfocus(); // close keyboard at last box
                                  }
                                }
                              },
                              onSubmitted: (value) {
                                if (index == 5) {
                                  final code = _collectOtp();
                                  if (code.length == 6) {
                                    _verifyOTP(code);
                                  }
                                }
                              },
                              controller: _otpControllers[index],
                            ),
                          );
                        }),
                      ),

                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed:
                            isLoading
                                ? null
                                : () {
                                  final code = _collectOtp();
                                  if (code.length == 6) {
                                    _verifyOTP(code);
                                  } else {
                                    _showSnack(
                                      'Please enter all 6 digits',
                                      error: true,
                                    );
                                  }
                                },
                        child: const Text('Verify OTP'),
                      ),

                      TextButton(
                        onPressed:
                            (resendTimeout == 0 && !isLoading)
                                ? _sendOTP
                                : null,
                        child: Text(
                          resendTimeout == 0
                              ? 'Resend OTP'
                              : 'Resend in $resendTimeout sec',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          if (isLoading)
            Container(
              color: Colors.black.withOpacity(0.15),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _boxedField({required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey),
      ),
      child: child,
    );
  }
}
