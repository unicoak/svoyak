import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/game_controller.dart';
import '../models/public_room_view.dart';
import '../models/room_state_view.dart';
import '../theme/app_theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final GameController _controller;

  final TextEditingController _displayNameController =
      TextEditingController(text: 'Player');
  final TextEditingController _packageIdController = TextEditingController();
  final TextEditingController _roomCodeController = TextEditingController();
  final TextEditingController _questionIdController = TextEditingController();
  final TextEditingController _answerController = TextEditingController();

  bool _logsExpanded = false;

  @override
  void initState() {
    super.initState();
    _controller = GameController()..addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_rebuild);
    _controller.dispose();

    _displayNameController.dispose();
    _packageIdController.dispose();
    _roomCodeController.dispose();
    _questionIdController.dispose();
    _answerController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final RoomStateView? roomState = _controller.roomState;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          _buildBackground(),
          SafeArea(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _buildTopCard(roomState),
                      const SizedBox(height: 14),
                      if (roomState == null)
                        _buildLobbyLayout(constraints.maxWidth)
                      else
                        _buildGameLayout(roomState, constraints.maxWidth),
                    ],
                  ),
                );
              },
            ),
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
            Color(0xFF0B1B4A)
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
            child: _glowOrb(
              280,
              const Color(0xAA4A7BFF),
            ),
          ),
          Positioned(
            bottom: -130,
            left: -90,
            child: _glowOrb(
              260,
              const Color(0xAA27D5FF),
            ),
          ),
          Positioned(
            top: 320,
            left: 190,
            child: _glowOrb(
              130,
              const Color(0x6648B8FF),
            ),
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

  Widget _buildTopCard(RoomStateView? roomState) {
    final int playersCount = roomState?.players.length ?? 0;

    return _glassPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'СИ: Онлайн',
                      style: GoogleFonts.sora(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Комнатные дуэли с честным buzz и авто-проверкой ответов',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppPalette.textMuted,
                            height: 1.3,
                          ),
                    ),
                  ],
                ),
              ),
              _statusPill(
                _controller.isConnected ? 'ONLINE' : 'OFFLINE',
                _controller.isConnected
                    ? AppPalette.success
                    : AppPalette.danger,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _metricPill('Latency', '${_controller.rttMs} ms'),
              _metricPill('Offset', '${_controller.offsetMs} ms'),
              if (roomState != null) _metricPill('Room', roomState.roomCode),
              if (roomState != null)
                _metricPill('Status', _humanStatus(roomState.status)),
              if (roomState != null) _metricPill('Players', '$playersCount'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _controller.statusMessage,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppPalette.textMuted,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildLobbyLayout(double width) {
    final bool wide = width > 880;

    return Column(
      children: <Widget>[
        _buildConnectPanel(),
        const SizedBox(height: 14),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: _buildCreateRoomPanel()),
              const SizedBox(width: 12),
              Expanded(child: _buildJoinRoomPanel()),
            ],
          )
        else
          Column(
            children: <Widget>[
              _buildCreateRoomPanel(),
              const SizedBox(height: 12),
              _buildJoinRoomPanel(),
            ],
          ),
      ],
    );
  }

  Widget _buildConnectPanel() {
    return _glassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _sectionTitle('Профиль и сеть', icon: Icons.wifi_tethering),
          const SizedBox(height: 12),
          TextField(
            controller: _displayNameController,
            decoration: const InputDecoration(labelText: 'Имя игрока'),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: _controller.isBusy
                    ? null
                    : () => _controller.ensureConnected(
                          _displayNameController.text.trim(),
                        ),
                icon: const Icon(Icons.power_rounded, size: 18),
                label: const Text('Подключиться'),
              ),
              OutlinedButton.icon(
                onPressed: _controller.isBusy ? null : _controller.syncTime,
                icon: const Icon(Icons.schedule_rounded, size: 18),
                label: const Text('Синхронизировать время'),
              ),
              if (_controller.isBusy)
                const Padding(
                  padding: EdgeInsets.only(left: 6, top: 8),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCreateRoomPanel() {
    return _glassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _sectionTitle('Создать комнату', icon: Icons.add_home_work_rounded),
          const SizedBox(height: 12),
          TextField(
            controller: _packageIdController,
            decoration: const InputDecoration(
              labelText: 'UUID пакета вопросов',
              hintText: '22222222-2222-2222-2222-222222222222',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Тип комнаты',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppPalette.textMuted,
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              ChoiceChip(
                label: const Text('Закрытая (по коду)'),
                selected: _controller.createRoomVisibility == 'PRIVATE',
                onSelected: _controller.isBusy
                    ? null
                    : (bool selected) {
                        if (selected) {
                          _controller.setCreateRoomVisibility('PRIVATE');
                        }
                      },
              ),
              ChoiceChip(
                label: const Text('Публичная'),
                selected: _controller.createRoomVisibility == 'PUBLIC',
                onSelected: _controller.isBusy
                    ? null
                    : (bool selected) {
                        if (selected) {
                          _controller.setCreateRoomVisibility('PUBLIC');
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _controller.isBusy
                  ? null
                  : () => _controller.createRoom(
                        packageId: _packageIdController.text.trim(),
                        displayName: _displayNameController.text.trim(),
                        visibility: _controller.createRoomVisibility,
                      ),
              child: const Text('Создать'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJoinRoomPanel() {
    return _glassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: _sectionTitle(
                  'Присоединиться',
                  icon: Icons.group_add_rounded,
                ),
              ),
              IconButton(
                tooltip: 'Обновить публичные комнаты',
                onPressed: _controller.isBusy
                    ? null
                    : () => _controller.refreshPublicRooms(),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          if (_controller.publicRoomsUpdatedAt != null)
            Text(
              'Публичные комнаты обновлены: ${_formatTime(_controller.publicRoomsUpdatedAt!)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppPalette.textMuted,
                  ),
            ),
          const SizedBox(height: 12),
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
              onPressed: _controller.isBusy
                  ? null
                  : () => _controller.joinRoom(
                        roomCode: _roomCodeController.text.trim(),
                        displayName: _displayNameController.text.trim(),
                      ),
              child: const Text('Войти в комнату'),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Публичные комнаты',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          if (_controller.publicRooms.isEmpty)
            Text(
              'Список пуст. Нажми обновить, чтобы загрузить доступные комнаты.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppPalette.textMuted,
                    height: 1.3,
                  ),
            )
          else
            Column(
              children: _controller.publicRooms
                  .map((PublicRoomView room) => _buildPublicRoomTile(room))
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildPublicRoomTile(PublicRoomView room) {
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
            onPressed: _controller.isBusy || !room.hasFreeSlots
                ? null
                : () {
                    _roomCodeController.text = room.roomCode;
                    _controller.joinPublicRoom(
                      roomCode: room.roomCode,
                      displayName: _displayNameController.text.trim(),
                    );
                  },
            child: Text(room.hasFreeSlots ? 'Войти' : 'Заполнена'),
          ),
        ],
      ),
    );
  }

  Widget _buildGameLayout(RoomStateView roomState, double width) {
    final Widget arenaColumn = Column(
      children: <Widget>[
        _buildQuestionArena(roomState),
        const SizedBox(height: 12),
        _buildLogsPanel(),
      ],
    );

    final Widget sideColumn = Column(
      children: <Widget>[
        _buildRoomPanel(roomState),
        const SizedBox(height: 12),
        _buildQuestionPicker(roomState),
        const SizedBox(height: 12),
        _buildPlayersPanel(roomState.players),
      ],
    );

    if (width > 980) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(flex: 11, child: arenaColumn),
          const SizedBox(width: 12),
          Expanded(flex: 8, child: sideColumn),
        ],
      );
    }

    return Column(
      children: <Widget>[
        arenaColumn,
        const SizedBox(height: 12),
        sideColumn,
      ],
    );
  }

  Widget _buildQuestionArena(RoomStateView roomState) {
    final QuestionView? question = roomState.currentQuestion;
    final bool buzzEnabled = roomState.isQuestionOpen && !_controller.isBusy;

    return _glassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _sectionTitle('Игровая арена', icon: Icons.bolt_rounded),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: const Color(0x333AA6FF),
              border: Border.all(color: AppPalette.border),
            ),
            child: question == null
                ? Text(
                    'Хост выбирает вопрос. Когда вопрос откроется, жми BUZZER.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppPalette.textMuted,
                          height: 1.35,
                        ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _statusPill(
                        '${question.points} pts',
                        AppPalette.warning,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        question.prompt,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  height: 1.3,
                                ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 14),
          _buildBuzzerButton(enabled: buzzEnabled),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _answerController,
                  decoration: const InputDecoration(
                    labelText: 'Твой ответ',
                    hintText: 'Введи текстовый ответ',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _controller.isBusy
                    ? null
                    : () => _controller.submitAnswer(
                          _answerController.text.trim(),
                        ),
                child: const Text('Отправить'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBuzzerButton({required bool enabled}) {
    final Color left =
        enabled ? const Color(0xFF35D39A) : const Color(0xFF2A355D);
    final Color right =
        enabled ? const Color(0xFF2EC8FF) : const Color(0xFF2A355D);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: enabled ? 1 : 0.62,
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
              blurRadius: 24,
              spreadRadius: -10,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: enabled ? _controller.buzz : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.sensors_rounded, color: Colors.white),
                  const SizedBox(width: 10),
                  Text(
                    'BUZZER',
                    style: GoogleFonts.sora(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoomPanel(RoomStateView roomState) {
    return _glassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _sectionTitle('Комната', icon: Icons.meeting_room_rounded),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  roomState.roomCode,
                  style: GoogleFonts.sora(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              IconButton(
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: roomState.roomCode));
                  if (!mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Код комнаты скопирован')),
                  );
                },
                icon: const Icon(Icons.copy_rounded),
                tooltip: 'Копировать код',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _statusPill(
                _humanStatus(roomState.status),
                _statusColor(roomState.status),
              ),
              _statusPill(
                roomState.visibility == 'PUBLIC' ? 'Публичная' : 'Закрытая',
                roomState.visibility == 'PUBLIC'
                    ? const Color(0xFF5CCBFF)
                    : const Color(0xFF8FA6FF),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (_controller.isHost)
                FilledButton.icon(
                  onPressed: _controller.isBusy ? null : _controller.startGame,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Старт'),
                ),
              OutlinedButton.icon(
                onPressed: _controller.isBusy ? null : _controller.syncTime,
                icon: const Icon(Icons.schedule_rounded, size: 18),
                label: const Text('Синхронизация'),
              ),
              OutlinedButton.icon(
                onPressed: _controller.isBusy ? null : _controller.leaveRoom,
                icon: const Icon(Icons.exit_to_app_rounded, size: 18),
                label: const Text('Выйти'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionPicker(RoomStateView roomState) {
    final List<String> quickIds =
        roomState.remainingQuestionIds.take(10).toList();

    return _glassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _sectionTitle('Выбор вопроса', icon: Icons.grid_view_rounded),
          const SizedBox(height: 8),
          Text(
            'Осталось: ${roomState.remainingQuestionIds.length}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppPalette.textMuted,
                ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _questionIdController,
                  decoration: const InputDecoration(
                    labelText: 'UUID вопроса',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _controller.isBusy
                    ? null
                    : () => _controller.selectQuestion(
                          _questionIdController.text.trim(),
                        ),
                child: const Text('Открыть'),
              ),
            ],
          ),
          if (quickIds.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: quickIds
                  .map(
                    (String id) => ActionChip(
                      label: Text(_shortQuestionId(id)),
                      onPressed: _controller.isBusy
                          ? null
                          : () {
                              _questionIdController.text = id;
                              _controller.selectQuestion(id);
                            },
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPlayersPanel(List<PlayerView> players) {
    return _glassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _sectionTitle('Лидерборд', icon: Icons.emoji_events_rounded),
          const SizedBox(height: 10),
          for (int index = 0; index < players.length; index += 1)
            _buildPlayerTile(index, players[index]),
        ],
      ),
    );
  }

  Widget _buildPlayerTile(int rank, PlayerView player) {
    final bool isMe = player.userId == _controller.selfUserId;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: isMe ? const Color(0x334A7BFF) : const Color(0x1AFFFFFF),
        border: Border.all(
          color: isMe ? const Color(0xAA4A7BFF) : AppPalette.border,
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0x331E4FDB),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              '${rank + 1}',
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${player.name}${player.isHost ? ' • host' : ''}${isMe ? ' • you' : ''}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                Text(
                  player.connected ? 'online' : 'offline',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: player.connected
                            ? AppPalette.success
                            : AppPalette.textMuted,
                      ),
                ),
              ],
            ),
          ),
          Text(
            '${player.score}',
            style: GoogleFonts.sora(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsPanel() {
    return _glassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          GestureDetector(
            onTap: () {
              setState(() {
                _logsExpanded = !_logsExpanded;
              });
            },
            child: Row(
              children: <Widget>[
                _sectionTitle('События', icon: Icons.receipt_long_rounded),
                const Spacer(),
                Icon(
                  _logsExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                ),
              ],
            ),
          ),
          if (_logsExpanded) ...<Widget>[
            const SizedBox(height: 10),
            if (_controller.logs.isEmpty)
              Text(
                'Событий пока нет',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppPalette.textMuted,
                    ),
              )
            else
              ..._controller.logs.take(12).map(
                    (String line) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        line,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppPalette.textMuted,
                              height: 1.25,
                            ),
                      ),
                    ),
                  ),
          ],
        ],
      ),
    );
  }

  Widget _glassPanel({
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
        Text(
          text,
          style: GoogleFonts.sora(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
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

  Widget _metricPill(String label, String value) {
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

  String _shortQuestionId(String id) {
    if (id.length <= 8) {
      return id;
    }
    return id.substring(0, 8).toUpperCase();
  }

  String _formatTime(DateTime value) {
    final String hour = value.hour.toString().padLeft(2, '0');
    final String minute = value.minute.toString().padLeft(2, '0');
    final String second = value.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
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

  Color _statusColor(String status) {
    switch (status) {
      case 'LOBBY':
        return AppPalette.accent;
      case 'QUESTION_OPEN':
        return AppPalette.warning;
      case 'ANSWERING':
        return AppPalette.success;
      case 'QUESTION_CLOSED':
        return const Color(0xFF8FA6FF);
      case 'FINISHED':
        return AppPalette.danger;
      default:
        return AppPalette.textMuted;
    }
  }
}
