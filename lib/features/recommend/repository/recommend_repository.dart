import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/internal/login_parser.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

enum RecommendStatus { success, duplicate, ownThread, limitReached, denied, needLogin, unavailable, failed }

class RecommendRepository {
  RecommendRepository({required this.authenticationRepository});

  final AuthenticationRepository authenticationRepository;

  Future<RecommendStatus> submit({required String tid, required bool support}) async {
    final uid = authenticationRepository.currentUser?.uid;
    // Let the authenticated page request decide whether the session has expired.
    final result = await ThreadRepository().fetchThread(tid: tid).run();
    if (result.isLeft()) return RecommendStatus.failed;
    final document = result.unwrap();
    if (isDiscuzLoggedOut(document)) {
      return RecommendStatus.needLogin;
    }
    if (authenticationRepository.currentUser?.uid != uid) return RecommendStatus.failed;
    final action = support ? 'add' : 'subtract';
    final link = document.querySelector('a#recommend_$action')?.attributes['href'];
    final relative = link == null ? null : Uri.tryParse(link);
    if (relative == null) return RecommendStatus.unavailable;
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
    // This GET changes server state; never retry it automatically.
    return getIt
        .get<NetClientProvider>()
        .getUri(
          uri.replace(
            queryParameters: {
              ...query,
              'inajax': '1',
            },
          ),
        )
        .match(
          (_) => RecommendStatus.failed,
          (response) {
            if (response.statusCode != 200 || response.data is! String) return RecommendStatus.failed;
            return parseResponse(response.data as String, support: support);
          },
        )
        .run();
  }

  static RecommendStatus parseResponse(String source, {required bool support}) {
    final html = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(source)?.group(1) ?? source;
    final document = parseHtmlDocument(html);
    final text = document.documentElement?.text ?? '';
    if (isDiscuzLoggedOut(document) ||
        text.contains('to_login') ||
        text.contains('先登录') ||
        text.contains('先登錄') ||
        text.contains('先登入')) {
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
    if (text.contains('no_privilege_recommend') ||
        text.contains('没有权限') ||
        text.contains('沒有權限') ||
        text.contains('无权') ||
        text.contains('無權') ||
        text.contains('用户组') ||
        text.contains('用戶組')) {
      return RecommendStatus.denied;
    }
    final delta = document.querySelector('#recommentv')?.text?.trim() ?? '';
    final expectedDelta = support ? RegExp(r'^\+\d+$') : RegExp(r'^-\d+$');
    if (text.contains('recommend_succeed') ||
        text.contains('recommend_daycount_succeed') ||
        (document.querySelector('#recommentc') != null && expectedDelta.hasMatch(delta))) {
      return RecommendStatus.success;
    }
    return RecommendStatus.failed;
  }
}
