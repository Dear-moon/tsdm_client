import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/homepage/internal/homepage_parser.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/profile/internal/profile_parser.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

part 'homepage_bloc.mapper.dart';
part 'homepage_event.dart';
part 'homepage_state.dart';

/// Extension on [uh.Document] to extract user info.
extension ExtractProfileAvatar on uh.Document {
  /// Extract the user avatar url.
  String? extractAvatar() {
    final profileRoot = findProfileRoot(this);
    return profileRoot == null ? null : findProfileAvatarUrl(this, profileRoot);
  }
}

/// Bloc for the homepage of the app.
class HomepageBloc extends Bloc<HomepageEvent, HomepageState> with LoggerMixin {
  /// Constructor.
  HomepageBloc({
    required ForumHomeRepository forumHomeRepository,
    required ProfileRepository profileRepository,
    required AuthenticationRepository authenticationRepository,
  }) : _forumHomeRepository = forumHomeRepository,
       _profileRepository = profileRepository,
       _authenticationRepository = authenticationRepository,
       super(
         forumHomeRepository.hasCache() && forumHomeRepository.hasGuideCache()
             ? _stateFromData(
                 parseHomepageDocuments(
                   forumHomeRepository.getCache()!,
                   forumHomeRepository.getGuideCache()!,
                   username: authenticationRepository.currentUser?.username,
                   avatarUrl: profileRepository.getCache()?.extractAvatar(),
                 ),
               )
             : const HomepageState(),
       ) {
    on<HomepageLoadRequested>(_onHomepageLoadRequested);
    on<HomepageRefreshRequested>(_onHomepageRefreshRequested);
    on<HomepageAuthChanged>(_onHomepageAuthChanged);
    on<HomepagePauseSwiper>(_onHomepagePauseSwiper);
    on<HomepageResumeSwiper>(_onHomepageResumeSwiper);

    // Pair wise the latest two auth status so that we can check if only its
    // inner data changed. For example switch user from one to anther keeps an
    // authed state but the user is changed.
    _authStatusSub = _authenticationRepository.status.pairwise().listen(
      (statusList) =>
          add(HomepageAuthChanged(prev: statusList.elementAtOrNull(statusList.length - 2), curr: statusList.last)),
    );
  }

  final ForumHomeRepository _forumHomeRepository;
  final ProfileRepository _profileRepository;

  /// Do not dispose this repo because it is not the owner.
  final AuthenticationRepository _authenticationRepository;
  late final StreamSubscription<List<AuthStatus>> _authStatusSub;

  Future<void> _onHomepageLoadRequested(HomepageLoadRequested event, Emitter<HomepageState> emit) async {
    await _loadHomepage(emit);
  }

  Future<void> _onHomepageRefreshRequested(HomepageRefreshRequested event, Emitter<HomepageState> emit) async {
    await _loadHomepage(emit, force: true);
  }

  Future<void> _loadHomepage(Emitter<HomepageState> emit, {bool force = false}) async {
    if (!force && _forumHomeRepository.hasCache() && _forumHomeRepository.hasGuideCache()) {
      emit(
        _stateFromData(
          parseHomepageDocuments(
            _forumHomeRepository.getCache()!,
            _forumHomeRepository.getGuideCache()!,
            username: _authenticationRepository.currentUser?.username,
            avatarUrl: _profileRepository.getCache()?.extractAvatar(),
          ),
        ),
      );
      return;
    }

    emit(const HomepageState(status: HomepageStatus.loading));
    final homeResult = await _forumHomeRepository.fetchHomePage(force: force).run();
    if (homeResult.isLeft()) {
      homeResult.match(handle, (_) {});
      emit(state.copyWith(status: HomepageStatus.failure));
      return;
    }

    final homeDocument = homeResult.unwrap();
    final authResult = await _authenticationRepository.loginWithDocument(homeDocument).run();
    if (authResult.isLeft() && authResult.unwrapErr() is! LoginUserInfoNotFoundException) {
      handle(authResult.unwrapErr());
    }

    final guideResult = await _forumHomeRepository.fetchGuidePages(force: force).run();
    if (guideResult.isLeft()) {
      guideResult.match(handle, (_) {});
      emit(state.copyWith(status: HomepageStatus.failure));
      return;
    }

    final profileResult = _authenticationRepository.currentUser == null
        ? null
        : await _profileRepository.fetchProfile(force: force).run();

    String? avatarUrl;
    if (profileResult?.isRight() ?? false) {
      avatarUrl = profileResult!.unwrap().extractAvatar();
    } else if (profileResult?.isLeft() ?? false) {
      final profileError = profileResult!.unwrapErr();
      if (profileError is! ProfileNeedLoginException) {
        handle(profileError);
      }
    }

    final username = authResult.isRight() ? _authenticationRepository.currentUser?.username : null;
    emit(
      _stateFromData(
        parseHomepageDocuments(homeDocument, guideResult.unwrap(), username: username, avatarUrl: avatarUrl),
      ),
    );
  }

  Future<void> _onHomepageAuthChanged(HomepageAuthChanged event, Emitter<HomepageState> emit) async {
    if (event.prev != event.curr && state.status != HomepageStatus.loading) {
      add(HomepageRefreshRequested());
    }
  }

  Future<void> _onHomepagePauseSwiper(HomepagePauseSwiper event, Emitter<HomepageState> emit) async {
    emit(state.copyWith(scrollSwiper: false));
  }

  Future<void> _onHomepageResumeSwiper(HomepageResumeSwiper event, Emitter<HomepageState> emit) async {
    emit(state.copyWith(scrollSwiper: true));
  }

  static HomepageState _stateFromData(HomepageData data) => HomepageState(
    status: HomepageStatus.success,
    forumStatus: data.forumStatus,
    loggedUserInfo: data.loggedUserInfo,
    pinnedThreadGroupList: data.pinnedThreadGroups,
  );

  @override
  Future<void> close() async {
    await _authStatusSub.cancel();
    await super.close();
  }
}
