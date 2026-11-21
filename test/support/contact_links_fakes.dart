import 'package:safecircle/models/contact_link.dart';
import 'package:safecircle/models/backend_profile_status.dart';
import 'package:safecircle/models/models.dart';
import 'package:safecircle/models/registered_user.dart';
import 'package:safecircle/services/api_service.dart';
import 'package:safecircle/services/auth_service.dart';

ContactLink testLink(int id, String status, {bool incoming = true}) =>
    ContactLink(
      id: id,
      inviterUserId: incoming ? 2 : 1,
      inviteeUserId: incoming ? 1 : 2,
      otherUserId: 2,
      rawStatus: status,
      createdAt: DateTime.utc(2026, 11, 7),
      updatedAt: DateTime.utc(2026, 11, 7, 1),
      otherUser: const ContactLinkUser(
        id: 2,
        name: 'Example Member',
        email: 'member@example.invalid',
      ),
    );

UserProfile testProfile(String uid) => UserProfile(
      uid: uid,
      name: 'Example $uid',
      email: '$uid@example.invalid',
      city: 'Test City',
      phone: '0000000000',
    );

class ContactLinksFakeApi extends ApiService {
  Future<BackendProfileStatus> Function()? onProfileStatus;
  int profileStatusReads = 0;
  Future<Map<String, dynamic>> Function(int)? onAlertLocation;

  @override
  Future<Map<String, dynamic>> fetchAlertLocation(int alertId) async =>
      onAlertLocation != null
          ? onAlertLocation!(alertId)
          : {
              'id': alertId,
              'owner_user_id': 1,
              'status': 'active',
              'latitude': -33.9,
              'longitude': 18.4,
              'created_at': '2026-11-16T10:00:00Z',
            };

  @override
  Future<BackendProfileStatus> fetchMyProfileStatus() async {
    profileStatusReads++;
    return onProfileStatus != null
        ? await onProfileStatus!()
        : const BackendProfileStatus(
            id: 1, profileReady: true, missingFields: []);
  }

  List<RegisteredUser> searchData = const [
    RegisteredUser(name: 'Example Member', email: 'member@example.invalid'),
  ];
  List<ContactLink> incomingData = [];
  List<ContactLink> outgoingData = [];
  List<ContactLink> acceptedData = [];
  int searchCalls = 0;
  int incomingCalls = 0;
  int outgoingCalls = 0;
  int acceptedCalls = 0;
  int sendCalls = 0;
  final List<(int, ContactInvitationAction)> responses = [];
  final List<int> revocations = [];
  Future<List<RegisteredUser>> Function(String)? onSearch;
  Future<List<ContactLink>> Function()? onIncoming;
  Future<List<ContactLink>> Function()? onOutgoing;
  Future<List<ContactLink>> Function()? onAccepted;
  Future<ContactLink> Function(String)? onSend;
  Future<ContactLink> Function(int, ContactInvitationAction)? onRespond;
  Future<ContactLink> Function(int)? onRevoke;

  @override
  Future<List<RegisteredUser>> searchRegisteredUsers(
      {required String email}) async {
    searchCalls++;
    return onSearch != null ? await onSearch!(email) : List.of(searchData);
  }

  @override
  Future<List<ContactLink>> fetchIncomingInvitations() async {
    incomingCalls++;
    return onIncoming != null ? await onIncoming!() : List.of(incomingData);
  }

  @override
  Future<List<ContactLink>> fetchOutgoingInvitations() async {
    outgoingCalls++;
    return onOutgoing != null ? await onOutgoing!() : List.of(outgoingData);
  }

  @override
  Future<List<ContactLink>> fetchContactRelationships() async {
    acceptedCalls++;
    return onAccepted != null ? await onAccepted!() : List.of(acceptedData);
  }

  @override
  Future<ContactLink> sendContactInvitation({required String email}) async {
    sendCalls++;
    return onSend != null
        ? await onSend!(email)
        : testLink(7, 'pending', incoming: false);
  }

  @override
  Future<ContactLink> respondToContactInvitation(
      {required int linkId, required ContactInvitationAction action}) async {
    responses.add((linkId, action));
    return onRespond != null
        ? await onRespond!(linkId, action)
        : testLink(linkId,
            action == ContactInvitationAction.accept ? 'accepted' : 'rejected');
  }

  @override
  Future<ContactLink> revokeContactRelationship({required int linkId}) async {
    revocations.add(linkId);
    return onRevoke != null
        ? await onRevoke!(linkId)
        : testLink(linkId, 'revoked');
  }

  int profileSyncs = 0;

  @override
  Future<Map<String, dynamic>> syncMyProfile(
      {required String name,
      required String city,
      required String phone}) async {
    profileSyncs++;
    return {'id': 1};
  }
}

class ContactLinksFakeAuth extends AuthService {
  Future<UserProfile?> Function()? onRestore;
  Future<UserProfile> Function()? onLogin;
  Future<UserProfile> Function()? onSignUp;
  Future<void> Function()? onLogout;
  Future<UserProfile> Function(UserProfile)? onUpdate;

  @override
  Future<UserProfile?> restoreProfile() async =>
      onRestore != null ? await onRestore!() : testProfile('alice');

  @override
  Future<UserProfile> logIn(
          {required String email, required String password}) async =>
      onLogin != null ? await onLogin!() : testProfile('alice');

  @override
  Future<UserProfile> signUp(
          {required String fullName,
          required String email,
          required String phone,
          required String password}) async =>
      onSignUp != null ? await onSignUp!() : testProfile('alice');

  @override
  Future<void> logOut() async {
    await onLogout?.call();
  }

  @override
  Future<UserProfile> updateProfile(UserProfile profile) async =>
      onUpdate != null ? await onUpdate!(profile) : profile;
}
