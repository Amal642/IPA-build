import 'dart:io';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:pin_code_fields/pin_code_fields.dart';
import 'package:fitnesschallenge/pages/home_page.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:fitnesschallenge/pages/login_page.dart';

class LoginSignupPage extends StatefulWidget {
  const LoginSignupPage({super.key});
  @override
  _LoginSignupPageState createState() => _LoginSignupPageState();
}

class _LoginSignupPageState extends State<LoginSignupPage> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  File? _pickedImage;
  String? _selectedAvatarUrl;

  String _selectedCountryCode = '+971';
  
  final List<String> avatarUrls = [
    //TODO: Add your avatar image URLs here
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
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController otpController = TextEditingController();
  final TextEditingController fnameController = TextEditingController();
  final TextEditingController lnameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();

  String? verificationId;
  int? forceResendingToken;
  bool otpSent = false;
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
      // ✅ Check if user already exists in Firestore
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('phone', isEqualTo: fullPhone)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        // ✅ User exists, redirect to login
        Fluttertoast.showToast(msg: "User already exists. Please log in.");
        setState(() => isLoading = false);
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => LoginPage()),
        );
        // Or use your route
        return;
      }

      // ✅ If user does NOT exist, continue sending OTP
      await _auth.verifyPhoneNumber(
        phoneNumber: fullPhone,
        timeout: const Duration(seconds: 60),
        forceResendingToken: forceResendingToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          await _auth.signInWithCredential(credential);
          _onLoginSuccess();
        },
        verificationFailed: (FirebaseAuthException e) {
          Fluttertoast.showToast(msg: e.message ?? "Verification failed");
          setState(() => isLoading = false);
        },
        codeSent: (String verId, resendToken) {
          setState(() {
            verificationId = verId;
            otpSent = true;
            isLoading = false;
            forceResendingToken = resendToken; // Store the resend token
          });
          _startResendTimer();
          Fluttertoast.showToast(msg: "OTP sent");
        },
        codeAutoRetrievalTimeout: (String verId) {
          verificationId = verId;
        },
      );
    } catch (e) {
      Fluttertoast.showToast(msg: "Error: ${e.toString()}");
      setState(() => isLoading = false);
    }
  }

  Future<void> _verifyOTP() async {
    if (verificationId == null || otpController.text.length != 6) return;

    setState(() => isLoading = true);
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId!,
        smsCode: otpController.text.trim(),
      );

      final UserCredential result = await _auth.signInWithCredential(
        credential,
      );

      if (result.user != null) {
        _onLoginSuccess();
      }
    } catch (e) {
      Fluttertoast.showToast(msg: "OTP verification failed : $e");
      setState(() => isLoading = false);
    }
  }

  Future<void> _onLoginSuccess() async {
    final user = _auth.currentUser;
    if (user == null) return;

    String? imageUrl;

    if (_pickedImage != null) {
      final ref = FirebaseStorage.instance.ref(
        'user_uploads/${user.uid}/profile.jpg',
      );
      await ref.putFile(_pickedImage!);
      imageUrl = await ref.getDownloadURL();
    } else if (_selectedAvatarUrl != null) {
      //TODO: Replace with your Firebase Storage URL

      imageUrl = _selectedAvatarUrl!;
    }
    if (imageUrl != null) {
    DocumentSnapshot doc =
        await _firestore.collection("users").doc(user.uid).get();

    if (!doc.exists) {
      // New user, save details
      await _firestore.collection("users").doc(user.uid).set({
        "uid": user.uid,
        "phone": user.phoneNumber,
        "first_name": fnameController.text.trim(),
        "last_name": lnameController.text.trim(),
        "email": emailController.text.trim(),
        "profile_image_url": imageUrl,
        "created_at": Timestamp.now(),
        "total_steps": 0,
        "total_kms": 0.0,
      });
    }

    setState(() => isLoading = false);
    Fluttertoast.showToast(msg: "Sign Up Success");
    // Navigate to dashboard or home screen
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => HomePage()),
    );
  }else {
    Fluttertoast.showToast(msg: "Please select an image or avatar.");
  }
}

  @override
  void dispose() {
    _resendTimer?.cancel();
    otpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Sign Up")),
      body:
          isLoading
              ? Center(child: CircularProgressIndicator())
              : Center(
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
                        Text(
                          "Enter your details to sign up",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (!otpSent) ...[
                          // First Name
                          Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey),
                            ),
                            child: TextFormField(
                              controller: fnameController,
                              decoration: InputDecoration(
                                labelText: "First Name",
                                border: InputBorder.none,
                              ),
                              validator:
                                  (v) =>
                                      v == null || v.isEmpty
                                          ? "Required"
                                          : null,
                            ),
                          ),
                          // Last Name
                          Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey),
                            ),
                            child: TextFormField(
                              controller: lnameController,
                              decoration: InputDecoration(
                                labelText: "Last Name",
                                border: InputBorder.none,
                              ),
                              validator:
                                  (v) =>
                                      v == null || v.isEmpty
                                          ? "Required"
                                          : null,
                            ),
                          ),
                          // Email
                          Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey),
                            ),
                            child: TextFormField(
                              controller: emailController,
                              decoration: InputDecoration(
                                labelText: "Email",
                                border: InputBorder.none,
                              ),
                              validator:
                                  (v) =>
                                      v == null || !v.contains('@')
                                          ? "Invalid email"
                                          : null,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            "Choose Profile Picture",
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children:
                                avatarUrls.map((path) {
                                  return GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        if (_selectedAvatarUrl == path) {
                                          _selectedAvatarUrl =
                                              null; // deselect if already selected
                                        } else {
                                          _selectedAvatarUrl = path;
                                          _pickedImage =
                                              null; // deselect gallery image
                                        }
                                      });
                                    },

                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color:
                                              _selectedAvatarUrl == path
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

                          Row(
                            children: <Widget>[
                              Expanded(child: Divider(thickness: 1)),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Text("OR"),
                              ),
                              Expanded(child: Divider(thickness: 1)),
                            ],
                          ),

                          const SizedBox(height: 12),

                          TextButton.icon(
                            icon: Icon(Icons.photo),
                            label: Text("Pick from Gallery"),
                            onPressed: () async {
                              final picker = ImagePicker();
                              final picked = await picker.pickImage(
                                source: ImageSource.gallery,
                              );
                              if (picked != null) {
                                setState(() {
                                  _pickedImage = File(picked.path);
                                  _selectedAvatarUrl = null;
                                });
                              }
                            },
                          ),

                          if (_pickedImage != null)
                            Stack(
                              alignment: Alignment.topRight,
                              children: [
                                CircleAvatar(
                                  backgroundImage: FileImage(_pickedImage!),
                                  radius: 40,
                                ),
                                Positioned(
                                  right: 0,
                                  child: GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        _pickedImage = null;
                                      });
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.red,
                                        shape: BoxShape.circle,
                                      ),
                                      padding: EdgeInsets.all(4),
                                      child: Icon(
                                        Icons.close,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                          const SizedBox(height: 16),
                          // Phone Number (Boxed)
                          Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
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
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: () {
                              if (_formKey.currentState!.validate()) {
                                _sendOTP();
                              }
                            },
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
                        if (otpSent) ...[
                          const SizedBox(height: 16),
                          Text(
                            "Enter the 6-digit OTP sent to ${phoneController.text}",
                          ),
                          const SizedBox(height: 8),
                          PinCodeTextField(
                            appContext: context,
                            controller: otpController,
                            autoDisposeControllers: false,
                            length: 6,
                            onChanged: (_) {},
                            keyboardType: TextInputType.number,
                            pinTheme: PinTheme(
                              shape: PinCodeFieldShape.box,
                              borderRadius: BorderRadius.circular(5),
                              fieldHeight: 50,
                              fieldWidth: 40,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ElevatedButton(
                            onPressed: _verifyOTP,
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
                            child: Text("Verify OTP"),
                          ),
                          const SizedBox(height: 10),
                          TextButton(
                            onPressed: resendTimeout == 0 ? _sendOTP : null,
                            child: Text(
                              resendTimeout == 0
                                  ? "Resend OTP"
                                  : "Resend in $resendTimeout sec",
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
    );
  }
}
