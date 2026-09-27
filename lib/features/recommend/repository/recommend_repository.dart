import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// Outcome of the thread rating control ("支持" / "踩踩") of the forum.
enum RecommendStatus {
  /// The forum stored the rating.
  success,

  /// This account already rated the thread.
  duplicate,

  /// A thread can not be rated by its own author.
  ownThread,

  /// The daily rating allowance of the account is used up.
  limitReached,

  /// The account or its group may not rate threads.
  denied,

  /// The forum served a guest page, so the session is gone.
  needLogin,

  /// The page carries no usable rating control.
  unavailable,

  /// The answer could not be read as one of the outcomes above.
  failed,
}

/// Submits the rating control a thread page carries.
///
/// The forum signs the control with the `hash` of the page it was rendered on, so the thread page is fetched first and
/// the link found there is used unchanged; nothing is synthesised. The control is a state changing GET, so an
/// unrecognised answer is never retried here.
final class RecommendRepository {
  /// Constructor.
  const RecommendRepository();

  /// Rate thread [tid] up when [support] is true, down otherwise.
  Future<RecommendStatus> submit({required String tid, required bool support}) async {
    final page = await ThreadRepository().fetchThread(tid: tid).run();
    if (page.isLeft()) {
      return RecommendStatus.failed;
    }
    final document = page.unwrap();
    // The page decides whether this session is logged in; the local record may not be restored yet.
    if (parseLoggedUidFromDocument(document) == null) {
      return RecommendStatus.needLogin;
    }

    final action = support ? 'add' : 'subtract';
    final href = document.querySelector('a#recommend_$action')?.attributes['href'];
    final relative = href == null ? null : Uri.tryParse(href);
    if (relative == null) {
      return RecommendStatus.unavailable;
    }
    final uri = Uri.parse('$baseUrl/').resolveUri(relative);
    final query = uri.queryParameters;
    if (uri.scheme != 'https' ||
        uri.host != baseHost ||
        uri.path != '/forum.php' ||
        query['mod'] != 'misc' ||
        query['action'] != 'recommend' ||
        query['do'] != action ||
        query['tid'] != tid ||
        (query['hash']?.isEmpty ?? true)) {
      return RecommendStatus.unavailable;
    }

    final result = await getIt
        .get<NetClientProvider>()
        .getUri(uri.replace(queryParameters: {...query, 'inajax': '1'}))
        .run();
    if (result.isLeft()) {
      return RecommendStatus.failed;
    }
    final response = result.unwrap();
    if (response.statusCode != HttpStatus.ok || response.data is! String) {
      return RecommendStatus.failed;
    }
    return parseResponse(response.data as String, support: support);
  }

  /// Read the reason of an `inajax` rating answer.
  static RecommendStatus parseResponse(String source, {required bool support}) {
    final html = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(source)?.group(1) ?? source;
    final document = parseHtmlDocument(html);
    final text = document.documentElement?.text ?? '';
    if (text.contains('to_login') || text.contains('请先登录') || text.contains('請先登入')) {
      return RecommendStatus.needLogin;
    }
    if (text.contains('recommend_duplicate') || text.contains('已评价过本主题') || text.contains('已評價過本主題')) {
      return RecommendStatus.duplicate;
    }
    if (text.contains('recommend_self_disallow') || text.contains('不能评价自己的帖子') || text.contains('不能評價自己的帖子')) {
      return RecommendStatus.ownThread;
    }
    if (text.contains('recommend_outoftimes') || text.contains('评价机会已用完') || text.contains('評價機會已用完')) {
      return RecommendStatus.limitReached;
    }
    if (text.contains('no_privilege_recommend') || text.contains('没有权限') || text.contains('沒有權限')) {
      return RecommendStatus.denied;
    }
    final delta = document.querySelector('#recommentv')?.text?.trim() ?? '';
    final expected = support ? RegExp(r'^\+\d+$') : RegExp(r'^-\d+$');
    if (text.contains('recommend_succeed') || text.contains('recommend_daycount_succeed') || expected.hasMatch(delta)) {
      return RecommendStatus.success;
    }
    return RecommendStatus.failed;
  }
}
