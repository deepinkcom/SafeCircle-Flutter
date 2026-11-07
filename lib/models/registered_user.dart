/// The deliberately limited result returned by registered-user discovery.
class RegisteredUser {
  const RegisteredUser({required this.name, required this.email});

  final String name;
  final String email;

  factory RegisteredUser.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final email = json['email'];
    if (name is! String || email is! String) {
      throw const FormatException('Invalid registered-user response.');
    }
    return RegisteredUser(name: name, email: email);
  }

  Map<String, dynamic> toJson() => {'name': name, 'email': email};
}
