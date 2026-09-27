import 'package:flutter/material.dart';
import 'package:tsdm_client/features/recommend/repository/recommend_repository.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// Ask the user to confirm a rating action on thread [tid] and submit it.
Future<void> showRecommendDialog(BuildContext context, {required String tid, required bool support}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => RootPage(DialogPaths.recommend, _RecommendDialog(tid: tid, support: support)),
    );

class _RecommendDialog extends StatefulWidget {
  const _RecommendDialog({required this.tid, required this.support});

  final String tid;
  final bool support;

  @override
  State<_RecommendDialog> createState() => _RecommendDialogState();
}

class _RecommendDialogState extends State<_RecommendDialog> {
  bool _busy = false;
  RecommendStatus? _result;

  Future<void> _submit() async {
    if (_busy || _result != null) {
      return;
    }
    setState(() => _busy = true);
    final result = await const RecommendRepository().submit(tid: widget.tid, support: widget.support);
    if (!mounted) {
      return;
    }
    setState(() {
      _result = result;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadPage.recommend;
    final message = switch (_result) {
      null => widget.support ? tr.confirmSupport : tr.confirmOppose,
      RecommendStatus.success => tr.success,
      RecommendStatus.duplicate => tr.duplicate,
      RecommendStatus.ownThread => tr.ownThread,
      RecommendStatus.limitReached => tr.limitReached,
      RecommendStatus.denied => tr.denied,
      RecommendStatus.needLogin => tr.needLogin,
      RecommendStatus.unavailable => tr.unavailable,
      RecommendStatus.failed => tr.failed,
    };
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(widget.support ? tr.support : tr.oppose),
        content: _busy ? const SizedBox(height: 64, child: Center(child: CircularProgressIndicator())) : Text(message),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(_result == null ? context.t.general.cancel : context.t.general.close),
          ),
          if (_result == null) TextButton(onPressed: _busy ? null : _submit, child: Text(context.t.general.ok)),
        ],
      ),
    );
  }
}
