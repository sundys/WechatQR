import 'package:platform_services/platform_services.dart';
import 'package:wechat_qrcode/wechat_qrcode.dart';

import '../services/release_service.dart';

/// Turns typed failures into the short, specific messages the user sees.
///
/// Keeping the mapping in one place means a new error code cannot silently fall
/// through to a generic "something went wrong" (project spec §4.7).
abstract final class ErrorMessages {
  static String forEngine(WeChatQrCodeException error) => switch (error.code) {
    WeChatQrCodeError.notInitialized => '二维码引擎尚未就绪，请稍后重试',
    WeChatQrCodeError.modelLoadFailed => '二维码引擎初始化失败，请重试',
    WeChatQrCodeError.cameraPermissionDenied => '未获得相机权限，无法扫码',
    WeChatQrCodeError.cameraPermissionPermanentlyDenied => '相机权限已被拒绝，请在系统设置中开启',
    WeChatQrCodeError.cameraUnavailable => '无法启动相机，可能被其他应用占用',
    WeChatQrCodeError.invalidImage => '图片无法读取，请选择其他图片',
    WeChatQrCodeError.unsupportedImageFormat => '不支持该图片格式',
    WeChatQrCodeError.decodeFailed => '识别失败，请重试',
    WeChatQrCodeError.unsupportedPlatform => '当前平台不支持二维码识别',
  };

  static String forPlatform(PlatformServiceException error) =>
      switch (error.code) {
        PlatformServiceError.unsupported => '当前平台不支持该操作',
        PlatformServiceError.permissionDenied => '权限被拒绝，无法完成操作',
        PlatformServiceError.installPermissionMissing => '需要允许“安装未知应用”才能安装更新',
        PlatformServiceError.saveFailed => '保存失败，请重试',
        PlatformServiceError.fileNotFound => '安装包不存在，请重新下载',
        PlatformServiceError.installFailed => '无法启动安装程序',
      };

  static String forReleaseCheck(ReleaseCheckException error) =>
      switch (error.failure) {
        ReleaseCheckFailure.notConfigured => '尚未配置更新仓库地址',
        ReleaseCheckFailure.networkUnavailable => '网络不可用，无法检查更新',
        ReleaseCheckFailure.rateLimited => '请求过于频繁，请稍后再试',
        ReleaseCheckFailure.notFound => '未找到发布仓库或该仓库暂无 Release',
        ReleaseCheckFailure.httpError =>
          '检查更新失败（HTTP ${error.statusCode ?? '未知'}）',
        ReleaseCheckFailure.malformedResponse => '更新信息格式异常，无法解析',
      };
}
