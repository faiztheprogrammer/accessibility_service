import 'package:shared_preferences/shared_preferences.dart';
import 'db_service.dart';

class AuthService {
  static const _keyUserId = 'auth_user_id';
  static const _keyUserName = 'auth_user_name';
  static const _keyUserEmail = 'auth_user_email';

  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<Map<String, dynamic>?> currentUser() async {
    final prefs = await _prefs;
    final id = prefs.getInt(_keyUserId);
    if (id == null) return null;
    return {
      'id': id,
      'name': prefs.getString(_keyUserName) ?? '',
      'email': prefs.getString(_keyUserEmail) ?? '',
    };
  }

  Future<bool> isLoggedIn() async => (await currentUser()) != null;

  Future<String> currentUserId() async {
    final prefs = await _prefs;
    final id = prefs.getInt(_keyUserId);
    return id != null ? id.toString() : 'default_user';
  }

  Future<String?> register({
    required String name,
    required String email,
    required String password,
  }) async {
    if (name.trim().isEmpty) return 'Name is required.';
    if (!_isValidEmail(email)) return 'Enter a valid email address.';
    if (password.length < 6) return 'Password must be at least 6 characters.';

    final user = await DatabaseService().registerUser(
      name: name,
      email: email,
      password: password,
    );
    if (user == null) return 'An account with this email already exists.';

    await _persistSession(user);
    return null;
  }

  Future<String?> login({
    required String email,
    required String password,
  }) async {
    if (!_isValidEmail(email)) return 'Enter a valid email address.';
    if (password.isEmpty) return 'Password is required.';

    final user = await DatabaseService().loginUser(
      email: email,
      password: password,
    );
    if (user == null) return 'Incorrect email or password.';

    await _persistSession(user);
    return null;
  }

  Future<void> logout() async {
    final prefs = await _prefs;
    await prefs.remove(_keyUserId);
    await prefs.remove(_keyUserName);
    await prefs.remove(_keyUserEmail);
  }

  Future<void> _persistSession(Map<String, dynamic> user) async {
    final prefs = await _prefs;
    await prefs.setInt(_keyUserId, user['id'] as int);
    await prefs.setString(_keyUserName, user['name']?.toString() ?? '');
    await prefs.setString(_keyUserEmail, user['email']?.toString() ?? '');
  }

  bool _isValidEmail(String email) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim());
  }
}
