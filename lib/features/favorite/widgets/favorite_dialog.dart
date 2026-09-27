import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

Future<void> showFavoriteDialog(BuildContext context, {required String id, required bool isThread}) async {
  final login = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FavoriteDialog(id: id, isThread: isThread),
  );
  if (login == true && context.mounted) {
    await context.pushNamed(ScreenPaths.login);
  }
}

class _FavoriteDialog extends StatefulWidget {
  const _FavoriteDialog({required this.id, required this.isThread});

  final String id;
  final bool isThread;

  @override
  State<_FavoriteDialog> createState() => _FavoriteDialogState();
}

class _FavoriteDialogState extends State<_FavoriteDialog> {
  final _repository = FavoriteRepository();
  final _description = TextEditingController();
  FavoriteResponse? _response;
  bool _busy = true;
  int? _accountId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _accountId = context.read<AuthenticationRepository>().currentUser?.uid;
    // Cookies can be valid before the local account profile has been restored.
    setState(() => _busy = true);
    final result = await _repository.load(id: widget.id, isThread: widget.isThread);
    if (!mounted) return;
    setState(() {
      _response = result;
      _busy = false;
    });
  }

  Future<void> _submit() async {
    final form = _response?.form;
    if (_busy || form == null) return;
    // The form belongs to the account that opened it.
    if (context.read<AuthenticationRepository>().currentUser?.uid != _accountId) {
      setState(() => _response = const FavoriteResponse(FavoriteStatus.failed));
      return;
    }
    setState(() => _busy = true);
    final result = await _repository.submit(form, _description.text);
    if (!mounted) return;
    setState(() {
      _response = result;
      _busy = false;
    });
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.favorite;
    final status = _response?.status;
    final message = switch (status) {
      FavoriteStatus.success => tr.success,
      FavoriteStatus.alreadySaved => tr.alreadySaved,
      FavoriteStatus.needLogin => tr.needLogin,
      _ => tr.failed,
    };
    return PopScope(
      canPop: !_busy,
      child: CustomAlertDialog.sync(
        title: Text(widget.isThread ? tr.thread : tr.forum),
        content: SizedBox(
          width: 360,
          child: _busy
              ? const Center(child: CircularProgressIndicator())
              : status == FavoriteStatus.ready
              ? TextField(
                  controller: _description,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(labelText: tr.description),
                )
              : Text(message),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(status == FavoriteStatus.ready ? context.t.general.cancel : context.t.general.close),
          ),
          if (status == FavoriteStatus.ready)
            TextButton(onPressed: _busy ? null : _submit, child: Text(context.t.general.ok)),
          if (status == FavoriteStatus.failed)
            TextButton(onPressed: _busy ? null : _load, child: Text(context.t.general.retry)),
          if (status == FavoriteStatus.needLogin)
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context, true),
              child: Text(context.t.loginPage.login),
            ),
        ],
      ),
    );
  }
}
