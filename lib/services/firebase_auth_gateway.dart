import 'package:firebase_auth/firebase_auth.dart';

import 'auth_gateway.dart';

/// Firebase Authentication with email and password.
class FirebaseAuthGateway implements AuthGateway {
  FirebaseAuthGateway([FirebaseAuth? auth])
      : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  @override
  Stream<AuthUser?> get userChanges => _auth.authStateChanges().map(
        (user) =>
            user == null ? null : AuthUser(uid: user.uid, email: user.email),
      );

  @override
  Future<void> signIn(String email, String password) async {
    try {
      // The password goes straight from the form to Firebase. It is never
      // stored, logged or kept after this call.
      await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(e.code, authErrorMessage(e.code));
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();
}
