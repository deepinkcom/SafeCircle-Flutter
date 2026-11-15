# SafeCircle – Community Safety & Emergency Alert Application

SafeCircle is a mobile safety application developed using **Flutter and Dart**, supported by a **Python FastAPI backend**, **PostgreSQL database**, **Firebase services**, and **Docker**.

The application enables users to build trusted emergency contact networks, share their location, trigger panic alerts, receive emergency notifications, and respond to emergencies involving their connections.

SafeCircle is designed to improve personal safety through real-time communication, location awareness, and community support.

**Repository:** https://github.com/deepinkcom/SafeCircle-Flutter

## 1. Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| Mobile application | Flutter + Dart | Android application and user interface |
| Backend API | Python + FastAPI | Business logic, API endpoints, alerts, contacts and device registration |
| Authentication | Firebase Authentication | Email/password registration and sign-in |
| User profiles | Cloud Firestore | Firebase user profile information |
| Application database | PostgreSQL | Persistent backend data |
| Geospatial capabilities | GPS, geocoding, mapping libraries | Location acquisition and map functionality |
| Push notifications | Firebase Cloud Messaging (FCM) | Emergency push notifications |
| Local notifications | Flutter Local Notifications | Displaying notifications on the device |
| Containerisation | Docker | Running development services and packaging backend services |
| Cloud backend hosting | Azure Container Apps (planned) | Hosting the containerised FastAPI backend |
| Cloud database | Azure Database for PostgreSQL (planned) | Managed PostgreSQL database |
| Version control | Git + GitHub | Source code management and collaboration |
| Development tools | Android Studio, VS Code, PowerShell | Development, debugging and testing |

The Flutter application communicates with the FastAPI backend through HTTP requests during local development and should use HTTPS in production.

The mobile application does not connect directly to PostgreSQL.

## 2. System Architecture

The application follows a client-server architecture.

```text
                  SAFECIRCLE
                       |
               Flutter Android App
                       |
          +------------+------------+
          |                         |
   Firebase Services          FastAPI Backend
          |                         |
   Authentication             REST API Endpoints
   Cloud Firestore            Emergency Alerts
   Cloud Messaging            Trusted Connections
   Device Notifications       Location Processing
          |                         |
          |                  PostgreSQL Database
          |                         |
          +------------+------------+
                       |
                Android Devices
```

### Component responsibilities

**Flutter Android Application**

Provides the user interface, navigation, panic activation, emergency screens, location features, connections, notifications, and profile management.

**Firebase**

Supports user authentication, profile storage where configured, and Firebase Cloud Messaging for device notifications.

**FastAPI**

Processes backend requests, validates access permissions, manages emergency workflows, and communicates with PostgreSQL.

**PostgreSQL**

Stores backend application records such as connections, emergency events, notification-related information, and other persistent data.

**Docker**

Provides a reproducible local environment for database and backend development. Docker is not required on users' Android phones.

## 3. Application Features

### 3.1 Registration and Login

SafeCircle supports account creation and authentication using Firebase Authentication.

Features include:

- Registering an account with email and password.
- Signing in with existing credentials.
- Maintaining authenticated user sessions.
- Accessing profile information.
- Updating user details.

Firebase Authentication manages credentials, while Firestore supports profile data.

### 3.2 User Profiles

Users can view and update personal information, including supported profile fields such as name, email, phone number, and city.

Profile information is managed through the application's profile and Firebase services.

### 3.3 Trusted Connections and Emergency Contacts

SafeCircle provides functionality for creating and managing a trusted safety network.

The application supports connection-related workflows such as adding contacts, managing connection requests, and maintaining accepted relationships.

The backend uses connection status when authorising certain emergency actions.

**Security requirement:** Emergency acknowledgement actions must be restricted to users with an authorised, accepted contact relationship where required by the backend.

### 3.4 Panic Button and Emergency Activation

The Panic Button is a central SafeCircle feature.

The emergency workflow includes:

1. A user opens the SafeCircle application.
2. The user activates the panic workflow.
3. The application displays the emergency confirmation interface.
4. The emergency alert is submitted to the backend.
5. The backend processes the alert and its associated recipients.
6. Relevant users can receive emergency information through supported notification and application workflows.
7. The emergency event can be tracked and subsequently resolved.

The activation interface uses a hold-to-confirm interaction to reduce accidental activation.

### 3.5 Live Location and Maps

SafeCircle integrates device location functionality using Flutter geolocation packages.

The repository includes:

- `geolocator` for device GPS coordinates.
- `geocoding` for location/address conversion.
- `flutter_map` for map rendering.
- `latlong2` for geographic coordinates and calculations.

Location-dependent features require the relevant Android permissions and an available location provider.

Location updates and emergency location sharing depend on application permissions, backend connectivity, and the implemented location lifecycle.

The current dependency configuration uses `flutter_map`; `google_maps_flutter` remains commented out.

### 3.6 Emergency Alerts

The application includes interfaces for active emergencies and nearby emergency events.

Emergency information can include the alert owner, associated location, emergency status, and supported response actions.

Emergency actions include:

- Activating an emergency.
- Viewing emergency information.
- Responding to an alert when authorised.
- Acknowledging assistance through the supported workflow.
- Marking an emergency as safe or resolved.
- Viewing historical emergency records.

Backend authorisation remains essential even when the Flutter interface hides unavailable actions.

### 3.7 Emergency Acknowledgements

The emergency response workflow includes an **"I'm On My Way"** acknowledgement action.

The backend must validate whether the responding user is authorised to acknowledge the emergency.

The interface should display or enable this action only for eligible users, and the backend must independently enforce the same restriction.

This prevents users without an accepted connection from performing protected emergency acknowledgement actions.

### 3.8 Notifications

SafeCircle uses Firebase Cloud Messaging and Flutter Local Notifications dependencies.

The notification architecture supports:

- Device registration for notification delivery.
- Emergency notification workflows.
- Notification presentation on Android.
- Notification-related backend processing.
- Application navigation associated with supported notifications.

Actual push delivery depends on valid Firebase configuration, Android notification permissions, device registration, and backend integration.

### 3.9 Alert History

The application includes an alert history interface with categories for:

- All alerts.
- Sent alerts.
- Received alerts.

This enables users to review emergency activity associated with their accounts, subject to backend access permissions.

## 4. Application Screens

The SafeCircle application includes the following main screens:

| Screen | Description |
|---|---|
| Welcome | Application introduction |
| Login | User authentication |
| Register | New account creation |
| Home | Dashboard and panic button |
| Activate Panic Alert | Emergency activation confirmation |
| Emergency Active | Active emergency information and location |
| Emergency Nearby | Emergency involving another user |
| Emergency Contacts / Connections | Trusted contact management |
| Notifications | Notification information |
| Alert History | Previous emergency activity |
| Profile & Settings | User information and settings |

## 5. Repository Structure

The repository contains the Flutter application and backend-related source files.

```text
SafeCircle-Flutter/
|
|-- android/             Android platform project
|-- ios/                 iOS platform project
|-- linux/               Linux platform project
|-- macos/               macOS platform project
|-- windows/             Windows platform project
|-- web/                 Web platform project
|
|-- lib/                 Flutter application source
|   |-- screens/         Application screens
|   |-- services/        API, authentication and other services
|   |-- widgets/         Reusable interface components
|
|-- backend/             Backend implementation and configuration
|-- test/                Flutter tests
|-- docs/                Project documentation
|-- tools/               Development utilities
|-- assets/
|   |-- branding/        Application branding assets
|
|-- pubspec.yaml         Flutter dependencies
|-- pubspec.lock         Resolved dependency versions
|-- firebase.json        Firebase project configuration
|-- firestore.rules      Firestore security rules
|-- storage.rules        Firebase Storage security rules
|-- analysis_options.yaml
|-- README.md
```

The repository already includes generated platform folders. Running `flutter create .` is therefore not a normal setup requirement.

## 6. Development Requirements

Before running SafeCircle locally, install:

- Flutter SDK with a compatible Dart SDK.
- Android Studio or Visual Studio Code.
- Android SDK and Android emulator, or a physical Android device.
- Python and the backend's required dependencies.
- Docker Desktop with Docker Compose support.
- Git.
- Firebase project configuration.

For cloud deployment, an Azure subscription and the relevant Azure resources are also required.

### Check installed tools

```powershell
flutter doctor
flutter --version
python --version
docker --version
docker compose version
git --version
```

Resolve any missing SDK or dependency requirements before continuing.

## 7. Clone and Configure the Project

Clone the repository:

```powershell
git clone https://github.com/deepinkcom/SafeCircle-Flutter.git
```

Navigate to the project:

```powershell
cd SafeCircle-Flutter
```

Install Flutter dependencies:

```powershell
flutter pub get
```

Verify the Flutter project:

```powershell
flutter analyze
```

Run the available Flutter tests:

```powershell
flutter test
```

## 8. Firebase Configuration

SafeCircle uses Firebase services for authentication and other mobile application functionality.

A configured Firebase project is required for Firebase-dependent features.

### Firebase setup

1. Create or select a Firebase project.
2. Enable Email/Password authentication.
3. Configure Cloud Firestore where required.
4. Configure Firebase Cloud Messaging.
5. Register the Android application with Firebase.
6. Configure the application using FlutterFire.
7. Deploy appropriate Firestore and Storage security rules.

Where Firebase configuration needs to be generated:

```powershell
dart pub global activate flutterfire_cli
flutterfire configure
```

Deploy Firestore rules when Firebase CLI access is configured:

```powershell
firebase deploy --only firestore:rules
```

Do not expose Firebase service-account private keys or backend secrets in the repository.

## 9. PostgreSQL and Docker

SafeCircle uses PostgreSQL for backend persistence.

During local development, Docker can run PostgreSQL in a container.

The database stores backend application records and is accessed by FastAPI rather than directly by the Flutter application.

### Start local database services

Start Docker Desktop.

From the directory containing the project's Docker Compose configuration, run:

```powershell
docker compose up -d
```

Inspect running containers:

```powershell
docker ps
```

Inspect container logs:

```powershell
docker compose logs
```

Stop Compose services:

```powershell
docker compose down
```

**Important:** Avoid using `docker compose down -v` unless you intentionally want to remove associated persistent volumes.

Database credentials and connection strings must be configured according to the backend's environment settings.

## 10. FastAPI Backend

FastAPI provides the server-side application functionality.

Backend responsibilities include:

- Handling REST API requests.
- Validating authenticated requests.
- Managing connections and emergency contacts.
- Processing emergency alerts.
- Handling emergency acknowledgements.
- Enforcing access-control rules.
- Managing notification-related operations.
- Processing location-related information.
- Reading and writing PostgreSQL data.

### Local backend startup

The exact Python module and dependency installation commands depend on the files in `backend/`.

A typical FastAPI development workflow uses a Python virtual environment and Uvicorn.

For example, after installing the project's declared backend dependencies, a FastAPI application exposed as `app` in `main.py` can be started using:

```powershell
python -m uvicorn main:app --reload
```

Run this from the appropriate backend module directory. Adjust the module path to match the actual repository implementation.

When running locally, a backend configured on port 8000 is typically accessible at:

```text
http://127.0.0.1:8000
```

FastAPI's interactive documentation is typically available at:

```text
http://127.0.0.1:8000/docs
```

These addresses assume the backend is configured to use port 8000.

## 11. Connect Flutter to FastAPI

The Flutter application must use a backend URL reachable from the device on which it runs.

Examples:

| Environment | Example backend address |
|---|---|
| Local development computer | `http://127.0.0.1:8000` |
| Android emulator | `http://10.0.2.2:8000` |
| Physical Android phone | `http://<development-computer-LAN-IP>:8000` |
| Azure production | `https://<deployed-api-domain>` |

The local addresses are examples and must match the actual backend configuration.

For a physical Android device, the computer and phone must have network connectivity, and the backend must listen on an accessible network interface.

Configure the application API base URL through the existing project configuration.

Production builds should use HTTPS.

**The APK alone does not provide the FastAPI backend or PostgreSQL database.** Features that depend on backend services require a reachable running server.

## 12. Run the Android Application

Start the required backend and database services before testing backend-dependent features.

Connect an Android device or launch an emulator.

Check connected devices:

```powershell
flutter devices
```

Run the application:

```powershell
flutter run
```

For a release APK:

```powershell
flutter build apk --release
```

The standard Flutter release output is:

```text
build/app/outputs/flutter-apk/app-release.apk
```

The generated APK can be installed on a compatible Android device.

Ensure the release application has valid Firebase configuration, permissions, and a reachable backend URL.

## 13. Azure Cloud Deployment

SafeCircle's proposed cloud deployment uses Microsoft Azure.

**Deployment status:** Azure hosting is a target architecture and should not be considered operational until provisioning, deployment, connectivity, and end-to-end testing are completed.

### Proposed Azure architecture

```text
              Android Users
                    |
             SafeCircle APK
                    |
               HTTPS API
                    |
          Azure Container Apps
                    |
             FastAPI Backend
                    |
       Azure Database for PostgreSQL
                    |
          Persistent Application Data
```

Firebase Authentication and Firebase Cloud Messaging remain separate services integrated with the application and backend.

### Azure Container Apps

Azure Container Apps is the proposed hosting platform for the Dockerised FastAPI backend.

Benefits include:

- Managed container hosting.
- HTTPS ingress.
- Container image deployment.
- Environment variable and secret configuration.
- Application scaling.
- Logging and monitoring integration.

### Azure Database for PostgreSQL

Azure Database for PostgreSQL Flexible Server is the proposed managed database service.

The deployment should include:

- A dedicated PostgreSQL database.
- Secure database credentials.
- TLS-protected connections.
- Appropriate network restrictions.
- Database migrations.
- Backup and recovery configuration.
- PostGIS where required by the application's geospatial queries.

### Docker's role in Azure

Docker remains useful for building and testing the FastAPI container image.

The image can be published to Azure Container Registry and deployed to Azure Container Apps.

PostgreSQL should run in Azure Database for PostgreSQL rather than relying on a development database container for production persistence.

Users do not need Docker installed on their Android devices.

### Production configuration

Before deployment:

1. Containerise and validate the FastAPI backend.
2. Provision Azure Container Registry.
3. Provision Azure Container Apps.
4. Provision Azure Database for PostgreSQL.
5. Configure database connectivity and migrations.
6. Configure secrets and environment variables.
7. Configure Firebase credentials and notification integration.
8. Enable HTTPS and appropriate access restrictions.
9. Update the Flutter application API URL.
10. Build and test the Android release APK.
11. Verify registration, connections, location, emergency alerts, notifications, and emergency acknowledgements.

## 14. Testing and Verification

SafeCircle should be tested at both frontend and backend levels.

### Flutter checks

```powershell
flutter analyze
flutter test
```

### Backend checks

Run the backend's configured test suite with its required test environment and database services.

For a backend configured with pytest:

```powershell
python -m pytest
```

### End-to-end scenarios

Important scenarios include:

- Registering and signing in.
- Updating profile information.
- Sending and accepting connection requests.
- Managing emergency contacts.
- Activating a panic alert.
- Recording an emergency in the database.
- Receiving an emergency notification.
- Viewing emergency location information.
- Acknowledging an emergency as an authorised connection.
- Rejecting unauthorised emergency acknowledgements.
- Resolving an emergency.
- Viewing alert history.

Testing should include multiple user accounts and, where possible, multiple physical Android devices.

## 15. Security Considerations

SafeCircle handles sensitive personal and location information.

Security controls should include:

- Firebase authentication verification.
- Backend authorisation for protected endpoints.
- Connection-based access restrictions.
- HTTPS for production API communication.
- Secure database credentials.
- Restricted database network access.
- Appropriate Firebase security rules.
- Android runtime permission handling.
- Secure storage and handling of notification tokens.
- Protection against unauthorised emergency acknowledgements.
- Avoidance of sensitive data in logs.
- Controlled retention of location and emergency data.

Frontend restrictions alone are not sufficient security controls. The FastAPI backend must independently validate access permissions.

## 16. Current Development and Deployment Status

| Component | Status |
|---|---|
| Flutter application | Developed; ongoing improvements |
| Firebase Authentication | Integrated into application architecture |
| Firebase profile services | Included |
| FastAPI backend | Backend implementation included |
| PostgreSQL | Local development database architecture |
| Docker | Local development infrastructure |
| Emergency alert workflows | Implemented/in active verification |
| Connection management | Implemented/in active verification |
| Emergency acknowledgement authorisation | Backend enforcement; frontend alignment under verification |
| Location and maps | Location and mapping dependencies included |
| Firebase messaging | Dependencies included; delivery requires configuration and testing |
| Android APK | Build supported; environment configuration required |
| Azure Container Apps | Planned deployment |
| Azure Database for PostgreSQL | Planned deployment |
| Production readiness | Pending deployment and end-to-end verification |

## 17. Future Improvements

Development priorities include:

- Completing emergency response interface and backend authorisation alignment.
- Validating notification delivery across physical devices.
- Improving location update reliability.
- Completing automated backend and Flutter regression tests.
- Deploying FastAPI to Azure Container Apps.
- Migrating PostgreSQL to Azure Database for PostgreSQL.
- Configuring production HTTPS, monitoring, backups, and secrets.
- Testing release APK connectivity against Azure.
- Improving performance, accessibility, and application reliability.

## 18. Important Limitations

SafeCircle is a safety-support application and is not a replacement for official emergency services.

Emergency notifications depend on factors including internet connectivity, Android permissions, Firebase configuration, backend availability, and device state.

Location accuracy depends on GPS availability, device settings, and environmental conditions.

Users should contact official emergency services directly whenever immediate assistance is required.

## 19. Project Information

**Project:** SafeCircle

**Application type:** Community Safety and Emergency Alert Mobile Application

**Frontend:** Flutter / Dart

**Backend:** Python / FastAPI

**Database:** PostgreSQL

**Authentication and messaging:** Firebase

**Development infrastructure:** Docker

**Planned cloud hosting:** Microsoft Azure

**Source code:** https://github.com/deepinkcom/SafeCircle-Flutter

SafeCircle is developed as a community safety solution focused on trusted connections, emergency communication, location awareness, and accessible mobile safety functionality.
