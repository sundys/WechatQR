import 'package:flutter/foundation.dart';

/// One third-party component the app ships, with the licence it is used under.
class ThirdPartyComponent {
  const ThirdPartyComponent({
    required this.name,
    required this.version,
    required this.license,
    required this.copyright,
    required this.purpose,
  });

  final String name;
  final String version;

  /// SPDX-style identifier as verified against the component's own licence file.
  final String license;
  final String copyright;

  /// What the app uses it for, so the entry describes real usage.
  final String purpose;
}

/// Components bundled into the shipped application.
///
/// This list covers what the app actually links against. Flutter's own licence
/// page (opened from [ThirdPartyNotices.register]) renders the complete,
/// machine-collected set of Dart and plugin licences, including transitive ones.
abstract final class ThirdPartyNotices {
  static const List<ThirdPartyComponent> components = <ThirdPartyComponent>[
    ThirdPartyComponent(
      name: 'WeChatQRCode (wechat-qrcode module)',
      version: '2.6.0',
      license: 'Apache-2.0',
      copyright: 'Copyright (C) Jenly Yu (jenly1314)',
      purpose: '二维码检测器封装与相机帧分析器（已按本项目需要修改）',
    ),
    ThirdPartyComponent(
      name: 'WeChat QRCode engine and CNN models',
      version: 'opencv_3rdparty @ a8b69ccc',
      license: 'Apache-2.0',
      copyright: 'Copyright (C) 2021 THL A29 Limited, a Tencent company',
      purpose: 'QR 检测 CNN 模型、超分辨率模型及解码引擎',
    ),
    ThirdPartyComponent(
      name: 'OpenCV',
      version: '4.12.0',
      license: 'Apache-2.0',
      copyright: 'Copyright (C) OpenCV Foundation',
      purpose:
          'WeChat QRCode 引擎所必需的底层库（core / imgproc / objdetect / dnn）；'
          '本项目不调用其他 OpenCV 模块',
    ),
    ThirdPartyComponent(
      name: 'CameraScan',
      version: '1.5.0',
      license: 'Apache-2.0',
      copyright: 'Copyright (C) Jenly Yu (jenly1314)',
      purpose: '相机帧分析接口（Analyzer）与 NV21 转换工具',
    ),
    ThirdPartyComponent(
      name: 'ViewfinderView',
      version: '1.4.0',
      license: 'Apache-2.0',
      copyright: 'Copyright (C) Jenly Yu (jenly1314)',
      purpose: '扫码取景框与上下滚动的扫描线动画',
    ),
    ThirdPartyComponent(
      name: 'LogX',
      version: '1.3.0',
      license: 'Apache-2.0',
      copyright: 'Copyright (C) Jenly Yu (jenly1314)',
      purpose: 'Android 端日志输出（由 CameraScan 传递引入）',
    ),
    ThirdPartyComponent(
      name: 'qr_flutter / qr',
      version: '4.1.0 / 3.0.2',
      license: 'BSD-3-Clause',
      copyright: 'Copyright (c) 2020 Luke Freeman; the Dart QR project authors',
      purpose: '二维码生成与绘制',
    ),
    ThirdPartyComponent(
      name: 'image_picker, url_launcher, shared_preferences, path_provider',
      version: 'Flutter packages',
      license: 'BSD-3-Clause',
      copyright: 'Copyright 2013 The Flutter Authors',
      purpose: '相册选择、打开链接、设置持久化、应用私有目录',
    ),
    ThirdPartyComponent(
      name: 'share_plus, package_info_plus, plugin_platform_interface',
      version: 'plus_plugins',
      license: 'BSD-3-Clause',
      copyright:
          'Copyright 2017 the Flutter project authors / Chromium Authors',
      purpose: '分享生成的二维码、读取应用版本、插件平台接口',
    ),
    ThirdPartyComponent(
      name: 'http, crypto',
      version: '1.6.0 / 3.0.7',
      license: 'BSD-3-Clause',
      copyright: 'Copyright 2014-2015 the Dart project authors',
      purpose: '更新检查与下载、安装包 SHA-256 校验',
    ),
    ThirdPartyComponent(
      name: 'Flutter',
      version: '3.44.5',
      license: 'BSD-3-Clause',
      copyright: 'Copyright 2014 The Flutter Authors',
      purpose: '跨平台 UI 框架与 Dart 运行时',
    ),
  ];

  /// SHA-256/MD5 provenance of the four bundled model files.
  ///
  /// Recorded so the shipped assets can be checked against the upstream release
  /// they came from.
  static const String modelProvenance =
      'detect.caffemodel  MD5 238e2b2d6f3c18d6c3a30de0c31e23cf\n'
      'detect.prototxt   MD5 6fb4976b32695f9f5c6305c19f12537d\n'
      'sr.caffemodel     MD5 cbfcd60361a73beb8c583eea7e8e6664\n'
      'sr.prototxt       MD5 69db99927a70df953b471daaba03fbef';

  /// The attribution text registered with Flutter's licence registry.
  static const String vendoredNotice = '''
WeChatQRCode — vendored components
==================================

This application embeds source files from the WeChatQRCode project
(https://github.com/jenly1314/WeChatQRCode), version 2.6.0, modules
`wechat-qrcode` and `wechat-qrcode-scanning`, which are licensed under the
Apache License, Version 2.0.

Copyright (C) Jenly Yu. Modifications made by this project are marked in the
file headers; they cover initialisation error reporting, model extraction
location, thread safety and removal of the unused OpenCV loader dependency.

WeChat QRCode engine and models
-------------------------------
The QR detection CNN model, the super-resolution model and the
`wechat_qrcode` decoder are provided by the WeChat Computer Vision Team.

Copyright (C) 2021 THL A29 Limited, a Tencent company. All rights reserved.
Licensed under the Apache License, Version 2.0. Third-party components:
zxing (Apache-2.0, Copyright (c) zxing authors and contributors).

The four model files shipped with this application are byte-identical to the
files published in WeChatCV/opencv_3rdparty at commit a8b69ccc.

OpenCV
------
This application ships OpenCV 4.12.0 through the WeChatQRCode Android
artifacts, licensed under the Apache License, Version 2.0. Only the modules the
WeChat QRCode engine requires (core, imgproc, objdetect, dnn) are exercised.

Full licence texts accompany this application; see the open-source licence
screen for the complete list and the licence body of every dependency.
''';

  /// Adds this project's attribution to Flutter's licence registry so it appears
  /// on the standard licence page alongside the package licences.
  static void register() {
    LicenseRegistry.addLicense(() async* {
      yield const LicenseEntryWithLineBreaks(<String>[
        'WeChatQRCode (vendored)',
        'WeChat QRCode models',
        'OpenCV',
      ], vendoredNotice);
    });
  }
}
