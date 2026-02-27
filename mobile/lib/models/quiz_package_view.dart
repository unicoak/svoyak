class QuizPackageView {
  QuizPackageView({
    required this.id,
    required this.title,
    required this.authorName,
    required this.difficulty,
    required this.questionsCount,
  });

  final String id;
  final String title;
  final String authorName;
  final int difficulty;
  final int questionsCount;

  factory QuizPackageView.fromMap(Map<String, dynamic> raw) {
    return QuizPackageView(
      id: raw['id']?.toString() ?? '',
      title: raw['title']?.toString() ?? 'Без названия',
      authorName: raw['authorName']?.toString() ?? 'Неизвестный автор',
      difficulty: (raw['difficulty'] as num?)?.toInt() ?? 3,
      questionsCount: (raw['questionsCount'] as num?)?.toInt() ?? 0,
    );
  }
}
