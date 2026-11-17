/// The signed-in account as the rest of the app sees it.
class AuthUser {
  const AuthUser({required this.uid, this.email});

  final String uid;
  final String? email;
}

class AuthFailure implements Exception {
  const AuthFailure(this.code, this.message);

  /// The provider's code, for example `invalid-credential`.
  final String code;

  /// Text that is safe to show. It never contains the password.
  final String message;
}

/// Identity service. The app talks to this interface so the state machine can
/// be unit tested without Firebase.
abstract class AuthGateway {
  /// Emits the current user (or null) on listen and on every change.
  Stream<AuthUser?> get userChanges;

  Future<void> signIn(String email, String password);

  Future<void> signOut();
}

/// Maps a Firebase Authentication error code to a visible message.
String authErrorMessage(String code) {
  switch (code) {
    case 'invalid-credential':
    case 'wrong-password':
    case 'user-not-found':
    case 'INVALID_LOGIN_CREDENTIALS':
      return 'Email or password is incorrect.';
    case 'invalid-email':
      return 'That email address is not valid.';
    case 'user-disabled':
      return 'This account has been disabled.';
    case 'too-many-requests':
      return 'Too many attempts. Wait a minute, then try again.';
    case 'network-request-failed':
      return 'No connection to the sign-in service. Check the network.';
    case 'operation-not-allowed':
      return 'Email/password sign-in is not enabled for this project.';
    case 'channel-error':
      return 'Enter both an email and a password.';
    default:
      return 'Sign-in failed ($code).';
  }
}
