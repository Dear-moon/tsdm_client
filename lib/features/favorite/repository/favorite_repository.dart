import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/internal/login_parser.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Outcomes of the website's favorite form.
enum FavoriteStatus { ready, success, alreadySaved, needLogin, failed }

/// Form data is retained only until the dialog closes.
class FavoriteForm {
  const FavoriteForm(this.action, this.fields);

  final Uri action;
  final Map<String, String> fields;
}

class FavoriteResponse {
  const FavoriteResponse(this.status, {this.form});

  final FavoriteStatus status;
  final FavoriteForm? form;
}

class FavoriteRepository {
  uh.Document _document(String source) {
    final body = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(source)?.group(1) ?? source;
    return parseHtmlDocument(body);
  }

  FavoriteStatus _status(uh.Document document) {
    if (isDiscuzLoggedOut(document)) return FavoriteStatus.needLogin;
    // AJAX success messages may exist only inside a script in the document head.
    final text = document.documentElement?.text ?? '';
    if (text.contains('not_loggedin') || text.contains('先登录') || text.contains('先登錄') || text.contains('先登入')) {
      return FavoriteStatus.needLogin;
    }
    if (text.contains('favorite_repeat') || text.contains('请勿重复收藏') || text.contains('請勿重複收藏')) {
      return FavoriteStatus.alreadySaved;
    }
    if (text.contains('favorite_do_success') || text.contains('信息收藏成功') || text.contains('資訊收藏成功')) {
      return FavoriteStatus.success;
    }
    return FavoriteStatus.failed;
  }

  Future<FavoriteResponse> load({required String id, required bool isThread}) async {
    final type = isThread ? 'thread' : 'forum';
    final uri = Uri.https(baseHost, '/home.php', {
      'mod': 'spacecp',
      'ac': 'favorite',
      'type': type,
      'id': id,
      'infloat': 'yes',
      'inajax': '1',
      'handlekey': 'favorite',
    });
    // A GET with formhash can add a favorite immediately; request the form without it.
    return getIt.get<NetClientProvider>().getUri(uri).match(
      (_) => const FavoriteResponse(FavoriteStatus.failed),
      (response) {
        if (response.statusCode != 200 || response.data is! String) {
          return const FavoriteResponse(FavoriteStatus.failed);
        }
        final document = _document(response.data as String);
        final form = document.querySelector('form[id^="favoriteform_"]');
        if (form == null) return FavoriteResponse(_status(document));
        final action = uri.resolve(form.attributes['action'] ?? '');
        final fields = <String, String>{
          for (final input in form.querySelectorAll('input[type="hidden"][name]'))
            input.attributes['name']!: input.attributes['value'] ?? '',
        };
        if (action.scheme != 'https' ||
            action.host != baseHost ||
            action.path != '/home.php' ||
            action.queryParameters['mod'] != 'spacecp' ||
            action.queryParameters['op'] != null ||
            action.queryParameters['ac'] != 'favorite' ||
            action.queryParameters['type'] != type ||
            action.queryParameters['id'] != id ||
            fields['formhash']?.isNotEmpty != true ||
            fields['favoritesubmit'] == null) {
          return const FavoriteResponse(FavoriteStatus.failed);
        }
        return FavoriteResponse(FavoriteStatus.ready, form: FavoriteForm(action, fields));
      },
    ).run();
  }

  Future<FavoriteResponse> submit(FavoriteForm form, String description) => getIt
      .get<NetClientProvider>()
      .postForm(
        form.action.toString(),
        queryParameters: {'inajax': '1', 'infloat': 'yes'},
        data: {...form.fields, 'description': description},
      )
      .match(
        (_) => const FavoriteResponse(FavoriteStatus.failed),
        (response) => response.statusCode == 200 && response.data is String
            ? FavoriteResponse(_status(_document(response.data as String)))
            : const FavoriteResponse(FavoriteStatus.failed),
      )
      .run();
}
