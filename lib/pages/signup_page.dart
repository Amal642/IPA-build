import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // ✅ Add this for kDebugMode
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
  bool _verifying = false; // ✅ Add verification state
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

  // ✅ Improved phone validation
  bool _isValidPhone(String phone, String code) {
    if (code == '+971') return phone.length == 9;
    if (code == '+91') return phone.length == 10;
    return phone.isNotEmpty; // fallback
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

  // ✅ IMPROVED: Fix OTP sending for iOS in your LoginSignupPage
Future<void> _sendOTP() async {
  FocusScope.of(context).unfocus();

  if (_pickedImage == null && _selectedAvatarUrl == null) {
    _showSnack('Please select an avatar or pick a photo before continuing.', error: true);
    return;
  }
  if (!_formKey.currentState!.validate()) return;

  final phone = phoneController.text.trim();

  if (!_isValidPhone(phone, _selectedCountryCode)) {
    final country = _selectedCountryCode == '+971' ? 'UAE' : 'Indian';
    final len = _selectedCountryCode == '+971' ? '9' : '10';
    _showSnack('Enter a valid $len-digit $country phone number', error: true);
    return;
  }

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
      timeout: const Duration(seconds: 120), // ✅ Increased timeout for iOS
      forceResendingToken: forceResendingToken,
      verificationCompleted: (PhoneAuthCredential credential) async {
        debugPrint('✅ iOS Auto verification completed for signup');
        if (Platform.isIOS) {
          // ✅ FIXED: Better handling for iOS auto-verification
          try {
            final userCred = await _auth.signInWithCredential(credential);
            if (userCred.user != null) {
              await _afterAuthSuccess();
            }
          } catch (e) {
            debugPrint('❌ iOS Auto sign-in failed: $e');
            // Continue with manual OTP entry
            if (mounted) {
              _showSnack('Please enter the OTP manually', error: false);
              setState(() {
                otpSent = true;
                isLoading = false;
              });
            }
          }
        }
      },
      verificationFailed: (FirebaseAuthException e) {
        if (mounted) setState(() => isLoading = false);
        
        String errorMessage = 'Verification failed';
        
        // ✅ IMPROVED: Better iOS-specific error handling
        switch (e.code) {
          case 'invalid-phone-number':
            errorMessage = 'Invalid phone number format. Please check the number and country code.';
            break;
          case 'too-many-requests':
            errorMessage = 'Too many requests. Please wait and try again later.';
            break;
          case 'operation-not-allowed':
            errorMessage = 'Phone authentication is not enabled. Please contact support.';
            break;
          case 'quota-exceeded':
            errorMessage = 'SMS quota exceeded. Please try again later.';
            break;
          case 'app-not-authorized':
            errorMessage = 'App not authorized for phone authentication.';
            break;
          case 'captcha-check-failed':
            errorMessage = 'reCAPTCHA verification failed. Please try again.';
            break;
          default:
            errorMessage = e.message ?? 'Phone verification failed. Please try again.';
        }
        
        debugPrint('❌ iOS Phone verification failed: ${e.code} - ${e.message}');
        _showSnack(errorMessage, error: true);
      },
      codeSent: (String verId, int? resendToken) {
        if (!mounted) return;
        debugPrint('✅ iOS OTP code sent successfully');
        setState(() {
          verificationId = verId;
          otpSent = true;
          isLoading = false;
          forceResendingToken = resendToken;
        });
        _startResendTimer();
        _showSnack('OTP sent successfully! Check your messages.');
      },
      codeAutoRetrievalTimeout: (String verId) {
        verificationId = verId;
        debugPrint('⏰ iOS Auto retrieval timeout for signup');
      },
    );
  } on SocketException {
    _showSnack('No internet connection. Please check your connection and try again.', error: true);
    if (mounted) setState(() => isLoading = false);
  } catch (e) {
    debugPrint('❌ iOS OTP sending error: $e');
    _showSnack('Error sending OTP: ${e.toString()}', error: true);
    if (mounted) setState(() => isLoading = false);
  }
}
  Future<void> _verifyOTP(String code) async {
    if (_verifying) return; // ✅ Prevent multiple calls
    
    if (verificationId == null || code.length != 6) {
      _showSnack('Please enter the 6-digit OTP.', error: true);
      return;
    }

    if (mounted) {
      setState(() {
        isLoading = true;
        _verifying = true; // ✅ Set verification state
      });
    }

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
        if (mounted) {
          setState(() {
            isLoading = false;
            _verifying = false;
          });
        }
      }
    } on FirebaseAuthException catch (e) {
      // ✅ Better Firebase error handling
      String errorMessage = 'OTP verification failed';
      
      switch (e.code) {
        case 'invalid-verification-code':
          errorMessage = 'Invalid OTP code. Please check and try again';
          break;
        case 'session-expired':
          errorMessage = 'OTP expired. Please request a new one';
          setState(() => otpSent = false); // Allow user to request new OTP
          break;
        case 'too-many-requests':
          errorMessage = 'Too many attempts. Please try again later';
          break;
        default:
          errorMessage = e.message ?? 'OTP verification failed';
      }
      
      _showSnack(errorMessage, error: true);
      if (mounted) {
        setState(() {
          isLoading = false;
          _verifying = false;
        });
      }
    } catch (e) {
      _showSnack('OTP verification failed: $e', error: true);
      if (mounted) {
        setState(() {
          isLoading = false;
          _verifying = false;
        });
      }
    }
  }

  Future<void> _afterAuthSuccess() async {
    final user = _auth.currentUser;
    if (user == null) {
      _showSnack('User not found after auth.', error: true);
      if (mounted) {
        setState(() {
          isLoading = false;
          _verifying = false;
        });
      }
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
      if (mounted) {
        setState(() {
          isLoading = false;
          _verifying = false;
        });
      }
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
        // Update existing user data
        await userDoc.update({
          "first_name": fnameController.text.trim(),
          "last_name": lnameController.text.trim(),
          "email": emailController.text.trim(),
          "profile_image_url": imageUrl,
          "updated_at": Timestamp.now(),
        });
        _showSnack('Welcome back! Profile updated.');
      }

      if (!mounted) return;
      setState(() {
        isLoading = false;
        _verifying = false;
      });
      
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomePage()),
        (route) => false,
      );
    } catch (e) {
      _showSnack('Saving profile failed: $e', error: true);
      if (mounted) {
        setState(() {
          isLoading = false;
          _verifying = false;
        });
      }
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
                          validator: (v) =>
                              (v == null || v.trim().isEmpty) ? 'Required' : null,
                        ),
                      ),
                      _boxedField(
                        child: TextFormField(
                          controller: lnameController,
                          decoration: const InputDecoration(
                            labelText: 'Last Name',
                            border: InputBorder.none,
                          ),
                          validator: (v) =>
                              (v == null || v.trim().isEmpty) ? 'Required' : null,
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
                            if (!s.contains('@') || !s.contains('.')) {
                              return 'Invalid email';
                            }
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
                        children: avatarUrls.map((path) {
                          final selected = _selectedAvatarUrl == path;
                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedAvatarUrl = selected ? null : path;
                                if (_selectedAvatarUrl != null) {
                                  _pickedImage = null;
                                }
                              });
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: selected ? Colors.blue : Colors.transparent,
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
                        onPressed: isLoading
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
                              onChanged: (v) => setState(
                                () => _selectedCountryCode = v ?? '+971',
                              ),
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
                                validator: (v) =>
                                    (v == null || v.trim().isEmpty) ? 'Required' : null,
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
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                        ),
                        child: const Text('Send OTP'),
                      ),
                    ],

                    if (otpSent) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Enter the 6-digit OTP sent to $_selectedCountryCode${phoneController.text}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16),
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
                              controller: _otpControllers[index],
                              decoration: InputDecoration(
                                counterText: '',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              onChanged: (value) {
                                if (value.isNotEmpty && index < 5) {
                                  FocusScope.of(context).nextFocus();
                                } else if (value.isEmpty && index > 0) {
                                  FocusScope.of(context).previousFocus();
                                }
                                
                                // ✅ Auto-verify when all fields are filled
                                if (index == 5 && value.isNotEmpty) {
                                  final allFilled = _otpControllers.every((c) => c.text.isNotEmpty);
                                  if (allFilled && !_verifying) {
                                    final code = _collectOtp();
                                    _verifyOTP(code);
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
                            ),
                          );
                        }),
                      ),

                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _verifying 
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
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                        ),
                        child: _verifying 
                            ? const Text('Verifying...') 
                            : const Text('Verify OTP'),
                      ),

                      TextButton(
                        onPressed: (resendTimeout == 0 && !isLoading && !_verifying)
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