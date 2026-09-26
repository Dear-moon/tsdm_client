import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/authentication/repository/internal/login_parser.dart';
import 'package:tsdm_client/features/thread/v1/models/models.dart';
import 'package:tsdm_client/features/thread/v1/repository/discuz_dsign_decoder.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Repository of thread page of the app.
class ThreadRepository {
  /// Constructor.
  ThreadRepository({String? redirect})
    : _pendingRedirect = {'nextoldset', 'nextnewset', 'lastpost'}.contains(redirect) ? redirect : null;

  String? _pendingRedirect;
  void _completeRedirect(uh.Document document, Uri responseUri) {
    if (_pendingRedirect == null || document.querySelector('#postlist') == null) return;
    final canonical = document.querySelector('link[rel="canonical"]')?.attributes['href'];
    final tid = Uri.tryParse(canonical ?? '')?.queryParameters['tid'] ?? responseUri.queryParameters['tid'];
    if (tid == null) return;
    // Share the resolved thread, not an action that would redirect again.
    _threadUrl = Uri.https(baseHost, '/forum.php', {
      'mod': 'viewthread',
      'tid': tid,
      'page': '${document.currentPage() ?? 1}',
      'ordertype': ?responseUri.queryParameters['ordertype'],
      'authorid': ?responseUri.queryParameters['authorid'],
    }).toString();
    _pendingRedirect = null;
  }

  String? _threadUrl;

  /// Getter to get the thread url.
  String? get threadUrl => _threadUrl;

  int? _pageNumber;

  /// getter of current thread page number.
  int? get pageNumber => _pageNumber;

  String _buildOperationUrl(String tid) =>
      '$baseUrl/forum.php?mod=misc&action=viewthreadmod&tid=$tid'
      '&infloat=yes&handlekey=viewthreadmod&inajax=1&ajaxtarget=fwin_content_viewthreadmod';

  static bool _isUsableThreadDocument(uh.Document document) {
    if (document.querySelector('div#messagetext, div#messagelogin') != null) {
      return true;
    }

    return document
        .querySelectorAll('div#postlist div[id^="post_"]')
        .any((post) => post.querySelector('[id^="postmessage_"]') != null);
  }

  static String _buildAlternateHostUrl(String url) => Uri.parse(url).replace(host: baseHostAlt).toString();

  /// Fetch the thread page with [tid] on page [pageNumber].
  ///
  /// # Exception
  ///
  /// * **HttpRequestedFailedException** when http request failed.
  AsyncEither<uh.Document> fetchThread({
    String? tid,
    String? pid,
    int pageNumber = 1,
    String? onlyVisibleUid,
    bool? reverseOrder,
    int? exactOrder,
  }) => AsyncEither(() async {
    assert(tid != null || pid != null, 'tid and pid MUST not be null at the same time');

    /// Only visible uid.
    final visibleUid = onlyVisibleUid == null ? '' : '&authorid=$onlyVisibleUid';
    // ordertype: Control sort of post floors.
    // 1: desc (latest post first)
    // 2: asc (oldest post first)
    //
    // Some threads defined reverse order (latest post first) as default
    // post order, it's hard to detect the default order of a thread.
    //
    // Instead, always set `ordertype` query parameter to ensure all threads
    // are in the same default order.
    //
    // And in some situation, do NOT force reverse order, like user is going
    // to find a post in a certain page number, in this use case a manually
    // other override may going into different page that does NOT contain
    // the target post.
    final orderType = switch ((exactOrder, reverseOrder)) {
      (final int i, _) => '&ordertype=$i',
      (null, true) => '&ordertype=1',
      (null, false) => '&ordertype=2',
      (null, null) => '',
    };

    _pageNumber = pageNumber;
    if (tid != null && _pendingRedirect != null) {
      _threadUrl = Uri.https(baseHost, '/forum.php', {
        'mod': 'redirect',
        'goto': _pendingRedirect!,
        'tid': tid,
        'authorid': ?onlyVisibleUid,
      }).toString();
    } else if (tid != null) {
      _threadUrl =
          '$baseUrl/forum.php?mod=viewthread&tid=$tid&extra=page%3D1'
          '$orderType$visibleUid'
          '&page=$pageNumber';
    } else {
      // The page came from where we redirect by finding a post.
      _threadUrl = '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=$pid';
    }

    final netClient = getIt.get<NetClientProvider>();
    final requestUrls = [
      _threadUrl!,
      _buildAlternateHostUrl(_threadUrl!),
      _threadUrl!,
      _buildAlternateHostUrl(_threadUrl!),
    ];
    AppException? lastError;

    for (final requestUrl in requestUrls) {
      final respEither = await netClient.get(requestUrl).run();
      if (respEither.isLeft()) {
        lastError = respEither.unwrapErr();
        continue;
      }

      final resp = respEither.unwrap();
      if (resp.statusCode != HttpStatus.ok) {
        lastError = HttpRequestFailedException(resp.statusCode);
        continue;
      }

      final html = resp.data as String;
      final document = parseHtmlDocument(html);
      // A host-only login cookie cannot authenticate the fallback domain.
      if (Uri.parse(requestUrl).host != baseHost && isDiscuzLoggedOut(document)) {
        lastError = HttpRequestFailedException(HttpStatus.serviceUnavailable);
        continue;
      }
      if (_isUsableThreadDocument(document)) {
        _completeRedirect(document, resp.realUri);
        return right(document);
      }

      String? signedPath;
      for (final script in document.querySelectorAll('script')) {
        signedPath = decodeDiscuzDsignRedirect(script.text ?? '');
        if (signedPath != null) {
          break;
        }
      }
      final signedRedirect = signedPath;
      if (signedRedirect != null) {
        final signedUri = Uri.parse(requestUrl).resolve(signedRedirect);
        final dsign = signedUri.queryParameters['_dsign'];
        if ((signedUri.host == baseHost || signedUri.host == baseHostAlt) && dsign != null && dsign.isNotEmpty) {
          final signedRespEither = await netClient.getUri(signedUri).run();
          if (signedRespEither.isLeft()) {
            lastError = signedRespEither.unwrapErr();
            continue;
          }

          final signedResp = signedRespEither.unwrap();
          if (signedResp.statusCode != HttpStatus.ok) {
            lastError = HttpRequestFailedException(signedResp.statusCode);
            continue;
          }

          final signedDocument = parseHtmlDocument(signedResp.data as String);
          if (signedUri.host != baseHost && isDiscuzLoggedOut(signedDocument)) {
            lastError = HttpRequestFailedException(HttpStatus.serviceUnavailable);
            continue;
          }
          if (_isUsableThreadDocument(signedDocument)) {
            _completeRedirect(signedDocument, signedResp.realUri);
            return right(signedDocument);
          }
        }
      }
      lastError = HttpRequestFailedException(HttpStatus.serviceUnavailable);
    }

    return left(lastError ?? HttpRequestFailedException(null));
  });

  /// Fetch the operation log for thread [tid].
  AsyncEither<List<OperationLogItem>> fetchOperationLog(String tid) =>
      getIt.get<NetClientProvider>().get(_buildOperationUrl(tid)).mapHttp((resp) {
        final htmlData = parseXmlDocument(resp.data as String).documentElement?.nodes.first.text;
        if (htmlData == null) {
          // Safe to throw because we use it in a future builder.
          throw Exception('html data not found');
        }

        final doc = parseHtmlDocument(htmlData);
        final items = doc
            .querySelectorAll('table tr')
            .map(OperationLogItem.fromTr)
            .whereType<OperationLogItem>()
            .toList();
        return items;
      });
}
