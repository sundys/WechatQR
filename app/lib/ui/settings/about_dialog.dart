import 'package:flutter/material.dart';

/// Explains what the app does and which engine powers it.
///
/// Every claim here describes behaviour that actually exists in this build
/// (project spec §8.4); nothing is advertised that is not implemented.
Future<void> showAboutAppDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('介绍'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Paragraph(
              '这是一款本地二维码工具，支持使用相机实时扫码、从相册图片识别，'
              '以及输入文本生成二维码。',
            ),
            const _Heading('二维码识别引擎'),
            const _Paragraph(
              '识别能力基于 OpenCV 的 WeChatQRCode 引擎（含 CNN 检测模型与超分辨率模型），'
              '通过本项目的原生模块在设备本地运行。',
            ),
            const _Heading('主要功能'),
            const _Bullet('相机实时扫码，识别结果以可滚动的弹出层显示'),
            const _Bullet('从相册选择图片识别二维码'),
            const _Bullet('生成二维码，可保存到相册或分享'),
            const _Bullet('本地扫描历史：复制、置顶、删除'),
            const _Bullet('自动复制、自动打开网址、连续扫描、振动等开关'),
            const _Bullet('浅色 / 暗色 / 跟随系统主题'),
            const _Heading('数据与隐私'),
            const _Paragraph(
              '扫描记录、历史与设置仅保存在本机，不会上传或同步。'
              '相机与相册仅在您授权后访问，图片不会被上传。',
            ),
            const _Heading('更新'),
            const _Paragraph(
              '应用版本从安装包元数据读取。Android 可检查 GitHub Releases 并'
              '通过系统安装器安装更新（需您在系统界面确认）；'
              'iOS 仅打开 Releases 网页查看。',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.bodyMedium);
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• '),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
