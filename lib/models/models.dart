import 'package:flutter/material.dart';

enum AlertKind { emergencySent, nearbyReceived, testSent }

enum AlertStatus { active, resolved, cancelled }

class EmergencyContact {
  final int id;
  final String name;
  final String relationship;
  final String phone;
  final String initials;
  final Color avatarColor;
  final bool enabled;

  const EmergencyContact({
    required this.id,
    required this.name,
    required this.relationship,
    required this.phone,
    required this.initials,
    required this.avatarColor,
    this.enabled = true,
  });

  EmergencyContact copyWith({bool? enabled}) => EmergencyContact(
        id: id,
        name: name,
        relationship: relationship,
        phone: phone,
        initials: initials,
        avatarColor: avatarColor,
        enabled: enabled ?? this.enabled,
      );
}

class AlertEvent {
  final int id;
  final AlertKind kind;
  final String title;
  final String timeLabel;
  final String locationLabel;
  final AlertStatus status;

  const AlertEvent({
    required this.id,
    required this.kind,
    required this.title,
    required this.timeLabel,
    required this.locationLabel,
    required this.status,
  });

  AlertEvent copyWith({AlertStatus? status}) => AlertEvent(
        id: id,
        kind: kind,
        title: title,
        timeLabel: timeLabel,
        locationLabel: locationLabel,
        status: status ?? this.status,
      );
}

class UserProfile {
  final String name;
  final String city;
  final String email;
  final String phone;

  const UserProfile({
    required this.name,
    required this.city,
    this.email = '',
    this.phone = '',
  });

  UserProfile copyWith({String? name}) => UserProfile(
        name: name ?? this.name,
        city: city,
        email: email,
        phone: phone,
      );
}

class NearbyPerson {
  final String name;
  final String distanceLabel;

  const NearbyPerson({required this.name, required this.distanceLabel});
}
