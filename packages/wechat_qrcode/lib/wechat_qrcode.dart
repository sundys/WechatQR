/// Flutter wrapper around OpenCV's WeChatQRCode engine.
///
/// Android uses the `wechat-qrcode` module from jenly1314/WeChatQRCode
/// (Apache-2.0) together with the published OpenCV Android bindings; iOS wraps
/// `cv::wechat_qrcode::WeChatQRCode` directly. See `docs/architecture.md` and
/// `docs/decisions/` in the application repository.
library;

export 'src/method_channel_wechat_qrcode.dart';
export 'src/wechat_qrcode.dart';
export 'src/wechat_qrcode_error.dart';
export 'src/wechat_qrcode_platform.dart';
