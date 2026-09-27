import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The `inajax` envelope of Discuz! carries the page inside a CDATA section; a plain page is used as is.
final _cdataRe = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>');

/// Unwrap a private message answer, which is a bare page or one wrapped in the Discuz XML envelope.
uh.Document parsePrivateMessageDocument(String source) =>
    parseHtmlDocument(_cdataRe.firstMatch(source)?.group(1) ?? source);

/// `errorhandle_<handlekey>('<reason>', {...})` carries the reason a message was rejected.
final _errorHandleRe = RegExp(r'''errorhandle_\w+\s*\(\s*(['"])(.*?)\1''', dotAll: true);

/// `succeedhandle_<handlekey>(...)` as a statement, not as a definition or a `typeof` test.
final _succeedHandleRe = RegExp(r'(?:^|[;{}])\s*succeedhandle_\w+\s*\(', multiLine: true);

/// Read whether the forum stored a sent private message.
///
/// The forum reports a stored message only through `succeedhandle_<handlekey>(url, message)`. An HTTP 200 answer that
/// says nothing - a challenge page, a login page, a page whose script merely defines the handler - must not count as
/// delivered, so the caller keeps the editor content and reports that the result was not confirmed.
SyncVoidEither parsePrivateMessageSendResult(String source) {
  final document = parsePrivateMessageDocument(source);
  final scripts = document.querySelectorAll('script').map((s) => s.text ?? '').join('\n');
  final error = _errorHandleRe.firstMatch(scripts);
  if (error != null) {
    return left(ReplyPersonalMessageFailedException(error.group(2) ?? 'message rejected'));
  }
  if (_succeedHandleRe.hasMatch(scripts)) {
    return rightVoid();
  }
  final text = document.documentElement?.text ?? '';
  if (text.contains('to_login') ||
      text.contains('请先登录') ||
      text.contains('請先登入') ||
      document.querySelector('form[name="login"]') != null) {
    return left(ReplyPersonalMessageFailedException('not logged in'));
  }
  final message = document.querySelector('#messagetext, [id^="returnmessage_"]')?.text?.trim();
  return left(
    ReplyPersonalMessageFailedException(
      message?.isNotEmpty == true ? message! : 'the forum did not confirm the message was sent',
    ),
  );
}
