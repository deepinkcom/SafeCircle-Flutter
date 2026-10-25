
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/models.dart';

class RealMap extends StatefulWidget {
  const RealMap({
    super.key,
    this.nearbyPerson,
  });

  final NearbyPerson? nearbyPerson;

  @override
  State<RealMap> createState() => _RealMapState();
}

class _RealMapState extends State<RealMap> {
  final MapController _mapController = MapController();

  LatLng? _currentLocation;
  String? _errorMessage;
  bool _isLoading = true;

  LatLng? get _emergencyLocation {
    final person = widget.nearbyPerson;

    if (person == null || !person.hasValidLocation) {
      return null;
    }

    return LatLng(
      person.latitude!,
      person.longitude!,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadCurrentLocation();
  }

  Future<void> _loadCurrentLocation() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final serviceEnabled =
      await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        throw Exception('Location services are disabled.');
      }

      LocationPermission permission =
      await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        throw Exception('Location permission was denied.');
      }

      if (permission == LocationPermission.deniedForever) {
        throw Exception(
          'Location permission is permanently denied. '
              'Enable it in your device settings.',
        );
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 20));

      if (!mounted) return;

      setState(() {
        _currentLocation = LatLng(
          position.latitude,
          position.longitude,
        );
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _errorMessage = error.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.location_off,
                color: Colors.red,
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
              ),
              TextButton(
                onPressed: _loadCurrentLocation,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final myLocation = _currentLocation!;
    final emergencyLocation = _emergencyLocation;

    final markers = <Marker>[
      Marker(
        point: myLocation,
        width: 50,
        height: 50,
        child: const Icon(
          Icons.my_location,
          color: Colors.blue,
          size: 36,
        ),
      ),
    ];

    if (emergencyLocation != null) {
      markers.add(
        Marker(
          point: emergencyLocation,
          width: 50,
          height: 50,
          child: const Icon(
            Icons.location_on,
            color: Colors.red,
            size: 42,
          ),
        ),
      );
    }

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: emergencyLocation ?? myLocation,
        initialZoom: 15,
      ),
      children: [
        TileLayer(
          urlTemplate:
          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.safecircle.app',
        ),
        MarkerLayer(
          markers: markers,
        ),
        const RichAttributionWidget(
          attributions: [
            TextSourceAttribution(
              'OpenStreetMap contributors',
            ),
          ],
        ),
      ],
    );
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }
}
