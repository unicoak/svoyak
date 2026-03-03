import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/game_controller.dart';
import '../core/player_profile_store.dart';
import '../models/public_room_view.dart';
import '../models/room_state_view.dart';
import '../theme/app_theme.dart';

enum _HomeStage { start, lobby, game }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _answerWindowMs = 15000;

  final PlayerProfileStore _profileStore = PlayerProfileStore();

  final TextEditingController _registrationNicknameController =
      TextEditingController();
  final TextEditingController _roomCodeController = TextEditingController();
  final TextEditingController _answerController = TextEditingController();

  GameController? _controller;
  PlayerProfile? _profile;
  _HomeStage _stage = _HomeStage.start;
  bool _isBootstrapping = true;
  bool _isRegistering = false;
  int? _packageDifficultyFilter;
  Timer? _clockTicker;
  int _nowMs = DateTime.now().millisecondsSinceEpoch;
  int _lastSeenFlashVersion = 0;

  @override
  void initState() {
    super.initState();
    _bootstrapProfile();
  }

  Future<void> _bootstrapProfile() async {
    final PlayerProfile? profile = await _profileStore.loadProfile();
    if (!mounted) {
      return;
    }

    if (profile != null) {
      _registrationNicknameController.text = profile.nickname;
      _attachController(profile);
    }

    setState(() {
      _profile = profile;
      _isBootstrapping = false;
    });
  }

  void _attachController(PlayerProfile profile) {
    _disposeController();
    final GameController controller = GameController(userId: profile.userId)
      ..addListener(_onControllerChanged);
    _controller = controller;
  }

  void _disposeController() {
    final GameController? controller = _controller;
    if (controller == null) {
      return;
    }

    controller.removeListener(_onControllerChanged);
    controller.dispose();
    _controller = null;
  }

  void _onControllerChanged() {
    if (!mounted) {
      return;
    }

    final GameController? game = _controller;
    if (game == null) {
      return;
    }

    setState(() {
      if (game.roomState != null) {
        _stage = _HomeStage.game;
      } else if (_stage == _HomeStage.game) {
        _stage = _HomeStage.lobby;
      }
    });

    _syncClockTicker(game);

    if (game.flashMessage != null &&
        game.flashMessageVersion > _lastSeenFlashVersion) {
      _lastSeenFlashVersion = game.flashMessageVersion;
      final String message = game.flashMessage!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.hideCurrentSnackBar();
        messenger?.showSnackBar(
          SnackBar(
            content: Text(message),
            behavior: SnackBarBehavior.floating,
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _stopClockTicker();
    _disposeController();
    _registrationNicknameController.dispose();
    _roomCodeController.dispose();
    _answerController.dispose();
    super.dispose();
  }

  bool _shouldRunClockTicker(GameController game) {
    if (_stage != _HomeStage.game) {
      return false;
    }

    final RoomStateView? roomState = game.roomState;
    if (roomState == null) {
      return false;
    }

    if (roomState.status == 'QUESTION_OPEN') {
      final bool hasRevealWindow = roomState.readStartedAtServerMs != null &&
          roomState.readEndsAtServerMs != null;
      final bool hasBuzzWindow = roomState.buzzOpenAtServerMs != null &&
          roomState.buzzCloseAtServerMs != null;
      return hasRevealWindow || hasBuzzWindow;
    }

    if (roomState.status == 'ANSWERING') {
      return roomState.answerDeadlineServerMs != null;
    }

    if (roomState.status == 'QUESTION_CLOSED') {
      return roomState.autoNextQuestionAtServerMs != null;
    }

    return false;
  }

  void _syncClockTicker(GameController game) {
    if (_shouldRunClockTicker(game)) {
      _startClockTicker();
    } else {
      _stopClockTicker();
    }
  }

  void _startClockTicker() {
    if (_clockTicker != null) {
      return;
    }

    _clockTicker = Timer.periodic(const Duration(milliseconds: 220), (_) {
      if (!mounted || _stage != _HomeStage.game) {
        return;
      }

      setState(() {
        _nowMs = DateTime.now().millisecondsSinceEpoch;
      });
    });
  }

  void _stopClockTicker() {
    _clockTicker?.cancel();
    _clockTicker = null;
  }

  @override
  Widget build(BuildContext context) {
    if (_isBootstrapping) {
      return Scaffold(
        body: Stack(
          children: <Widget>[
            _buildBackground(),
            const SafeArea(
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
          ],
        ),
      );
    }

    if (_profile == null || _controller == null) {
      return Scaffold(
        body: Stack(
          children: <Widget>[
            _buildBackground(),
            SafeArea(child: _buildRegistrationStage()),
          ],
        ),
      );
    }

    final GameController game = _controller!;
    final RoomStateView? roomState = game.roomState;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          _buildBackground(),
          SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _buildCurrentStage(game, roomState),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentStage(GameController game, RoomStateView? roomState) {
    switch (_stage) {
      case _HomeStage.start:
        return KeyedSubtree(
          key: const ValueKey<String>('start'),
          child: _buildStartStage(game),
        );
      case _HomeStage.lobby:
        return KeyedSubtree(
          key: const ValueKey<String>('lobby'),
          child: _buildLobbyStage(game),
        );
      case _HomeStage.game:
        return KeyedSubtree(
          key: const ValueKey<String>('game'),
          child: roomState == null
              ? _buildLobbyStage(game)
              : _buildGameStage(game, roomState),
        );
    }
  }

  Widget _buildRegistrationStage() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          child: _panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Добро пожаловать в СИ: Онлайн',
                  style: _headlineFont(
                    size: 28,
                    weight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Перед началом игры зарегистрируйся: выбери никнейм. '
                  'Профиль сохранится на устройстве до выхода из аккаунта.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppPalette.textMuted,
                        height: 1.35,
                      ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _registrationNicknameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Никнейм',
                    hintText: 'Например, DonSu',
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isRegistering ? null : _registerProfile,
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: Text(_isRegistering
                        ? 'Регистрация...'
                        : 'Зарегистрироваться'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStartStage(GameController game) {
    final PlayerProfile profile = _profile!;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'СИ: Онлайн',
                style: _headlineFont(
                  size: 40,
                  weight: FontWeight.w800,
                  letterSpacing: -1.0,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Привет, ${profile.nickname}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppPalette.accent,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Комнатные интеллектуальные матчи с быстрым подключением друзей.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppPalette.textMuted,
                      height: 1.35,
                    ),
              ),
              const SizedBox(height: 16),
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _sectionTitle(
                            'Профиль',
                            icon: Icons.account_circle_rounded,
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _logout,
                          icon: const Icon(Icons.logout_rounded, size: 18),
                          label: const Text('Log out'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        _statChip('Никнейм', profile.nickname),
                        _statChip('Опыт', '${profile.experience}'),
                        _statChip('Рейтинг', '${profile.rating}'),
                        _statusPill(
                          game.isConnected ? 'ONLINE' : 'OFFLINE',
                          game.isConnected
                              ? AppPalette.success
                              : AppPalette.danger,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: game.isBusy ? null : () => _enterLobby(game),
                        icon: const Icon(Icons.stadium_rounded, size: 20),
                        label: const Text('Игровое лобби'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      game.statusMessage,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppPalette.textMuted,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLobbyStage(GameController game) {
    final PlayerProfile profile = _profile!;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth > 980;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _panel(
                child: Row(
                  children: <Widget>[
                    IconButton(
                      tooltip: 'Назад',
                      onPressed: () {
                        setState(() {
                          _stage = _HomeStage.start;
                        });
                      },
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Игровое лобби',
                            style: _headlineFont(
                              size: 21,
                              weight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'Игрок: ${profile.nickname}',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: AppPalette.textMuted,
                                    ),
                          ),
                        ],
                      ),
                    ),
                    _statusPill(
                      game.isConnected ? 'ONLINE' : 'OFFLINE',
                      game.isConnected ? AppPalette.success : AppPalette.danger,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _logout,
                      tooltip: 'Log out',
                      icon: const Icon(Icons.logout_rounded),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      flex: 5,
                      child: Column(
                        children: <Widget>[
                          _buildCreateRoomCard(game),
                          const SizedBox(height: 10),
                          _buildJoinByCodeCard(game),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 6,
                      child: _buildPublicRoomsCard(game),
                    ),
                  ],
                )
              else
                Column(
                  children: <Widget>[
                    _buildCreateRoomCard(game),
                    const SizedBox(height: 10),
                    _buildPublicRoomsCard(game),
                    const SizedBox(height: 10),
                    _buildJoinByCodeCard(game),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCreateRoomCard(GameController game) {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _sectionTitle('Создать комнату', icon: Icons.add_home_work_rounded),
          const SizedBox(height: 8),
          _buildDifficultySelector(game),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 84, maxHeight: 180),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: const Color(0x1AFFFFFF),
              border: Border.all(color: AppPalette.border),
            ),
            child: game.availablePackages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          'Пакеты не найдены. Попробуй изменить фильтр.',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppPalette.textMuted,
                                  ),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: game.isBusy
                              ? null
                              : () => _resetPackageFilters(game),
                          icon: const Icon(Icons.restart_alt_rounded, size: 18),
                          label: const Text('Сбросить фильтры'),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: game.availablePackages.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (BuildContext context, int index) {
                      final package = game.availablePackages[index];
                      final bool selected =
                          game.selectedPackageId == package.id;

                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: game.isBusy
                            ? null
                            : () => game.setSelectedPackage(package.id),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: selected
                                ? const Color(0x334A7BFF)
                                : const Color(0x14000000),
                            border: Border.all(
                              color: selected
                                  ? const Color(0xAA4A7BFF)
                                  : AppPalette.border,
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              Icon(
                                selected
                                    ? Icons.radio_button_checked_rounded
                                    : Icons.radio_button_unchecked_rounded,
                                color: selected
                                    ? AppPalette.accent
                                    : AppPalette.textMuted,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      package.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${package.authorName} · ${_difficultyLabel(package.difficulty)} · ${package.questionsCount} вопросов',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: AppPalette.textMuted,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (game.packagesUpdatedAt != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Пакеты обновлены: ${_formatTime(game.packagesUpdatedAt!)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppPalette.textMuted,
                  ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'Тип комнаты',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppPalette.textMuted,
                ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              ChoiceChip(
                label: const Text('Закрытая'),
                selected: game.createRoomVisibility == 'PRIVATE',
                onSelected: game.isBusy
                    ? null
                    : (bool selected) {
                        if (selected) {
                          game.setCreateRoomVisibility('PRIVATE');
                        }
                      },
              ),
              ChoiceChip(
                label: const Text('Публичная'),
                selected: game.createRoomVisibility == 'PUBLIC',
                onSelected: game.isBusy
                    ? null
                    : (bool selected) {
                        if (selected) {
                          game.setCreateRoomVisibility('PUBLIC');
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Фальстарты',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppPalette.textMuted,
                ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              ChoiceChip(
                label: const Text('Включены'),
                selected: game.createRoomAllowFalseStarts,
                onSelected: game.isBusy
                    ? null
                    : (bool selected) {
                        if (selected) {
                          game.setCreateRoomAllowFalseStarts(true);
                        }
                      },
              ),
              ChoiceChip(
                label: const Text('Выключены'),
                selected: !game.createRoomAllowFalseStarts,
                onSelected: game.isBusy
                    ? null
                    : (bool selected) {
                        if (selected) {
                          game.setCreateRoomAllowFalseStarts(false);
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: game.isBusy || game.selectedPackageId == null
                  ? null
                  : () => _createRoom(game),
              child: const Text('Создать'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDifficultySelector(GameController game) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Сложность пакета',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppPalette.textMuted,
              ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            _buildDifficultyTile(
              game: game,
              value: null,
              title: 'Любая',
              icon: Icons.all_inclusive_rounded,
            ),
            _buildDifficultyTile(
              game: game,
              value: 1,
              title: 'Легкая',
              icon: Icons.eco_rounded,
            ),
            _buildDifficultyTile(
              game: game,
              value: 2,
              title: 'Средняя',
              icon: Icons.flare_rounded,
            ),
            _buildDifficultyTile(
              game: game,
              value: 3,
              title: 'Сложная',
              icon: Icons.local_fire_department_rounded,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDifficultyTile({
    required GameController game,
    required int? value,
    required String title,
    required IconData icon,
  }) {
    final bool selected = _packageDifficultyFilter == value;
    final Color borderColor = selected ? AppPalette.accent : AppPalette.border;
    final Color bgColor =
        selected ? const Color(0x334A7BFF) : const Color(0x1AFFFFFF);

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: game.isBusy
          ? null
          : () {
              setState(() {
                _packageDifficultyFilter = value;
              });
              _refreshPackages(game);
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 104,
        padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor),
          color: bgColor,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              size: 15,
              color: selected ? AppPalette.accent : AppPalette.textMuted,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPublicRoomsCard(GameController game) {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: _sectionTitle(
                  'Найти публичную комнату',
                  icon: Icons.travel_explore_rounded,
                ),
              ),
              IconButton(
                tooltip: 'Обновить',
                onPressed: game.isBusy ? null : () => _refreshPublicRooms(game),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          if (game.publicRoomsUpdatedAt != null)
            Text(
              'Обновлено: ${_formatTime(game.publicRoomsUpdatedAt!)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppPalette.textMuted,
                  ),
            ),
          const SizedBox(height: 8),
          if (game.publicRooms.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: const Color(0x1AFFFFFF),
                border: Border.all(color: AppPalette.border),
              ),
              child: Text(
                'Список пуст. Нажми обновить и попробуй снова.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppPalette.textMuted,
                    ),
              ),
            )
          else
            Column(
              children: game.publicRooms
                  .map(
                    (PublicRoomView room) => _buildPublicRoomTile(
                      game: game,
                      room: room,
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildJoinByCodeCard(GameController game) {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _sectionTitle('Найти комнату по коду', icon: Icons.pin_rounded),
          const SizedBox(height: 10),
          TextField(
            controller: _roomCodeController,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Код комнаты',
              hintText: 'AB12CD',
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: game.isBusy ? null : () => _joinByCode(game),
              child: const Text('Войти по коду'),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            game.statusMessage,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppPalette.textMuted,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameStage(GameController game, RoomStateView roomState) {
    final double keyboardInset = MediaQuery.of(context).viewInsets.bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.fromLTRB(16, 14, 16, 12 + keyboardInset),
      child: Column(
        children: <Widget>[
          Expanded(
            flex: 7,
            child: _buildGameTopBoardCard(game, roomState),
          ),
          const SizedBox(height: 10),
          Expanded(
            flex: 2,
            child: _buildPlayersCard(game, roomState.players),
          ),
          const SizedBox(height: 10),
          _buildGameAnswerBar(game, roomState),
        ],
      ),
    );
  }

  Widget _buildGameTopBoardCard(GameController game, RoomStateView roomState) {
    final QuestionView? question = roomState.currentQuestion;
    final String topic = _topicLabel(roomState, question);
    final String costLabel = _questionCostLabel(question);
    final int serverNowMs = _nowMs + game.offsetMs;
    final int? buzzOpenAtMs = roomState.buzzOpenAtServerMs;
    final bool canPressSignal = roomState.allowFalseStarts &&
        roomState.status == 'QUESTION_OPEN' &&
        buzzOpenAtMs != null &&
        serverNowMs >= buzzOpenAtMs;
    final bool shouldShowAnswer = roomState.status == 'QUESTION_CLOSED' &&
        question != null &&
        question.answerDisplay.trim().isNotEmpty;
    final String answerComment = question?.answerComment.trim() ?? '';

    return _panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  topic,
                  style: _headlineFont(
                    size: 16,
                    weight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              _statusPill(
                costLabel,
                const Color(0xFF7FD7FF),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Выйти из комнаты',
                onPressed: game.isBusy ? null : game.leaveRoom,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Комната ${roomState.roomCode}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppPalette.textMuted,
                      ),
                ),
              ),
              IconButton(
                tooltip: 'Копировать код',
                onPressed: () => _copyRoomCode(roomState.roomCode),
                icon: const Icon(Icons.copy_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: const Color(0x2236A3FF),
                border: Border.all(
                  color: canPressSignal
                      ? const Color(0xFF4CFF9B)
                      : AppPalette.border,
                  width: canPressSignal ? 2 : 1,
                ),
                boxShadow: canPressSignal
                    ? <BoxShadow>[
                        BoxShadow(
                          color:
                              const Color(0xFF4CFF9B).withValues(alpha: 0.35),
                          blurRadius: 16,
                          spreadRadius: -6,
                          offset: const Offset(0, 8),
                        ),
                      ]
                    : null,
              ),
              child: Scrollbar(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: _buildAnimatedPrompt(game, roomState, question),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 62,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: const Color(0x2535D39A),
                border: Border.all(color: const Color(0x9953DDB0)),
              ),
              child: Text(
                shouldShowAnswer
                    ? 'Правильный ответ: ${question.answerDisplay}\n'
                        'Комментарий: ${answerComment.isEmpty ? '—' : answerComment}'
                    : 'Ответ и комментарий появятся после завершения вопроса.',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _topicLabel(RoomStateView roomState, QuestionView? question) {
    if (question == null) {
      return 'ТЕМА';
    }

    final String? themeTitle = roomState.themeTitlesByRow[question.boardRow];
    if (themeTitle != null && themeTitle.trim().isNotEmpty) {
      return themeTitle.trim();
    }

    if (question.boardRow > 0) {
      return 'ТЕМА ${question.boardRow}';
    }

    return 'ТЕМА';
  }

  String _questionCostLabel(QuestionView? question) {
    if (question == null) {
      return 'Цена —';
    }

    final int normalizedPoints = question.boardCol.clamp(1, 5) * 10;
    return 'Цена $normalizedPoints';
  }

  Widget _buildGameAnswerBar(GameController game, RoomStateView roomState) {
    final PlayerView? self = _findSelfPlayer(game, roomState);
    final int serverNowMs = _nowMs + game.offsetMs;
    final int? autoNextAtMs = roomState.autoNextQuestionAtServerMs;
    final bool hostCanLaunchQuestion = game.isHost &&
        ((roomState.status == 'LOBBY' &&
                roomState.remainingQuestionIds.isNotEmpty) ||
            (roomState.status == 'QUESTION_CLOSED' &&
                roomState.remainingQuestionIds.isNotEmpty &&
                (autoNextAtMs == null || serverNowMs >= autoNextAtMs)));

    if (hostCanLaunchQuestion) {
      return _panel(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: game.isBusy
                ? null
                : () async {
                    if (roomState.status == 'LOBBY') {
                      await game.startGame();
                    }
                    await game.selectNextQuestion();
                  },
            child: const Text('Запустить вопрос'),
          ),
        ),
      );
    }

    if (roomState.status == 'LOBBY' && !game.isHost) {
      return _panel(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Text(
          'Ожидаем ведущего: он запускает первый вопрос.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppPalette.textMuted,
              ),
        ),
      );
    }

    final int? buzzOpenAtMs = roomState.buzzOpenAtServerMs;
    final int? buzzCloseAtMs = roomState.buzzCloseAtServerMs;
    final int? readEndMs = roomState.readEndsAtServerMs;
    final int? answerDeadlineMs = roomState.answerDeadlineServerMs;
    final bool hasQuestion = roomState.currentQuestion != null;
    final bool inQuestionOpen =
        roomState.status == 'QUESTION_OPEN' && hasQuestion;
    final bool inReading =
        inQuestionOpen && buzzOpenAtMs != null && serverNowMs < buzzOpenAtMs;
    final bool withinBuzzWindow = inQuestionOpen &&
        buzzOpenAtMs != null &&
        buzzCloseAtMs != null &&
        serverNowMs >= buzzOpenAtMs &&
        serverNowMs <= buzzCloseAtMs;
    final bool beforeBuzzClose =
        inQuestionOpen && buzzCloseAtMs != null && serverNowMs <= buzzCloseAtMs;
    final bool readingInProgress =
        inQuestionOpen && readEndMs != null && serverNowMs < readEndMs;
    final bool selfCanBuzz = self?.canBuzz ?? false;
    final bool legacyWindowActive = beforeBuzzClose && buzzOpenAtMs == null;

    final bool buzzEnabled = !game.isBusy &&
        selfCanBuzz &&
        hasQuestion &&
        (withinBuzzWindow || inReading || legacyWindowActive);

    final bool submitEnabled = !game.isBusy &&
        hasQuestion &&
        roomState.status == 'ANSWERING' &&
        roomState.activeAnswerUserId == game.selfUserId;
    if (submitEnabled) {
      game.updateAnswerDraft(_answerController.text);
    }
    final bool showAnswerProgress = roomState.status == 'ANSWERING' &&
        answerDeadlineMs != null &&
        serverNowMs <= answerDeadlineMs;
    final int answerMsLeft = showAnswerProgress
        ? (answerDeadlineMs - serverNowMs).clamp(0, _answerWindowMs)
        : 0;
    final double? answerProgress = showAnswerProgress
        ? (answerMsLeft / _answerWindowMs).clamp(0, 1).toDouble()
        : null;

    String buttonLabel = 'КНОПКА';
    String hint = 'Ждите начала вопроса';
    bool buttonWarn = false;

    if (roomState.status == 'ANSWERING') {
      final String timeLabel =
          showAnswerProgress ? ' ${_secondsLeft(answerMsLeft)}c' : '';
      if (roomState.activeAnswerUserId == game.selfUserId) {
        buttonLabel = 'ОТВЕЧАЙ$timeLabel';
        hint = 'Введи ответ в поле ниже';
      } else {
        buttonLabel = 'ОТВЕЧАЕТ ИГРОК$timeLabel';
        hint = 'Кнопка временно недоступна';
      }
    } else if (inReading) {
      final int msLeft = (buzzOpenAtMs - serverNowMs).clamp(0, 60 * 1000);
      if (roomState.allowFalseStarts) {
        buttonLabel = 'ФАЛЬСТАРТ';
        hint =
            'До кнопки ${_secondsLeft(msLeft)} c. Раннее нажатие = блокировка на вопрос.';
        buttonWarn = true;
      } else {
        buttonLabel = 'ЖМИ В ЛЮБОЙ МОМЕНТ';
        hint = 'Можно нажимать уже во время чтения вопроса';
      }
    } else if (withinBuzzWindow) {
      final int msLeft = (buzzCloseAtMs - serverNowMs).clamp(0, 60 * 1000);
      if (roomState.allowFalseStarts) {
        buttonLabel = 'МОЖНО НАЖИМАТЬ';
      } else {
        buttonLabel = readingInProgress ? 'ЖМИ В ЛЮБОЙ МОМЕНТ' : 'ЖМИ!';
      }
      hint = 'Окно кнопки: осталось ${_secondsLeft(msLeft)} c';
    } else if (!selfCanBuzz && inQuestionOpen) {
      buttonLabel = 'БЛОКИРОВКА';
      hint = 'Ты не можешь нажимать кнопку в этом вопросе';
    } else if (roomState.status == 'QUESTION_CLOSED') {
      buttonLabel = 'ОЖИДАНИЕ';
      final int? autoNextAtMs = roomState.autoNextQuestionAtServerMs;
      if (roomState.remainingQuestionIds.isEmpty) {
        hint = 'Игра завершена';
      } else if (autoNextAtMs != null && serverNowMs < autoNextAtMs) {
        hint = 'Показ ответа: ${_secondsLeft(autoNextAtMs - serverNowMs)} c';
      } else {
        hint = 'Ведущий открывает следующий вопрос';
      }
    }

    return _panel(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _buildMainActionButton(
            enabled: buzzEnabled,
            onTap: game.buzz,
            label: buttonLabel,
            warning: buttonWarn,
            progress: answerProgress,
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              hint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppPalette.textMuted,
                  ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _answerController,
                  enabled: submitEnabled,
                  onChanged: (String value) {
                    if (!submitEnabled) {
                      return;
                    }
                    game.updateAnswerDraft(value);
                  },
                  onSubmitted: (_) {
                    if (!submitEnabled) {
                      return;
                    }
                    game.submitAnswer(_answerController.text.trim());
                  },
                  decoration: const InputDecoration(
                    labelText: 'Твой ответ',
                    hintText: 'Введи текст ответа',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: submitEnabled
                    ? () => game.submitAnswer(_answerController.text.trim())
                    : null,
                child: const Text('Ответить'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMainActionButton({
    required bool enabled,
    required VoidCallback onTap,
    required String label,
    bool warning = false,
    double? progress,
  }) {
    final Color left = enabled
        ? (warning ? const Color(0xFFE2862F) : const Color(0xFF35D39A))
        : const Color(0xFF2A355D);
    final Color right = enabled
        ? (warning ? const Color(0xFFD74B4B) : const Color(0xFF2EC8FF))
        : const Color(0xFF2A355D);
    final double? safeProgress = progress?.clamp(0, 1);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: enabled ? 1 : 0.58,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            colors: <Color>[left, right],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: (enabled ? AppPalette.accent : Colors.transparent)
                  .withValues(alpha: 0.35),
              blurRadius: 26,
              spreadRadius: -10,
              offset: const Offset(0, 15),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: Stack(
            children: <Widget>[
              InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: enabled ? onTap : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const Icon(Icons.bolt_rounded, color: Colors.white),
                      const SizedBox(width: 10),
                      Text(
                        label,
                        style: _headlineFont(
                          size: 20,
                          weight: FontWeight.w800,
                          letterSpacing: 0.7,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (safeProgress != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(18)),
                    child: Container(
                      height: 6,
                      color: const Color(0x29000000),
                      child: FractionallySizedBox(
                        widthFactor: safeProgress,
                        alignment: Alignment.centerLeft,
                        child: Container(
                          color: const Color(0xCCFFFFFF),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAnimatedPrompt(
    GameController game,
    RoomStateView roomState,
    QuestionView? question,
  ) {
    final TextStyle baseStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ) ??
            const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              height: 1.3,
              color: Colors.white,
            );

    if (question == null) {
      return Text(
        'Ожидание вопроса. Ведущий запускает игру и открывает следующий вопрос.',
        style: baseStyle,
      );
    }

    final int textLength = question.prompt.length;
    if (textLength == 0) {
      return Text(
        'Вопрос пуст.',
        style: baseStyle,
      );
    }

    final int serverNowMs = _nowMs + game.offsetMs;
    int visibleChars = textLength;

    final int? readStartMs = roomState.readStartedAtServerMs;
    final int? readEndMs = roomState.readEndsAtServerMs;
    if (readStartMs != null &&
        readEndMs != null &&
        readEndMs > readStartMs &&
        roomState.status == 'QUESTION_OPEN') {
      if (serverNowMs <= readStartMs) {
        visibleChars = 0;
      } else if (serverNowMs >= readEndMs) {
        visibleChars = textLength;
      } else {
        final double progress =
            (serverNowMs - readStartMs) / (readEndMs - readStartMs);
        visibleChars = (textLength * progress).floor().clamp(0, textLength);
      }
    } else {
      final int revealDurationMs =
          question.revealDurationMs > 0 ? question.revealDurationMs : 1;
      final int baseRevealedMs = question.revealedMs.clamp(0, revealDurationMs);
      final int liveRevealedMs = question.revealResumedAtServerMs == null
          ? 0
          : (serverNowMs - question.revealResumedAtServerMs!)
              .clamp(0, 60 * 1000);
      final int effectiveRevealedMs =
          (baseRevealedMs + liveRevealedMs).clamp(0, revealDurationMs);
      visibleChars = ((textLength * effectiveRevealedMs) / revealDurationMs)
          .floor()
          .clamp(0, textLength);
    }

    if (visibleChars >= textLength) {
      return Text(
        question.prompt,
        style: baseStyle,
      );
    }

    final String revealed = question.prompt.substring(0, visibleChars);
    final String hidden = question.prompt.substring(visibleChars);

    final bool useTypewriterMode = !roomState.allowFalseStarts;
    if (useTypewriterMode) {
      final bool showCursor = (_nowMs ~/ 350).isEven;
      return Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: revealed,
              style: baseStyle.copyWith(color: Colors.white),
            ),
            if (showCursor)
              TextSpan(
                text: '▌',
                style: baseStyle.copyWith(
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
          ],
        ),
        style: baseStyle,
      );
    }

    return RichText(
      text: TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: revealed,
            style: baseStyle.copyWith(color: Colors.white),
          ),
          TextSpan(
            text: hidden,
            style: baseStyle.copyWith(
              color: Colors.white.withValues(alpha: 0.32),
            ),
          ),
        ],
      ),
    );
  }

  PlayerView? _findSelfPlayer(GameController game, RoomStateView roomState) {
    final String? selfId = game.selfUserId;
    if (selfId == null) {
      return null;
    }

    for (final PlayerView player in roomState.players) {
      if (player.userId == selfId) {
        return player;
      }
    }

    return null;
  }

  String _secondsLeft(int ms) {
    return _secondsLeftInt(ms).toString();
  }

  int _secondsLeftInt(int ms) {
    return ((ms.clamp(0, 60 * 1000) + 999) / 1000).floor();
  }

  Widget _buildPlayersCard(GameController game, List<PlayerView> players) {
    return _panel(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: _sectionTitle('Игроки и счёт',
                    icon: Icons.groups_2_rounded),
              ),
              _statusPill('${players.length}', const Color(0xFF8DB8FF)),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: players.isEmpty
                ? Center(
                    child: Text(
                      'Пока нет игроков',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppPalette.textMuted,
                          ),
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    physics: const ClampingScrollPhysics(),
                    itemCount: players.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (BuildContext context, int index) {
                      return _buildPlayerTile(game, index, players[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerTile(GameController game, int rank, PlayerView player) {
    final bool isMe = player.userId == game.selfUserId;
    final Color scoreColor =
        player.score >= 0 ? const Color(0xFF9BE8C8) : const Color(0xFFFF9B9B);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        color: isMe ? const Color(0x334A7BFF) : const Color(0x1AFFFFFF),
        border: Border.all(
          color: isMe ? const Color(0xAA4A7BFF) : AppPalette.border,
        ),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 24,
            child: Text(
              '${rank + 1}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppPalette.textMuted,
                  ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  '${player.name}${player.isHost ? ' · host' : ''}${isMe ? ' · you' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                Text(
                  player.connected
                      ? (player.canBuzz ? 'online · ready' : 'online · locked')
                      : 'offline',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: player.connected
                            ? (player.canBuzz
                                ? AppPalette.success
                                : AppPalette.warning)
                            : AppPalette.textMuted,
                      ),
                ),
              ],
            ),
          ),
          Container(
            constraints: const BoxConstraints(minWidth: 58),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            alignment: Alignment.centerRight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: const Color(0x1AFFFFFF),
            ),
            child: Text(
              '${player.score}',
              style: _headlineFont(
                size: 18,
                weight: FontWeight.w800,
                color: scoreColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPublicRoomTile({
    required GameController game,
    required PublicRoomView room,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0x1AFFFFFF),
        border: Border.all(color: AppPalette.border),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${room.roomCode} · ${room.hostName}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${room.playersCount}/${room.maxPlayers} игроков · ${_humanStatus(room.status)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppPalette.textMuted,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.tonal(
            onPressed: game.isBusy || !room.hasFreeSlots
                ? null
                : () {
                    _roomCodeController.text = room.roomCode;
                    game.joinPublicRoom(
                      roomCode: room.roomCode,
                      displayName: _profile!.nickname,
                    );
                  },
            child: Text(room.hasFreeSlots ? 'Войти' : 'Заполнена'),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            Color(0xFF060B1A),
            Color(0xFF08133A),
            Color(0xFF0B1B4A),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            top: -120,
            right: -80,
            child: _glowOrb(280, const Color(0xAA4A7BFF)),
          ),
          Positioned(
            bottom: -130,
            left: -90,
            child: _glowOrb(260, const Color(0xAA27D5FF)),
          ),
          Positioned(
            top: 320,
            left: 190,
            child: _glowOrb(130, const Color(0x6648B8FF)),
          ),
        ],
      ),
    );
  }

  Widget _glowOrb(double size, Color color) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: <Color>[color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }

  Widget _panel({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: AppPalette.panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppPalette.border),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 26,
            spreadRadius: -12,
            offset: Offset(0, 20),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _sectionTitle(String text, {required IconData icon}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 19, color: AppPalette.accent),
        const SizedBox(width: 8),
        Text(text, style: _headlineFont(size: 16)),
      ],
    );
  }

  Widget _statusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.16),
        border: Border.all(color: color.withValues(alpha: 0.75)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
      ),
    );
  }

  Widget _statChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        color: const Color(0x1FFFFFFF),
        border: Border.all(color: AppPalette.border),
      ),
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.labelSmall,
          children: <InlineSpan>[
            TextSpan(
              text: '$label ',
              style: const TextStyle(color: AppPalette.textMuted),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextStyle _headlineFont({
    required double size,
    FontWeight weight = FontWeight.w700,
    double letterSpacing = 0,
    Color color = Colors.white,
  }) {
    return TextStyle(
      fontFamily: 'Avenir Next',
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
    );
  }

  Future<void> _registerProfile() async {
    final String nickname = _registrationNicknameController.text.trim();
    if (nickname.isEmpty) {
      _showMessage('Введите никнейм.');
      return;
    }

    setState(() {
      _isRegistering = true;
    });

    try {
      final PlayerProfile profile = await _profileStore.registerProfile(
        nickname: nickname,
      );

      if (!mounted) {
        return;
      }

      _attachController(profile);

      setState(() {
        _profile = profile;
        _stage = _HomeStage.start;
      });
    } catch (error) {
      _showMessage('Не удалось зарегистрироваться: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isRegistering = false;
        });
      }
    }
  }

  Future<void> _logout() async {
    final GameController? game = _controller;
    if (game != null) {
      try {
        await game.leaveRoom();
      } catch (_) {
        // ignore
      }
    }

    _disposeController();
    await _profileStore.clearProfile();

    if (!mounted) {
      return;
    }

    setState(() {
      _profile = null;
      _stage = _HomeStage.start;
      _packageDifficultyFilter = null;
      _roomCodeController.clear();
      _answerController.clear();
      _registrationNicknameController.clear();
    });
  }

  Future<void> _enterLobby(GameController game) async {
    final PlayerProfile? profile = _profile;
    if (profile == null) {
      return;
    }

    await game.ensureConnected(profile.nickname);
    await game.refreshPublicRooms();
    await game.refreshPackages(
      query: null,
      difficulty: _packageDifficultyFilter,
    );

    if (!mounted) {
      return;
    }
    setState(() {
      _stage = _HomeStage.lobby;
    });
  }

  Future<void> _refreshPublicRooms(GameController game) async {
    await game.refreshPublicRooms();
  }

  Future<void> _refreshPackages(GameController game) async {
    await game.refreshPackages(
      query: null,
      difficulty: _packageDifficultyFilter,
    );
  }

  Future<void> _resetPackageFilters(GameController game) async {
    setState(() {
      _packageDifficultyFilter = null;
    });
    await _refreshPackages(game);
  }

  Future<void> _createRoom(GameController game) async {
    final PlayerProfile? profile = _profile;
    if (profile == null) {
      return;
    }

    final String? packageId = game.selectedPackageId;
    if (packageId == null || packageId.isEmpty) {
      _showMessage('Выберите пакет вопросов.');
      return;
    }

    await game.createRoom(
      packageId: packageId,
      displayName: profile.nickname,
      visibility: game.createRoomVisibility,
    );
  }

  Future<void> _joinByCode(GameController game) async {
    final PlayerProfile? profile = _profile;
    if (profile == null) {
      return;
    }

    await game.joinRoom(
      roomCode: _roomCodeController.text.trim(),
      displayName: profile.nickname,
    );
  }

  Future<void> _copyRoomCode(String roomCode) async {
    try {
      await Clipboard.setData(ClipboardData(text: roomCode));
      _showMessage('Код комнаты $roomCode скопирован');
    } catch (_) {
      _showMessage('Не удалось скопировать код комнаты');
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _formatTime(DateTime value) {
    final String hour = value.hour.toString().padLeft(2, '0');
    final String minute = value.minute.toString().padLeft(2, '0');
    final String second = value.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  String _difficultyLabel(int difficulty) {
    switch (difficulty) {
      case 1:
        return 'легкая';
      case 2:
        return 'средняя';
      case 3:
        return 'сложная';
      default:
        return 'сложность $difficulty';
    }
  }

  String _humanStatus(String status) {
    switch (status) {
      case 'LOBBY':
        return 'Лобби';
      case 'QUESTION_OPEN':
        return 'Вопрос открыт';
      case 'ANSWERING':
        return 'Ответ игрока';
      case 'QUESTION_CLOSED':
        return 'Раунд закрыт';
      case 'FINISHED':
        return 'Игра завершена';
      default:
        return status;
    }
  }
}
