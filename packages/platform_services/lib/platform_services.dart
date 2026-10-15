/// Native device capabilities for the QR application.
///
/// Android-backed: vibration, gallery saving and package installation
/// hand-off. On iOS everything except vibration and gallery saving reports
/// [PlatformServiceError.unsupported]; the version row opens the Releases web
/// page instead of downloading anything (project spec §3.2).
library;

export 'src/method_channel_platform_services.dart';
export 'src/platform_service_error.dart';
export 'src/platform_services.dart';
