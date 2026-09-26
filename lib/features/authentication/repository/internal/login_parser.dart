import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

final _cdataPattern = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>');

String _unwrapCdata(String source) => _cdataPattern.firstMatch(source)?.group(1) ?? source;

String _resolveForumUrl(String path) => Uri.parse('$baseUrl/').resolve(path).toString();

/// Parse the dynamic standard Discuz login form.
SyncEither<LoginHash> parseDiscuzLoginForm(String source) {
  final document = parseHtmlDocument(_unwrapCdata(source));
  final form = document.querySelector('form[name="login"]') ?? document.querySelector('form[id^="loginform_"]');
  if (form == null) {
    return left(LoginFormHashNotFoundException());
  }

  final action = form.attributes['action'];
  if (action == null || action.isEmpty) {
    return left(LoginFormHashNotFoundException());
  }
  final actionUrl = _resolveForumUrl(action);
  final loginHash = Uri.tryParse(actionUrl)?.queryParameters['loginhash'];
  if (loginHash == null || loginHash.isEmpty) {
    return left(LoginFormHashNotFoundException());
  }

  final hiddenFields = <String, String>{};
  for (final input in form.querySelectorAll('input[type="hidden"][name]')) {
    hiddenFields[input.attributes['name']!] = input.attributes['value'] ?? '';
  }
  final formHash = hiddenFields['formhash'];
  if (formHash == null || formHash.isEmpty) {
    return left(LoginInvalidFormHashException());
  }

  final captchaInput = form.querySelector('input[name="seccodeverify"]');
  final captchaHash = form.querySelector('input[name="seccodehash"]')?.attributes['value'];
  final requiresCaptcha = captchaInput != null || captchaHash != null;
  final captchaImagePath = form.querySelector('img[src*="seccode"]')?.attributes['src'];
  final captchaImageUrl = captchaImagePath == null ? null : _resolveForumUrl(captchaImagePath);
  if (requiresCaptcha && (captchaHash == null || captchaHash.isEmpty || captchaImageUrl == null)) {
    return left(LoginOtherErrorException('incomplete captcha challenge'));
  }

  return right(
    LoginHash(
      formHash: formHash,
      loginHash: loginHash,
      actionUrl: actionUrl,
      hiddenFields: hiddenFields,
      requiresCaptcha: requiresCaptcha,
      captchaHash: captchaHash,
      captchaImageUrl: captchaImageUrl,
    ),
  );
}

/// Map known Discuz login result markers to existing application errors.
AppException? parseDiscuzLoginError(String source) {
  final html = _unwrapCdata(source);
  final document = parseHtmlDocument(html);
  final messageNode =
      document.querySelector('#messagetext') ??
      document.querySelector('[id^="returnmessage_"]') ??
      document.querySelector('[id^="message_"]');
  final message = messageNode == null || (messageNode.text?.trim().isEmpty ?? true)
      ? html
      : '${messageNode.text}\n${messageNode.innerHtml ?? ''}';

  if (message.contains('err_login_captcha_invalid') || message.contains('验证码填写错误')) {
    return LoginIncorrectCaptchaException();
  }
  if (message.contains('login_strike') || message.contains('密码错误次数过多')) {
    return LoginAttemptLimitException();
  }
  if (message.contains('login_question_empty') || message.contains('请选择安全提问以及填写正确的答案')) {
    return LoginIncorrectSecurityQuestionException();
  }
  if (message.contains('login_invalid') ||
      message.contains('login_password_invalid') ||
      message.contains('登录失败') ||
      message.contains('密码错误') ||
      message.contains('您输入的密码有误')) {
    return LoginInvalidCredentialException();
  }
  return null;
}

int? _sessionUid(uh.Document document) {
  final pattern = RegExp(r'''\bdiscuz_uid\s*=\s*['"]?(\d+)\b''');
  for (final script in document.querySelectorAll('head script:not([src])')) {
    final match = pattern.firstMatch(script.text ?? '');
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
  }
  return null;
}

/// Recognize guest responses without treating challenge pages as logout.
bool isDiscuzLoggedOut(uh.Document document) {
  final uid = _sessionUid(document);
  if (uid != null) {
    return uid == 0;
  }
  return document.querySelector('#messagelogin, form[name="login"], form[id^="loginform_"]') != null;
}

/// Parse the standard account page after a successful login.
UserLoginInfo? parseLoggedUserInfo(uh.Document document) {
  final sessionUid = _sessionUid(document);
  if (sessionUid == 0) {
    return null;
  }
  final userNodes = document.querySelectorAll('#um .vwmy a, #um a[href], #inner_stat > strong > a');
  for (final userNode in userNodes) {
    final username = userNode.text?.trim();
    final href = userNode.attributes['href'];
    final uid =
        href?.uriQueryParameter('uid')?.parseToInt() ??
        int.tryParse(RegExp(r'space-uid-(\d+)').firstMatch(href ?? '')?.group(1) ?? '');
    if (username == null || username.isEmpty || uid == null || uid <= 0 || (sessionUid != null && uid != sessionUid)) {
      continue;
    }
    return UserLoginInfo(
      uid: uid,
      username: username,
      email: document.querySelector('input#emailnew')?.attributes['value'],
    );
  }
  return null;
}
