import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/recommend/repository/recommend_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

Future<void> showRecommendDialog(BuildContext context, {required String tid, required bool support}) async {
  final login = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RecommendDialog(tid: tid, support: support),
  );
  if (login == true && context.mounted) {
    await context.pushNamed(ScreenPaths.login);
  }
}

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
    if (_busy || _result != null) return;
    setState(() => _busy = true);
    final repository = RecommendRepository(authenticationRepository: context.read<AuthenticationRepository>());
    final result = await repository.submit(tid: widget.tid, support: widget.support);
    if (!mounted) return;
    setState(() {
      _result = result;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.recommend;
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
      child: CustomAlertDialog.sync(
        title: Text(widget.support ? tr.support : tr.oppose),
        content: _busy ? const SizedBox(height: 64, child: Center(child: CircularProgressIndicator())) : Text(message),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(_result == null ? context.t.general.cancel : context.t.general.close),
          ),
          if (_result == null) TextButton(onPressed: _busy ? null : _submit, child: Text(context.t.general.ok)),
          if (_result == RecommendStatus.needLogin)
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context, true),
              child: Text(context.t.loginPage.login),
            ),
        ],
      ),
    );
  }
}
